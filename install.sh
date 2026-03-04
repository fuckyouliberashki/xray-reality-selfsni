#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Установка VLESS + WS + TLS (nginx + certbot) ===${NC}"

echo -e "\n${YELLOW}Освобождаем порты 80 и 443...${NC}"
for port in 80 443; do
    sudo fuser -k -n tcp $port 2>/dev/null || true
done

echo -e "\n${GREEN}Установка пакетов...${NC}"
apt update -qq
DEBIAN_FRONTEND=noninteractive apt install -y \
    curl wget jq openssl certbot nginx qrencode ca-certificates lsof

echo -e "\n${GREEN}Установка Xray...${NC}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

mkdir -p /usr/local/etc/xray
rm -f /usr/local/etc/xray/.keys
touch /usr/local/etc/xray/.keys

uuid=$(xray uuid)
echo "uuid: $uuid" >> /usr/local/etc/xray/.keys

# ===== ДОМЕН =====
while true; do
    read -p "Введите домен (пример: vpn.example.com): " domain
    if [[ -z "$domain" ]]; then
        echo -e "${RED}Домен обязателен!${NC}"
        continue
    fi

    if [[ ! "$domain" =~ ^[A-Za-z0-9.-]+$ ]]; then
        echo -e "${RED}Некорректный формат домена!${NC}"
        continue
    fi
    break
done

echo "domain: $domain" >> /usr/local/etc/xray/.keys

# ===== ПРОВЕРКА DNS =====
SERVER_IP=$(curl -s ifconfig.me)
DOMAIN_IP=$(dig +short $domain | tail -n1)

if [[ "$SERVER_IP" != "$DOMAIN_IP" ]]; then
    echo -e "${RED}DNS не указывает на этот сервер!${NC}"
    echo "IP сервера : $SERVER_IP"
    echo "IP домена  : $DOMAIN_IP"
    exit 1
fi

ws_path="/$(openssl rand -hex 5)"
echo "ws_path: $ws_path" >> /usr/local/etc/xray/.keys

echo -e "\n${GREEN}Получаем сертификат Let's Encrypt...${NC}"

sudo systemctl stop nginx 2>/dev/null || true

certbot certonly \
    --standalone \
    --non-interactive \
    --agree-tos \
    --email "admin@$domain" \
    -d "$domain"

if [[ ! -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]]; then
    echo -e "${RED}Сертификат не получен!${NC}"
    exit 1
fi

echo -e "${GREEN}Сертификат получен${NC}"

# ===== NGINX =====
cat > /etc/nginx/sites-available/xray-vless <<EOF
server {
    listen 80;
    server_name $domain;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $domain;

    ssl_certificate     /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        return 404;
    }

    location $ws_path {
        proxy_pass http://127.0.0.1:10042;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOF

ln -sf /etc/nginx/sites-available/xray-vless /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

nginx -t
systemctl restart nginx

# ===== XRAY CONFIG =====
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 10042,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$uuid"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "$ws_path"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

mkdir -p /var/log/xray

# Проверка JSON
jq . /usr/local/etc/xray/config.json >/dev/null

systemctl restart xray

echo -e "\n${GREEN}Установка завершена!${NC}"
echo "Домен : $domain"
echo "UUID  : $uuid"
echo "Path  : $ws_path"

echo -e "\nСсылка:"
echo "vless://${uuid}@${domain}:443?type=ws&path=${ws_path}&security=tls&sni=${domain}#main"
