<!-- file: QWEN.md v1.0 -->
# myfakesite — MySphere Fake Login Portal

## Project Overview

**myfakesite** — это имитация облачного портала аутентификации "MySphere" (v2.4.8), развёртываемая через Docker. Проект представляет собой одностраничное приложение (SPA) с 3D-анимацией фона (Three.js), формой логина и набором API-эндпоинтов, которые возвращают заглушки (mock responses) вместо реальной аутентификации.

**Основная цель:** демонстрация/тестирование внешнего вида и поведения веб-портала с имитацией API-ответов на уровне nginx/PHP.

**Репозиторий:** https://github.com/iqubik/myfakesite

### Архитектура

```
┌─────────────────────────────────────┐
│  nginx:alpine (fakesite, порт 80/443)│
│  ├── index.html (SPA + Three.js)    │
│  ├── nginx.conf (mock API routes)   │
│  ├── status.php → php-fpm           │
│  └── phpinfo.php → php-fpm          │
└──────────────┬──────────────────────┘
               │ fastcgi
┌──────────────▼──────────────────────┐
│  php:8.3-fpm-alpine (fakesite-php)  │
│  ├── status.php (JSON health)       │
│  └── phpinfo.php                    │
└─────────────────────────────────────┘
```

### Ключевые особенности

- **3D-фон** — Three.js r128: сфера с логотипом, световые лучи (GLSL-шейдеры), градиентный фон в teal-палитре
- **Glassmorphism UI** — полупрозрачная карточка логина с backdrop-filter blur
- **SPA-роутинг** — `try_files` в nginx перенаправляет все запросы на `index.html`
- **Mock API** — все `/api/*` эндпоинты возвращают статические JSON-ответы напрямую из nginx (без бэкенда):
  - `GET /api/status` — health check (200)
  - `POST /api/auth` — всегда 401 с varying ошибками (зависит от `$request_id` префикса)
  - `GET /api/files/*` — 401 "Требуется авторизация"
  - `GET /api/users/*` — 401 "Требуется авторизация"
  - `GET /api/settings` — 200 с моковыми настройками
- **Rate limiting** — `/api/auth` ограничен 3 запросами/мин (burst=2)
- **CSRF-токен** — генерируется на клиенте через `crypto.getRandomValues`
- **Security headers** — CSP, HSTS, X-Frame-Options, X-Content-Type-Options, Referrer-Policy и др.
- **SSL/TLS** — сертификаты Let's Encrypt (пути в docker-compose заглушечные: `YOUDOMEN.XXX`)

## Technologies

| Компонент | Технология |
|-----------|-----------|
| Web-сервер | nginx:alpine |
| PHP | php:8.3-fpm-alpine |
| Frontend | Vanilla JS + Three.js r128 (CDN) |
| Шрифты | Google Fonts (Inter) |
| Оркестрация | Docker Compose |
| SSL | Let's Encrypt (подразумевается) |

## Building and Running

### Запуск

```bash
docker compose up -d
```

Сервис будет доступен на портах **80** (HTTP → редирект на HTTPS) и **443** (HTTPS).

### Остановка

```bash
docker compose down
```

### Логи

```bash
docker compose logs -f fakesite
docker compose logs -f php-fpm
```

### Предварительные требования

1. **SSL-сертификаты:** в `docker-compose.yml` пути к сертификатам содержат заглушку `YOUDOMEN.XXX`. Перед запуском замените на реальные пути или закомментируйте SSL-строки для HTTP-режима.
2. **Домен:** в `nginx.conf` замените `YOUDOMEN.XXX` на ваш реальный домен.
3. Docker и Docker Compose v2+.

## Resource Limits

| Сервис | CPU | Memory |
|--------|-----|--------|
| fakesite (nginx) | 0.25 | 64M |
| php-fpm | 0.1 | 32M |

## Key Files

| Файл | Описание |
|------|----------|
| `docker-compose.yml` | Определение сервисов (nginx + php-fpm), volumes, сети, лимиты ресурсов |
| `nginx.conf` | Конфигурация nginx: SSL, mock API-эндпоинты, rate limiting, security headers, SPA-роутинг |
| `index.html` | Единственная страница: 3D-фон (Three.js), форма логина, клиентская логика отправки формы |
| `status.php` | PHP-скрипт, возвращающий JSON со статусом сервера (дублирует nginx /api/status) |
| `phpinfo.php` | Стандартный phpinfo() для отладки |
| `robots.txt` | Запрет индексации `/api/`, `/admin/`, `/internal/` |
| `favicon.ico` / `apple-touch-icon.png` | Иконки приложения |

## Development Notes

- **Нет реального бэкенда** — вся "аутентификация" имитируется: nginx всегда возвращает 401 с моковыми сообщениями об ошибках
- **Нет базы данных** — проект полностью stateless
- **Varying auth errors** — сообщения об ошибках зависят от hex-префикса `$request_id` (0-3: "Пользователь не найден", 4-7: "Неверный пароль", и т.д.)
- **Моковые куки** — при POST /api/auth устанавливаются фейковые `ms_session` и `__Host-ms_privacy`
- **X-Powered-By** — подделан как `MySphere/2.4.8`
- **Стиль кода** — vanilla JS (ES5-совместимый синтаксис в index.html), Three.js модуль через CDN
