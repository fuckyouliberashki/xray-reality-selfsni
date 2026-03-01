#!/bin/bash
# Перед запуском скрипта задайте переменную с именем вашего домена (опционально, для использования в ссылках; если нет домена, используйте IP в клиенте вручную)
# Замените vstavit-domen на ваш домен
# export domain=vstavit-domen
apt update
apt install curl wget qrencode jq -y


bbr=$(sysctl -a | grep net.ipv4.tcp_congestion_control)
if [ "$bbr" = "net.ipv4.tcp_congestion_control = bbr" ]; then
echo "bbr уже включен"
else
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p
echo "bbr включен"
fi


bash -c "$(curl -4 -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
[ -f /usr/local/etc/xray/.keys ] && rm /usr/local/etc/xray/.keys
touch /usr/local/etc/xray/.keys

shortsid=$(openssl rand -hex 4)
echo "shortsid: $shortsid" >> /usr/local/etc/xray/.keys

key_output=$(xray x25519)
private_key=$(echo "$key_output" | awk '/Private key:/ {print $3}')
public_key=$(echo "$key_output" | awk '/Public key:/ {print $3}')
echo "private_key: $private_key" >> /usr/local/etc/xray/.keys
echo "public_key: $public_key" >> /usr/local/etc/xray/.keys

sni="www.icloud.com"
echo "sni: $sni" >> /usr/local/etc/xray/.keys

uuid=$(xray uuid)
echo "uuid: $uuid" >> /usr/local/etc/xray/.keys
echo "domain: ${domain:-$(curl -s ifconfig.me)}" >> /usr/local/etc/xray/.keys  


touch /usr/local/etc/xray/config.json
cat << EOF > /usr/local/etc/xray/config.json
{
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
                "domain": [
                    "geosite:category-ads-all"
                ],
                "outboundTag": "block"
            }
        ]
    },
    "inbounds": [
        {
            "port": 443,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "email": "main",
                        "id": "$uuid",
                        "flow": "xtls-rprx-vision",
                        "level": 0
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                  "dest": "$sni:443",
                  "xver": 0,
                  "serverNames": ["$sni"],
                  "privateKey": "$private_key",
                  "shortIds": ["$shortsid"]
                }
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


touch /usr/local/bin/userlist
cat << 'EOF' > /usr/local/bin/userlist
#!/bin/bash
emails=($(jq -r '.inbounds[0].settings.clients[].email' "/usr/local/etc/xray/config.json"))

if [[ ${#emails[@]} -eq 0 ]]; then
    echo "Список клиентов пуст"
    exit 1
fi

echo "Список клиентов:"
for i in "${!emails[@]}"; do
    echo "$((i+1)). ${emails[$i]}"
done
EOF
chmod +x /usr/local/bin/userlist


touch /usr/local/bin/mainuser
cat << 'EOF' > /usr/local/bin/mainuser
#!/bin/bash
protocol=$(jq -r '.inbounds[0].protocol' /usr/local/etc/xray/config.json)
port=$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json)
uuid=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/uuid/ {print $2}')
domain=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/domain/ {print $2}')
public_key=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/public_key/ {print $2}')
sni=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/sni/ {print $2}')
shortsid=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/shortsid/ {print $2}')
link="$protocol://$uuid@$domain:$port?type=tcp&headerType=none&flow=xtls-rprx-vision&security=reality&pbk=$public_key&fp=chrome&sni=$sni&sid=$shortsid#mainuser"
echo ""
echo "Ссылка для подключения":
echo "$link"
echo ""
echo "QR-код:"
echo ${link} | qrencode -t ansiutf8
EOF
chmod +x /usr/local/bin/mainuser


touch /usr/local/bin/newuser
cat << 'EOF' > /usr/local/bin/newuser
#!/bin/bash
read -p "Введите имя пользователя (email): " email

    if [[ -z "$email" || "$email" == *" "* ]]; then
    echo "Имя пользователя не может быть пустым или содержать пробелы. Попробуйте снова."
    exit 1
    fi
user_json=$(jq --arg email "$email" '.inbounds[0].settings.clients[] | select(.email == $email)' /usr/local/etc/xray/config.json)

if [[ -z "$user_json" ]]; then
uuid=$(xray uuid)
jq --arg email "$email" --arg uuid "$uuid" '.inbounds[0].settings.clients += [{"email": $email, "id": $uuid, "flow": "xtls-rprx-vision"}]' /usr/local/etc/xray/config.json > tmp.json && mv tmp.json /usr/local/etc/xray/config.json
systemctl restart xray
index=$(jq --arg email "$email" '.inbounds[0].settings.clients | to_entries[] | select(.value.email == $email) | .key'  /usr/local/etc/xray/config.json)
protocol=$(jq -r '.inbounds[0].protocol' /usr/local/etc/xray/config.json)
port=$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json)
uuid=$(jq --argjson index "$index" -r '.inbounds[0].settings.clients[$index].id' /usr/local/etc/xray/config.json)
username=$(jq --argjson index "$index" -r '.inbounds[0].settings.clients[$index].email' /usr/local/etc/xray/config.json)
domain=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/domain/ {print $2}')
public_key=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/public_key/ {print $2}')
sni=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/sni/ {print $2}')
shortsid=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/shortsid/ {print $2}')
link="$protocol://$uuid@$domain:$port?type=tcp&headerType=none&flow=xtls-rprx-vision&security=reality&pbk=$public_key&fp=chrome&sni=$sni&sid=$shortsid#$username"
echo ""
echo "Ссылка для подключения":
echo "$link"
echo ""
echo "QR-код:"
echo ${link} | qrencode -t ansiutf8
else
echo "Пользователь с таким именем уже существует. Попробуйте снова." 
fi
EOF
chmod +x /usr/local/bin/newuser


touch /usr/local/bin/rmuser
cat << 'EOF' > /usr/local/bin/rmuser
#!/bin/bash
emails=($(jq -r '.inbounds[0].settings.clients[].email' "/usr/local/etc/xray/config.json"))

if [[ ${#emails[@]} -eq 0 ]]; then
    echo "Нет клиентов для удаления."
    exit 1
fi

echo "Список клиентов:"
for i in "${!emails[@]}"; do
    echo "$((i+1)). ${emails[$i]}"
done

read -p "Введите номер клиента для удаления: " choice

if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#emails[@]} )); then
    echo "Ошибка: номер должен быть от 1 до ${#emails[@]}"
    exit 1
fi

selected_email="${emails[$((choice - 1))]}"

jq --arg email "$selected_email" \
   '(.inbounds[0].settings.clients) |= map(select(.email != $email))' \
   "/usr/local/etc/xray/config.json" > tmp && mv tmp "/usr/local/etc/xray/config.json"

systemctl restart xray

echo "Клиент $selected_email удалён."
EOF
chmod +x /usr/local/bin/rmuser


touch /usr/local/bin/sharelink
cat << 'EOF' > /usr/local/bin/sharelink
#!/bin/bash
emails=($(jq -r '.inbounds[0].settings.clients[].email' /usr/local/etc/xray/config.json))

for i in "${!emails[@]}"; do
   echo "$((i + 1)). ${emails[$i]}"
done

read -p "Выберите клиента: " client

if ! [[ "$client" =~ ^[0-9]+$ ]] || (( client < 1 || client > ${#emails[@]} )); then
    echo "Ошибка: номер должен быть от 1 до ${#emails[@]}"
    exit 1
fi

selected_email="${emails[$((client - 1))]}"

index=$(jq --arg email "$selected_email" '.inbounds[0].settings.clients | to_entries[] | select(.value.email == $email) | .key'  /usr/local/etc/xray/config.json)
protocol=$(jq -r '.inbounds[0].protocol' /usr/local/etc/xray/config.json)
port=$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json) 
uuid=$(jq --argjson index "$index" -r '.inbounds[0].settings.clients[$index].id' /usr/local/etc/xray/config.json)
username=$(jq --argjson index "$index" -r '.inbounds[0].settings.clients[$index].email' /usr/local/etc/xray/config.json)
domain=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/domain/ {print $2}')
public_key=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/public_key/ {print $2}')
sni=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/sni/ {print $2}')
shortsid=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/shortsid/ {print $2}')
link="$protocol://$uuid@$domain:$port?type=tcp&headerType=none&flow=xtls-rprx-vision&security=reality&pbk=$public_key&fp=chrome&sni=$sni&sid=$shortsid#$username"
echo ""
echo "Ссылка для подключения":
echo "$link"
echo ""
echo "QR-код:"
echo ${link} | qrencode -t ansiutf8
EOF
chmod +x /usr/local/bin/sharelink

systemctl restart xray

echo "Xray-core успешно установлен"
mainuser


touch $HOME/help
cat << 'EOF' > $HOME/help

Команды для управления пользователями Xray:

    mainuser - выводит ссылку для подключения основного пользователя
    userlist - список клиентов
    newuser - создать нового пользователя
    rmuser - удалить пользователя
    sharelink - получить ссылку и QR-код для выбранного пользователя

EOF
cat $HOME/help
