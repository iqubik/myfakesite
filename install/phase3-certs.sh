#!/usr/bin/env bash
# file: install/phase3-certs.sh v2.0
# Phase 3: SSL certificates
# Sets: SSL_CERT_PATH, SSL_KEY_PATH, SSL_MODE
# Expects: MODE, DOMAIN, CUSTOM_CERT, CUSTOM_KEY, NON_INTERACTIVE, log/warn/die

log "═══════════════════════════════════════════"
log "  Фаза 3: SSL-сертификаты"
log "═══════════════════════════════════════════"

SSL_CERT_PATH=""
SSL_KEY_PATH=""
SSL_MODE="none"

export SSL_CERT_PATH SSL_KEY_PATH SSL_MODE

#################################
# HTTP — без сертификатов
#################################
if [[ "$MODE" == "http" ]]; then
  log "HTTP-режим: SSL не требуется"
  SSL_MODE="none"
  export SSL_MODE
  exit 0
fi

#################################
# Пользовательские сертификаты (-c / -k)
#################################
if [[ -n "$CUSTOM_CERT" && -n "$CUSTOM_KEY" ]]; then
  if [[ ! -f "$CUSTOM_CERT" ]]; then
    die "Сертификат не найден: $CUSTOM_CERT"
  fi
  if [[ ! -f "$CUSTOM_KEY" ]]; then
    die "Ключ не найден: $CUSTOM_KEY"
  fi

  # Проверяем, что это действительно cert/key
  if ! openssl x509 -in "$CUSTOM_CERT" -noout 2>/dev/null; then
    warn "Файл не похож на PEM-сертификат: $CUSTOM_CERT"
    warn "Но продолжаем — возможно, это другой формат."
  fi

  # Копируем в стандартное место, чтобы docker мог смонтировать
  # (Docker не всегда может монтировать файлы с произвольных путей)
  SSL_DIR="/etc/letsencrypt/live/${DOMAIN}"
  mkdir -p "$SSL_DIR"

  SSL_CERT_PATH="${SSL_DIR}/fullchain.pem"
  SSL_KEY_PATH="${SSL_DIR}/privkey.pem"

  cp "$CUSTOM_CERT" "$SSL_CERT_PATH"
  cp "$CUSTOM_KEY" "$SSL_KEY_PATH"
  chmod 644 "$SSL_CERT_PATH"
  chmod 600 "$SSL_KEY_PATH"

  SSL_MODE="custom"
  log "Пользовательские сертификаты скопированы в: $SSL_DIR"

  # Проверка срока действия
  expiry=$(openssl x509 -in "$SSL_CERT_PATH" -noout -enddate 2>/dev/null | cut -d= -f2 || echo "unknown")
  log "Сертификат действителен до: $expiry"

  export SSL_CERT_PATH SSL_KEY_PATH SSL_MODE
  exit 0
fi

#################################
# Self-signed для IP-адреса
#################################
if [[ "$MODE" == "https-selfsigned" ]]; then
  SSL_DIR="/etc/letsencrypt/live/${DOMAIN}"
  SSL_CERT_PATH="${SSL_DIR}/fullchain.pem"
  SSL_KEY_PATH="${SSL_DIR}/privkey.pem"

  if [[ -f "$SSL_CERT_PATH" && -f "$SSL_KEY_PATH" ]]; then
    log "Self-signed сертификат уже существует"
  else
    log "Генерируем self-signed сертификат для $DOMAIN..."
    mkdir -p "$SSL_DIR"
    openssl req -x509 -nodes -days 365 \
      -newkey rsa:2048 \
      -keyout "$SSL_KEY_PATH" \
      -out "$SSL_CERT_PATH" \
      -subj "/CN=${DOMAIN}" \
      -addext "subjectAltName=IP:${DOMAIN}" 2>/dev/null

    log "Сертификат создан: $SSL_CERT_PATH"
    warn "Браузер покажет предупреждение — это нормально для IP-адресов"
  fi

  SSL_MODE="selfsigned"
  export SSL_CERT_PATH SSL_KEY_PATH SSL_MODE
  exit 0
fi

#################################
# Домен: Let's Encrypt или self-signed
#################################
# MODE == "https-domain"
LE_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
LE_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"

if [[ -f "$LE_CERT" && -f "$LE_KEY" ]]; then
  issuer=$(openssl x509 -in "$LE_CERT" -noout -issuer 2>/dev/null || true)
  if echo "$issuer" | grep -q "Let's Encrypt"; then
    log "Найден Let's Encrypt сертификат для $DOMAIN ✓"
    SSL_CERT_PATH="$LE_CERT"
    SSL_KEY_PATH="$LE_KEY"
    SSL_MODE="letsencrypt"
    export SSL_CERT_PATH SSL_KEY_PATH SSL_MODE

    expiry=$(openssl x509 -in "$SSL_CERT_PATH" -noout -enddate 2>/dev/null | cut -d= -f2 || echo "unknown")
    log "Действителен до: $expiry"
    exit 0
  fi
fi

# Нет LE — решаем
if [[ "$NON_INTERACTIVE" == "true" ]]; then
  # Автоматический режим: пробуем certbot, иначе self-signed
  if command -v certbot >/dev/null 2>&1; then
    log "Пробуем получить Let's Encrypt сертификат..."
    if certbot certonly --standalone -d "$DOMAIN" \
        --non-interactive --agree-tos --register-unsafely-without-email 2>&1; then
      if [[ -f "$LE_CERT" && -f "$LE_KEY" ]]; then
        SSL_CERT_PATH="$LE_CERT"
        SSL_KEY_PATH="$LE_KEY"
        SSL_MODE="letsencrypt"
        log "Let's Encrypt сертификат получен ✓"

        expiry=$(openssl x509 -in "$SSL_CERT_PATH" -noout -enddate 2>/dev/null | cut -d= -f2 || echo "unknown")
        log "Действителен до: $expiry"
        export SSL_CERT_PATH SSL_KEY_PATH SSL_MODE
        exit 0
      fi
    fi
    warn "certbot не смог получить сертификат. Переключаемся на self-signed..."
  else
    log "certbot не установлен — генерируем self-signed..."
  fi
else
  # Интерактивный режим — спрашиваем
  echo ""
  echo "  Сертификат для $DOMAIN не найден."
  echo ""
  echo "  Варианты:"
  echo "    1) Получить Let's Encrypt через certbot (настоящий сертификат)"
  echo "       Рекомендуется для продакшена"
  echo ""
  echo "    2) Сгенерировать self-signed (для тестирования)"
  echo "       Браузер покажет предупреждение"
  echo ""
  read -r -p "Выбор [2]: " cert_choice

  if [[ "$cert_choice" == "1" ]]; then
    if command -v certbot >/dev/null 2>&1; then
      log "Запускаем certbot..."
      if certbot certonly --standalone -d "$DOMAIN" \
          --non-interactive --agree-tos --register-unsafely-without-email 2>&1; then
        if [[ -f "$LE_CERT" && -f "$LE_KEY" ]]; then
          SSL_CERT_PATH="$LE_CERT"
          SSL_KEY_PATH="$LE_KEY"
          SSL_MODE="letsencrypt"
          log "Let's Encrypt сертификат получен ✓"

          expiry=$(openssl x509 -in "$SSL_CERT_PATH" -noout -enddate 2>/dev/null | cut -d= -f2 || echo "unknown")
          log "Действителен до: $expiry"
          export SSL_CERT_PATH SSL_KEY_PATH SSL_MODE
          exit 0
        fi
      fi
      warn "certbot не смог получить сертификат."
    else
      warn "certbot не установлен. Установите: apt install certbot"
    fi

    echo ""
    echo "  Переключаемся на self-signed сертификат..."
  fi
fi

# Self-signed fallback
SSL_DIR="/etc/letsencrypt/live/${DOMAIN}"
SSL_CERT_PATH="${SSL_DIR}/fullchain.pem"
SSL_KEY_PATH="${SSL_DIR}/privkey.pem"

log "Генерируем self-signed сертификат..."
mkdir -p "$SSL_DIR"
openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout "$SSL_KEY_PATH" \
  -out "$SSL_CERT_PATH" \
  -subj "/CN=${DOMAIN}" \
  -addext "subjectAltName=DNS:${DOMAIN}" 2>/dev/null

SSL_MODE="selfsigned"
warn "Self-signed сертификат создан (браузер покажет предупреждение)"
warn "Для настоящего: certbot certonly --standalone -d ${DOMAIN}"

export SSL_CERT_PATH SSL_KEY_PATH SSL_MODE
