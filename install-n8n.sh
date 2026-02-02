#!/bin/bash
# Скрипт автоматической установки n8n + Traefik + Postgres + Backup
set -euo pipefail

########################################
# 1. ПОДГОТОВКА И ПРОВЕРКИ
########################################
if [ "$EUID" -ne 0 ]; then
  echo "❌ Запусти скрипт через sudo"
  exit 1
fi

echo "🔄 Обновление индексов и установка базовых утилит..."
apt update && apt install -y lsb-release curl jq openssl git ca-certificates gnupg

DISTRO=$(lsb_release -is)
CODENAME=$(lsb_release -cs)

if [[ "$DISTRO" != "Ubuntu" ]]; then
  echo "❌ Поддерживается только Ubuntu"
  exit 1
fi

########################################
# 2. ФИКС DOCKER API (Для совместимости с Traefik)
########################################
echo "🔧 Настройка Docker API compatibility..."
mkdir -p /etc/docker
DOCKER_CONFIG="/etc/docker/daemon.json"

if [ -f "$DOCKER_CONFIG" ]; then
    tmp=$(mktemp)
    jq '. + {"min-api-version": "1.24"}' "$DOCKER_CONFIG" > "$tmp" && mv "$tmp" "$DOCKER_CONFIG"
else
    echo '{"min-api-version": "1.24"}' > "$DOCKER_CONFIG"
fi

########################################
# 3. УСТАНОВКА DOCKER
########################################
echo "📦 Установка Docker Engine..."
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $CODENAME stable" > /etc/apt/sources.list.d/docker.list

apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Перезапуск демона для активации конфига
systemctl daemon-reload
systemctl restart docker

########################################
# 4. ВВОД ДАННЫХ
########################################
echo "-------------------------------------------------------"
read -rp "Введите домен (например, n8n.example.com): " DOMAIN
read -rp "Введите ваш Email (для SSL): " EMAIL
echo "-------------------------------------------------------"

# Подготовка папок
mkdir -p /opt/n8n/{data,postgres-data,redis-data,letsencrypt,backups}
cd /opt/n8n

# Генерация секретов
DB_PASSWORD=$(openssl rand -base64 24)
ENCRYPTION_KEY=$(openssl rand -hex 24)

# Создание .env
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
    container_name: n8n-traefik
    restart: always
    user: root
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
    container_name: n8n-postgres
    restart: always
    environment:
      POSTGRES_USER: n8n
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: n8n
    volumes:
      - ./postgres-data:/var/lib/postgresql/data
    networks:
      - private

  postgres-backup:
    image: prodrigestivill/postgres-backup-local:16-alpine
    container_name: n8n-backup
    restart: always
    environment:
      POSTGRES_HOST: postgres
      POSTGRES_USER: n8n
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: n8n
      SCHEDULE: '@daily'
      BACKUP_KEEP_DAYS: 7
    volumes:
      - ./backups:/backups
    depends_on:
      - postgres
    networks:
      - private

  redis:
    image: redis:7-alpine
    container_name: n8n-redis
    restart: always
    networks:
      - private

  n8n:
    image: n8nio/n8n:latest
    container_name: n8n-main
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
# 6. ФИНАЛЬНЫЙ ЗАПУСК
########################################
chown -R 1000:1000 /opt/n8n/data
touch /opt/n8n/letsencrypt/acme.json
chmod 600 /opt/n8n/letsencrypt/acme.json

echo "🚀 Запуск Docker Compose..."
docker compose up -d

echo "-------------------------------------------------------"
echo "✅ Установка на чистый сервер завершена!"
echo "🌐 Ссылка: https://$DOMAIN"
echo "📁 Рабочая директория: /opt/n8n"
echo "-------------------------------------------------------"
