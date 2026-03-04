# Xray VLESS + WS + TLS Installer

Установка VLESS (Xray) с WebSocket + TLS через Nginx и Let's Encrypt.  
Скрипт автоматически настраивает Xray, Nginx и сертификаты.

---

## ⚡ Быстрый запуск

Просто выполните одну команду в терминале:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/fuckyouliberashki/xray-reality-selfsni/refs/heads/main/install.sh)

или через wget: bash <(wget -qO- https://raw.githubusercontent.com/fuckyouliberashki/xray-reality-selfsni/refs/heads/main/install.sh)


💡 Рекомендуется использовать bash <(curl -sSL ...) вместо curl ... | bash для безопасности.

📝 Что делает скрипт

Проверяет и освобождает порты 80 и 443
Устанавливает необходимые пакеты: curl, wget, jq, openssl, certbot, nginx, qrencode
Скачивает и устанавливает Xray последней версии
Генерирует UUID для клиента VLESS
Настраивает домен и WebSocket путь
Получает сертификат Let's Encrypt
Настраивает Nginx с HTTPS и WebSocket проксированием

Создает готовую конфигурацию Xray
Выводит ссылку VLESS и QR-код


📌 Примечания

Убедитесь, что ваш домен указывает на этот сервер через DNS.
Порты 80 и 443 должны быть свободны.
Скрипт автоматически перезапускает Nginx и Xray после установки.
Для стабильной работы рекомендуется использовать официальный Xray install script.



---

💡 **Совет:** на GitHub Pages можно добавить HTML-блок с кнопкой Copy рядом с командой:

```html
<pre>
<code id="install-cmd">bash &lt;(curl -sSL https://raw.githubusercontent.com/fuckyouliberashki/xray-reality-selfsni/refs/heads/main/install.sh)</code>
<button onclick="navigator.clipboard.writeText(document.getElementById('install-cmd').innerText)">Copy</button>
</pre>
