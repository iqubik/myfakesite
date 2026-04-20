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
  -b  Ветка (по умолчанию: test-ssl-custom-ip)
  -p  Папка проекта (по умолчанию: /opt/myfakesite)
  -y  Неинтерактивный режим (без подтверждения)
  -h  Показать справку

Примеры:
  ./update.sh                              # Обновить до test-ssl-custom-ip
  ./update.sh -b feature-branch            # Обновить до ветки
  ./update.sh -r https://github.com/me/myfakesite.git -b mybranch
EOF
}

REPO_URL="https://github.com/iqubik/myfakesite.git"
BRANCH="test-ssl-custom-ip"
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
echo "[INFO] Версия скрипта: 1.1"
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
SAVED_SSL_PORT=""
if [[ -f "docker-compose.yml" ]]; then
  SAVED_DOMAIN=$(grep -oP '/etc/letsencrypt/live/\K[^/]+' docker-compose.yml 2>/dev/null | head -n1 || true)
  SAVED_SSL_PORT=$(grep -oP '"\K[0-9]+(?=:443")' docker-compose.yml 2>/dev/null | head -n1 || true)
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

  # VERIFY: домен действительно подставлен
  if grep -q 'YOUDOMEN.XXX' docker-compose.yml 2>/dev/null; then
    die "Не удалось подставить домен в docker-compose.yml"
  fi
  if grep -q 'YOUDOMEN.XXX' data/nginx.conf 2>/dev/null; then
    die "Не удалось подставить домен в nginx.conf"
  fi
  log "Домен в конфигурации подтверждён ✓"

  DOMAIN="$SAVED_DOMAIN"
  MODE="https"
  SSL_PORT="${SAVED_SSL_PORT:-443}"

  # VERIFY: SSL-пути в docker-compose.yml
  if grep -q "letsencrypt/live/${DOMAIN}" docker-compose.yml 2>/dev/null; then
    log "SSL-пути в docker-compose.yml подтверждены ✓"
  else
    warn "SSL-пути для ${DOMAIN} не найдены в docker-compose.yml"
  fi
elif [[ -n "$SAVED_DOMAIN" ]]; then
  DOMAIN="localhost"
  MODE="http"
  SSL_PORT="443"
  log "Режим: HTTP"
else
  warn "Не удалось определить предыдущий домен. Запустите install.sh -d <domain>."
  DOMAIN="localhost"
  MODE="http"
  SSL_PORT="443"
fi

export DOMAIN MODE SSL_PORT SSL_CERT_PATH="" SSL_KEY_PATH=""

# Для HTTP-режима обязательно пере-применяем Phase 4 логику:
# - генерируем nginx-http.conf
# - убираем 443/SSL-монты из docker-compose.yml
# Это гарантирует идемпотентность после git reset/merge.
if [[ "$MODE" == "http" ]]; then
  if [[ -f "install/phase4-apply.sh" ]]; then
    # shellcheck source=/dev/null
    source "install/phase4-apply.sh"
  else
    die "Не найден install/phase4-apply.sh — не могу применить HTTP-конфигурацию"
  fi
else
  # HTTPS-режим: восстанавливаем выбранный пользователем host-порт SSL.
  sed -i "s/SSL_PORT_PLACEHOLDER/${SSL_PORT:-443}/g" data/nginx.conf 2>/dev/null || true
  sed -Ei "s|return 301 https://\\\$host(:[0-9]+)?\\\$request_uri;|return 301 https://\\\$host:${SSL_PORT:-443}\\\$request_uri;|g" data/nginx.conf 2>/dev/null || true
  if grep -qE -- '- "[0-9]+:443"' docker-compose.yml 2>/dev/null; then
    sed -Ei "s|- \"[0-9]+:443\"|- \"${SSL_PORT:-443}:443\"|g" docker-compose.yml
  else
    sed -i "/- \"80:80\"/a\      - \"${SSL_PORT:-443}:443\"" docker-compose.yml
  fi
fi

# Подставляем версию из data/VERSION
if [[ -f "data/VERSION" ]]; then
  APP_VERSION=$(tr -d '[:space:]' < data/VERSION)
  log "Версия приложения: ${APP_VERSION}"

  # Стратегия: заменяем VERSION_PLACEHOLDER ИЛИ текущую версию vX.X.X
  # Это гарантирует работу и при первом запуске (placeholder),
  # и при повторных обновлениях (версия уже заменена)
  _bump_version() {
    local file="$1"
    local new_ver="$2"
    [[ -f "$file" ]] || return 0

    if grep -q 'VERSION_PLACEHOLDER' "$file" 2>/dev/null; then
      sed -i "s/VERSION_PLACEHOLDER/${new_ver}/g" "$file"
    else
      # Ищем текущую версию: с "v" (v1.2.3) или без (1.2.3)
      local cur
      cur=$(grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+' "$file" 2>/dev/null | head -n1 || true)
      if [[ -z "$cur" ]]; then
        cur=$(grep -oP "(?<=[\"'])([0-9]+\.[0-9]+\.[0-9]+)(?=[\"'])" "$file" 2>/dev/null | head -n1 || true)
      fi
      if [[ -n "$cur" ]]; then
        sed -i "s/${cur}/${new_ver}/g" "$file"
      fi
    fi
  }

  _bump_version data/index.html "$APP_VERSION"
  _bump_version data/nginx.conf "$APP_VERSION"
  _bump_version data/status.php "$APP_VERSION"

  # VERIFY: версия действительно обновлена
  _version_ok=0
  for f in data/index.html data/nginx.conf data/status.php; do
    if [[ -f "$f" ]]; then
      if grep -q 'VERSION_PLACEHOLDER' "$f" 2>/dev/null; then
        warn "VERSION_PLACEHOLDER найден в $f — замена не сработала"
      elif grep -q "$APP_VERSION" "$f" 2>/dev/null; then
        log "Версия в $f подтверждена: $APP_VERSION ✓"
        _version_ok=$((_version_ok + 1))
      else
        warn "Версия $APP_VERSION не найдена в $f"
      fi
    fi
  done
  if [[ $_version_ok -eq 0 ]]; then
    warn "Ни в одном файле версия не подтверждена. Возможна проблема с обновлением."
  fi
fi

#################################
# CERTBOT RENEWAL SETUP (если LE)
#################################
LE_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
HAS_CERTBOT=0
if command -v certbot >/dev/null 2>&1; then
  HAS_CERTBOT=1
fi

if [[ "$MODE" == "https" && -f "$LE_CERT" && "$HAS_CERTBOT" -eq 1 ]]; then
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
# ACCESS LOG ROTATION CRON (no logrotate)
#################################
mkdir -p /var/log/myfakesite
touch /var/log/myfakesite/access.log

LOG_ROTATE_SCRIPT="${PROJECT_DIR}/data/log-rotate-by-size.sh"
if [[ -f "$LOG_ROTATE_SCRIPT" ]]; then
  chmod 755 "$LOG_ROTATE_SCRIPT" 2>/dev/null || true
  cat > /etc/cron.d/myfakesite-log-rotate <<CRON
# MySphere fakesite — access log rotation by size (1 MiB), without logrotate
*/5 * * * * root ${LOG_ROTATE_SCRIPT} >/dev/null 2>&1
CRON
  chmod 644 /etc/cron.d/myfakesite-log-rotate
  log "cron для ротации access.log подтверждён ✓"
else
  warn "Скрипт ротации логов не найден: $LOG_ROTATE_SCRIPT"
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
HTTPS_HOST_PORT=$(grep -oP '"\K[0-9]+(?=:443")' docker-compose.yml 2>/dev/null | head -n1 || true)
if grep -q "listen 443 ssl" data/nginx.conf 2>/dev/null && [[ -n "$HTTPS_HOST_PORT" ]]; then
  HTTPS_MODE=1
fi

if [[ $HTTPS_MODE -eq 1 ]]; then
  code=$(curl -fsSk -o /dev/null -w "%{http_code}" "https://localhost:${HTTPS_HOST_PORT}/" 2>/dev/null || echo "000")
  if [[ "$code" =~ ^(200|301|302)$ ]]; then
    log "Сайт доступен (HTTPS) ✓"

    # Проверяем версию в /api/status
    api_ver=$(curl -fsSk "https://localhost:${HTTPS_HOST_PORT}/api/status" 2>/dev/null | grep -oP '"version"\s*:\s*"\K[^"]+' || true)
    if [[ -n "$api_ver" ]]; then
      if [[ "$api_ver" == "$APP_VERSION" ]]; then
        log "Версия в API подтверждена: $api_ver ✓"
      else
        warn "Версия в API ($api_ver) не совпадает с ожидаемой ($APP_VERSION)"
      fi
    fi
  else
    warn "Сайт не отвечает на https://localhost:${HTTPS_HOST_PORT}/ (код $code)"
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
