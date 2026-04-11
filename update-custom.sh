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
  update-custom.sh [-r <repo_url>] [-b <branch>] [-p <project_dir>]

Параметры:
  -r  Git URL репозитория (обязательно), например:
      https://github.com/<user>/myfakesite.git
  -b  Ветка с вашими правками (обязательно), например:
      my-custom-branch
  -p  Папка установленного проекта (по умолчанию /opt/myfakesite)
  -h  Показать эту справку

Примеры:
  ./update-custom.sh -r https://github.com/me/myfakesite.git -b mybranch
  ./update-custom.sh -r https://github.com/iqubik/myfakesite.git -b main
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
    while IFS=$'\t' read -r container_name status; do
      if [ -n "$container_name" ] && [ -n "$status" ]; then
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

REPO_URL=""
BRANCH=""
PROJECT_DIR="/opt/myfakesite"

while getopts ":r:b:p:h" opt; do
  case "$opt" in
    r) REPO_URL="$OPTARG" ;;
    b) BRANCH="$OPTARG" ;;
    p) PROJECT_DIR="$OPTARG" ;;
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
command -v git >/dev/null 2>&1 || die "git не установлен"
command -v docker >/dev/null 2>&1 || die "docker не установлен"
resolve_compose_cmd
log "Compose команда: ${COMPOSE_CMD[*]}"

[[ -d "$PROJECT_DIR" ]] || die "Папка проекта не найдена: $PROJECT_DIR"
[[ -f "$PROJECT_DIR/docker-compose.yml" ]] || die "Не найден docker-compose.yml в $PROJECT_DIR"

cd "$PROJECT_DIR"

#################################
# UPDATE SOURCE
#################################
log "Обновление исходников из ${REPO_URL} (${BRANCH})..."

if [[ ! -d "$PROJECT_DIR/.git" ]]; then
  die "$PROJECT_DIR не является git-репозиторием. Используйте install.sh для первоначальной установки."
fi

git remote set-url origin "$REPO_URL" 2>/dev/null || true
git fetch origin "$BRANCH"

if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git checkout "$BRANCH"
  # Merge from FETCH_HEAD to support repos cloned with --single-branch
  # where origin/<branch> may not exist.
  git merge --ff-only FETCH_HEAD || die "Не удалось fast-forward merge. Проверьте локальные изменения в $PROJECT_DIR."
else
  git checkout -b "$BRANCH" FETCH_HEAD
fi

log "Исходники обновлены до ${BRANCH}"

#################################
# RESTART CONTAINERS
#################################
log "Перезапуск контейнеров..."
"${COMPOSE_CMD[@]}" up -d --remove-orphans --force-recreate

# Проверка: все ли контейнеры запустились
if ! check_containers_running 60; then
  warn "Не удалось запустить контейнеры. Логи:"
  "${COMPOSE_CMD[@]}" logs --tail=50
  die "Обновление прервано из-за ошибки запуска контейнеров"
fi

#################################
# VERIFY
#################################
log "Проверяем доступность сайта..."

# Определяем режим: ищем SSL-сертификаты в docker-compose.yml или nginx.conf
HTTPS_MODE=0
if grep -q "listen 443 ssl" nginx.conf 2>/dev/null && ! grep -q "# - \"443:443\"" docker-compose.yml 2>/dev/null; then
  HTTPS_MODE=1
fi

if [[ $HTTPS_MODE -eq 1 ]]; then
  if curl -fsSk -o /dev/null -w "%{http_code}" https://localhost/ 2>/dev/null | grep -qE "200|301|302"; then
    log "Сайт доступен (HTTPS) ✓"
  else
    warn "Сайт не отвечает на https://localhost/ (возможно другой домен или ошибка nginx)"
  fi
else
  if curl -fsS -o /dev/null -w "%{http_code}" http://localhost/ 2>/dev/null | grep -qE "200|301|302"; then
    log "Сайт доступен (HTTP) ✓"
  else
    warn "Сайт не отвечает на http://localhost/ (возможно ошибка nginx)"
  fi
fi

log "Готово: MySphere fakesite обновлён до ${REPO_URL} (${BRANCH})"
