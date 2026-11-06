#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# UNIVERSAL WEBSITE INSTALLER
# Version: 3.0.0
# Ubuntu 22.04 / 24.04, Debian 12
#
# Features:
# - Interactive domain and website settings
# - Nginx installation and configuration
# - Static responsive website generation
# - Optional Let's Encrypt HTTPS
# - Backups and rollback on Nginx errors
# - Diagnostics and update mode
#
# Does NOT modify Docker, RemnaNode, UFW or SSH.
# ============================================================

VERSION="3.0.0"

BASE_DIR="/var/www"
BACKUP_DIR="/var/backups/website-installer"
LOG_DIR="/var/log/website-installer"

DOMAIN=""
SITE_NAME=""
TAGLINE=""
PHONE=""
EMAIL=""
ADDRESS=""
DESCRIPTION=""
SSL="yes"

SITE_DIR=""
NGINX_CONF=""
BACKUP_PATH=""
LOG_FILE=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()      { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()    { echo -e "${RED}[ERROR]${NC} $*" >&2; }

die() {
    fail "$*"
    exit 1
}

# ============================================================
# LOGGING
# ============================================================

mkdir -p "$LOG_DIR" "$BACKUP_DIR"

LOG_FILE="$LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log"
touch "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

# ============================================================
# ERROR HANDLING
# ============================================================

on_error() {
    local code=$?
    fail "Произошла ошибка. Код: $code"
    fail "Журнал: $LOG_FILE"
    exit "$code"
}

trap on_error ERR

# ============================================================
# BASIC CHECKS
# ============================================================

require_root() {
    [[ "$EUID" -eq 0 ]] || die "Запусти скрипт от root: sudo bash install.sh"
}

check_os() {
    [[ -f /etc/os-release ]] || die "Не удалось определить операционную систему."

    # shellcheck disable=SC1091
    source /etc/os-release

    case "${ID:-}" in
        ubuntu|debian) ;;
        *) die "Поддерживаются Ubuntu и Debian. Обнаружено: ${PRETTY_NAME:-unknown}" ;;
    esac

    info "Операционная система: ${PRETTY_NAME:-unknown}"
}

check_disk() {
    local free_mb
    free_mb=$(df -Pm / | awk 'NR==2 {print $4}')

    info "Свободное место: ${free_mb} MB"

    (( free_mb >= 300 )) || die "Недостаточно места на диске."
}

check_commands() {
    command -v apt-get >/dev/null 2>&1 || die "Не найден apt-get."
}

# ============================================================
# INPUT
# ============================================================

ask_value() {
    local prompt="$1"
    local default="${2:-}"
    local answer

    if [[ -n "$default" ]]; then
        read -r -p "$prompt [$default]: " answer
        printf '%s' "${answer:-$default}"
    else
        read -r -p "$prompt: " answer
        printf '%s' "$answer"
    fi
}

html_escape() {
    local s="$1"

    s="${s//&/\&amp;}"
    s="${s//</\&lt;}"
    s="${s//>/\&gt;}"
    s="${s//\"/\&quot;}"
    s="${s//\'/\&#39;}"

    printf '%s' "$s"
}

valid_domain() {
    local d="$1"

    [[ ${#d} -le 253 ]] || return 1

    [[ "$d" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]
}

valid_email() {
    [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

collect_settings() {
    echo
    echo "=========================================="
    echo "       НАСТРОЙКА САЙТА"
    echo "=========================================="
    echo

    while true; do
        DOMAIN=$(ask_value "Введите домен сайта, например example.com")

        DOMAIN="${DOMAIN,,}"
        DOMAIN="${DOMAIN#http://}"
        DOMAIN="${DOMAIN#https://}"
        DOMAIN="${DOMAIN%%/*}"

        if valid_domain "$DOMAIN"; then
            break
        fi

        warn "Неверный формат домена. Попробуй ещё раз."
    done

    SITE_NAME=$(ask_value "Название сайта" "My Website")
    TAGLINE=$(ask_value "Краткий слоган" "Добро пожаловать!")
    PHONE=$(ask_value "Телефон" "+1 000 000 0000")
    EMAIL=$(ask_value "Email" "info@$DOMAIN")
    ADDRESS=$(ask_value "Адрес" "Укажите адрес")
    DESCRIPTION=$(ask_value "Описание сайта" "Добро пожаловать на наш сайт!")

    echo
    echo "Настройка HTTPS:"
    echo "1. Да, получить сертификат Let's Encrypt"
    echo "2. Нет, использовать только HTTP"

    local choice
    choice=$(ask_value "Выбери вариант" "1")

    case "$choice" in
        1) SSL="yes" ;;
        2) SSL="no" ;;
        *) die "Неверный вариант." ;;
    esac

    if [[ "$SSL" == "yes" ]]; then
        while true; do
            CERT_EMAIL=$(ask_value "Email для Let's Encrypt" "$EMAIL")
            valid_email "$CERT_EMAIL" && break
            warn "Укажи корректный email."
        done
    fi

    SITE_DIR="$BASE_DIR/$DOMAIN"
    NGINX_CONF="/etc/nginx/conf.d/website-${DOMAIN//./_}.conf"

    echo
    info "Параметры установки:"
    echo "Домен:       $DOMAIN"
    echo "Название:    $SITE_NAME"
    echo "Каталог:     $SITE_DIR"
    echo "HTTPS:       $SSL"
    echo
}

# ============================================================
# DNS CHECK
# ============================================================

check_dns() {
    info "Проверка DNS..."

    local resolved
    resolved=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u || true)

    if [[ -z "$resolved" ]]; then
        warn "DNS для $DOMAIN не найден."
        warn "Сайт будет установлен, но Let's Encrypt может не выдать сертификат."
        return 1
    fi

    local public_ip
    public_ip=$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)

    echo "DNS IP:"
    echo "$resolved"

    if [[ -n "$public_ip" ]]; then
        echo "IP сервера: $public_ip"

        if ! grep -Fxq "$public_ip" <<< "$resolved"; then
            warn "DNS IP не совпадает с публичным IP сервера."
            warn "Проверь A-запись домена."
            return 1
        fi
    fi

    ok "DNS проверен."
    return 0
}

# ============================================================
# CHECK EXISTING NGINX CONFIG
# ============================================================

check_domain_conflict() {
    info "Проверка конфигураций Nginx..."

    if ! command -v nginx >/dev/null 2>&1; then
        return 0
    fi

    local found=0
    local file

    while IFS= read -r -d '' file; do
        [[ "$file" == "$NGINX_CONF" ]] && continue

        if grep -Fq -- "$DOMAIN" "$file" 2>/dev/null; then
            fail "Домен уже упоминается в конфигурации:"
            fail "$file"
            found=1
        fi
    done < <(
        find /etc/nginx -type f \
            \( -name '*.conf' -o -path '*/sites-enabled/*' \) \
            -print0 2>/dev/null
    )

    if (( found )); then
        die "Конфликт домена. Выбери другой домен или сначала вручную проверь существующий виртуальный хост."
    fi

    ok "Конфликтов не обнаружено."
}

# ============================================================
# CHECK EXISTING SERVICES
# ============================================================

check_services() {
    info "Проверка существующих сервисов..."

    if command -v docker >/dev/null 2>&1; then
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qi remnanode; then
            warn "Обнаружен контейнер RemnaNode."
            warn "Скрипт не будет менять Docker или RemnaNode."
        fi
    fi

    if command -v nginx >/dev/null 2>&1; then
        ok "Nginx уже установлен."
    else
        info "Nginx будет установлен."
    fi
}

# ============================================================
# BACKUP
# ============================================================

make_backup() {
    local stamp
    stamp=$(date +%Y%m%d-%H%M%S)

    BACKUP_PATH="$BACKUP_DIR/$DOMAIN-$stamp"

    mkdir -p "$BACKUP_PATH"

    if [[ -d "$SITE_DIR" ]]; then
        cp -a "$SITE_DIR" "$BACKUP_PATH/site"
        ok "Резервная копия сайта создана."
    fi

    if [[ -f "$NGINX_CONF" ]]; then
        cp -a "$NGINX_CONF" "$BACKUP_PATH/nginx.conf"
        ok "Резервная копия Nginx создана."
    fi

    echo "$BACKUP_PATH" > "$BACKUP_DIR/latest-$DOMAIN.txt"

    ok "Резервная копия: $BACKUP_PATH"
}

# ============================================================
# INSTALL PACKAGES
# ============================================================

install_packages() {
    export DEBIAN_FRONTEND=noninteractive

    info "Обновление списка пакетов..."
    apt-get update

    info "Установка Nginx и необходимых утилит..."
    apt-get install -y \
        nginx \
        curl \
        ca-certificates \
        openssl \
        certbot \
        python3-certbot-nginx

    systemctl enable nginx
    systemctl start nginx

    ok "Пакеты установлены."
}

# ============================================================
# WEBSITE
# ============================================================

create_website() {
    info "Создание сайта..."

    mkdir -p "$SITE_DIR/assets"
    mkdir -p "$SITE_DIR/pages"

    local safe_name
    local safe_tagline
    local safe_phone
    local safe_email
    local safe_address
    local safe_description

    safe_name=$(html_escape "$SITE_NAME")
    safe_tagline=$(html_escape "$TAGLINE")
    safe_phone=$(html_escape "$PHONE")
    safe_email=$(html_escape "$EMAIL")
    safe_address=$(html_escape "$ADDRESS")
    safe_description=$(html_escape "$DESCRIPTION")

    cat > "$SITE_DIR/index.html" <<EOF
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="description" content="$safe_description">
<meta name="theme-color" content="#211a17">
<title>$safe_name</title>
<link rel="stylesheet" href="/assets/style.css">
</head>
<body>

<header class="header">
  <div class="container nav">
    <a class="logo" href="/">$safe_name</a>
    <nav>
      <a href="/">Главная</a>
      <a href="/pages/about.html">О нас</a>
      <a href="/pages/menu.html">Услуги</a>
      <a href="/pages/contact.html">Контакты</a>
    </nav>
  </div>
</header>

<main>
<section class="hero">
  <div class="container hero-content">
    <span class="eyebrow">Добро пожаловать</span>
    <h1>$safe_tagline</h1>
    <p>$safe_description</p>
    <a class="button" href="/pages/contact.html">Связаться с нами</a>
  </div>
</section>

<section class="section">
  <div class="container">
    <span class="eyebrow">О нашем проекте</span>
    <h2>Качество и внимание к деталям</h2>
    <p class="lead">
      Мы стремимся создавать качественный сервис,
      уделяя внимание каждому посетителю.
    </p>
  </div>
</section>

<section class="section cards-section">
  <div class="container cards">
    <article class="card">
      <div class="card-icon">✦</div>
      <h3>Качество</h3>
      <p>Внимание к деталям и высокий уровень обслуживания.</p>
    </article>

    <article class="card">
      <div class="card-icon">♡</div>
      <h3>Забота</h3>
      <p>Мы ценим каждого клиента и его время.</p>
    </article>

    <article class="card">
      <div class="card-icon">✧</div>
      <h3>Уют</h3>
      <p>Создаём приятную атмосферу для каждого гостя.</p>
    </article>
  </div>
</section>

<section class="section contact-preview">
  <div class="container">
    <h2>Будем рады вас видеть</h2>
    <p>$safe_address</p>
    <a class="button" href="/pages/contact.html">Контакты</a>
  </div>
</section>
</main>

<footer class="footer">
  <div class="container footer-inner">
    <span>$safe_name</span>
    <span>© $(date +%Y) Все права защищены</span>
  </div>
</footer>

</body>
</html>
EOF

    cat > "$SITE_DIR/pages/about.html" <<EOF
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>О нас — $safe_name</title>
<link rel="stylesheet" href="/assets/style.css">
</head>
<body>
<header class="header">
<div class="container nav">
<a class="logo" href="/">$safe_name</a>
<nav>
<a href="/">Главная</a>
<a href="/pages/about.html">О нас</a>
<a href="/pages/menu.html">Услуги</a>
<a href="/pages/contact.html">Контакты</a>
</nav>
</div>
</header>
<main class="section page">
<div class="container">
<span class="eyebrow">Наша история</span>
<h1>О нас</h1>
<p class="lead">$safe_description</p>
<p>Наша цель — предложить посетителям качественный сервис,
приятную атмосферу и внимательное отношение.</p>
<a class="button" href="/">На главную</a>
</div>
</main>
<footer class="footer"><div class="container">$safe_name</div></footer>
</body>
</html>
EOF

    cat > "$SITE_DIR/pages/menu.html" <<EOF
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Услуги — $safe_name</title>
<link rel="stylesheet" href="/assets/style.css">
</head>
<body>
<header class="header">
<div class="container nav">
<a class="logo" href="/">$safe_name</a>
<nav>
<a href="/">Главная</a>
<a href="/pages/about.html">О нас</a>
<a href="/pages/menu.html">Услуги</a>
<a href="/pages/contact.html">Контакты</a>
</nav>
</div>
</header>
<main class="section page">
<div class="container">
<span class="eyebrow">Наше предложение</span>
<h1>Услуги</h1>
<div class="cards">
<article class="card"><h3>Основные услуги</h3><p>Добавьте сюда описание ваших услуг.</p></article>
<article class="card"><h3>Индивидуальный подход</h3><p>Расскажите о специальных предложениях.</p></article>
<article class="card"><h3>Связь с нами</h3><p>Мы ответим на ваши вопросы.</p></article>
</div>
</div>
</main>
<footer class="footer"><div class="container">$safe_name</div></footer>
</body>
</html>
EOF

    cat > "$SITE_DIR/pages/contact.html" <<EOF
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Контакты — $safe_name</title>
<link rel="stylesheet" href="/assets/style.css">
</head>
<body>
<header class="header">
<div class="container nav">
<a class="logo" href="/">$safe_name</a>
<nav>
<a href="/">Главная</a>
<a href="/pages/about.html">О нас</a>
<a href="/pages/menu.html">Услуги</a>
<a href="/pages/contact.html">Контакты</a>
</nav>
</div>
</header>
<main class="section page">
<div class="container">
<span class="eyebrow">Свяжитесь с нами</span>
<h1>Контакты</h1>
<div class="card contact-card">
<p><strong>Телефон:</strong> <a href="tel:$safe_phone">$safe_phone</a></p>
<p><strong>Email:</strong> <a href="mailto:$safe_email">$safe_email</a></p>
<p><strong>Адрес:</strong> $safe_address</p>
</div>
</div>
</main>
<footer class="footer"><div class="container">$safe_name</div></footer>
</body>
</html>
EOF

    cat > "$SITE_DIR/assets/style.css" <<'EOF'
:root {
  --bg: #f7f3ed;
  --text: #29231f;
  --muted: #756a61;
  --accent: #a56b42;
  --dark: #211a17;
  --card: #fff;
}

* {
  box-sizing: border-box;
}

html {
  scroll-behavior: smooth;
}

body {
  margin: 0;
  background: var(--bg);
  color: var(--text);
  font-family: Arial, Helvetica, sans-serif;
  line-height: 1.7;
}

a {
  color: inherit;
  text-decoration: none;
}

.container {
  width: min(1120px, 90%);
  margin: 0 auto;
}

.header {
  background: var(--dark);
  color: white;
}

.nav {
  min-height: 76px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 24px;
}

.logo {
  font-size: 22px;
  font-weight: 800;
  letter-spacing: .5px;
}

nav {
  display: flex;
  flex-wrap: wrap;
  gap: 24px;
}

nav a {
  color: #eee4dc;
  font-size: 14px;
}

nav a:hover {
  color: #d6a77e;
}

.hero {
  min-height: 560px;
  display: flex;
  align-items: center;
  color: white;
  background:
    linear-gradient(90deg, rgba(25,18,15,.92), rgba(25,18,15,.55)),
    radial-gradient(circle at 75% 30%, #a56b42, #34231c 65%);
}

.hero-content {
  padding-top: 80px;
  padding-bottom: 80px;
}

.eyebrow {
  color: var(--accent);
  text-transform: uppercase;
  font-size: 12px;
  font-weight: 800;
  letter-spacing: 2px;
}

.hero .eyebrow {
  color: #e0b38e;
}

h1, h2, h3 {
  line-height: 1.2;
}

h1 {
  max-width: 800px;
  font-size: clamp(38px, 7vw, 76px);
  margin: 20px 0;
}

h2 {
  font-size: clamp(28px, 4vw, 42px);
}

.hero p {
  max-width: 620px;
  color: #eee2d8;
  font-size: 18px;
}

.button {
  display: inline-block;
  margin-top: 22px;
  padding: 13px 25px;
  background: var(--accent);
  color: white;
  border-radius: 5px;
  font-weight: 700;
}

.button:hover {
  background: #855332;
}

.section {
  padding: 90px 0;
}

.lead {
  max-width: 750px;
  color: var(--muted);
  font-size: 19px;
}

.cards {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 22px;
}

.card {
  padding: 30px;
  background: var(--card);
  border-radius: 12px;
  box-shadow: 0 8px 30px rgba(30,20,10,.06);
}

.card-icon {
  color: var(--accent);
  font-size: 32px;
}

.card p {
  color: var(--muted);
}

.cards-section {
  background: #eee6dc;
}

.contact-preview {
  text-align: center;
}

.page {
  min-height: 65vh;
}

.contact-card {
  max-width: 650px;
  margin-top: 30px;
}

.footer {
  background: var(--dark);
  color: #eee4dc;
  padding: 28px 0;
}

.footer-inner {
  display: flex;
  justify-content: space-between;
  gap: 20px;
}

@media (max-width: 720px) {
  .nav {
    padding: 20px 0;
    align-items: flex-start;
    flex-direction: column;
  }

  nav {
    gap: 12px 18px;
  }

  .hero {
    min-height: 450px;
  }

  .section {
    padding: 60px 0;
  }

  .cards {
    grid-template-columns: 1fr;
  }

  .footer-inner {
    flex-direction: column;
  }
}
EOF

    cat > "$SITE_DIR/robots.txt" <<EOF
User-agent: *
Allow: /
Sitemap: https://$DOMAIN/sitemap.xml
EOF

    cat > "$SITE_DIR/sitemap.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
<url><loc>https://$DOMAIN/</loc></url>
<url><loc>https://$DOMAIN/pages/about.html</loc></url>
<url><loc>https://$DOMAIN/pages/menu.html</loc></url>
<url><loc>https://$DOMAIN/pages/contact.html</loc></url>
</urlset>
EOF

    chown -R www-data:www-data "$SITE_DIR"
    find "$SITE_DIR" -type d -exec chmod 755 {} \;
    find "$SITE_DIR" -type f -exec chmod 644 {} \;

    ok "Сайт создан: $SITE_DIR"
}

# ============================================================
# NGINX CONFIGURATION
# ============================================================

write_http_config() {
    info "Создание HTTP-конфигурации Nginx..."

    cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;

    server_name $DOMAIN www.$DOMAIN;

    root $SITE_DIR;
    index index.html;

    access_log /var/log/nginx/${DOMAIN}.access.log;
    error_log /var/log/nginx/${DOMAIN}.error.log;

    server_tokens off;

    location ^~ /.well-known/acme-challenge/ {
        root $SITE_DIR;
        default_type "text/plain";
        allow all;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ /\. {
        deny all;
    }

    location ~* \.(css|js|jpg|jpeg|png|gif|svg|webp|ico)$ {
        expires 7d;
        add_header Cache-Control "public";
    }
}
EOF
}

write_https_config() {
    info "Создание HTTPS-конфигурации Nginx..."

    cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;

    server_name $DOMAIN www.$DOMAIN;

    location ^~ /.well-known/acme-challenge/ {
        root $SITE_DIR;
        default_type "text/plain";
        allow all;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;

    server_name $DOMAIN www.$DOMAIN;

    root $SITE_DIR;
    index index.html;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    access_log /var/log/nginx/${DOMAIN}.access.log;
    error_log /var/log/nginx/${DOMAIN}.error.log;

    server_tokens off;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ /\. {
        deny all;
    }

    location ~* \.(css|js|jpg|jpeg|png|gif|svg|webp|ico)$ {
        expires 7d;
        add_header Cache-Control "public";
    }
}
EOF
}

# ============================================================
# NGINX VALIDATION AND ROLLBACK
# ============================================================

reload_nginx() {
    if nginx -t; then
        systemctl reload nginx
        ok "Nginx успешно перезагружен."
    else
        fail "Ошибка конфигурации Nginx."

        if [[ -f "$BACKUP_PATH/nginx.conf" ]]; then
            cp -a "$BACKUP_PATH/nginx.conf" "$NGINX_CONF"
        else
            rm -f "$NGINX_CONF"
        fi

        nginx -t && systemctl reload nginx || true

        die "Конфигурация возвращена к резервной копии."
    fi
}

# ============================================================
# SSL
# ============================================================

setup_ssl() {
    [[ "$SSL" == "yes" ]] || {
        warn "HTTPS отключён пользователем."
        return 0
    }

    info "Проверка DNS перед выпуском сертификата..."

    if ! check_dns; then
        warn "Сертификат не запрашивается: DNS не прошёл проверку."
        warn "Сайт будет доступен по HTTP."
        return 0
    fi

    info "Проверка доступности порта 80..."
    warn "Для Let's Encrypt порт TCP 80 должен быть доступен извне."

    write_http_config
    reload_nginx

    info "Запрос сертификата Let's Encrypt..."

    if certbot certonly \
        --webroot \
        -w "$SITE_DIR" \
        -d "$DOMAIN" \
        --email "$CERT_EMAIL" \
        --agree-tos \
        --non-interactive \
        --keep-until-expiring; then

        ok "SSL-сертификат получен."

        write_https_config
        reload_nginx

        mkdir -p /etc/letsencrypt/renewal-hooks/deploy

        cat > /etc/letsencrypt/renewal-hooks/deploy/website-installer-reload-nginx.sh <<'EOF'
#!/usr/bin/env bash
systemctl reload nginx
EOF

        chmod 755 /etc/letsencrypt/renewal-hooks/deploy/website-installer-reload-nginx.sh

        ok "HTTPS настроен."
    else
        warn "Не удалось получить SSL-сертификат."
        warn "Сайт останется доступен по HTTP."
        warn "Проверь DNS, A-запись, порт 80 и настройки firewall."
    fi
}

# ============================================================
# DIAGNOSTICS
# ============================================================

diagnostics() {
    echo
    echo "=========================================="
    echo "              ДИАГНОСТИКА"
    echo "=========================================="

    echo "Дата: $(date)"
    echo "ОС: $(. /etc/os-release && echo "$PRETTY_NAME")"

    if command -v nginx >/dev/null 2>&1; then
        nginx -v 2>&1 || true
        nginx -t || true
        systemctl status nginx --no-pager || true
    else
        warn "Nginx не установлен."
    fi

    if command -v docker >/dev/null 2>&1; then
        echo
        echo "Docker:"
        docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true
    fi

    echo
    echo "Порты:"
    ss -lntp 2>/dev/null | grep -E ':(80|443)\b' || true

    echo
    echo "Каталоги сайтов:"
    ls -lah "$BASE_DIR" 2>/dev/null || true

    echo
    echo "=========================================="
}

# ============================================================
# INSTALL / UPDATE
# ============================================================

run_install() {
    require_root
    check_os
    check_commands
    check_disk

    collect_settings

    check_services
    check_domain_conflict

    make_backup
    install_packages
    create_website

    write_http_config
    reload_nginx

    setup_ssl

    echo
    echo "=========================================="
    ok "УСТАНОВКА ЗАВЕРШЕНА"
    echo "=========================================="

    echo "Домен:      $DOMAIN"
    echo "Каталог:    $SITE_DIR"
    echo "Nginx:      $NGINX_CONF"

    if [[ "$SSL" == "yes" && -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
        echo "Сайт:       https://$DOMAIN"
    else
        echo "Сайт:       http://$DOMAIN"
    fi

    echo "Резервная копия: $BACKUP_PATH"
    echo "Журнал:          $LOG_FILE"

    echo
    warn "DNS и доступность портов 80/443 должны быть настроены у провайдера."
    warn "Скрипт не менял настройки RemnaNode, Docker, UFW или SSH."
}

# ============================================================
# MENU
# ============================================================

main() {
    require_root

    echo
    echo "=========================================="
    echo " $APP_NAME"
    echo " Version $VERSION"
    echo "=========================================="
    echo
    echo "1. Установить новый сайт"
    echo "2. Обновить сайт"
    echo "3. Диагностика сервера"
    echo "4. Выход"
    echo

    local choice
    choice=$(ask_value "Выбери действие" "1")

    case "$choice" in
        1)
            run_install
            ;;
        2)
            warn "Обновление использует те же проверки и создаёт резервную копию."
            run_install
            ;;
        3)
            diagnostics
            ;;
        4)
            exit 0
            ;;
        *)
            die "Неверный пункт меню."
            ;;
    esac
}

main "$@"
