#!/usr/bin/env bash
set -Eeuo pipefail

# Remnawave Node installer for Ubuntu 24.04
# Repository: https://github.com/Wanderer-95/remnanode-installer

INSTALL_DIR="/opt/remnanode"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
ENV_FILE="${INSTALL_DIR}/.env"
CONTAINER_NAME="remnanode"
REQUIRED_PORTS=(2222 443 8443 80)

log()  { printf '\n\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

trap 'die "Установка прервана на строке ${LINENO}. Проверь вывод выше."' ERR

[[ "${EUID}" -eq 0 ]] || die "Запусти скрипт от root: sudo -i"
[[ -r /etc/os-release ]] || die "Не удалось определить ОС."
. /etc/os-release
[[ "${ID}" == "ubuntu" ]] || die "Поддерживается Ubuntu. Обнаружена: ${PRETTY_NAME:-unknown}"
[[ "${VERSION_ID:-}" == "24.04" ]] || warn "Скрипт рассчитан на Ubuntu 24.04; обнаружена ${VERSION_ID:-unknown}."

if [[ -t 0 ]]; then
    read -rsp "Вставь SECRET_KEY из панели Remnawave: " SECRET_KEY
    printf '\n'
else
    die "Нужен интерактивный терминал для безопасного ввода SECRET_KEY."
fi

[[ -n "${SECRET_KEY}" ]] || die "SECRET_KEY не может быть пустым."
[[ "${SECRET_KEY}" != *$'\n'* && "${SECRET_KEY}" != *$'\r'* ]] || die "SECRET_KEY не должен содержать переносы строк."

log "Проверка SSH-порта и текущего доступа..."
SSH_PORT="22"
if command -v sshd >/dev/null 2>&1; then
    detected_port="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')"
    [[ -n "${detected_port:-}" ]] && SSH_PORT="${detected_port}"
fi
log "SSH-порт для правила UFW: ${SSH_PORT}/tcp"

log "Обновление пакетов..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y
apt-get install -y ca-certificates curl openssl ufw

log "Установка Docker Engine и Compose..."
if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
else
    log "Docker уже установлен — пропускаю установку."
fi

systemctl enable --now docker
docker compose version >/dev/null 2>&1 || die "Docker Compose plugin не найден."

log "Подготовка ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}"
chmod 700 "${INSTALL_DIR}"

# Compose dotenv single-quoted values support escaped single quotes and backslashes.
dotenv_value="${SECRET_KEY//\\/\\\\}"
dotenv_value="${dotenv_value//\'/\\\'}"
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
docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" config -q

log "Настройка UFW..."
# Allow the active SSH port before enabling the firewall.
ufw allow "${SSH_PORT}/tcp" comment 'SSH'
for port in "${REQUIRED_PORTS[@]}"; do
    ufw allow "${port}/tcp" comment "Remnawave Node ${port}"
done

if ufw status | grep -q '^Status: active'; then
    log "UFW уже активен — существующие правила сохранены."
else
    warn "Сейчас будет включён UFW. SSH-порт ${SSH_PORT}/tcp заранее разрешён."
    ufw --force enable
fi

log "Загрузка образа и запуск Remnawave Node..."
docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" pull
docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" up -d

log "Ожидание запуска контейнера..."
for attempt in {1..30}; do
    if [[ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null || true)" == "true" ]]; then
        break
    fi
    sleep 2
done
[[ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null || true)" == "true" ]] \
    || die "Контейнер не запустился. Проверь: docker logs ${CONTAINER_NAME}"

log "Генерация X25519..."
docker exec "${CONTAINER_NAME}" xray x25519

log "Генерация дополнительного случайного значения (openssl rand -hex 8)..."
openssl rand -hex 8

printf '\n'
log "Установка завершена."
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
