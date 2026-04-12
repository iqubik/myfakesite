#!/usr/bin/env bash
# file: update.sh v1.1
set -euo pipefail

trap 'echo -e "\033[1;31m[ERROR]\033[0m Ошибка в строке $LINENO"; exit 1' ERR

log()  { echo -e "\033[1;32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
die()  { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }

usage() {
  cat <<'EOF'
Использование:
  update.sh [-r <repo_url>] [-b <branch>] [-p <project_dir>] [-y]

Параметры:
  -r  Git URL репозитория (по умолчанию: https://github.com/iqubik/myfakesite.git)
  -b  Ветка (по умолчанию: main)
  -p  Папка проекта (по умолчанию: /opt/myfakesite)
  -y  Неинтерактивный режим (без подтверждения)
  -h  Показать справку

Примеры:
  ./update.sh                              # Обновить до main
  ./update.sh -b feature-branch            # Обновить до ветки
  ./update.sh -r https://github.com/me/myfakesite.git -b mybranch
EOF
}

REPO_URL="https://github.com/iqubik/myfakesite.git"
BRANCH="main"
PROJECT_DIR="/opt/myfakesite"
NON_INTERACTIVE=false

while getopts ":r:b:p:yh" opt; do
  case "$opt" in
    r) REPO_URL="$OPTARG" ;;
    b) BRANCH="$OPTARG" ;;
    p) PROJECT_DIR="$OPTARG" ;;
    y) NON_INTERACTIVE=true ;;
    h) usage; exit 0 ;;
    :) die "Параметр -$OPTARG требует значение" ;;
    \?) die "Неизвестный параметр: -$OPTARG" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Запускать только от root"
command -v git >/dev/null 2>&1 || die "git не установлен"
command -v docker >/dev/null 2>&1 || die "docker не установлен"

resolve_compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=("docker" "compose")
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=("docker-compose")
  else
    die "Не найден Docker Compose"
  fi
}
resolve_compose_cmd

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

# ─── START ─────────────────────────────────────────────────
echo "==================================================="
echo "  MySphere — Обновление"
echo "==================================================="
echo ""

[[ -d "$PROJECT_DIR" ]] || die "Папка проекта не найдена: $PROJECT_DIR"
[[ -f "$PROJECT_DIR/docker-compose.yml" ]] || die "Не найден docker-compose.yml в $PROJECT_DIR"

cd "$PROJECT_DIR"

if [[ ! -d ".git" ]]; then
  die "$PROJECT_DIR не является git-репозиторием. Используйте install.sh."
fi

if [[ "$NON_INTERACTIVE" != "true" ]]; then
  read -r -p "Обновить до ${REPO_URL} (${BRANCH})? [y/n]: " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    log "Обновление отменено"
    exit 0
  fi
fi

#################################
# UPDATE SOURCE
#################################
log "Обновление исходников из ${REPO_URL} (${BRANCH})..."

# Сохраняем текущий домен ДО обновления (reset --hard может затереть)
SAVED_DOMAIN=""
if [[ -f "docker-compose.yml" ]]; then
  SAVED_DOMAIN=$(grep -oP '/etc/letsencrypt/live/\K[^/]+' docker-compose.yml 2>/dev/null | head -n1 || true)
  if [[ -z "$SAVED_DOMAIN" ]]; then
    # Проверяем HTTP-режим
    if grep -q 'nginx-http\.conf' docker-compose.yml 2>/dev/null; then
      SAVED_DOMAIN="localhost"
    fi
  fi
fi

git remote set-url origin "$REPO_URL" 2>/dev/null || true
git fetch origin "$BRANCH"

if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git checkout "$BRANCH"
  git merge --ff-only FETCH_HEAD || {
    warn "Не удалось fast-forward merge."
    warn "Возможны локальные изменения. Принудительно берём версию из репозитория..."
    git reset --hard FETCH_HEAD
  }
else
  git checkout -b "$BRANCH" FETCH_HEAD
fi

log "Исходники обновлены до ${BRANCH} ✓"

#################################
# RESTORE DOMAIN + RE-APPLY CONFIG
#################################
log "Применяем конфигурацию..."

if [[ -n "$SAVED_DOMAIN" && "$SAVED_DOMAIN" != "localhost" ]]; then
  # После reset --hard домен мог вернуться к YOUDOMEN.XXX — восстанавливаем
  sed -i "s/YOUDOMEN\.XXX/${SAVED_DOMAIN}/g" docker-compose.yml 2>/dev/null || true
  sed -i "s/YOUDOMEN\.XXX/${SAVED_DOMAIN}/g" data/nginx.conf 2>/dev/null || true
  log "Домен восстановлен: ${SAVED_DOMAIN}"
  DOMAIN="$SAVED_DOMAIN"
  MODE="https"
elif [[ -n "$SAVED_DOMAIN" ]]; then
  DOMAIN="localhost"
  MODE="http"
  log "Режим: HTTP"
else
  warn "Не удалось определить предыдущий домен. Запустите install.sh -d <domain>."
  DOMAIN="localhost"
  MODE="http"
fi

export DOMAIN MODE SSL_CERT_PATH="" SSL_KEY_PATH=""

# Подставляем версию из data/VERSION
if [[ -f "data/VERSION" ]]; then
  APP_VERSION=$(tr -d '[:space:]' < data/VERSION)
  log "Версия приложения: ${APP_VERSION}"
  sed -i "s/VERSION_PLACEHOLDER/${APP_VERSION}/g" data/index.html 2>/dev/null || true
  sed -i "s/VERSION_PLACEHOLDER/${APP_VERSION}/g" data/nginx.conf 2>/dev/null || true
  sed -i "s/VERSION_PLACEHOLDER/${APP_VERSION}/g" data/status.php 2>/dev/null || true
fi

#################################
# CERTBOT RENEWAL SETUP (если LE)
#################################
LE_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
if [[ "$MODE" == "https" && -f "$LE_CERT" && command -v certbot >/dev/null 2>&1 ]]; then
  log "Проверяем авто-обновление сертификатов..."
  if [[ ! -f /etc/cron.d/certbot-fakesite ]]; then
    log "Настраиваем авто-обновление сертификатов..."
    mkdir -p /etc/myfakesite
    echo "$PROJECT_DIR" > /etc/myfakesite/project_path
    HOOK_SCRIPT="${PROJECT_DIR}/install/certbot-renew-hook.sh"
    cat > /etc/cron.d/certbot-fakesite <<CRON
# MySphere fakesite — certbot auto-renewal (webroot, zero-downtime)
0 3 * * * root certbot renew --quiet --deploy-hook "${HOOK_SCRIPT}" > /var/log/certbot-fakesite.log 2>&1
CRON
    chmod 644 /etc/cron.d/certbot-fakesite
    log "cron job создан ✓"
  fi
fi

#################################
# RESTART CONTAINERS
#################################
log "Перезапуск контейнеров..."
"${COMPOSE_CMD[@]}" down --remove-orphans 2>/dev/null || true
"${COMPOSE_CMD[@]}" up -d --remove-orphans

if ! check_containers_running 60; then
  warn "Не удалось запустить контейнеры. Логи:"
  "${COMPOSE_CMD[@]}" logs --tail=50
  die "Обновление прервано из-за ошибки запуска контейнеров"
fi

#################################
# VERIFY
#################################
log "Проверяем доступность сайта..."

HTTPS_MODE=0
if grep -q "listen 443 ssl" data/nginx.conf 2>/dev/null && grep -q '"443:443"' docker-compose.yml 2>/dev/null; then
  HTTPS_MODE=1
fi

if [[ $HTTPS_MODE -eq 1 ]]; then
  code=$(curl -fsSk -o /dev/null -w "%{http_code}" https://localhost/ 2>/dev/null || echo "000")
  if [[ "$code" =~ ^(200|301|302)$ ]]; then
    log "Сайт доступен (HTTPS) ✓"
  else
    warn "Сайт не отвечает на https://localhost/ (код $code)"
  fi
else
  code=$(curl -fsS -o /dev/null -w "%{http_code}" http://localhost/ 2>/dev/null || echo "000")
  if [[ "$code" =~ ^(200|301|302)$ ]]; then
    log "Сайт доступен (HTTP) ✓"
  else
    warn "Сайт не отвечает на http://localhost/ (код $code)"
  fi
fi

#################################
# CLEANUP
#################################
log "Очистка старых образов..."
docker image prune -f 2>/dev/null || true

echo ""
echo "==================================================="
log "✔ MySphere fakesite обновлён до ${BRANCH}"
echo "==================================================="
