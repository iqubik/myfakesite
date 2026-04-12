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
    A1["-r репозиторий (обяз.)"]
    A2["-b ветка (обяз.)"]
    A3["-p директория (/opt/myfakesite)"]
    A4["-d домен (опц.)"]
    A5["-c cert_path (опц.)"]
    A6["-k key_path (опц.)"]
    A7["-h справка"]
  end

  subgraph EXPORT_CHAIN [Переменные между фазами]
    E1["MODE: http | self-signed | letsencrypt"]
    E2["DOMAIN: домен или IP"]
    E3["SSL_CERT_PATH"]
    E4["SSL_KEY_PATH"]
    E5["SSL_MODE: user-provided | letsencrypt | self-signed"]
    E6["COMPOSE_CMD: docker compose / docker-compose"]
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
  Start2["Определение DOMAIN"] --> DomainCheck{"-d задан?"}

  DomainCheck -->|Да| UseDomain["DOMAIN = -d значение"]
  DomainCheck -->|Нет| TryResolve["host -T домен ИЛИ\nhostname -I (IP)"]

  TryResolve --> Resolved{"Домен\nразрешается?"}
  Resolved -->|Да| UseDomain
  Resolved -->|Нет| UseIP["DOMAIN = внешний IP"]

  UseDomain --> ModeCheck
  UseIP --> ModeCheck

  ModeCheck{"SSL-сертификаты\nуказаны (-c/-k)?"} -->|Да| MODE_USER["MODE = http\nSSL_MODE = user-provided"]
  ModeCheck -->|Нет| DomainCheck2{"DOMAIN — это\nдомен (не IP)?"}

  DomainCheck2 -->|Да| MODE_LE["MODE = https\nSSL_MODE = letsencrypt"]
  DomainCheck2 -->|Нет| MODE_SS["MODE = http\nSSL_MODE = self-signed"]

  MODE_USER --> PortCheck
  MODE_LE --> PortCheck
  MODE_SS --> PortCheck

  PortCheck["Проверка портов 80 и 443\nss -tlnp"] --> PortBusy{"Порт занят?"}

  PortBusy -->|Да| ShowProc["Показать PID + имя процесса"]
  ShowProc --> UserChoice{"Выбор пользователя"}

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
  Start3["SSL_MODE проверка"] --> SSLCheck{"SSL_MODE?"}

  SSLCheck -->|user-provided| CustomCert["Копирование cert/key в\n/etc/letsencrypt/live/DOMAIN/"]
  SSLCheck -->|letsencrypt| LECheck{"certbot установлен?"}
  SSLCheck -->|self-signed| SelfSign["openssl req -x509\n-selfsigned\nCN=DOMAIN"]

  LECheck -->|Да| CertbotReq["certbot certonly --standalone\n-d DOMAIN"]
  LECheck -->|Нет| Fallback["warn: certbot не найден\n→ self-signed fallback"]

  CertbotReq --> ValidCheck
  CustomCert --> ValidCheck
  SelfSign --> ValidCheck
  Fallback --> SelfSign

  ValidCheck["Проверка сертификата\nopenssl x509 -noout -dates -issuer"] --> Expired{"Валиден?"}

  Expired -->|Да| Done3["OK: cert/key готовы"]
  Expired -->|Нет| Warn3["warn: сертификат просрочен"]

  style Done3 fill:#8f8
  style Warn3 fill:#ff8
```

## Phase 4 — Apply Configuration

```mermaid
flowchart TD
  Start4["Загрузка DOMAIN,\nMODE, SSL-переменных"] --> ModeBranch{"MODE?"}

  ModeBranch -->|http| HTTPMode["HTTP-режим"]
  ModeBranch -->|https| HTTPSMode["HTTPS-режим"]

  subgraph HTTP_PATH [HTTP-режим]
    H1["Создание nginx-http.conf\n(без listen 443, без ssl)"]
    H2["docker-compose.yml:\nубрать порт 443:443\nубрать SSL volumes"]
    H3["Заменить YOUDOMEN.XXX\n→ DOMAIN в nginx-http.conf\nи docker-compose.yml"]
    H1 --> H2 --> H3
  end

  subgraph HTTPS_PATH [HTTPS-режим]
    S1["Заменить YOUDOMEN.XXX\n→ DOMAIN в nginx.conf\ndocker-compose.yml"]
    S2["Обновить пути ssl_certificate\nssl_certificate_key\ndocker-compose volumes"]
    S1 --> S2
  end

  HTTPMode --> HTTP_PATH
  HTTPSMode --> HTTPS_PATH

  HTTP_PATH --> Backup["Бэкап оригинальных файлов\n*.bak"]
  HTTPS_PATH --> Backup

  Backup --> Done4["OK: конфигурация применена"]

  style Done4 fill:#8f8
```

## Phase 5 — Start & Verify

```mermaid
flowchart TD
  Start5["cd PROJECT_DIR"] --> ComposeUp["docker compose up -d\n--remove-orphans"]

  ComposeUp --> Wait["sleep 5"]
  Wait --> CurlCheck{"curl запрос\nк localhost?"}

  CurlCheck -->|HTTP| CurlHTTP["curl -fsS http://localhost/"]
  CurlCheck -->|HTTPS| CurlHTTPS["curl -fsSk https://localhost/"]

  CurlHTTP --> HTTPCode{"HTTP code\n200/301/302?"}
  CurlHTTPS --> HTTPCode

  HTTPCode -->|Да| Success["log: Сайт доступен ✓"]
  HTTPCode -->|Нет| Fail["warn: Сайт не отвечает\ndocker compose logs"]

  Success --> Summary["Итоговая сводка:\n- Режим (HTTP/HTTPS)\n- Домен/IP\n- SSL-тип\n- Путь к проекту\n- Команды управления"]

  style Success fill:#8f8
  style Fail fill:#f88
```

## Update Pipeline

```mermaid
flowchart TD
  A["update-custom.sh\n-r repo -b branch [-p dir]"] --> Root["need_root"]
  Root --> ResolveCompose["resolve_compose_cmd"]
  ResolveCompose --> Validate{"-r и -b\nзаданы?"}

  Validate -->|Нет| DieU["die"]
  Validate -->|Да| DirCheck{"PROJECT_DIR\nсуществует?"}

  DirCheck -->|Нет| DieU
  DirCheck -->|Да| GitCheckU{"PROJECT_DIR/.git\nсуществует?"}

  GitCheckU -->|Нет| DieU2["die: используйте install.sh"]
  GitCheckU -->|Да| GitUpdate["git remote set-url\ngit fetch origin branch"]

  GitUpdate --> BranchExists{"refs/heads/branch\nсуществует?"}

  BranchExists -->|Да| Merge["git checkout branch\ngit merge --ff-only FETCH_HEAD"]
  BranchExists -->|Нет| NewBranch["git checkout -b branch FETCH_HEAD"]

  Merge --> Restart
  NewBranch --> Restart

  Restart["docker compose up -d\n--remove-orphans --force-recreate"] --> CheckContainers["check_containers_running\n(polling 60s)"]

  CheckContainers --> AllUp{"Все контейнеры\nзапущены?"}

  AllUp -->|Нет| LogsFail["warn: docker compose logs\ndie"]
  AllUp -->|Да| VerifyMode{"HTTPS или HTTP?\ngrep nginx.conf +\ndocker-compose.yml"}

  VerifyMode -->|HTTPS| CurlHTTPS2["curl -fsSk https://localhost/"]
  VerifyMode -->|HTTP| CurlHTTP2["curl -fsS http://localhost/"]

  CurlHTTPS2 --> CheckCode{"HTTP 200/301/302?"}
  CurlHTTP2 --> CheckCode

  CheckCode -->|Да| DoneU["log: Сайт доступен ✓"]
  CheckCode -->|Нет| WarnU["warn: Сайт не отвечает"]

  style DieU fill:#f88
  style DieU2 fill:#f88
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

  CleanImages["docker images | grep\nmyfakesite|fakesite | xargs rmi -f"] --> RmDir["rm -rf PROJECT_DIR"]

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
    Update["update-custom.sh\nОбновление git + restart"]
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
  Определение --> HTTP: нет домена / IP
  Определение --> SelfSigned: IP-адрес без домена
  Определение --> LetsEncrypt: есть домен + certbot

  HTTP --> [*]: curl http://localhost
  SelfSigned --> [*]: curl -k https://localhost
  LetsEncrypt --> [*]: curl -k https://localhost

  note right of HTTP
    nginx-http.conf без SSL
    docker-compose: port 80 only
  end note

  note right of SelfSigned
    openssl req -x509
    /etc/letsencrypt/live/IP
    port 80 + 443
  end note

  note right of LetsEncrypt
    certbot certonly --standalone
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
  P1-->>I: REPO_URL, BRANCH, PROJECT_DIR

  I->>P2: source phase2-domain.sh
  P2-->>I: DOMAIN, MODE, SSL_MODE, COMPOSE_CMD

  I->>P3: source phase3-certs.sh
  P3-->>I: SSL_CERT_PATH, SSL_KEY_PATH, SSL_MODE

  I->>P4: source phase4-apply.sh
  P4-->>I: nginx.conf / nginx-http.conf и docker-compose.yml обновлены

  I->>P5: source phase5-start.sh
  P5-->>I: curl проверка, сводка
```
