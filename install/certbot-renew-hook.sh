#!/usr/bin/env bash
# file: install/certbot-renew-hook.sh v1.1
# Deploy-hook для certbot: перезапускает контейнер после обновления сертификата
# Вызывается ТОЛЬКО при успешном renew одного из сертификатов
# Контекст: DOMAIN уже в renewal config, certs обновлены

set -euo pipefail

# Определяем путь к проекту
PROJECT_DIR=""
if [[ -f "/etc/myfakesite/project_path" ]]; then
  PROJECT_DIR=$(cat /etc/myfakesite/project_path)
elif [[ -n "${PROJECT_DIR:-}" ]]; then
  : # уже задан из cron env
elif [[ -f "/opt/myfakesite/docker-compose.yml" ]]; then
  PROJECT_DIR="/opt/myfakesite"
fi

if [[ -z "$PROJECT_DIR" || ! -f "$PROJECT_DIR/docker-compose.yml" ]]; then
  echo "[certbot-renew-hook] docker-compose.yml не найден, пропуск" >&2
  exit 0
fi

echo "[certbot-renew-hook] Перезапуск контейнера fakesite ($PROJECT_DIR)..." >&2
cd "$PROJECT_DIR"

if docker compose version >/dev/null 2>&1; then
  docker compose restart fakesite
else
  docker-compose restart fakesite
fi

echo "[certbot-renew-hook] Контейнер перезапущен ✓" >&2
