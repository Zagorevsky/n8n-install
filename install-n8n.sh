#!/bin/bash
set -euo pipefail

########################################
# 1. ПРОВЕРКИ СИСТЕМЫ
########################################

if [ "$EUID" -ne 0 ]; then
  echo "❌ Запусти скрипт через sudo"
  exit 1
fi

if ! command -v lsb_release >/dev/null 2>&1; then
  apt update && apt install -y lsb-release
fi

DISTRO=$(lsb_release -is)
VERSION=$(lsb_release -rs)
CODENAME=$(lsb_release -cs)

if [[ "$DISTRO" != "Ubuntu" ]]; then
  echo "❌ Поддерживается только Ubuntu"
  exit 1
fi

case "$VERSION" in
  20.04|22.04|24.04) ;;
  *) echo "❌ Требуется Ubuntu 20.04+"; exit 1 ;;
esac

########################################
# 2. ВВОД ДАННЫХ
########################################

echo "=== Настройка n8n с авто-бэкапами ==="
read -rp "Домен (например, n8n.example.com): " DOMAIN
read -rp "Email для SSL (Let's Encrypt): " EMAIL

if [[ -z "$DOMAIN" || -z "$EMAIL" ]]; then
  echo "❌ Домен и Email обязательны"
  exit 1
fi

########################################
# 3. УСТАНОВКА DOCKER
########################################

apt update && apt upgrade -y
apt install -y ca-certificates curl gnupg git openssl

mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $CODENAME stable" > /etc/apt/sources.list.d/docker.list

apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

########################################
# 4. ПОДГОТОВКА ОКРУЖЕНИЯ
########################################

mkdir -p /opt/n8n/{data,postgres-data,redis-data,letsencrypt,backups}
cd /opt/n8n

chown -R 1000:1000 /opt/n8n/data
touch /opt/n8n/letsencrypt/acme.json
chmod 600 /opt/n8n/letsencrypt/acme.json

DB_PASSWORD=$(openssl rand -base64 24)
ENCRYPTION_KEY=$(openssl rand -hex 24)

cat > .env <<EOF
DOMAIN=$DOMAIN
EMAIL=$EMAIL
POSTGRES_PASSWORD=$DB_PASSWORD
N8N_ENCRYPTION_KEY=$ENCRYPTION_KEY
EOF

########################################
# 5. ГЕНЕРАЦИЯ DOCKER COMPOSE
########################################

cat > docker-compose.yml <<'EOF'
services:
  traefik:
    image: traefik:v3.0
    restart: always
    command:
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --entrypoints.web.address=:80
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
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
    networks:
      - public

  postgres:
    image: postgres:16-alpine
    restart: always
    environment:
      POSTGRES_USER: n8n
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: n8n
    volumes:
      - ./postgres-data:/var/lib/postgresql/data
    networks:
      - private

  # Контейнер для бэкапов (запускается раз в сутки)
  postgres-backup:
    image: prodrigestivill/postgres-backup-local:16-alpine
    restart: always
    environment:
      POSTGRES_HOST: postgres
      POSTGRES_CLUSTER: 'FALSE'
      POSTGRES_USER: n8n
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: n8n
      SCHEDULE: '@daily'
      BACKUP_KEEP_DAYS: 7
      BACKUP_SUFFIX: .sql.gz
    volumes:
      - ./backups:/backups
    depends_on:
      - postgres
    networks:
      - private

  redis:
    image: redis:7-alpine
    restart: always
    networks:
      - private

  n8n:
    image: n8nio/n8n:latest
    restart: always
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_USER=n8n
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
      - N8N_HOST=${DOMAIN}
      - WEBHOOK_URL=https://${DOMAIN}/
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
    volumes:
      - ./data:/home/node/.n8n
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(`${DOMAIN}`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=letsencrypt"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"
    networks:
      - public
      - private
    depends_on:
      - postgres

networks:
  public:
  private:
EOF

########################################
# 6. ЗАПУСК
########################################

echo "🚀 Запуск всех служб..."
docker compose pull
docker compose up -d

echo "-------------------------------------------------------"
echo "✅ Готово!"
echo "🌐 URL: https://$DOMAIN"
echo "📂 Бэкапы БД здесь: /opt/n8n/backups"
echo "-------------------------------------------------------"
