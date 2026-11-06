#!/usr/bin/env bash
#
# Remnawave Node installer
# Режимы:
#   1) нода без self-steal
#   2) нода с self-steal (сайт, nginx, сертификат)
#   3) каскад RU -> EU: шаг на RU (нода, self-steal, ключи)
#   4) переустановка ноды
#   5) каскад RU -> EU: ввод PublicKey и Short ID с EU, сборка профиля RU
#   6) доделать self-steal на уже запущенной ноде
#
set -Eeuo pipefail

INSTALLER_VERSION="1.13.0"
INSTALLER_URL="https://raw.githubusercontent.com/Wanderer-95/remnanode-installer/main/install.sh"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

REAL_SYSTEMCTL="$(command -v systemctl || echo /bin/systemctl)"

INSTALL_DIR="/opt/remnanode"
CONTAINER_NAME="remnanode"
IMAGE="remnawave/node:latest"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
ENV_FILE="${INSTALL_DIR}/.env"

SYSCTL_FILE="/etc/sysctl.d/99-node-tuning.conf"
MODULES_FILE="/etc/modules-load.d/remnanode.conf"
DOCKER_DROPIN="/etc/systemd/system/docker.service.d/99-remnanode-limits.conf"
DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
JOURNALD_DROPIN="/etc/systemd/journald.conf.d/99-remnanode.conf"

NGINX_CONF="/etc/nginx/conf.d/remnanode-selfsteal.conf"
NGINX_PREBACKUP="${NGINX_CONF}.pre-remnanode"
NGINX_BACKUP_DIR="/root/remnanode-backups"
NGINX_PREV="${NGINX_BACKUP_DIR}/remnanode-selfsteal.conf.prev"
SITE_ROOT_BASE="/var/www/remnanode-selfsteal"
SITE_ROOT="${SITE_ROOT_BASE}"
GENERATOR_TIMEOUT=900
FOREIGN_WEB_UNITS=(apache2 httpd lighttpd caddy)

# Состояние каскада на RU (содержит приватный ключ RU, права 600). Удаляется после подтверждения.
CASCADE_STATE_FILE="/root/remnanode-cascade.state"
LEGACY_PROFILE_FILE="/root/remnanode-profile.json"

BACKUP_SUFFIX="$(date +%Y%m%d-%H%M%S)"

DOMAIN_RE='^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$'
UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
PUBKEY_RE='^[A-Za-z0-9_-]{43}$'
# Reality shortId: чётное число hex-символов, от 2 до 16.
SHORTID_RE='^([0-9a-f]{2}){1,8}$'
NAME_RE='^[A-Za-z0-9_-]{1,32}$'

# Домены, которые идут напрямую с RU (как в рабочем профиле).
RU_DIRECT_DOMAINS=(
    "geosite:category-ru"
    "domain:vk.com" "domain:vk.ru" "domain:userapi.com"
    "domain:vk-cdn.net" "domain:vkuservideo.net" "domain:vkvideo.ru"
    "domain:mycdn.me" "domain:ok.ru" "domain:mail.ru" "domain:imgsmail.ru"
    "domain:yandex.ru" "domain:ya.ru" "domain:dzen.ru" "domain:rutube.ru"
    "domain:kinopoisk.ru" "domain:gosuslugi.ru" "domain:mos.ru"
    "domain:sberbank.ru" "domain:tbank.ru" "domain:avito.ru"
    "domain:wildberries.ru" "domain:ozon.ru"
)

# ============================================================
# STATE
# ============================================================

MENU_ACTION=""
REINSTALL=0
RESUME_CASCADE=0
RESUME_SITE=0
REINSTALL_TYPE=""
CONFIRM_DELETE=""
SELFSTEAL=0
CASCADE=0

MAIN_INTERFACE=""
EXISTING_SECRET_KEY=""
SECRET_KEY=""
INBOUND_NAME=""
SITE_DOMAIN=""
SITE_FILE=""
PASTE_TMP=""
NGINX_VERSION=""

WORK_DIR=""
SITE_SOURCE_DIR=""
NGINX_SNAPSHOT=""

PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""
PROFILE_JSON=""

EU_SITE_DOMAIN=""
EU_INBOUND_NAME=""
EU_UUID=""
EU_PUBLIC_KEY=""
EU_SHORT_ID=""

# ============================================================
# LOGGING, CLEANUP
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
info() { echo -e "${BLUE}[*]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*" >&2; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

trap 'die "Ошибка на строке ${LINENO}. Проверьте вывод выше."' ERR

cleanup() {
    [[ -n "${PASTE_TMP}" && -f "${PASTE_TMP}" ]] && rm -f "${PASTE_TMP}"
    [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]] && rm -rf "${WORK_DIR}"
    PROFILE_JSON=""
    return 0
}
trap cleanup EXIT

# ============================================================
# INPUT HELPERS
# ============================================================

# ask VAR "подсказка" [secret]
ask() {
    local var="$1" prompt="$2" secret="${3:-0}" value=""
    while true; do
        if [[ "${secret}" == "1" ]]; then
            read -r -s -p "${prompt}" value
            echo
        else
            read -r -p "${prompt}" value
        fi
        [[ -n "${value}" ]] && break
        warn "Значение не может быть пустым."
    done
    printf -v "${var}" '%s' "${value}"
}

# ask_valid VAR "подсказка" REGEX "сообщение об ошибке"
ask_valid() {
    local var="$1" prompt="$2" re="$3" msg="$4"
    while true; do
        ask "${var}" "${prompt}"
        if [[ "${!var}" =~ ${re} ]]; then
            return 0
        fi
        warn "${msg}"
        printf -v "${var}" '%s' ''
    done
}

ask_secret_confirmed() {
    local var="$1" prompt="$2" again=""
    while true; do
        ask "${var}" "${prompt}" 1
        read -r -s -p "Повторите: " again
        echo
        [[ "${!var}" == "${again}" ]] && return 0
        warn "Значения не совпадают. Попробуйте снова."
        printf -v "${var}" '%s' ''
    done
}

confirm_continue() {
    local answer=""
    read -r -p "${1:-Продолжить? [y/N]: }" answer
    [[ "${answer}" =~ ^[Yy]$ ]] || die "Остановлено пользователем."
}

# ============================================================
# CHECKS AND MENU
# ============================================================

check_system() {
    [[ "${EUID}" -eq 0 ]] || die "Запустите установщик от root."
    [[ -t 0 ]] || die "Нужен интерактивный терминал. Запускайте так: bash <(curl -fsSL ${INSTALLER_URL})"
    [[ -f /etc/os-release ]] || die "Не удалось определить ОС."
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == "ubuntu" ]] || die "Поддерживается только Ubuntu."
    command -v python3 >/dev/null 2>&1 || die "Не найден python3. Установите: apt-get install -y python3"

    if [[ "${VERSION_ID:-}" != "24.04" ]]; then
        warn "Рекомендуется Ubuntu 24.04. Текущая версия: ${VERSION_ID:-unknown}"
        confirm_continue "Продолжить? [y/N]: "
    fi
    log "Операционная система: ${PRETTY_NAME:-Ubuntu}"
    log "Версия установщика: ${INSTALLER_VERSION}"
}

docker_container_exists() {
    command -v docker >/dev/null 2>&1 &&
        docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1
}

apply_type() {
    case "$1" in
        1) SELFSTEAL=0; CASCADE=0; log "Выбрана установка без self-steal." ;;
        2) SELFSTEAL=1; CASCADE=0; log "Выбрана установка с self-steal." ;;
        3) SELFSTEAL=1; CASCADE=1; log "Выбран каскад RU -> EU (шаг на RU)." ;;
        *) die "Неверный тип установки: $1" ;;
    esac
}

select_reinstall() {
    REINSTALL=1
    echo
    echo "Тип установки после переустановки:"
    echo "1) Без self-steal"
    echo "2) С self-steal"
    echo "3) Каскад RU -> EU"
    echo
    ask REINSTALL_TYPE "Выберите тип [1/2/3]: "
    apply_type "${REINSTALL_TYPE}"
    warn "Будет удалены текущая нода, её сайт и незавершённый каскад (если был)."
    warn "Docker, SSH, UFW и остальные контейнеры сохраняются."
    ask CONFIRM_DELETE "Для подтверждения введите DELETE: "
    [[ "${CONFIRM_DELETE}" == "DELETE" ]] || die "Операция отменена."
}

select_mode() {
    echo
    echo "========================================"
    echo "       REMNAWAVE NODE INSTALLER"
    echo "            v${INSTALLER_VERSION}"
    echo "========================================"
    echo
    echo "1) Установка без self-steal"
    echo "2) Установка с self-steal"
    echo "3) Каскад RU -> EU (шаг на RU)"
    echo "4) Удалить Remnawave Node и установить заново"
    if [[ -f "${CASCADE_STATE_FILE}" ]]; then
        echo "5) Каскад RU -> EU: ввести PublicKey и Short ID с EU и собрать профиль RU"
    fi
    if docker_container_exists; then
        echo "6) Доделать self-steal (сайт, nginx, сертификат) на запущенной ноде"
    fi
    echo "0) Выход"
    echo

    ask MENU_ACTION "Выберите действие: "

    case "${MENU_ACTION}" in
        1|2|3) REINSTALL=0; apply_type "${MENU_ACTION}" ;;
        4)     select_reinstall ;;
        5)     [[ -f "${CASCADE_STATE_FILE}" ]] || die "Нет сохранённого состояния каскада."
               RESUME_CASCADE=1 ;;
        6)     docker_container_exists || die "Нода не найдена. Выберите пункт 1, 2 или 3."
               RESUME_SITE=1 ;;
        0)     exit 0 ;;
        *)     die "Неверный пункт меню." ;;
    esac
}

# ============================================================
# EXISTING CONFIGURATION
# ============================================================

read_existing_secret() {
    if [[ -f "${ENV_FILE}" ]]; then
        EXISTING_SECRET_KEY="$(
            python3 - "${ENV_FILE}" <<'PY'
import re
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        if line.startswith("SECRET_KEY="):
            value = line.rstrip("\n")[len("SECRET_KEY="):]
            if len(value) >= 2 and value[0] == value[-1] == '"':
                value = value[1:-1]
            value = re.sub(r'\\(.)', r'\1', value)
            print(value)
            break
PY
        )" || true
    fi
}

backup_file() {
    local file="$1"
    [[ -f "${file}" ]] && cp -a "${file}" "${file}.bak.${BACKUP_SUFFIX}"
    return 0
}

# ============================================================
# COLLECT ANSWERS BEFORE CHANGING THE SERVER
# ============================================================

read_secret_key() {
    if [[ -n "${EXISTING_SECRET_KEY}" ]]; then
        echo
        info "Найден SECRET_KEY от предыдущей установки."
        local choice=""
        ask_valid choice "1) оставить существующий, 2) ввести новый: " '^[12]$' "Введите 1 или 2."
        if [[ "${choice}" == "1" ]]; then
            SECRET_KEY="${EXISTING_SECRET_KEY}"
            log "Используется существующий SECRET_KEY."
            return 0
        fi
    fi
    ask_secret_confirmed SECRET_KEY "SECRET_KEY Remnawave Node из панели (ввод скрыт): "
    log "SECRET_KEY принят."
}

check_dns_points_here() {
    local domain="$1" dns_ip="" my_ip=""
    dns_ip="$(getent ahostsv4 "${domain}" 2>/dev/null | awk 'NR==1 {print $1}' || true)"
    my_ip="$(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"

    if [[ -z "${dns_ip}" ]]; then
        warn "Домен ${domain} пока не резолвится. Создайте A-запись на ${my_ip:-IP этого сервера}."
        confirm_continue "Продолжить без DNS? [y/N]: "
    elif [[ -n "${my_ip}" && "${dns_ip}" != "${my_ip}" ]]; then
        warn "Домен ${domain} указывает на ${dns_ip}, а IP этого сервера: ${my_ip}."
        warn "Если домен за Cloudflare-прокси, переключите запись в режим DNS only."
        confirm_continue "Продолжить? [y/N]: "
    else
        log "DNS: ${domain} -> ${dns_ip}"
    fi
}

ask_selfsteal_domain() {
    ask_valid SITE_DOMAIN "Домен этой ноды (self-steal, A-запись на этот сервер): " "${DOMAIN_RE}" "Некорректный домен."
    SITE_DOMAIN="${SITE_DOMAIN,,}"
    SITE_ROOT="${SITE_ROOT_BASE}/${SITE_DOMAIN}"
    log "Домен: ${SITE_DOMAIN}"
    log "Каталог сайта: ${SITE_ROOT}"
    check_dns_points_here "${SITE_DOMAIN}"
}

ask_inbound_name() {
    local var="$1" prompt="$2"
    ask_valid "${var}" "${prompt}" "${NAME_RE}" "Допустимы латинские буквы, цифры, _ и - (до 32 символов)."
}

ask_cascade_params() {
    echo
    info "Параметры EU-ноды. Скрипт не заходит на EU сам, эти данные нужны для профиля RU."
    while true; do
        ask_valid EU_SITE_DOMAIN "Домен EU-ноды (A-запись на EU): " "${DOMAIN_RE}" "Некорректный домен."
        EU_SITE_DOMAIN="${EU_SITE_DOMAIN,,}"
        [[ "${EU_SITE_DOMAIN}" != "${SITE_DOMAIN}" ]] && break
        warn "Домен EU должен отличаться от домена RU."
    done
    ask_valid EU_UUID "UUID клиента для RU на EU (flow xtls-rprx-vision): " "${UUID_RE}" "Некорректный UUID."
    EU_UUID="${EU_UUID,,}"
}

# ============================================================
# SITE INPUT: VALIDATION BEFORE ANY CHANGES
# ============================================================

normalize_site_file() {
    local file="$1"
    python3 - "${file}" <<'PY'
import sys

path = sys.argv[1]
with open(path, "rb") as f:
    data = f.read()
if data.startswith(b"\xef\xbb\xbf"):
    data = data[3:]
data = data.replace(b"\r\n", b"\n")
with open(path, "wb") as f:
    f.write(data)
PY
    chmod 600 "${file}"
}

# Печатает: bash, html, unsupported-shebang или unknown.
detect_site_kind() {
    local file="$1" first=""
    first="$(sed -n '/[^[:space:]]/{p;q;}' "${file}")"

    if [[ "${first}" == '#!'* ]]; then
        if [[ "${first}" =~ ^#!.*(bash|/sh)([[:space:]]|$) ]]; then
            echo "bash"
        else
            echo "unsupported-shebang"
        fi
        return 0
    fi
    if [[ "${first}" =~ ^[[:space:]]*\< ]] &&
       grep -qiE '<!doctype[[:space:]]+html|<html|<head|<body' "${file}"; then
        echo "html"
        return 0
    fi
    echo "unknown"
}

# Проверяет синтаксис встроенных Python-блоков (<<'PY' ... PY) в генераторе.
check_embedded_python() {
    local file="$1"
    python3 - "${file}" <<'PYCHK'
import ast
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8", errors="replace") as f:
    lines = f.read().split("\n")

start_re = re.compile(r"<<-?\s*(['\"]?)PY\1\s*$")
end_re = re.compile(r"^\s*PY\s*$")

errors = []
blocks = []
i = 0
while i < len(lines):
    if start_re.search(lines[i]):
        begin = i + 1
        j = begin
        while j < len(lines) and not end_re.match(lines[j]):
            j += 1
        if j >= len(lines):
            errors.append(f"строка {i + 1}: блок <<'PY' не закрыт строкой PY")
            break
        blocks.append((begin, lines[begin:j]))
        i = j + 1
        continue
    i += 1

for begin, body in blocks:
    try:
        ast.parse("\n".join(body) + "\n", filename=path)
    except SyntaxError as e:
        ln = begin + (e.lineno or 1)
        text = lines[ln - 1].strip() if 0 < ln <= len(lines) else ""
        errors.append(f"строка {ln}: {e.msg}\n      {text}")

if errors:
    print("Ошибки во встроенном Python-коде генератора:", file=sys.stderr)
    for err in errors:
        print("    " + err, file=sys.stderr)
    sys.exit(1)
print(f"    Python-блоков проверено: {len(blocks)}, ошибок нет.")
PYCHK
}

warn_generator_style() {
    local file="$1"

    if grep -qE '^[[:space:]]*(read|select)[[:space:]]' "${file}"; then
        warn "В генераторе есть интерактивный ввод (read/select). Ввода не будет: возможна ошибка или зависание."
    fi
    if grep -E 'apt(-get)?[[:space:]]+install' "${file}" 2>/dev/null | grep -qvE -- '(-y|--yes|assume-yes)'; then
        warn "В генераторе есть 'apt install' без -y: установка может зависнуть в ожидании ответа."
    fi
    if grep -qE '/var/www/|/usr/share/nginx' "${file}" &&
       ! grep -qE '\$1|\$\{1|OUT_DIR|SITE_OUT|WEB_ROOT|SITE_ROOT' "${file}"; then
        warn "Генератор пишет в фиксированный путь. Надёжнее писать в каталог из \$1: ROOT=\"\${1:-/var/www/\${DOMAIN}}\"."
    fi
    if grep -qE 'nginx|certbot|ufw|systemctl|apache' "${file}"; then
        info "Генератор упоминает веб-сервер или фаервол: эти команды будут подменены, изменения nginx откатятся."
    fi
}

validate_site_input() {
    local file="$1" kind="" out=""

    [[ -s "${file}" ]] || { warn "Сайт пустой."; return 1; }
    normalize_site_file "${file}"
    kind="$(detect_site_kind "${file}")"

    case "${kind}" in
        html)
            log "Обнаружена HTML-страница."
            ;;
        bash)
            log "Обнаружен bash-генератор. Проверяем его до начала установки..."
            if ! out="$(bash -n "${file}" 2>&1)"; then
                warn "Синтаксическая ошибка в bash-генераторе:"
                printf '%s\n' "${out}" | sed 's/^/    /' >&2
                return 1
            fi
            check_embedded_python "${file}" || return 1
            warn_generator_style "${file}"
            log "Генератор прошёл проверку."
            ;;
        unsupported-shebang)
            warn "Первая строка задаёт не bash и не sh. Поддерживаются HTML и bash-генератор (#!/bin/bash)."
            return 1
            ;;
        *)
            warn "Не удалось распознать сайт. Нужен HTML (<!DOCTYPE html> или <html>) или bash-генератор (#!/bin/bash)."
            return 1
            ;;
    esac
    return 0
}

collect_site() {
    echo
    info "Сайт-заглушку можно передать двумя способами:"
    info " - HTML-страница (начинается с <!DOCTYPE html> или <html>);"
    info " - bash-генератор, первая строка которого #!/bin/bash или #!/bin/sh."
    info "Генератор запускается от root без ввода с клавиатуры. Он должен писать сайт в каталог из \$1."
    info "Генератор не настраивает nginx, firewall и сертификаты: это делает установщик."
    info "Вставьте сайт целиком, затем на новой строке нажмите Ctrl+D."

    while true; do
        PASTE_TMP="$(mktemp /tmp/remnanode-site.XXXXXX)"
        chmod 600 "${PASTE_TMP}"
        cat > "${PASTE_TMP}"
        if validate_site_input "${PASTE_TMP}"; then
            SITE_FILE="${PASTE_TMP}"
            return 0
        fi
        warn "Сайт не принят. Исправьте генератор или HTML."
        confirm_continue "Вставить сайт заново? [y/N]: "
        rm -f "${PASTE_TMP}"
    done
}

ask_restart_if_needed() {
    local count=0
    if command -v docker >/dev/null 2>&1; then
        count="$(
            docker ps --format '{{.Names}}' 2>/dev/null |
            { grep -vx "${CONTAINER_NAME}" || true; } |
            wc -l
        )" || count=0
    fi
    count="${count//[[:space:]]/}"
    if [[ "${count}" =~ ^[0-9]+$ ]] && (( count > 0 )); then
        warn "На сервере есть другие запущенные контейнеры (${count})."
        warn "Перезапуск Docker временно прервёт их работу."
        local restart_confirm=""
        ask_valid restart_confirm "Для перезапуска Docker введите RESTART: " '^RESTART$' "Введите RESTART."
    fi
}

collect_answers() {
    read_secret_key

    if (( SELFSTEAL == 1 )); then
        ask_selfsteal_domain
        ask_inbound_name INBOUND_NAME "Название инбаунда этой ноды (например, RU_IN): "
        collect_site
    fi
    if (( CASCADE == 1 )); then
        ask_cascade_params
    fi
    ask_restart_if_needed
    log "Все параметры собраны. Дальше установка идёт автоматически."
}

# ============================================================
# REMOVAL (REINSTALL)
# ============================================================

remove_remnanode() {
    log "Удаление предыдущей ноды..."

    docker_container_exists && docker rm -f "${CONTAINER_NAME}" >/dev/null
    if [[ -d "${INSTALL_DIR}" ]]; then
        rm -rf -- "${INSTALL_DIR}"
        log "Удалён каталог ${INSTALL_DIR}."
    fi

    if [[ -f "${NGINX_PREBACKUP}" ]]; then
        cp -a "${NGINX_PREBACKUP}" "${NGINX_CONF}"
        rm -f -- "${NGINX_PREBACKUP}"
    else
        rm -f -- "${NGINX_CONF}"
    fi
    rm -f -- "${NGINX_PREV}" "${CASCADE_STATE_FILE}" "${LEGACY_PROFILE_FILE}"

    local hook="/etc/letsencrypt/renewal-hooks/deploy/remnanode-selfsteal-reload-nginx.sh"
    local hook_backup=""
    hook_backup="$(
        find "$(dirname "${hook}")" -maxdepth 1 -type f -name "$(basename "${hook}").bak.*" \
            -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1 {$1=""; sub(/^ /,""); print}'
    )" || true
    if [[ -n "${hook_backup}" && -f "${hook_backup}" ]]; then
        cp -a "${hook_backup}" "${hook}"
    else
        rm -f -- "${hook}"
    fi

    if "${REAL_SYSTEMCTL}" is-active --quiet nginx; then
        if nginx -t >/dev/null 2>&1; then
            "${REAL_SYSTEMCTL}" reload nginx || warn "Nginx не перезагружен."
        else
            warn "Конфигурация nginx не проходит проверку после удаления. Проверьте вручную."
        fi
    fi

    if command -v docker >/dev/null 2>&1 && docker image inspect "${IMAGE}" >/dev/null 2>&1; then
        local users=""
        users="$(docker ps -a --filter "ancestor=${IMAGE}" --format '{{.Names}}' 2>/dev/null || true)"
        if [[ -z "${users}" ]]; then
            docker image rm "${IMAGE}" >/dev/null 2>&1 || warn "Образ ${IMAGE} не удалён."
        else
            log "Образ ${IMAGE} сохранён: его используют контейнеры ${users//$'\n'/, }."
        fi
    fi
}

# ============================================================
# APT AND PACKAGES
# ============================================================

wait_for_apt() {
    if ! command -v fuser >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y -qq psmisc >/dev/null 2>&1 || die "Не удалось установить psmisc."
    fi

    local waited=0
    local locks=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock)
    while fuser "${locks[@]}" >/dev/null 2>&1; do
        (( waited == 0 )) && warn "Ждём освобождения apt (обычно это unattended-upgrades)..."
        sleep 5
        waited=$((waited + 5))
        (( waited < 600 )) || die "Блокировка apt занята более 10 минут."
    done
    dpkg --configure -a >/dev/null 2>&1 ||
        die "dpkg не смог завершить незавершённые пакеты. Выполните вручную: dpkg --configure -a"
}

install_packages() {
    log "Установка необходимых пакетов..."
    wait_for_apt
    apt-get update -qq
    wait_for_apt
    apt-get install -y -qq \
        ca-certificates curl gnupg openssl python3 \
        iproute2 iptables kmod ufw psmisc util-linux
    log "Необходимые пакеты установлены."
}

# Утилиты для генераторов сайта. Сбой отдельных пакетов не критичен.
install_generator_tools() {
    log "Установка утилит для генератора сайта..."
    wait_for_apt
    apt-get install -y -qq \
        sudo wget git unzip zip jq rsync tar xz-utils \
        python3-pip python3-venv cron >/dev/null 2>&1 ||
        warn "Часть вспомогательных пакетов не установилась. Генератор может доставить их сам."
}

install_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        log "Установка Docker..."
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh
        rm -f /tmp/get-docker.sh
    else
        log "Docker уже установлен."
    fi

    systemctl enable --now docker >/dev/null 2>&1
    docker info >/dev/null 2>&1 || die "Docker не запустился."
    if ! docker compose version >/dev/null 2>&1; then
        wait_for_apt
        apt-get update -qq
        apt-get install -y -qq docker-compose-plugin ||
            apt-get install -y -qq docker-compose-v2 ||
            die "Не удалось установить Docker Compose plugin."
    fi
    docker compose version >/dev/null 2>&1 || die "Docker Compose не найден после установки."
    log "Docker и Docker Compose доступны."
}

# ============================================================
# PORTS (BEFORE ANY CHANGES)
# ============================================================

listener_owners() {
    ss -H -tlnp 2>/dev/null | awk '
        {
            n = split($4, a, ":"); port = a[n]
            if (port != "80" && port != "443" && port != "8443") next
            proc = "?"
            if (match($0, /"[^"]+"/)) proc = substr($0, RSTART + 1, RLENGTH - 2)
            print port, proc
        }'
}

# 443 занимает Xray внутри ноды (rw-core), это штатно. 80 и 8443 нужны только для self-steal.
preflight_ports() {
    local port proc bad=""
    while read -r port proc; do
        [[ -n "${port}" ]] || continue
        case "${port}" in
            443) ;;
            80|8443) (( SELFSTEAL == 1 )) || continue ;;
            *) continue ;;
        esac
        case "${port}:${proc}" in
            80:nginx|8443:nginx|443:rw-core|443:xray|443:docker-proxy) ;;
            *) bad+="${port} (${proc}) " ;;
        esac
    done < <(listener_owners)

    [[ -z "${bad}" ]] || die "Порты заняты посторонними процессами: ${bad}. Освободите их и запустите снова."
    log "Порты проверены."
}

# ============================================================
# SYSTEM TUNING
# ============================================================

detect_system() {
    echo
    info "Определение параметров системы..."
    echo "Kernel: $(uname -r)"
    echo "Architecture: $(uname -m)"
    command -v systemd-detect-virt >/dev/null 2>&1 &&
        echo "Virtualization: $(systemd-detect-virt 2>/dev/null || echo unknown)"

    MAIN_INTERFACE="$(
        ip -4 route get 1.1.1.1 2>/dev/null |
        awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true
    )"
    if [[ -z "${MAIN_INTERFACE}" ]]; then
        MAIN_INTERFACE="$(ip -o link show | awk -F': ' '$2 != "lo" {print $2; exit}' || true)"
    fi
    if [[ -n "${MAIN_INTERFACE}" ]]; then
        log "Основной интерфейс: ${MAIN_INTERFACE}"
    else
        warn "Не удалось определить сетевой интерфейс."
    fi

    modprobe tcp_bbr 2>/dev/null && log "Модуль TCP BBR доступен." ||
        { grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null &&
            log "BBR встроен в ядро." || warn "BBR не поддерживается ядром."; }
    modprobe sch_fq 2>/dev/null && log "Модуль sch_fq доступен." || warn "Модуль sch_fq недоступен."
    modprobe nf_conntrack 2>/dev/null && log "Модуль nf_conntrack загружен." || warn "nf_conntrack не загружен."
}

configure_modules() {
    log "Настройка автозагрузки nf_conntrack..."
    mkdir -p /etc/modules-load.d
    backup_file "${MODULES_FILE}"
    touch "${MODULES_FILE}"
    grep -qxF nf_conntrack "${MODULES_FILE}" || echo "nf_conntrack" >> "${MODULES_FILE}"
    modprobe nf_conntrack 2>/dev/null || warn "nf_conntrack пока не загружен."
}

configure_sysctl() {
    log "Настройка сетевых параметров ядра..."
    backup_file "${SYSCTL_FILE}"

    local lines
    lines="$(cat <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_mtu_probing = 1
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_udp_timeout = 120
net.netfilter.nf_conntrack_udp_timeout_stream = 300
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192
net.ipv4.ip_local_port_range = 10240 65535
EOF
)"

    : > "${SYSCTL_FILE}"
    echo "# Remnawave Node network tuning" >> "${SYSCTL_FILE}"

    local line key value
    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        key="$(xargs <<< "${line%%=*}")"
        value="$(xargs <<< "${line#*=}")"
        if [[ ! -e "/proc/sys/${key//./\/}" ]]; then
            warn "Параметр не поддерживается: ${key}"
            continue
        fi
        if sysctl -w "${key}=${value}" >/dev/null 2>&1; then
            echo "${key} = ${value}" >> "${SYSCTL_FILE}"
        else
            warn "Не удалось применить ${key}."
        fi
    done <<< "${lines}"
    chmod 644 "${SYSCTL_FILE}"
    log "Параметры ядра применены."
}

configure_qdisc() {
    if [[ -z "${MAIN_INTERFACE}" ]] || ! command -v tc >/dev/null 2>&1; then
        warn "Пропускаем настройку FQ на интерфейсе."
        return 0
    fi
    tc qdisc replace dev "${MAIN_INTERFACE}" root fq 2>/dev/null &&
        log "FQ применён к ${MAIN_INTERFACE}." || warn "Не удалось применить FQ."
}

configure_docker_limits() {
    log "Настройка системных лимитов Docker..."
    mkdir -p "$(dirname "${DOCKER_DROPIN}")"
    backup_file "${DOCKER_DROPIN}"
    cat > "${DOCKER_DROPIN}" <<'EOF'
[Service]
LimitNOFILE=1048576
LimitNPROC=1048576
EOF
    chmod 644 "${DOCKER_DROPIN}"
}

# daemon.json собирается во временный файл, проверяется dockerd и только потом заменяет боевой.
configure_docker_logging() {
    log "Настройка Docker logging..."
    mkdir -p /etc/docker
    backup_file "${DOCKER_DAEMON_JSON}"

    local tmp
    tmp="$(mktemp /etc/docker/daemon.json.new.XXXXXX)"
    chmod 644 "${tmp}"

    if ! python3 - "${DOCKER_DAEMON_JSON}" "${tmp}" <<'PY'
import json
import os
import sys

src, dst = sys.argv[1], sys.argv[2]
config = {}
if os.path.exists(src):
    with open(src, "r", encoding="utf-8") as f:
        config = json.load(f)
if not isinstance(config, dict):
    raise SystemExit("daemon.json должен содержать JSON-объект")
log_opts = config.get("log-opts", {})
if not isinstance(log_opts, dict):
    raise SystemExit("log-opts должен быть JSON-объектом")
config["log-driver"] = "json-file"
log_opts["max-size"] = "50m"
log_opts["max-file"] = "3"
config["log-opts"] = log_opts
with open(dst, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
    then
        rm -f "${tmp}"
        die "Не удалось собрать ${DOCKER_DAEMON_JSON}. Проверьте его содержимое вручную."
    fi

    if ! dockerd --validate --config-file="${tmp}" >/dev/null 2>&1; then
        rm -f "${tmp}"
        die "Конфигурация Docker не прошла проверку. ${DOCKER_DAEMON_JSON} не изменён."
    fi
    mv -f "${tmp}" "${DOCKER_DAEMON_JSON}"
    log "Конфигурация Docker применена."
}

configure_journald() {
    log "Настройка journald..."
    mkdir -p /etc/systemd/journald.conf.d
    backup_file "${JOURNALD_DROPIN}"
    printf '[Journal]\nSystemMaxUse=200M\n' > "${JOURNALD_DROPIN}"
    chmod 644 "${JOURNALD_DROPIN}"
    systemctl restart systemd-journald
    journalctl --vacuum-size=200M >/dev/null 2>&1 || true
}

restart_docker() {
    log "Перезапуск Docker для применения лимитов и логов..."
    systemctl daemon-reload
    systemctl restart docker
    systemctl is-active --quiet docker || die "Docker не запустился после перезапуска."
    docker info >/dev/null 2>&1 || die "Docker API недоступен после перезапуска."
}

verify_docker_limits() {
    local pid nofile nproc
    pid="$(systemctl show docker -p MainPID --value)"
    [[ "${pid}" =~ ^[0-9]+$ ]] && (( pid > 0 )) || die "Процесс Docker не запущен."
    nofile="$(awk '/Max open files/ {print $4; exit}' "/proc/${pid}/limits")"
    nproc="$(awk '/Max processes/ {print $4; exit}' "/proc/${pid}/limits")"
    [[ "${nofile}" == "1048576" && "${nproc}" == "1048576" ]] || die "Лимиты Docker не применились."
    log "Лимиты Docker подтверждены."
}

verify_docker_logging() {
    local driver
    driver="$(docker info --format '{{.LoggingDriver}}')"
    [[ "${driver}" == "json-file" ]] || die "Docker logging driver не применился: ${driver}"
    log "Docker logging: ${driver}."
}

# ============================================================
# FIREWALL
# ============================================================

detect_ssh_ports() {
    local candidates
    candidates="$(
        {
            awk '{print $4}' <<< "${SSH_CONNECTION:-}"
            mkdir -p /run/sshd 2>/dev/null || true
            sshd -T 2>/dev/null | awk '$1=="port" {print $2}' || true
            ss -tlnp 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); print a[n]}' || true
            systemctl show ssh.socket -p Listen --value 2>/dev/null | grep -oE ':[0-9]+' | tr -d ':' || true
        } |
        grep -E '^[0-9]+$' |
        awk '$1 >= 1 && $1 <= 65535' |
        sort -un || true
    )"
    [[ -n "${candidates}" ]] || candidates="22"
    printf '%s\n' "${candidates}"
}

# Открываются только нужные порты. 8443 слушает nginx лишь на 127.0.0.1, наружу не открываем.
apply_firewall_rules() {
    local port ssh_ports=""
    while read -r port; do
        ufw allow "${port}/tcp" comment 'SSH' >/dev/null 2>&1 || true
        ssh_ports+="${port} "
    done < <(detect_ssh_ports)

    ufw allow 2222/tcp comment 'Remnawave Node API' >/dev/null 2>&1 || true
    ufw allow 443/tcp comment 'Reality' >/dev/null 2>&1 || true
    (( SELFSTEAL == 1 )) && ufw allow 80/tcp comment 'ACME and HTTP' >/dev/null 2>&1 || true
    echo "${ssh_ports}"
}

configure_firewall() {
    log "Настройка UFW..."
    local ssh_ports
    ssh_ports="$(apply_firewall_rules)"
    if ufw status 2>/dev/null | grep -q "Status: inactive"; then
        ufw --force enable >/dev/null
    fi
    log "UFW настроен. Открыты SSH-порты: ${ssh_ports% }."
}

ensure_firewall_after_generator() {
    apply_firewall_rules >/dev/null
    if ufw status 2>/dev/null | grep -q "Status: inactive"; then
        ufw --force enable >/dev/null 2>&1 || true
    fi
}

# ============================================================
# NODE
# ============================================================

create_configuration() {
    log "Создание конфигурации Remnawave Node..."
    mkdir -p "${INSTALL_DIR}"
    chmod 700 "${INSTALL_DIR}"

    local escaped
    escaped="$(SECRET_KEY="${SECRET_KEY}" python3 - <<'PY'
import os
v = os.environ["SECRET_KEY"]
print(v.replace("\\", "\\\\").replace('"', '\\"'))
PY
)"

    umask 077
    cat > "${ENV_FILE}" <<EOF
NODE_PORT=2222
SECRET_KEY="${escaped}"
EOF
    chmod 600 "${ENV_FILE}"

    cat > "${COMPOSE_FILE}" <<EOF
services:
  remnanode:
    image: ${IMAGE}
    container_name: ${CONTAINER_NAME}
    restart: always
    network_mode: host
    environment:
      NODE_PORT: \${NODE_PORT}
      SECRET_KEY: \${SECRET_KEY}
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
EOF
    chmod 644 "${COMPOSE_FILE}"

    cd "${INSTALL_DIR}"
    docker compose config -q || die "Ошибка проверки docker-compose.yml."
    log "Конфигурация Node создана."
}

start_node() {
    log "Загрузка образа и запуск Remnawave Node..."
    cd "${INSTALL_DIR}"
    docker compose pull || die "Не удалось загрузить образ ${IMAGE}. Проверьте доступ к Docker Hub."
    docker compose up -d

    local i status
    for i in $(seq 1 30); do
        status="$(docker inspect -f '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null || true)"
        if [[ "${status}" == "running" ]]; then
            log "Контейнер Remnawave Node запущен."
            return 0
        fi
        sleep 2
    done
    docker logs --tail 100 "${CONTAINER_NAME}" || true
    die "Remnawave Node не запустился."
}

check_node_running() {
    local status
    status="$(docker inspect -f '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null || true)"
    [[ "${status}" == "running" ]] ||
        die "Контейнер ноды не в статусе running (статус: ${status:-unknown})."
}

# Генерирует ключи Reality. В образе бинарник может называться xray или rw-core.
generate_keys() {
    log "Генерация ключей Reality (X25519)..."
    local out="" bin
    for bin in xray rw-core; do
        out="$(docker exec "${CONTAINER_NAME}" "${bin}" x25519 2>/dev/null || true)"
        [[ -n "${out}" ]] && break
    done
    [[ -n "${out}" ]] || die "Не удалось выполнить x25519 в контейнере (пробовали xray и rw-core)."

    PRIVATE_KEY="$(awk -F': *' '/^PrivateKey/ {print $2; exit}' <<< "${out}" | tr -d '[:space:]')"
    PUBLIC_KEY="$(awk -F': *' '/^(PublicKey|Password)/ {print $2; exit}' <<< "${out}" | tr -d '[:space:]')"
    SHORT_ID="$(openssl rand -hex 8)"

    [[ "${PRIVATE_KEY}" =~ ${PUBKEY_RE} && "${PUBLIC_KEY}" =~ ${PUBKEY_RE} ]] ||
        die "Не удалось разобрать вывод x25519: ${out}"
    [[ "${SHORT_ID}" =~ ${SHORTID_RE} ]] || die "Некорректный Short ID: ${SHORT_ID}"
    log "Ключи сгенерированы."
}

show_plain_parameters() {
    echo
    echo "========================================"
    echo "          NODE PARAMETERS"
    echo "========================================"
    echo "PrivateKey: ${PRIVATE_KEY}"
    echo "PublicKey:  ${PUBLIC_KEY}"
    echo "Short ID:   ${SHORT_ID}"
    echo "========================================"
    warn "PrivateKey секретный. Не публикуйте его."
}

# ============================================================
# NGINX AND CERTIFICATE
# ============================================================

install_nginx() {
    log "Установка nginx и certbot..."
    wait_for_apt
    apt-get update -qq
    wait_for_apt
    apt-get install -y -qq nginx certbot >/dev/null
    systemctl enable nginx >/dev/null 2>&1 || true
    NGINX_VERSION="$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
    [[ -n "${NGINX_VERSION}" ]] || die "Не удалось определить версию nginx."
    log "nginx ${NGINX_VERSION} установлен."
}

nginx_test_or_show() {
    local out=""
    if ! out="$(nginx -t 2>&1)"; then
        printf '%s\n' "${out}" >&2
        return 1
    fi
    return 0
}

# Чужой конфиг с этим доменом не трогаем: при конфликте останавливаемся.
check_nginx_domain_conflicts() {
    local f dir escaped
    local -a dirs=(/etc/nginx/conf.d /etc/nginx/sites-enabled)
    escaped="${SITE_DOMAIN//./\\.}"

    for dir in "${dirs[@]}"; do
        [[ -d "${dir}" ]] || continue
        while IFS= read -r -d '' f; do
            [[ "${f}" == "${NGINX_CONF}" ]] && continue
            [[ "$(basename "${f}")" == remnanode-* ]] && continue
            if grep -qE "^[[:space:]]*server_name[^;]*[[:space:]]${escaped}([[:space:];]|$)" "${f}" 2>/dev/null ||
               grep -qF "/etc/letsencrypt/live/${SITE_DOMAIN}/" "${f}" 2>/dev/null; then
                warn "Найден конфиг Nginx с доменом ${SITE_DOMAIN}: ${f}"
                die "Конфликт домена. Чужой конфиг не изменён. Устраните конфликт вручную."
            fi
        done < <(find "${dir}" -maxdepth 1 \( -type f -o -type l \) -print0 2>/dev/null)
    done
}

restore_prev_nginx_conf() {
    if [[ -f "${NGINX_PREV}" ]]; then
        cp -a "${NGINX_PREV}" "${NGINX_CONF}"
    else
        rm -f "${NGINX_CONF}"
    fi
}

write_nginx_config() {
    local stage="$1"
    local tmp="${NGINX_CONF}.new.$$"

    mkdir -p /etc/nginx/conf.d "${NGINX_BACKUP_DIR}"
    chmod 700 "${NGINX_BACKUP_DIR}"

    if [[ "${stage}" == "http" ]]; then
        cat > "${tmp}" <<'NGINX'
server {
    listen 80;
    listen [::]:80;
    server_name _DOMAIN_;
    root _SITE_ROOT_;
    index index.html;
    server_tokens off;

    location ^~ /.well-known/acme-challenge/ {
        try_files $uri =404;
    }

    location / {
        try_files $uri $uri/ =404;
    }
}
NGINX
    else
        cat > "${tmp}" <<'NGINX'
server {
    listen 80;
    listen [::]:80;
    server_name _DOMAIN_;
    root _SITE_ROOT_;
    server_tokens off;

    location ^~ /.well-known/acme-challenge/ {
        try_files $uri =404;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

# Внутренний HTTPS для Reality (dest). Слушает только localhost.
server {
    listen 127.0.0.1:8443 ssl http2;
    server_name _DOMAIN_;
    server_tokens off;

    ssl_certificate     /etc/letsencrypt/live/_DOMAIN_/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/_DOMAIN_/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:remnanode_ssl:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    root _SITE_ROOT_;
    index index.html;
    charset utf-8;
    add_header X-Content-Type-Options nosniff always;

    location / {
        try_files $uri $uri/ =404;
    }

    location ~ /\. {
        deny all;
    }
}
NGINX
    fi

    sed -i \
        -e "s|_DOMAIN_|${SITE_DOMAIN}|g" \
        -e "s|_SITE_ROOT_|${SITE_ROOT}|g" \
        "${tmp}"
    chmod 644 "${tmp}"

    if [[ -f "${NGINX_CONF}" ]]; then
        cp -a "${NGINX_CONF}" "${NGINX_PREV}"
        cp -a "${NGINX_CONF}" "${NGINX_BACKUP_DIR}/remnanode-selfsteal.conf.bak.${BACKUP_SUFFIX}"
        if [[ ! -e "${NGINX_PREBACKUP}" ]]; then
            cp -a "${NGINX_CONF}" "${NGINX_PREBACKUP}"
            chmod 600 "${NGINX_PREBACKUP}"
        fi
    else
        rm -f "${NGINX_PREV}"
    fi
    mv -f "${tmp}" "${NGINX_CONF}"

    if ! nginx_test_or_show; then
        restore_prev_nginx_conf
        die "Конфигурация nginx не прошла проверку. Предыдущий конфиг восстановлен."
    fi
    log "Конфиг nginx записан и проверен: ${NGINX_CONF}"
}

restart_nginx_checked() {
    if "${REAL_SYSTEMCTL}" restart nginx && "${REAL_SYSTEMCTL}" is-active --quiet nginx; then
        return 0
    fi
    warn "Nginx не запустился. Откатываем конфиг к предыдущей версии."
    warn "Проверьте, не занят ли порт 80: ss -tlnp | grep ':80 '"
    restore_prev_nginx_conf
    if nginx_test_or_show; then
        "${REAL_SYSTEMCTL}" restart nginx || true
    fi
    die "Новая конфигурация Nginx не применена; предыдущая восстановлена."
}

check_http_reachable() {
    local token="remnanode-check-$$" dir="${SITE_ROOT}/.well-known/acme-challenge" code=""
    mkdir -p "${dir}"
    echo "${token}" > "${dir}/${token}"
    chmod 644 "${dir}/${token}"
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
        --resolve "${SITE_DOMAIN}:80:127.0.0.1" "http://${SITE_DOMAIN}/.well-known/acme-challenge/${token}" || true)"
    rm -f "${dir}/${token}"
    if [[ "${code}" != "200" ]]; then
        warn "Локальная проверка ACME-каталога вернула ${code}. Проверьте nginx: nginx -T | less"
    else
        log "ACME-каталог отдаётся через nginx."
    fi
}

issue_certificate() {
    log "Получение сертификата Let's Encrypt для ${SITE_DOMAIN}..."
    mkdir -p "${SITE_ROOT}/.well-known/acme-challenge"
    chmod 755 "${SITE_ROOT_BASE}" "${SITE_ROOT}" "${SITE_ROOT}/.well-known" "${SITE_ROOT}/.well-known/acme-challenge"
    check_http_reachable

    certbot certonly \
        --webroot -w "${SITE_ROOT}" \
        -d "${SITE_DOMAIN}" \
        --agree-tos \
        --register-unsafely-without-email \
        --non-interactive \
        --keep-until-expiring ||
        die "Не удалось получить сертификат. Проверьте DNS и открытый снаружи порт 80."

    [[ -f "/etc/letsencrypt/live/${SITE_DOMAIN}/fullchain.pem" ]] ||
        die "Сертификат не найден после выпуска."

    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    local hook="/etc/letsencrypt/renewal-hooks/deploy/remnanode-selfsteal-reload-nginx.sh"
    backup_file "${hook}"
    printf '#!/bin/sh\nsystemctl reload nginx\n' > "${hook}"
    chmod 755 "${hook}"

    systemctl enable --now certbot.timer >/dev/null 2>&1 || true
    log "Сертификат получен. Автообновление включено (certbot.timer)."
}

# ============================================================
# SITE: GENERATOR (SANDBOXED), INSTALL
# ============================================================

# Подмены команд: генератор не может управлять nginx, ufw, certbot и веб-серверами.
create_generator_shims() {
    local dir="$1" name real="${REAL_SYSTEMCTL}"
    mkdir -p "${dir}"

    for name in nginx apache2 apache2ctl httpd lighttpd caddy certbot ufw; do
        cat > "${dir}/${name}" <<EOF
#!/bin/sh
echo "[installer] команда '${name} \$*' пропущена: этим управляет установщик" >&2
exit 0
EOF
        chmod 755 "${dir}/${name}"
    done

    cat > "${dir}/systemctl" <<EOF
#!/bin/sh
for a in "\$@"; do
    case "\$a" in
        *nginx*|*apache2*|*httpd*|*lighttpd*|*caddy*|*ufw*|*certbot*)
            echo "[installer] systemctl \$* пропущен: этим управляет установщик" >&2
            exit 0 ;;
    esac
done
exec "${real}" "\$@"
EOF
    chmod 755 "${dir}/systemctl"
}

snapshot_nginx() {
    local snap="${WORK_DIR}/nginx-snapshot"
    rm -rf "${snap}"
    cp -a /etc/nginx "${snap}"
    chmod 700 "${snap}"
    NGINX_SNAPSHOT="${snap}"
}

restore_nginx_if_changed() {
    local diffs=""
    diffs="$(diff -rq /etc/nginx "${NGINX_SNAPSHOT}" 2>/dev/null || true)"
    [[ -z "${diffs}" ]] && return 0

    warn "Генератор изменил конфигурацию nginx. Изменения откатываются:"
    printf '%s\n' "${diffs}" | sed 's/^/    /' >&2

    if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete "${NGINX_SNAPSHOT}/" /etc/nginx/
    else
        rm -rf /etc/nginx
        cp -a "${NGINX_SNAPSHOT}" /etc/nginx
    fi
    nginx_test_or_show || die "После отката конфиг nginx не проходит проверку."
    log "Конфиг nginx возвращён к состоянию до генератора."
}

stop_new_foreign_web_servers() {
    local before="$1" unit
    for unit in "${FOREIGN_WEB_UNITS[@]}"; do
        grep -qx "${unit}" "${before}" 2>/dev/null && continue
        if "${REAL_SYSTEMCTL}" is-active --quiet "${unit}" 2>/dev/null; then
            warn "Генератор запустил посторонний веб-сервер ${unit}. Останавливаем и отключаем."
            "${REAL_SYSTEMCTL}" disable --now "${unit}" >/dev/null 2>&1 || true
        fi
    done
}

check_web_ports() {
    local port proc bad=""
    while read -r port proc; do
        [[ -n "${port}" ]] || continue
        case "${port}:${proc}" in
            80:nginx|8443:nginx) ;;
            443:rw-core|443:xray|443:docker-proxy) ;;
            *) bad+="${port} (${proc}) " ;;
        esac
    done < <(listener_owners)

    if [[ -n "${bad}" ]]; then
        warn "На портах заняты посторонние процессы: ${bad}"
        return 1
    fi
    return 0
}

# Ищет свежий index.html вне $1, но только в конкретных каталогах веб-серверов.
find_external_site() {
    local marker="$1" gen_dir="$2" idx="" dir=""
    idx="$(
        find /var/www /usr/share/nginx/html /srv /opt -maxdepth 5 -type f -name 'index.html' \
            -newer "${marker}" \
            -not -path "${SITE_ROOT_BASE}/*" \
            -not -path "${WORK_DIR}/*" \
            -not -path '*/node_modules/*' \
            -printf '%T@ %p\n' 2>/dev/null |
        sort -nr | awk 'NR==1 {$1=""; sub(/^ /,""); print}'
    )" || true

    [[ -n "${idx}" && -f "${idx}" ]] || return 1
    dir="$(dirname "${idx}")"
    case "${dir}" in
        /|/var/www|/srv|/opt|/usr|/usr/share|/usr/share/nginx)
            warn "Найденный каталог слишком общий (${dir}). Сайт не копируется."
            return 1 ;;
    esac
    warn "Генератор записал сайт вне каталога \$1. Найден: ${dir}"
    cp -a "${dir}/." "${gen_dir}/"
    return 0
}

pick_site_source() {
    local gen_dir="$1" marker="$2" cand="" dir="" html=""

    if [[ -f "${gen_dir}/index.html" ]]; then
        SITE_SOURCE_DIR="${gen_dir}"
        return 0
    fi

    cand="$(
        find "${gen_dir}" -mindepth 2 -maxdepth 4 -type f -name 'index.html' -printf '%d %p\n' 2>/dev/null |
        sort -n | head -n1 | cut -d' ' -f2- || true
    )"
    if [[ -n "${cand}" ]]; then
        dir="$(dirname "${cand}")"
        warn "index.html найден в подкаталоге: ${dir#"${gen_dir}"/}. Используем его как корень сайта."
        SITE_SOURCE_DIR="${dir}"
        return 0
    fi

    if find_external_site "${marker}" "${gen_dir}" && [[ -f "${gen_dir}/index.html" ]]; then
        SITE_SOURCE_DIR="${gen_dir}"
        return 0
    fi

    html="$(find "${gen_dir}" -maxdepth 4 -type f -name '*.html' 2>/dev/null | sort | head -n1 || true)"
    if [[ -n "${html}" ]]; then
        cp "${html}" "${gen_dir}/index.html"
        warn "index.html не создан. Первая HTML-страница использована как index.html."
        SITE_SOURCE_DIR="${gen_dir}"
        return 0
    fi
    return 1
}

keep_generator_log() {
    local src="$1" dst="${NGINX_BACKUP_DIR}/generator-${BACKUP_SUFFIX}.log"
    if [[ -f "${src}" ]]; then
        mkdir -p "${NGINX_BACKUP_DIR}"
        cp -p "${src}" "${dst}"
        chmod 600 "${dst}"
        warn "Лог генератора сохранён: ${dst}"
    fi
}

reload_nginx_quiet() {
    if nginx -t >/dev/null 2>&1; then
        if "${REAL_SYSTEMCTL}" is-active --quiet nginx; then
            "${REAL_SYSTEMCTL}" reload nginx >/dev/null 2>&1 || true
        else
            "${REAL_SYSTEMCTL}" start nginx >/dev/null 2>&1 || true
        fi
    fi
}

run_site_generator() {
    local script="$1"
    local gen_dir="${WORK_DIR}/gen-out"
    local shim_dir="${WORK_DIR}/shims"
    local gen_log="${WORK_DIR}/generator.log"
    local marker="${WORK_DIR}/generator.marker"
    local foreign_before="${WORK_DIR}/foreign-before"
    local rc=0 unit

    mkdir -p "${gen_dir}"
    chmod 700 "${gen_dir}"
    cp "${script}" "${gen_dir}/generator.sh"
    chmod 700 "${gen_dir}/generator.sh"

    create_generator_shims "${shim_dir}"

    wait_for_apt
    apt-get update -qq >/dev/null 2>&1 || warn "Не удалось обновить индекс apt до генератора."

    snapshot_nginx

    : > "${foreign_before}"
    for unit in "${FOREIGN_WEB_UNITS[@]}"; do
        "${REAL_SYSTEMCTL}" is-active --quiet "${unit}" 2>/dev/null && echo "${unit}" >> "${foreign_before}"
    done

    touch "${marker}"
    sleep 1

    log "Запуск генератора от root (до ${GENERATOR_TIMEOUT} секунд, ввод отключён)..."

    (
        cd "${gen_dir}"
        env \
            HOME=/root USER=root LOGNAME=root \
            PATH="${shim_dir}:${PATH}" \
            DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 \
            TERM=dumb \
            SITE_DOMAIN="${SITE_DOMAIN}" DOMAIN="${SITE_DOMAIN}" \
            OUT_DIR="${gen_dir}" SITE_OUT="${gen_dir}" WEB_ROOT="${gen_dir}" SITE_ROOT="${gen_dir}" \
            timeout --kill-after=20 "${GENERATOR_TIMEOUT}" bash "${gen_dir}/generator.sh" "${gen_dir}" </dev/null
    ) > "${gen_log}" 2>&1 || rc=$?

    # Что бы ни сделал генератор, возвращаем веб-сервер и фаервол до любых проверок.
    rm -f "${gen_dir}/generator.sh"
    stop_new_foreign_web_servers "${foreign_before}"
    restore_nginx_if_changed
    ensure_firewall_after_generator
    reload_nginx_quiet

    if (( rc != 0 )); then
        tail -n 30 "${gen_log}" >&2 || true
        keep_generator_log "${gen_log}"
        if (( rc == 124 || rc == 137 )); then
            die "Генератор не завершился за ${GENERATOR_TIMEOUT} секунд. Возможно, он ждёт ввод."
        fi
        die "Генератор сайта завершился с кодом ${rc}. Лог сохранён. Nginx и UFW не изменены."
    fi

    check_web_ports || die "Посторонние процессы заняли порты 80/443."
    check_node_running

    if ! pick_site_source "${gen_dir}" "${marker}"; then
        tail -n 30 "${gen_log}" >&2 || true
        keep_generator_log "${gen_log}"
        die "Генератор не создал ни одной HTML-страницы. Проверьте логику генератора и лог."
    fi
    log "Сайт сгенерирован: ${SITE_SOURCE_DIR}"
}

prepare_final_site() {
    local src="$1" final="${WORK_DIR}/final" links size_mb

    rm -rf "${final}"
    mkdir -p "${final}"
    cp -a "${src}/." "${final}/"

    links="$(find "${final}" -type l | wc -l)"
    links="${links//[[:space:]]/}"
    if (( links > 0 )); then
        warn "Удаляем символические ссылки в сайте: ${links} шт."
        find "${final}" -type l -delete
    fi

    find "${final}" \( -name '.git' -o -name '.env*' -o -name '*.key' -o -name '*.pem' \
        -o -name 'node_modules' -o -name '*.sh' \) -prune -exec rm -rf {} + 2>/dev/null || true

    size_mb="$(du -sm "${final}" | awk '{print $1}')"
    (( size_mb < 200 )) || die "Сайт слишком большой: ${size_mb} МБ."
    [[ -f "${final}/index.html" ]] || die "В готовом сайте нет index.html."

    find "${final}" ! -type d ! -type f -delete
    chown -R root:root "${final}"
    find "${final}" -type d -exec chmod 755 {} +
    find "${final}" -type f -exec chmod 644 {} +
    log "Сайт подготовлен: $(find "${final}" -type f | wc -l) файлов, ${size_mb} МБ."
}

install_final_site() {
    local final="${WORK_DIR}/final"

    if [[ -e "${SITE_ROOT}" || -L "${SITE_ROOT}" ]]; then
        local old="${SITE_ROOT}.old.${BACKUP_SUFFIX}"
        mv "${SITE_ROOT}" "${old}"
        log "Прежний сайт сохранён в ${old}."
    fi

    mkdir -p "${SITE_ROOT}"
    cp -a "${final}/." "${SITE_ROOT}/"
    mkdir -p "${SITE_ROOT}/.well-known/acme-challenge"
    chown -R root:root "${SITE_ROOT}"
    find "${SITE_ROOT}" -type d -exec chmod 755 {} +
    find "${SITE_ROOT}" -type f -exec chmod 644 {} +
    [[ -f "${SITE_ROOT}/index.html" ]] || die "После установки в ${SITE_ROOT} нет index.html."
    log "Сайт установлен в ${SITE_ROOT}."
}

# Сайт готовится полностью до любых изменений nginx. Если генератор упал, nginx не трогается.
install_site() {
    [[ -n "${SITE_FILE}" && -s "${SITE_FILE}" ]] || die "Сайт не передан."

    WORK_DIR="$(mktemp -d /tmp/remnanode-work.XXXXXX)"
    chmod 700 "${WORK_DIR}"

    local norm="${WORK_DIR}/site.input"
    cp "${SITE_FILE}" "${norm}"
    chmod 600 "${norm}"

    local kind=""
    kind="$(detect_site_kind "${norm}")"
    case "${kind}" in
        html)
            log "Обнаружена HTML-страница."
            mkdir -p "${WORK_DIR}/html-src"
            cp "${norm}" "${WORK_DIR}/html-src/index.html"
            SITE_SOURCE_DIR="${WORK_DIR}/html-src"
            ;;
        bash)
            log "Обнаружен bash-генератор сайта."
            run_site_generator "${norm}"
            ;;
        *)
            die "Не удалось распознать сайт. Перезапустите установщик и вставьте сайт заново."
            ;;
    esac

    prepare_final_site "${SITE_SOURCE_DIR}"
    install_final_site
}

verify_site() {
    local code
    code="$(
        curl -sk -o /dev/null -w '%{http_code}' --max-time 15 \
            --resolve "${SITE_DOMAIN}:8443:127.0.0.1" \
            "https://${SITE_DOMAIN}:8443/" || true
    )"
    echo "local=${code}"
    [[ "${code}" == "200" ]] || die "Сайт не отвечает кодом 200 (получен ${code})."
    log "Сайт-заглушка отвечает на ${SITE_DOMAIN}."
}

# Порядок: сайт (без изменений nginx) -> конфиг HTTP -> сертификат -> финальный конфиг.
configure_selfsteal() {
    log "Настройка self-steal..."
    install_nginx
    install_generator_tools
    check_nginx_domain_conflicts

    install_site

    write_nginx_config http
    restart_nginx_checked

    issue_certificate

    write_nginx_config ssl
    restart_nginx_checked

    verify_site
}

# ============================================================
# XRAY PROFILE: BUILD AND VALIDATE
# ============================================================

# Проверяет профиль командой xray run -test внутри контейнера ноды.
# Ноду не трогает: проверка идёт на отдельном временном файле.
validate_xray_config() {
    local json="$1" tmp out="" rc=0
    tmp="$(mktemp /tmp/rw-xray-check.XXXXXX.json)"
    chmod 600 "${tmp}"
    printf '%s\n' "${json}" > "${tmp}"

    python3 -m json.tool "${tmp}" >/dev/null 2>&1 || {
        rm -f "${tmp}"
        die "Сгенерированный профиль не является корректным JSON."
    }

    docker exec -i "${CONTAINER_NAME}" sh -c 'cat > /tmp/rw-check.json' < "${tmp}"
    out="$(docker exec "${CONTAINER_NAME}" xray run -test -config /tmp/rw-check.json 2>&1)" || rc=$?
    docker exec "${CONTAINER_NAME}" rm -f /tmp/rw-check.json >/dev/null 2>&1 || true
    rm -f "${tmp}"

    if (( rc != 0 )) || ! grep -qi 'Configuration OK' <<< "${out}"; then
        printf '%s\n' "${out}" | tail -n 20 >&2
        die "Xray не принял конфигурацию. Профиль не выведен. Проверьте значения EU и повторите."
    fi
    log "Профиль проверен Xray: Configuration OK."
}

# Один генератор для обоих случаев (с каскадом и без).
# Структура совпадает с рабочими профилями: inbound Reality, при каскаде outbound на EU и маршрутизация.
build_profile() {
    PROFILE_JSON="$(
        CASCADE="${CASCADE}" \
        INBOUND_NAME="${INBOUND_NAME}" \
        SITE_DOMAIN="${SITE_DOMAIN}" \
        PRIVATE_KEY="${PRIVATE_KEY}" \
        SHORT_ID="${SHORT_ID}" \
        EU_DOMAIN="${EU_SITE_DOMAIN}" \
        EU_UUID="${EU_UUID}" \
        EU_PUBLIC_KEY="${EU_PUBLIC_KEY}" \
        EU_SHORT_ID="${EU_SHORT_ID}" \
        RU_DIRECT="$(printf '%s\n' "${RU_DIRECT_DOMAINS[@]}")" \
        python3 - <<'PY'
import json
import os

e = os.environ
tag = e["INBOUND_NAME"]
cascade = e["CASCADE"] == "1"
ru_direct = [line for line in e["RU_DIRECT"].split("\n") if line]

rules = [
    {"ip": ["geoip:private"], "outboundTag": "BLOCK"},
    {"protocol": ["bittorrent"], "outboundTag": "BLOCK"},
    {"domain": ["geosite:category-ads-all"], "outboundTag": "BLOCK"},
]
outbounds = [
    {"tag": "DIRECT", "protocol": "freedom"},
    {"tag": "BLOCK", "protocol": "blackhole"},
]

if cascade:
    out_tag = "VLESS_OUTBOUND_TO_EU"
    outbounds.append({
        "tag": out_tag,
        "protocol": "vless",
        "settings": {
            "vnext": [{
                "address": e["EU_DOMAIN"],
                "port": 443,
                "users": [{
                    "id": e["EU_UUID"],
                    "flow": "xtls-rprx-vision",
                    "encryption": "none",
                }],
            }]
        },
        "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
                "serverName": e["EU_DOMAIN"],
                "fingerprint": "firefox",
                "publicKey": e["EU_PUBLIC_KEY"],
                "shortId": e["EU_SHORT_ID"],
            },
        },
    })
    rules += [
        {"domain": ru_direct, "outboundTag": "DIRECT"},
        {"ip": ["geoip:ru"], "outboundTag": "DIRECT"},
        {"inboundTag": [tag], "outboundTag": out_tag},
    ]

profile = {
    "log": {"loglevel": "warning"},
    "inbounds": [{
        "tag": tag,
        "port": 443,
        "listen": "0.0.0.0",
        "protocol": "vless",
        "settings": {"clients": [], "decryption": "none"},
        "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]},
        "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
                "dest": "127.0.0.1:8443",
                "show": False,
                "xver": 0,
                "shortIds": [e["SHORT_ID"]],
                "privateKey": e["PRIVATE_KEY"],
                "serverNames": [e["SITE_DOMAIN"]],
            },
        },
    }],
    "outbounds": outbounds,
    "routing": {"rules": rules, "domainStrategy": "IPIfNonMatch"},
}
print(json.dumps(profile, ensure_ascii=False, indent=2))
PY
    )"

    [[ -n "${PROFILE_JSON}" ]] || die "Не удалось собрать профиль."
    validate_xray_config "${PROFILE_JSON}"
}

show_block() {
    echo
    echo "========================================"
    echo "  $1"
    echo "========================================"
    echo
    printf '%s\n' "$2"
    echo
    echo "========================================"
}

# Выводит профиль и параметры. Файлов с профилем не создаётся.
output_node_profile() {
    build_profile

    show_block "PUBLIC KEY и SHORT ID (для клиентских конфигов)" \
        "PublicKey: ${PUBLIC_KEY}"$'\n'"Short ID:   ${SHORT_ID}"

    if (( CASCADE == 1 )); then
        show_block "PROFILE RU-НОДЫ (вставить в панель для RU)" "${PROFILE_JSON}"
    else
        show_block "PROFILE ЭТОЙ НОДЫ (вставить в панель)" "${PROFILE_JSON}"
    fi
    warn "Профиль содержит приватный ключ. Не публикуйте его."
    PROFILE_JSON=""
}

# ============================================================
# CASCADE: STATE, EU DATA, FINAL STEP
# ============================================================

state_get() {
    sed -n "s/^$1=//p" "${CASCADE_STATE_FILE}" | head -n1
}

save_cascade_state() {
    umask 077
    cat > "${CASCADE_STATE_FILE}" <<EOF
SITE_DOMAIN=${SITE_DOMAIN}
INBOUND_NAME=${INBOUND_NAME}
PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_KEY=${PUBLIC_KEY}
SHORT_ID=${SHORT_ID}
EU_SITE_DOMAIN=${EU_SITE_DOMAIN}
EU_UUID=${EU_UUID}
EOF
    chmod 600 "${CASCADE_STATE_FILE}"
    log "Состояние каскада сохранено: ${CASCADE_STATE_FILE}"
}

load_cascade_state() {
    [[ -f "${CASCADE_STATE_FILE}" ]] || die "Файл состояния каскада не найден."

    SITE_DOMAIN="$(state_get SITE_DOMAIN)"
    INBOUND_NAME="$(state_get INBOUND_NAME)"
    PRIVATE_KEY="$(state_get PRIVATE_KEY)"
    PUBLIC_KEY="$(state_get PUBLIC_KEY)"
    SHORT_ID="$(state_get SHORT_ID)"
    EU_SITE_DOMAIN="$(state_get EU_SITE_DOMAIN)"
    EU_UUID="$(state_get EU_UUID)"

    if [[ "${SITE_DOMAIN}" =~ ${DOMAIN_RE} ]] &&
       [[ "${INBOUND_NAME}" =~ ${NAME_RE} ]] &&
       [[ "${PRIVATE_KEY}" =~ ${PUBKEY_RE} ]] &&
       [[ "${PUBLIC_KEY}" =~ ${PUBKEY_RE} ]] &&
       [[ "${SHORT_ID}" =~ ${SHORTID_RE} ]] &&
       [[ "${EU_SITE_DOMAIN}" =~ ${DOMAIN_RE} ]] &&
       [[ "${EU_UUID}" =~ ${UUID_RE} ]]; then
        SELFSTEAL=1
        CASCADE=1
    else
        die "Состояние каскада повреждено. Запустите пункт 4 (переустановка RU)."
    fi
}

cascade_show_eu_instructions() {
    local text
    text="$(cat <<EOF
1. На EU-сервере (${EU_SITE_DOMAIN}) должна быть чистая Ubuntu 24.04.
2. Создайте ноду для EU в панели Remnawave, скопируйте её SECRET_KEY.
3. Зайдите по SSH на EU и выполните:
   bash <(curl -fsSL ${INSTALLER_URL})
4. Выберите пункт 2 (установка с self-steal) и введите:
   - SECRET_KEY EU-ноды;
   - домен: ${EU_SITE_DOMAIN};
   - название инбаунда EU;
   - сайт-заглушку (HTML или bash-генератор, затем Ctrl+D).
5. В конце EU-установщик выведет PublicKey и Short ID. Запишите их.
6. Вставьте PROFILE EU в конфиг-профиль панели для EU-ноды.
7. В панели добавьте клиента с UUID ${EU_UUID} и flow xtls-rprx-vision на инбаунд EU.
   Без этого клиента RU не сможет подключиться к EU.
8. Вернитесь на RU и выберите пункт 5.
EOF
)"
    show_block "ДЕЙСТВИЕ НА EU-СЕРВЕРЕ" "${text}"
}

cascade_ask_eu_keys() {
    echo
    info "Введите PublicKey и Short ID, которые EU-установщик вывел в конце."

    while true; do
        ask_valid EU_PUBLIC_KEY "PublicKey с EU: " "${PUBKEY_RE}" "Некорректный PublicKey (43 символа, base64url)."
        if [[ "${EU_PUBLIC_KEY}" == "${PUBLIC_KEY}" ]]; then
            warn "Этот PublicKey совпадает с ключом RU. Введите PublicKey именно с EU."
            continue
        fi
        if [[ "${EU_PUBLIC_KEY}" == "${PRIVATE_KEY}" ]]; then
            warn "Это PrivateKey RU. Нужен PublicKey с EU."
            continue
        fi
        break
    done

    ask_valid EU_SHORT_ID "Short ID с EU: " "${SHORTID_RE}" "Некорректный Short ID (чётное число hex-символов, до 16)."
    EU_SHORT_ID="${EU_SHORT_ID,,}"
    log "Данные EU приняты."
}

# Проверяет, что EU принимает TCP на 443. Не блокирует: проверка может не пройти из-за временного сбоя.
check_eu_reachable() {
    if timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/443"' _ "${EU_SITE_DOMAIN}" 2>/dev/null; then
        log "EU ${EU_SITE_DOMAIN}:443 доступен по TCP."
    else
        warn "EU ${EU_SITE_DOMAIN}:443 не отвечает по TCP с RU."
        warn "Проверьте, что EU поднят и DNS указывает на него. Профиль всё равно будет выведен."
    fi
}

finish_cascade() {
    echo
    warn "Скопируйте профиль RU выше."
    warn "Если прервать сейчас, профиль можно вывести заново пунктом 5."
    read -r -p "Профиль скопирован, нажмите Enter для удаления состояния с приватным ключом: " _
    rm -f "${CASCADE_STATE_FILE}"
    log "Каскад завершён, состояние удалено."
}

# Общий финальный шаг каскада на RU: ключи EU -> проверки -> профиль RU.
cascade_finalize() {
    cascade_ask_eu_keys
    check_eu_reachable
    output_node_profile
    finish_cascade
}

# ============================================================
# FLOWS
# ============================================================

resume_cascade() {
    load_cascade_state
    check_node_running
    log "Состояние каскада загружено."
    cascade_show_eu_instructions
    cascade_finalize
}

resume_selfsteal() {
    check_node_running

    SELFSTEAL=1
    CASCADE=0

    warn "Нода не переустанавливается, но Reality-ключи будут сгенерированы заново."
    warn "Новый профиль нужно вставить в панель вместо старого."
    confirm_continue "Продолжить? [y/N]: "

    install_packages
    preflight_ports
    ask_selfsteal_domain
    ask_inbound_name INBOUND_NAME "Название инбаунда этой ноды (например, RU_IN): "
    collect_site

    configure_selfsteal
    generate_keys
    output_node_profile
}

fresh_install() {
    if (( REINSTALL == 0 )); then
        if [[ -d "${INSTALL_DIR}" ]] || docker_container_exists; then
            die "Обнаружена существующая установка. Выберите пункт 4 (переустановка) или 6 (доделать self-steal)."
        fi
    fi

    collect_answers

    install_packages
    install_docker
    preflight_ports

    if (( REINSTALL == 1 )); then
        remove_remnanode
    fi

    detect_system
    configure_modules
    configure_sysctl
    configure_qdisc
    configure_docker_limits
    configure_docker_logging
    configure_journald
    restart_docker
    verify_docker_limits
    verify_docker_logging

    configure_firewall
    create_configuration
    start_node
    generate_keys

    if (( SELFSTEAL == 1 )); then
        configure_selfsteal
    fi

    if (( CASCADE == 1 )); then
        save_cascade_state
        log "Часть для RU готова. Дальше нужно действие на EU."
        cascade_show_eu_instructions
        cascade_finalize
    elif (( SELFSTEAL == 1 )); then
        output_node_profile
    else
        show_plain_parameters
    fi
}

show_result() {
    local mode_name="без self-steal"
    (( SELFSTEAL == 1 )) && mode_name="с self-steal"
    (( CASCADE == 1 )) && mode_name="каскад RU -> EU"

    echo
    echo "========================================"
    echo "          INSTALLATION COMPLETE"
    echo "========================================"
    log "Remnawave Node: ${mode_name}"
    log "Container: ${CONTAINER_NAME}, image: ${IMAGE}"
    log "Install directory: ${INSTALL_DIR}"
    if (( SELFSTEAL == 1 )); then
        log "Домен self-steal: ${SITE_DOMAIN}"
        log "nginx: ${NGINX_VERSION:-уже был установлен}"
        log "Сайт: ${SITE_ROOT}"
    fi
    if (( CASCADE == 1 )); then
        log "EU: ${EU_SITE_DOMAIN}"
    fi
    echo "========================================"
}

# ============================================================
# MAIN
# ============================================================

main() {
    check_system
    read_existing_secret
    select_mode

    if (( RESUME_CASCADE == 1 )); then
        resume_cascade
    elif (( RESUME_SITE == 1 )); then
        resume_selfsteal
    else
        fresh_install
    fi

    show_result
}

main "$@"
