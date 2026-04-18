#!/usr/bin/env bash
# file: install/phase4-apply.sh v1.0
# Phase 4: Apply config — replace domain, adapt for HTTP mode
# Expects: DOMAIN, MODE, SSL_CERT_PATH, SSL_KEY_PATH, log/warn/die

log "═══════════════════════════════════════════"
log "  Фаза 4: Настройка конфигурации"
log "═══════════════════════════════════════════"

#################################
# REPLACE DOMAIN IN SOURCE FILES
#################################
log "Подставляем '${DOMAIN}' в файлы..."

sed -i "s/YOUDOMEN\.XXX/${DOMAIN}/g" docker-compose.yml
sed -i "s/YOUDOMEN\.XXX/${DOMAIN}/g" data/nginx.conf

log "Замена YOUDOMEN.XXX → ${DOMAIN} выполнена ✓"

#################################
# APPLY VERSION from data/VERSION
#################################
if [[ -f "data/VERSION" ]]; then
  APP_VERSION=$(tr -d '[:space:]' < data/VERSION)
  log "Версия приложения: ${APP_VERSION}"

  # Подставляем версию во все файлы где есть заглушка VERSION_PLACEHOLDER
  sed -i "s/VERSION_PLACEHOLDER/${APP_VERSION}/g" data/index.html 2>/dev/null || true
  sed -i "s/VERSION_PLACEHOLDER/${APP_VERSION}/g" data/nginx.conf 2>/dev/null || true
  sed -i "s/VERSION_PLACEHOLDER/${APP_VERSION}/g" data/status.php 2>/dev/null || true
  sed -i "s/VERSION_PLACEHOLDER/${APP_VERSION}/g" data/VERSION 2>/dev/null || true

  # Если фаза 4 запускается повторно (версия уже стоит) — ничего страшного
  # VERSION_PLACEHOLDER не найден, sed просто пропустит
fi

#################################
# HTTP MODE: adapt docker-compose.yml
#################################
if [[ "$MODE" == "http" ]]; then
  echo ""
  log "HTTP-режим: готовим nginx-http.conf"

  # Создаём HTTP-версию nginx.conf (без SSL, без редиректа 80→443)
  cat > nginx-http.conf <<'HTTPCONF'
limit_req_zone $binary_remote_addr zone=auth_limit:10m rate=3r/m;
limit_req_status 429;

map $request_id $auth_error_msg {
    default                                         "Неверный логин или пароль. Попробуйте ещё раз.";
    "~^[0-3]"                                       "Пользователь не найден.";
    "~^[4-7]"                                       "Неверный пароль.";
    "~^[8-b]"                                       "Аккаунт временно заблокирован. Попробуйте позже.";
    "~^[c-f]"                                       "Слишком много попыток. Подождите и попробуйте снова.";
}

server {
    listen 80;
    listen [::]:80;

    server_tokens off;
    access_log off;

    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Permitted-Cross-Domain-Policies "none" always;
    add_header X-Robots-Tag "noindex, nofollow" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "no-referrer" always;

    location / {
        root /usr/share/nginx/html;
        index index.html;
        try_files $uri $uri/ /index.html;
    }

    location ~ ^/api/status$ {
        default_type application/json;
        add_header X-Powered-By "MySphere/VERSION_PLACEHOLDER" always;
        add_header X-Request-Id "$request_id" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Robots-Tag "noindex, nofollow" always;
        add_header Referrer-Policy "no-referrer" always;
        return 200 '{"online":true,"maintenance":false,"version":"VERSION_PLACEHOLDER","build":"2026.03.15","product":"MySphere","api":"1.0"}';
    }

    error_page 429 = @rate_limited;
    location @rate_limited {
        default_type application/json;
        add_header Retry-After "20" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        return 429 '{"status":"error","message":"Слишком много запросов. Попробуйте через 20 секунд."}';
    }

    location ~ ^/api/auth$ {
        limit_req zone=auth_limit burst=2 nodelay;
        access_log /var/log/myfakesite/access.log combined;

        default_type application/json;
        add_header X-Request-Id "$request_id" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header Set-Cookie "ms_session=eyJhbGciOiJIUzI1NiJ9.$request_id.sig; Path=/; HttpOnly; Secure; SameSite=Strict" always;
        add_header Set-Cookie "__Host-ms_privacy=ack; Path=/; Secure; SameSite=Strict" always;
        add_header X-Robots-Tag "noindex, nofollow" always;
        add_header Referrer-Policy "no-referrer" always;
        return 401 '{"status":"error","message":"$auth_error_msg"}';
    }

    location ~ ^/api/files(/.*)?$ {
        default_type application/json;
        add_header X-Request-Id "$request_id" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Robots-Tag "noindex, nofollow" always;
        add_header Referrer-Policy "no-referrer" always;
        return 401 '{"status":"error","message":"Требуется авторизация"}';
    }

    location ~ ^/api/users(/.*)?$ {
        default_type application/json;
        add_header X-Request-Id "$request_id" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Robots-Tag "noindex, nofollow" always;
        add_header Referrer-Policy "no-referrer" always;
        return 401 '{"status":"error","message":"Требуется авторизация"}';
    }

    location ~ ^/api/settings$ {
        default_type application/json;
        add_header X-Request-Id "$request_id" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Robots-Tag "noindex, nofollow" always;
        add_header Referrer-Policy "no-referrer" always;
        return 200 '{"status":"ok","lang":"ru","theme":"auto","notifications":true,"two_factor":false,"storage":{"used":2847193600,"total":10737418240},"last_login":"2026-04-10T18:32:07Z"}';
    }

    location = /robots.txt {
        default_type text/plain;
        add_header X-Content-Type-Options "nosniff" always;
        return 200 'User-agent: *
Allow: /
Disallow: /api/
Disallow: /admin/
Disallow: /internal/
';
    }

    location = /heartbeat {
        default_type application/json;
        return 200 '{"ok":true,"ts":$msec}';
    }

    location = /.well-known/security.txt {
        default_type text/plain;
        add_header Access-Control-Allow-Origin "*" always;
        return 200 'Contact: mailto:admin@YOUDOMEN.XXX
Preferred-Languages: ru, en
Expires: 2027-01-01T00:00:00Z
';
    }

    location ~ ^/\.well-known/(?!security\.txt) {
        return 404;
    }

    location = /favicon.ico {
        root /usr/share/nginx/html;
        expires 30d;
        add_header Cache-Control "public, immutable" always;
        add_header X-Content-Type-Options "nosniff" always;
    }

    location = /apple-touch-icon.png {
        root /usr/share/nginx/html;
        expires 30d;
        add_header Cache-Control "public, immutable" always;
        add_header X-Content-Type-Options "nosniff" always;
    }

    location = /log-rotate-by-size.sh { return 404; }
    location = /data/log-rotate-by-size.sh { return 404; }

    location ~ \.php$ {
        root /usr/share/nginx/html;
        fastcgi_pass php-fpm:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Robots-Tag "noindex, nofollow" always;
        add_header Referrer-Policy "no-referrer" always;
    }

    location ~ ^/(?:\.ht.*|\.git.*|\.env.*|data/|config/|lib/|3rdparty/|templates/) {
        return 404;
    }

    error_page 500 502 503 504 /50x.html;
    location = /50x.html {
        root /usr/share/nginx/html;
    }
}
HTTPCONF

  sed -i "s/YOUDOMEN\.XXX/${DOMAIN}/g" nginx-http.conf

  # Правим docker-compose.yml: убираем 443 и SSL-тома, монтируем nginx-http.conf
  log "Адаптируем docker-compose.yml для HTTP-режима..."

  sed -i '/- "443:443"/d' docker-compose.yml
  sed -i '/fullchain\.pem.*fakesite\.crt/d' docker-compose.yml
  sed -i '/privkey\.pem.*fakesite\.key/d' docker-compose.yml
  sed -i 's|./data/nginx\.conf:/etc/nginx/conf\.d/default\.conf:ro|./nginx-http.conf:/etc/nginx/conf.d/default.conf:ro|' docker-compose.yml

  log "HTTP-конфигурация готова ✓"
  return 0
fi

#################################
# HTTPS MODE: SSL paths in docker-compose.yml
#################################
log "HTTPS-режим: проверяем пути к SSL в docker-compose.yml..."

# В docker-compose.yml пути-заглушки вида:
#   /etc/letsencrypt/live/YOUDOMEN.XXX/fullchain.pem
# YOUDOMEN.XXX уже заменён на DOMAIN.
# Если SSL_CERT_PATH совпадает — ничего не трогаем.
# Если нет — подменяем.

expected_cert="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
expected_key="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"

if [[ "$SSL_CERT_PATH" != "$expected_cert" ]]; then
  log "SSL-сертификаты в нестандартном пути — обновляем docker-compose.yml"
  log "  Было: $expected_cert"
  log "  Стало: $SSL_CERT_PATH"

  sed -i "s|${expected_cert}|${SSL_CERT_PATH}|g" docker-compose.yml
  sed -i "s|${expected_key}|${SSL_KEY_PATH}|g" docker-compose.yml
fi

log "Конфигурация HTTPS готова ✓"
