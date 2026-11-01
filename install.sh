
#!/usr/bin/env bash
set -Eeuo pipefail

# Remnawave Node Installer
# Repository: https://github.com/Wanderer-95/remnanode-installer
# Version: 1.0.0

VERSION="1.0.0"

INSTALL_DIR="/opt/remnanode"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
ENV_FILE="${INSTALL_DIR}/.env"

CONTAINER_NAME="remnanode"
IMAGE_NAME="remnawave/node:latest"

REQUIRED_PORTS=(2222 443 8443 80)

log() {
    printf '\n\033[1;34m[INFO]\033[0m %s\n' "$*"
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

    if [[ ! -e "${INSTALL_DIR}" && ! -L "${INSTALL_DIR}" ]] && ! docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
        warn "Существующая установка Remnawave Node не обнаружена."
        return
    fi

    # Do not proceed without Docker: container ownership cannot be verified.
    command -v docker >/dev/null 2>&1 || die "Docker не найден. Невозможно безопасно проверить и удалить Node."

    docker info >/dev/null 2>&1 || die "Docker Engine недоступен. Удаление отменено."

    # Refuse symlinks to prevent deletion outside the intended directory.
    if [[ -L "${INSTALL_DIR}" ]]; then
        die "${INSTALL_DIR} является символической ссылкой. Автоматическое удаление запрещено."
    fi

    local image_id=""
    local container_image=""

    if docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
        container_image="$(docker inspect -f '{{.Config.Image}}' "${CONTAINER_NAME}")"
        image_id="$(docker inspect -f '{{.Image}}' "${CONTAINER_NAME}")"

        if [[ "${container_image}" != remnawave/node:* ]]; then
            die "Контейнер ${CONTAINER_NAME} использует посторонний образ: ${container_image}. Удаление отменено."
        fi

        log "Обнаружен контейнер Remnawave Node."
        log "Остановка контейнера..."

        docker stop "${CONTAINER_NAME}"

        log "Удаление контейнера..."
        docker rm "${CONTAINER_NAME}"
    else
        warn "Контейнер ${CONTAINER_NAME} не обнаружен."
    fi

    # Remove only the dedicated installation directory.
    if [[ -d "${INSTALL_DIR}" ]]; then
        log "Удаление конфигурации ${INSTALL_DIR}..."

        rm -rf --one-file-system -- "${INSTALL_DIR}"
    elif [[ -e "${INSTALL_DIR}" ]]; then
        die "${INSTALL_DIR} существует, но не является обычным каталогом. Удаление отменено."
    fi

    # Remove the Node image only if no remaining container uses its image ID.
    if [[ -n "${image_id}" ]]; then
        local dependent_containers

        dependent_containers="$(
            docker ps -aq --filter "ancestor=${image_id}" |
            while read -r id; do
                [[ -n "${id}" ]] && printf '%s\n' "${id}"
            done
        )"

        if [[ -n "${dependent_containers}" ]]; then
            warn "Образ используется другими контейнерами. Образ оставлен без изменений."
        else
            log "Удаление образа Remnawave Node..."

            docker image rm "${image_id}" || warn "Не удалось удалить образ ${image_id}. Остальные действия не затронуты."
        fi
    else
        warn "Образ текущего контейнера не определён. Проверка локального образа..."

        if docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
            local tagged_image_id
            tagged_image_id="$(docker image inspect -f '{{.Id}}' "${IMAGE_NAME}")"

            if docker ps -aq --filter "ancestor=${tagged_image_id}" | grep -q .; then
                warn "Образ используется другими контейнерами. Оставляю его."
            else
                docker image rm "${IMAGE_NAME}" || warn "Не удалось удалить локальный образ."
            fi
        fi
    fi

    log "Компоненты Remnawave Node удалены."
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

    # Escape values for Docker Compose single-quoted dotenv syntax.
    dotenv_value="${SECRET_KEY//\\/\\\\}"
    dotenv_value="${dotenv_value//\'/\\\'}"
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

    # Preserve all existing firewall rules.
    ufw allow "${SSH_PORT}/tcp" comment 'SSH'

    for port in "${REQUIRED_PORTS[@]}"; do
        ufw allow "${port}/tcp" comment "Remnawave Node ${port}"
    done

    if ufw status | grep -q '^Status: active'; then
        log "UFW уже активен. Существующие правила сохранены."
    else
        warn "Включение UFW. SSH-порт ${SSH_PORT}/tcp предварительно разрешён."
        ufw --force enable
    fi
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
# SYSTEM PACKAGES
# --------------------------------------------------

install_packages() {
    log "Обновление списка пакетов..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update
    apt-get upgrade -y

    apt-get install -y ca-certificates curl openssl ufw iproute2
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

    log "Проверка конфигурации Docker Compose..."

    docker compose \
        --env-file "${ENV_FILE}" \
        -f "${COMPOSE_FILE}" \
        config -q
}

# --------------------------------------------------
# START NODE
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
        up -d

    log "Ожидание запуска контейнера..."

    for attempt in {1..30}; do
        if [[ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null || true)" == "true" ]]; then
            break
        fi

        sleep 2
    done

    [[ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null || true)" == "true" ]] \
        || die "Контейнер не запустился. Проверь: docker logs ${CONTAINER_NAME}"

    log "Контейнер успешно запущен."
}

# --------------------------------------------------
# X25519
# --------------------------------------------------

generate_parameters() {
    log "Генерация X25519..."

    docker exec "${CONTAINER_NAME}" xray x25519

    log "Генерация дополнительного случайного значения..."

    openssl rand -hex 8
}

# --------------------------------------------------
# FINAL STATUS
# --------------------------------------------------

show_result() {
    printf '\n'
    log "Установка Remnawave Node ${VERSION} завершена."

    echo "Каталог: ${INSTALL_DIR}"
    echo "Compose: ${COMPOSE_FILE}"
    echo "Секрет:  ${ENV_FILE} (права 600)"

    echo
    echo "Статус контейнера:"
    docker ps --filter "name=^/${CONTAINER_NAME}$"

    echo
    echo "Статус UFW:"
    ufw status

    echo
    echo "Добавь Node в панели Remnawave, используя параметры своей конфигурации."
    echo "Логи: docker logs -f ${CONTAINER_NAME}"
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
        echo "  - Локальный образ remnawave/node (если он не используется другими контейнерами)"
        echo
        echo "Docker, Compose, SSH, UFW, Ubuntu и другие контейнеры сохраняются."
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

    start_node
    generate_parameters
    show_result
}

main "$@"
