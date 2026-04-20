#!/usr/bin/env bash
# file: install/phase5-start.sh v1.1
# Phase 5: Start containers, verify, summary
# Expects: MODE, DOMAIN, SSL_PORT, COMPOSE_CMD, NON_INTERACTIVE, log/warn/die

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
  code=$(curl -fsSk -o /dev/null -w "%{http_code}" "https://localhost:${SSL_PORT:-443}/" 2>/dev/null || echo "000")
  if [[ "$code" =~ ^(200|301|302)$ ]]; then
    log "Сайт доступен: https://${DOMAIN}:${SSL_PORT:-443} (код $code) ✓"
  else
    warn "Сайт не отвечает (код $code)"
    warn "Посмотрите логи: ${COMPOSE_CMD[*]} logs"
  fi
fi

#################################
# CERTBOT RENEWAL SETUP
#################################
if [[ "${SSL_MODE:-}" == "letsencrypt" ]]; then
  log "Настраиваем авто-обновление сертификатов..."

  # Сохраняем путь к проекту для deploy-hook
  mkdir -p /etc/myfakesite
  echo "$PROJECT_DIR" > /etc/myfakesite/project_path

  HOOK_SCRIPT="${PROJECT_DIR}/install/certbot-renew-hook.sh"

  if command -v certbot >/dev/null 2>&1; then
    certbot update_symlinks 2>/dev/null || true

    # webroot renew — контейнер НЕ останавливается
    # certbot пишет challenge в /var/www/acme-challenge
    # nginx в контейнере монтирует этот путь и отдаёт challenge
    # deploy-hook вызывается ТОЛЬКО при реальном обновлении cert
    cat > /etc/cron.d/certbot-fakesite <<CRON
# MySphere fakesite — certbot auto-renewal (webroot, zero-downtime)
# certbot renew проверяет сертификаты ежедневно, обновляет если <30 дней до истечения
0 3 * * * root certbot renew --quiet --deploy-hook "${HOOK_SCRIPT}" > /var/log/certbot-fakesite.log 2>&1
CRON
    chmod 644 /etc/cron.d/certbot-fakesite

    log "cron job создан: ежедневная проверка в 3:00 (webroot, без даунтайма) ✓"
  else
    warn "certbot не найден — авто-обновление сертификатов не настроено"
  fi
fi

#################################
# ACCESS LOG ROTATION (CRON, no logrotate)
#################################
mkdir -p /var/log/myfakesite
touch /var/log/myfakesite/access.log

LOG_ROTATE_SCRIPT="${PROJECT_DIR}/data/log-rotate-by-size.sh"
if [[ -f "$LOG_ROTATE_SCRIPT" ]]; then
  chmod 755 "$LOG_ROTATE_SCRIPT" 2>/dev/null || true
  cat > /etc/cron.d/myfakesite-log-rotate <<CRON
# MySphere fakesite — access log rotation by size (1 MiB), without logrotate
*/5 * * * * root ${LOG_ROTATE_SCRIPT} >/dev/null 2>&1
CRON
  chmod 644 /etc/cron.d/myfakesite-log-rotate
  log "cron job создан: /etc/cron.d/myfakesite-log-rotate (каждые 5 минут) ✓"
else
  warn "Скрипт ротации логов не найден: $LOG_ROTATE_SCRIPT"
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
  log "    sudo ./install.sh -d <domain>"
else
  log "  Режим:       HTTPS"
  log "  URL:         https://${DOMAIN}:${SSL_PORT:-443}"
  log "  Порт:        ${SSL_PORT:-443}"

  if [[ "${SSL_MODE:-}" == "selfsigned" ]]; then
    echo ""
    warn "  ⚠ Self-signed сертификат"
    warn "  Браузер покажет предупреждение — это нормально"
    warn "  Для настоящего: certbot certonly --standalone -d ${DOMAIN}"
  fi
fi

echo ""
log "Управление:"
log "  Обновить:  sudo ./update.sh"
log "  Удалить:   sudo ./delete.sh"
log "  Логи:      sudo ${COMPOSE_CMD[*]} logs -f"
echo ""
