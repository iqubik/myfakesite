<!-- file: README.md v1.0 -->

[🇷🇺 Русский](#-русский) | [🇬🇧 English](#-english)

---

# MySphere — Учебный проект: Mock API & Frontend

> **Mock API Usage Tutorial** — как имитировать бэкенд на уровне Nginx для разработки и тестирования фронтенда без реального сервера.

---

## 🇷🇺 Русский

### Что это?

<img width="2560" height="1000" alt="2026-04-13_16-12-57" src="https://github.com/user-attachments/assets/9ed3ea55-884c-4ba5-af3b-78577efeec93" />

---

Учебный проект, демонстрирующий подход **Mock API** — техника, при которой frontend-разработчик имитирует ответы сервера прямо на уровне конфигурации Nginx, без написания бэкенда и без базы данных.

Идея проста: вам нужно сделать красивый одностраничный сайт с формой входа, 3D-анимацией и API-эндпоинтами, но **реальный сервер пока не готов**. Вместо того чтобы ждать, вы настраиваете Nginx так, чтобы он возвращал заранее заготовленные JSON-ответы. Фронтенд работает как с настоящим API — отправляет запросы, получает ответы, обрабатывает ошибки.

### Чему учит этот проект

1. **Mock API на уровне Nginx** — `return 200`, `return 401`, `return 429` вместо `proxy_pass`. Все эндпоинты (`/api/status`, `/api/auth`, `/api/files`, `/api/settings`) отвечают заглушками, но фронтенд этого «не знает» и работает штатно.

2. **SPA-роутинг** — `try_files $uri $uri/ /index.html` — классический паттерн для клиентских приложений, где все маршруты обрабатывает JavaScript.

3. **Rate Limiting** — `limit_req_zone` и `limit_req` для имитации защиты от брутфорса. Nginx сам считает запросы и возвращает `429 Too Many Requests`.

4. **Security Headers** — CSP, HSTS, X-Frame-Options, X-Content-Type-Options, Referrer-Policy — полный набор заголовков безопасности, настроенных один раз и применяемых ко всем ответам.

5. **Docker Compose** — минимальная инфраструктура: Nginx + PHP-FPM, каждый с ограничениями по CPU и памяти.

6. **3D-графика в браузере** — Three.js (r128), GLSL-шейдеры, градиентные текстуры, освещение — всё на клиенте, без серверной части.

### Зачем это нужно

- **Быстрый прототип.** За `docker compose up -d` — у вас рабочий сайт с HTTPS, формой и API.
- **Отладка фронтенда.** Не нужен бэкенд — мокируют ответ, тестируют UI/UX.
- **Портфолио.** Показываете: вот как выглядит сайт, вот как он себя ведёт, вот какие заголовки безопасности.
- **Обучение.** Каждая секция `nginx.conf` — это мини-урок: rate limiting, mock JSON, SPA-роутинг, SSL-терминация.

### Структура

```
├── docker-compose.yml   # Nginx + PHP-FPM, лимиты ресурсов
├── install.sh           # Скрипт установки
├── update.sh            # Скрипт обновления
├── delete.sh            # Скрипт удаления
├── data/
│   ├── nginx.conf       # Mock API, security headers, rate limiting
│   ├── index.html       # SPA: Three.js 3D-фон + форма логина
│   ├── status.php       # PHP health check (дубль /api/status)
│   ├── phpinfo.php      # Отладка PHP
│   ├── favicon.ico      # Иконка сайта
│   ├── apple-touch-icon.png
│   └── robots.txt       # SEO: Disallow /api/, /admin/, /internal/
└── install/
    ├── phase*.sh        # Фазы установки
    └── certbot-renew-hook.sh  # Хук обновления сертификатов
```

### Запуск

#### ⚡ Быстрая установка (одной командой)

> Это **опциональный** способ. Если предпочитаете ручной запуск — просто `git clone` и `docker compose up -d` (см. ниже).

```
# Интерактивный режим (скрипт задаст вопросы)
curl -fsSL https://raw.githubusercontent.com/iqubik/myfakesite/main/install.sh | sudo bash
```

```bash
# HTTP-режим, localhost (молча, без вопросов)
curl -fsSL https://raw.githubusercontent.com/iqubik/myfakesite/main/install.sh | sudo bash -s -- -y

# С доменом и HTTPS (Let's Encrypt, молча)
curl -fsSL https://raw.githubusercontent.com/iqubik/myfakesite/main/install.sh | sudo bash -s -- -d fakesite.example.com -y

# С self-signed сертификатом (по IP, молча)
curl -fsSL https://raw.githubusercontent.com/iqubik/myfakesite/main/install.sh | sudo bash -s -- -d 192.168.1.100 -y

```

Флаг `-y` — полностью автоматическая установка без вопросов. Если порты 80/443 заняты — установка прервётся с ошибкой. Без `-y` скрипт предложит варианты действий.

> **Требования:** Linux-сервер с `curl`. Скрипт сам установит Docker, Docker Compose и настроит всё остальное. Запускается от **root**.

#### ⚡ Обновление (одной командой)

```bash
# Обновить до последней версии
curl -fsSL https://raw.githubusercontent.com/iqubik/myfakesite/main/update.sh | sudo bash -s -- -y

# Обновить до конкретной ветки/репозитория
curl -fsSL https://raw.githubusercontent.com/iqubik/myfakesite/main/update.sh | sudo bash -s -- -r https://github.com/iqubik/myfakesite.git -b main -y
```

> Обновление находит проект в `/opt/myfakesite` (или укажите `-p /путь`). Работает из любой директории.

#### Ручная установка

```bash
docker compose up -d
```

Перед запуском замените `YOUDOMEN.XXX` в `docker-compose.yml` и `nginx.conf` на ваш домен и укажите пути к SSL-сертификатам (или закомментируйте SSL-секции для HTTP-режима).

<img width="2560" height="1000" alt="2026-04-13_16-13-58" src="https://github.com/user-attachments/assets/eb587eb5-8cfe-474d-bf59-ec831df19971" />

### 📖 Уроки и документация

Полный подробный разбор — **[TUTORIAL.md →](docs/TUTORIAL.md)**.

Там вы найдёте:
- Детальный разбор каждой строки `nginx.conf`, `docker-compose.yml` и `index.html`
- Объяснение Mock API, rate limiting, security headers
- 3D-графику: Three.js, GLSL-шейдеры, анимация вершин
- Практические упражнения с решениями
- Контрольные вопросы для самопроверки
- Шпаргалку по mock API-паттернам

### 🛠 Установка, обновление, удаление

В проекте есть три скрипта для управления жизненным циклом на Linux-сервере (запуск от **root**):

#### Установка

```bash
# Базовая установка (HTTP-режим, localhost)
sudo ./install.sh

# С доменом и HTTPS (Let's Encrypt или self-signed сертификат)
sudo ./install.sh -d fakesite.example.com

# Полная команда: свой репозиторий, ветка, домен, папка
sudo ./install.sh \
  -r https://github.com/me/myfakesite.git \
  -b my-branch \
  -d demo.example.com \
  -p /opt/myfakesite
```

**Что делает `install.sh`:**
- Клонирует репозиторий (или обновляет если уже есть)
- Запрашивает домен (или берёт из `-d`)
- Настраивает nginx: подставляет домен, SSL или HTTP-режим
- Если SSL нет — предложит HTTP-режим или self-signed сертификат
- При домене и Let's Encrypt — устанавливает certbot, получает сертификат, настраивает **авто-обновление** (cron ежедневно в 3:00)
- Запускает контейнеры через Docker Compose

#### Обновление

```bash
# Обновить до последней версии
sudo ./update.sh

# Обновить до конкретной ветки/репозитория
sudo ./update.sh -r https://github.com/iqubik/myfakesite.git -b main

# Обновить из своего форка
sudo ./update.sh \
  -r https://github.com/me/myfakesite.git \
  -b feature-branch
```

**Что делает `update.sh`:**
- Сохраняет текущий домен из конфигурации (до git-обновления)
- Fetch + merge из указанного ветки (или `reset --hard` при конфликтах)
- Восстанавливает домен в `docker-compose.yml` и `data/nginx.conf`
- Подставляет версию из `data/VERSION`
- Перезапускает контейнеры
- Проверяет что все контейнеры запустились
- Проверяет доступность сайта через curl

#### Удаление

```bash
# С подтверждением
sudo ./delete.sh

# Без подтверждения (force)
sudo ./delete.sh -f

# Из другой папки
sudo ./delete.sh -p /opt/myfakesite -f
```

#### ⚡ Удаление (одной командой)

```bash
# Без подтверждения (force)
curl -fsSL https://raw.githubusercontent.com/iqubik/myfakesite/main/delete.sh | sudo bash -s -- -f
```

**Что делает `delete.sh`:**
- `docker compose down --volumes --remove-orphans`
- Удаляет Docker-образы проекта
- `rm -rf` директории проекта

> **Важно:** `delete.sh` **не трогает** `/etc/letsencrypt/`, cron-задания и другие системные файлы — сертификаты и настройки остаются на сервере.

#### Параметры скриптов

| Параметр | Скрипты | Описание |
|----------|---------|----------|
| `-r <url>` | install, update | Git URL репозитория |
| `-b <branch>` | install, update | Ветка |
| `-p <path>` | все | Папка проекта (по умолчанию `/opt/myfakesite`) |
| `-d <domain>` | install | Домен для nginx (пустой = localhost, HTTP) |
| `-c <path>` | install | Путь к кастомному SSL-сертификату |
| `-k <path>` | install | Путь к кастомному SSL-ключу |
| `-f` | delete | Без подтверждения |
| `-h` | все | Показать справку

---

## 🇬🇧 English

### What is this?

An educational project demonstrating the **Mock API** approach — a technique where a frontend developer simulates server responses directly in the Nginx configuration, without writing backend code or setting up a database.

The concept is simple: you want to build a polished single-page application with a login form, 3D animations, and API endpoints, but **the real backend isn't ready yet**. Instead of waiting, you configure Nginx to return pre-canned JSON responses. The frontend works exactly as it would with a real API — sending requests, receiving responses, handling errors.

### What this project teaches

1. **Mock API at the Nginx level** — `return 200`, `return 401`, `return 429` instead of `proxy_pass`. All endpoints (`/api/status`, `/api/auth`, `/api/files`, `/api/settings`) respond with stubs, but the frontend "doesn't know" and operates normally.

2. **SPA routing** — `try_files $uri $uri/ /index.html` — the classic pattern for client-side applications where all routes are handled by JavaScript.

3. **Rate limiting** — `limit_req_zone` and `limit_req` to simulate brute-force protection. Nginx counts requests per IP and returns `429 Too Many Requests` automatically.

4. **Security headers** — CSP, HSTS, X-Frame-Options, X-Content-Type-Options, Referrer-Policy — a full security header suite, configured once and applied to all responses.

5. **Docker Compose** — minimal infrastructure: Nginx + PHP-FPM, each with CPU and memory limits.

6. **3D graphics in the browser** — Three.js (r128), GLSL shaders, gradient textures, lighting — all client-side, no server involvement.

### Why this matters

- **Rapid prototyping.** One `docker compose up -d` and you have a working site with HTTPS, a form, and an API.
- **Frontend debugging.** No backend needed — mock the responses, test the UI/UX.
- **Portfolio.** Show how the site looks, how it behaves, what security headers are in place.
- **Education.** Every section of `nginx.conf` is a mini-lesson: rate limiting, mock JSON, SPA routing, SSL termination.

### Structure

```
├── docker-compose.yml   # Nginx + PHP-FPM, resource limits
├── install.sh           # Installation script
├── update.sh            # Update script
├── delete.sh            # Uninstall script
├── data/
│   ├── nginx.conf       # Mock API, security headers, rate limiting
│   ├── index.html       # SPA: Three.js 3D background + login form
│   ├── status.php       # PHP health check (mirror of /api/status)
│   ├── phpinfo.php      # PHP debugging
│   ├── favicon.ico      # Site icon
│   ├── apple-touch-icon.png
│   └── robots.txt       # SEO: Disallow /api/, /admin/, /internal/
└── install/
    ├── phase*.sh        # Installation phases
    └── certbot-renew-hook.sh  # Certificate renewal hook
```

### Running

#### ⚡ Quick Install (one command)

> This is **optional**. If you prefer manual setup — just `git clone` and `docker compose up -d` (see below).

```bash
# HTTP mode, localhost (silent, no prompts)
curl -fsSL https://raw.githubusercontent.com/iqubik/myfakesite/main/install.sh | sudo bash -s -- -y

# With domain and HTTPS (Let's Encrypt, silent)
curl -fsSL https://raw.githubusercontent.com/iqubik/myfakesite/main/install.sh | sudo bash -s -- -d fakesite.example.com -y

# With self-signed certificate (by IP, silent)
curl -fsSL https://raw.githubusercontent.com/iqubik/myfakesite/main/install.sh | sudo bash -s -- -d 192.168.1.100 -y

# Interactive mode (script will ask questions)
curl -fsSL https://raw.githubusercontent.com/iqubik/myfakesite/main/install.sh | sudo bash
```

The `-y` flag — fully automated installation without any prompts. If ports 80/443 are busy, installation will fail with an error. Without `-y`, the script will offer options.

> **Requirements:** Linux server with `curl`. The script installs Docker, Docker Compose and everything else automatically. Runs as **root**.

#### ⚡ Quick Update (one command)

```bash
# Update to latest version
curl -fsSL https://raw.githubusercontent.com/iqubik/myfakesite/main/update.sh | sudo bash -s -- -y

# Update to a specific branch/repo
curl -fsSL https://raw.githubusercontent.com/iqubik/myfakesite/main/update.sh | sudo bash -s -- -r https://github.com/iqubik/myfakesite.git -b main -y
```

> Update finds the project in `/opt/myfakesite` (or specify `-p /path`). Works from any directory.

#### Manual setup

```bash
docker compose up -d
```

Before running, replace `YOUDOMEN.XXX` in `docker-compose.yml` and `nginx.conf` with your actual domain and provide paths to SSL certificates (or comment out the SSL sections for HTTP-only mode).

### 📖 Tutorials & Documentation

Full detailed walkthrough — **[TUTORIAL.md →](docs/TUTORIAL.md)**.

Inside you'll find:
- Line-by-line breakdown of `nginx.conf`, `docker-compose.yml` and `index.html`
- Mock API, rate limiting, security headers explained
- 3D graphics: Three.js, GLSL shaders, vertex animation
- Hands-on exercises with solutions
- Self-check questions
- Mock API patterns cheat sheet

### 🛠 Installation, Update, Uninstallation

The project includes three scripts for lifecycle management on a Linux server (run as **root**):

#### Installation

```bash
# Basic install (HTTP mode, localhost)
sudo ./install.sh

# With domain and HTTPS (Let's Encrypt or self-signed certificate)
sudo ./install.sh -d fakesite.example.com

# Full command: custom repo, branch, domain, path
sudo ./install.sh \
  -r https://github.com/me/myfakesite.git \
  -b my-branch \
  -d demo.example.com \
  -p /opt/myfakesite
```

**What `install.sh` does:**
- Clones the repository (or updates if already present)
- Prompts for domain (or takes from `-d`)
- Configures nginx: substitutes domain, SSL or HTTP mode
- If no SSL — offers HTTP mode or a self-signed certificate
- With domain and Let's Encrypt — installs certbot, obtains certificate, sets up **auto-renewal** (cron daily at 3:00 AM)
- Starts containers via Docker Compose

#### Update

```bash
# Update to latest version
sudo ./update.sh

# Update to a specific branch/repo
sudo ./update.sh -r https://github.com/iqubik/myfakesite.git -b main

# Update from your fork
sudo ./update.sh \
  -r https://github.com/me/myfakesite.git \
  -b feature-branch
```

**What `update.sh` does:**
- Saves current domain from config (before git update)
- Fetch + merge from the specified branch (or `reset --hard` on conflicts)
- Restores domain in `docker-compose.yml` and `data/nginx.conf`
- Applies version from `data/VERSION`
- Restarts containers
- Verifies all containers are running
- Checks site availability via curl

#### Uninstallation

```bash
# With confirmation prompt
sudo ./delete.sh

# Without confirmation (force)
sudo ./delete.sh -f

# From a custom path
sudo ./delete.sh -p /opt/myfakesite -f
```

#### ⚡ Quick Uninstall (one command)

```bash
# Without confirmation (force)
curl -fsSL https://raw.githubusercontent.com/iqubik/myfakesite/main/delete.sh | sudo bash -s -- -f
```

**What `delete.sh` does:**
- `docker compose down --volumes --remove-orphans`
- Removes project Docker images
- `rm -rf` project directory

> **Important:** `delete.sh` does **not** touch `/etc/letsencrypt/`, cron jobs, or other system files — certificates and settings remain on the server.

#### Script Parameters

| Parameter | Scripts | Description |
|-----------|---------|-------------|
| `-r <url>` | install, update | Git repository URL |
| `-b <branch>` | install, update | Branch |
| `-p <path>` | all | Project directory (default: `/opt/myfakesite`) |
| `-d <domain>` | install | Domain for nginx (empty = localhost, HTTP) |
| `-c <path>` | install | Path to custom SSL certificate |
| `-k <path>` | install | Path to custom SSL key |
| `-f` | delete | Force mode (no confirmation) |
| `-h` | all | Show help

---

**License:** MIT

<img width="1476" height="1112" alt="image" src="https://github.com/user-attachments/assets/8bc2036e-357c-4c5e-87b0-bdb85b302e2e" />
