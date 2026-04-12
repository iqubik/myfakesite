<!-- file: TUTORIAL.md v1.0 -->

[🇷🇺 Русский](#-часть-1-зачем-нужен-mock-api) | [🇬🇧 English](#part-2-english-translation--full-tutorial)

---

# MySphere — Урок: Mock API в Nginx. Полный разбор проекта

> **Цель урока:** понять, как имитировать полноценный бэкенд с помощью одного лишь Nginx, и зачем это нужно при разработке фронтенда.

---

## Часть 1. Зачем нужен Mock API

### Проблема

Вы — frontend-разработчик. Вам нужно сделать:

- Красивую страницу с формой логина
- Анимированный 3D-фон
- API-эндпоинты (`/api/auth`, `/api/status`, `/api/settings`)
- Обработку ошибок, загрузку, rate limiting

Но **бэкенд ещё не написан**. Серверная команда занята другим проектом, база данных не развёрнута, API-спецификация только в черновиках. Ждать? Нет.

### Решение: Mock API

Mock API — это заглушки, которые **выглядят для фронтенда как настоящий сервер**. Фронтенд отправляет `POST /api/auth` — получает JSON-ответ с кодом 401. Он не знает, что ответ сгенерирован статически. Для него это полноценный HTTP-ответ с правильными заголовками.

**Преимущества:**
- Фронтенд разрабатывается параллельно с бэкендом
- Можно тестировать UI, анимации, обработку ошибок
- Когда реальный API будет готов — замена минимальна (убрать `return`, добавить `proxy_pass`)

---

## Часть 2. Архитектура проекта

```
docker-compose.yml
├── fakesite (nginx:alpine)
│   ├── :80  → HTTP (редирект на HTTPS)
│   ├── :443 → HTTPS (SSL-терминация)
│   ├── nginx.conf   ← здесь вся магия mock API
│   ├── index.html   ← SPA с Three.js
│   ├── status.php   ─┐
│   └── phpinfo.php  ─┤
│                     │ fastcgi
├── php-fpm (php:8.3-fpm-alpine)
│   ├── status.php   ← PHP health check
│   └── phpinfo.php  ← отладка PHP
```

**Ключевая идея:** Nginx — не просто прокси. Это полноценный HTTP-сервер, который умеет:
- Возвращать статический контент (`return 200 '...'`)
- Применять rate limiting (`limit_req`)
- Генерировать заголовки безопасности (`add_header`)
- Проксировать PHP-файлы в PHP-FPM (`fastcgi_pass`)

---

## Часть 3. Разбор docker-compose.yml

```yaml
services:
  fakesite:
    image: nginx:alpine
    container_name: fakesite
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./index.html:/usr/share/nginx/html/index.html:ro
      - ./status.php:/usr/share/nginx/html/status.php:ro
      - ./phpinfo.php:/usr/share/nginx/html/phpinfo.php:ro
      - ./favicon.ico:/usr/share/nginx/html/favicon.ico:ro
      - ./apple-touch-icon.png:/usr/share/nginx/html/apple-touch-icon.png:ro
      - ./robots.txt:/usr/share/nginx/html/robots.txt:ro
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - /etc/letsencrypt/live/YOUDOMEN.XXX/fullchain.pem:/etc/nginx/certs/fakesite.crt:ro
      - /etc/letsencrypt/live/YOUDOMEN.XXX/privkey.pem:/etc/nginx/certs/fakesite.key:ro
    networks:
      - fakesite
    depends_on:
      - php-fpm
    deploy:
      resources:
        limits:
          cpus: "0.25"
          memory: 64M
```

### Что здесь происходит

| Директива | Зачем |
|-----------|-------|
| `image: nginx:alpine` | Минимальный образ (~5 МБ) |
| `ports: "80:80", "443:443"` | Проброс портов хоста в контейнер |
| `volumes: ./файл:путь:ro` | Монтирование файлов с хоста в контейнер. `:ro` = read-only — контейнер не может их изменить |
| `depends_on: php-fpm` | Запускать nginx только после php-fpm |
| `deploy.resources.limits` | Лимиты: 0.25 CPU, 64 МБ памяти — чтобы контейнер не съедал всё |

**Зачем volume-монтирование?** Без него пришлось бы каждый раз пересобирать Docker-образ при изменении `index.html`. С volumes — меняете файл на хосте → nginx подхватывает мгновенно.

### PHP-FPM сервис

```yaml
  php-fpm:
    image: php:8.3-fpm-alpine
    container_name: fakesite-php
    restart: unless-stopped
    volumes:
      - ./status.php:/usr/share/nginx/html/status.php:ro
      - ./phpinfo.php:/usr/share/nginx/html/phpinfo.php:ro
    networks:
      - fakesite
    deploy:
      resources:
        limits:
          cpus: "0.1"
          memory: 32M
```

PHP-FPM — это FastCGI Process Manager. Он **не слушает HTTP-порты**. Вместо этого nginx подключается к нему по внутреннему порту `9000` через FastCGI протокол.

**Почему только два файла?** Потому что все API-эндпоинты обслуживает nginx напрямую. PHP нужен только для демонстрации `phpinfo()` и дублирующего health check.

### Сеть

```yaml
networks:
  fakesite:
    driver: bridge
```

Оба контейнера в одной bridge-сети. Это значит, что nginx может обращаться к php-fpm по **имени сервиса** `php-fpm:9000` — DNS-резольвинг внутри Docker.

---

## Часть 4. Разбор nginx.conf — сердце проекта

### 4.1. Rate Limiting Zone

```nginx
limit_req_zone $binary_remote_addr zone=auth_limit:10m rate=3r/m;
limit_req_status 429;
```

**Как это работает:**

- `$binary_remote_addr` — IP-адрес клиента в бинарном формате (компактнее строки)
- `zone=auth_limit:10m` — выделяем 10 МБ общей памяти для хранения счётчиков запросов. В 10 МБ помещается ~160 000 IP-адресов
- `rate=3r/m` — максимум 3 запроса в минуту с одного IP
- `limit_req_status 429` — при превышении лимита возвращать HTTP 429 (Too Many Requests)

**Токен-бакет алгоритм:** Nginx использует алгоритм "leaky bucket" (дырявое ведро). Каждый IP получает "токены" со скоростью 3 в минуту. Каждый запрос тратит 1 токен. Если токенов нет — 429.

### 4.2. Varying Error Messages

```nginx
map $request_id $auth_error_msg {
    default                                         "Неверный логин или пароль. Попробуйте ещё раз.";
    "~^[0-3]"                                       "Пользователь не найден.";
    "~^[4-7]"                                       "Неверный пароль.";
    "~^[8-b]"                                       "Аккаунт временно заблокирован. Попробуйте позже.";
    "~^[c-f]"                                       "Слишком много попыток. Подождите и попробуйте снова.";
}
```

**Зачем это нужно?** Реальные серверы не возвращают всегда одно и то же сообщение об ошибке — это выглядело бы неестественно. Здесь мы имитируем разные ответы:

- `$request_id` — уникальный 32-символьный hex-идентификатор, который nginx генерирует для каждого запроса (например, `a3f8b2c1d4e5f6a7b8c9d0e1f2a3b4c5`)
- `map` сопоставляет первый символ с сообщением об ошибке
- `~^[0-3]` — регулярное выражение: если первый символ 0, 1, 2 или 3 → "Пользователь не найден"

**Результат:** при каждой попытке входа пользователь видит **разные** сообщения — как на реальном сервере.

### 4.3. HTTP → HTTPS Редирект

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name YOUDOMEN.XXX;
    return 301 https://$host$request_uri;
}
```

Прослушиваем порт 80 (IPv4 + IPv6). Все запросы перенаправляем на HTTPS с кодом 301 (Permanent Redirect).

**Почему 301, а не 302?** 301 = "навсегда". Браузер кэширует этот редирект и в следующий раз сразу пойдёт на HTTPS, не заходя на порт 80.

### 4.4. Основной HTTPS Server

```nginx
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name YOUDOMEN.XXX;

    ssl_certificate /etc/nginx/certs/fakesite.crt;
    ssl_certificate_key /etc/nginx/certs/fakesite.key;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
```

- `ssl_protocols TLSv1.2 TLSv1.3` — только современные версии TLS. SSLv3, TLSv1.0, TLSv1.1 исключены (уязвимы)
- `HIGH:!aNULL:!MD5` — сильные шифры, без анонимных и без MD5
- `ssl_prefer_server_ciphers on` — сервер выбирает шифр, а не клиент

### 4.5. Security Headers

```nginx
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Permitted-Cross-Domain-Policies "none" always;
    add_header X-Robots-Tag "noindex, nofollow" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "no-referrer" always;
    add_header Strict-Transport-Security "max-age=15552000; includeSubDomains" always;
    add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval' https://cdnjs.cloudflare.com; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; img-src 'self' data: blob:; connect-src 'self'; media-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'self';" always;

    server_tokens off;
```

| Заголовок | Что делает |
|-----------|-----------|
| `X-Content-Type-Options: nosniff` | Запрещает браузеру угадывать MIME-тип (защита от MIME-sniffing атак) |
| `X-Frame-Options: SAMEORIGIN` | Запрещает встраивание сайта в iframe на чужих доменах (защита от clickjacking) |
| `X-Permitted-Cross-Domain-Policies: none` | Запрещает Flash/PDF кросс-доменные запросы |
| `X-Robots-Tag: noindex, nofollow` | Говорит поисковикам не индексировать сайт |
| `X-XSS-Protection: 1; mode=block` | Включает XSS-фильтр браузера (устаревший, но harmless) |
| `Referrer-Policy: no-referrer` | Не передаёт URL реферера при переходах на другие сайты |
| `Strict-Transport-Security` | HSTS: браузер всегда будет использовать HTTPS для этого домена (15552000 сек = 180 дней) |
| `Content-Security-Policy` | CSP: whitelist источников для скриптов, стилей, шрифтов, изображений. `object-src 'none'` — запрет `<object>`/`<embed>` |
| `server_tokens off` | Убирает версию nginx из заголовка `Server:` |

**`always`** — заголовки добавляются ко всем ответам, включая ошибки (4xx, 5xx).

### 4.6. SPA Routing

```nginx
    location / {
        root /usr/share/nginx/html;
        index index.html;
        try_files $uri $uri/ /index.html;
    }
```

**Как работает `try_files`:**

1. Пользователь заходит на `https://domain.com/dashboard`
2. Nginx ищет файл `/usr/share/nginx/html/dashboard` — не находит
3. Ищет директорию `/usr/share/nginx/html/dashboard/` — не находит
4. Возвращает `/usr/share/nginx/html/index.html`

JavaScript-роутер в браузере видит URL `/dashboard` и отрисовывает нужную страницу. Это стандартный паттерн для React, Vue, Angular и любых SPA.

### 4.7. Mock API: Health Check

```nginx
    location ~ ^/api/status$ {
        default_type application/json;
        add_header X-Powered-By "MySphere/2.4.8" always;
        add_header X-Request-Id "$request_id" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Robots-Tag "noindex, nofollow" always;
        add_header Referrer-Policy "no-referrer" always;
        add_header Strict-Transport-Security "max-age=15552000; includeSubDomains" always;
        return 200 '{"online":true,"maintenance":false,"version":"2.4.8","build":"2026.03.15","product":"MySphere","api":"1.0"}';
    }
```

**Разбор:**

- `location ~ ^/api/status$` — регулярное выражение. `~` = case-sensitive regex match. Точное совпадение `/api/status`
- `default_type application/json` — если не указан Content-Type, браузер поймёт что это JSON
- `add_header` — стандартные заголовки + фейковый `X-Powered-By: MySphere/2.4.8` (имитация реального бэкенда)
- `return 200 '...'` — **вот он, mock API**. Nginx возвращает HTTP 200 с телом JSON. Ни одного бэкенд-сервера не было вызвано.

**Результат запроса:**
```json
{
  "online": true,
  "maintenance": false,
  "version": "2.4.8",
  "build": "2026.03.15",
  "product": "MySphere",
  "api": "1.0"
}
```

### 4.8. Mock API: Authentication с Rate Limiting

```nginx
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

        default_type application/json;
        add_header X-Request-Id "$request_id" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header Set-Cookie "ms_session=eyJhbGciOiJIUzI1NiJ9.$request_id.sig; Path=/; HttpOnly; Secure; SameSite=Strict" always;
        add_header Set-Cookie "__Host-ms_privacy=ack; Path=/; Secure; SameSite=Strict" always;
        add_header X-Robots-Tag "noindex, nofollow" always;
        add_header Referrer-Policy "no-referrer" always;
        add_header Strict-Transport-Security "max-age=15552000; includeSubDomains" always;
        return 401 '{"status":"error","message":"$auth_error_msg"}';
    }
```

**Это самый интересный блок. Разбираем построчно:**

#### Rate Limiting

```nginx
limit_req zone=auth_limit burst=2 nodelay;
```

- `zone=auth_limit` — используем зону, определённую выше (`rate=3r/m`)
- `burst=2` — разрешаем "всплеск" из 2 дополнительных запросов
- `nodelay` — не задерживать запросы из burst-очереди, а обрабатывать сразу

**Пример:**
- Запрос 1 → OK (в лимите)
- Запрос 2 → OK (burst)
- Запрос 3 → OK (burst)
- Запрос 4 → 429 Too Many Requests

#### Fake Cookies

```nginx
add_header Set-Cookie "ms_session=eyJhbGciOiJIUzI1NiJ9.$request_id.sig; Path=/; HttpOnly; Secure; SameSite=Strict" always;
```

- Формируем фейковую куку `ms_session` с `$request_id` в качестве сигнатуры
- `HttpOnly` — JavaScript не может прочитать куку (защита от XSS)
- `Secure` — кука отправляется только по HTTPS
- `SameSite=Strict` — кука не отправляется при кросс-сайтовых запросах (защита от CSRF)

Вторая кука `__Host-ms_privacy` — имитация privacy-согласия. Префикс `__Host-` требует, чтобы кука была установлена с HTTPS и `Path=/`.

#### Mock Response

```nginx
return 401 '{"status":"error","message":"$auth_error_msg"}';
```

- Всегда возвращаем 401 Unauthorized
- `$auth_error_msg` — переменная из `map` выше, зависит от первого символа `$request_id`

**Примеры ответов:**
```json
{"status":"error","message":"Пользователь не найден."}
{"status":"error","message":"Неверный пароль."}
{"status":"error","message":"Аккаунт временно заблокирован. Попробите позже."}
{"status":"error","message":"Слишком много попыток. Подождите и попробуйте снова."}
```

### 4.9. Mock API: Защищённые эндпоинты

```nginx
    location ~ ^/api/files(/.*)?$ {
        default_type application/json;
        add_header X-Request-Id "$request_id" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Robots-Tag "noindex, nofollow" always;
        add_header Referrer-Policy "no-referrer" always;
        add_header Strict-Transport-Security "max-age=15552000; includeSubDomains" always;
        return 401 '{"status":"error","message":"Требуется авторизация"}';
    }

    location ~ ^/api/users(/.*)?$ {
        ...аналогично...
        return 401 '{"status":"error","message":"Требуется авторизация"}';
    }
```

`^/api/files(/.*)?$` — регулярное выражение, которое матчит:
- `/api/files`
- `/api/files/`
- `/api/files/document.pdf`
- `/api/files/images/photo.jpg`

Всегда возвращаем 401 — имитация защищённого маршрута, требующего авторизации.

### 4.10. Mock API: Settings

```nginx
    location ~ ^/api/settings$ {
        default_type application/json;
        add_header X-Request-Id "$request_id" always;
        ...заголовки...
        return 200 '{"status":"ok","lang":"ru","theme":"auto","notifications":true,"two_factor":false,"storage":{"used":2847193600,"total":10737418240},"last_login":"2026-04-10T18:32:07Z"}';
    }
```

Возвращаем моковые настройки пользователя: язык, тема, уведомления, двухфакторка, квота хранилища (2.8 ГБ из 10 ГБ использовано).

### 4.11. Robots.txt из Nginx

```nginx
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
```

Обычно `robots.txt` — это файл на диске. Здесь мы генерируем его **на лету** из конфига Nginx. Результат идентичный, но не нужно хранить отдельный файл.

### 4.12. Heartbeat Endpoint

```nginx
    location = /heartbeat {
        default_type application/json;
        return 200 '{"ok":true,"ts":$msec}';
    }
```

- `$msec` — текущее время в миллисекундах (nginx-переменная)
- Мониторинг доступности, health checks от load balancer'а

**Пример ответа:** `{"ok":true,"ts":1712950000123}`

### 4.13. Well-Known URIs

```nginx
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
```

- `/.well-known/security.txt` — стандарт RFC 9116. Файл, по которому исследователи безопасности находят контакт для отчётов об уязвимостях
- `Access-Control-Allow-Origin "*"` — CORS-заголовок, позволяющий любому сайту читать этот файл
- Второй блок — все остальные `.well-known` пути (кроме `security.txt`) → 404

### 4.14. Статические ресурсы

```nginx
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
```

- `expires 30d` — заголовок `Expires` через 30 дней
- `Cache-Control: public, immutable` — CDN и браузеры могут кэшировать навсегда (имя файла не меняется — версия через content hash)

### 4.15. PHP-FPM Proxy

```nginx
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
        add_header Strict-Transport-Security "max-age=15552000; includeSubDomains" always;
    }
```

**Как работает FastCGI:**

1. Запрос на `/status.php` попадает в этот `location` (regex `\.php$`)
2. `fastcgi_pass php-fpm:9000` — nginx подключается к PHP-FPM контейнеру по порту 9000
3. `fastcgi_param SCRIPT_FILENAME` — говорит PHP-FPM, какой файл выполнять (`$document_root$fastcgi_script_name` = `/usr/share/nginx/html/status.php`)
4. `include fastcgi_params` — стандартные FastCGI-параметры (REQUEST_METHOD, QUERY_STRING и т.д.)
5. PHP-FPM выполняет PHP-скрипт и возвращает результат nginx'у
6. Nginx добавляет security headers и отдаёт клиенту

**`fastcgi_hide_header X-Powered-By`** — PHP по умолчанию добавляет `X-Powered-By: PHP/8.3.x`. Мы скрываем это, чтобы не раскрывать версию PHP.

### 4.16. Блокировка чувствительных путей

```nginx
    location ~ ^/(?:\.ht.*|\.git.*|\.env.*|data/|config/|lib/|3rdparty/) {
        return 404;
    }
```

Защита от доступа к файлам, которые **не должны быть доступны из интернета**:

| Паттерн | Что защищает |
|---------|-------------|
| `\.ht.*` | `.htaccess`, `.htpasswd` |
| `\.git.*` | `.git/config`, `.git/HEAD` (утечка репозитория) |
| `\.env.*` | `.env` файлы с секретами |
| `data/` | Директория с данными |
| `config/` | Конфигурационные файлы |
| `lib/` | Библиотеки |
| `3rdparty/` | Сторонний код |

**Почему 404, а не 403?** 403 = "Forbidden" — говорит атакующему "файл есть, но доступа нет". 404 = "Not Found" — атакующий не знает, существует ли файл вообще.

---

## Часть 5. Разбор index.html — фронтенд

### 5.1. Структура страницы

```
index.html
├── <head>
│   ├── meta-теги (viewport, description, PWA)
│   ├── SVG favicon (inline data URI)
│   ├── Google Fonts (Inter)
│   └── <style> (все стили, без внешних CSS)
├── <body>
│   ├── .bg-planet (планета-фон внизу экрана)
│   ├── #canvas-container (Three.js 3D-фон)
│   ├── #login-container (форма логина поверх 3D)
│   │   ├── logo-wrapper (лого + "MySphere")
│   │   ├── form-wrapper
│   │   │   └── #form-card (glassmorphism карточка)
│   │   │       ├── CSRF token (hidden)
│   │   │       ├── user input
│   │   │       ├── password input
│   │   │       └── submit button
│   │   └── footer-bar (текст + версия)
│   └── <script> (вся логика)
```

**Ключевое:** весь CSS и JS inline, нет внешних зависимостей кроме:
- Google Fonts (Inter)
- Three.js r128 (CDN: cdnjs.cloudflare.com)

### 5.2. Health Check при загрузке

```javascript
(function checkHealth() {
    fetch('/api/status', { method: 'GET', cache: 'no-store' })
        .then(r => r.json())
        .then(data => {
            if (data.online && !data.maintenance) {
                console.log('[MySphere] Server ready — v' + data.version);
            }
        })
        .catch(() => {
            console.warn('[MySphere] Status check failed — offline mode');
        });
})();
```

IIFE (Immediately Invoked Function Expression) — функция выполняется сразу при загрузке скрипта.

1. `fetch('/api/status')` — GET-запрос к mock API
2. `cache: 'no-store'` — не использовать кэш (всегда свежий запрос)
3. `.then(r => r.json())` — парсим JSON
4. Если `online: true` и `maintenance: false` — логируем в консоль
5. Если ошибка сети — предупреждение "offline mode"

**Зачем?** Убедиться что бэкенд (nginx) работает до того, как пользователь попытается войти.

### 5.3. CSRF Token Generation

```javascript
(function generateCSRFToken() {
    var array = new Uint8Array(32);
    crypto.getRandomValues(array);
    var token = 'ms-' + Array.from(array).map(function(b) {
        return b.toString(16).padStart(2, '0');
    }).join('');
    document.getElementById('requesttoken').value = token;
})();
```

1. `new Uint8Array(32)` — массив из 32 случайных байт
2. `crypto.getRandomValues(array)` — криптографически безопасный генератор (не `Math.random`)
3. Конвертируем каждый байт в hex (`toString(16)`) с лидирующим нулём (`padStart(2, '0')`)
4. Склеиваем с префиксом `ms-`
5. Вставляем в скрытое поле `#requesttoken`

**Результат:** `ms-a3f8b2c1d4e5f6a7b8c9d0e1f2a3b4c5a3f8b2c1d4e5f6a7b8c9d0e1f2a3b4c5`

### 5.4. Отправка формы (реальный POST-запрос)

```javascript
document.getElementById('login-form').addEventListener('submit', function(e) {
    e.preventDefault();

    const btn = document.getElementById('submit-btn');
    const originalHTML = btn.innerHTML;
    const user = document.getElementById('user').value;
    const password = document.getElementById('password').value;
    const token = document.getElementById('requesttoken').value;

    // Показываем спиннер загрузки
    btn.innerHTML = '<svg>...spinner...</svg>';

    // Реальный POST на /api/auth
    fetch('/api/auth', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ user: user, pass: password, token: token })
    })
    .then(r => {
        if (r.status === 429) {
            return r.json().then(data => {
                btn.innerHTML = originalHTML;
                alert(data.message || 'Слишком много попыток. Попробуйте через минуту.');
                throw new Error('Rate limited');
            });
        }
        return r.json();
    })
    .then(data => {
        btn.innerHTML = originalHTML;
        // Анимация "тряски" карточки
        const card = document.getElementById('form-card');
        card.classList.remove('shake-animation');
        void card.offsetWidth; // force reflow (перезапуск анимации)
        card.classList.add('shake-animation');
        // Очистка поля пароля
        document.getElementById('password').value = '';
        document.getElementById('password').focus();
    })
    .catch(err => {
        if (err.message === 'Rate limited') return;
        btn.innerHTML = originalHTML;
        // ... та же анимация тряски
    });
});
```

**Пошагово:**

1. **`e.preventDefault()`** — предотвращаем стандартную отправку формы (перезагрузку страницы)
2. **Запоминаем** текущее содержимое кнопки для восстановления после запроса
3. **Меняем кнопку** на SVG-спиннер с `animation: spin 1s linear infinite`
4. **Отправляем `POST /api/auth`** с JSON-телом: `{user, pass, token}`
5. **Обработка 429:** если rate limit — показываем `alert` с сообщением из ответа сервера
6. **Обработка 401:** в любом случае (сервер всегда возвращает 401) — трясём карточку, очищаем пароль, возвращаем фокус
7. **`void card.offsetWidth`** — хак для перезапуска CSS-анимации. Без него повторное добавление класса `shake-animation` не сработает (браузер видит что класс уже был и не анимирует заново)

### 5.5. Three.js: 3D-фон

#### Градиентная текстура (фон сцены)

```javascript
function createGradientTexture() {
    const canvas = document.createElement('canvas');
    canvas.width = 1024;
    canvas.height = 1024;
    const context = canvas.getContext('2d');

    const gradient = context.createRadialGradient(512, 0, 0, 512, 0, 1024);
    gradient.addColorStop(0.0, '#14b8a6');
    gradient.addColorStop(0.4, '#0d9488');
    gradient.addColorStop(0.8, '#0f766e');
    gradient.addColorStop(1.0, '#042f2e');

    context.fillStyle = gradient;
    context.fillRect(0, 0, 1024, 1024);

    const texture = new THREE.CanvasTexture(canvas);
    texture.colorSpace = THREE.SRGBColorSpace;
    texture.mapping = THREE.EquirectangularReflectionMapping;
    return texture;
}
```

Создаём canvas 1024×1024, рисуем радиальный градиент в teal-палитре, превращаем в Three.js-текстуру. Эта текстура используется как `scene.background`.

#### Environment Map (отражения)

```javascript
function createEnvTexture() {
    const canvas = document.createElement('canvas');
    canvas.width = 1024;
    canvas.height = 512;
    // ... рисуем световые пятна
    const texture = new THREE.CanvasTexture(canvas);
    texture.mapping = THREE.EquirectangularReflectionMapping;
    return texture;
}
```

Environment map — текстура, которая используется для **отражений** на 3D-объектах. Сфера на сцене будет отражать эти световые пятна, создавая реалистичный эффект.

#### Шейдеры: Light Rays

```glsl
fragmentShader: `
    varying vec2 vUv;
    uniform float time;
    uniform vec3 uColor;

    float hash(vec2 p) {
        return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
    }

    float noise(vec2 p) {
        vec2 i = floor(p);
        vec2 f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
                   mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
    }

    void main() {
        float rays = 0.0;
        float angle = atan(vUv.y - 0.5, vUv.x - 0.5);
        // ... генерация лучей через sin(angle * N + time)
        // ... наложение noise для органичности
        gl_FragColor = vec4(uColor, rays * 0.15);
    }
`
```

**Что такое шейдер?** Это программа, которая выполняется на GPU для каждого пикселя (fragment shader) или каждой вершины (vertex shader).

- `hash()` — псевдослучайная функция на основе `sin(dot(...))` — стандартный трюк в GLSL
- `noise()` — Value Noise (интерполяция хешей соседних ячеек) — создаёт "облачную" текстуру
- `atan(vUv.y - 0.5, vUv.x - 0.5)` — угол от центра — используется для создания радиальных лучей
- `sin(angle * N + time)` — N лучей, вращающихся со временем
- `gl_FragColor` — итоговый цвет пикселя с прозрачностью `rays * 0.15`

#### Анимация сферы (CPU-side)

```javascript
function updateClouds(time) {
    const noise = createNoise3D();
    cloudMeshes.forEach(mesh => {
        const positions = mesh.geometry.attributes.position.array;
        const originalPositions = mesh.userData.originalPositions;

        for (let i = 0; i < positions.length; i += 3) {
            const ox = originalPositions[i];
            const oy = originalPositions[i + 1];
            const oz = originalPositions[i + 2];

            const n = noise(ox * 0.5, oy * 0.5, oz * 0.5, time * 0.3);
            const displacement = n * 0.08;

            positions[i]     = ox + ox * displacement;
            positions[i + 1] = oy + oy * displacement;
            positions[i + 2] = oz + oz * displacement;
        }

        mesh.geometry.attributes.position.needsUpdate = true;
        mesh.geometry.computeVertexNormals();
    });
}
```

Каждый кадр:
1. Для каждой вершины сферы вычисляем 3D-шум
2. Смещаем вершину вдоль радиального направления на величину шума × 0.08
3. `needsUpdate = true` — сообщаем Three.js что геометрия изменилась
4. `computeVertexNormals()` — пересчитываем нормали для правильного освещения

**Результат:** сфера "дышит" — её поверхность плавно деформируется как облако или планета с атмосферой.

#### Render Loop

```javascript
function animate() {
    requestAnimationFrame(animate);

    const time = clock.getElapsedTime();

    cloudGroup.rotation.y = time * 0.05;

    updateClouds(time);

    rayMaterial.uniforms.time.value = time;

    renderer.render(scene, camera);
}

animate();
```

`requestAnimationFrame` — браузер вызывает функцию перед каждой перерисовкой (обычно 60 fps).

1. Получаем время с начала работы часов
2. Вращаем группу сфер вокруг оси Y
3. Обновляем вершины сфер (деформация)
4. Обновляем uniform времени в шейдере лучей
5. Рендерим сцену

### 5.6. Resize Handler

```javascript
window.addEventListener('resize', () => {
    camera.aspect = window.innerWidth / window.innerHeight;
    camera.updateProjectionMatrix();
    renderer.setSize(window.innerWidth, window.innerHeight);
});
```

При изменении размера окна:
- Обновляем aspect ratio камеры
- Пересчитываем матрицу проекции (иначе будет искажение)
- Меняем размер рендерера

---

## Часть 6. Разбор status.php

```php
<?php
header('Content-Type: application/json; charset=utf-8');
header('X-Powered-By: MySphere/2.4.8');
http_response_code(200);

echo json_encode([
    'online' => true,
    'maintenance' => false,
    'version' => '2.4.8',
    'build' => '2026.03.15',
    'product' => 'MySphere',
    'api' => '1.0',
]);
```

Дублирует nginx-эндпоинт `/api/status`. Используется если:
- Нужно проверить что PHP-FPM работает (через nginx: `GET /status.php`)
- Прямой доступ к PHP-FPM без nginx (`curl php-fpm:9000` — но это не сработает, т.к. PHP-FPM не HTTP-сервер)

**Результат:**
```json
{
  "online": true,
  "maintenance": false,
  "version": "2.4.8",
  "build": "2026.03.15",
  "product": "MySphere",
  "api": "1.0"
}
```

---

## Часть 7. Практические упражнения

### Упражнение 1: Добавить новый mock-эндпоинт

**Задача:** Добавить `GET /api/profile`, который возвращает профиль пользователя.

**Решение** — в `nginx.conf` добавить:

```nginx
location ~ ^/api/profile$ {
    default_type application/json;
    add_header X-Request-Id "$request_id" always;
    add_header X-Content-Type-Options "nosniff" always;
    return 200 '{"status":"ok","user":"demo","email":"demo@example.com","role":"user","created":"2025-01-15T10:00:00Z"}';
}
```

### Упражнение 2: Изменить rate limiting

**Задача:** Увеличить лимит `/api/auth` до 10 запросов в минуту с burst=5.

**Решение** — изменить:

```nginx
limit_req_zone $binary_remote_addr zone=auth_limit:10m rate=10r/m;
```

И в location:

```nginx
limit_req zone=auth_limit burst=5 nodelay;
```

### Упражнение 3: Добавить редирект для неавторизованных

**Задача:** При запросе `/admin` редиректить на `/` с сообщением.

**Решение:**

```nginx
location ~ ^/admin {
    return 302 '/?error=access_denied';
}
```

### Упражнение 4: Обработать 404 для несуществующих API-эндпоинтов

**Задача:** Все запросы к `/api/*`, которые не замаплены на конкретные location'ы, должны возвращать 404.

**Решение** — в конец конфига (перед закрывающей `}` server-блока):

```nginx
location ^~ /api/ {
    default_type application/json;
    return 404 '{"status":"error","message":"Endpoint not found"}';
}
```

`^~` — приоритет prefix match над regex. Если запрос начинается с `/api/` и не попал в более специфичный `location ~` — срабатывает этот блок.

---

## Часть 8. Контрольные вопросы

1. **Чем `return 200 '...'` отличается от `proxy_pass`?**
2. **Зачем нужен `burst=2 nodelay` в rate limiting?**
3. **Почему мы используем `void card.offsetWidth` перед добавлением класса анимации?**
4. **Какой заголовок защищает от clickjacking?**
5. **Зачем `server_tokens off`?**
6. **Как nginx понимает к какому контейнеру подключаться при `fastcgi_pass php-fpm:9000`?**
7. **Почему 404 лучше чем 403 для блокировки чувствительных путей?**
8. **Что делает `try_files $uri $uri/ /index.html`?**

---

## Часть 9. Ответы

1. **`return`** — nginx сам генерирует ответ из конфига. **`proxy_pass`** — nginx пересылает запрос на внешний бэкенд и возвращает его ответ.
2. **`burst`** — позволяет кратковременно превысить лимит (очередь из дополнительных запросов). **`nodelay`** — не задерживать их, а обрабатывать сразу. Без nodelay запросы из burst-очереди ставились бы в очередь и ждали освобождения лимита.
3. **Force reflow** — браузер "забывает" о предыдущем применении анимации. Без этого трюка повторное добавление класса не перезапускает CSS-анимацию.
4. **`X-Frame-Options: SAMEORIGIN`** — запрещает iframe-встраивание с чужих доменов.
5. **Скрытие версии nginx** — из заголовка `Server: nginx` убирается номер версии. Затрудняет поиск известных уязвимостей для конкретной версии.
6. **Docker DNS** — в bridge-сети Docker запускает встроенный DNS-сервер. Имя сервиса `php-fpm` резольвится в IP контейнера автоматически.
7. **404** не подтверждает существование файла. **403** говорит "файл есть, но доступа нет" — это информация для атакующего.
8. **Пытается отдать файл → директорию → fallback на index.html.** Это позволяет SPA обрабатывать все маршруты на клиенте.

---

## Часть 10. Шпаргалка: Mock API паттерны

| Паттерн | Nginx-директива | Пример |
|---------|----------------|--------|
| Простой GET | `return 200 '{...}'` | Health check, статус сервера |
| Ошибка авторизации | `return 401 '{...}'` | Mock auth endpoint |
| Rate limit ответ | `error_page 429 = @name` | Кастомный JSON для 429 |
| Редирект | `return 301 URL` | HTTP → HTTPS |
| Динамический контент | Переменные nginx (`$request_id`, `$msec`) | Уникальные ID в ответах |
| Varying ошибки | `map $var $msg` | Разные сообщения об ошибках |
| Фейковые куки | `add_header Set-Cookie "..."` | Mock session cookies |
| Заглушка для всего пути | `return 401/404` | Защищённые маршруты |

---

**Итог:** Mock API на уровне Nginx — это мощный приём, который позволяет фронтенд-разработчикам работать автономно, не дожидаясь бэкенда. Вы контролируете каждый заголовок, каждый код ответа, каждый байт тела ответа — и всё это без единой строки серверного кода.

---

[🔝 В начало](#mysphere--урок-mock-api-в-nginx-полный-разбор-проекта) | [🇷🇺 Русская часть](#-часть-1-зачем-нужен-mock-api)

---

# Part 2. English Translation — Full Tutorial

> **Goal:** Understand how to simulate a full backend using Nginx alone, and why this matters for frontend development.

---

## Part 1. Why Mock API

### The Problem

You're a frontend developer. You need to build:

- A beautiful login page
- An animated 3D background
- API endpoints (`/api/auth`, `/api/status`, `/api/settings`)
- Error handling, loading states, rate limiting

But **the backend isn't written yet**. The server team is busy with another project, the database isn't deployed, the API spec is still in drafts. Wait? No.

### The Solution: Mock API

Mock API — these are stubs that **look like a real server to the frontend**. The frontend sends `POST /api/auth` — gets a JSON response with code 401. It doesn't know the response was generated statically. For the frontend, it's a full HTTP response with proper headers.

**Advantages:**
- Frontend develops in parallel with the backend
- You can test UI, animations, error handling
- When the real API is ready — minimal changes needed (remove `return`, add `proxy_pass`)

---

## Part 2. Project Architecture

```
docker-compose.yml
├── fakesite (nginx:alpine)
│   ├── :80  → HTTP (redirect to HTTPS)
│   ├── :443 → HTTPS (SSL termination)
│   ├── nginx.conf   ← all the mock API magic
│   ├── index.html   ← SPA with Three.js
│   ├── status.php   ─┐
│   └── phpinfo.php  ─┤
│                     │ fastcgi
├── php-fpm (php:8.3-fpm-alpine)
│   ├── status.php   ← PHP health check
│   └── phpinfo.php  ← PHP debugging
```

**Key idea:** Nginx is not just a proxy. It's a full HTTP server that can:
- Return static content (`return 200 '...'`)
- Apply rate limiting (`limit_req`)
- Generate security headers (`add_header`)
- Proxy PHP files to PHP-FPM (`fastcgi_pass`)

---

## Part 3. docker-compose.yml Breakdown

```yaml
services:
  fakesite:
    image: nginx:alpine
    container_name: fakesite
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./index.html:/usr/share/nginx/html/index.html:ro
      - ./status.php:/usr/share/nginx/html/status.php:ro
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      # ... other volumes ...
    networks:
      - fakesite
    depends_on:
      - php-fpm
    deploy:
      resources:
        limits:
          cpus: "0.25"
          memory: 64M
```

| Directive | Purpose |
|-----------|---------|
| `image: nginx:alpine` | Minimal image (~5 MB) |
| `ports: "80:80", "443:443"` | Host-to-container port mapping |
| `volumes: ./file:path:ro` | Mount files from host. `:ro` = read-only — container can't modify them |
| `depends_on: php-fpm` | Start nginx only after php-fpm is ready |
| `deploy.resources.limits` | Limits: 0.25 CPU, 64 MB memory — prevents the container from hogging resources |

**Why volume mounting?** Without it, you'd have to rebuild the Docker image every time `index.html` changes. With volumes — change the file on the host → nginx picks it up instantly.

---

## Part 4. nginx.conf Breakdown — The Heart of the Project

### 4.1. Rate Limiting Zone

```nginx
limit_req_zone $binary_remote_addr zone=auth_limit:10m rate=3r/m;
limit_req_status 429;
```

**How it works:**

- `$binary_remote_addr` — client IP in binary format (more compact than a string)
- `zone=auth_limit:10m` — allocate 10 MB shared memory for request counters. 10 MB holds ~160,000 IP addresses
- `rate=3r/m` — max 3 requests per minute per IP
- `limit_req_status 429` — return HTTP 429 (Too Many Requests) when exceeded

**Token bucket algorithm:** Nginx uses the "leaky bucket" algorithm. Each IP gets "tokens" at a rate of 3 per minute. Each request costs 1 token. No tokens left → 429.

### 4.2. Varying Error Messages

```nginx
map $request_id $auth_error_msg {
    default                                         "Invalid username or password. Please try again.";
    "~^[0-3]"                                       "User not found.";
    "~^[4-7]"                                       "Invalid password.";
    "~^[8-b]"                                       "Account temporarily locked. Please try again later.";
    "~^[c-f]"                                       "Too many attempts. Please wait and try again.";
}
```

**Why?** Real servers don't always return the same error message — that would look artificial. Here we simulate different responses:

- `$request_id` — a unique 32-character hex ID nginx generates per request (e.g., `a3f8b2c1...`)
- `map` matches the first character to an error message
- `~^[0-3]` — regex: if the first character is 0, 1, 2, or 3 → "User not found."

**Result:** each login attempt shows a **different** message — just like a real server.

### 4.3. HTTP → HTTPS Redirect

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name YOUDOMEN.XXX;
    return 301 https://$host$request_uri;
}
```

Listen on port 80 (IPv4 + IPv6). Redirect all requests to HTTPS with code 301 (Permanent Redirect).

**Why 301, not 302?** 301 = "permanent". The browser caches this redirect and next time goes straight to HTTPS without hitting port 80.

### 4.4. Main HTTPS Server Block

```nginx
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name YOUDOMEN.XXX;

    ssl_certificate /etc/nginx/certs/fakesite.crt;
    ssl_certificate_key /etc/nginx/certs/fakesite.key;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
```

- `ssl_protocols TLSv1.2 TLSv1.3` — modern TLS versions only. SSLv3, TLSv1.0, TLSv1.1 excluded (vulnerable)
- `HIGH:!aNULL:!MD5` — strong ciphers, no anonymous or MD5-based
- `ssl_prefer_server_ciphers on` — server picks the cipher, not the client

### 4.5. Security Headers

```nginx
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Permitted-Cross-Domain-Policies "none" always;
add_header X-Robots-Tag "noindex, nofollow" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "no-referrer" always;
add_header Strict-Transport-Security "max-age=15552000; includeSubDomains" always;
add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval' https://cdnjs.cloudflare.com; ..." always;

server_tokens off;
```

| Header | What it does |
|--------|-------------|
| `X-Content-Type-Options: nosniff` | Prevents browser MIME-type sniffing |
| `X-Frame-Options: SAMEORIGIN` | Blocks iframe embedding on other domains (clickjacking protection) |
| `X-Permitted-Cross-Domain-Policies: none` | Blocks Flash/PDF cross-domain requests |
| `X-Robots-Tag: noindex, nofollow` | Tells search engines not to index the site |
| `X-XSS-Protection: 1; mode=block` | Enables browser XSS filter (legacy, but harmless) |
| `Referrer-Policy: no-referrer` | Don't send referrer URL when navigating to other sites |
| `Strict-Transport-Security` | HSTS: browser always uses HTTPS for this domain (180 days) |
| `Content-Security-Policy` | CSP: whitelist of allowed sources for scripts, styles, fonts, images |
| `server_tokens off` | Removes nginx version from the `Server:` header |

### 4.6. SPA Routing

```nginx
location / {
    root /usr/share/nginx/html;
    index index.html;
    try_files $uri $uri/ /index.html;
}
```

**How `try_files` works:**

1. User visits `https://domain.com/dashboard`
2. Nginx looks for file `/usr/share/nginx/html/dashboard` — not found
3. Looks for directory `/usr/share/nginx/html/dashboard/` — not found
4. Returns `/usr/share/nginx/html/index.html`

The JavaScript router in the browser sees URL `/dashboard` and renders the correct page. Standard pattern for React, Vue, Angular, and any SPA.

### 4.7. Mock API: Health Check

```nginx
location ~ ^/api/status$ {
    default_type application/json;
    add_header X-Powered-By "MySphere/2.4.8" always;
    add_header X-Request-Id "$request_id" always;
    return 200 '{"online":true,"maintenance":false,"version":"2.4.8","build":"2026.03.15","product":"MySphere","api":"1.0"}';
}
```

**Breakdown:**

- `location ~ ^/api/status$` — regex match. `~` = case-sensitive. Exact match `/api/status`
- `default_type application/json` — browser understands this is JSON
- `add_header` — standard headers + fake `X-Powered-By: MySphere/2.4.8` (simulating a real backend)
- `return 200 '...'` — **this is the mock API**. Nginx returns HTTP 200 with a JSON body. Zero backend servers were invoked.

### 4.8. Mock API: Authentication with Rate Limiting

```nginx
error_page 429 = @rate_limited;
location @rate_limited {
    default_type application/json;
    add_header Retry-After "20" always;
    return 429 '{"status":"error","message":"Too many requests. Please try again in 20 seconds."}';
}

location ~ ^/api/auth$ {
    limit_req zone=auth_limit burst=2 nodelay;

    default_type application/json;
    add_header Set-Cookie "ms_session=eyJhbGciOiJIUzI1NiJ9.$request_id.sig; Path=/; HttpOnly; Secure; SameSite=Strict" always;
    add_header Set-Cookie "__Host-ms_privacy=ack; Path=/; Secure; SameSite=Strict" always;
    return 401 '{"status":"error","message":"$auth_error_msg"}';
}
```

#### Rate Limiting

```nginx
limit_req zone=auth_limit burst=2 nodelay;
```

- `zone=auth_limit` — uses the zone defined above (`rate=3r/m`)
- `burst=2` — allow a burst of 2 additional requests
- `nodelay` — don't delay burst requests, process them immediately

**Example:**
- Request 1 → OK (within limit)
- Request 2 → OK (burst)
- Request 3 → OK (burst)
- Request 4 → 429 Too Many Requests

#### Fake Cookies

```nginx
add_header Set-Cookie "ms_session=eyJhbGciOiJIUzI1NiJ9.$request_id.sig; Path=/; HttpOnly; Secure; SameSite=Strict" always;
```

- Fake cookie `ms_session` with `$request_id` as the signature
- `HttpOnly` — JavaScript can't read it (XSS protection)
- `Secure` — cookie only sent over HTTPS
- `SameSite=Strict` — cookie not sent on cross-site requests (CSRF protection)

#### Mock Response

```nginx
return 401 '{"status":"error","message":"$auth_error_msg"}';
```

- Always returns 401 Unauthorized
- `$auth_error_msg` — variable from the `map` above, depends on the first character of `$request_id`

### 4.9. Mock API: Protected Endpoints

```nginx
location ~ ^/api/files(/.*)?$ {
    default_type application/json;
    return 401 '{"status":"error","message":"Authorization required"}';
}

location ~ ^/api/users(/.*)?$ {
    default_type application/json;
    return 401 '{"status":"error","message":"Authorization required"}';
}
```

`^/api/files(/.*)?$` matches:
- `/api/files`
- `/api/files/`
- `/api/files/document.pdf`
- `/api/files/images/photo.jpg`

Always returns 401 — simulating a protected route requiring authentication.

### 4.10. Mock API: Settings

```nginx
location ~ ^/api/settings$ {
    default_type application/json;
    return 200 '{"status":"ok","lang":"ru","theme":"auto","notifications":true,"two_factor":false,"storage":{"used":2847193600,"total":10737418240},"last_login":"2026-04-10T18:32:07Z"}';
}
```

Returns mock user settings: language, theme, notifications, two-factor auth, storage quota (2.8 GB out of 10 GB used).

### 4.11. Heartbeat Endpoint

```nginx
location = /heartbeat {
    default_type application/json;
    return 200 '{"ok":true,"ts":$msec}';
}
```

- `$msec` — current time in milliseconds (nginx variable)
- Availability monitoring, health checks from a load balancer

**Example response:** `{"ok":true,"ts":1712950000123}`

### 4.12. PHP-FPM Proxy

```nginx
location ~ \.php$ {
    root /usr/share/nginx/html;
    fastcgi_pass php-fpm:9000;
    fastcgi_index index.php;
    fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    include fastcgi_params;
    fastcgi_hide_header X-Powered-By;
}
```

**How FastCGI works:**

1. Request to `/status.php` hits this `location` (regex `\.php$`)
2. `fastcgi_pass php-fpm:9000` — nginx connects to the PHP-FPM container on port 9000
3. `fastcgi_param SCRIPT_FILENAME` — tells PHP-FPM which file to execute
4. `include fastcgi_params` — standard FastCGI parameters (REQUEST_METHOD, QUERY_STRING, etc.)
5. PHP-FPM executes the PHP script and returns the result to nginx
6. Nginx adds security headers and serves to the client

### 4.13. Blocking Sensitive Paths

```nginx
location ~ ^/(?:\.ht.*|\.git.*|\.env.*|data/|config/|lib/|3rdparty/) {
    return 404;
}
```

Blocks access to files that **should never be publicly accessible**:

| Pattern | What it protects |
|---------|-----------------|
| `\.ht.*` | `.htaccess`, `.htpasswd` |
| `\.git.*` | `.git/config`, `.git/HEAD` (repository leak) |
| `\.env.*` | `.env` files with secrets |
| `data/` | Data directory |
| `config/` | Configuration files |
| `lib/` | Libraries |
| `3rdparty/` | Third-party code |

**Why 404, not 403?** 403 = "Forbidden" — tells the attacker "the file exists but you can't access it". 404 = "Not Found" — the attacker doesn't even know if the file exists.

---

## Part 5. index.html Breakdown — The Frontend

### 5.1. Page Structure

```
index.html
├── <head>
│   ├── meta tags (viewport, description, PWA)
│   ├── SVG favicon (inline data URI)
│   ├── Google Fonts (Inter)
│   └── <style> (all styles, no external CSS)
├── <body>
│   ├── .bg-planet (planet background at the bottom)
│   ├── #canvas-container (Three.js 3D background)
│   ├── #login-container (login form overlaying 3D)
│   │   ├── logo-wrapper (logo + "MySphere")
│   │   ├── form-wrapper
│   │   │   └── #form-card (glassmorphism card)
│   │   │       ├── CSRF token (hidden field)
│   │   │       ├── user input
│   │   │       ├── password input
│   │   │       └── submit button
│   │   └── footer-bar (text + version)
│   └── <script> (all logic)
```

**Key point:** all CSS and JS inline, no external dependencies except:
- Google Fonts (Inter)
- Three.js r128 (CDN: cdnjs.cloudflare.com)

### 5.2. Health Check on Load

```javascript
(function checkHealth() {
    fetch('/api/status', { method: 'GET', cache: 'no-store' })
        .then(r => r.json())
        .then(data => {
            if (data.online && !data.maintenance) {
                console.log('[MySphere] Server ready — v' + data.version);
            }
        })
        .catch(() => {
            console.warn('[MySphere] Status check failed — offline mode');
        });
})();
```

IIFE (Immediately Invoked Function Expression) — runs as soon as the script loads.

1. `fetch('/api/status')` — GET request to the mock API
2. `cache: 'no-store'` — don't use cache (always a fresh request)
3. `.then(r => r.json())` — parse JSON
4. If `online: true` and `maintenance: false` — log to console
5. On network error — warning "offline mode"

### 5.3. CSRF Token Generation

```javascript
(function generateCSRFToken() {
    var array = new Uint8Array(32);
    crypto.getRandomValues(array);
    var token = 'ms-' + Array.from(array).map(function(b) {
        return b.toString(16).padStart(2, '0');
    }).join('');
    document.getElementById('requesttoken').value = token;
})();
```

1. `new Uint8Array(32)` — array of 32 random bytes
2. `crypto.getRandomValues(array)` — cryptographically secure generator (not `Math.random`)
3. Convert each byte to hex (`toString(16)`) with leading zero (`padStart(2, '0')`)
4. Concatenate with prefix `ms-`
5. Insert into hidden field `#requesttoken`

### 5.4. Form Submission (Real POST Request)

```javascript
document.getElementById('login-form').addEventListener('submit', function(e) {
    e.preventDefault();

    const btn = document.getElementById('submit-btn');
    const originalHTML = btn.innerHTML;
    const user = document.getElementById('user').value;
    const password = document.getElementById('password').value;
    const token = document.getElementById('requesttoken').value;

    // Show loading spinner
    btn.innerHTML = '<svg>...spinner...</svg>';

    // Real POST to /api/auth
    fetch('/api/auth', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ user: user, pass: password, token: token })
    })
    .then(r => {
        if (r.status === 429) {
            return r.json().then(data => {
                btn.innerHTML = originalHTML;
                alert(data.message || 'Too many attempts. Please try again in a minute.');
                throw new Error('Rate limited');
            });
        }
        return r.json();
    })
    .then(data => {
        btn.innerHTML = originalHTML;
        // Shake animation on the card
        const card = document.getElementById('form-card');
        card.classList.remove('shake-animation');
        void card.offsetWidth; // force reflow (restart animation)
        card.classList.add('shake-animation');
        // Clear password field
        document.getElementById('password').value = '';
        document.getElementById('password').focus();
    })
    .catch(err => {
        if (err.message === 'Rate limited') return;
        btn.innerHTML = originalHTML;
        // ... same shake animation
    });
});
```

**Step by step:**

1. **`e.preventDefault()`** — prevent default form submission (page reload)
2. **Save** the current button content to restore after the request
3. **Replace the button** with an SVG spinner using `animation: spin 1s linear infinite`
4. **Send `POST /api/auth`** with JSON body: `{user, pass, token}`
5. **Handle 429:** if rate limited — show `alert` with the message from the server response
6. **Handle 401:** in any case (server always returns 401) — shake the card, clear password, refocus
7. **`void card.offsetWidth`** — hack to restart CSS animation. Without it, re-adding the `shake-animation` class won't work (the browser sees the class was already there and doesn't re-animate)

### 5.5. Three.js: 3D Background

#### Gradient Texture (scene background)

```javascript
function createGradientTexture() {
    const canvas = document.createElement('canvas');
    canvas.width = 1024;
    canvas.height = 1024;
    const context = canvas.getContext('2d');

    const gradient = context.createRadialGradient(512, 0, 0, 512, 0, 1024);
    gradient.addColorStop(0.0, '#14b8a6');
    gradient.addColorStop(0.4, '#0d9488');
    gradient.addColorStop(0.8, '#0f766e');
    gradient.addColorStop(1.0, '#042f2e');

    context.fillStyle = gradient;
    context.fillRect(0, 0, 1024, 1024);

    const texture = new THREE.CanvasTexture(canvas);
    texture.colorSpace = THREE.SRGBColorSpace;
    texture.mapping = THREE.EquirectangularReflectionMapping;
    return texture;
}
```

Create a 1024×1024 canvas, draw a radial gradient in teal palette, convert to Three.js texture. Used as `scene.background`.

#### Environment Map (reflections)

Environment map — a texture used for **reflections** on 3D objects. The sphere on the scene will reflect these light spots, creating a realistic effect.

#### Shaders: Light Rays

```glsl
fragmentShader: `
    varying vec2 vUv;
    uniform float time;
    uniform vec3 uColor;

    float hash(vec2 p) {
        return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
    }

    float noise(vec2 p) {
        vec2 i = floor(p);
        vec2 f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
                   mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
    }

    void main() {
        float rays = 0.0;
        float angle = atan(vUv.y - 0.5, vUv.x - 0.5);
        // ... generate rays via sin(angle * N + time)
        // ... overlay noise for organic look
        gl_FragColor = vec4(uColor, rays * 0.15);
    }
`
```

**What is a shader?** A program that runs on the GPU for every pixel (fragment shader) or every vertex (vertex shader).

- `hash()` — pseudo-random function based on `sin(dot(...))` — a standard GLSL trick
- `noise()` — Value Noise (interpolation of neighboring cell hashes) — creates a "cloudy" texture
- `atan(vUv.y - 0.5, vUv.x - 0.5)` — angle from center — used to create radial rays
- `sin(angle * N + time)` — N rays rotating over time
- `gl_FragColor` — final pixel color with transparency `rays * 0.15`

#### Sphere Animation (CPU-side)

```javascript
function updateClouds(time) {
    const noise = createNoise3D();
    cloudMeshes.forEach(mesh => {
        const positions = mesh.geometry.attributes.position.array;
        const originalPositions = mesh.userData.originalPositions;

        for (let i = 0; i < positions.length; i += 3) {
            const ox = originalPositions[i];
            const oy = originalPositions[i + 1];
            const oz = originalPositions[i + 2];

            const n = noise(ox * 0.5, oy * 0.5, oz * 0.5, time * 0.3);
            const displacement = n * 0.08;

            positions[i]     = ox + ox * displacement;
            positions[i + 1] = oy + oy * displacement;
            positions[i + 2] = oz + oz * displacement;
        }

        mesh.geometry.attributes.position.needsUpdate = true;
        mesh.geometry.computeVertexNormals();
    });
}
```

Every frame:
1. Compute 3D noise for each vertex of the sphere
2. Displace the vertex along its radial direction by noise × 0.08
3. `needsUpdate = true` — tell Three.js that geometry has changed
4. `computeVertexNormals()` — recalculate normals for proper lighting

**Result:** the sphere "breathes" — its surface smoothly deforms like a cloud or a planet with atmosphere.

#### Render Loop

```javascript
function animate() {
    requestAnimationFrame(animate);

    const time = clock.getElapsedTime();

    cloudGroup.rotation.y = time * 0.05;
    updateClouds(time);
    rayMaterial.uniforms.time.value = time;

    renderer.render(scene, camera);
}

animate();
```

`requestAnimationFrame` — browser calls the function before each repaint (usually 60 fps).

---

## Part 6. status.php Breakdown

```php
<?php
header('Content-Type: application/json; charset=utf-8');
header('X-Powered-By: MySphere/2.4.8');
http_response_code(200);

echo json_encode([
    'online' => true,
    'maintenance' => false,
    'version' => '2.4.8',
    'build' => '2026.03.15',
    'product' => 'MySphere',
    'api' => '1.0',
]);
```

Duplicates the nginx `/api/status` endpoint. Used if:
- You need to verify PHP-FPM is working (via nginx: `GET /status.php`)

---

## Part 7. Hands-On Exercises

### Exercise 1: Add a new mock endpoint

**Task:** Add `GET /api/profile` returning a user profile.

**Solution** — add to `nginx.conf`:

```nginx
location ~ ^/api/profile$ {
    default_type application/json;
    add_header X-Request-Id "$request_id" always;
    return 200 '{"status":"ok","user":"demo","email":"demo@example.com","role":"user","created":"2025-01-15T10:00:00Z"}';
}
```

### Exercise 2: Change rate limiting

**Task:** Increase `/api/auth` limit to 10 requests/minute with burst=5.

**Solution:**

```nginx
limit_req_zone $binary_remote_addr zone=auth_limit:10m rate=10r/m;
```

And in the location:

```nginx
limit_req zone=auth_limit burst=5 nodelay;
```

### Exercise 3: Add a redirect for unauthenticated users

**Task:** Redirect `/admin` to `/` with an error message.

**Solution:**

```nginx
location ~ ^/admin {
    return 302 '/?error=access_denied';
}
```

### Exercise 4: Handle 404 for unmapped API endpoints

**Task:** All requests to `/api/*` that don't match specific locations should return 404.

**Solution** — at the end of the server block (before the closing `}`):

```nginx
location ^~ /api/ {
    default_type application/json;
    return 404 '{"status":"error","message":"Endpoint not found"}';
}
```

`^~` — prefix match priority over regex. If a request starts with `/api/` and didn't match a more specific `location ~` — this block fires.

---

## Part 8. Self-Check Questions

1. **What's the difference between `return 200 '...'` and `proxy_pass`?**
2. **Why do we need `burst=2 nodelay` in rate limiting?**
3. **Why do we use `void card.offsetWidth` before adding the animation class?**
4. **Which header protects against clickjacking?**
5. **Why `server_tokens off`?**
6. **How does nginx know which container to connect to with `fastcgi_pass php-fpm:9000`?**
7. **Why is 404 better than 403 for blocking sensitive paths?**
8. **What does `try_files $uri $uri/ /index.html` do?**

---

## Part 9. Answers

1. **`return`** — nginx generates the response from the config itself. **`proxy_pass`** — nginx forwards the request to an external backend and returns its response.
2. **`burst`** — allows temporarily exceeding the limit (a queue of extra requests). **`nodelay`** — don't delay them, process immediately. Without nodelay, burst requests would queue up and wait for the rate limit to free.
3. **Force reflow** — the browser "forgets" the previous animation application. Without this trick, re-adding the class won't restart the CSS animation.
4. **`X-Frame-Options: SAMEORIGIN`** — blocks iframe embedding from other domains.
5. **Hiding nginx version** — removes the version number from the `Server:` header. Makes it harder to search for known vulnerabilities for a specific version.
6. **Docker DNS** — Docker runs a built-in DNS server in bridge networks. The service name `php-fpm` resolves to the container's IP automatically.
7. **404** doesn't confirm the file exists. **403** says "file exists but no access" — that's useful info for an attacker.
8. **Tries to serve a file → directory → fallback to index.html.** This lets SPAs handle all routes on the client side.

---

## Part 10. Cheat Sheet: Mock API Patterns

| Pattern | Nginx Directive | Example |
|---------|----------------|---------|
| Simple GET | `return 200 '{...}'` | Health check, server status |
| Auth error | `return 401 '{...}'` | Mock auth endpoint |
| Rate limit response | `error_page 429 = @name` | Custom JSON for 429 |
| Redirect | `return 301 URL` | HTTP → HTTPS |
| Dynamic content | Nginx variables (`$request_id`, `$msec`) | Unique IDs in responses |
| Varying errors | `map $var $msg` | Different error messages |
| Fake cookies | `add_header Set-Cookie "..."` | Mock session cookies |
| Catch-all for a path | `return 401/404` | Protected routes |

---

**Summary:** Mock API at the Nginx level is a powerful technique that lets frontend developers work independently without waiting for the backend. You control every header, every status code, every byte of the response body — and all of this without a single line of server-side code.

---

[🔝 В начало](#mysphere--урок-mock-api-в-nginx-полный-разбор-проекта) | [🇷🇺 Русская часть](#-часть-1-зачем-нужен-mock-api)
