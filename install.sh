#!/usr/bin/env bash

set -Eeuo pipefail

# Не используем VERSION: её перезаписывает /etc/os-release.
INSTALLER_VERSION="1.4.0"

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
NGINX_KEYRING="/usr/share/keyrings/nginx-archive-keyring.gpg"
NGINX_REPO_LIST="/etc/apt/sources.list.d/nginx.list"
NGINX_PIN="/etc/apt/preferences.d/99-nginx-org"
SITE_ROOT="/var/www/html"
PROFILE_FILE="/root/remnanode-profile.json"

BACKUP_SUFFIX="$(date +%Y%m%d-%H%M%S)"
DOCKER_RESTARTED=0
MAIN_INTERFACE=""
EXISTING_SECRET_KEY=""
SECRET_KEY=""
REINSTALL=0
SELFSTEAL=0
SITE_DOMAIN=""
INBOUND_NAME=""
NGINX_VERSION=""
PRIVATE_KEY=""
SHORT_ID=""

# ============================================================
# COLORS AND LOGGING
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[+]${NC} $*"
}

info() {
    echo -e "${BLUE}[*]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[!]${NC} $*"
}

die() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    exit 1
}

trap 'die "Ошибка на строке ${LINENO}. Проверьте вывод выше."' ERR

# ============================================================
# BASIC CHECKS
# ============================================================

check_system() {
    [[ "${EUID}" -eq 0 ]] || die "Запустите установщик от root."

    [[ -t 0 ]] || die "Установщик требует интерактивный терминал."

    [[ -f /etc/os-release ]] || die "Не удалось определить ОС."

    # shellcheck disable=SC1091
    source /etc/os-release

    [[ "${ID:-}" == "ubuntu" ]] || die "Поддерживается только Ubuntu."

    if [[ "${VERSION_ID:-}" != "24.04" ]]; then
        warn "Рекомендуется Ubuntu 24.04. Текущая версия: ${VERSION_ID:-unknown}"
        read -r -p "Продолжить? [y/N]: " answer
        [[ "${answer}" =~ ^[Yy]$ ]] || exit 0
    fi

    log "Операционная система: ${PRETTY_NAME}"
    log "Версия установщика: ${INSTALLER_VERSION}"
}

# ============================================================
# MENU
# ============================================================

select_reinstall_mode() {
    echo
    echo "Переустановка Remnawave Node:"
    echo "1) Установка без self-steal"
    echo "2) Установка с self-steal"
    echo "0) Выход"
    echo

    read -r -p "Выберите тип установки: " choice

    case "${choice}" in
        1)
            SELFSTEAL=0
            ;;
        2)
            SELFSTEAL=1
            ;;
        0)
            exit 0
            ;;
        *)
            die "Неверный пункт меню."
            ;;
    esac

    REINSTALL=1

    warn "Будет удалён текущий Remnawave Node."
    warn "Docker, SSH, UFW и остальные контейнеры сохраняются."
    read -r -p "Для подтверждения введите DELETE: " confirm
    [[ "${confirm}" == "DELETE" ]] || die "Операция отменена."
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
    echo "3) Удалить Remnawave Node и установить заново"
    echo "0) Выход"
    echo

    read -r -p "Выберите действие: " choice

    case "${choice}" in
        1)
            REINSTALL=0
            SELFSTEAL=0
            log "Выбрана установка без self-steal."
            ;;
        2)
            REINSTALL=0
            SELFSTEAL=1
            log "Выбрана установка с self-steal."
            ;;
        3)
            select_reinstall_mode
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
# BACKUPS
# ============================================================

backup_file() {
    local file="$1"

    if [[ -f "${file}" ]]; then
        cp -a "${file}" "${file}.bak.${BACKUP_SUFFIX}"
        log "Резервная копия: ${file}.bak.${BACKUP_SUFFIX}"
    fi
}

# ============================================================
# EXISTING CONFIGURATION
# ============================================================

read_existing_secret() {
    if [[ -f "${ENV_FILE}" ]]; then
        EXISTING_SECRET_KEY="$(
            sed -n 's/^SECRET_KEY=//p' "${ENV_FILE}" | head -n 1
        )"
    fi
}

# ============================================================
# REMNANODE REMOVAL
# ============================================================

docker_container_exists() {
    docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1
}

remove_selfsteal_config() {
    if [[ -f "${NGINX_CONF}" ]]; then
        rm -f "${NGINX_CONF}"
        log "Удалён конфиг self-steal: ${NGINX_CONF}"

        if command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then
            systemctl reload nginx || warn "Не удалось перезагрузить nginx."
        fi
    fi
}

remove_remnanode() {
    log "Удаление предыдущего Remnawave Node..."

    if docker_container_exists; then
        docker rm -f "${CONTAINER_NAME}"
    fi

    if [[ -d "${INSTALL_DIR}" ]]; then
        rm -rf "${INSTALL_DIR}"
        log "Удалён каталог ${INSTALL_DIR}"
    fi

    # Удаляем образ только если его не использует другой контейнер.
    if docker image inspect "${IMAGE}" >/dev/null 2>&1; then
        local image_id
        image_id="$(docker image inspect -f '{{.Id}}' "${IMAGE}")"

        local used=0

        while IFS= read -r container_id; do
            [[ -n "${container_id}" ]] || continue

            local container_image
            container_image="$(
                docker inspect -f '{{.Image}}' "${container_id}" 2>/dev/null || true
            )"

            if [[ "${container_image}" == "${image_id}" ]]; then
                used=1
                break
            fi
        done < <(docker ps -aq)

        if [[ "${used}" -eq 0 ]]; then
            docker image rm "${IMAGE}" || warn "Не удалось удалить старый образ."
        else
            info "Образ используется другим контейнером. Оставляем его."
        fi
    fi

    remove_selfsteal_config
}

# ============================================================
# PACKAGES
# ============================================================

prepare_apt() {
    export DEBIAN_FRONTEND=noninteractive

    if ! command -v fuser >/dev/null 2>&1; then
        apt-get update >/dev/null 2>&1 || true
        apt-get install -y psmisc >/dev/null 2>&1 ||
            die "Не удалось установить psmisc (нужен для проверки блокировок apt)."
    fi

    local waited=0
    local locks=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock)

    while fuser "${locks[@]}" >/dev/null 2>&1; do
        if (( waited == 0 )); then
            warn "Ждём освобождения блокировки apt (обычно это unattended-upgrades)..."
        fi

        sleep 5
        waited=$((waited + 5))

        (( waited < 600 )) ||
            die "Блокировка apt занята более 10 минут. Проверьте: fuser -v /var/lib/dpkg/lock-frontend"
    done

    (( waited == 0 )) || log "Блокировка apt освобождена."

    dpkg --configure -a >/dev/null 2>&1 ||
        die "dpkg не смог завершить незавершённые пакеты. Запустите вручную: dpkg --configure -a"
}

wait_for_apt() {
    prepare_apt
}

install_packages() {
    log "Установка необходимых пакетов..."

    prepare_apt

    apt-get update

    apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        openssl \
        python3 \
        iproute2 \
        iptables \
        kmod \
        ufw \
        psmisc

    log "Необходимые пакеты установлены."
}

# ============================================================
# DOCKER INSTALLATION
# ============================================================

install_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        log "Установка Docker..."

        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh
        rm -f /tmp/get-docker.sh
    else
        log "Docker уже установлен."
    fi

    systemctl enable docker
    systemctl start docker

    docker info >/dev/null 2>&1 || die "Docker не запустился."

    if ! docker compose version >/dev/null 2>&1; then
        die "Docker Compose не найден."
    fi

    log "Docker и Docker Compose доступны."
}

# ============================================================
# SYSTEM DETECTION
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
        awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
    )"

    if [[ -z "${MAIN_INTERFACE}" ]]; then
        MAIN_INTERFACE="$(
            ip -o link show |
            awk -F': ' '$2 != "lo" {print $2; exit}'
        )"
    fi

    if [[ -n "${MAIN_INTERFACE}" ]]; then
        log "Основной интерфейс: ${MAIN_INTERFACE}"
    else
        warn "Не удалось определить сетевой интерфейс."
    fi

    # BBR
    if modprobe tcp_bbr 2>/dev/null; then
        log "Модуль TCP BBR доступен."
    elif grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
        log "BBR встроен в ядро."
    else
        warn "BBR не поддерживается текущим ядром."
    fi

    # FQ
    if modprobe sch_fq 2>/dev/null; then
        log "Модуль sch_fq доступен."
    else
        warn "Модуль sch_fq недоступен."
    fi

    # Conntrack
    if modprobe nf_conntrack 2>/dev/null; then
        log "Модуль nf_conntrack загружен."
    else
        warn "Не удалось загрузить nf_conntrack."
    fi
}

# ============================================================
# MODULE AUTOSTART
# ============================================================

configure_modules() {
    log "Настройка автозагрузки nf_conntrack..."

    mkdir -p /etc/modules-load.d

    backup_file "${MODULES_FILE}"

    touch "${MODULES_FILE}"

    if ! grep -qxF "nf_conntrack" "${MODULES_FILE}"; then
        echo "nf_conntrack" >> "${MODULES_FILE}"
    fi

    modprobe nf_conntrack || warn "nf_conntrack пока не загружен."

    log "Автозагрузка модуля настроена."
}

# ============================================================
# SYSCTL OPTIMIZATION
# ============================================================

configure_sysctl() {
    log "Настройка сетевых параметров ядра..."

    backup_file "${SYSCTL_FILE}"

    local tmp_file
    tmp_file="$(mktemp)"

    cat > "${tmp_file}" <<'EOF'
# Remnawave Node network tuning

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

    # Оставляем только параметры, поддерживаемые текущим ядром.
    : > "${SYSCTL_FILE}"

    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        [[ "${line}" =~ ^# ]] && {
            echo "${line}" >> "${SYSCTL_FILE}"
            continue
        }

        local key="${line%%=*}"
        key="$(echo "${key}" | xargs)"

        local value="${line#*=}"
        value="$(echo "${value}" | xargs)"

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
    done < "${tmp_file}"

    rm -f "${tmp_file}"

    chmod 644 "${SYSCTL_FILE}"

    log "Параметры sysctl записаны в ${SYSCTL_FILE}."
}

# ============================================================
# ACTIVE FQ QDISC
# ============================================================

configure_qdisc() {
    log "Настройка активной очереди FQ..."

    if [[ -z "${MAIN_INTERFACE}" ]]; then
        warn "Интерфейс не определён. Пропускаем настройку tc."
        return 0
    fi

    if ! command -v tc >/dev/null 2>&1; then
        warn "Команда tc недоступна."
        return 0
    fi

    if ! modprobe sch_fq 2>/dev/null; then
        warn "sch_fq не загружен. Активный qdisc не изменён."
        return 0
    fi

    if tc qdisc replace dev "${MAIN_INTERFACE}" root fq; then
        log "FQ применён к ${MAIN_INTERFACE}."

        tc qdisc show dev "${MAIN_INTERFACE}"
    else
        warn "Не удалось применить FQ к ${MAIN_INTERFACE}."
    fi
}

# ============================================================
# DOCKER SYSTEMD LIMITS
# ============================================================

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

# ============================================================
# DOCKER LOGGING CONFIGURATION
# ============================================================

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
    raise SystemExit("Параметр log-opts должен быть JSON-объектом")

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

    chmod 644 "${DOCKER_DAEMON_JSON}"

    # Проверяем JSON и конфигурацию dockerd до перезапуска.
    python3 -m json.tool "${DOCKER_DAEMON_JSON}" >/dev/null

    if dockerd --validate --config-file="${DOCKER_DAEMON_JSON}" >/dev/null 2>&1; then
        log "Конфигурация Docker прошла проверку."
    else
        die "Конфигурация Docker не прошла проверку. Перезапуск отменён."
    fi
}

# ============================================================
# JOURNALD
# ============================================================

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

    log "Лимит journald установлен: 200M."
}

# ============================================================
# DOCKER RESTART AND VERIFICATION
# ============================================================

restart_docker() {
    log "Подготовка к обязательному перезапуску Docker..."

    local other_containers=()

    while IFS= read -r name; do
        [[ -n "${name}" ]] || continue
        [[ "${name}" == "${CONTAINER_NAME}" ]] && continue
        other_containers+=("${name}")
    done < <(docker ps --format '{{.Names}}')

    if (( ${#other_containers[@]} > 0 )); then
        echo
        warn "На сервере запущены другие Docker-контейнеры:"
        printf '  - %s\n' "${other_containers[@]}"
        echo
        warn "Перезапуск Docker временно прервёт их работу."
        warn "Контейнеры с restart policy могут запуститься автоматически."
        echo

        read -r -p "Для обязательного перезапуска Docker введите RESTART: " confirm

        if [[ "${confirm}" != "RESTART" ]]; then
            die "Перезапуск Docker не подтверждён. Установка остановлена."
        fi
    else
        log "Других запущенных контейнеров не обнаружено."
    fi

    # Перечитываем unit-файлы и обязательно перезапускаем Docker.
    systemctl daemon-reload

    log "Перезапуск Docker..."

    systemctl restart docker

    systemctl is-active --quiet docker ||
        die "Docker не запустился после перезапуска."

    docker info >/dev/null 2>&1 ||
        die "Docker API недоступен после перезапуска."

    DOCKER_RESTARTED=1

    log "Docker успешно перезапущен."
}

verify_docker_limits() {
    log "Проверка фактических лимитов процесса Docker..."

    local docker_pid
    docker_pid="$(systemctl show docker -p MainPID --value)"

    [[ "${docker_pid}" =~ ^[0-9]+$ ]] ||
        die "Не удалось определить PID Docker."

    [[ "${docker_pid}" -gt 0 ]] ||
        die "Процесс Docker не запущен."

    local limits_file="/proc/${docker_pid}/limits"

    [[ -r "${limits_file}" ]] ||
        die "Не удалось прочитать ${limits_file}."

    local nofile
    local nproc

    nofile="$(
        awk '/Max open files/ {print $4; exit}' "${limits_file}"
    )"

    nproc="$(
        awk '/Max processes/ {print $4; exit}' "${limits_file}"
    )"

    echo "Docker PID: ${docker_pid}"
    echo "LimitNOFILE: ${nofile}"
    echo "LimitNPROC: ${nproc}"

    [[ "${nofile}" == "1048576" ]] ||
        die "LimitNOFILE не применился."

    [[ "${nproc}" == "1048576" ]] ||
        die "LimitNPROC не применился."

    log "Фактические лимиты Docker подтверждены."
}

verify_docker_logging() {
    log "Проверка Docker logging..."

    local driver
    driver="$(docker info --format '{{.LoggingDriver}}')"

    echo "Logging driver: ${driver}"

    [[ "${driver}" == "json-file" ]] ||
        die "Docker logging driver не применился."

    log "Docker logging активен."
}

# ============================================================
# SECRET KEY
# ============================================================

read_secret_key() {
    echo

    if [[ -n "${EXISTING_SECRET_KEY}" ]]; then
        log "Существующий SECRET_KEY будет сохранён."
        SECRET_KEY="${EXISTING_SECRET_KEY}"
        return
    fi

    echo "Введите SECRET_KEY Remnawave Node."
    echo "Значение не будет отображаться на экране."
    echo

    while true; do
        read -r -s -p "SECRET_KEY: " SECRET_KEY
        echo

        [[ -n "${SECRET_KEY}" ]] || {
            warn "SECRET_KEY не может быть пустым."
            continue
        }

        read -r -s -p "Повторите SECRET_KEY: " SECRET_KEY_CONFIRM
        echo

        [[ "${SECRET_KEY}" == "${SECRET_KEY_CONFIRM}" ]] && break

        warn "Значения не совпадают."
    done
}

# ============================================================
# SSH PORT DETECTION
# ============================================================

detect_ssh_port() {
    local ssh_port="22"

    if command -v sshd >/dev/null 2>&1; then
        ssh_port="$(
            sshd -T 2>/dev/null |
            awk '$1=="port" {print $2; exit}'
        )"
    fi

    [[ "${ssh_port}" =~ ^[0-9]+$ ]] || ssh_port="22"

    echo "${ssh_port}"
}

# ============================================================
# FIREWALL
# ============================================================

configure_firewall() {
    log "Настройка UFW..."

    local ssh_port
    ssh_port="$(detect_ssh_port)"

    ufw allow "${ssh_port}/tcp" comment 'SSH' >/dev/null
    ufw allow 2222/tcp comment 'Remnawave Node' >/dev/null
    ufw allow 443/tcp comment 'Remnawave Node' >/dev/null
    ufw allow 8443/tcp comment 'Remnawave Node' >/dev/null
    ufw allow 80/tcp comment 'HTTP' >/dev/null

    if ufw status | grep -q "Status: inactive"; then
        ufw --force enable
    fi

    log "UFW настроен. SSH-порт: ${ssh_port}."
}

# ============================================================
# NODE CONFIGURATION
# ============================================================

create_configuration() {
    log "Создание конфигурации Remnawave Node..."

    mkdir -p "${INSTALL_DIR}"

    chmod 700 "${INSTALL_DIR}"

    # Экранирование специальных символов для dotenv.
    local escaped_secret
    escaped_secret="$(
        SECRET_KEY="${SECRET_KEY}" python3 - <<'PY'
import os
value = os.environ["SECRET_KEY"]
value = value.replace("\\", "\\\\").replace('"', '\\"')
print(value)
PY
    )"

    umask 077

    cat > "${ENV_FILE}" <<EOF
NODE_PORT=2222
SECRET_KEY="${escaped_secret}"
EOF

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

    chmod 600 "${ENV_FILE}"
    chmod 644 "${COMPOSE_FILE}"

    cd "${INSTALL_DIR}"

    docker compose config -q ||
        die "Ошибка проверки docker-compose.yml."

    log "Конфигурация Node создана."
}

# ============================================================
# START NODE
# ============================================================

start_node() {
    log "Загрузка образа Remnawave Node..."

    cd "${INSTALL_DIR}"

    docker compose pull

    log "Запуск Remnawave Node..."

    docker compose up -d

    local attempt=0
    local max_attempts=60

    while (( attempt < max_attempts )); do
        if docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null |
            grep -qx true; then
            log "Контейнер Remnawave Node запущен."
            break
        fi

        sleep 2
        ((attempt+=1))
    done

    if (( attempt >= max_attempts )); then
        docker logs --tail 100 "${CONTAINER_NAME}" || true
        die "Remnawave Node не запустился за отведённое время."
    fi

    local health
    health="$(
        docker inspect -f '{{.State.Status}}' "${CONTAINER_NAME}"
    )"

    [[ "${health}" == "running" ]] ||
        die "Контейнер не находится в состоянии running."

    echo
    docker ps --filter "name=${CONTAINER_NAME}"
}

# ============================================================
# NGINX (SELF-STEAL)
# ============================================================

version_ge() {
    # Возвращает успех, если $1 >= $2.
    [[ "$(printf '%s\n' "$1" "$2" | sort -V | head -n 1)" == "$2" ]]
}

get_nginx_version() {
    nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
}

install_nginx_from_org() {
    # Вызывается в условии if, поэтому set -e здесь не работает.
    # Каждый шаг проверяем явно.
    local codename key_tmp

    codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
    [[ -n "${codename}" ]] || { warn "Не удалось определить codename Ubuntu."; return 1; }

    key_tmp="$(mktemp)"

    if ! curl -fsSL https://nginx.org/keys/nginx_signing.key -o "${key_tmp}"; then
        warn "Не удалось скачать ключ nginx.org."
        rm -f "${key_tmp}"
        return 1
    fi

    # Проверяем, что ключ действительно тот, которым подписан репозиторий.
    if ! gpg --show-keys --with-colons "${key_tmp}" 2>/dev/null |
         grep -q '^fpr:.*2FD21310B49F6B46:$'; then
        warn "Ключ nginx.org не совпал с ожидаемым отпечатком."
        rm -f "${key_tmp}"
        return 1
    fi

    if ! gpg --dearmor --yes -o "${NGINX_KEYRING}" "${key_tmp}"; then
        warn "Не удалось сохранить ключ nginx.org."
        rm -f "${key_tmp}"
        return 1
    fi

    rm -f "${key_tmp}"

    echo "deb [signed-by=${NGINX_KEYRING}] http://nginx.org/packages/ubuntu ${codename} nginx" \
        > "${NGINX_REPO_LIST}"

    printf 'Package: *\nPin: origin nginx.org\nPin-Priority: 900\n' > "${NGINX_PIN}"

    wait_for_apt
    apt-get update || return 1

    wait_for_apt
    apt-get install -y nginx || return 1

    return 0
}

install_nginx_latest() {
    log "Установка последней стабильной версии nginx..."

    export DEBIAN_FRONTEND=noninteractive

    if install_nginx_from_org; then
        log "nginx установлен из официального репозитория nginx.org."
    else
        warn "Не удалось установить nginx из nginx.org. Используем версию из Ubuntu."

        # Убираем репозиторий nginx.org, чтобы apt update не падал на нём.
        rm -f "${NGINX_REPO_LIST}" "${NGINX_PIN}"

        wait_for_apt
        apt-get update

        wait_for_apt
        apt-get install -y nginx
    fi

    systemctl enable nginx >/dev/null 2>&1 || true

    NGINX_VERSION="$(get_nginx_version)"

    [[ -n "${NGINX_VERSION}" ]] || die "Не удалось определить версию nginx."

    log "Версия nginx: ${NGINX_VERSION}"
}

disable_default_nginx_sites() {
    rm -f /etc/nginx/sites-enabled/default

    if [[ -f /etc/nginx/conf.d/default.conf ]]; then
        mv /etc/nginx/conf.d/default.conf \
           "/etc/nginx/conf.d/default.conf.bak.${BACKUP_SUFFIX}"
        log "Стандартный конфиг nginx отключён."
    fi
}

write_nginx_config() {
    # $1: http (только порт 80 для получения сертификата) или ssl (финальный конфиг)
    local stage="$1"

    local listen_line="listen 127.0.0.1:8443 ssl;"
    local http2_line="    http2 on;"

    if ! version_ge "${NGINX_VERSION}" "1.25.0"; then
        listen_line="listen 127.0.0.1:8443 ssl http2;"
        http2_line=""
    fi

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
    root /var/www/html;
    location /.well-known/acme-challenge/ { allow all; }
    location / { return 301 https://$host$request_uri; }
}

server {
    __LISTEN__
__HTTP2__
    server_name __DOMAIN__;

    ssl_certificate     /etc/letsencrypt/live/__DOMAIN__/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/__DOMAIN__/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    root /var/www/html;
    index index.html;
    error_page 404 /404.html;
    add_header X-Content-Type-Options nosniff;

    location / { try_files $uri $uri/ =404; }
}
NGINX
    fi

    sed -i \
        -e "s|__DOMAIN__|${SITE_DOMAIN}|g" \
        -e "s|__LISTEN__|${listen_line}|g" \
        -e "s|__HTTP2__|${http2_line}|g" \
        "${NGINX_CONF}"

    log "Конфиг nginx записан: ${NGINX_CONF}"
}

install_certbot_hook() {
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy

    printf '#!/bin/sh\nsystemctl reload nginx\n' \
        > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

    chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
}

ask_selfsteal_domain() {
    local domain

    while true; do
        echo
        read -r -p "Введите домен для ноды (например, node.example.com): " domain
        domain="${domain,,}"

        if [[ "${domain}" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; then
            SITE_DOMAIN="${domain}"
            log "Домен: ${SITE_DOMAIN}"
            info "Домен должен указывать A-записью на IP этого сервера."
            return 0
        fi

        warn "Некорректный домен. Попробуйте снова."
    done
}

configure_selfsteal_nginx() {
    echo
    log "Настройка nginx для self-steal..."

    install_nginx_latest
    disable_default_nginx_sites

    mkdir -p "${SITE_ROOT}"

    # Сначала HTTP-конфиг, чтобы certbot смог пройти проверку.
    write_nginx_config http

    nginx -t || die "Конфигурация nginx не прошла проверку."
    systemctl restart nginx
}

configure_selfsteal_certificate() {
    log "Получение сертификата Let's Encrypt..."

    apt-get install -y certbot

    certbot certonly \
        --webroot -w "${SITE_ROOT}" \
        -d "${SITE_DOMAIN}" \
        --agree-tos \
        --register-unsafely-without-email \
        --non-interactive \
        --keep-until-expiring ||
        die "Не удалось получить сертификат. Проверьте DNS-запись домена и открытый порт 80."

    [[ -f "/etc/letsencrypt/live/${SITE_DOMAIN}/fullchain.pem" ]] ||
        die "Сертификат не найден после выпуска."

    install_certbot_hook

    certbot renew --dry-run ||
        warn "Проверка автообновления сертификата не прошла. Проверьте порт 80 и DNS."

    log "Сертификат получен."
}

configure_selfsteal_final() {
    log "Применение финального конфига nginx..."

    write_nginx_config ssl

    nginx -t || die "Финальный конфиг nginx не прошёл проверку."
    systemctl restart nginx

    systemctl is-active --quiet nginx || die "Nginx не запущен."

    log "Nginx настроен для self-steal."
}

check_site_placeholder() {
    local code
    code="$(
        curl -sk -o /dev/null -w '%{http_code}' \
            https://127.0.0.1:8443/ \
            -H "Host: ${SITE_DOMAIN}" || true
    )"

    echo "local=${code}"
    info "Ответ 404 или 403 нормален, пока сайт не загружен."
}

install_site() {
    echo
    info "Вставьте сайт целиком."
    info "Если это HTML-страница, вставьте её как есть."
    info "Если это Bash-скрипт генератора, вставьте его целиком."
    info "Затем на новой пустой строке нажмите Ctrl+D."
    echo

    local tmp_site
    tmp_site="$(mktemp /tmp/remnanode-site.XXXXXX)"
    chmod 600 "${tmp_site}"

    cat > "${tmp_site}"

    [[ -s "${tmp_site}" ]] || die "Сайт пустой."

    mkdir -p "${SITE_ROOT}"

    if grep -qiE '<!doctype html|<html' "${tmp_site}"; then
        cp "${tmp_site}" "${SITE_ROOT}/index.html"
        log "HTML-страница сохранена как index.html."
    else
        log "Выполнение скрипта сайта..."

        SITE_DOMAIN="${SITE_DOMAIN}" SITE_TMP="${tmp_site}" python3 - <<'PY'
import os

path = os.environ["SITE_TMP"]
domain = os.environ["SITE_DOMAIN"]

with open(path, "r", encoding="utf-8") as f:
    text = f.read()

text = text.replace("/var/www/selfsteal", "/var/www/html")
text = text.replace("greenhabitat.info", domain)

with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PY

        bash "${tmp_site}" || die "Скрипт сайта завершился с ошибкой."
    fi

    rm -f "${tmp_site}"

    [[ -f "${SITE_ROOT}/index.html" ]] ||
        die "Не найден index.html в ${SITE_ROOT}."

    find "${SITE_ROOT}" -type d -exec chmod 755 {} +
    find "${SITE_ROOT}" -type f -exec chmod 644 {} +

    log "Файлы сайта установлены в ${SITE_ROOT}."
}

verify_site() {
    log "Проверка сайта через nginx..."

    local code
    code="$(
        curl -sk -o /dev/null -w '%{http_code}' \
            https://127.0.0.1:8443/ \
            -H "Host: ${SITE_DOMAIN}" || true
    )"

    echo "local=${code}"

    [[ "${code}" == "200" ]] ||
        die "Сайт не отвечает с кодом 200 (получен ${code})."

    log "Сайт открывается по домену ${SITE_DOMAIN}."
}

configure_selfsteal() {
    ask_selfsteal_domain
    configure_selfsteal_nginx
    configure_selfsteal_certificate
    configure_selfsteal_final
    check_site_placeholder
    install_site
    verify_site
}

# ============================================================
# INBOUND AND KEYS (SELF-STEAL)
# ============================================================

read_inbound_name() {
    echo
    read -r -p "Введите название инбаунда: " INBOUND_NAME
    INBOUND_NAME="${INBOUND_NAME:-Reality}"
    log "Название инбаунда: VLESS-Reality-${INBOUND_NAME}"
}

generate_selfsteal_keys() {
    log "Генерация X25519..."

    local x25519_output
    x25519_output="$(
        docker exec "${CONTAINER_NAME}" xray x25519
    )" || die "Не удалось сгенерировать X25519."

    PRIVATE_KEY="$(
        printf '%s\n' "${x25519_output}" |
        awk -F': *' '/^PrivateKey/ {print $2; exit}' |
        tr -d '[:space:]'
    )"

    [[ -n "${PRIVATE_KEY}" ]] ||
        die "Не удалось извлечь PrivateKey из вывода xray x25519."

    SHORT_ID="$(openssl rand -hex 8)"

    log "Ключи сгенерированы."
}

build_selfsteal_profile() {
    log "Сборка профиля..."

    INBOUND_NAME="${INBOUND_NAME}" \
    SITE_DOMAIN="${SITE_DOMAIN}" \
    PRIVATE_KEY="${PRIVATE_KEY}" \
    SHORT_ID="${SHORT_ID}" \
    PROFILE_FILE="${PROFILE_FILE}" \
    python3 - <<'PY'
import json
import os

profile = {
    "log": {
        "loglevel": "warning"
    },
    "dns": {
        "servers": ["1.1.1.1", "1.0.0.1"],
        "queryStrategy": "UseIPv4"
    },
    "inbounds": [
        {
            "tag": "VLESS-Reality-" + os.environ["INBOUND_NAME"],
            "port": 443,
            "listen": "0.0.0.0",
            "protocol": "vless",
            "settings": {
                "clients": [],
                "decryption": "none"
            },
            "sniffing": {
                "enabled": True,
                "destOverride": ["http", "tls", "quic"]
            },
            "streamSettings": {
                "network": "raw",
                "security": "reality",
                "realitySettings": {
                    "dest": "127.0.0.1:8443",
                    "show": False,
                    "xver": 0,
                    "shortIds": [os.environ["SHORT_ID"]],
                    "privateKey": os.environ["PRIVATE_KEY"],
                    "fingerprint": "firefox",
                    "serverNames": [os.environ["SITE_DOMAIN"]]
                }
            }
        }
    ],
    "outbounds": [
        {
            "tag": "DIRECT",
            "protocol": "freedom"
        },
        {
            "tag": "BLOCK",
            "protocol": "blackhole"
        }
    ],
    "routing": {
        "rules": [
            {
                "ip": ["geoip:private"],
                "type": "field",
                "outboundTag": "BLOCK"
            },
            {
                "type": "field",
                "protocol": ["bittorrent"],
                "outboundTag": "BLOCK"
            }
        ],
        "domainStrategy": "IPIfNonMatch"
    }
}

path = os.environ["PROFILE_FILE"]
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(profile, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

    log "Профиль сохранён в ${PROFILE_FILE} (права 600)."
}

show_selfsteal_profile() {
    echo
    echo "========================================"
    echo "          PROFILE FOR REMNAWAVE"
    echo "========================================"
    echo
    cat "${PROFILE_FILE}"
    echo
    warn "Профиль содержит приватный ключ. Не публикуйте его."
    echo "========================================"
}

configure_selfsteal_profile() {
    read_inbound_name
    generate_selfsteal_keys
    build_selfsteal_profile
    show_selfsteal_profile
}

# ============================================================
# GENERATE PARAMETERS (WITHOUT SELF-STEAL)
# ============================================================

generate_parameters() {
    log "Генерация X25519..."

    local x25519_output

    x25519_output="$(
        docker exec "${CONTAINER_NAME}" xray x25519
    )" || die "Не удалось сгенерировать X25519."

    [[ -n "${x25519_output}" ]] ||
        die "X25519 вернул пустой результат."

    local short_id
    short_id="$(openssl rand -hex 8)"

    echo
    echo "========================================"
    echo "          NODE PARAMETERS"
    echo "========================================"
    echo
    echo "X25519:"
    echo "${x25519_output}"
    echo
    echo "Short ID:"
    echo "${short_id}"
    echo
}

# ============================================================
# FINAL VERIFICATION
# ============================================================

show_result() {
    echo
    echo "========================================"
    echo "          INSTALLATION COMPLETE"
    echo "========================================"
    echo

    log "Remnawave Node установлен."
    log "Режим: $( (( SELFSTEAL == 1 )) && echo 'с self-steal' || echo 'без self-steal' )"
    log "Docker перезапущен: ${DOCKER_RESTARTED}"
    log "Docker logging: $(docker info --format '{{.LoggingDriver}}')"
    log "Docker limits: проверены"
    log "Container: ${CONTAINER_NAME}"
    log "Image: ${IMAGE}"
    log "Install directory: ${INSTALL_DIR}"

    if (( SELFSTEAL == 1 )); then
        log "Домен self-steal: ${SITE_DOMAIN}"
        log "Nginx: ${NGINX_VERSION}"
    fi

    if [[ -n "${MAIN_INTERFACE}" ]]; then
        echo
        echo "Network interface: ${MAIN_INTERFACE}"
        tc qdisc show dev "${MAIN_INTERFACE}" 2>/dev/null || true
    fi

    echo
    echo "Sysctl configuration: ${SYSCTL_FILE}"
    echo "Docker daemon config: ${DOCKER_DAEMON_JSON}"
    echo "Docker systemd limits: ${DOCKER_DROPIN}"
    echo "Journald config: ${JOURNALD_DROPIN}"
    echo
    echo "========================================"
}

# ============================================================
# MAIN
# ============================================================

main() {
    check_system

    # Сохраняем SECRET_KEY до возможного удаления каталога.
    read_existing_secret

    select_mode

    if (( REINSTALL == 0 )); then
        if [[ -d "${INSTALL_DIR}" ]] || docker_container_exists; then
            die "Обнаружена существующая установка. Выберите пункт 3 для переустановки."
        fi
    fi

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

    # Обязательный перезапуск после изменения Docker config и systemd limits.
    restart_docker

    # Проверяем, что изменения действительно вступили в силу.
    verify_docker_limits
    verify_docker_logging

    # После перезапуска Docker создаём и запускаем Node.
    read_secret_key
    configure_firewall
    create_configuration
    start_node

    if (( SELFSTEAL == 1 )); then
        configure_selfsteal
        configure_selfsteal_profile
    else
        generate_parameters
    fi

    show_result
}

main "$@"
