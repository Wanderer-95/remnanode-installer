
#!/usr/bin/env bash
set -Eeuo pipefail

# Remnawave Node Installer
# Repository: https://github.com/Wanderer-95/remnanode-installer
# Version: 1.1.0

VERSION="1.1.0"

INSTALL_DIR="/opt/remnanode"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
ENV_FILE="${INSTALL_DIR}/.env"

CONTAINER_NAME="remnanode"
IMAGE_NAME="remnawave/node:latest"

SYSCTL_FILE="/etc/sysctl.d/99-node-tuning.conf"
MODULES_FILE="/etc/modules-load.d/remnanode.conf"
DOCKER_LIMITS_FILE="/etc/systemd/system/docker.service.d/99-remnanode-limits.conf"
DOCKER_CONFIG="/etc/docker/daemon.json"
JOURNALD_CONFIG="/etc/systemd/journald.conf.d/99-remnanode.conf"

REQUIRED_PORTS=(2222 443 8443 80)

BACKUP_SUFFIX="$(date +%Y%m%d-%H%M%S)"

DOCKER_RESTART_SKIPPED=0
SYSCTL_APPLIED=0
SYSCTL_SKIPPED=0

log() {
    printf '\n\033[1;34m[INFO]\033[0m %s\n' "$*"
}

success() {
    printf '\n\033[1;32m[OK]\033[0m %s\n' "$*"
}

warn() {
    printf '\n\033[1;33m[WARN]\033[0m %s\n' "$*" >&2
}

die() {
    printf '\n\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
    exit 1
}

trap 'die "Операция прервана на строке ${LINENO}. Проверь вывод выше."' ERR

# --------------------------------------------------
# BACKUP HELPER
# --------------------------------------------------

backup_file() {
    local file="$1"

    if [[ -f "${file}" ]]; then
        local backup="${file}.bak.${BACKUP_SUFFIX}"

        cp -a -- "${file}" "${backup}"

        log "Резервная копия: ${backup}"
    fi
}

# --------------------------------------------------
# SYSTEM CHECKS
# --------------------------------------------------

check_system() {
    [[ "${EUID}" -eq 0 ]] || die "Запусти скрипт от root: sudo -i"

    [[ -r /etc/os-release ]] || die "Не удалось определить ОС."

    . /etc/os-release

    [[ "${ID}" == "ubuntu" ]] || die "Поддерживается Ubuntu. Обнаружена: ${PRETTY_NAME:-unknown}"

    if [[ "${VERSION_ID:-}" != "24.04" ]]; then
        warn "Рекомендуется Ubuntu 24.04. Обнаружена версия ${VERSION_ID:-unknown}."
    fi

    [[ -t 0 ]] || die "Для работы установщика необходим интерактивный терминал."

    command -v systemctl >/dev/null 2>&1 || die "systemd не обнаружен."
}

# --------------------------------------------------
# MENU
# --------------------------------------------------

show_menu() {
    clear 2>/dev/null || true

    printf '\033[1;36m'

    cat <<'EOF'
╔══════════════════════════════════════════════╗
║           Remnawave Node Installer           ║
║              Wanderer-95                     ║
║                 Version 1.1.0                ║
╠══════════════════════════════════════════════╣
║                                              ║
║  1. Чистая установка                         ║
║                                              ║
║  2. Полное удаление и переустановка          ║
║                                              ║
║  0. Выход                                    ║
║                                              ║
╚══════════════════════════════════════════════╝
EOF

    printf '\033[0m\n'
}

select_mode() {
    while true; do
        show_menu

        read -rp "Выбери режим [0-2]: " choice

        case "${choice}" in
            1)
                MODE="fresh"
                return
                ;;
            2)
                MODE="reinstall"
                return
                ;;
            0)
                log "Выход."
                exit 0
                ;;
            *)
                warn "Неверный выбор. Введи 0, 1 или 2."
                sleep 1
                ;;
        esac
    done
}

# --------------------------------------------------
# DOCKER HELPERS
# --------------------------------------------------

docker_container_exists() {
    docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1
}

# --------------------------------------------------
# FRESH INSTALL VALIDATION
# --------------------------------------------------

check_fresh_install() {
    log "Проверка возможности чистой установки..."

    if docker_container_exists; then
        die "Контейнер ${CONTAINER_NAME} уже существует. Выбери режим переустановки."
    fi

    if [[ -e "${INSTALL_DIR}" || -L "${INSTALL_DIR}" ]]; then
        die "${INSTALL_DIR} уже существует. Выбери режим переустановки или проверь каталог вручную."
    fi

    if command -v ss >/dev/null 2>&1; then
        if ss -H -lntp '( sport = :2222 )' | grep -q .; then
            ss -lntp '( sport = :2222 )' || true
            die "TCP-порт 2222 уже занят. Освободи его перед установкой."
        fi
    fi

    log "Проверка пройдена."
}

# --------------------------------------------------
# REMNANODE REMOVAL
# --------------------------------------------------

remove_remnanode() {
    log "Проверка существующей установки Remnawave Node..."

    if [[ ! -e "${INSTALL_DIR}" && ! -L "${INSTALL_DIR}" ]] &&
       ! docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then

        warn "Существующая установка Remnawave Node не обнаружена."
        return
    fi

    command -v docker >/dev/null 2>&1 || die "Docker не найден. Невозможно безопасно проверить и удалить Node."

    docker info >/dev/null 2>&1 || die "Docker Engine недоступен. Удаление отменено."

    if [[ -L "${INSTALL_DIR}" ]]; then
        die "${INSTALL_DIR} является символической ссылкой. Автоматическое удаление запрещено."
    fi

    local image_id=""
    local container_image=""

    if docker_container_exists; then
        container_image="$(docker inspect -f '{{.Config.Image}}' "${CONTAINER_NAME}")"
        image_id="$(docker inspect -f '{{.Image}}' "${CONTAINER_NAME}")"

        if [[ "${container_image}" != remnawave/node:* ]]; then
            die "Контейнер ${CONTAINER_NAME} использует посторонний образ: ${container_image}. Удаление отменено."
        fi

        log "Остановка контейнера..."

        docker stop "${CONTAINER_NAME}"

        log "Удаление контейнера..."

        docker rm "${CONTAINER_NAME}"
    else
        warn "Контейнер ${CONTAINER_NAME} не обнаружен."
    fi

    if [[ -d "${INSTALL_DIR}" ]]; then
        log "Удаление конфигурации ${INSTALL_DIR}..."

        rm -rf --one-file-system -- "${INSTALL_DIR}"

    elif [[ -e "${INSTALL_DIR}" ]]; then
        die "${INSTALL_DIR} существует, но не является обычным каталогом."
    fi

    if [[ -n "${image_id}" ]]; then
        local dependent_containers

        dependent_containers="$(
            docker ps -aq --filter "ancestor=${image_id}"
        )"

        if [[ -n "${dependent_containers}" ]]; then
            warn "Образ используется другими контейнерами. Образ оставлен."
        else
            log "Удаление образа Remnawave Node..."

            docker image rm "${image_id}" \
                || warn "Не удалось удалить образ. Остальные действия продолжаются."
        fi
    else
        if docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
            local tagged_image_id

            tagged_image_id="$(docker image inspect -f '{{.Id}}' "${IMAGE_NAME}")"

            if docker ps -aq --filter "ancestor=${tagged_image_id}" | grep -q .; then
                warn "Образ используется другими контейнерами. Оставляю его."
            else
                docker image rm "${IMAGE_NAME}" \
                    || warn "Не удалось удалить локальный образ."
            fi
        fi
    fi

    success "Компоненты Remnawave Node удалены."
}

# --------------------------------------------------
# SYSTEM PACKAGES
# --------------------------------------------------

install_packages() {
    log "Обновление списка пакетов..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update
    apt-get upgrade -y

    apt-get install -y \
        ca-certificates \
        curl \
        openssl \
        ufw \
        iproute2 \
        python3 \
        kmod
}

# --------------------------------------------------
# INSTALL DOCKER
# --------------------------------------------------

install_docker() {
    log "Проверка Docker..."

    if ! command -v docker >/dev/null 2>&1; then
        log "Установка Docker Engine..."

        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh

        sh /tmp/get-docker.sh

        rm -f /tmp/get-docker.sh
    else
        log "Docker уже установлен."
    fi

    systemctl enable --now docker

    docker info >/dev/null 2>&1 || die "Docker Engine не запустился."

    docker compose version >/dev/null 2>&1 \
        || die "Docker Compose plugin не найден."
}

# --------------------------------------------------
# SSH / FIREWALL
# --------------------------------------------------

detect_ssh_port() {
    SSH_PORT="22"

    if command -v sshd >/dev/null 2>&1; then
        local detected_port

        detected_port="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')"

        [[ -n "${detected_port:-}" ]] && SSH_PORT="${detected_port}"
    fi

    [[ "${SSH_PORT}" =~ ^[0-9]+$ ]] || die "Не удалось определить корректный SSH-порт."

    log "SSH-порт: ${SSH_PORT}/tcp"
}

configure_firewall() {
    log "Настройка UFW..."

    ufw allow "${SSH_PORT}/tcp" comment 'SSH'

    for port in "${REQUIRED_PORTS[@]}"; do
        ufw allow "${port}/tcp" comment "Remnawave Node ${port}"
    done

    if ufw status | grep -q '^Status: active'; then
        log "UFW уже активен. Существующие правила сохранены."
    else
        warn "Включение UFW. SSH-порт предварительно разрешён."

        ufw --force enable
    fi
}

# --------------------------------------------------
# SECRET KEY
# --------------------------------------------------

read_secret_key() {
    printf '\n'

    log "Ввод SECRET_KEY"

    read -rsp "Вставь SECRET_KEY из панели Remnawave: " SECRET_KEY

    printf '\n'

    [[ -n "${SECRET_KEY}" ]] || die "SECRET_KEY не может быть пустым."

    [[ "${SECRET_KEY}" != *$'\n'* && "${SECRET_KEY}" != *$'\r'* ]] \
        || die "SECRET_KEY не должен содержать переносы строк."

    dotenv_value="${SECRET_KEY//\\/\\\\}"
    dotenv_value="${dotenv_value//\'/\\\'}"
}

# --------------------------------------------------
# NODE CONFIGURATION
# --------------------------------------------------

create_configuration() {
    log "Создание конфигурации Remnawave Node..."

    mkdir -p "${INSTALL_DIR}"

    chmod 700 "${INSTALL_DIR}"

    umask 077

    printf "SECRET_KEY='%s'\n" "${dotenv_value}" > "${ENV_FILE}"

    chmod 600 "${ENV_FILE}"

    cat > "${COMPOSE_FILE}" <<'YAML'
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      NODE_PORT: "2222"
      SECRET_KEY: "${SECRET_KEY:?SECRET_KEY is required}"
YAML

    chmod 600 "${COMPOSE_FILE}"

    log "Проверка Docker Compose..."

    docker compose \
        --env-file "${ENV_FILE}" \
        -f "${COMPOSE_FILE}" \
        config -q

    success "Конфигурация Node создана."
}

# --------------------------------------------------
# SYSTEM TUNING: ENVIRONMENT CHECK
# --------------------------------------------------

check_system_tuning() {
    log "Шаг 1 из 4 · Проверка системного окружения"

    KERNEL_VERSION="$(uname -r)"

    VIRT_TYPE="unknown"

    if command -v systemd-detect-virt >/dev/null 2>&1; then
        VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || echo unknown)"
    fi

    MAIN_INTERFACE="$(
        ip -o route get 1.1.1.1 2>/dev/null |
        awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
    )"

    log "Ядро: ${KERNEL_VERSION}"
    log "Виртуализация: ${VIRT_TYPE}"

    if [[ -n "${MAIN_INTERFACE}" ]]; then
        log "Основной интерфейс: ${MAIN_INTERFACE}"
    else
        warn "Не удалось определить основной сетевой интерфейс."
    fi

    if command -v modprobe >/dev/null 2>&1; then
        if modprobe tcp_bbr 2>/dev/null || \
           grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then

            if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
                success "BBR доступен."
                BBR_AVAILABLE=1
            else
                warn "Модуль BBR загружен, но алгоритм не обнаружен."
                BBR_AVAILABLE=0
            fi
        else
            warn "BBR недоступен в текущем ядре."
            BBR_AVAILABLE=0
        fi
    else
        warn "modprobe не найден."
        BBR_AVAILABLE=0
    fi

    if modprobe sch_fq 2>/dev/null; then
        success "Модуль sch_fq доступен."
        FQ_AVAILABLE=1
    else
        warn "Модуль sch_fq не удалось загрузить."
        FQ_AVAILABLE=0
    fi

    if modprobe nf_conntrack 2>/dev/null; then
        success "nf_conntrack доступен."
        CONNTRACK_AVAILABLE=1
    else
        warn "nf_conntrack недоступен. Настройки Conntrack будут пропущены."
        CONNTRACK_AVAILABLE=0
    fi
}

# --------------------------------------------------
# SYSTEM TUNING: SYSCTL
# --------------------------------------------------

apply_sysctl_setting() {
    local key="$1"
    local value="$2"
    local proc_path="/proc/sys/${key//./\/}"

    if [[ ! -e "${proc_path}" ]]; then
        warn "Пропуск ${key}: параметр отсутствует в текущем ядре."
        ((SYSCTL_SKIPPED+=1))
        return 0
    fi

    if sysctl -w "${key}=${value}" >/dev/null 2>&1; then
        printf '%s = %s\n' "${key}" "${value}" >> "${SYSCTL_TEMP_FILE}"

        ((SYSCTL_APPLIED+=1))

        success "${key} = ${value}"
    else
        warn "Не удалось применить ${key}."
        ((SYSCTL_SKIPPED+=1))
    fi
}

configure_sysctl() {
    log "Шаг 2 из 4 · Сохранение предыдущих настроек"

    backup_file "${SYSCTL_FILE}"

    if [[ "${CONNTRACK_AVAILABLE}" -eq 1 ]]; then
        backup_file "${MODULES_FILE}"
    fi

    log "Шаг 3 из 4 · Отбор поддерживаемых параметров"

    SYSCTL_TEMP_FILE="$(mktemp)"

    cat > "${SYSCTL_TEMP_FILE}" <<'EOF'
# Remnawave Node system tuning
# Managed by Wanderer-95 Remnawave Node Installer

# BBR congestion control
EOF

    if [[ "${BBR_AVAILABLE}" -eq 1 ]]; then
        apply_sysctl_setting "net.ipv4.tcp_congestion_control" "bbr"
    fi

    if [[ "${FQ_AVAILABLE}" -eq 1 ]]; then
        apply_sysctl_setting "net.core.default_qdisc" "fq"
    fi

    cat >> "${SYSCTL_TEMP_FILE}" <<'EOF'

# TCP buffers
EOF

    apply_sysctl_setting "net.ipv4.tcp_rmem" "4096 131072 16777216"
    apply_sysctl_setting "net.ipv4.tcp_wmem" "4096 65536 16777216"

    cat >> "${SYSCTL_TEMP_FILE}" <<'EOF'

# TCP connection optimization
EOF

    apply_sysctl_setting "net.ipv4.tcp_slow_start_after_idle" "0"
    apply_sysctl_setting "net.ipv4.tcp_no_metrics_save" "1"
    apply_sysctl_setting "net.ipv4.tcp_mtu_probing" "1"

    cat >> "${SYSCTL_TEMP_FILE}" <<'EOF'

# Connection tracking
EOF

    if [[ "${CONNTRACK_AVAILABLE}" -eq 1 ]]; then
        apply_sysctl_setting "net.netfilter.nf_conntrack_max" "262144"
        apply_sysctl_setting "net.netfilter.nf_conntrack_udp_timeout" "120"
        apply_sysctl_setting "net.netfilter.nf_conntrack_udp_timeout_stream" "300"

        printf 'nf_conntrack\n' > "${MODULES_FILE}"

        chmod 644 "${MODULES_FILE}"

        success "nf_conntrack закреплён на загрузку."
    fi

    cat >> "${SYSCTL_TEMP_FILE}" <<'EOF'

# Network queues
EOF

    apply_sysctl_setting "net.core.netdev_max_backlog" "16384"
    apply_sysctl_setting "net.core.somaxconn" "8192"

    cat >> "${SYSCTL_TEMP_FILE}" <<'EOF'

# Local port range
EOF

    apply_sysctl_setting "net.ipv4.ip_local_port_range" "10240 65535"

    install -o root -g root -m 644 "${SYSCTL_TEMP_FILE}" "${SYSCTL_FILE}"

    rm -f "${SYSCTL_TEMP_FILE}"

    success "Применено параметров: ${SYSCTL_APPLIED}"
    log "Пропущено параметров: ${SYSCTL_SKIPPED}"
}

# --------------------------------------------------
# NETWORK QUEUE
# --------------------------------------------------

configure_network_queue() {
    log "Применение сетевой очереди..."

    if [[ "${FQ_AVAILABLE}" -ne 1 ]]; then
        warn "FQ недоступен. Текущая очередь интерфейса не изменяется."
        return 0
    fi

    if [[ -z "${MAIN_INTERFACE:-}" ]]; then
        warn "Основной интерфейс не определён. Применение FQ пропущено."
        return 0
    fi

    if tc qdisc replace dev "${MAIN_INTERFACE}" root fq 2>/dev/null; then
        success "FQ применён к интерфейсу ${MAIN_INTERFACE}."

        tc qdisc show dev "${MAIN_INTERFACE}" || true
    else
        warn "Не удалось применить FQ к ${MAIN_INTERFACE}. Проверь права и поддержку драйвера."
    fi
}

# --------------------------------------------------
# DOCKER SYSTEMD LIMITS
# --------------------------------------------------

configure_docker_limits() {
    log "Настройка системных лимитов Docker..."

    mkdir -p "$(dirname "${DOCKER_LIMITS_FILE}")"

    backup_file "${DOCKER_LIMITS_FILE}"

    cat > "${DOCKER_LIMITS_FILE}" <<'EOF'
[Service]
LimitNOFILE=1048576
LimitNPROC=1048576
EOF

    chmod 644 "${DOCKER_LIMITS_FILE}"

    systemctl daemon-reload

    success "Docker systemd limits настроены."
}

# --------------------------------------------------
# DOCKER LOGGING
# --------------------------------------------------

configure_docker_logging() {
    log "Настройка Docker daemon.json..."

    mkdir -p /etc/docker

    backup_file "${DOCKER_CONFIG}"

    python3 - "${DOCKER_CONFIG}" <<'PY'
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
    raise SystemExit("Docker daemon.json должен содержать JSON-объект.")

config["log-driver"] = "json-file"

log_opts = config.get("log-opts", {})

if not isinstance(log_opts, dict):
    raise SystemExit("Параметр log-opts должен быть JSON-объектом.")

log_opts["max-size"] = "50m"
log_opts["max-file"] = "3"

config["log-opts"] = log_opts

directory = os.path.dirname(path)

fd, temp_path = tempfile.mkstemp(dir=directory, prefix=".daemon.")

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

    chmod 644 "${DOCKER_CONFIG}"

    success "Docker logging настроен: 50 MB × 3."
}

# --------------------------------------------------
# JOURNALD
# --------------------------------------------------

configure_journald() {
    log "Настройка системных журналов..."

    mkdir -p "$(dirname "${JOURNALD_CONFIG}")"

    backup_file "${JOURNALD_CONFIG}"

    cat > "${JOURNALD_CONFIG}" <<'EOF'
[Journal]
SystemMaxUse=200M
EOF

    chmod 644 "${JOURNALD_CONFIG}"

    log "Ограничение размера journald: 200 MB."

    if journalctl --vacuum-size=200M; then
        success "Старые журналы очищены до установленного лимита."
    else
        warn "Не удалось выполнить очистку старых журналов."
    fi

    if systemctl restart systemd-journald; then
        success "systemd-journald перезапущен."
    else
        warn "Не удалось перезапустить systemd-journald."
    fi
}

# --------------------------------------------------
# SAFE DOCKER RESTART
# --------------------------------------------------


restart_docker_safely() {
    log "Проверка контейнеров перед перезапуском Docker..."

    local other_containers=()

    while read -r container_id; do
        [[ -n "${container_id}" ]] || continue

        local container_name

        container_name="$(
            docker inspect -f '{{.Name}}' "${container_id}" |
            sed 's#^/##'
        )"

        if [[ "${container_name}" != "${CONTAINER_NAME}" ]]; then
            other_containers+=("${container_name}")
        fi
    done < <(docker ps -aq)

    if (( ${#other_containers[@]} > 0 )); then
        warn "Обнаружены другие Docker-контейнеры:"

        printf '  - %s\n' "${other_containers[@]}"

        echo
        warn "Перезапуск Docker временно остановит работу этих контейнеров."
        echo

        read -rp "Для продолжения введи RESTART: " confirmation

        [[ "${confirmation}" == "RESTART" ]] \
            || die "Перезапуск Docker отменён. Установка прервана."
    fi

    log "Перезапуск Docker Engine..."

    systemctl restart docker

    systemctl is-active --quiet docker \
        || die "Docker Engine не запустился после перезапуска."

    docker info >/dev/null 2>&1 \
        || die "Docker Engine недоступен после перезапуска."

    success "Docker Engine успешно перезапущен."

    DOCKER_RESTART_SKIPPED=0

    log "Проверка Docker logging..."

    local logging_driver

    logging_driver="$(docker info --format '{{.LoggingDriver}}')"

    [[ "${logging_driver}" == "json-file" ]] \
        || die "Docker logging не применился: ${logging_driver}"

    success "Docker logging: ${logging_driver}"

    log "Проверка системных лимитов..."

    systemctl show docker -p LimitNOFILE -p LimitNPROC

    success "Перезапуск Docker завершён."
}

# --------------------------------------------------
# NODE START
# --------------------------------------------------

start_node() {
    log "Загрузка образа Remnawave Node..."

    docker compose \
        --env-file "${ENV_FILE}" \
        -f "${COMPOSE_FILE}" \
        pull

    log "Запуск Remnawave Node..."

    docker compose \
        --env-file "${ENV_FILE}" \
        -f "${COMPOSE_FILE}" \
        up -d --force-recreate

    log "Ожидание запуска контейнера..."

    for attempt in {1..30}; do
        if [[ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null || true)" == "true" ]]; then
            break
        fi

        sleep 2
    done

    [[ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null || true)" == "true" ]] \
        || die "Контейнер не запустился. Проверь: docker logs ${CONTAINER_NAME}"

    success "Remnawave Node успешно запущена."
}

# --------------------------------------------------
# SYSTEM TUNING VERIFICATION
# --------------------------------------------------

verify_system_tuning() {
    log "Проверка применённых настроек..."

    local key
    local value

    while read -r key _ value; do
        [[ "${key}" == net.* ]] || continue

        local actual

        actual="$(sysctl -n "${key}" 2>/dev/null || true)"

        if [[ "${actual}" == "${value}" ]]; then
            success "${key} = ${actual}"
        else
            warn "${key}: ожидалось '${value}', получено '${actual:-недоступно}'."
        fi
    done < "${SYSCTL_FILE}"

    if [[ -n "${MAIN_INTERFACE:-}" ]]; then
        log "Текущая очередь ${MAIN_INTERFACE}:"

        tc qdisc show dev "${MAIN_INTERFACE}" 2>/dev/null || true
    fi

    log "Проверка Docker logging..."

    docker info --format '{{.LoggingDriver}}' 2>/dev/null || true

    log "Проверка Docker systemd limits..."

    systemctl show docker \
        -p LimitNOFILE \
        -p LimitNPROC || true
}

# --------------------------------------------------
# X25519
# --------------------------------------------------

generate_parameters() {
    log "Генерация X25519..."

    docker exec "${CONTAINER_NAME}" xray x25519

    log "Генерация дополнительного случайного значения..."

    openssl rand -hex 8

    success "Параметры сгенерированы."
}

# --------------------------------------------------
# FINAL STATUS
# --------------------------------------------------

show_result() {
    printf '\n'

    printf '\033[1;36m'
    cat <<'EOF'
╔══════════════════════════════════════════════╗
║            INSTALLATION COMPLETE             ║
╚══════════════════════════════════════════════╝
EOF
    printf '\033[0m\n'

    success "Remnawave Node ${VERSION} установлена."

    echo
    echo "УСТАНОВКА"
    echo "Каталог: ${INSTALL_DIR}"
    echo "Compose: ${COMPOSE_FILE}"
    echo "Секрет:  ${ENV_FILE} (права 600)"

    echo
    echo "СИСТЕМНАЯ ОПТИМИЗАЦИЯ"
    echo "Ядро: ${KERNEL_VERSION}"
    echo "Виртуализация: ${VIRT_TYPE}"
    echo "Интерфейс: ${MAIN_INTERFACE:-не определён}"
    echo "BBR: ${BBR_AVAILABLE}"
    echo "FQ: ${FQ_AVAILABLE}"
    echo "Conntrack: ${CONNTRACK_AVAILABLE}"
    echo "Применено sysctl: ${SYSCTL_APPLIED}"
    echo "Пропущено sysctl: ${SYSCTL_SKIPPED}"

    echo
    echo "DOCKER"
    echo "Logging: json-file"
    echo "Max log size: 50 MB"
    echo "Max log files: 3"
    echo "NOFILE: 1048576"
    echo "NPROC: 1048576"

    if [[ "${DOCKER_RESTART_SKIPPED}" -eq 1 ]]; then
        warn "Docker не перезапускался из-за работающих посторонних контейнеров."
        echo "Новые настройки Docker применятся после безопасного перезапуска Docker."
    else
        success "Настройки Docker применены."
    fi

    echo
    echo "JOURNALD"
    echo "SystemMaxUse: 200M"

    echo
    echo "UFW"
    ufw status

    echo
    echo "REMNANODE"
    docker ps --filter "name=^/${CONTAINER_NAME}$"

    echo
    echo "КОМАНДЫ"
    echo "Логи: docker logs -f ${CONTAINER_NAME}"
    echo "Статус: docker ps"
    echo "Перезагрузка Node: cd ${INSTALL_DIR} && docker compose up -d"

    echo
    echo "Добавь Node в панели Remnawave, используя параметры своей конфигурации."

    if [[ "${DOCKER_RESTART_SKIPPED}" -eq 1 ]]; then
        echo
        warn "ВНИМАНИЕ: настройки Docker ожидают перезапуска Docker Engine."
        echo "Не перезапускай Docker, пока работающие посторонние контейнеры не будут готовы к остановке."
    fi

    echo
    success "Установка завершена."
}

# --------------------------------------------------
# MAIN
# --------------------------------------------------

main() {
    check_system

    select_mode

    if [[ "${MODE}" == "fresh" ]]; then
        check_fresh_install
    else
        printf '\n'

        warn "ВНИМАНИЕ! Будет удалена существующая Remnawave Node."

        echo
        echo "Будут удалены:"
        echo "  - Контейнер remnanode"
        echo "  - Каталог /opt/remnanode"
        echo "  - Файл .env с прежним SECRET_KEY"
        echo "  - Локальный образ Remnawave Node (если не используется другими контейнерами)"

        echo
        echo "Сохраняются:"
        echo "  - Ubuntu и системные настройки"
        echo "  - SSH"
        echo "  - UFW и существующие правила"
        echo "  - Docker и Docker Compose"
        echo "  - Другие контейнеры"
        echo "  - Другие сервисы"

        echo

        read -rp "Для подтверждения введи DELETE: " confirmation

        [[ "${confirmation}" == "DELETE" ]] || die "Переустановка отменена."

        remove_remnanode
    fi

    install_packages

    install_docker

    detect_ssh_port

    read_secret_key

    create_configuration

    configure_firewall

    # SYSTEM OPTIMIZATION

    check_system_tuning

    configure_sysctl

    configure_network_queue

    configure_docker_limits

    configure_docker_logging

    configure_journald

    restart_docker_safely

    # START NODE AFTER OPTIMIZATION

    start_node

    # VERIFY ALL SETTINGS

    verify_system_tuning

    # GENERATE PARAMETERS ONLY AFTER INSTALLATION

    generate_parameters

    show_result
}

main "$@"
