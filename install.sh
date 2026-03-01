#!/bin/bash
# =============================================================================
# Установка VLESS + TCP + TLS (через WebSocket + nginx + настоящий сертификат)
# =============================================================================
# Требования:
#   - Домен уже направлен на сервер (A-запись)
#   - Порты 80 и 443 открыты
#   - Ubuntu/Debian
# =============================================================================

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}Установка VLESS + WS + TLS (без Reality)${NC}"

# 1. Обновление и установка пакетов
apt update -qq
apt install -y curl wget jq openssl certbot nginx qrencode

# 2. Включаем BBR (если не включен)
if ! sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
    echo -e "${GREEN}BBR включён${NC}"
else
    echo "BBR уже включен"
fi

# 3. Установка Xray
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# 4. Генерация ключей и параметров
mkdir -p /usr/local/etc/xray/
[ -f /usr/local/etc/xray/.keys ] && rm /usr/local/etc/xray/.keys
touch /usr/local/etc/xray/.keys

shortsid=$(openssl rand -hex 4)           # не обязателен, оставим для совместимости
uuid=$(xray uuid)

echo "uuid: $uuid" >> /usr/local/etc/xray/.keys
echo "shortsid: $shortsid" >> /usr/local/etc/xray/.keys  # просто для примера

# Запрашиваем домен
if [ -z "$domain" ]; then
    read -p "Введите ваш домен (например: vpn.mydomain.com): " domain
    if [ -z "$domain" ]; then
        echo -e "${RED}Домен обязателен для TLS!${NC}"
        exit 1
    fi
fi
echo "domain: $domain" >> /usr/local/etc/xray/.keys

# 5. Получаем сертификат Let's Encrypt (standalone режим)
echo -e "${GREEN}Получаем сертификат Let's Encrypt...${NC}"
systemctl stop nginx 2>/dev/null || true

certbot certonly --standalone -d "$domain" --non-interactive --agree-tos --email admin@$domain || {
    echo -e "${RED}Не удалось получить сертификат! Проверьте DNS и порты 80/443.${NC}"
    exit 1
}

# 6. Настраиваем nginx
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

    # Опционально: HSTS и другие заголовки
    add_header Strict-Transport-Security "max-age=31536000" always;

    location / {
        # Можно поставить фейковую страницу или 404
        return 404;
    }

    location /ray-{0,1}[a-z0-9]{8,12} {   # случайный путь, поменяй на свой
        proxy_pass http://127.0.0.1:10042;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 36000s;
        proxy_send_timeout 36000s;
    }
}
EOF

ln -sf /etc/nginx/sites-available/xray-vless /etc/nginx/sites-enabled/
nginx -t && systemctl restart nginx

# 7. Конфиг Xray (VLESS + WS)
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "dns": {
    "servers": [
      "https+local://1.1.1.1/dns-query",
      "localhost"
    ]
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "domain": ["geosite:category-ads-all"],
        "outboundTag": "block"
      }
    ]
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 10042,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$uuid",
            "email": "main",
            "level": 0
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "/ray-$(openssl rand -hex 5)"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF

# 8. Скрипты управления пользователями (адаптированы под WS + TLS)

# mainuser
cat > /usr/local/bin/mainuser <<'EOF'
#!/bin/bash
uuid=$(grep '^uuid:' /usr/local/etc/xray/.keys | cut -d' ' -f2)
domain=$(grep '^domain:' /usr/local/etc/xray/.keys | cut -d' ' -f2)
path=$(jq -r '.inbounds[0].streamSettings.wsSettings.path' /usr/local/etc/xray/config.json)

link="vless://${uuid}@${domain}:443?type=ws&path=${path}&security=tls&host=${domain}#main"
echo ""
echo "Основная ссылка:"
echo "$link"
echo ""
echo "QR:"
echo "$link" | qrencode -t ansiutf8
EOF
chmod +x /usr/local/bin/mainuser

# newuser (пример, без flow и reality)
cat > /usr/local/bin/newuser <<'EOF'
#!/bin/bash
read -p "Имя пользователя (email): " email
if [[ -z "$email" || "$email" == *" "* ]]; then
    echo "Некорректное имя"
    exit 1
fi

if jq --arg e "$email" '.inbounds[0].settings.clients[] | select(.email==$e)' /usr/local/etc/xray/config.json | grep -q .; then
    echo "Пользователь уже существует"
    exit 1
fi

newuuid=$(xray uuid)
jq --arg e "$email" --arg u "$newuuid" \
   '.inbounds[0].settings.clients += [{"id": $u, "email": $e, "level": 0}]' \
   /usr/local/etc/xray/config.json > /tmp/c.json && mv /tmp/c.json /usr/local/etc/xray/config.json

systemctl restart xray

path=$(jq -r '.inbounds[0].streamSettings.wsSettings.path' /usr/local/etc/xray/config.json)
domain=$(grep '^domain:' /usr/local/etc/xray/.keys | cut -d' ' -f2)

link="vless://${newuuid}@${domain}:443?type=ws&path=${path}&security=tls&host=${domain}#${email}"
echo ""
echo "Ссылка:"
echo "$link"
echo ""
echo "QR:"
echo "$link" | qrencode -t ansiutf8
EOF
chmod +x /usr/local/bin/newuser

# Остальные скрипты (userlist, rmuser, sharelink) — аналогично адаптируй, убирая reality-параметры (pbk, sid, flow, fp)

# 9. Перезапуск и финал
systemctl restart xray
echo -e "${GREEN}Установка завершена!${NC}"
echo "Домен: $domain"
echo "Путь WS: $(jq -r '.inbounds[0].streamSettings.wsSettings.path' /usr/local/etc/xray/config.json)"
/usr/local/bin/mainuser

cat <<'EOF' > ~/help-vless-tls
Команды:
  mainuser     - ссылка главного пользователя
  newuser      - добавить пользователя
  userlist     - список пользователей (добавь сам, если нужно)
  rmuser       - удалить (адаптируй под ws)
EOF

cat ~/help-vless-tls
