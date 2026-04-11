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
[[ -f nginx.conf ]] || die "Не найден nginx.conf в $PROJECT_DIR"
[[ -f index.html ]] || die "Не найден index.html в $PROJECT_DIR"

log "Ключевые файлы на месте ✓"
