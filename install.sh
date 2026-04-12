#!/usr/bin/env bash
# file: install.sh v1.1
set -euo pipefail

trap 'echo -e "\033[1;31m[ERROR]\033[0m Ошибка в строке $LINENO"; exit 1' ERR

# ─── Helpers ───────────────────────────────────────────────
log()  { echo -e "\033[1;32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
die()  { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }

# ─── ASCII Banner ──────────────────────────────────────────
show_banner() {
  echo "==================================================="
  echo "   __  __            _           ____  ____  "
  echo "  |  \/  | __ _  ___| | ___   _ / ___||  _ \ "
  echo "  | |\/| |/ _\` |/ __| |/ / | | \___ \| |_) |"
  echo "  | |  | | (_| | (__|   <| |_| |___) |  __/ "
  echo "  |_|  |_|\__,_|\___|_|\_\\__,_|____/|_|    "
  echo ""
  echo "          MySphere — Mock API Portal             "
  echo "==================================================="
  echo ""
}

# ─── Usage ─────────────────────────────────────────────────
usage() {
  cat <<'EOF'
Использование:
  install.sh [-r <repo>] [-b <branch>] [-p <dir>] [-d <domain|ip>] [-c <cert_path>] [-k <key_path>] [-y]

Параметры:
  -r  Git URL репозитория (по умолчанию: https://github.com/iqubik/myfakesite.git)
  -b  Ветка (по умолчанию: main)
  -p  Папка установки (по умолчанию: /opt/myfakesite)
  -d  Домен или IP-адрес для nginx
      пусто/localhost  → HTTP, порт 80
      IP-адрес         → HTTPS, self-signed сертификат
      домен            → HTTPS, Let's Encrypt или self-signed
  -c  Путь к SSL-сертификату (полный путь к файлу)
  -k  Путь к SSL-ключу (полный путь к файлу)
  -y  Неинтерактивный режим (без вопросов, пропуск confirmations)
  -h  Показать эту справку

Примеры:
  ./install.sh                                     # Интерактивный, HTTP/localhost
  ./install.sh -y                                  # Молча, HTTP/localhost
  ./install.sh -d 192.168.1.100                    # self-signed HTTPS
  ./install.sh -d fakesite.example.com -y          # Молча, Let's Encrypt или self-signed
  ./install.sh -c /path/to/cert.pem -k /path/to/privkey.pem  # Свои сертификаты
  ./install.sh -d demo.example.com -y              # Полностью автоматическая установка
EOF
}

# ─── Defaults ──────────────────────────────────────────────
REPO_URL="https://github.com/iqubik/myfakesite.git"
BRANCH="main"
PROJECT_DIR="/opt/myfakesite"
DOMAIN=""
CUSTOM_CERT=""
CUSTOM_KEY=""
NON_INTERACTIVE=false

while getopts ":r:b:p:d:c:k:yh" opt; do
  case "$opt" in
    r) REPO_URL="$OPTARG" ;;
    b) BRANCH="$OPTARG" ;;
    p) PROJECT_DIR="$OPTARG" ;;
    d) DOMAIN="$OPTARG" ;;
    c) CUSTOM_CERT="$OPTARG" ;;
    k) CUSTOM_KEY="$OPTARG" ;;
    y) NON_INTERACTIVE=true ;;
    h) usage; exit 0 ;;
    :) die "Параметр -$OPTARG требует значение" ;;
    \?) die "Неизвестный параметр: -$OPTARG" ;;
  esac
done

# ─── Banner ────────────────────────────────────────────────
show_banner

# ─── Need root ─────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Запускать только от root"

# ─── Dependency checks ─────────────────────────────────────
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    warn "$1 не найден, пытаемся установить..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq && apt-get install -y -qq "$1" >/dev/null 2>&1 || die "Не удалось установить $1"
      log "$1 установлен ✓"
    else
      die "Не найдена команда: $1"
    fi
  }
}

need_cmd git
need_cmd curl

# Docker — special handling via get.docker.com
if ! command -v docker >/dev/null 2>&1; then
  warn "docker не найден, устанавливаем через get.docker.com..."
  curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 || die "Не удалось установить Docker"
  systemctl is-active --quiet docker || systemctl start docker
  log "docker установлен ✓"
fi

if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
  log "Docker Compose не найден, устанавливаем..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq docker-compose-plugin 2>/dev/null || \
      apt-get install -y -qq docker-compose 2>/dev/null || true
    docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1 || \
      die "Не удалось установить Docker Compose"
    log "Docker Compose установлен ✓"
  else
    die "Docker Compose не найден"
  fi
fi

# ─── Docker Compose cmd ────────────────────────────────────
resolve_compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=("docker" "compose")
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=("docker-compose")
  else
    die "Не найден Docker Compose"
  fi
  log "Compose: ${COMPOSE_CMD[*]}"
}
resolve_compose_cmd

# ─── Helpers: check port, check containers ─────────────────
check_port() {
  local port=$1
  local info
  info=$(ss -tlnp "sport = :${port}" 2>/dev/null | grep -v "^State" || true)

  if [[ -n "$info" ]]; then
    local pid proc_name
    pid=$(echo "$info" | grep -oP 'pid=\K[0-9]+' | head -1 || true)
    if [[ -n "$pid" ]]; then
      proc_name=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
    else
      proc_name="unknown"
      pid="N/A"
    fi
    echo "${pid}:${proc_name}"
    return 1
  fi
  return 0
}

check_containers_running() {
  log "Проверка статуса контейнеров..."
  local timeout=${1:-60}
  local elapsed=0
  local failed=0

  while [ $elapsed -lt $timeout ]; do
    failed=0
    while IFS=$'\t' read -r container_name status; do
      if [ -n "$container_name" ] && [ -n "$status" ]; then
        if ! echo "$status" | grep -qiE "^up|running|healthy|restarting"; then
          failed=1
          warn "Контейнер $container_name в статусе: $status"
        fi
      fi
    done < <("${COMPOSE_CMD[@]}" ps --format "table {{.Name}}\t{{.Status}}" --all 2>/dev/null | tail -n +2)

    if [ $failed -eq 0 ]; then
      log "Все контейнеры запущены успешно ✓"
      return 0
    fi

    sleep 2
    elapsed=$((elapsed + 2))
  done

  return 1
}

# ─── Phase scripts ─────────────────────────────────────────
PHASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/install" && pwd)"

export PHASE_DIR REPO_URL BRANCH PROJECT_DIR DOMAIN CUSTOM_CERT CUSTOM_KEY NON_INTERACTIVE

# Phase 1: Prerequisites + git clone/pull
# shellcheck source=/dev/null
source "$PHASE_DIR/phase1-prereqs.sh"

# Phase 2: Domain detection, port checks, UFW
# shellcheck source=/dev/null
source "$PHASE_DIR/phase2-domain.sh"

# Phase 3: SSL certificates (custom / LE / self-signed)
# shellcheck source=/dev/null
source "$PHASE_DIR/phase3-certs.sh"

# Phase 4: Apply config (replace domain, HTTP mode adaptation)
# shellcheck source=/dev/null
source "$PHASE_DIR/phase4-apply.sh"

# Phase 5: Start containers, verify, summary
# shellcheck source=/dev/null
source "$PHASE_DIR/phase5-start.sh"
