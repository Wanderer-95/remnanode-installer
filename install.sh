#!/usr/bin/env bash

set -Eeuo pipefail

VERSION="1.3.0"

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

SITE_ROOT="/var/www/html"
SITE_BACKUP_DIR="/var/backups/remnanode-site"

BACKUP_SUFFIX="$(date +%Y%m%d-%H%M%S)"
DOCKER_RESTARTED=0
MAIN_INTERFACE=""
EXISTING_SECRET_KEY=""
SITE_DOMAIN=""
SITE_TMP_SCRIPT=""

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
    log "Версия установщика: ${VERSION}"
}

# ============================================================
# MENU
# ============================================================

show_menu() {
    echo
    echo "========================================"
    echo "       REMNAWAVE NODE INSTALLER"
    echo "              v${VERSION}"
    echo "========================================"
    echo
    echo "1) Чистая установка"
    echo "2) Удалить Remnawave Node и установить заново"
    echo "0) Выход"
    echo
}

select_mode() {
    show_menu

    read -r -p "Выберите действие: " MODE

    case "${MODE}" in
        1)
            log "Выбрана чистая установка."
            ;;
        2)
            warn "Будет удалён текущий Remnawave Node."
            warn "Docker, SSH, UFW и остальные контейнеры сохраняются."
            read -r -p "Для подтверждения введите DELETE: " confirm
            [[ "${confirm}" == "DELETE" ]] || die "Операция отменена."
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
}

# ============================================================
# PACKAGES
# ============================================================

install_packages() {
    log "Установка необходимых пакетов..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update

    apt-get install -y \
        ca-certificates \
        curl \
        openssl \
        python3 \
        iproute2 \
        iptables \
        kmod \
        ufw \
        nginx

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

# ============================================================
# DOCKER LIMIT VERIFICATION
# ============================================================

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

# ============================================================
# DOCKER LOGGING VERIFICATION
# ============================================================

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
# SITE INSTALLATION (CTRL+D INPUT)
# ============================================================

ask_site_domain() {
    local domain

    while true; do
        echo
        read -r -p "Введите домен сайта (например, example.com): " domain
        domain="${domain,,}"

        if [[ "${domain}" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; then
            SITE_DOMAIN="${domain}"
            log "Домен сайта: ${SITE_DOMAIN}"
            return 0
        fi

        warn "Некорректный домен. Попробуйте снова."
    done
}

read_site_script() {
    echo
    info "Вставьте Bash-скрипт сайта целиком."
    info "Затем на новой пустой строке нажмите Ctrl+D."
    echo

    SITE_TMP_SCRIPT="$(mktemp /tmp/remnanode-site.XXXXXX.sh)"
    chmod 600 "${SITE_TMP_SCRIPT}"

    cat > "${SITE_TMP_SCRIPT}"

    [[ -s "${SITE_TMP_SCRIPT}" ]] ||
        die "Скрипт сайта пустой."

    log "Скрипт сайта получен: $(wc -l < "${SITE_TMP_SCRIPT}") строк."
}

prepare_site_script() {
    log "Подготовка скрипта сайта..."

    SITE_DOMAIN="${SITE_DOMAIN}" SITE_TMP="${SITE_TMP_SCRIPT}" python3 - <<'PY'
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

    log "Путь заменён на /var/www/html, домен заменён на ${SITE_DOMAIN}."
}

backup_site() {
    mkdir -p "${SITE_ROOT}"
    mkdir -p "${SITE_BACKUP_DIR}"
    chmod 700 "${SITE_BACKUP_DIR}"

    if [[ -n "$(ls -A "${SITE_ROOT}" 2>/dev/null)" ]]; then
        local backup="${SITE_BACKUP_DIR}/site-${BACKUP_SUFFIX}.tar.gz"

        tar -czf "${backup}" -C "${SITE_ROOT}" .
        log "Резервная копия предыдущего сайта: ${backup}"

        find "${SITE_ROOT}" -mindepth 1 -delete
        log "Содержимое ${SITE_ROOT} очищено перед установкой."
    else
        info "Предыдущий сайт не найден."
    fi
}

run_site_generator() {
    log "Запуск генератора сайта..."

    # Скрипт выполняется отдельным процессом, не через eval.
    bash "${SITE_TMP_SCRIPT}" ||
        die "Генератор сайта завершился с ошибкой. Профиль не создан."

    rm -f "${SITE_TMP_SCRIPT}"

    log "Генератор сайта выполнен."
}

verify_site_files() {
    log "Проверка файлов сайта..."

    [[ -f "${SITE_ROOT}/index.html" ]] ||
        die "Не найден index.html в ${SITE_ROOT}."

    [[ -n "$(find "${SITE_ROOT}" -type f -name '*.css' -print -quit)" ]] ||
        die "Не найден CSS-файл в ${SITE_ROOT}."

    [[ -n "$(find "${SITE_ROOT}" -type f -name '*.js' -print -quit)" ]] ||
        die "Не найден JavaScript-файл в ${SITE_ROOT}."

    log "Найдены index.html, CSS и JavaScript."
}

set_site_permissions() {
    log "Настройка прав доступа к сайту..."

    chown -R www-data:www-data "${SITE_ROOT}"
    find "${SITE_ROOT}" -type d -exec chmod 755 {} +
    find "${SITE_ROOT}" -type f -exec chmod 644 {} +

    log "Права доступа установлены."
}

verify_site_nginx() {
    log "Проверка сайта через Nginx..."

    systemctl enable nginx >/dev/null 2>&1 || true

    nginx -t ||
        die "Конфигурация Nginx не прошла проверку."

    if systemctl is-active --quiet nginx; then
        systemctl reload nginx
    else
        systemctl start nginx
    fi

    systemctl is-active --quiet nginx ||
        die "Nginx не запущен."

    local http_code
    http_code="$(
        curl -s -o /dev/null -w '%{http_code}' \
            -H "Host: ${SITE_DOMAIN}" \
            http://127.0.0.1/ || true
    )"

    echo "HTTP-код локальной проверки: ${http_code}"

    [[ "${http_code}" == "200" ]] ||
        die "Сайт не отвечает с кодом 200 через Nginx."

    log "Сайт отвечает через Nginx."
}

configure_site() {
    echo
    log "Установка сайта-маскировки..."

    ask_site_domain
    read_site_script
    prepare_site_script
    backup_site
    run_site_generator
    verify_site_files
    set_site_permissions
    verify_site_nginx

    log "Сайт ${SITE_DOMAIN} установлен."
}

# ============================================================
# GENERATE PARAMETERS
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
    log "Docker перезапущен: ${DOCKER_RESTARTED}"
    log "Docker logging: $(docker info --format '{{.LoggingDriver}}')"
    log "Docker limits: проверены"
    log "Container: ${CONTAINER_NAME}"
    log "Image: ${IMAGE}"
    log "Install directory: ${INSTALL_DIR}"
    log "Сайт: ${SITE_DOMAIN} (${SITE_ROOT})"

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
    echo "Site backups: ${SITE_BACKUP_DIR}"
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

    if [[ "${MODE}" == "1" ]]; then
        if [[ -d "${INSTALL_DIR}" ]] || docker_container_exists; then
            die "Обнаружена существующая установка. Выберите переустановку."
        fi
    fi

    install_packages
    install_docker

    if [[ "${MODE}" == "2" ]]; then
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

    # Сайт устанавливается до генерации параметров профиля.
    configure_site

    # Ключи генерируются только после успешной установки сайта и запуска Node.
    generate_parameters

    show_result
}

main "$@"
