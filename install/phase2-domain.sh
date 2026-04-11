#!/usr/bin/env bash
# file: install/phase2-domain.sh v1.0
# Phase 2: Domain/IP detection, port checks, UFW
# Sets: MODE, DOMAIN
# Expects: DOMAIN, PROJECT_DIR, log/warn/die

log "═══════════════════════════════════════════"
log "  Фаза 2: Домен, порты, фаервол"
log "═══════════════════════════════════════════"

is_ip_address() {
  [[ "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]
}

#################################
# DOMAIN / IP DETECTION
#################################
if [[ -z "$DOMAIN" ]]; then
  echo ""
  echo "  Как будет доступен сайт?"
  echo "    • Оставьте пустым  → HTTP, http://localhost (для тестирования)"
  echo "    • IP-адрес         → HTTPS, self-signed сертификат"
  echo "    • Домен            → HTTPS, Let's Encrypt или self-signed"
  echo ""
  read -r -p "Введите домен или IP-адрес [localhost]: " DOMAIN
fi

# Определяем режим
if [[ -z "$DOMAIN" || "$DOMAIN" == "localhost" ]]; then
  MODE="http"
  DOMAIN="localhost"
  log "Режим: HTTP, порт 80 (localhost)"
elif is_ip_address "$DOMAIN"; then
  MODE="https-selfsigned"
  log "Режим: HTTPS, self-signed сертификат для IP $DOMAIN"
else
  MODE="https-domain"
  log "Режим: HTTPS для домена $DOMAIN"
fi

export MODE

#################################
# PORT CHECK
#################################
check_port() {
  local port=$1
  local info
  info=$(ss -tlnp "sport = :${port}" 2>/dev/null | grep -v "^State" || true)

  if [[ -n "$info" ]]; then
    local pid proc_name
    pid=$(echo "$info" | grep -oP 'pid=\K[0-9]+' | head -1 || true)
    if [[ -n "$pid" ]]; then
      proc_name=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
    else
      proc_name="unknown"
      pid="N/A"
    fi
    echo "${pid}:${proc_name}"
    return 1
  fi
  return 0
}

echo ""
log "Проверка портов..."

# --- Порт 80 ---
p80=$(check_port 80) || true
if [[ -n "$p80" ]]; then
  IFS=':' read -r p80_pid p80_name <<< "$p80"
  warn "Порт 80 занят: ${p80_name} (PID ${p80_pid})"
  echo ""
  echo "  MySphere требует порт 80."
  echo "  1) Остановить ${p80_name} и продолжить"
  echo "  2) Продолжить так (контейнеры могут не запуститься)"
  echo ""
  read -r -p "Выбор [1]: " ch
  if [[ "$ch" == "2" ]]; then
    warn "Продолжаем с занятым портом 80."
  else
    log "Останавливаем ${p80_name} (PID ${p80_pid})..."
    kill "$p80_pid" 2>/dev/null || {
      warn "Не удалось остановить. Попробуйте вручную: sudo kill -9 ${p80_pid}"
      die "Установка прервана."
    }
    sleep 1
    if ss -tlnp "sport = :80" 2>/dev/null | grep -qv "^State"; then
      warn "Порт 80 всё ещё занят. Остановите процесс и повторите установку."
      die "Установка прервана."
    fi
    log "Порт 80 свободен ✓"
  fi
else
  log "Порт 80 свободен ✓"
fi

# --- Порт 443 (только HTTPS) ---
if [[ "$MODE" != "http" ]]; then
  p443=$(check_port 443) || true
  if [[ -n "$p443" ]]; then
    IFS=':' read -r p443_pid p443_name <<< "$p443"
    warn "Порт 443 занят: ${p443_name} (PID ${p443_pid})"
    echo ""
    echo "  MySphere требует порт 443 для HTTPS."
    echo "  1) Остановить ${p443_name} и продолжить"
    echo "  2) Переключиться на HTTP-режим (без SSL)"
    echo "  3) Продолжить так (контейнеры могут не запуститься)"
    echo ""
    read -r -p "Выбор [1]: " ch
    case "$ch" in
      2)
        log "Переключаемся на HTTP-режим..."
        MODE="http"
        DOMAIN="localhost"
        export MODE
        ;;
      3)
        warn "Продолжаем с занятым портом 443."
        ;;
      *)
        log "Останавливаем ${p443_name} (PID ${p443_pid})..."
        kill "$p443_pid" 2>/dev/null || {
          warn "Не удалось остановить. Попробуйте: sudo kill -9 ${p443_pid}"
          die "Установка прервана."
        }
        sleep 1
        if ss -tlnp "sport = :443" 2>/dev/null | grep -qv "^State"; then
          warn "Порт 443 всё ещё занят."
          die "Установка прервана."
        fi
        log "Порт 443 свободен ✓"
        ;;
    esac
  else
    log "Порт 443 свободен ✓"
  fi
fi

#################################
# UFW
#################################
configure_ufw() {
  if ! command -v ufw >/dev/null 2>&1; then
    log "UFW не установлен — пропуск"
    return 0
  fi

  local status
  status=$(ufw status 2>/dev/null | head -1)

  if echo "$status" | grep -qi "inactive"; then
    log "UFW установлен, но не активен — пропуск"
    return 0
  fi

  log "UFW активен — настраиваем порты..."

  local rules
  rules=$(ufw status 2>/dev/null)

  if ! echo "$rules" | grep -qE "80(/tcp)?\s+ALLOW"; then
    log "Открываем порт 80 в UFW..."
    ufw allow 80/tcp
  else
    log "Порт 80 уже открыт"
  fi

  if [[ "$MODE" != "http" ]]; then
    if ! echo "$rules" | grep -qE "443(/tcp)?\s+ALLOW"; then
      log "Открываем порт 443 в UFW..."
      ufw allow 443/tcp
    else
      log "Порт 443 уже открыт"
    fi
  fi
}

configure_ufw
