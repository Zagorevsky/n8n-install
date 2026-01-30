#!/bin/bash
set -e

# --- Проверка root ---
if [ "$EUID" -ne 0 ]; then
  echo "❌ Запусти скрипт через sudo или под root"
  exit 1
fi

echo "=== n8n one-shot установка на новый VPS ==="

# --- ВВОД ДОМЕНА И EMAIL ---
read -p "Домен для n8n (например, bot.n-46.ru): " DOMAIN
read -p "Email для Let's Encrypt (например, user@example.com): " EMAIL

if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
  echo "❌ DOMAIN и EMAIL обязательны"
  exit 1
fi

echo "Домен: $DOMAIN"
echo "Email:  $EMAIL"

# --- ОБНОВЛЕНИЕ И УСТАНОВКА DOCKER ---
apt update && apt upgrade -y
apt install -y curl git ca-certificates gnupg lsb-release

# Добавляем репозиторий Docker
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Проверка установки
if ! command -v docker >/dev/null 2>&1; then
  echo "❌ Docker не установился"
  exit 1
fi
usermod -aG docker "$SUDO_USER" 2>/dev/null || true

echo "✅ Docker и docker-compose установлены"

# --- ПОДГОТОВКА КАТАЛОГА ---
mkdir -p /opt/n8n/{data,postgres-data,redis-data,letsencrypt,backups}
cd /opt/n8n
chown -R 1000:1000 data

# --- ГЕНЕРАЦИЯ ПАРОЛЕЙ ---
POSTGRES_PASSWORD=$(openssl rand -base64 32)
N8N_PASSWORD=$(openssl rand -base64 24)

echo "=== Сгенерированы пароли ==="
echo "POSTGRES_PASSWORD: $POSTGRES_PASSWORD"
echo "N8N_PASSWORD (admin): $N8N_PASSWORD"
echo "⚠️ СКОПИРУЙ их и сохрани!"

# --- .env ---
cat > .env << EOF
DOMAIN=$DOMAIN
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
N8N_PASSWORD=$N8N_PASSWORD
EOF
echo "✅ Файл .env создан"

# --- docker-compose.yml ---
cat > docker-compose.yml << EOF
version: '3.8'

services:
  traefik:
    image: traefik:v2.10
    restart: always
    command:
      - "--api.dashboard=true"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.docker.endpoint=unix:///var/run/docker.sock"
      - "--providers.docker.watch=true"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.letsencrypt.acme.httpchallenge=true"
      - "--certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web"
      - "--certificatesresolvers.letsencrypt.acme.email=$EMAIL"
      - "--certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./letsencrypt:/letsencrypt

  postgres:
    image: postgres:15-alpine
    restart: always
    environment:
      - POSTGRES_USER=n8n
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=n8n
    volumes:
      - ./postgres-data:/var/lib/postgresql/data

  redis:
    image: redis:7-alpine
    restart: always
    volumes:
      - ./redis-data:/data
    command: redis-server --appendonly yes

  n8n-main:
    image: n8nio/n8n:latest
    restart: always
    environment:
      - EXECUTIONS_MODE=queue
      - QUEUE_BULL_REDIS_HOST=redis
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_DATABASE=n8n
      - DB_POSTGRESDB_USER=n8n
      - DB_POSTGRESDB_PASSWORD=\${POSTGRES_PASSWORD}
      - N8N_HOST=\${DOMAIN}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - WEBHOOK_URL=https://\${DOMAIN}/
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=admin
      - N8N_BASIC_AUTH_PASSWORD=\${N8N_PASSWORD}
      - GENERIC_TIMEZONE=Europe/Moscow
      - N8N_SECURE_COOKIE=false
    volumes:
      - ./data:/home/node/.n8n
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(\`\${DOMAIN}\`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=letsencrypt"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"
    depends_on:
      postgres:
        condition: service_started
      redis:
        condition: service_started

  n8n-worker:
    image: n8nio/n8n:latest
    command: worker
    restart: always
    environment:
      - EXECUTIONS_MODE=queue
      - QUEUE_BULL_REDIS_HOST=redis
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_DATABASE=n8n
      - DB_POSTGRESDB_USER=n8n
      - DB_POSTGRESDB_PASSWORD=\${POSTGRES_PASSWORD}
    volumes:
      - ./data:/home/node/.n8n
    depends_on:
      postgres:
        condition: service_started
      redis:
        condition: service_started
EOF
echo "✅ docker-compose.yml создан"

# --- ЗАПУСК ---
docker-compose down || true
docker-compose up -d

# Даем Traefik немного времени на регистрацию контейнеров
sleep 5

echo "✅ Контейнеры запущены"
echo
echo "=== ДАННЫЕ ДЛЯ ВХОДА ==="
echo "URL:    https://$DOMAIN"
echo "Логин: admin"
echo "Пароль: $N8N_PASSWORD"
echo
echo "‼️ Не забудь в DNS настроить A-запись для $DOMAIN на IP этого VPS и подождать, пока обновится DNS."
