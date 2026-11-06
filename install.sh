#!/usr/bin/env bash
#
# Remnawave Node installer
# Режимы: 1) без self-steal  2) с self-steal  3) каскад RU -> EU  4) переустановка
#
set -Eeuo pipefail

INSTALLER_VERSION="1.6.0"
INSTALLER_URL="https://raw.githubusercontent.com/Wanderer-95/remnanode-installer/main/install.sh"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

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
SITE_ROOT="/var/www/html"

BACKUP_SUFFIX="$(date +%Y%m%d-%H%M%S)"

DOMAIN_RE='^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$'
UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
PUBKEY_RE='^[A-Za-z0-9_-]{43}$'
SHORTID_RE='^[0-9a-f]{2,16}$'

# ============================================================
# STATE
# ============================================================

MENU_ACTION=""
REINSTALL=0
REINSTALL_TYPE=""
CONFIRM_DELETE=""
SELFSTEAL=0
CASCADE=0

MAIN_INTERFACE=""
EXISTING_SECRET_KEY=""
SECRET_KEY=""
RESTART_CONFIRM=""
INBOUND_NAME=""
SITE_DOMAIN=""
SITE_FILE=""
PASTE_TMP=""
NGINX_VERSION=""

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
    if [[ -n "${PASTE_TMP}" && -f "${PASTE_TMP}" ]]; then
        rm -f "${PASTE_TMP}"
    fi
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
        if [[ -n "${value}" ]]; then
            break
        fi
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

# ask_secret_confirmed VAR "подсказка" — секрет вводится дважды
ask_secret_confirmed() {
    local var="$1" prompt="$2" again=""

    while true; do
        ask "${var}" "${prompt}" 1
        read -r -s -p "Повторите: " again
        echo
        if [[ "${!var}" == "${again}" ]]; then
            return 0
        fi
        warn "Значения не совпадают. Попробуйте снова."
        printf -v "${var}" '%s' ''
    done
}

# ============================================================
# CHECKS AND MENU
# ============================================================

check_system() {
    [[ "${EUID}" -eq 0 ]] || die "Запустите установщик от root."

    [[ -t 0 ]] || die "Нужен интерактивный терминал."

    [[ -f /etc/os-release ]] || die "Не удалось определить ОС."
    # shellcheck disable=SC1091
    . /etc/os-release

    [[ "${ID:-}" == "ubuntu" ]] || die "Поддерживается только Ubuntu."

    if [[ "${VERSION_ID:-}" != "24.04" ]]; then
        warn "Рекомендуется Ubuntu 24.04. Текущая версия: ${VERSION_ID:-unknown}"
        local answer=""
        read -r -p "Продолжить? [y/N]: " answer
        [[ "${answer}" =~ ^[Yy]$ ]] || exit 0
    fi

    log "Операционная система: ${PRETTY_NAME:-Ubuntu}"
    log "Версия установщика: ${INSTALLER_VERSION}"
}

apply_type() {
    case "$1" in
        1) SELFSTEAL=0; CASCADE=0; log "Выбрана установка без self-steal." ;;
        2) SELFSTEAL=1; CASCADE=0; log "Выбрана установка с self-steal." ;;
        3) SELFSTEAL=1; CASCADE=1; log "Выбран каскад RU -> EU (с self-steal)." ;;
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

    warn "Будет удалён текущий Remnawave Node."
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
    echo "3) Каскад RU -> EU (с self-steal)"
    echo "4) Удалить Remnawave Node и установить заново"
    echo "0) Выход"
    echo

    ask MENU_ACTION "Выберите действие: "

    case "${MENU_ACTION}" in
        1|2|3)
            REINSTALL=0
            apply_type "${MENU_ACTION}"
            ;;
        4)
            select_reinstall
            ;;
        0)
            exit 0
            ;;
        *)
            die "Неверный пункт меню."
            ;;
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
        )"
    fi
}

docker_container_exists() {
    docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1
}

backup_file() {
    local file="$1"
    if [[ -f "${file}" ]]; then
        cp -a "${file}" "${file}.bak.${BACKUP_SUFFIX}"
    fi
}

# ============================================================
# COLLECT ALL ANSWERS BEFORE CHANGING THE SERVER
# ============================================================

read_secret_key() {
    if [[ -n "${EXISTING_SECRET_KEY}" ]]; then
        echo
        info "Найден SECRET_KEY от предыдущей установки."
        local choice=""
        ask choice "1) оставить существующий, 2) ввести новый: "
        if [[ "${choice}" == "1" ]]; then
            SECRET_KEY="${EXISTING_SECRET_KEY}"
            log "Используется существующий SECRET_KEY."
            return 0
        fi
    fi

    ask_secret_confirmed SECRET_KEY "SECRET_KEY Remnawave Node из панели (ввод скрыт): "
    log "SECRET_KEY принят."
}

ask_selfsteal_domain() {
    ask_valid SITE_DOMAIN "Домен этой ноды (self-steal, A-запись на этот сервер): " "${DOMAIN_RE}" "Некорректный домен."
    SITE_DOMAIN="${SITE_DOMAIN,,}"
    log "Домен: ${SITE_DOMAIN}"
}

collect_site() {
    if [[ -n "${SITE_FILE}" ]]; then
        [[ -s "${SITE_FILE}" ]] || die "Файл сайта не найден или пустой: ${SITE_FILE}"
        return 0
    fi

    echo
    info "Вставьте сайт целиком (HTML или Bash-генератор), затем на новой строке нажмите Ctrl+D."
    PASTE_TMP="$(mktemp /tmp/remnanode-site.XXXXXX)"
    chmod 600 "${PASTE_TMP}"
    cat > "${PASTE_TMP}"
    [[ -s "${PASTE_TMP}" ]] || die "Сайт пустой."
    SITE_FILE="${PASTE_TMP}"
}

ask_restart_if_needed() {
    local count=0
    if command -v docker >/dev/null 2>&1; then
        count="$(
            docker ps --format '{{.Names}}' 2>/dev/null |
            { grep -vx "${CONTAINER_NAME}" || true; } |
            wc -l
        )"
    fi
    count="${count//[[:space:]]/}"

    if [[ "${count}" =~ ^[0-9]+$ ]] && (( count > 0 )); then
        warn "На сервере есть другие запущенные контейнеры (${count})."
        warn "Перезапуск Docker временно прервёт их работу. Контейнеры с restart policy поднимутся сами."
        ask_valid RESTART_CONFIRM "Для перезапуска Docker введите RESTART: " '^RESTART$' "Введите RESTART."
    else
        RESTART_CONFIRM="RESTART"
    fi
}

ask_cascade_params() {
    echo
    info "Параметры EU-ноды. Скрипт не заходит на EU сам: эти данные нужны для профиля RU"
    info "и для инструкции, которую вы выполните на EU вручную."

    ask_valid EU_SITE_DOMAIN "Домен EU-ноды (A-запись на EU): " "${DOMAIN_RE}" "Некорректный домен."
    EU_SITE_DOMAIN="${EU_SITE_DOMAIN,,}"
    ask_valid EU_UUID "UUID пользователя для RU на EU (flow xtls-rprx-vision): " "${UUID_RE}" "Некорректный UUID."
    ask EU_INBOUND_NAME "Название инбаунда на EU (например, DE_IN): "
}

collect_answers() {
    read_secret_key

    if (( SELFSTEAL == 1 )); then
        ask_selfsteal_domain
        ask INBOUND_NAME "Название инбаунда этой ноды (например, RU_IN): "
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
    log "Удаление предыдущего Remnawave Node..."

    if docker_container_exists; then
        docker rm -f "${CONTAINER_NAME}" >/dev/null
    fi

    if [[ -d "${INSTALL_DIR}" ]]; then
        rm -rf "${INSTALL_DIR}"
        log "Удалён каталог ${INSTALL_DIR}."
    fi

    rm -f "${NGINX_CONF}"
    if systemctl is-active --quiet nginx; then
        systemctl reload nginx || warn "Не удалось перезагрузить nginx."
    fi
}

# ============================================================
# APT AND PACKAGES
# ============================================================

wait_for_apt() {
    if ! command -v fuser >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y -qq psmisc >/dev/null 2>&1 ||
            die "Не удалось установить psmisc."
    fi

    local waited=0
    local locks=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock)

    while fuser "${locks[@]}" >/dev/null 2>&1; do
        if (( waited == 0 )); then
            warn "Ждём освобождения apt (обычно это unattended-upgrades)..."
        fi
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
        iproute2 iptables kmod ufw psmisc
    log "Необходимые пакеты установлены."
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
    docker compose version >/dev/null 2>&1 || die "Docker Compose не найден."
    log "Docker и Docker Compose доступны."
}

# ============================================================
# SYSTEM TUNING
# ============================================================

detect_system() {
    echo
    info "Определение параметров системы..."
    echo "Kernel: $(uname -r)"
    echo "Architecture: $(uname -m)"

    if command -v systemd-detect-virt >/dev/null 2>&1; then
        echo "Virtualization: $(systemd-detect-virt 2>/dev/null || echo unknown)"
    fi

    MAIN_INTERFACE="$(
        ip -4 route get 1.1.1.1 2>/dev/null |
        awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true
    )"
    if [[ -z "${MAIN_INTERFACE}" ]]; then
        MAIN_INTERFACE="$(
            ip -o link show | awk -F': ' '$2 != "lo" {print $2; exit}' || true
        )"
    fi
    if [[ -n "${MAIN_INTERFACE}" ]]; then
        log "Основной интерфейс: ${MAIN_INTERFACE}"
    else
        warn "Не удалось определить сетевой интерфейс."
    fi

    if modprobe tcp_bbr 2>/dev/null; then
        log "Модуль TCP BBR доступен."
    elif grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
        log "BBR встроен в ядро."
    else
        warn "BBR не поддерживается текущим ядром."
    fi

    if modprobe sch_fq 2>/dev/null; then
        log "Модуль sch_fq доступен."
    else
        warn "Модуль sch_fq недоступен."
    fi

    if modprobe nf_conntrack 2>/dev/null; then
        log "Модуль nf_conntrack загружен."
    else
        warn "Не удалось загрузить nf_conntrack."
    fi
}

configure_modules() {
    log "Настройка автозагрузки nf_conntrack..."
    mkdir -p /etc/modules-load.d
    backup_file "${MODULES_FILE}"
    touch "${MODULES_FILE}"
    if ! grep -qxF nf_conntrack "${MODULES_FILE}"; then
        echo "nf_conntrack" >> "${MODULES_FILE}"
    fi
    modprobe nf_conntrack || warn "nf_conntrack пока не загружен."
    log "Автозагрузка модуля настроена."
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
        if [[ "${line}" =~ ^# ]]; then
            continue
        fi
        key="$(xargs <<< "${line%%=*}")"
        value="$(xargs <<< "${line#*=}")"

        if [[ ! -e "/proc/sys/${key//./\/}" ]]; then
            warn "Параметр не поддерживается: ${key}"
            continue
        fi

        if sysctl -w "${key}=${value}" >/dev/null 2>&1; then
            echo "${key} = ${value}" >> "${SYSCTL_FILE}"
            log "${key} применён."
        else
            warn "Не удалось применить ${key}."
        fi
    done <<< "${lines}"

    chmod 644 "${SYSCTL_FILE}"
}

configure_qdisc() {
    log "Настройка активной очереди FQ..."

    if [[ -z "${MAIN_INTERFACE}" ]] || ! command -v tc >/dev/null 2>&1; then
        warn "Пропускаем настройку FQ на интерфейсе."
        return 0
    fi

    if tc qdisc replace dev "${MAIN_INTERFACE}" root fq 2>/dev/null; then
        log "FQ применён к ${MAIN_INTERFACE}."
    else
        warn "Не удалось применить FQ к ${MAIN_INTERFACE}."
    fi
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
    log "Лимиты Docker записаны."
}

configure_docker_logging() {
    log "Настройка Docker logging..."
    mkdir -p /etc/docker
    backup_file "${DOCKER_DAEMON_JSON}"

    python3 - "${DOCKER_DAEMON_JSON}" <<'PY'
import json
import os
import sys
import tempfile

path = sys.argv[1]
config = {}

if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as f:
        config = json.load(f)

if not isinstance(config, dict):
    raise SystemExit("daemon.json должен содержать JSON-объект")

config["log-driver"] = "json-file"
log_opts = config.get("log-opts", {})
if not isinstance(log_opts, dict):
    raise SystemExit("log-opts должен быть JSON-объектом")
log_opts["max-size"] = "50m"
log_opts["max-file"] = "3"
config["log-opts"] = log_opts

directory = os.path.dirname(path)
fd, temp_path = tempfile.mkstemp(prefix="daemon.json.", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2)
        f.write("\n")
    os.chmod(temp_path, 0o644)
    os.replace(temp_path, path)
except Exception:
    if os.path.exists(temp_path):
        os.unlink(temp_path)
    raise
PY

    python3 -m json.tool "${DOCKER_DAEMON_JSON}" >/dev/null
    dockerd --validate --config-file="${DOCKER_DAEMON_JSON}" >/dev/null 2>&1 ||
        die "Конфигурация Docker не прошла проверку."
    log "Конфигурация Docker прошла проверку."
}

configure_journald() {
    log "Настройка journald..."
    mkdir -p /etc/systemd/journald.conf.d
    backup_file "${JOURNALD_DROPIN}"
    cat > "${JOURNALD_DROPIN}" <<'EOF'
[Journal]
SystemMaxUse=200M
EOF
    chmod 644 "${JOURNALD_DROPIN}"
    systemctl restart systemd-journald
    journalctl --vacuum-size=200M >/dev/null 2>&1 || true
    log "Лимит journald: 200M."
}

restart_docker() {
    log "Перезапуск Docker для применения лимитов и логов..."
    systemctl daemon-reload
    systemctl restart docker
    systemctl is-active --quiet docker || die "Docker не запустился после перезапуска."
    docker info >/dev/null 2>&1 || die "Docker API недоступен после перезапуска."
    log "Docker перезапущен."
}

verify_docker_limits() {
    local pid limits nofile nproc
    pid="$(systemctl show docker -p MainPID --value)"
    [[ "${pid}" =~ ^[0-9]+$ ]] && (( pid > 0 )) || die "Процесс Docker не запущен."

    limits="/proc/${pid}/limits"
    nofile="$(awk '/Max open files/ {print $4; exit}' "${limits}")"
    nproc="$(awk '/Max processes/ {print $4; exit}' "${limits}")"

    echo "Docker PID: ${pid}, LimitNOFILE: ${nofile}, LimitNPROC: ${nproc}"
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

detect_ssh_port() {
    local port=""
    mkdir -p /run/sshd 2>/dev/null || true
    port="$(
        { sshd -T 2>/dev/null || true; } |
        awk '$1=="port" {print $2; exit}'
    )"
    if [[ ! "${port}" =~ ^[0-9]+$ ]]; then
        # Порт текущего SSH-соединения: server_port — четвёртое поле SSH_CONNECTION.
        port="$(awk '{print $4}' <<< "${SSH_CONNECTION:-}" 2>/dev/null || true)"
    fi
    [[ "${port}" =~ ^[0-9]+$ ]] || port="22"
    echo "${port}"
}

configure_firewall() {
    log "Настройка UFW..."
    local ssh_port
    ssh_port="$(detect_ssh_port)"

    ufw allow "${ssh_port}/tcp" comment 'SSH' >/dev/null
    ufw allow 2222/tcp comment 'Remnawave Node API' >/dev/null
    ufw allow 443/tcp comment 'Reality' >/dev/null

    if (( SELFSTEAL == 1 )); then
        ufw allow 80/tcp comment 'ACME and HTTP' >/dev/null
    fi

    local state
    state="$(ufw status 2>/dev/null || true)"
    if grep -q "Status: inactive" <<< "${state}"; then
        ufw --force enable >/dev/null
    fi

    log "UFW настроен. SSH-порт: ${ssh_port}."
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
    docker compose pull
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

generate_keys() {
    log "Генерация ключей Reality (X25519)..."

    local out
    out="$(docker exec "${CONTAINER_NAME}" xray x25519)" || die "Не удалось сгенерировать X25519."

    # Новые версии Xray печатают "Password (PublicKey)", старые — "PublicKey".
    PRIVATE_KEY="$(awk -F': *' '/^PrivateKey/ {print $2; exit}' <<< "${out}" | tr -d '[:space:]')"
    PUBLIC_KEY="$(awk -F': *' '/^(PublicKey|Password)/ {print $2; exit}' <<< "${out}" | tr -d '[:space:]')"
    SHORT_ID="$(openssl rand -hex 8)"

    [[ -n "${PRIVATE_KEY}" && -n "${PUBLIC_KEY}" ]] || die "Не удалось разобрать вывод xray x25519."
    log "Ключи сгенерированы."
}

generate_parameters() {
    # Режим без self-steal: только вывод параметров.
    generate_keys
    echo
    echo "========================================"
    echo "          NODE PARAMETERS"
    echo "========================================"
    echo "PrivateKey: ${PRIVATE_KEY}"
    echo "PublicKey:  ${PUBLIC_KEY}"
    echo "Short ID:   ${SHORT_ID}"
    echo "========================================"
}

# ============================================================
# NGINX AND CERTIFICATE (SELF-STEAL)
# ============================================================

install_nginx() {
    log "Установка nginx..."

    # Остатки неудачной установки из nginx.org (без подписи) мешают apt update.
    rm -f /etc/apt/sources.list.d/nginx.list \
          /etc/apt/preferences.d/99-nginx-org \
          /usr/share/keyrings/nginx-archive-keyring.gpg

    wait_for_apt
    apt-get update -qq
    wait_for_apt
    apt-get install -y -qq nginx certbot >/dev/null

    rm -f /etc/nginx/sites-enabled/default
    systemctl enable nginx >/dev/null 2>&1 || true

    NGINX_VERSION="$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
    [[ -n "${NGINX_VERSION}" ]] || die "Не удалось определить версию nginx."
    log "nginx ${NGINX_VERSION} установлен."
}

write_nginx_config() {
    local stage="$1"
    mkdir -p /etc/nginx/conf.d

    if [[ "${stage}" == "http" ]]; then
        cat > "${NGINX_CONF}" <<'NGINX'
server {
    listen 80;
    listen [::]:80;
    server_name __DOMAIN__;
    root /var/www/html;
    location /.well-known/acme-challenge/ { allow all; }
    location / { return 200 'ok'; add_header Content-Type text/plain; }
}
NGINX
    else
        cat > "${NGINX_CONF}" <<'NGINX'
server {
    listen 80;
    listen [::]:80;
    server_name __DOMAIN__;
    location /.well-known/acme-challenge/ { root /var/www/html; allow all; }
    location / { return 301 https://$host$request_uri; }
}

server {
    listen 127.0.0.1:8443 ssl http2;
    server_name __DOMAIN__;

    ssl_certificate     /etc/letsencrypt/live/__DOMAIN__/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/__DOMAIN__/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    root /var/www/html;
    index index.html;
    add_header X-Content-Type-Options nosniff;

    location / { try_files $uri $uri/ =404; }
}
NGINX
    fi

    sed -i "s|__DOMAIN__|${SITE_DOMAIN}|g" "${NGINX_CONF}"
    log "Конфиг nginx записан: ${NGINX_CONF}"
}

issue_certificate() {
    log "Получение сертификата Let's Encrypt для ${SITE_DOMAIN}..."

    mkdir -p "${SITE_ROOT}"
    certbot certonly \
        --webroot -w "${SITE_ROOT}" \
        -d "${SITE_DOMAIN}" \
        --agree-tos \
        --register-unsafely-without-email \
        --non-interactive \
        --keep-until-expiring ||
        die "Не удалось получить сертификат. Проверьте DNS-запись и открытый порт 80."

    [[ -f "/etc/letsencrypt/live/${SITE_DOMAIN}/fullchain.pem" ]] ||
        die "Сертификат не найден после выпуска."

    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    printf '#!/bin/sh\nsystemctl reload nginx\n' > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
    chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

    if ! certbot renew --dry-run >/dev/null 2>&1; then
        warn "Проверка автообновления не прошла. Проверьте порт 80 снаружи:"
        warn "  curl -I http://${SITE_DOMAIN}   (с другой машины)"
    fi

    log "Сертификат получен."
}

install_site() {
    [[ -n "${SITE_FILE}" && -s "${SITE_FILE}" ]] || die "Файл сайта не найден: ${SITE_FILE}"
    mkdir -p "${SITE_ROOT}"

    local first_line
    first_line="$(sed -n '/[^[:space:]]/{p;q;}' "${SITE_FILE}")"

    if [[ "${first_line}" == '#!'* ]]; then
        log "Обнаружен Bash-генератор сайта. Выполнение..."
        bash "${SITE_FILE}" "${SITE_ROOT}" || die "Генератор сайта завершился с ошибкой."
    elif grep -qiE '<!doctype html|<html' "${SITE_FILE}"; then
        cp "${SITE_FILE}" "${SITE_ROOT}/index.html"
        log "HTML-страница сохранена как index.html."
    else
        die "Не удалось распознать сайт: нужен HTML или Bash-генератор."
    fi

    [[ -f "${SITE_ROOT}/index.html" ]] || die "После установки сайта нет index.html в ${SITE_ROOT}."

    find "${SITE_ROOT}" -type d -exec chmod 755 {} +
    find "${SITE_ROOT}" -type f -exec chmod 644 {} +
    log "Сайт установлен в ${SITE_ROOT}."
}

verify_site() {
    local code
    code="$(
        curl -sk -o /dev/null -w '%{http_code}' \
            --resolve "${SITE_DOMAIN}:8443:127.0.0.1" \
            "https://${SITE_DOMAIN}:8443/" || true
    )"
    echo "local=${code}"
    [[ "${code}" == "200" ]] || die "Сайт не отвечает кодом 200 (получен ${code})."
    log "Сайт-заглушка отвечает на ${SITE_DOMAIN}."
}

configure_selfsteal() {
    log "Настройка self-steal..."
    install_nginx
    write_nginx_config http
    nginx -t >/dev/null 2>&1 || die "Конфигурация nginx не прошла проверку."
    systemctl restart nginx

    issue_certificate

    write_nginx_config ssl
    nginx -t >/dev/null 2>&1 || die "Финальный конфиг nginx не прошёл проверку."
    systemctl restart nginx

    install_site
    verify_site
}

# ============================================================
# CASCADE: MANUAL STEP ON EU
# ============================================================

cascade_show_eu_instructions() {
    local text
    text="$(cat <<EOF
1. Зайдите по SSH на EU-сервер (${EU_SITE_DOMAIN}). Сервер должен быть чистым, Ubuntu 24.04.
2. Выполните команду:
   bash <(curl -fsSL ${INSTALLER_URL})
3. Выберите пункт 2 (установка с self-steal).
4. Введите данные по запросам:
   - SECRET_KEY EU-ноды из панели Remnawave;
   - домен: ${EU_SITE_DOMAIN};
   - название инбаунда: ${EU_INBOUND_NAME};
   - сайт-заглушка (вставьте HTML или Bash-генератор, затем Ctrl+D).
5. В конце установщик покажет PublicKey и Short ID. Скопируйте их, они понадобятся на RU.
6. Из вывода установщика на EU возьмите PROFILE и вставьте его в конфиг-профиль панели Remnawave для EU-ноды.
7. В этом же профиле или в панели добавьте пользователя с UUID ${EU_UUID} и flow xtls-rprx-vision.
8. Вернитесь на RU-сервер. Скрипт будет ждать ввода PublicKey и Short ID с EU.
EOF
)"
    show_block "ДЕЙСТВИЕ НА EU-СЕРВЕРЕ" "${text}"
}

cascade_ask_eu_keys() {
    echo
    info "Введите данные, которые EU-установщик вывел в конце."
    ask_valid EU_PUBLIC_KEY "PublicKey с EU: " "${PUBKEY_RE}" "Некорректный PublicKey (43 символа)."
    ask_valid EU_SHORT_ID "Short ID с EU: " "${SHORTID_RE}" "Некорректный Short ID (hex, 2-16 символов)."
    log "Данные EU приняты."
}

# ============================================================
# PROFILE
# ============================================================

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
        python3 - <<'PY'
import json
import os

e = os.environ
tag = "VLESS-Reality-" + e["INBOUND_NAME"]
cascade = e["CASCADE"] == "1"

ru_direct = [
    "geosite:category-ru",
    "domain:vk.com", "domain:vk.ru", "domain:userapi.com",
    "domain:vk-cdn.net", "domain:vkuservideo.net", "domain:vkvideo.ru",
    "domain:mycdn.me", "domain:ok.ru", "domain:mail.ru", "domain:imgsmail.ru",
    "domain:yandex.ru", "domain:ya.ru", "domain:dzen.ru", "domain:rutube.ru",
    "domain:kinopoisk.ru", "domain:gosuslugi.ru", "domain:mos.ru",
    "domain:sberbank.ru", "domain:tbank.ru", "domain:avito.ru",
    "domain:wildberries.ru", "domain:ozon.ru",
]

outbounds = [
    {"tag": "DIRECT", "protocol": "freedom"},
    {"tag": "BLOCK", "protocol": "blackhole"},
]

rules = [
    {"ip": ["geoip:private"], "outboundTag": "BLOCK"},
    {"protocol": ["bittorrent"], "outboundTag": "BLOCK"},
    {"domain": ["geosite:category-ads-all"], "outboundTag": "BLOCK"},
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
    "dns": {"servers": ["1.1.1.1", "1.0.0.1"], "queryStrategy": "UseIPv4"},
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

output_profiles() {
    show_block "PUBLIC KEY и SHORT ID (для клиентских конфигов)" \
        "PublicKey: ${PUBLIC_KEY}"$'\n'"Short ID:   ${SHORT_ID}"

    show_block "PROFILE ЭТОЙ НОДЫ (вставить в панель)" "${PROFILE_JSON}"
    warn "Профиль содержит приватный ключ. Не публикуйте его."
    PROFILE_JSON=""
}

# ============================================================
# SHOW RESULT
# ============================================================

show_result() {
    local mode_name="без self-steal"
    if (( SELFSTEAL == 1 )); then
        mode_name="с self-steal"
    fi
    if (( CASCADE == 1 )); then
        mode_name="каскад RU -> EU"
    fi

    echo
    echo "========================================"
    echo "          INSTALLATION COMPLETE"
    echo "========================================"
    log "Remnawave Node установлен."
    log "Режим: ${mode_name}"
    log "Container: ${CONTAINER_NAME}, image: ${IMAGE}"
    log "Install directory: ${INSTALL_DIR}"
    if (( SELFSTEAL == 1 )); then
        log "Домен self-steal: ${SITE_DOMAIN}"
        log "nginx: ${NGINX_VERSION}"
    fi
    if (( CASCADE == 1 )); then
        log "EU: ${EU_SITE_DOMAIN}"
    fi
    if [[ -n "${MAIN_INTERFACE}" ]]; then
        echo "Network interface: ${MAIN_INTERFACE}"
        tc qdisc show dev "${MAIN_INTERFACE}" 2>/dev/null || true
    fi
    echo "Sysctl: ${SYSCTL_FILE}"
    echo "Docker daemon: ${DOCKER_DAEMON_JSON}"
    echo "Docker limits: ${DOCKER_DROPIN}"
    echo "Journald: ${JOURNALD_DROPIN}"
    echo "========================================"
}

# ============================================================
# MAIN
# ============================================================

main() {
    check_system
    read_existing_secret
    select_mode

    if (( REINSTALL == 0 )); then
        if [[ -d "${INSTALL_DIR}" ]] || docker_container_exists; then
            die "Обнаружена существующая установка. Выберите пункт 4 (переустановка)."
        fi
    fi

    collect_answers

    install_packages
    install_docker

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

    if (( SELFSTEAL == 1 )); then
        configure_selfsteal
        generate_keys
    else
        generate_parameters
    fi

    if (( CASCADE == 1 )); then
        log "Часть для RU готова. Дальше нужно действие на EU."
        cascade_show_eu_instructions
        cascade_ask_eu_keys
    fi

    if (( SELFSTEAL == 1 )); then
        build_profile
        output_profiles
    fi

    show_result
}

main "$@"
