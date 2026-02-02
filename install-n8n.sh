#!/bin/bash
set -euo pipefail

########################################
# ПРОВЕРКИ
########################################

if [ "$EUID" -ne 0 ]; then
  echo "❌ Запусти скрипт через sudo"
  exit 1
fi

if ! command -v lsb_release >/dev/null 2>&1; then
  apt update
  apt install -y lsb-release
fi

DISTRO=$(lsb_release -is)
CODENAME=$(lsb_release -cs)
VERSION=$(lsb_release -rs)

if [[ "$DISTRO" != "Ubuntu" ]]; then
  echo "❌ Поддерживается только Ubuntu"
  exit 1
fi

case "$VERSION" in
  20.04|22.04|24.04)
    ;;
  *)
    echo "❌ Ubuntu $VERSION слишком старая. Минимум 20.04"
    exit 1
    ;;
esac

echo "✅ Ubuntu $VERSION ($CODENAME) — поддерживается"

########################################
# ВВОД ДАННЫХ
########################################

read -rp "Домен для n8n (например, bot.example.com): " DOMAIN
read -rp "Email для Let's Encrypt: " EMAIL

if [[ -z "$DOMAIN" || -z "$EMAIL" ]]; then
  echo "❌ DOMAIN и EMAIL обязательны"
  exit 1
fi

########################################
# ОБНОВЛЕНИЕ СИСТЕМЫ
########################################

apt update
apt upgrade -y
apt install -y \
  ca-certificates \
  curl \
  gnupg \
  git \
  lsb-release \
  openssl

########################################
# УСТАНОВКА DOCKER (OFFICIAL)
########################################

echo "=== Установка Docker Engine ==="

mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $CODENAME stable" \
  > /etc/apt/sources.list.d/docker.list

apt update
apt install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

########################################
# ЖЁСТКАЯ ПРОВЕРКА: НИКАКОГО compose v1
########################################

if command -v docker-compose >/dev/null 2>&1; then
  echo "❌ Найден docker-compose v1 — УДАЛЯЕМ"
  apt remove -y docker-compose || true
  rm -f /usr/local/bin/docker-compose || true
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "❌ docker compose plugin не работает"
  exit 1
fi

docker --version
docker compose version

########################################
# ПОДГОТОВКА КАТАЛОГА
########################################

mkdir -p /opt/n8n/{data,postgres-data,redis-data,letsencrypt,backups}
cd /opt/n8n
chown -R 1000:1000 data

########################################
# ACME (Traefik)
########################################

touch /opt/n8n/letsencrypt/acme.json
chmod 600 /opt/n8n/letsencrypt/acme.json

########################################
# ПАРОЛИ
########################################

POSTGRES_PASSWORD=$(openssl rand -base64 32)
N8N_PASSWORD=$(openssl rand -base64 24)

echo
echo "=== СГЕНЕРИРОВАНЫ ПАРОЛИ ==="
echo "POSTGRES_PASSWORD: $POSTGRES_PASSWORD"
echo "N8N_PASSWORD:      $N8N_PASSWORD"
echo "⚠️ СОХРАНИ ИХ"
echo

########################################
# .env
########################################

cat > .env <<EOF
DOMAIN=$DOMAIN
EMAIL=$EMAIL
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
N8N_PASSWORD=$N8N_PASSWORD
EOF

########################################
# docker-compose.yml (n8nio/n8n:1.122.5, без воркеров)
########################################

cat > docker-compose.yml <<'EOF'
services:
  traefik:
    image: traefik:latest
    restart: always
    command:
      - --log.level=INFO
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --providers.docker.watch=true
      - --providers.docker.endpoint=unix:///var/run/docker.sock
      - --entrypoints.web.address=:80
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.web.http.redirections.entrypoint.scheme=https
      - --entrypoints.websecure.address=:443
      - --certificatesresolvers.letsencrypt.acme.httpchallenge=true
      - --certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web
      - --certificatesresolvers.letsencrypt.acme.email=${EMAIL}
      - --certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./letsencrypt:/letsencrypt
    networks: [traefik]

  postgres:
    image: postgres:17-alpine
    restart: always
    environment:
      POSTGRES_USER: n8n
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: n8n
    volumes:
      - ./postgres-data:/var/lib/postgresql/data
    networks: [internal]

  redis:
    image: redis:8-alpine
    restart: always
    command: redis-server --appendonly yes
    volumes:
      - ./redis-data:/data
    networks: [internal]

  n8n:
    image: n8nio/n8n:1.122.5
    restart: always
    environment:
      # РЕЖИМ БЕЗ ВОРКЕРОВ - только main процесс
      EXECUTIONS_MODE: regular
      EXECUTIONS_PROCESS: main
      
      # База данных
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_DATABASE: n8n
      DB_POSTGRESDB_USER: n8n
      DB_POSTGRESDB_PASSWORD: ${POSTGRES_PASSWORD}
      
      # Настройки хоста
      N8N_HOST: ${DOMAIN}
      N8N_PROTOCOL: https
      WEBHOOK_URL: https://${DOMAIN}/
      
      # Базовая авторизация
      N8N_BASIC_AUTH_ACTIVE: "true"
      N8N_BASIC_AUTH_USER: admin
      N8N_BASIC_AUTH_PASSWORD: ${N8N_PASSWORD}
      
      # Дополнительные настройки
      GENERIC_TIMEZONE: Europe/Moscow
      NODE_ENV: production
      N8N_METRICS: "false"
      
    volumes:
      - ./data:/home/node/.n8n
    labels:
      - traefik.enable=true
      - traefik.http.routers.n8n.rule=Host(`${DOMAIN}`)
      - traefik.http.routers.n8n.entrypoints=websecure
      - traefik.http.routers.n8n.tls.certresolver=letsencrypt
      - traefik.http.services.n8n.loadbalancer.server.port=5678
    networks: [internal, traefik]
    depends_on:
      - postgres
      - redis

networks:
  traefik:
  internal:
    internal: true
EOF

########################################
# ЗАПУСК
########################################

docker compose pull
docker compose down || true
docker compose up -d --force-recreate

echo
echo "✅ n8n [1.122.5] запущен БЕЗ ВОРКЕРОВ"
echo "🌐 https://$DOMAIN"
echo "👤 admin / $N8N_PASSWORD"
echo "📦 Только main процесс (EXECUTIONS_MODE: regular)"
echo
echo "🔍 Логи: docker compose logs -f n8n"
