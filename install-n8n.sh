#!/bin/bash
# Automatic installation: n8n (v1.122.5) + Traefik v3 + Postgres + Redis
set -euo pipefail

########################################
# 1. PRE-FLIGHT CHECKS AND PREPARATION
########################################
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run this script as sudo"
  exit 1
fi

echo "🔄 Preparing system and installing utilities..."
# Fix for EOL/Archive Ubuntu versions (switches to old-releases if 404 occurs)
sed -i -re 's/([a-z]{2}\.)?archive.ubuntu.com|security.ubuntu.com/old-releases.ubuntu.com/g' /etc/apt/sources.list || true

apt update && apt install -y lsb-release curl jq openssl git ca-certificates gnupg

# Free up ports 80 and 443 (stop Apache/Nginx if they are running)
systemctl stop nginx apache2 || true
systemctl disable nginx apache2 || true

########################################
# 2. DOCKER API CONFIGURATION (Critical for Traefik v3 compatibility)
########################################
echo "🔧 Configuring Docker API compatibility..."
mkdir -p /etc/docker
DOCKER_CONFIG="/etc/docker/daemon.json"

if [ -f "$DOCKER_CONFIG" ]; then
    # If file exists, merge the min-api-version using jq
    tmp=$(mktemp)
    jq '. + {"min-api-version": "1.24"}' "$DOCKER_CONFIG" > "$tmp" && mv "$tmp" "$DOCKER_CONFIG"
else
    # Create new config if it doesn't exist
    echo '{"min-api-version": "1.24"}' > "$DOCKER_CONFIG"
fi

########################################
# 3. DOCKER INSTALLATION
########################################
echo "📦 Installing Docker Engine..."
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes

CODENAME=$(lsb_release -cs)
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $CODENAME stable" > /etc/apt/sources.list.d/docker.list

apt update && apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Reload and restart Docker to apply API changes
systemctl daemon-reload
systemctl restart docker

########################################
# 4. USER INPUT AND ENVIRONMENT SETUP
########################################
echo "-------------------------------------------------------"
read -rp "Enter your domain (e.g., n8n.example.com): " DOMAIN
read -rp "Enter your email for SSL: " EMAIL
echo "-------------------------------------------------------"

# Create necessary directories
mkdir -p /opt/n8n/{data,postgres-data,redis-data,letsencrypt,backups}
cd /opt/n8n

# Generate secure random secrets
DB_PASSWORD=$(openssl rand -base64 24)
ENCRYPTION_KEY=$(openssl rand -hex 24)

# Create .env file
cat > .env <<EOF
DOMAIN=$DOMAIN
EMAIL=$EMAIL
POSTGRES_PASSWORD=$DB_PASSWORD
N8N_ENCRYPTION_KEY=$ENCRYPTION_KEY
EOF

########################################
# 5. DOCKER COMPOSE GENERATION
########################################
# Using 'EOF' in quotes to prevent shell expansion of variables during file creation
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

  redis:
    image: redis:7-alpine
    container_name: n8n-redis
    restart: always
    networks:
      - private

  n8n:
    image: n8nio/n8n:1.122.5
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
      - N8N_RUNNERS_ENABLED=true
    volumes:
      - ./data:/home/node/.n8n
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(`${DOMAIN}`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=letsencrypt"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"
      - "traefik.docker.network=public" # Fixes 504 Gateway Timeout when multi-network is used
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
# 6. PERMISSIONS AND DEPLOYMENT
########################################
# Set correct ownership for n8n data
chown -R 1000:1000 /opt/n8n/data
# Set secure permissions for SSL storage
touch /opt/n8n/letsencrypt/acme.json
chmod 600 /opt/n8n/letsencrypt/acme.json

echo "🚀 Starting containers..."
docker compose up -d

echo "-------------------------------------------------------"
echo "✅ Installation completed successfully!"
echo "🌐 URL: https://$DOMAIN"
echo "📂 Workdir: /opt/n8n"
echo "-------------------------------------------------------"
