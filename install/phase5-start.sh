#!/usr/bin/env bash
# Phase 5: Start containers, verify, summary
# Expects: MODE, DOMAIN, COMPOSE_CMD, log/warn/die

log "═══════════════════════════════════════════"
log "  Фаза 5: Запуск и проверка"
log "═══════════════════════════════════════════"

#################################
# START
#################################
echo ""
log "Запускаем контейнеры..."
"${COMPOSE_CMD[@]}" up -d --remove-orphans

log "Ожидаем запуск..."
sleep 3

#################################
# STATUS
#################################
echo ""
"${COMPOSE_CMD[@]}" ps

#################################
# VERIFY
#################################
echo ""
log "Проверяем доступность..."

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
log "═══════════════════════════════════════════════════"
log "  MySphere fakesite установлен и запущен!"
log "═══════════════════════════════════════════════════"
echo ""

if [[ "$MODE" == "http" ]]; then
  log "  Режим:       HTTP"
  log "  URL:         http://localhost"
  log "  Порт:        80"
  echo ""
  log "  Для HTTPS:"
  log "    update-custom.sh -r <repo> -b <branch> -d <domain>"
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
log "  Обновить:  sudo ./update-custom.sh -r <repo> -b <branch>"
log "  Удалить:   sudo ./delete.sh"
log "  Логи:      sudo ${COMPOSE_CMD[*]} logs -f"
echo ""
