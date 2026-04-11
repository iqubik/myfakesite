#!/usr/bin/env bash
# file: install.sh v1.0
set -euo pipefail

trap 'echo -e "\033[1;31m[ERROR]\033[0m Ошибка в строке $LINENO"; exit 1' ERR

# ─── Helpers ───────────────────────────────────────────────
log()  { echo -e "\033[1;32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
die()  { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }

# ─── Usage ─────────────────────────────────────────────────
usage() {
  cat <<'EOF'
Использование:
  install.sh [-r <repo>] [-b <branch>] [-p <dir>] [-d <domain|ip>] [-c <cert_path>] [-k <key_path>]

Параметры:
  -r  Git URL репозитория (по умолчанию: https://github.com/iqubik/myfakesite.git)
  -b  Ветка (по умолчанию: main)
  -p  Папка установки (по умолчанию: /opt/myfakesite)
  -d  Домен или IP-адрес для nginx
      пусто/localhost  → HTTP, порт 80
      IP-адрес         → HTTPS, self-signed сертификат
      домен            → HTTPS, Let's Encrypt или self-signed
  -c  Путь к SSL-сертификату (полный путь к файлу, например /etc/nginx/certs/site.crt)
  -k  Путь к SSL-ключу (полный путь к файлу, например /etc/nginx/certs/site.key)
  -h  Показать эту справку

Примеры:
  ./install.sh                                     # HTTP, localhost
  ./install.sh -d 192.168.1.100                    # self-signed HTTPS
  ./install.sh -d fakesite.example.com             # Let's Encrypt или self-signed
  ./install.sh -c /path/to/cert.pem -k /path/to/privkey.pem  # Свои сертификаты
  ./install.sh -r https://github.com/me/myfakesite.git -b mybranch -d demo.example.com
EOF
}

# ─── Defaults ──────────────────────────────────────────────
REPO_URL="https://github.com/iqubik/myfakesite.git"
BRANCH="main"
PROJECT_DIR="/opt/myfakesite"
DOMAIN=""
CUSTOM_CERT=""
CUSTOM_KEY=""

while getopts ":r:b:p:d:c:k:h" opt; do
  case "$opt" in
    r) REPO_URL="$OPTARG" ;;
    b) BRANCH="$OPTARG" ;;
    p) PROJECT_DIR="$OPTARG" ;;
    d) DOMAIN="$OPTARG" ;;
    c) CUSTOM_CERT="$OPTARG" ;;
    k) CUSTOM_KEY="$OPTARG" ;;
    h) usage; exit 0 ;;
    :) die "Параметр -$OPTARG требует значение" ;;
    \?) die "Неизвестный параметр: -$OPTARG" ;;
  esac
done

# ─── Need root ─────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Запускать только от root"
command -v docker >/dev/null 2>&1 || die "Не найден docker"

# ─── Docker Compose ────────────────────────────────────────
resolve_compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=("docker" "compose")
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=("docker-compose")
  else
    die "Не найден Docker Compose (ни v2 plugin, ни v1 binary)"
  fi
  log "Compose: ${COMPOSE_CMD[*]}"
}
resolve_compose_cmd

# ─── Phase scripts ─────────────────────────────────────────
PHASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/install" && pwd)"

export PHASE_DIR REPO_URL BRANCH PROJECT_DIR DOMAIN CUSTOM_CERT CUSTOM_KEY

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
