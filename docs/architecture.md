<!-- file: architecture.md v1.0 -->
# MySphere fakesite — Architecture & Logic Flow

## Install Pipeline Overview

```mermaid
flowchart TD
  A["install.sh — Оркестратор"] --> B["Phase 1: prereqs.sh"]
  B --> C["Phase 2: domain.sh"]
  C --> D["Phase 3: certs.sh"]
  D --> E["Phase 4: apply.sh"]
  E --> F["Phase 5: start.sh"]

  subgraph INSTALL_ARGS [install.sh аргументы]
    A1["-r репозиторий (по умолчанию: iqubik/myfakesite.git)"]
    A2["-b ветка (по умолчанию: main)"]
    A3["-p директория (по умолчанию: /opt/myfakesite)"]
    A4["-d домен/IP (опц.)"]
    A5["-c cert_path (опц.)"]
    A6["-k key_path (опц.)"]
    A7["-y неинтерактивный режим"]
    A8["-h справка"]
  end

  subgraph EXPORT_CHAIN [Переменные между фазами]
    E1["MODE: http | https-selfsigned | https-domain"]
    E2["DOMAIN: домен, IP или localhost"]
    E3["SSL_CERT_PATH (фаза 3)"]
    E4["SSL_KEY_PATH (фаза 3)"]
    E5["SSL_MODE: user-provided | letsencrypt | self-signed (фаза 3)"]
    E6["COMPOSE_CMD (фаза 1)"]
    E7["NON_INTERACTIVE"]
  end

  INSTALL_ARGS -.->|source| A
  A -.->|export| B
  B -.->|export| C
  C -.->|export| D
  D -.->|export| E
```

## Phase 1 — Prerequisites

```mermaid
flowchart TD
  Start1["root check (EUID == 0)"] --> GitCheck{"git репозиторий\nсуществует?"}

  GitCheck -->|Да| GitPull["git pull origin"]
  GitCheck -->|Нет| Clone["git clone -b branch repo_url dir"]

  GitPull --> FileCheck
  Clone --> FileCheck

  FileCheck{"Ключевые файлы\nсуществуют?"} -->|Да| Done1["OK: docker-compose.yml,\nnginx.conf, index.html"]
  FileCheck -->|Нет| Die1["die: файлы не найдены"]

  style Die1 fill:#f88
  style Done1 fill:#8f8
```

## Phase 2 — Domain & Ports

```mermaid
flowchart TD
  Start2["Определение DOMAIN"] --> ArgCheck{"-d задан?"}

  ArgCheck -->|Да| UseDomain["DOMAIN = -d значение"]
  ArgCheck -->|Нет| NonInt{"NON_INTERACTIVE\ntrue?"}

  NonInt -->|Да| DefaultLocal["DOMAIN = localhost"]
  NonInt -->|Нет| Prompt["read DOMAIN < /dev/tty\nили stdin если -t 0"]

  Prompt --> EnteredEmpty{"DOMAIN\nпустой?"}
  EnteredEmpty -->|Да| DefaultLocal
  EnteredEmpty -->|Нет| UseDomain

  UseDomain --> ModeCheck
  DefaultLocal --> SetHttp["MODE = http"]

  ModeCheck{"DOMAIN тип?"} -->|localhost| SetHttp
  ModeCheck -->|IP (x.x.x.x)| SetSS["MODE = https-selfsigned"]
  ModeCheck -->|домен| SetLE["MODE = https-domain"]

  SetHttp --> PortCheck
  SetSS --> PortCheck
  SetLE --> PortCheck

  PortCheck["Проверка портов 80 и 443\nss -tlnp"] --> PortBusy{"Порт занят?"}

  PortBusy -->|Да| ShowProc["Показать PID + имя процесса"]
  ShowProc --> UserChoice{"Выбор пользователя\n(-y = abort)"}

  UserChoice -->|stop| StopProc["kill процесс"]
  UserChoice -->|continue| Cont["Продолжить (риск конфликта)"]
  UserChoice -->|abort| Abort["die: установка отменена"]

  StopProc --> UFWCheck
  Cont --> UFWCheck
  Abort --> Die2["die"]

  PortBusy -->|Нет| UFWCheck

  UFWCheck{"UFW установлен\nИ активен (ufw status)?"} -->|Да| UFWOpen["ufw allow 80/tcp\nufw allow 443/tcp"]
  UFWCheck -->|Нет| Done2["Пропуск UFW"]

  UFWOpen --> Done2

  style Die2 fill:#f88
  style Done2 fill:#8f8
  style Abort fill:#faa
```

## Phase 3 — Certificates

```mermaid
flowchart TD
  Start3["SSL_MODE проверка"] --> HTTPCheck{"MODE == http?"}

  HTTPCheck -->|Да| Done3["SSL_MODE = none\nвозврат (без сертификата)"]
  HTTPCheck -->|Нет| CustomCheck{"-c и -k\nзаданы?"}

  CustomCheck -->|Да| CopyCert["cp cert/key →\n/etc/letsencrypt/live/DOMAIN/"]
  CustomCheck -->|Нет| SelfSignedCheck{"MODE ==\nhttps-selfsigned?"}

  SelfSignedCheck -->|Да| GenSS["openssl req -x509\n-days 365 -subj /CN=DOMAIN\n-addext subjectAltName=IP:DOMAIN"]
  SelfSignedCheck -->|Нет| LECheck{"LE cert уже\nсуществует?"}

  LECheck -->|Да| CheckIssuer{"issuer ==\nLet's Encrypt?"}
  LECheck -->|Нет| CertbotCheck{"certbot\nустановлен?"}

  CheckIssuer -->|Да| UseLE["SSL_MODE = letsencrypt"]
  CheckIssuer -->|Нет| CertbotCheck

  CertbotCheck -->|Да| CertbotReq["certbot certonly --standalone\n-d DOMAIN"]
  CertbotCheck -->|Нет| Fallback["warn: certbot не найден\n→ self-signed fallback"]

  CertbotReq --> LEGen["openssl req -x509\nself-signed"]
  Fallback --> LEGen

  CopyCert --> ValidCheck
  GenSS --> ValidCheck
  UseLE --> ValidCheck
  LEGen --> ValidCheck

  ValidCheck["Проверка срока действия\nopenssl x509 -noout -enddate"] --> Done3b["OK: cert/key готовы\nSSL_MODE = custom|selfsigned|letsencrypt"]

  style Done3 fill:#8f8
  style Done3b fill:#8f8
```

## Phase 4 — Apply Configuration

```mermaid
flowchart TD
  Start4["Загрузка DOMAIN,\nMODE, SSL-переменных"] --> ReplaceDomain["sed YOUDOMEN.XXX → DOMAIN\nв docker-compose.yml\ndata/nginx.conf"]

  ReplaceDomain --> ApplyVersion["Чтение data/VERSION\n→ VERSION_PLACEHOLDER\nв index.html, nginx.conf, status.php"]

  ApplyVersion --> ModeBranch{"MODE?"}

  ModeBranch -->|http| HTTPMode["HTTP-режим"]
  ModeBranch -->|https-selfsigned| HTTPSMode["HTTPS-режим"]
  ModeBranch -->|https-domain| HTTPSMode

  subgraph HTTP_PATH [HTTP-режим]
    H1["Создание nginx-http.conf\n(без listen 443, без ssl,\nбез редиректа 80→443)"]
    H2["docker-compose.yml:\nубрать порт 443:443\nубрать SSL volumes\nзаменить volume на nginx-http.conf"]
    H3["sed YOUDOMEN.XXX → DOMAIN\nв nginx-http.conf"]
    H1 --> H2 --> H3
  end

  subgraph HTTPS_PATH [HTTPS-режим]
    S1["docker-compose.yml:\nобновить пути ssl_certificate\nssl_certificate_key\nна /etc/letsencrypt/live/DOMAIN/"]
    S1
  end

  HTTPMode --> HTTP_PATH
  HTTPSMode --> HTTPS_PATH

  HTTP_PATH --> Done4["OK: конфигурация применена"]
  HTTPS_PATH --> Done4

  style Done4 fill:#8f8
```

## Phase 5 — Start & Verify

```mermaid
flowchart TD
  Start5["cd PROJECT_DIR"] --> ComposeDown["docker compose down\n--remove-orphans"]

  ComposeDown --> ComposeUp["docker compose up -d\n--remove-orphans"]

  ComposeUp --> Wait["check_containers_running\npolling 60s, sleep 2"]

  Wait --> ModeCheck5{"MODE?"}

  ModeCheck5 -->|http| CurlHTTP["curl http://localhost/"]
  ModeCheck5 -->|https| CurlHTTPS["curl -fsSk https://localhost/"]

  CurlHTTP --> HTTPCode{"HTTP code\n200/301/302?"}
  CurlHTTPS --> HTTPCode

  HTTPCode -->|Да| Success["log: Сайт доступен ✓"]
  HTTPCode -->|Нет| Fail["warn: Сайт не отвечает\ndocker compose logs"]

  Success --> SSLModeCheck{"SSL_MODE ==\nletsencrypt?"}

  SSLModeCheck -->|Да| CertbotSetup["mkdir /etc/myfakesite\necho PROJECT_DIR > project_path\nсоздать /etc/cron.d/certbot-fakesite\nwebroot renew 3:00 AM"]
  SSLModeCheck -->|Нет| Summary

  CertbotSetup --> Summary["Сводка:\n- Режим (HTTP/HTTPS)\n- Домен/IP\n- SSL-тип\n- Путь к проекту\n- Команды управления"]

  style Success fill:#8f8
  style Fail fill:#f88
```

## Update Pipeline

```mermaid
flowchart TD
  A["update.sh\n-r repo -b branch -p dir -y"] --> Root["need_root"]
  Root --> ResolveCompose["resolve_compose_cmd"]
  ResolveCompose --> DirCheck{"PROJECT_DIR\nсуществует?"}

  DirCheck -->|Нет| DieU["die: проект не найден"]
  DirCheck -->|Да| GitCheckU{"PROJECT_DIR/.git\nсуществует?"}

  GitCheckU -->|Нет| DieU2["die: используйте install.sh"]
  GitCheckU -->|Да| ConfirmY{"-y задан\nили y/n?"}

  ConfirmY -->|Нет| ExitUpd["exit 1: отменено"]
  ConfirmY -->|Да| GitUpdate["git remote set-url\ngit fetch origin branch\ngit checkout branch\ngit merge --ff-only FETCH_HEAD"]

  GitUpdate --> VersionCheck{"data/VERSION\nсуществует?"}

  VersionCheck -->|Да| BumpVer["_bump_version()\nтекущая → новая версия"]
  VersionCheck -->|Нет| Restart

  BumpVer --> Restart["docker compose up -d\n--remove-orphans --force-recreate"]

  Restart --> CheckContainers["check_containers_running\n(polling 60s)"]

  CheckContainers --> AllUp{"Все контейнеры\nзапущены?"}

  AllUp -->|Нет| LogsFail["warn: docker compose logs\ndie"]
  AllUp -->|Да| VerifyMode{"MODE?\ngrep 'listen 443'\nв docker-compose.yml"}

  VerifyMode -->|HTTPS| CurlHTTPS2["curl -fsSk https://localhost/"]
  VerifyMode -->|HTTP| CurlHTTP2["curl -fsS http://localhost/"]

  CurlHTTPS2 --> CheckCode{"HTTP 200/301/302?"}
  CurlHTTP2 --> CheckCode

  CheckCode -->|Да| CertbotCheck2{"SSL_MODE ==\nletsencrypt и нет\ncertbot-fakesite cron?"}
  CheckCode -->|Нет| WarnU["warn: Сайт не отвечает"]

  CertbotCheck2 -->|Да| CreateCron["Создать certbot cron"]
  CertbotCheck2 -->|Нет| DoneU
  CreateCron --> DoneU["log: MySphere fakesite\nобновлён до branch ✓"]

  style DieU fill:#f88
  style DieU2 fill:#f88
  style ExitUpd fill:#ff8
  style DoneU fill:#8f8
  style LogsFail fill:#f88
```

## Delete Pipeline

```mermaid
flowchart TD
  A["delete.sh\n[-p dir] [-f]"] --> Confirm{"-f задан?\nили\ny/n подтверждение?"}

  Confirm -->|Нет| ExitDel["exit 1: отменено"]
  Confirm -->|Да| RootD["need_root"]

  RootD --> DirCheckD{"PROJECT_DIR\nсуществует?"}

  DirCheckD -->|Нет| WarnD["warn: удалять нечего\nexit 0"]
  DirCheckD -->|Да| CdD["cd PROJECT_DIR"]

  CdD --> DockerCheckD{"docker +\ndocker compose\nустановлены?"}

  DockerCheckD -->|Нет| SkipDocker["warn: пропуск"]
  DockerCheckD -->|Да| ComposeYML{"docker-compose.yml\nсуществует?"}

  ComposeYML -->|Да| ComposeDown["docker compose down\n--volumes --remove-orphans"]
  ComposeYML -->|Нет| WarnNoYML["warn: файл не найден"]

  ComposeDown --> CleanImages
  WarnNoYML --> CleanImages
  SkipDocker --> CleanImages

  CleanImages["docker images | grep\nmyfakesite|fakesite | xargs rmi -f"] --> CleanNetworks["docker network rm\norphan сети (root_fakesite)"]

  CleanNetworks --> CleanTmp["rm -rf /tmp/myfakesite-install"]

  CleanTmp --> RmDir["rm -rf PROJECT_DIR"]

  RmDir --> DoneD["log: MySphere fakesite\nполностью удалён"]

  style ExitDel fill:#ff8
  style WarnD fill:#ff8
  style DoneD fill:#8f8
```

## Complete Project Structure

```mermaid
graph LR
  subgraph ENTRY_POINTS [Точки входа]
    Install["install.sh\nОркестратор фаз"]
    Update["update.sh\nОбновление git + restart"]
    Delete["delete.sh\nУдаление проекта"]
  end

  subgraph INSTALL_PHASES [install/ — фазы]
    P1["phase1-prereqs.sh\nroot, git, файлы"]
    P2["phase2-domain.sh\ndomain/IP, порты, UFW"]
    P3["phase3-certs.sh\ncustom/LE/self-signed"]
    P4["phase4-apply.sh\nYOUDOMEN.XXX → DOMAIN"]
    P5["phase5-start.sh\ncompose up, curl check"]
  end

  subgraph PROJECT_FILES [Файлы проекта]
    DC["docker-compose.yml\nnginx + php-fpm"]
    NC["nginx.conf\nHTTPS server"]
    NC_HTTP["nginx-http.conf\nHTTP (создаётся в фазе 4)"]
    IDX["index.html"]
    PHP["phpinfo.php, status.php"]
  end

  Install --> P1 --> P2 --> P3 --> P4 --> P5
  P4 -.->|создает| NC_HTTP
  P5 -.->|запускает| DC
  Update -.->|обновляет| DC
  Delete -.->|удаляет| DC

  style Install fill:#bbf
  style Update fill:#bfb
  style Delete fill:#fbb
  style P1 fill:#ddf
  style P2 fill:#ddf
  style P3 fill:#ddf
  style P4 fill:#ddf
  style P5 fill:#ddf
```

## Режимы работы (MODE)

```mermaid
stateDiagram-v2
  [*] --> Определение: install.sh запускается
  Определение --> HTTP: DOMAIN пустой/localhost или -y
  Определение --> SelfSigned: IP-адрес (-d 77.110.125.196)
  Определение --> Domain: домен (-d example.com)

  HTTP --> [*]: curl http://localhost
  SelfSigned --> SelfSignedGen["openssl req -x509\nCN=IP"]
  SelfSignedGen --> [*]: curl -k https://IP
  Domain --> LECheck{"LE cert\nсуществует?"}
  LECheck -->|Да| [*]: curl https://domain
  LECheck -->|Нет| Certbot["certbot certonly\n--standalone"]
  Certbot --> [*]: curl https://domain

  note right of HTTP
    MODE = http
    nginx-http.conf без SSL
    docker-compose: port 80 only
  end note

  note right of SelfSigned
    MODE = https-selfsigned
    openssl req -x509 -days 365
    /etc/letsencrypt/live/IP
    subjectAltName=IP:IP
    port 80 + 443
  end note

  note right of Domain
    MODE = https-domain
    certbot или existing LE cert
    /etc/letsencrypt/live/DOMAIN
    port 80 + 443
  end note
```

## Переменные между фазами (export chain)

```mermaid
sequenceDiagram
  participant I as install.sh
  participant P1 as phase1-prereqs
  participant P2 as phase2-domain
  participant P3 as phase3-certs
  participant P4 as phase4-apply
  participant P5 as phase5-start

  I->>P1: source phase1-prereqs.sh
  P1-->>I: COMPOSE_CMD

  I->>P2: source phase2-domain.sh
  P2-->>I: DOMAIN, MODE, NON_INTERACTIVE

  I->>P3: source phase3-certs.sh
  P3-->>I: SSL_CERT_PATH, SSL_KEY_PATH, SSL_MODE

  I->>P4: source phase4-apply.sh
  P4-->>I: nginx.conf/nginx-http.conf<br/>и docker-compose.yml обновлены

  I->>P5: source phase5-start.sh
  P5-->>I: curl проверка, certbot cron, сводка
```
