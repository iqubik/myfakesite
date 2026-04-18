#!/usr/bin/env bash
# file: delete.sh v1.1.6
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
  COMPOSE_AVAILABLE=0
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=("docker" "compose")
    COMPOSE_AVAILABLE=1
    return 0
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=("docker-compose")
    COMPOSE_AVAILABLE=1
    return 0
  fi
  warn "Docker Compose не найден — шаги compose down будут пропущены"
  return 1
}

cleanup_system_artifacts() {
  log "Очищаем системные артефакты MySphere..."

  rm -f /etc/cron.d/myfakesite-log-rotate 2>/dev/null || true

  rm -rf /var/log/myfakesite 2>/dev/null || true
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
resolve_compose_cmd || true
echo ""
echo "[INFO] Версия скрипта: 1.1.6"
echo ""
if [[ "${COMPOSE_AVAILABLE:-0}" -eq 1 ]]; then
  log "Compose команда: ${COMPOSE_CMD[*]}"
else
  warn "Compose команда недоступна"
fi

log "Начинаем удаление MySphere fakesite"

if [[ ! -d "$PROJECT_DIR" ]]; then
  warn "Директория $PROJECT_DIR не найдена — удалять нечего"

  # VERIFY: убеждаемся что и контейнеров/образов проекта нет
  remaining_containers=$(docker ps -a --filter 'name=fakesite' --format '{{.Names}}' 2>/dev/null || true)
  remaining_images=$(docker images --filter "reference=fakesite*" --format '{{.Repository}}' 2>/dev/null || true)
  remaining_volumes=$(docker volume ls --filter 'name=fakesite' --filter 'name=myfakesite' -q 2>/dev/null || true)
  remaining_networks=$(docker network ls --filter 'name=fakesite' --filter 'name=myfakesite' --format '{{.Name}}' 2>/dev/null || true)

  if [[ -z "$remaining_containers" && -z "$remaining_images" && -z "$remaining_volumes" && -z "$remaining_networks" ]]; then
    log "Контейнеры проекта отсутствуют ✓"
    log "Образы проекта отсутствуют ✓"
    log "Тома проекта отсутствуют ✓"
    log "Сети проекта отсутствуют ✓"
  else
    [[ -n "$remaining_containers" ]] && warn "Остались контейнеры: $remaining_containers"
    [[ -n "$remaining_images" ]] && warn "Остались образы: $remaining_images"

    # Чистим оставшиеся volumes
    if [[ -n "$remaining_volumes" ]]; then
      echo "$remaining_volumes" | xargs -r docker volume rm -f 2>/dev/null || true
      log "Оставшиеся тома удалены ✓"
    fi

    # Чистим оставшиеся сети
    if [[ -n "$remaining_networks" ]]; then
      echo "$remaining_networks" | while read -r net; do
        docker network rm "$net" 2>/dev/null || warn "Не удалось удалить сеть: $net"
      done
      log "Оставшиеся сети удалены ✓"
    fi
  fi

  # Чистим временные файлы install
  rm -rf /tmp/myfakesite-install 2>/dev/null || true
  cleanup_system_artifacts

  log "✔ MySphere fakesite уже удалён"
  exit 0
fi

cd "$PROJECT_DIR"

#################################
# DOCKER COMPOSE DOWN
#################################
if [[ "${COMPOSE_AVAILABLE:-0}" -eq 1 ]]; then
  if [[ -f docker-compose.yml ]]; then
    log "Останавливаем контейнеры MySphere fakesite"
    "${COMPOSE_CMD[@]}" down --volumes --remove-orphans || warn "Ошибка при docker compose down"

    # VERIFY: контейнеры остановлены
    remaining=$(docker ps -a --filter 'name=fakesite' --format '{{.Names}}' 2>/dev/null || true)
    if [[ -n "$remaining" ]]; then
      warn "Остались контейнеры: $remaining"
    else
      log "Контейнеры удалены ✓"
    fi
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

# VERIFY: образы удалены
remaining_imgs=$(docker images --filter "reference=fakesite*" --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true)
if [[ -n "$remaining_imgs" ]]; then
  warn "Остались образы: $remaining_imgs"
else
  log "Образы проекта удалены ✓"
fi

#################################
# CLEAN VOLUMES AND NETWORKS
#################################
log "Очищаем тома и сети проекта..."

# Удаляем volumes проекта
remaining_volumes=$(docker volume ls --filter 'name=fakesite' --filter 'name=myfakesite' -q 2>/dev/null || true)
if [[ -n "$remaining_volumes" ]]; then
  echo "$remaining_volumes" | xargs -r docker volume rm -f 2>/dev/null || warn "Не удалось удалить часть томов"
fi

# Удаляем сети проекта (docker compose down обычно делает это, но на случай если остались)
remaining_networks=$(docker network ls --filter 'name=fakesite' --filter 'name=myfakesite' --format '{{.Name}}' 2>/dev/null || true)
if [[ -n "$remaining_networks" ]]; then
  echo "$remaining_networks" | while read -r net; do
    docker network rm "$net" 2>/dev/null || warn "Не удалось удалить сеть: $net"
  done
fi

# VERIFY: тома и сети очищены
final_volumes=$(docker volume ls --filter 'name=fakesite' --filter 'name=myfakesite' -q 2>/dev/null || true)
if [[ -z "$final_volumes" ]]; then
  log "Тома проекта удалены ✓"
else
  warn "Остались тома: $final_volumes"
fi

final_networks=$(docker network ls --filter 'name=fakesite' --filter 'name=myfakesite' --format '{{.Name}}' 2>/dev/null || true)
if [[ -z "$final_networks" ]]; then
  log "Сети проекта удалены ✓"
else
  warn "Остались сети: $final_networks"
fi

#################################
# CLEAN TMP INSTALL FILES
#################################
log "Очищаем временные файлы установки..."
rm -rf /tmp/myfakesite-install 2>/dev/null || true
log "Временные файлы удалены ✓"

#################################
# CLEAN SYSTEM ARTIFACTS
#################################
cleanup_system_artifacts
log "Системные артефакты очищены ✓"

#################################
# REMOVE DIRECTORY
#################################
# Sanity check перед rm -rf
if [[ -z "$PROJECT_DIR" || "$PROJECT_DIR" == "/" ]]; then
  die "Подозрительный путь PROJECT_DIR=$PROJECT_DIR — удаление отменено"
fi

log "Удаляем $PROJECT_DIR"
rm -rf "$PROJECT_DIR"

# VERIFY: директория удалена
if [[ -d "$PROJECT_DIR" ]]; then
  warn "Директория $PROJECT_DIR всё ещё существует!"
else
  log "Директория удалена ✓"
fi

#################################
# DONE
#################################
log "✔ MySphere fakesite полностью удалён"
