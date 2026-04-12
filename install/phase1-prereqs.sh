#!/usr/bin/env bash
# file: install/phase1-prereqs.sh v1.0
# Phase 1: Prerequisites + Git clone/pull
# Expects: REPO_URL, BRANCH, PROJECT_DIR, log/warn/die

#################################
# SYSTEM CHECKS
#################################
log "═══════════════════════════════════════════"
log "  Фаза 1: Проверка окружения"
log "═══════════════════════════════════════════"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Не найдена команда: $1"
}

need_cmd git
need_cmd sed

#################################
# DOCKER INSTALL
#################################
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  log "Docker $(docker --version) уже установлен ✓"
else
  log "Docker не найден — устанавливаем..."
  curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 || die "Не удалось установить Docker"
  # Убедимся что демон запущен
  systemctl is-active --quiet docker || systemctl start docker
  log "Docker установлен и запущен ✓"
fi

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

resolve_compose_cmd
log "Compose команда: ${COMPOSE_CMD[*]}"

#################################
# GIT CLONE / UPDATE
#################################
log "Подготовка проекта в $PROJECT_DIR"

if [[ ! -d "$PROJECT_DIR/.git" ]]; then
  if [[ -e "$PROJECT_DIR" ]]; then
    die "Путь $PROJECT_DIR существует, но это не git-репозиторий. Удалите вручную или укажите другой -p."
  fi

  log "Клонируем репозиторий ${REPO_URL} (${BRANCH})..."
  git clone --single-branch --branch "$BRANCH" "$REPO_URL" "$PROJECT_DIR" || die "Не удалось клонировать репозиторий"

  log "Репозиторий склонирован ✓"
else
  cd "$PROJECT_DIR"
  log "Репозиторий уже существует — обновляем..."

  git remote set-url origin "$REPO_URL" 2>/dev/null || true
  git fetch origin "$BRANCH" || die "Не удалось fetch ветку $BRANCH"

  if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git checkout "$BRANCH"
    git merge --ff-only FETCH_HEAD 2>/dev/null || {
      warn "Не удалось fast-forward merge."
      warn "Возможны локальные изменения в $PROJECT_DIR — продолжим с текущей версией."
    }
  else
    git checkout -b "$BRANCH" FETCH_HEAD
  fi

  log "Исходники обновлены ✓"
fi

cd "$PROJECT_DIR"

# Проверка ключевых файлов
[[ -f docker-compose.yml ]] || die "Не найден docker-compose.yml в $PROJECT_DIR"
[[ -f data/nginx.conf ]] || die "Не найден data/nginx.conf в $PROJECT_DIR"
[[ -f data/index.html ]] || die "Не найден data/index.html в $PROJECT_DIR"

log "Ключевые файлы на месте ✓"
