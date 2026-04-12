#!/usr/bin/env bash
# file: install/certbot-renew-hook.sh v1.0
# Deploy-hook для certbot: перезапускает контейнер после обновления сертификата
# Вызывается ТОЛЬКО при успешном renew одного из сертификатов
# Контекст: DOMAIN уже в renewal config, certs обновлены

set -euo pipefail

COMPOSE_FILE="/opt/myfakesite/docker-compose.yml"

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "[certbot-renew-hook] docker-compose.yml не найден, пропуск" >&2
  exit 0
fi

echo "[certbot-renew-hook] Перезапуск контейнера fakesite..." >&2
cd /opt/myfakesite

if docker compose version >/dev/null 2>&1; then
  docker compose restart fakesite
else
  docker-compose restart fakesite
fi

echo "[certbot-renew-hook] Контейнер перезапущен ✓" >&2
