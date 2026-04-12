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
  
  # Загружаем скрипт во временный файл (избегаем pipefail-проблем с прямым piping)
  TMPDOCKER=$(mktemp /tmp/get-docker.XXXXXX.sh)
  if curl -fsSL https://get.docker.com -o "$TMPDOCKER" 2>&1; then
    chmod +x "$TMPDOCKER"
    # Запускаем скрипт — выводим логи для отладки
    if sh "$TMPDOCKER" 2>&1; then
      log "docker установлен ✓"
    else
      rm -f "$TMPDOCKER"
      die "Не удалось установить Docker (скрипт get.docker.com завершился с ошибкой)"
    fi
    rm -f "$TMPDOCKER"
  else
    rm -f "$TMPDOCKER"
    die "Не удалось загрузить установочный скрипт Docker"
  fi
  
  # Запуск демона — пробуем systemctl, fallback на прямое выполнение
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker 2>/dev/null || systemctl start docker 2>/dev/null || true
  else
    # Fallback для систем без systemd
    service docker start 2>/dev/null || true
  fi
  
  # Проверяем что docker действительно работает
  if ! command -v docker >/dev/null 2>&1; then
    die "Docker установлен некорректно — команда docker не найдена"
  fi
  if ! docker info >/dev/null 2>&1; then
    warn "docker info недоступен — возможно демон не запущен, пробуем перезапуск..."
    if command -v systemctl >/dev/null 2>&1; then
      systemctl restart docker 2>/dev/null || true
    else
      service docker restart 2>/dev/null || true
    fi
    sleep 2
    if ! docker info >/dev/null 2>&1; then
      die "Docker демон не отвечает после перезапуска"
    fi
  fi
  log "docker работает ✓"
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
# When run via `curl | bash`, the script has no file path.
# Phase files need to be fetched or located.
#
# Strategy:
#   1. If executed as a file (./install.sh) → use dirname/install
#   2. If PROJECT_DIR already has install/ → use it (re-run)
#   3. If running from piped curl → download phases from GitHub into /tmp

_resolve_phase_dir() {
  local dir=""

  # Strategy 1: direct file execution
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install"
    if [[ -d "$dir" ]]; then
      echo "$dir"
      return 0
    fi
  fi

  # Strategy 2: PROJECT_DIR already cloned (re-run scenario)
  if [[ -n "$PROJECT_DIR" && -d "$PROJECT_DIR/install" ]]; then
    echo "$PROJECT_DIR/install"
    return 0
  fi

  # Strategy 3: download phase files from GitHub into /tmp/install
  if [[ -z "$dir" || ! -d "$dir" ]]; then
    local tmp_install="/tmp/myfakesite-install"
    if [[ ! -d "$tmp_install" ]]; then
      mkdir -p "$tmp_install"
      # Extract org/repo from REPO_URL
      local repo_path="${REPO_URL#https://github.com/}"
      repo_path="${repo_path%.git}"
      local base_url="https://raw.githubusercontent.com/${repo_path}/${BRANCH}/install"

      warn "Загружаем файлы фаз из репозитория..." >&2
      local phase_file
      for phase_file in phase1-prereqs.sh phase2-domain.sh phase3-certs.sh phase4-apply.sh phase5-start.sh; do
        if ! curl -fsSL "${base_url}/${phase_file}" -o "$tmp_install/${phase_file}" 2>&1; then
          die "Не удалось загрузить $phase_file из ${base_url}"
        fi
      done
      log "Файлы фаз загружены ✓" >&2
    fi
    echo "$tmp_install"
    return 0
  fi

  echo ""
  return 1
}

PHASE_DIR="$(_resolve_phase_dir)"
if [[ -z "$PHASE_DIR" || ! -d "$PHASE_DIR" ]]; then
  die "Директория фаз установки не найдена."
fi

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
