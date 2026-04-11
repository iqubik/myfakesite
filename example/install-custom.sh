#!/usr/bin/env bash
set -euo pipefail

trap 'echo -e "\033[1;31m[ERROR]\033[0m Ошибка в строке $LINENO"; exit 1' ERR

log()  { echo -e "\033[1;32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
die()  { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }

usage() {
  cat <<'EOF'
Использование:
  install-custom.sh [-r <repo_url>] [-b <branch>] [-p <project_dir>] [-s <source_dir>]

Параметры:
  -r  Git URL форка для custom-сборки (по умолчанию: https://github.com/iqubik/3dp-manager.git)
  -b  Ветка форка (по умолчанию: dp-custom)
  -p  Папка установленного проекта (по умолчанию: /opt/3dp-manager)
  -s  Папка исходников custom-сборки (по умолчанию: /opt/3dp-manager-src)
  -h  Показать эту справку

Пример:
  ./install-custom.sh -r https://github.com/iqubik/3dp-manager.git -b dp-custom
EOF
}

need_root() {
  [[ $EUID -eq 0 ]] || die "Запускать только от root"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Не найдена команда: $1"
}

REPO_URL="https://github.com/iqubik/3dp-manager.git"
BRANCH="dp-custom"
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

need_root
need_cmd curl
need_cmd bash

if [[ "$REPO_URL" =~ ^https://github\.com/([^/]+)/([^/]+?)(\.git)?$ ]]; then
  GH_OWNER="${BASH_REMATCH[1]}"
  GH_REPO="${BASH_REMATCH[2]}"
else
  die "Поддерживается только GitHub URL формата https://github.com/<owner>/<repo>.git"
fi

INSTALL_URL="https://raw.githubusercontent.com/${GH_OWNER}/${GH_REPO}/${BRANCH}/install.sh"
UPDATE_URL="https://raw.githubusercontent.com/${GH_OWNER}/${GH_REPO}/${BRANCH}/update-custom.sh"

tmp_install="$(mktemp)"
tmp_update="$(mktemp)"
cleanup() {
  rm -f "$tmp_install" "$tmp_update"
}
trap cleanup EXIT

if [[ ! -f "$PROJECT_DIR/docker-compose.yml" ]]; then
  log "3dp-manager не найден в $PROJECT_DIR. Запускаем базовую установку..."
  curl -fsSL -o "$tmp_install" "$INSTALL_URL"
  bash "$tmp_install"
else
  log "Обнаружена существующая установка в $PROJECT_DIR. Базовую установку пропускаем."
fi

log "Применяем custom-сборку из ${REPO_URL} (${BRANCH})..."
curl -fsSL -o "$tmp_update" "$UPDATE_URL"
bash "$tmp_update" -r "$REPO_URL" -b "$BRANCH" -p "$PROJECT_DIR" -s "$SOURCE_DIR"

log "Готово: установлена/обновлена custom-конфигурация"
