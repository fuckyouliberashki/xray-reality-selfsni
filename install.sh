#!/bin/bash
# =============================================================================
# Установка VLESS + WebSocket + TLS (nginx + Let's Encrypt)
# С принудительным освобождением портов 80, 443, 8080, 8443 в начале
# =============================================================================
# Требования:
#   - Ubuntu/Debian
#   - Домен уже направлен на IP сервера (A-запись)
#   - Порты 80 и 443 доступны извне
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Установка VLESS + WS + TLS (nginx + certbot) ===${NC}"

# ────────────────────────────────────────────────
# 0. Агрессивное освобождение портов 80,443,8080,8443
# ────────────────────────────────────────────────
echo -e "\n${YELLOW}Принудительно освобождаем порты 80, 443, 8080, 8443...${NC}"

PORTS="80 443 8080 8443"

for port in $PORTS; do
    if sudo ss -ltn | grep -q ":$port "; then
        echo -e "  Порт ${YELLOW}$port${NC} занят → убиваем процессы..."

        # Вариант 1 — fuser (самый удобный и быстрый)
        sudo fuser -k -n tcp $port 2>/dev/null || true

        # Вариант 2 — если fuser не справился, добиваем через lsof + kill -9
        PIDS=$(sudo lsof -t -iTCP:$port -sTCP:LISTEN 2>/dev/null)
        if [ -n "$PIDS" ]; then
            echo "  fuser не справился → добиваем через kill -9"
            sudo kill -9 $PIDS 2>/dev/null || true
        fi

        # Даём 1–2 секунды на завершение
        sleep 1.5

        # Проверка
        if sudo ss -ltn | grep -q ":$port "; then
            echo -e "  ${RED}Внимание! Порт $port всё ещё занят после попытки убийства${NC}"
        else
            echo -e "  ${GREEN}Порт $port освобождён${NC}"
        fi
    else
        echo -e "  Порт ${GREEN}$port${NC} свободен"
    fi
done

# ────────────────────────────────────────────────
# 1. Установка необходимых пакетов
# ────────────────────────────────────────────────
echo -e "\n${GREEN}Установка пакетов...${NC}"
apt update -qq
DEBIAN_FRONTEND=noninteractive apt install -y \
    curl wget jq openssl certbot nginx qrencode ca-certificates

# ────────────────────────────────────────────────
# 2. BBR (если не включён)
# ────────────────────────────────────────────────
if ! sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
    echo "net.core.default_qdisc=fq" | sudo tee -a /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" | sudo tee -a /etc/sysctl.conf
    sudo sysctl -p
    echo -e "${GREEN}BBR включён${NC}"
else
    echo "BBR уже активен"
fi

# ────────────────────────────────────────────────
# 3. Установка Xray
# ────────────────────────────────────────────────
echo -e "\n${GREEN}Установка Xray...${NC}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# ────────────────────────────────────────────────
# 4. Генерация ключей и запрос домена
# ────────────────────────────────────────────────
mkdir -p /usr/local/etc/xray
rm -f /usr/local/etc/xray/.keys
touch /usr/local/etc/xray/.keys

uuid=$(xray uuid)
echo "uuid: $uuid" >> /usr/local/etc/xray/.keys

while true; do
    read -p "Введите ваш домен (пример: vpn.example.com): " domain
    if [[ -z "$domain" ]]; then
        echo -e "${RED}Домен обязателен!${NC}"
    else
        break
    fi
done

echo "domain: $domain" >> /usr/local/etc/xray/.keys

# Случайный путь для WebSocket (можно поменять)
ws_path="/$(openssl rand -hex 5)-$(openssl rand -hex 3)"

echo "ws_path: $ws_path" >> /usr/local/etc/xray/.keys

# ────────────────────────────────────────────────
# 5. Получение сертификата Let's Encrypt
# ────────────────────────────────────────────────
echo -e "\n${GREEN}Получаем сертификат Let's Encrypt...${NC}"

sudo systemctl stop nginx 2>/dev/null || true

if ! sudo certbot certonly \
    --standalone \
    --non-interactive \
    --agree-tos \
    --email "admin@${domain}" \
    -d "${domain}" \
    --preferred-challenges http; then

    echo -e "${RED}Не удалось получить сертификат!${NC}"
    echo "Возможные причины:"
    echo "  • DNS A-запись домена не указывает на этот сервер"
    echo "  • Порт 80 закрыт в firewall / провайдером"
    echo "  • Rate-limit Let's Encrypt (подождите 1 час)"
    echo ""
    echo "Диагностика:"
    echo "  sudo certbot certonly --standalone -d $domain --dry-run"
    exit 1
fi

if [[ ! -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]]; then
    echo -e "${RED}Сертификаты не найдены после certbot!${NC}"
    exit 1
fi

echo -e "${GREEN}Сертификат получен${NC}"

# ────────────────────────────────────────────────
# 6. Конфигурация nginx
# ────────────────────────────────────────────────
echo -e "\n${GREEN}Настраиваем nginx...${NC}"

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
    ssl_ciphers HIGH:!aNULL:!MD5;

    location / {
        return 404;
    }

    location $ws_path {
        proxy_pass http://127.0.0.1:10042;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
EOF

ln -sf /etc/nginx/sites-available/xray-vless /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

nginx -t && sudo systemctl restart nginx

# ────────────────────────────────────────────────
# 7. Конфиг Xray (VLESS + WS)
# ────────────────────────────────────────────────
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
          "path": "$ws_path"
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

# ────────────────────────────────────────────────
# 8. Полезные скрипты
# ────────────────────────────────────────────────

cat > /usr/local/bin/vless-main <<'EOF'
#!/bin/bash
uuid=$(grep '^uuid:' /usr/local/etc/xray/.keys | cut -d' ' -f2)
domain=$(grep '^domain:' /usr/local/etc/xray/.keys | cut -d' ' -f2)
path=$(grep '^ws_path:' /usr/local/etc/xray/.keys | cut -d' ' -f2)

link="vless://${uuid}@${domain}:443?type=ws&path=${path}&security=tls&host=${domain}&sni=${domain}#main"
echo -e "\nОсновная ссылка:"
echo "$link"
echo -e "\nQR-код:"
echo "$link" | qrencode -t ansiutf8
EOF
chmod +x /usr/local/bin/vless-main

# Перезапуск
systemctl restart xray
systemctl restart nginx

echo -e "\n${GREEN}Установка завершена!${NC}"
echo "Домен          : $domain"
echo "Путь WebSocket : $ws_path"
echo ""
/usr/local/bin/vless-main

cat <<'EOF' > ~/vless-help
Команды:
  vless-main       → показать ссылку и QR основного пользователя
  xray version     → версия Xray
  systemctl status xray
  systemctl status nginx
  sudo certbot renew --dry-run   → проверить автопродление сертификата
EOF

cat ~/vless-help
