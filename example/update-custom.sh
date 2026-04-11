#!/usr/bin/env bash
set -euo pipefail

#################################
# TRAP
#################################
trap 'echo -e "\033[1;31m[ERROR]\033[0m Ошибка в строке $LINENO"; exit 1' ERR

#################################
# HELPERS
#################################
log()  { echo -e "\033[1;32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
die()  { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }

usage() {
  cat <<'EOF'
Использование:
  update-custom.sh -r <repo_url> -b <branch> [-p <project_dir>] [-s <source_dir>]

Параметры:
  -r  Git URL вашего форка (обязательно), например:
      https://github.com/<user>/3dp-manager.git
  -b  Ветка с вашими правками (обязательно), например:
      dp-fix
  -p  Папка установленного 3dp-manager (по умолчанию /opt/3dp-manager)
  -s  Папка исходников для сборки (по умолчанию /opt/3dp-manager-src)
  -h  Показать эту справку

Пример:
  ./update-custom.sh -r https://github.com/me/3dp-manager.git -b dp-fix
EOF
}

need_root() {
  [[ $EUID -eq 0 ]] || die "Запускать только от root"
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

check_containers_running() {
  log "Проверка статуса контейнеров..."
  local timeout=${1:-60}
  local elapsed=0
  local failed=0

  while [ $elapsed -lt $timeout ]; do
    failed=0
    # Формат: NAME\tSTATUS (например: "3dp-postgres\tUp 2 days" или "3dp-postgres\tError")
    while IFS=$'\t' read -r container_name status; do
      if [ -n "$container_name" ] && [ -n "$status" ]; then
        # Проверяем, что статус содержит Up/running/healthy/restarting
        # Up, Up 2 days, Up Less than a second, (healthy), running, restarting
        if ! echo "$status" | grep -qiE "^up|running|healthy|restarting"; then
          failed=1
          warn "Контейнер $container_name в статусе: $status"
        fi
      fi
    done < <("${COMPOSE_CMD[@]}" ps --format "table {{.Name}}\t{{.Status}}" --all 2>/dev/null | tail -n +2)

    if [ $failed -eq 0 ]; then
      log "Все контейнеры запущены успешно"
      return 0
    fi

    sleep 2
    elapsed=$((elapsed + 2))
  done

  return 1
}

check_and_fix_credentials() {
  log "Проверка учётных данных на безопасность..."
  
  local env_file=".env"
  local credentials_changed=0
  
  # Проверяем, существует ли .env файл
  if [[ ! -f "$env_file" ]]; then
    log "Создание .env файла с безопасными учётными данными..."
    
    # Генерируем случайные пароли
    local db_pass
    local jwt_secret
    local admin_login
    local admin_pass
    
    db_pass=$(openssl rand -base64 12 | tr -dc 'A-Za-z0-9' | cut -c1-12)
    jwt_secret=$(openssl rand -base64 32)
    admin_login=$(openssl rand -base64 8 | tr -dc 'A-Za-z0-9' | cut -c1-8)
    admin_pass=$(openssl rand -base64 12 | tr -dc 'A-Za-z0-9' | cut -c1-12)
    
    # Создаём .env файл
    cat > "$env_file" <<EOF
POSTGRES_USER=admin
POSTGRES_PASSWORD=${db_pass}
POSTGRES_DB=3dp_manager
JWT_SECRET=${jwt_secret}
ADMIN_LOGIN=${admin_login}
ADMIN_PASSWORD=${admin_pass}
PORT=3100
LOG_LEVEL=error
ALLOWED_ORIGINS=
EOF
    
    log "Сгенерированы новые учётные данные:"
    log "  ADMIN_LOGIN: ${admin_login}"
    log "  ADMIN_PASSWORD: ${admin_pass}"
    log "  POSTGRES_PASSWORD: ${db_pass}"
    log "  JWT_SECRET: ${jwt_secret}"
    log "⚠️ Сохраните эти данные в безопасном месте!"
    
    credentials_changed=1
  else
    # Проверяем, не используются ли дефолтные значения
    local admin_login_val
    local admin_pass_val
    local jwt_secret_val
    local db_pass_val
    
    admin_login_val=$(grep -E "^ADMIN_LOGIN=" "$env_file" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'" || echo "")
    admin_pass_val=$(grep -E "^ADMIN_PASSWORD=" "$env_file" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'" || echo "")
    jwt_secret_val=$(grep -E "^JWT_SECRET=" "$env_file" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'" || echo "")
    db_pass_val=$(grep -E "^POSTGRES_PASSWORD=" "$env_file" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'" || echo "")
    
    local needs_update=0
    
    if [[ "$admin_login_val" == "admin" ]] || [[ -z "$admin_login_val" ]]; then
      warn "Обнаружен дефолтный ADMIN_LOGIN=admin"
      needs_update=1
    fi
    
    if [[ "$admin_pass_val" == "admin" ]] || [[ -z "$admin_pass_val" ]]; then
      warn "Обнаружен дефолтный ADMIN_PASSWORD=admin"
      needs_update=1
    fi
    
    if [[ "$jwt_secret_val" == "secretKey" ]] || [[ -z "$jwt_secret_val" ]]; then
      warn "Обнаружен дефолтный JWT_SECRET=secretKey"
      needs_update=1
    fi
    
    if [[ "$db_pass_val" == "admin" ]] || [[ -z "$db_pass_val" ]]; then
      warn "Обнаружен дефолтный POSTGRES_PASSWORD=admin"
      needs_update=1
    fi
    
    if [[ $needs_update -eq 1 ]]; then
      log "Генерация новых безопасных учётных данных..."
      
      # Генерируем новые пароли
      local new_db_pass
      local new_jwt_secret
      local new_admin_login
      local new_admin_pass
      
      new_db_pass=$(openssl rand -base64 12 | tr -dc 'A-Za-z0-9' | cut -c1-12)
      new_jwt_secret=$(openssl rand -base64 32)
      new_admin_login=$(openssl rand -base64 8 | tr -dc 'A-Za-z0-9' | cut -c1-8)
      new_admin_pass=$(openssl rand -base64 12 | tr -dc 'A-Za-z0-9' | cut -c1-12)
      
      # Сохраняем существующие значения, которые не нужно менять
      local existing_postgres_user
      existing_postgres_user=$(grep -E "^POSTGRES_USER=" "$env_file" 2>/dev/null | cut -d'=' -f2 || echo "admin")

      # Создаём новый .env файл
      cat > "$env_file" <<EOF
POSTGRES_USER=${existing_postgres_user:-admin}
POSTGRES_PASSWORD=${new_db_pass}
POSTGRES_DB=3dp_manager
JWT_SECRET=${new_jwt_secret}
ADMIN_LOGIN=${new_admin_login}
ADMIN_PASSWORD=${new_admin_pass}
PORT=3100
LOG_LEVEL=error
ALLOWED_ORIGINS=
EOF
      
      log "Сгенерированы новые учётные данные:"
      log "  ADMIN_LOGIN: ${new_admin_login}"
      log "  ADMIN_PASSWORD: ${new_admin_pass}"
      log "  POSTGRES_PASSWORD: ${new_db_pass}"
      log "  JWT_SECRET: ${new_jwt_secret}"
      log "⚠️ Сохраните эти данные в безопасном месте!"
      
      credentials_changed=1
    else
      log "Учётные данные безопасны ✅"
    fi
  fi
  
  return $credentials_changed
}

ensure_nginx_api_timeouts() {
  local nginx_conf="$1"
  [[ -f "$nginx_conf" ]] || return 0

  local tmp_file
  tmp_file="$(mktemp)"

  awk '
    BEGIN { in_api = 0; in_bus = 0; injected = 0 }
    {
      line = $0

      if (line ~ /^[[:space:]]*location[[:space:]]+\/api\/[[:space:]]*\{/) {
        in_api = 1
        in_bus = 0
        injected = 0
      }

      if (line ~ /^[[:space:]]*location[[:space:]]+\/bus\/[[:space:]]*\{/) {
        in_bus = 1
        in_api = 0
        injected = 0
      }

      if ((in_api || in_bus) && line ~ /proxy_(connect|send|read)_timeout[[:space:]]+[0-9]+s;/) {
        next
      }

      print line

      if ((in_api || in_bus) && line ~ /proxy_set_header[[:space:]]+X-Forwarded-For[[:space:]]+/ && injected == 0) {
        print "        proxy_connect_timeout 10s;"
        print "        proxy_send_timeout 650s;"
        print "        proxy_read_timeout 650s;"
        injected = 1
      }

      if ((in_api || in_bus) && line ~ /^[[:space:]]*}/) {
        in_api = 0
        in_bus = 0
        injected = 0
      }
    }
  ' "$nginx_conf" > "$tmp_file"

  mv "$tmp_file" "$nginx_conf"
}

ensure_bus_location() {
  local nginx_conf="$1"
  [[ -f "$nginx_conf" ]] || return 0

  # Проверяем, есть ли уже location /bus/
  if grep -q "location /bus/" "$nginx_conf"; then
    return 0
  fi

  local tmp_file
  tmp_file="$(mktemp)"

  awk '
    {
      print $0
      if ($0 ~ /^[[:space:]]*location[[:space:]]+\/api\//) {
        found_api = 1
      }
      if (found_api && $0 ~ /^[[:space:]]*\}/) {
        print ""
        print "    location /bus/ {"
        print "        proxy_pass http://backend:3000/bus/;"
        print "        proxy_set_header Host $http_host;"
        print "        proxy_set_header X-Real-IP $remote_addr;"
        print "        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;"
        print "        proxy_connect_timeout 10s;"
        print "        proxy_send_timeout 650s;"
        print "        proxy_read_timeout 650s;"
        print "    }"
        found_api = 0
      }
    }
  ' "$nginx_conf" > "$tmp_file"

  mv "$tmp_file" "$nginx_conf"
}

REPO_URL=""
BRANCH=""
PROJECT_DIR="/opt/3dp-manager"
SOURCE_DIR="/opt/3dp-manager-src"

while getopts ":r:b:p:s:h" opt; do
  case "$opt" in
    r) REPO_URL="$OPTARG" ;;
    b) BRANCH="$OPTARG" ;;
    p) PROJECT_DIR="$OPTARG" ;;
    s) SOURCE_DIR="$OPTARG" ;;
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

[[ -n "$REPO_URL" ]] || { usage; die "Укажите -r <repo_url>"; }
[[ -n "$BRANCH" ]] || { usage; die "Укажите -b <branch>"; }

need_root

[[ -d "$PROJECT_DIR" ]] || die "Папка проекта не найдена: $PROJECT_DIR"
[[ -f "$PROJECT_DIR/docker-compose.yml" ]] || die "Не найден docker-compose.yml в $PROJECT_DIR"

command -v git >/dev/null 2>&1 || die "git не установлен"
command -v docker >/dev/null 2>&1 || die "docker не установлен"
resolve_compose_cmd
log "Compose команда: ${COMPOSE_CMD[*]}"

#################################
# CHECK AND FIX CREDENTIALS
#################################
check_and_fix_credentials || true

#################################
# PREPARE SOURCE
#################################

log "Подготовка исходников в $SOURCE_DIR"
if [[ ! -d "$SOURCE_DIR/.git" ]]; then
  if [[ -e "$SOURCE_DIR" ]]; then
    die "Путь $SOURCE_DIR существует, но это не git-репозиторий. Укажите другой -s или подготовьте папку вручную."
  fi
  git clone --single-branch --branch "$BRANCH" "$REPO_URL" "$SOURCE_DIR"
else
  cd "$SOURCE_DIR"
  git remote set-url origin "$REPO_URL"
  git fetch origin "$BRANCH"

  if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git checkout "$BRANCH"
    # Merge from FETCH_HEAD to support repos cloned with --single-branch
    # where origin/<branch> may not exist.
    git merge --ff-only FETCH_HEAD || die "Не удалось fast-forward merge. Проверьте локальные изменения в $SOURCE_DIR."
  else
    git checkout -b "$BRANCH" FETCH_HEAD
  fi
fi

COMPOSE_OVERRIDE="$PROJECT_DIR/docker-compose.custom.yml"
cat > "$COMPOSE_OVERRIDE" <<EOF
services:
  backend:
    build: $SOURCE_DIR/server
    image: 3dp-manager-server:custom
  frontend:
    build: $SOURCE_DIR/client
    image: 3dp-manager-client:custom
EOF

ensure_nginx_api_timeouts "$PROJECT_DIR/client/nginx-client.conf"
ensure_bus_location "$PROJECT_DIR/client/nginx-client.conf"

log "Сборка custom-образов backend/frontend"
cd "$PROJECT_DIR"
"${COMPOSE_CMD[@]}" -f docker-compose.yml -f docker-compose.custom.yml build backend frontend

log "Перезапуск контейнеров с custom-образами"
"${COMPOSE_CMD[@]}" -f docker-compose.yml -f docker-compose.custom.yml up -d --remove-orphans backend frontend

# Проверка: все ли контейнеры запустились
if ! check_containers_running 60; then
    error "Не удалось запустить контейнеры. Логи:"
    "${COMPOSE_CMD[@]}" -f docker-compose.yml -f docker-compose.custom.yml logs --tail=50
    die "Обновление прервано из-за ошибки запуска контейнеров"
fi

if "${COMPOSE_CMD[@]}" -f docker-compose.yml -f docker-compose.custom.yml exec -T backend sh -lc "command -v RealiTLScanner-linux-64 >/dev/null"; then
  log "Scanner binary найден в backend-контейнере"
else
  warn "Scanner binary не найден в backend-контейнере"
fi

log "Готово: VPS обновлен на ваш fork/branch"
