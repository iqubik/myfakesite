#!/usr/bin/env bash
# file: install/phase5-start.sh v2.0
# Phase 5: Start containers, verify, summary
# Expects: MODE, DOMAIN, COMPOSE_CMD, NON_INTERACTIVE, log/warn/die

log "═══════════════════════════════════════════"
log "  Фаза 5: Запуск и проверка"
log "═══════════════════════════════════════════"

#################################
# START
#################################
echo ""
log "Запускаем контейнеры..."

# Останавливаем старые, если были
"${COMPOSE_CMD[@]}" down --remove-orphans 2>/dev/null || true

"${COMPOSE_CMD[@]}" up -d --remove-orphans

#################################
# VERIFY — polling check
#################################
log "Ожидаем запуск контейнеров (до 60 сек)..."

if ! check_containers_running 60; then
  warn "Не все контейнеры запустились. Логи:"
  "${COMPOSE_CMD[@]}" logs --tail=50
  die "Установка прервана из-за ошибки запуска контейнеров"
fi

#################################
# HTTP VERIFY
#################################
echo ""
log "Проверяем доступность сайта..."

sleep 2

if [[ "$MODE" == "http" ]]; then
  code=$(curl -fsS -o /dev/null -w "%{http_code}" http://localhost/ 2>/dev/null || echo "000")
  if [[ "$code" =~ ^(200|301|302)$ ]]; then
    log "Сайт доступен: http://localhost (код $code) ✓"
  else
    warn "Сайт не отвечает (код $code)"
    warn "Посмотрите логи: ${COMPOSE_CMD[*]} logs"
  fi
else
  code=$(curl -fsSk -o /dev/null -w "%{http_code}" https://localhost/ 2>/dev/null || echo "000")
  if [[ "$code" =~ ^(200|301|302)$ ]]; then
    log "Сайт доступен: https://${DOMAIN} (код $code) ✓"
  else
    warn "Сайт не отвечает (код $code)"
    warn "Посмотрите логи: ${COMPOSE_CMD[*]} logs"
  fi
fi

#################################
# SUMMARY
#################################
echo ""
echo "==================================================="
echo "  ✔ MySphere fakesite установлен и запущен!"
echo "==================================================="
echo ""

if [[ "$MODE" == "http" ]]; then
  log "  Режим:       HTTP"
  log "  URL:         http://localhost"
  log "  Порт:        80"
  echo ""
  log "  Для HTTPS с доменом:"
  log "    sudo ./update-custom.sh -d <domain>"
else
  log "  Режим:       HTTPS"
  log "  URL:         https://${DOMAIN}"
  log "  Порт:        443"

  if [[ "${SSL_MODE:-}" == "selfsigned" ]]; then
    echo ""
    warn "  ⚠ Self-signed сертификат"
    warn "  Браузер покажет предупреждение — это нормально"
    warn "  Для настоящего: certbot certonly --standalone -d ${DOMAIN}"
  fi
fi

echo ""
log "Управление:"
log "  Обновить:  sudo ./update-custom.sh"
log "  Удалить:   sudo ./delete.sh"
log "  Логи:      sudo ${COMPOSE_CMD[*]} logs -f"
echo ""
