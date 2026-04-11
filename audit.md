<!-- file: audit.md v1.0 -->
# Аудит проекта myfakesite

**Дата:** 12 апреля 2026 г.  
**Репозиторий:** https://github.com/iqubik/myfakesite  
**Методология:** Мультиагентный аудит (4 агента: безопасность, качество кода, Docker, nginx)

---

## Оглавление

1. [Аудит безопасности](#1-аудит-безопасности)
2. [Аудит качества кода](#2-аудит-качества-кода)
3. [Аудит Docker-конфигурации](#3-аудит-docker-конфигурации)
4. [Аудит nginx-конфигурации](#4-аудит-nginx-конфигурации)
5. [Сводная таблица всех проблем](#5-сводная-таблица-всех-проблем)
6. [Приоритетные рекомендации](#6-приоритетные-рекомендации)

---

## 1. Аудит безопасности

### 1.1 nginx.conf

#### [HIGH] `unsafe-eval` в Content-Security-Policy

```
script-src 'self' 'unsafe-inline' 'unsafe-eval' https://cdnjs.cloudflare.com;
```

Директива `'unsafe-eval'` разрешает выполнение `eval()`, `new Function()`, `setTimeout(string)`. Это существенно ослабляет CSP и делает XSS-фильтрацию практически бесполезной.

**Рекомендация:** Удалить `'unsafe-eval'`. Three.js r128 работает без него (шейдеры загружаются как строки через GLSL, не через `eval`).

#### [HIGH] `Access-Control-Allow-Origin "*"` на `/.well-known/security.txt`

CORS с wildcard `*` — любой сайт может прочитать ответ через JavaScript. Для публичного файла не критично, но задаёт опасный паттерн.

#### [MEDIUM] XSS через `$request_id` в Set-Cookie

```nginx
add_header Set-Cookie "ms_session=eyJhbGciOiJIUzI1NiJ9.$request_id.sig; Path=/; HttpOnly; Secure; SameSite=Strict" always;
```

Значение `$request_id` не экранируется перед вставкой в HTTP-заголовок. На практике `$request_id` контролируется nginx, но паттерн рискован.

#### [MEDIUM] Information disclosure через varying error messages

```nginx
map $request_id $auth_error_msg {
    "~^[0-3]"  "Пользователь не найден.";
    "~^[4-7]"  "Неверный пароль.";
    "~^[8-b]"  "Аккаунт временно заблокирован...";
    "~^[c-f]"  "Слишком много попыток...";
}
```

Разные сообщения об ошибках позволяют **user enumeration** — определить валидность учётных данных. "Пользователь не найден" vs "Неверный пароль" — классическая уязвимость.

#### [MEDIUM] Rate limiting слишком слабый

`rate=3r/m` — ~4320 запросов/день. Для brute-force медленно, но достаточно для targeted-атаки при наличии varying error messages.

#### [LOW] `X-XSS-Protection` заголовок устарел

Современные браузеры (Chrome удалил в 2020, Firefox никогда не поддерживал). Может вводить в заблуждение.

#### [LOW] Отсутствие `Permissions-Policy`

Нет ограничения доступа к API браузера (камера, микрофон, геолокация).

#### [LOW] Отсутствие `Cross-Origin-Opener-Policy` и `Cross-Origin-Resource-Policy`

Может позволить атаки типа Spectre через cross-origin окна.

---

### 1.2 docker-compose.yml

#### [CRITICAL] SSL-пути-заглушки монтируются как volumes

```yaml
- /etc/letsencrypt/live/YOUDOMEN.XXX/fullchain.pem:/etc/nginx/certs/fakesite.crt:ro
- /etc/letsencrypt/live/YOUDOMEN.XXX/privkey.pem:/etc/nginx/certs/fakesite.key:ro
```

Пути содержат заглушку `YOUDOMEN.XXX`. Если файлы не существуют, контейнер fakesite не запустится (Docker создаст директории вместо файлов, и nginx упадёт).

#### [HIGH] PHP-контейнер без `no-new-privileges` и `read_only`

PHP-контейнер работает от root без ограничений:
- Нет `security_opt: [no-new-privileges:true]`
- Нет `read_only: true`
- Нет `user: "33:33"` (www-data)

#### [MEDIUM] Volume монтирование PHP-файлов — корректно (`:ro` указан)

Оба сервиса монтируют PHP-файлы с `:ro` — это правильно.

#### [LOW] `restart: unless-stopped` без healthcheck

Нет `healthcheck` ни в одном сервисе. Если nginx "зависнет", Docker не перезапустит контейнер.

---

### 1.3 index.html

#### [MEDIUM] Передача учётных данных через `fetch` с `Content-Type: application/json`

Пароль передаётся в поле `pass` (не `password`). CSRF-токен генерируется на клиенте, но **не валидируется на сервере** (nginx mock всегда возвращает 401). CSRF-защита иллюзорна.

#### [MEDIUM] Отсутствие `credentials` флага в fetch-запросе

По умолчанию fetch не отправляет cookies. Cookie будут установлены, но не отправлены обратно.

#### [LOW] `console.log` с информацией о сервере

В production-режиме раскрывает версию продукта в DevTools.

---

### 1.4 PHP файлы

#### [HIGH] `phpinfo.php` — полный disclosure информации о сервере

`phpinfo()` раскрывает:
- Версию PHP и все расширения
- Пути к файлам на сервере
- Переменные окружения
- Конфигурационные директивы

**Рекомендация:** Удалить файл или ограничить доступ по IP.

#### [LOW] `status.php` — дублирует nginx endpoint

Дублирует `/api/status` из nginx, но сам устанавливает `X-Powered-By` (nginx пытается скрыть его через `fastcgi_hide_header`).

---

### 1.5 Shell-скрипты

#### [HIGH] `install.sh` — `kill` процесса на порту 80/443 без достаточной проверки

Скрипт убивает любой процесс на порту 80, включая критичные сервисы (Apache, другой nginx, HAProxy).

#### [HIGH] `install.sh` — `sed -i` на docker-compose.yml без бэкапа

Если `${DOMAIN}` содержит спецсимволы (`/`, `&`, `\`), `sed` может сломать конфиг. Нет валидации `${DOMAIN}` на допустимые символы.

#### [MEDIUM] `install.sh` — certbot с `--register-unsafely-without-email`

Регистрация ACME без email для восстановления.

#### [MEDIUM] `delete.sh` — `rm -rf` без достаточных проверок

Если `${PROJECT_DIR}` окажется пустым или некорректным, `rm -rf` может удалить не тот каталог.

#### [MEDIUM] `update-custom.sh` — `git merge --ff-only` без проверки подписи коммитов

Если репозиторий скомпрометирован, обновление доставит вредоносный код.

---

### 1.6 Дополнительные проблемы безопасности

#### [HIGH] Отсутствие `.gitignore`

Без `.gitignore` в репозиторий могут попасть:
- SSL private keys (`*.key`, `privkey.pem`)
- `.env` файлы с секретами
- Файлы IDE (`.idea/`, `.vscode/`)

#### [MEDIUM] nginx HTTP→HTTPS редирект с `$host` вместо `$server_name`

Может привести к open redirect если злоумышленник контролирует заголовок `Host`.

#### [MEDIUM] Self-signed сертификаты без Subject Alternative Name (SAN)

Современные браузеры (Chrome 58+) игнорируют CN и требуют SAN.

---

## 2. Аудит качества кода

### 2.1 index.html

#### Структура и Best Practices

**Плюсы:**
- Корректный `<!DOCTYPE html>`, `<meta charset="UTF-8">`, viewport
- Three.js загружается как ES-модуль с importmap — современный подход

**Проблемы:**

| Приоритет | Проблема |
|-----------|----------|
| MEDIUM | Inline-обработчики (`onclick="..."`) — антипаттерн, лучше `addEventListener` |
| MEDIUM | Отсутствует `<noscript>` блок — при отключённом JS пользователь увидит только 3D-фон |
| LOW | Скрипт встроен в `<script type="module">` без разделения на модули |

#### Производительность

| Приоритет | Проблема |
|-----------|----------|
| MEDIUM | Нет `preconnect` для `fonts.googleapis.com` и `fonts.gstatic.com` |
| MEDIUM | Нет `&display=swap` для Google Fonts (риск FOIT) |
| LOW | Three.js модули загружаются с разных CDN (unpkg.com, esm.sh) — дополнительные DNS/TLS handshake |

#### Доступность (a11y)

| Приоритет | Проблема |
|-----------|----------|
| **HIGH** | Форма не имеет `<label>`, связанных с полями `<input>`. Placeholder — не замена label |
| MEDIUM | Нет `role="alert"` или `aria-live="polite"` на блоках ошибок |
| MEDIUM | Модальные окна не управляют фокусом — нет focus trap, нет возврата фокуса |
| MEDIUM | Нет `aria-modal="true"` и `role="dialog"` на модальных окнах |
| MEDIUM | Canvas Three.js не имеет `aria-hidden="true"` |
| LOW | Нет skip-link для keyboard navigation |

#### SEO

| Приоритет | Проблема |
|-----------|----------|
| **HIGH** | Нет `<meta name="description">` — критично для SEO |
| HIGH | Нет `<link rel="canonical">` |
| MEDIUM | Нет Open Graph тегов (`og:title`, `og:description`, `og:image`) |
| LOW | Нет `<meta name="theme-color">` для мобильных браузеров

---

### 2.2 nginx.conf — качество кода

#### Gzip сжатие

| Приоритет | Проблема |
|-----------|----------|
| MEDIUM | Нет `gzip_vary on;` — без `Vary: Accept-Encoding` CDN могут кешировать несжатую версию |
| MEDIUM | Нет `gzip_proxied any;` — для fastcgi gzip может не применяться |
| MEDIUM | Нет явного `gzip_min_length` — по умолчанию 20 байт, лучше `256` |
| LOW | `gzip_comp_level` не задан — по умолчанию 1, для CPU-bound сервера можно 4-5 |

#### Кеширование статических ресурсов

| Приоритет | Проблема |
|-----------|----------|
| MEDIUM | `add_header Cache-Control` в location блоке **перезаписывает** security headers из server блока (особенность nginx) |

#### Performance

| Приоритет | Проблема |
|-----------|----------|
| MEDIUM | Нет `open_file_cache` — кеширование файловых дескрипторов ускорит ответ |
| MEDIUM | Нет `client_max_body_size` — по умолчанию 1M, явное указание защитит от неожиданностей |
| LOW | Нет `ssl_session_cache shared:SSL:10m;` — повторные TLS-рукопожатия медленнее |
| LOW | Нет `ssl_prefer_server_ciphers on;` (хотя директива есть, но cipher suite слабый) |

#### Security headers

| Приоритет | Проблема |
|-----------|----------|
| **HIGH** | CSP содержит `https://unpkg.com https://esm.sh https://cdn.jsdelivr.net` в `script-src` — очень широкие источники (supply chain attack risk) |
| **HIGH** | Нет `nonce` или `hash` для inline-скрипта — строгий CSP заблокирует `<script type="module">` |
| MEDIUM | `X-Frame-Options DENY` дублируется CSP `frame-ancestors 'none'` — достаточно одного |
| LOW | Моковые куки без `SameSite` атрибута явно (хотя `__Host-` требует `SameSite=None` по спецификации) |

#### Rate limiting

| Приоритет | Проблема |
|-----------|----------|
| LOW | `limit_req` возвращает 503 по умолчанию, а не 429 — нужен `limit_req_status 429;` (уже есть в конфиге — OK) |

---

### 2.3 docker-compose.yml — качество кода

| Приоритет | Проблема |
|-----------|----------|
| **HIGH** | **Нет healthcheck** ни для одного сервиса |
| MEDIUM | **Нет `depends_on`** с условием healthy |
| MEDIUM | `deploy.resources.limits` работают **только в Docker Swarm mode**. В обычном `docker compose up` игнорируются |
| MEDIUM | SSL-сертификаты замаунчены с заглушкой — если запустить без замены, nginx упадёт |
| LOW | Нет `networks` с явным именем — используется default сеть |
| LOW | Нет `.env` файла или `env_file` директивы — параметры хардкодом |
| LOW | Нет `logging` драйвера с ротацией — логи могут разрастись |

---

### 2.4 PHP файлы — качество кода

#### status.php

| Приоритет | Проблема |
|-----------|----------|
| LOW | Нет `exit;` после `echo json_encode(...)` — если будет добавлен код после, он выполнится |
| LOW | `date()` использует часовой пояс сервера, лучше `gmdate()` или `date_default_timezone_set('UTC')` |
| LOW | `$_SERVER['HTTP_HOST']` может быть подделан клиентом |

#### phpinfo.php

| Приоритет | Проблема |
|-----------|----------|
| **HIGH** | `phpinfo()` раскрывает всю внутреннюю информацию — серьёзная уязвимость в production |
| LOW | Нет проверки IP/авторизации |

---

### 2.5 Shell-скрипты — качество кода

#### install.sh

| Приоритет | Проблема |
|-----------|----------|
| MEDIUM | `git clone --depth 1` — shallow clone, могут быть проблемы с будущими fetch/merge |
| MEDIUM | `check_containers_running` парсит `docker compose ps --format "table ..."` — формат может измениться, лучше `--format json` |
| LOW | Нет `set -x` для дебаг-режима |

#### update-custom.sh

| Приоритет | Проблема |
|-----------|----------|
| MEDIUM | `git merge --ff-only` при fail сообщение не подсказывает решение (`git stash` или `git reset --hard`) |
| MEDIUM | HTTPS_MODE определяется через `grep` по файлам — хрупкий подход |

#### delete.sh

| Приоритет | Проблема |
|-----------|----------|
| MEDIUM | `docker images | grep | xargs` — если grep найдёт что-то неожиданное, удалит чужие образы |
| MEDIUM | `rm -rf "$PROJECT_DIR"` после `cd` — если `$PROJECT_DIR` окажется `/`, будет катастрофа |

---

### 2.6 Общее

#### Code Duplication

| Приоритет | Проблема |
|-----------|----------|
| MEDIUM | Функции `log`, `warn`, `die`, `usage`, `need_root`, `resolve_compose_cmd` дублируются во всех 3 shell-скриптах |

**Рекомендация:** Вынести в `lib.sh` и `source`.

#### Consistency

| Приоритет | Проблема |
|-----------|----------|
| LOW | `update-custom.sh` выбивается из паттерна — должен быть `update.sh` |
| LOW | `deploy.resources.limits` в compose vs standalone — несоответствие |

#### Документация

| Приоритет | Проблема |
|-----------|----------|
| LOW | Дублирование: `readme.txt` vs `README.md` — вероятно одно и то же |
| LOW | Нет `.dockerignore` — в образ попадут `.git`, `.qwen`, ненужные файлы |

---

## 3. Аудит Docker-конфигурации

### 3.1 Версия Compose-файла

Файл начинается с `services:` без `version:`. Это **корректно** для Docker Compose V2 (Compose Specification). Поле `version` считается устаревшим с 2020 года.

**Рекомендация:** Добавить комментарий `# Compose Specification (v2+)` для ясности.

### 3.2 Image tags — плавающие теги

| Сервис | Текущий тег | Проблема |
|--------|------------|----------|
| `fakesite` | `nginx:alpine` | **Плавающий тег** — сегодня nginx 1.27.x, завтра изменится. Невоспроизводимая сборка |
| `php-fpm` | `php:8.3-fpm-alpine` | **Полу-плавающий** — минорные 8.3.x меняются. Лучше фиксировать: `php:8.3.29-fpm-alpine` |

**Рекомендация:** Заменить на конкретные версии с digest:
```yaml
image: nginx:1.27.4-alpine@sha256:...
image: php:8.3.29-fpm-alpine@sha256:...
```

### 3.3 Известные CVE в образах

#### nginx:alpine

| CVE | Severity | Описание |
|-----|----------|----------|
| CVE-2026-32767 | CRITICAL (9.8) | В Alpine-базовом образе |
| CVE-2026-28755 | HIGH | Неправильная авторизация в ngx_stream_ssl_module |
| CVE-2026-32647 | HIGH | Out-of-bounds read в ngx_http_mp4_module |
| CVE-2025-15467 | HIGH (8.8) | В Alpine-библиотеках |

**Митигация:** Многие CVE относятся к модулям, которые не используются (mp4_module, stream_ssl_module). Риск для данного проекта низкий.

#### php:8.3-fpm-alpine

| CVE | Severity | Описание |
|-----|----------|----------|
| CVE-2026-24842 | HIGH (8.2) | В Alpine-базовых пакетах |
| CVE-2026-23745 | HIGH (8.2) | В Alpine-базовых пакетах |
| CVE-2025-49796 | MEDIUM | В PHP 8.3 < 8.3.29 |

**Рекомендация:** Фиксировать версию PHP и регулярно обновлять образы.

### 3.4 Resource Limits

```yaml
# fakesite (nginx)
limits:
  cpus: "0.25"
  memory: 64M

# php-fpm
limits:
  cpus: "0.1"
  memory: 32M
```

| Приоритет | Проблема |
|-----------|----------|
| MEDIUM-HIGH | **`memory: 32M` для php-fpm — критически мало.** PHP-FPM потребляет 25-40МБ на воркер. Возможен OOM-kill |
| MEDIUM | Отсутствуют `reservations` — Docker не гарантирует минимальные ресурсы |
| MEDIUM | `deploy.resources.limits` работают **только в Swarm mode**. В standalone `docker compose` игнорируются |
| LOW | `cpus: "0.1"` для php-fpm — может вызвать заметные задержки |

**Рекомендация:**
```yaml
deploy:
  resources:
    reservations:
      cpus: "0.05"
      memory: 16M
    limits:
      cpus: "0.5"
      memory: 128M
```

### 3.5 Healthchecks — ОТСУТСТВУЮТ (критический недостаток)

**Последствия:**
- `docker compose up -d` возвращает успех до реальной готовности nginx
- `depends_on: [php-fpm]` гарантирует только запуск контейнера, не готовность PHP-FPM
- При падении PHP-FPM nginx продолжит слать запросы (502 Bad Gateway)

**Рекомендация:**
```yaml
# fakesite (nginx)
healthcheck:
  test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost/heartbeat"]
  interval: 30s
  timeout: 5s
  retries: 3
  start_period: 10s

# php-fpm
healthcheck:
  test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:9000/fpm-ping || exit 1"]
  interval: 30s
  timeout: 5s
  retries: 3
  start_period: 15s
```

### 3.6 Restart Policies

```yaml
restart: unless-stopped
```

**Проблема:** При использовании `deploy:` секции Docker Compose рекомендует `deploy.restart_policy` вместо `restart`. При одновременном использовании `restart` может игнорироваться.

**Рекомендация:** Мигрировать на:
```yaml
deploy:
  restart_policy:
    condition: unless-stopped
    delay: 5s
    max_attempts: 3
    window: 120s
```

### 3.7 Volumes

| Приоритет | Проблема |
|-----------|----------|
| MEDIUM | SSL private key монтируется в контейнер — при компрометации контейнера ключ может быть прочитан |
| LOW | Нет volume для логов — логи пишутся в stdout/stderr (правильно для Docker), но нет персистентности на хосте |
| OK | Все bind mounts корректно помечены `:ro` |

### 3.8 Networks

Custom bridge-сеть `fakesite` — правильно. PHP-FPM недоступен напрямую с хоста.

| Приоритет | Проблема |
|-----------|----------|
| LOW | Нет `internal: true` — контейнеры имеют outbound доступ (для nginx это нужно для OCSP stapling) |

### 3.9 Logging — не настроен

По умолчанию `json-file` driver с неограниченным ростом.

**Рекомендация:**
```yaml
logging:
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"
    tag: "{{.Name}}"
```

### 3.10 Security — порты и capabilities

| Приоритет | Проблема |
|-----------|----------|
| MEDIUM | Нет `security_opt: [no-new-privileges:true]` |
| MEDIUM | Нет `cap_drop: ALL` — контейнеры с дефолтными capabilities |
| LOW | Порты привязаны ко всем интерфейсам (`0.0.0.0:80`, `0.0.0.0:443`) |
| LOW | Оба контейнера запускаются от root (дефолтное поведение) |

---

## 4. Аудит nginx-конфигурации

### 4.1 Server blocks

#### HTTP → HTTPS редирект

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name YOUDOMEN.XXX;
    return 301 https://$host$request_uri;
}
```

| Приоритет | Проблема |
|-----------|----------|
| MEDIUM | `$host` вместо `$server_name` — если запрос по IP без Host-заголовка, редирект уйдёт на пустой домен |

### 4.2 SSL/TLS настройки

```nginx
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers HIGH:!aNULL:!MD5;
ssl_prefer_server_ciphers on;
```

| Приоритет | Проблема |
|-----------|----------|
| MEDIUM | Cipher suite `HIGH:!aNULL:!MD5` слишком широкий. Включает устаревшие шифры (CBC, SHA-1) |
| LOW | Отсутствует `ssl_session_cache` и `ssl_session_timeout` — каждая TLS-рукопожатие полная |
| LOW | Нет `ssl_stapling on` (OCSP stapling) |
| LOW | Нет `ssl_dhparam` — DHE-шифры используют стандартные группы |

**Рекомендация (Mozilla Intermediate):**
```nginx
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 1d;
ssl_session_tickets off;
```

### 4.3 Security headers — КРИТИЧЕСКАЯ ПРОБЛЕМА

**Проблема:** В nginx `add_header` в location block **полностью переопределяет** все `add_header` из server block.

Это значит, что в location-блоках API **теряются**:
- `Content-Security-Policy` (CSP)
- `X-XSS-Protection`
- `X-Permitted-Cross-Domain-Policies`

Затронутые location-блоки: `/api/status`, `@rate_limited`, `/api/auth`, `/api/files`, `/api/users`, `/api/settings`, `/.well-known/security.txt`, `.php`.

**Дополнительно:** `X-Frame-Options` в server block = `DENY`, а в location-блоках = `SAMEORIGIN` — несогласованность.

### 4.4 Rate limiting

```nginx
limit_req_zone $binary_remote_addr zone=auth_limit:10m rate=3r/m;
limit_req_status 429;
...
limit_req zone=auth_limit burst=2 nodelay;
```

| Приоритет | Проблема |
|-----------|----------|
| MEDIUM | `rate=3r/m` + `burst=2 nodelay` — до 5 запросов за короткое время, затем 429. Легитимный пользователь с опечатками может упираться в лимит |
| LOW | `zone=auth_limit:10m` — 10MB хранит ~160,000 IP. Для проекта избыточно, `1m` хватило бы |
| LOW | Нет rate limiting на `/api/status`, `/api/files`, `/api/users`, `/api/settings` |

### 4.5 Location blocks — маршрутизация

| Приоритет | Проблема |
|-----------|----------|
| MEDIUM | `location ~ ^/api/status$` → лучше `location = /api/status` (exact match быстрее regex) |
| MEDIUM | Аналогично для `/api/auth`, `/api/settings` |
| MEDIUM | `location ~ ^/api/files(/.*)?$` → лучше `location ^~ /api/files` (prefix с приоритетом) |
| MEDIUM | Несуществующие `/api/*` попадают на `index.html` вместо 404 — нужен catch-all для `/api/` |

**Рекомендация — catch-all для API:**
```nginx
location /api/ {
    return 404 '{"status":"error","message":"Endpoint not found"}';
    add_header Content-Type application/json always;
}
```

### 4.6 PHP-FPM интеграция

```nginx
location ~ \.php$ {
    root /usr/share/nginx/html;
    fastcgi_pass php-fpm:9000;
    fastcgi_index index.php;
    fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    include fastcgi_params;
    fastcgi_hide_header X-Powered-By;
    ...
}
```

| Приоритет | Проблема |
|-----------|----------|
| **CRITICAL** | `include fastcgi_params` стоит **ПОСЛЕ** `fastcgi_param SCRIPT_FILENAME`. В стандартном `fastcgi_params` может быть определён `SCRIPT_FILENAME`, который **перезапишет** вашу строку |
| MEDIUM | Конфликт: `fastcgi_hide_header X-Powered-By` скрывает PHP-версию, но `status.php` сам устанавливает `X-Powered-By: MySphere/2.4.8` |
| LOW | Нет `fastcgi_param HTTPS on;` — PHP может не знать о HTTPS |
| LOW | Нет `fastcgi_read_timeout`, `fastcgi_connect_timeout` — дефолтные 60s |

**Рекомендация:** Поменять порядок:
```nginx
include fastcgi_params;
fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
fastcgi_param HTTPS on;
```

### 4.7 Error pages

```nginx
error_page 500 502 503 504 /50x.html;
location = /50x.html {
    root /usr/share/nginx/html;
}
```

| Приоритет | Проблема |
|-----------|----------|
| MEDIUM | `50x.html` **не примонтирован** в docker-compose.yml! При 500/502/503/504 nginx вернёт дефолтную страницу Alpine или 404 |
| LOW | Нет кастомной страницы для 404 |

### 4.8 Logging

| Приоритет | Проблема |
|-----------|----------|
| MEDIUM | **Полностью отсутствуют** явные `access_log` и `error_log` директивы |
| LOW | Нет кастомного `log_format` — нельзя логировать `$request_id`, `$auth_error_msg` |
| LOW | Нет `access_log off;` для статики (favicon, apple-touch-icon) — лишние записи |

**Рекомендация:**
```nginx
access_log /var/log/nginx/access.log combined;
error_log /var/log/nginx/error.log warn;
```

### 4.9 Performance

| Приоритет | Проблема |
|-----------|----------|
| MEDIUM | Отсутствует `gzip` сжатие — `index.html` содержит Three.js-код, без gzip передача медленнее |
| LOW | Нет `keepalive_timeout` — дефолтное 75s, для портала достаточно 15-30s |
| LOW | Нет `client_max_body_size` — дефолт 1m |
| LOW | `index.html` не имеет заголовков кэширования — SPA должен кэшироваться минимально |

**Рекомендация:**
```nginx
gzip on;
gzip_types text/css application/javascript application/json image/svg+xml;
gzip_min_length 256;
gzip_vary on;
```

### 4.10 Mock API endpoints

| Приоритет | Проблема |
|-----------|----------|
| LOW | Cookie устанавливаются даже при 401 — создают иллюзию аутентификации |
| LOW | Два `Set-Cookie` заголовка — nginx поддерживает множественные, корректно |
| OK | `map $request_id $auth_error_msg` — элегантное решение varying ошибок |
| OK | `/heartbeat` с `$msec` — живое значение, не моковое |

### 4.11 try_files для SPA

```nginx
try_files $uri $uri/ /index.html;
```

**Оценка:** Корректно — стандартный паттерн для SPA. Но нет разделения между API и SPA-роутингом (см. 4.5).

---

## 5. Сводная таблица всех проблем

### Критические (CRITICAL) — 2

| # | Раздел | Проблема | Файл |
|---|--------|----------|------|
| 1 | Безопасность | SSL-заглушки в volumes — контейнер не запустится | docker-compose.yml |
| 2 | nginx | `include fastcgi_params` после `SCRIPT_FILENAME` может переопределить его | nginx.conf |

### Высокие (HIGH) — 11

| # | Раздел | Проблема | Файл |
|---|--------|----------|------|
| 3 | Безопасность | `unsafe-eval` в CSP | nginx.conf |
| 4 | Безопасность | `phpinfo.php` — полный disclosure | phpinfo.php |
| 5 | Безопасность | `kill` процесса на порту 80 без проверки | install.sh |
| 6 | Безопасность | `sed -i` без валидации DOMAIN | install.sh |
| 7 | Безопасность | Отсутствие `.gitignore` | проект |
| 8 | Качество | Нет `<label>` для input'ов формы | index.html |
| 9 | Качество | Нет `<meta name="description">` | index.html |
| 10 | Качество | CSP может заблокировать inline module script | nginx.conf |
| 11 | Качество | CSP — широкие CDN источники (supply chain) | nginx.conf |
| 12 | Docker | Нет healthcheck ни для одного сервиса | docker-compose.yml |
| 13 | Docker | Плавающие image tags (`nginx:alpine`) | docker-compose.yml |

### Средние (MEDIUM) — 25

| # | Раздел | Проблема | Файл |
|---|--------|----------|------|
| 14 | Безопасность | Varying error messages (user enumeration) | nginx.conf |
| 15 | Безопасность | PHP-контейнер без security_opt/read_only | docker-compose.yml |
| 16 | Безопасность | CSRF-защита иллюзорна | index.html |
| 17 | Безопасность | certbot без email | install.sh |
| 18 | Безопасность | `rm -rf` без проверок | delete.sh |
| 19 | Безопасность | HTTP→HTTPS redirect с `$host` | nginx.conf |
| 20 | Качество | Security headers теряются в location блоках | nginx.conf |
| 21 | Качество | Нет gzip_vary, gzip_proxied | nginx.conf |
| 22 | Качество | `deploy.resources.limits` не работают в standalone | docker-compose.yml |
| 23 | Качество | Дублирование функций в shell-скриптах | install/update/delete.sh |
| 24 | Качество | Нет `depends_on` с condition: healthy | docker-compose.yml |
| 25 | Качество | `memory: 32M` для php-fpm — риск OOM | docker-compose.yml |
| 26 | Качество | `50x.html` не примонтирован | docker-compose.yml |
| 27 | Docker | Нет logging с ротацией | docker-compose.yml |
| 28 | Docker | Нет `security_opt` / `cap_drop` | docker-compose.yml |
| 29 | nginx | Cipher suite слишком широкий | nginx.conf |
| 30 | nginx | Rate limiting слишком жёсткий (3r/m) | nginx.conf |
| 31 | nginx | Regex location где можно exact/prefix | nginx.conf |
| 32 | nginx | Несуществующие `/api/*` → index.html вместо 404 | nginx.conf |
| 33 | nginx | Нет явного логирования | nginx.conf |
| 34 | nginx | Нет gzip сжатия | nginx.conf |
| 35 | nginx | Конфликт `fastcgi_hide_header` с PHP | nginx.conf |
| 36 | nginx | SSL session cache отсутствует | nginx.conf |
| 37 | a11y | Нет `role="alert"` / `aria-live` на ошибках | index.html |
| 38 | a11y | Модальные окна без focus trap | index.html |

### Низкие (LOW) — 22

| # | Раздел | Проблема | Файл |
|---|--------|----------|------|
| 39-60 | Различные | X-XSS-Protection устарел, нет Permissions-Policy, нет COOP/CORP, console.log, shallow clone, нет .dockerignore, дублирование документации, и др. | различные |

---

## 6. Приоритетные рекомендации

### 🔴 Исправить немедленно (1-3 день)

| # | Действие | Файлы | Сложность |
|---|----------|-------|-----------|
| 1 | **Удалить `phpinfo.php`** или ограничить доступ по IP (`allow 127.0.0.1; deny all;`) | phpinfo.php, nginx.conf | 5 мин |
| 2 | **Поменять порядок** `include fastcgi_params` и `fastcgi_param SCRIPT_FILENAME` | nginx.conf | 2 мин |
| 3 | **Продублировать security headers** (CSP, X-XSS-Protection, X-Permitted-Cross-Domain-Policies) во все API location-блоки | nginx.conf | 15 мин |
| 4 | **Добавить `.gitignore`** с правилами для `*.key`, `*.pem`, `.env`, `*.log`, `.idea/`, `.vscode/` | .gitignore | 5 мин |
| 5 | **Удалить `unsafe-eval`** из CSP | nginx.conf | 2 мин |
| 6 | **Добавить healthcheck** для обоих сервисов + `depends_on: condition: service_healthy` | docker-compose.yml | 10 мин |

### 🟡 Исправить в ближайшее время (1-2 недели)

| # | Действие | Файлы | Сложность |
|---|----------|-------|-----------|
| 7 | **Зафиксировать версии образов** (nginx:1.27.4-alpine, php:8.3.29-fpm-alpine) | docker-compose.yml | 5 мин |
| 8 | **Увеличить memory limit php-fpm** до 128M | docker-compose.yml | 2 мин |
| 9 | **Добавить logging с ротацией** (max-size: 10m, max-file: 3) | docker-compose.yml | 5 мин |
| 10 | **Сузить cipher suite** до Mozilla Intermediate | nginx.conf | 5 мин |
| 11 | **Добавить gzip сжатие** | nginx.conf | 5 мин |
| 12 | **Добавить API catch-all** для возврата 404 на неизвестные эндпоинты | nginx.conf | 5 мин |
| 13 | **Заменить regex location на exact/prefix** | nginx.conf | 10 мин |
| 14 | **Добавить `<meta name="description">` и `<label>`** к форме | index.html | 10 мин |
| 15 | **Добавить `security_opt` и `cap_drop`** в docker-compose | docker-compose.yml | 5 мин |
| 16 | **Вынести общие функции** shell-скриптов в `lib.sh` | install/update/delete.sh | 30 мин |

### 🟢 Оптимизация (по возможности)

| # | Действие | Файлы |
|---|----------|-------|
| 17 | Добавить SSL session cache, OCSP stapling | nginx.conf |
| 18 | Добавить `preconnect` для Google Fonts | index.html |
| 19 | Добавить `<noscript>` fallback | index.html |
| 20 | Добавить a11y атрибуты (aria-label, role="dialog", focus trap) | index.html |
| 21 | Добавить Open Graph теги | index.html |
| 22 | Добавить `.dockerignore` | .dockerignore |
| 23 | Удалить `readme.txt` (дублирует README.md) | readme.txt |
| 24 | Переименовать `update-custom.sh` → `update.sh` | update-custom.sh |
| 25 | Добавить SAN при генерации self-signed сертификатов | install.sh |
| 26 | Добавить валидацию DOMAIN в install.sh | install.sh |
| 27 | Заменить `kill` процесса на предупреждение | install.sh |
| 28 | Использовать `--filter` вместо `grep | xargs` в delete.sh | delete.sh |

---

## Общая оценка проекта

| Категория | Оценка | Комментарий |
|-----------|--------|-------------|
| **Безопасность** | ⚠️ 4/10 | phpinfo.php, unsafe-eval, нет .gitignore, user enumeration |
| **Качество кода** | ✅ 6/10 | Хорошая структура, но нет a11y, SEO, дублирование скриптов |
| **Docker** | ⚠️ 5/10 | Нет healthcheck, limits не работают, плавающие теги |
| **nginx** | ⚠️ 5/10 | Headers теряются в location, нет gzip, weak ciphers |
| **Документация** | ✅ 7/10 | README, TUTORIAL, architecture — хорошо, но дублирование |

**Итого:** Проект функционален для своей цели (демо/фейковый портал), но требует доработки в области безопасности и production-ready конфигурации.
