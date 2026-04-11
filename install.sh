#!/usr/bin/env bash
set -euo pipefail

trap 'echo -e "\033[1;31m[ERROR]\033[0m Ошибка в строке $LINENO"; exit 1' ERR

log()  { echo -e "\033[1;32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
die()  { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }

usage() {
  cat <<'EOF'
Использование:
  install.sh [-r <repo_url>] [-b <branch>] [-p <project_dir>] [-d <domain>]

Параметры:
  -r  Git URL репозитория (по умолчанию: https://github.com/iqubik/myfakesite.git)
  -b  Ветка (по умолчанию: main)
  -p  Папка установки (по умолчанию: /opt/myfakesite)
  -d  Домен для nginx (по умолчанию: localhost — HTTP-режим без SSL)
  -h  Показать эту справку

Примеры:
  ./install.sh
  ./install.sh -d fakesite.example.com
  ./install.sh -r https://github.com/me/myfakesite.git -b mybranch -d demo.example.com
EOF
}

need_root() {
  [[ $EUID -eq 0 ]] || die "Запускать только от root"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Не найдена команда: $1"
}

resolve_compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=("docker" "compose")
    return 0
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=("docker-compose")
    return 0
  fi
  die "Не найден Docker Compose (ни v2 plugin, ни v1 binary)"
}

REPO_URL="https://github.com/iqubik/myfakesite.git"
BRANCH="main"
PROJECT_DIR="/opt/myfakesite"
DOMAIN=""

while getopts ":r:b:p:d:h" opt; do
  case "$opt" in
    r) REPO_URL="$OPTARG" ;;
    b) BRANCH="$OPTARG" ;;
    p) PROJECT_DIR="$OPTARG" ;;
    d) DOMAIN="$OPTARG" ;;
    h)
      usage
      exit 0
      ;;
    :)
      die "Параметр -$OPTARG требует значение"
      ;;
    \?)
      die "Неизвестный параметр: -$OPTARG"
      ;;
  esac
done

need_root
need_cmd docker
resolve_compose_cmd
log "Compose команда: ${COMPOSE_CMD[*]}"

#################################
# CLONE OR PULL SOURCE
#################################
log "Подготовка проекта в $PROJECT_DIR"

if [[ ! -d "$PROJECT_DIR/.git" ]]; then
  if [[ -e "$PROJECT_DIR" ]]; then
    die "Путь $PROJECT_DIR существует, но это не git-репозиторий. Удалите вручную или укажите другой -p."
  fi
  log "Клонируем репозиторий ${REPO_URL} (${BRANCH})..."
  git clone --single-branch --branch "$BRANCH" "$REPO_URL" "$PROJECT_DIR"
else
  log "Репозиторий уже существует — обновляем..."
  cd "$PROJECT_DIR"
  git remote set-url origin "$REPO_URL" 2>/dev/null || true
  git fetch origin "$BRANCH"
  if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git checkout "$BRANCH"
    git merge --ff-only FETCH_HEAD || warn "Не удалось fast-forward merge. Возможны локальные изменения."
  else
    git checkout -b "$BRANCH" FETCH_HEAD
  fi
  log "Исходники обновлены."
fi

cd "$PROJECT_DIR"

#################################
# DOMAIN CONFIGURATION
#################################
if [[ -z "$DOMAIN" ]]; then
  # Интерактивный запрос если не указан
  read -r -p "Введите домен (оставьте пустым для localhost / HTTP-режима): " DOMAIN
fi

if [[ -n "$DOMAIN" && "$DOMAIN" != "localhost" ]]; then
  log "Настраиваем домен: $DOMAIN"

  # Заменяем YOUDOMEN.XXX в nginx.conf
  sed -i "s/YOUDOMEN\.XXX/${DOMAIN}/g" nginx.conf

  # Заменяем YOUDOMEN.XXX в docker-compose.yml
  sed -i "s/YOUDOMEN\.XXX/${DOMAIN}/g" docker-compose.yml

  # Проверяем наличие SSL-сертификатов
  SSL_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
  SSL_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"

  if [[ -f "$SSL_CERT" && -f "$SSL_KEY" ]]; then
    log "SSL-сертификаты найдены: $SSL_CERT"
  else
    warn "SSL-сертификаты не найдены для $DOMAIN"
    read -r -p "Продолжить в HTTP-режиме (без SSL)? (y/n): " ssl_answer
    case "$ssl_answer" in
      y|Y)
        log "Создаём docker-compose.override.yml для HTTP-режима..."
        cat > docker-compose.override.yml <<'OVERRIDE'
services:
  fakesite:
    ports:
      - "80:80"
    volumes:
      - ./nginx-http.conf:/etc/nginx/conf.d/default.conf:ro
OVERRIDE

        # Создаём HTTP-версию конфига (убираем SSL-секцию и listen 443)
        cat > nginx-http.conf <<'HTTPCONF'
server {
    listen 80;
    listen [::]:80;
    server_name YOUDOMEN.XXX;

    server_tokens off;

    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Robots-Tag "noindex, nofollow" always;
    add_header Referrer-Policy "no-referrer" always;

    location / {
        root /usr/share/nginx/html;
        index index.html;
        try_files $uri $uri/ /index.html;
    }

    location ~ \.php$ {
        root /usr/share/nginx/html;
        fastcgi_pass php-fpm:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;
    }

    location ~ ^/(?:\.ht.*|\.git.*|\.env.*|data/|config/|lib/|3rdparty/) {
        return 404;
    }

    error_page 500 502 503 504 /50x.html;
    location = /50x.html {
        root /usr/share/nginx/html;
    }
}
HTTPCONF
        sed -i "s/YOUDOMEN\.XXX/${DOMAIN}/g" nginx-http.conf

        log "HTTP-режим активирован (порт 80, без SSL)"
        ;;
      *)
        log "Сгенерируем self-signed SSL-сертификат..."
        mkdir -p "/etc/letsencrypt/live/${DOMAIN}"
        openssl req -x509 -nodes -days 365 \
          -newkey rsa:2048 \
          -keyout "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" \
          -out "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" \
          -subj "/CN=${DOMAIN}" 2>/dev/null
        log "Self-signed сертификат создан (будет предупреждение браузера о недоверенном сертификате)"
        ;;
    esac
  fi
else
  log "Режим localhost — HTTP на порту 80"
  [[ -z "$DOMAIN" ]] && DOMAIN="localhost"

  cat > docker-compose.override.yml <<'OVERRIDE'
services:
  fakesite:
    ports:
      - "80:80"
    volumes:
      - ./nginx-http.conf:/etc/nginx/conf.d/default.conf:ro
OVERRIDE

  cat > nginx-http.conf <<'HTTPCONF'
server {
    listen 80;
    listen [::]:80;

    server_tokens off;

    location / {
        root /usr/share/nginx/html;
        index index.html;
        try_files $uri $uri/ /index.html;
    }

    location ~ \.php$ {
        root /usr/share/nginx/html;
        fastcgi_pass php-fpm:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
    }
}
HTTPCONF
fi

#################################
# START CONTAINERS
#################################
log "Запускаем контейнеры..."
"${COMPOSE_CMD[@]}" up -d --remove-orphans

log "Проверка статуса контейнеров..."
sleep 3
"${COMPOSE_CMD[@]}" ps

log "Готово: MySphere fakesite установлен и запущен"
log "Откройте http://${DOMAIN} (или https://${DOMAIN} если SSL)"
