#!/bin/bash

# --- Шаг 1: Создание пользователя для облачного сервиса ---
echo "--- Шаг 1: Задаем переменные ---"

# Запрашиваем имя пользователя у пользователя
read -p "Введите имя нового пользователя для облачного сервиса: " USER_NAME
read -p "Введите имя пользователя на VPS: " REMOTE_USER
read -p "Введите IP-адрес удаленного сервера (vps_ip): " REMOTE_IP
read -p "Введите SSH-порт удаленного сервера (Если вы его меняли в прошлом скрипте). Чтобы оставить порт по умолчанию 22, просто нажмите ENTER): " SSH_COPY_PORT
read -p "Введите порт для облака (Из предыдущего скрипта):" REMOTE_PORT

# Проверяем, существует ли пользователь, чтобы избежать ошибки
if id "$USER_NAME" &>/dev/null; then
    echo "Пользователь '$USER_NAME' уже существует. Пропускаем этот шаг."
else
    if sudo adduser "$USER_NAME"; then
        echo "Пользователь '$USER_NAME' успешно создан."
    else
        echo "Ошибка: не удалось создать пользователя '$USER_NAME'." >&2
        exit 1
    fi
fi

# --- Шаг 2: Генерация SSH-ключа и копирование на удаленный сервер ---
#ВОТ ТУТ ВОЗМОЖНО ВЫПОЛНЕНИЕ ОТ ПРОСТОГО ПОЛЬЗАКА НЕ ПРОКАТИТ $USER_NAME
echo "--- Шаг 2: Настройка SSH-ключа ---"
# Проверяем, существует ли ключ, чтобы избежать перезаписи
if [ -f "/home/$USER_NAME/.ssh/id_ed25519" ]; then
    echo "SSH-ключ уже существует для пользователя '$USER_NAME'. Пропускаем генерацию."
else
    echo "Генерация нового SSH-ключа..."
    # Генерируем ключ ed25519 для пользователя
    sudo -u "$USER_NAME" ssh-keygen -t ed25519 -C "reverse_ssh_tunnel" -f "/home/$USER_NAME/.ssh/id_ed25519" -q -N ""
    echo "Ключ успешно сгенерирован."
fi

# Используем порт по умолчанию, если пользователь нажал ENTER
if [ -z "$SSH_COPY_PORT" ]; then
    SSH_COPY_PORT="22"
fi

echo "Копируем ключ на удаленный сервер. Пожалуйста, введите пароль для пользователя $REMOTE_USER@$REMOTE_IP:"
# Копируем публичный ключ на удаленный сервер
if ! sudo -u "$USER_NAME" ssh-copy-id -p "$SSH_COPY_PORT" "$REMOTE_USER@$REMOTE_IP"; then
    echo "Ошибка: не удалось скопировать ключ. Проверьте данные и попробуйте снова." >&2
    exit 1
fi
echo "Ключ успешно скопирован."

# --- Шаг 3: Установка autossh ---
echo "--- Шаг 3: Установка autossh ---"

# Проверяем наличие autossh
if command -v autossh &>/dev/null; then
    echo "autossh уже установлен. Пропускаем установку."
else
    # Проверяем, какой пакетный менеджер доступен
    if command -v apt &>/dev/null; then
        echo "Используем apt для установки autossh..."
        if ! sudo apt update && sudo apt install -y autossh; then
            echo "Ошибка: не удалось установить autossh." >&2
            exit 1
        fi
    elif command -v dnf &>/dev/null; then
        echo "Используем dnf для установки autossh..."
        if ! sudo dnf install -y autossh; then
            echo "Ошибка: не удалось установить autossh." >&2
            exit 1
        fi
    elif command -v yum &>/dev/null; then
        echo "Используем yum для установки autossh..."
        if ! sudo yum install -y autossh; then
            echo "Ошибка: не удалось установить autossh." >&2
            exit 1
        fi
    else
        echo "Ошибка: не найден подходящий пакетный менеджер для установки autossh." >&2
        exit 1
    fi
fi


# --- Шаг 4: Создание скрипта запуска туннеля ---
echo "--- Шаг 4: Создание скрипта запуска туннеля ---"

TUNNEL_SCRIPT="/usr/local/bin/reverse-ssh-tunnel.sh"

echo "Создаем скрипт запуска $TUNNEL_SCRIPT..."
# Создаем скрипт с помощью tee, чтобы избежать проблем с правами доступа
cat <<EOF | sudo tee "$TUNNEL_SCRIPT" >/dev/null
#!/bin/bash
### Этот скрипт запускает autossh для обратного туннеля ###
AUTOSSH_GATETIME=0

# Путь к вашему приватному SSH-ключу
SSH_KEY="/home/${USER_NAME}/.ssh/id_ed25519"

# Параметры подключения
USER="${REMOTE_USER}"
VPS="${REMOTE_IP}"
# Удаленный порт, на который будет пробрасываться трафик
REMOTE_PORT="${REMOTE_PORT}"
# Локальный порт, с которого берется трафик (в данном случае, SSH-порт)
LOCAL_PORT="22"
# Порт на VPS, который слушает autossh
LISTEN_PORT="${SSH_COPY_PORT}"

# Добавлены опции для поддержания SSH-соединения активным
# -o ServerAliveInterval=30: Отправляет keep-alive пакет каждые 30 секунд.
# -o ServerAliveCountMax=3: Разрывает соединение, если 3 пакета подряд не получили ответа.
KEEPALIVE_OPTS="-o ServerAliveInterval=30 -o ServerAliveCountMax=3"

# Команда для установки туннеля
/usr/bin/autossh -M 0 -N -R \${REMOTE_PORT}:localhost:\${LOCAL_PORT} \
    -p "\${LISTEN_PORT}" -i "\${SSH_KEY}" \
    \${KEEPALIVE_OPTS} "\${USER}"@"\${VPS}"
EOF

# Делаем скрипт исполняемым
if ! sudo chmod +x "$TUNNEL_SCRIPT"; then
    echo "Ошибка: не удалось сделать скрипт исполняемым." >&2
    exit 1
fi

# --- Шаг 5: Создание службы автозапуска скрипта ---
echo "--- Шаг 5: Создание службы автозапуска ---"

TUNNEL_SERVICE="/etc/systemd/system/reverse-ssh-tunnel.service"

echo "Создаем файл службы: $TUNNEL_SERVICE"
# Создаем файл службы с помощью tee
cat <<EOF | sudo tee "$TUNNEL_SERVICE" >/dev/null
[Unit]
Description=Reverse SSH Tunnel Service
After=network-online.target
Wants=network-online.target

[Service]
User=${USER_NAME}
ExecStart=${TUNNEL_SCRIPT}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Активируем и запускаем службу
echo "Активируем и запускаем службу..."
if ! sudo systemctl daemon-reload; then echo "Ошибка: не удалось перезагрузить systemd." >&2; exit 1; fi
if ! sudo systemctl enable --now reverse-ssh-tunnel.service; then echo "Ошибка: не удалось активировать службу." >&2; exit 1; fi
echo "Облачный сервис запущен и будет автоматически запускаться при старте системы."