#!/usr/bin/env bash
# file: install/phase3-certs.sh v1.1
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
  return 0
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
  return 0
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
  return 0
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
    return 0
  fi
fi

# Функция получения LE сертификата
_get_le_cert() {
  local certbot_bin
  certbot_bin=$(command -v certbot 2>/dev/null || true)

  if [[ -z "$certbot_bin" ]]; then
    log "Устанавливаем certbot..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq && apt-get install -y -qq certbot 2>&1 || return 1
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y certbot 2>&1 || return 1
    elif command -v yum >/dev/null 2>&1; then
      yum install -y certbot 2>&1 || return 1
    else
      warn "Не удалось установить certbot"
      return 1
    fi

    certbot_bin=$(command -v certbot 2>/dev/null || true)
    [[ -n "$certbot_bin" ]] || { warn "certbot установлен, но не найден в PATH"; return 1; }
    log "certbot установлен ✓"
  fi

  # Получаем cert через standalone (контейнеры ещё не запущены, порт 80 свободен)
  log "Получаем Let's Encrypt сертификат для $DOMAIN..."

  if "$certbot_bin" certonly --standalone -d "$DOMAIN" \
    --non-interactive \
    --agree-tos \
    --register-unsafely-without-email 2>&1; then

    if [[ -f "$LE_CERT" && -f "$LE_KEY" ]]; then
      SSL_CERT_PATH="$LE_CERT"
      SSL_KEY_PATH="$LE_KEY"
      SSL_MODE="letsencrypt"
      log "Let's Encrypt сертификат получен ✓"

      # Переключаем renewal config на webroot для zero-downtime обновления
      local renewal_conf="/etc/letsencrypt/renewal/${DOMAIN}.conf"
      if [[ -f "$renewal_conf" ]]; then
        mkdir -p /var/www/acme-challenge/.well-known/acme-challenge
        sed -i 's/authenticator = standalone/authenticator = webroot/' "$renewal_conf"
        # Заменяем или добавляем webroot_path
        if grep -q 'webroot_path' "$renewal_conf"; then
          sed -i "s|webroot_path = .*|webroot_path = /var/www/acme-challenge|" "$renewal_conf"
        else
          sed -i "/authenticator = webroot/a webroot_path = /var/www/acme-challenge" "$renewal_conf"
        fi
        log "Renewal config переключён на webroot (без даунтайма) ✓"
      fi

      expiry=$(openssl x509 -in "$SSL_CERT_PATH" -noout -enddate 2>/dev/null | cut -d= -f2 || echo "unknown")
      log "Действителен до: $expiry"
      export SSL_CERT_PATH SSL_KEY_PATH SSL_MODE
      return 0
    fi
  fi

  return 1
}

if [[ "$NON_INTERACTIVE" == "true" ]]; then
  if ! _get_le_cert; then
    warn "certbot не смог получить сертификат. Переключаемся на self-signed..."
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
    if ! _get_le_cert; then
      warn "certbot не смог получить сертификат."
    fi
  fi
fi

# Если LE не получен — self-signed fallback
if [[ "$SSL_MODE" != "letsencrypt" ]]; then
  SSL_DIR="/etc/letsencrypt/live/${DOMAIN}"
  SSL_CERT_PATH="${SSL_DIR}/fullchain.pem"
  SSL_KEY_PATH="${SSL_DIR}/privkey.pem"

  # Проверяем, не занят ли путь существующим чужим сертификатом
  if [[ -f "$SSL_CERT_PATH" && -f "$SSL_KEY_PATH" ]]; then
    local existing_issuer
    existing_issuer=$(openssl x509 -in "$SSL_CERT_PATH" -noout -issuer 2>/dev/null || true)
    if [[ -n "$existing_issuer" ]] && ! echo "$existing_issuer" | grep -qi "MySphere\|fake"; then
      warn "В $SSL_DIR уже есть сертификат: $existing_issuer"
      warn "Используем его вместо генерации нового"
      if echo "$existing_issuer" | grep -qi "Let's Encrypt"; then
        SSL_MODE="letsencrypt"
      else
        SSL_MODE="custom"
      fi
      export SSL_CERT_PATH SSL_KEY_PATH SSL_MODE
      return 0
    fi
  fi

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
  warn "Для настоящего: apt install certbot && certbot certonly --standalone -d ${DOMAIN}"
fi

export SSL_CERT_PATH SSL_KEY_PATH SSL_MODE
