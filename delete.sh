#!/usr/bin/env bash
# file: delete.sh v1.0
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
  delete.sh [-p <project_dir>] [-f]

Параметры:
  -p  Папка установленного проекта (по умолчанию: /opt/myfakesite)
  -f  Без подтверждения (force mode)
  -h  Показать эту справку

Примеры:
  ./delete.sh
  ./delete.sh -p /opt/myfakesite
  ./delete.sh -f
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

PROJECT_DIR="/opt/myfakesite"
FORCE=0

while getopts ":p:fh" opt; do
  case "$opt" in
    p) PROJECT_DIR="$OPTARG" ;;
    f) FORCE=1 ;;
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

if [[ $FORCE -eq 0 ]]; then
  read -r -p "Вы уверены, что хотите удалить MySphere fakesite из $PROJECT_DIR? (y/n): " answer
  case "$answer" in
    y|Y)
      log "Начинаю удаление..."
      ;;
    *)
      log "Удаление отменено"
      exit 1
      ;;
  esac
else
  log "Force mode — удаление без подтверждения"
fi

#################################
# START
#################################
need_root
resolve_compose_cmd
log "Compose команда: ${COMPOSE_CMD[*]}"

log "Начинаем удаление MySphere fakesite"

if [[ ! -d "$PROJECT_DIR" ]]; then
  warn "Директория $PROJECT_DIR не найдена — удалять нечего"
  exit 0
fi

cd "$PROJECT_DIR"

#################################
# DOCKER COMPOSE DOWN
#################################
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  if [[ -f docker-compose.yml ]]; then
    log "Останавливаем контейнеры MySphere fakesite"
    docker compose down --volumes --remove-orphans || warn "Ошибка при docker compose down"
  else
    warn "docker-compose.yml не найден"
  fi
else
  warn "Docker или docker compose не установлен — пропуск"
fi

#################################
# CLEAN IMAGES
#################################
log "Удаляем образы проекта (если есть)"

# Безопасная очистка через --filter вместо grep | xargs
docker images --filter "reference=myfakesite*" --filter "reference=fakesite*" --format '{{.ID}}' \
  | xargs -r docker rmi -f 2>/dev/null || true

# Чистим dangling (битые) образы
docker image prune -f 2>/dev/null || true

#################################
# CLEAN /etc/myfakesite + наш cron
#################################
if [[ -d /etc/myfakesite ]]; then
  log "Удаляем метаданные /etc/myfakesite"
  rm -rf /etc/myfakesite
fi
if [[ -f /etc/cron.d/certbot-fakesite ]]; then
  log "Удаляем cron job certbot"
  rm -f /etc/cron.d/certbot-fakesite
fi

#################################
# REMOVE DIRECTORY
#################################
# Sanity check перед rm -rf
if [[ -z "$PROJECT_DIR" || "$PROJECT_DIR" == "/" ]]; then
  die "Подозрительный путь PROJECT_DIR=$PROJECT_DIR — удаление отменено"
fi

log "Удаляем $PROJECT_DIR"
rm -rf "$PROJECT_DIR"

#################################
# DONE
#################################
log "✔ MySphere fakesite полностью удалён"
