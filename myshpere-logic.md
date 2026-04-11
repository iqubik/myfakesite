# MySphere — Application Logic

## Request Routing Architecture

```mermaid
flowchart TD
  Client["🌐 Браузер"] -->|"HTTP :80"| Redirect["nginx :80\nreturn 301 → https://"]
  Client -->|"HTTPS :443"| Router["nginx SSL terminator\nTLSv1.2/1.3\nsecurity headers pipeline"]

  Redirect -->|"301"| Client

  Router --> PathMatch{"URI path\nmatching"}

  PathMatch -->|"/"| SPA["SPA location /\nroot /usr/share/nginx/html\ntry_files → /index.html"]
  PathMatch -->|"/api/status"| Health["GET /api/status\nreturn 200 JSON\nX-Powered-By: MySphere/2.4.8"]
  PathMatch -->|"/api/auth"| Auth["POST /api/auth\nlimit_req: 3r/min, burst=2\nreturn 401 JSON"]
  PathMatch -->|"/api/files"| Files["GET /api/files/*\nreturn 401\nТребуется авторизация"]
  PathMatch -->|"/api/users"| Users["GET /api/users/*\nreturn 401\nТребуется авторизация"]
  PathPath -->|"/api/settings"| Settings["GET /api/settings\nreturn 200 JSON\nнастройки пользователя"]
  PathMatch -->|"/heartbeat"| Heartbeat["GET /heartbeat\nreturn 200 JSON\n{ok:true, ts:msec}"]
  PathMatch -->|"/robots.txt"| Robots["GET /robots.txt\nreturn 200 text/plain\nDisallow: /api/, /admin/, /internal/"]
  PathMatch -->|"/.well-known/security.txt"| SecTxt["GET /.well-known/security.txt\nreturn 200\nContact: admin@DOMAIN"]
  PathMatch -->|"/.well-known/*"| WellKnown404["GET /.well-known/*\nreturn 404"]
  PathMatch -->|"/favicon.ico"| Favicon["GET /favicon.ico\nroot: cache 30d immutable"]
  PathMatch -->|"/apple-touch-icon.png"| TouchIcon["GET /apple-touch-icon.png\nroot: cache 30d immutable"]
  PathMatch -->|"*.php"| PHP["~ \\.php$\nfastcgi_pass php-fpm:9000\nSCRIPT_FILENAME → /usr/share/nginx/html"]
  PathMatch -->|"sensitive paths"| Block["~ ^/(\\.ht|\\.git|\\.env|data|config|lib|templates)\nreturn 404"]

  SPA -->|"index.html"| Client
  Health -->|"JSON":| Client
  Auth -->|"JSON 401":| Client
  Files -->|"JSON 401":| Client
  Users -->|"JSON 401":| Client
  Settings -->|"JSON 200":| Client
  Heartbeat -->|"JSON 200":| Client
  Robots -->|"text/plain":| Client
  SecTxt -->|"text/plain":| Client
  WellKnown404 -->|"404"| Client
  Favicon -->|"static file":| Client
  TouchIcon -->|"static file":| Client
  PHP -->|"PHP output":| Client
  Block -->|"404"| Client
```

## API Endpoints — Mock Responses

```mermaid
flowchart LR
  subgraph 200_OK [200 OK — успешные]
    S1["/api/status\n{online:true,\n maintenance:false,\n version:2.4.8,\n product:MySphere}"]
    S2["/api/settings\n{status:ok,\n lang:ru, theme:auto,\n storage:{used:2.8GB,\n total:10GB}}"]
    S3["/heartbeat\n{ok:true,\n ts:$msec}"]
  end

  subgraph 401_Unauthorized [401 Unauthorized — mock отказа]
    A1["/api/auth\n{status:error,\n message:varied\n по $request_id}"]
    A2["/api/files/*\n{status:error,\n message:Требуется\n авторизация}"]
    A3["/api/users/*\n{status:error,\n message:Требуется\n авторизация}"]
  end

  subgraph 429_RateLimited [429 Too Many Requests]
    R1["/api/auth (3r/min)\nRetry-After: 20\n{status:error,\n message:Слишком\n много запросов}"]
  end

  subgraph Static [Статические]
    ST1["/robots.txt\nUser-agent: *\nDisallow: /api/"]
    ST2["/.well-known/security.txt\nContact: mailto:\nadmin@DOMAIN"]
    ST3["/index.html\nSPA приложение"]
  end

  S1 --> ClientA
  S2 --> ClientB
  S3 --> ClientC
  A1 --> ClientD
  A2 --> ClientE
  A3 --> ClientF
  R1 --> ClientG
  ST1 --> ClientH
  ST2 --> ClientI
  ST3 --> ClientJ

  ClientA["🌐"]
  ClientB["🌐"]
  ClientC["🌐"]
  ClientD["🌐"]
  ClientE["🌐"]
  ClientF["🌐"]
  ClientG["🌐"]
  ClientH["🌐"]
  ClientI["🌐"]
  ClientJ["🌐"]
```

## Auth Error Variation (по $request_id)

```mermaid
flowchart TD
  Req["POST /api/auth\nnginx генерирует\n$request_id (hex)"] --> FirstByte{"Первый байт\n$request_id"}

  FirstByte -->|"0-3"| E1["Пользователь\nне найден."]
  FirstByte -->|"4-7"| E2["Неверный\nпароль."]
  FirstByte -->|"8-b"| E3["Аккаунт временно\nзаблокирован."]
  FirstByte -->|"c-f"| E4["Слишком много\nпопыток."]
  FirstByte -->|default| E5["Неверный логин\nили пароль."]

  E1 --> Resp["return 401\n{status:error,\n message:varied}"]
  E2 --> Resp
  E3 --> Resp
  E4 --> Resp
  E5 --> Resp

  Resp --> Cookies["Set-Cookie:\nms_session=eyJhbGciOiJIUzI1NiJ9.$request_id.sig\n__Host-ms_privacy=ack"]
```

## Rate Limiting — State Machine

```mermaid
stateDiagram-v2
  [*] --> Idle: IP первый запрос

  Idle --> Granted: запрос ≤ 3/мин\nбеспроводной доступ
  Idle --> Burst: burst=2\nmgn

  Granted --> Idle: ответ 200/401
  Burst --> Idle: ответ 200/401\n(nodelay)

  Granted --> Exhausted: лимит исчерпан
  Burst --> Exhausted: burst исчерпан

  Exhausted --> RateLimited: следующий запрос
  RateLimited --> Return429: return 429 JSON\nRetry-After: 20

  Return429 --> Cooling: wait 20 сек
  Cooling --> Idle: время прошло\nзапрос снова

  note right of RateLimited
    zone: auth_limit:10m
    rate: 3r/m per IP
    burst: 2 (nodelay)
    status: 429
  end note
```

## Security Headers Pipeline

```mermaid
flowchart TD
  subgraph INPUT [Входящий запрос]
    Req["HTTPS Request\n:443"]
  end

  subgraph TLS [SSL Termination]
    TLS1["TLSv1.2 / TLSv1.3\nHIGH:!aNULL:!MD5\nserver_ciphers on"]
  end

  subgraph HEADERS [Security Headers — каждый ответ]
    H1["X-Content-Type-Options: nosniff"]
    H2["X-Frame-Options: SAMEORIGIN"]
    H3["X-Permitted-Cross-Domain-Policies: none"]
    H4["X-Robots-Tag: noindex, nofollow"]
    H5["X-XSS-Protection: 1; mode=block"]
    H6["Referrer-Policy: no-referrer"]
    H7["Strict-Transport-Security:\nmax-age=15552000;\nincludeSubDomains"]
    H8["Content-Security-Policy:\ndefault-src 'self'\nscript-src 'self' 'unsafe-inline'\n'unsafe-eval' cdnjs.cloudflare.com\nstyle-src 'self' fonts.googleapis.com\nfont-src fonts.gstatic.com\nimg-src self data: blob:\nconnect-src 'self'\nobject-src 'none'\nframe-ancestors 'none'\nbase-uri 'self'"]
  end

  subgraph SERVER [Server header]
    SOff["server_tokens off\nбез версии nginx"]
  end

  Req --> TLS1
  TLS1 --> H1
  H1 --> H2
  H2 --> H3
  H3 --> H4
  H4 --> H5
  H5 --> H6
  H6 --> H7
  H7 --> H8
  H8 --> SOff
  SOff --> Resp["Ответ клиенту\nс полным набором заголовков"]

  style TLS1 fill:#bbf
  style HEADERS fill:#bfb
  style SOff fill:#ffb
```

## Docker Container Topology

```mermaid
flowchart TB
  subgraph HOST [Linux Host]
    subgraph NETWORK [Docker Network: fakesite (bridge)]
      subgraph NGINX_CONTAINER [fakesite (nginx:alpine)]
        N1["nginx:80, :443"]
        N2["ports:\n80:80\n443:443"]
        N3["limits:\nCPU: 0.25\nRAM: 64M"]
      end

      subgraph PHP_CONTAINER [fakesite-php (php:8.3-fpm-alpine)]
        P1["php-fpm:9000"]
        P2["no exposed ports\nonly internal network"]
        P3["limits:\nCPU: 0.1\nRAM: 32M"]
      end

      N1 -->|"fastcgi_pass\nphp-fpm:9000"| P1
    end

    subgraph VOLUMES [Bind Mounts]
      V1["./index.html → /usr/share/nginx/html/index.html :ro"]
      V2["./nginx.conf → /etc/nginx/conf.d/default.conf :ro"]
      V3["./status.php → /usr/share/nginx/html/status.php :ro"]
      V4["./phpinfo.php → /usr/share/nginx/html/phpinfo.php :ro"]
      V5["./favicon.ico → ... :ro"]
      V6["./apple-touch-icon.png → ... :ro"]
      V7["./robots.txt → ... :ro"]
      V8["SSL cert → /etc/nginx/certs/fakesite.crt :ro"]
      V9["SSL key → /etc/nginx/certs/fakesite.key :ro"]
      V10["status.php → php-fpm :ro"]
      V11["phpinfo.php → php-fpm :ro"]
    end

    subgraph CERTS [SSL Certificates]
      C1["/etc/letsencrypt/live/DOMAIN/\nfullchain.pem + privkey.pem\nили self-signed"]
    end
  end

  Internet -->|"HTTP 80\nHTTPS 443"| N2
  C1 -. mount .-> V8
  C1 -. mount .-> V9
  VOLUMES -. volumes .-> NGINX_CONTAINER
  VOLUMES -. volumes .-> PHP_CONTAINER

  style NGINX_CONTAINER fill:#bfb
  style PHP_CONTAINER fill:#bbf
  style VOLUMES fill:#ffb
  style CERTS fill:#fbb
```

## Frontend — SPA Application Flow

```mermaid
flowchart TD
  subgraph LOAD [Загрузка страницы]
    L1["Браузер загружает\nhttps://DOMAIN/index.html"]
    L2["CSS: glassmorphism,\nанимации, responsive"]
    L3["Three.js r128\nimport из cdnjs"]
    L4["Google Fonts: Inter\npreconnect → load"]
  end

  subgraph 3D [Three.js Scene]
    T1["Scene: gradient background\nteal palette (#14b8a6 → #042f2e)"]
    T2["Camera: Perspective 75°\nz = 7.0"]
    T3["Renderer: WebGL,\nACES Filmic tone mapping\npixelRatio: min(devicePixel, 2)"]
    T4["Lighting: ambient + directional\n+ spot + point backLight"]
    T5["Main sphere: r=2.4\nMeshStandardMaterial\nemissive: #042f2e"]
    T6["2 orbiting accents:\nr=0.6, r=0.5"]
    T7["Light rays: custom GLSL shader\nanimated noise displacement"]
    T8["Planet background:\nCSS radial-gradient\nbottom of viewport"]
    T9["Animation loop:\nrequestAnimationFrame\nvertex displacement\nsphere rotation"]
  end

  subgraph FORM [Login Form]
    F1["Glassmorphism card:\nbackdrop-filter blur(60px)\nrgba(0,0,0,0.8)"]
    F2["CSRF Token:\ngenerateCSRFToken()\ncrypto.getRandomValues(32)\nms-{hex}"]
    F3["Inputs:\nuser (username)\npassword (current-password)"]
    F4["Submit button\n→ spinner animation"]
  end

  subgraph AUTH_FLOW [Аутентификация]
    A1["Submit → preventDefault"]
    A2["POST /api/auth\nContent-Type: application/json\n{user, pass, token}"]
    A3["Response: 401\n{status:error, message}"]
    A4["Card shake animation\nvoid offsetWidth → reflow"]
    A5["Clear password field\nfocus() на password"]
    A6["429 Rate Limited\nalert + retry hint"]
  end

  subgraph HEALTH [Health Check]
    H1["IIFE: fetch('/api/status')"]
    H2["online && !maintenance\n→ console.log('Server ready')"]
    H3["catch → console.warn\n'offline mode'"]
  end

  L1 --> L2 --> L3 --> L4 --> T1
  T1 --> T2 --> T3 --> T4 --> T5 --> T6 --> T7 --> T8 --> T9
  T9 --> F1 --> F2 --> F3 --> F4
  F4 --> A1 --> A2
  A2 -->|"401"| A3 --> A4 --> A5
  A2 -->|"429"| A6
  A6 --> A5

  H1 -.独立执行.-> H2
  H1 -.catch.-> H3

  style 3D fill:#ddf
  style FORM fill:#ffd
  style AUTH_FLOW fill:#fdd
  style HEALTH fill:#dfd
```

## Three.js Rendering Pipeline

```mermaid
flowchart LR
  subgraph GEOMETRY [Geometry]
    G1["SphereGeometry(r=2.4,\n64x64 segments)"]
    G2["SphereGeometry(r=0.6,\n64x64 segments)"]
    G3["SphereGeometry(r=0.5,\n64x64 segments)"]
    G4["PlaneGeometry(25x25)\nfor light rays"]
  end

  subgraph MATERIAL [Material]
    M1["MeshStandardMaterial\nroughness:0.85\nmetalness:0.1\nemissive:#042f2e"]
    M2["ShaderMaterial\nvertex: time-based displacement\nfragment: hash noise + ray"]
  end

  subgraph RENDER [Render Loop]
    R1["requestAnimationFrame\nanimate(time)"]
    R2["cloudMeshes.forEach:\nvertex displacement\nnoise3D(x,y,z, time)"]
    R3["rayMaterial.uniforms\ntime.value = time * 0.001"]
    R4["camera.position\nsubtle parallax\n(mouse, optional)"]
    R5["renderer.render\nscene, camera"]
  end

  subgraph LIGHTING [Lights]
    L1["AmbientLight\nintensity: 1.0"]
    L2["DirectionalLight\nintensity: 5.0"]
    L3["SpotLight (ray)\nintensity: 20\nangle: 0.4"]
    L4["PointLight (back)\nintensity: 5\ncolor: #14b8a6"]
  end

  G1 --> M1
  G2 --> M1
  G3 --> M1
  G4 --> M2
  M1 --> R1
  M2 --> R1
  R1 --> R2 --> R3 --> R4 --> R5
  L1 --> R5
  L2 --> R5
  L3 --> R5
  L4 --> R5

  style GEOMETRY fill:#ddf
  style MATERIAL fill:#ffd
  style RENDER fill:#dfd
  style LIGHTING fill:#fdd
```

## SPA Routing — try_files Logic

```mermaid
flowchart TD
  Req["GET /path"] --> IsStatic{"Файл существует\nв /usr/share/nginx/html?"}

  IsStatic -->|Да| ServeFile["Serve static file\nindex.html, .php, .ico, .png, .txt"]
  IsStatic -->|Нет| IsDir{"Директория существует?"}

  IsDir -->|Да| ServeIndex["Serve index.html из\nдиректории"]
  IsDir -->|Нет| Fallback["Serve /index.html\n(SPA fallback)"]

  ServeFile --> MatchAPI{API endpoint?}
  MatchAPI -->|Да| RouteAPI["nginx location match\nreturn mock JSON"]
  MatchAPI -->|Нет| MatchPHP{.php файл?}

  MatchPHP -->|Да| ProxyPHP["fastcgi_pass\nphp-fpm:9000"]
  MatchPHP -->|Нет| ServeStatic["Serve as static file"]

  ServeIndex --> MatchAPI2{API endpoint?}
  MatchAPI2 -->|Да| RouteAPI
  MatchAPI2 -->|Нет| MatchPHP2{.php?}
  MatchPHP2 -->|Да| ProxyPHP
  MatchPHP2 -->|Нет| ServeStatic

  Fallback --> Client["Client receives index.html\nJavaScript handles routing"]

  RouteAPI --> Client
  ProxyPHP --> Client
  ServeStatic --> Client

  style RouteAPI fill:#bfb
  style ProxyPHP fill:#bbf
  style ServeStatic fill:#ffd
```

## Health & Maintenance — PHP vs Mock

```mermaid
flowchart TD
  subgraph MOCK_API [Mock API — nginx]
    M1["GET /api/status\nreturn 200 (nginx)\n{online:true, version:2.4.8}"]
  end

  subgraph PHP_HEALTH [PHP Health Check]
    P1["GET /status.php\nphp-fpm executes\njson_encode([...])"]
  end

  subgraph PHP_DEBUG [PHP Debug]
    P2["GET /phpinfo.php\nphpinfo()\nfull PHP configuration"]
  end

  subgraph HEARTBEAT [Heartbeat]
    H1["GET /heartbeat\nreturn 200 (nginx)\n{ok:true, ts:$msec}"]
  end

  subgraph FRONTEND_CHECK [Frontend Health]
    F1["IIFE on page load:\nfetch('/api/status')\nlog or warn"]
  end

  F1 -->|"fetch"| M1
  M1 -->|"200 JSON"| F2["console.log:\n'MySphere Server ready — v2.4.8'"]
  F1 -->|"error"| F3["console.warn:\n'Status check failed — offline mode'"]

  P1 -. для отладки .-> Ops["Оператор:\nпроверяет PHP-FPM\nи nginx routing"]
  P2 -. для отладки .-> Ops

  H1 -. для мониторинга .-> Monitor["Мониторинг:\nпроверка alive каждые N сек\n$msec = nginx timestamp"]

  style MOCK_API fill:#bfb
  style PHP_HEALTH fill:#bbf
  style PHP_DEBUG fill:#ffb
  style HEARTBEAT fill:#dfd
  style FRONTEND_CHECK fill:#fdd
```

## CSS & Visual Design System

```mermaid
flowchart TD
  subgraph PALETTE [Color Palette]
    C1["#14b8a6 — Teal 500\n(accent, light)"]
    C2["#0d9488 — Teal 600\n(primary)"]
    C3["#0f766e — Teal 700\n(body background)"]
    C4["#042f2e — Teal 950\n(deepest, planet)"]
    C5["#ffffff — White\n(text, borders)"]
    C6["rgba(0,0,0,0.8) — Black glass\n(card backgrounds)"]
  end

  subgraph GLASS [Glassmorphism]
    G1["background: rgba(0,0,0,0.8)\nbackdrop-filter: blur(60px)\nsaturate(120%)"]
    G2["border: 1px solid rgba(255,255,255,0.1)\nborder-radius: 0.5rem\nbox-shadow: 0 8px 32px rgba(0,0,0,0.8)"]
    G3["inputs: rgba(0,0,0,0.85)\nfocus: rgba(0,0,0,0.95)"]
  end

  subgraph ANIMATIONS [Animations]
    A1["@keyframes fadeUp\nopacity 0→1, translateY 20→0\nduration: 0.8s cubic-bezier"]
    A2["@keyframes fadeIn\nopacity 0→1\nduration: 1s ease-out"]
    A3["@keyframes spin\nrotate 0→360°\n1s linear infinite"]
    A4["@keyframes shake\ntranslateX ±4px\n0.4s — error feedback"]
  end

  subgraph PLANET [Planet Background]
    P1["CSS radial-gradient\nbottom: -135vh, left: 50%\nwidth: 250vw, height: 150vh"]
    P2["border-radius: 50%\nbox-shadow: teal glow\nborder-top: 2px rgba(white,0.3)"]
    P3["z-index: 1\npointer-events: none"]
  end

  PALETTE --> GLASS
  GLASS --> ANIMATIONS
  ANIMATIONS --> PLANET
  PLANET --> Canvas["Three.js canvas\nz-index: 0"]
  Canvas --> Login["Login overlay\nz-index: 10\npointer-events: auto"]
  Login --> Footer["Footer bar\nz-index: 20\nversion + branding"]

  style PALETTE fill:#ddf
  style GLASS fill:#ffd
  style ANIMATIONS fill:#dfd
  style PLANET fill:#fdd
```

## Complete Request-Response Lifecycle

```mermaid
sequenceDiagram
  participant U as 👤 User Browser
  participant N as nginx (fakesite)
  participant P as php-fpm (fakesite-php)
  participant FS as File System (bind mounts)
  participant SSL as SSL Certificates

  Note over U,SSL: === HTTPS Request ===
  U->>N: GET https://DOMAIN/ (HTTPS)
  Note over N: SSL termination TLSv1.2+
  N->>SSL: read cert + key
  SSL-->>N: loaded
  N->>FS: try_files / → /index.html
  FS-->>N: index.html (bind mount)
  N->>N: apply security headers<br/>(CSP, HSTS, X-Frame-Options, etc.)
  N-->>U: 200 OK + index.html + headers

  Note over U,SSL: === Page Load ===
  U->>U: parse HTML, load CSS
  U->>U: import Three.js r128 from cdnjs
  U->>U: load Google Fonts (Inter)
  U->>U: render glassmorphism form + planet
  U->>U: init Three.js scene

  Note over U,SSL: === Health Check (IIFE) ===
  U->>N: GET /api/status (XHR)
  N->>N: return 200 JSON mock
  N-->>U: {online:true, version:"2.4.8"}
  U->>U: console.log("Server ready")

  Note over U,SSL: === CSRF Token Generation ===
  U->>U: crypto.getRandomValues(32)
  U->>U: set hidden #requesttoken

  Note over U,SSL: === Login Attempt ===
  U->>U: fill user + password
  U->>N: POST /api/auth<br/>{user, pass, token}
  Note over N: limit_req: check 3r/min<br/>burst=2, nodelay
  N->>N: generate $request_id (hex)
  N->>N: map $request_id → error message
  N->>N: Set-Cookie: ms_session + __Host-ms_privacy
  N-->>U: 401 {status:error, message}
  U->>U: card shake animation
  U->>U: clear password, focus()

  Note over U,SSL: === PHP Health Check (operator) ===
  U->>N: GET /status.php
  N->>P: fastcgi_pass php-fpm:9000
  P->>P: execute status.php
  P-->>N: JSON response
  N->>N: apply security headers
  N-->>U: 200 OK + JSON

  Note over U,SSL: === Heartbeat (monitoring) ===
  Monitor->>N: GET /heartbeat
  N->>N: return 200 {ok:true, ts:$msec}
  N-->>Monitor: 200 OK
```

## Resource Limits & Container Constraints

```mermaid
flowchart TD
  subgraph NGINX [fakesite — nginx:alpine]
    N_CPU["CPU limit: 0.25 cores"]
    N_RAM["Memory limit: 64M"]
    N_PORTS["Ports: 80, 443 (exposed)"]
    N_RESTART["restart: unless-stopped"]
  end

  subgraph PHP [fakesite-php — php:8.3-fpm-alpine]
    P_CPU["CPU limit: 0.1 cores"]
    P_RAM["Memory limit: 32M"]
    P_PORTS["No exposed ports\n(internal network only)"]
    P_RESTART["restart: unless-stopped"]
  end

  subgraph NETWORK [Docker Network]
    NET["fakesite (bridge driver)\ninternal communication\nnginx → php-fpm:9000"]
  end

  NGINX --> NET
  PHP --> NET

  style NGINX fill:#bfb
  style PHP fill:#bbf
  style NETWORK fill:#ffd
```

## File Mount Map — What Goes Where

```mermaid
flowchart LR
  subgraph HOST_FILES [Host Files]
    H1["index.html"]
    H2["nginx.conf"]
    H3["status.php"]
    H4["phpinfo.php"]
    H5["favicon.ico"]
    H6["apple-touch-icon.png"]
    H7["robots.txt"]
    H8["SSL fullchain.pem"]
    H9["SSL privkey.pem"]
  end

  subgraph NGINX_FS [nginx container FS]
    N1["/usr/share/nginx/html/index.html"]
    N2["/etc/nginx/conf.d/default.conf"]
    N3["/usr/share/nginx/html/status.php"]
    N4["/usr/share/nginx/html/phpinfo.php"]
    N5["/usr/share/nginx/html/favicon.ico"]
    N6["/usr/share/nginx/html/apple-touch-icon.png"]
    N7["/usr/share/nginx/html/robots.txt"]
    N8["/etc/nginx/certs/fakesite.crt"]
    N9["/etc/nginx/certs/fakesite.key"]
  end

  subgraph PHP_FS [php-fpm container FS]
    P1["/usr/share/nginx/html/status.php"]
    P2["/usr/share/nginx/html/phpinfo.php"]
  end

  H1 -->|:ro| N1
  H2 -->|:ro| N2
  H3 -->|:ro| N3
  H4 -->|:ro| N4
  H5 -->|:ro| N5
  H6 -->|:ro| N6
  H7 -->|:ro| N7
  H8 -->|:ro| N8
  H9 -->|:ro| N9

  H3 -->|:ro| P1
  H4 -->|:ro| P2

  style HOST_FILES fill:#fdd
  style NGINX_FS fill:#bfb
  style PHP_FS fill:#bbf
```
