#!/bin/bash

# Функция для проверки, занят ли порт
check_port() {
    ss -tlpn | grep -q ":$1"
}

# Функция для получения порта от пользователя. Принимает ввод, порт по умолчанию и список уже занятых портов
get_port_input() {
    local port_name="$1"
    local default_port="$2"
    local -n excluded_ports_ref="$3"
    local selected_port

    while true; do
        if [[ -n "$default_port" ]]; then
            echo "Выберите порт для $port_name (Для применения порта по умолчанию $default_port, нажмите ENTER):"
        else
            echo "Выберите порт для $port_name:"
        fi
        
        read selected_port

        # Используем порт по умолчанию, если пользователь нажал ENTER
        if [[ -z "$selected_port" ]] && [[ -n "$default_port" ]]; then
            selected_port="$default_port"
            echo "Выбран порт по умолчанию: $selected_port"
            break
        # Проверяем, является ли ввод числом и находится ли он в допустимом диапазоне
        elif [[ "$selected_port" =~ ^[0-9]+$ ]] && (( selected_port >= 1024 && selected_port <= 65535 )); then
            # Проверяем, не занят ли порт в системе
            if check_port "$selected_port"; then
                echo "Порт $selected_port уже занят в системе. Пожалуйста, выберите другой."
            # Проверяем, не был ли порт выбран ранее для другой цели
            elif [[ " ${excluded_ports_ref[*]} " =~ " ${selected_port} " ]]; then
                echo "Порт $selected_port уже выбран для другого соединения. Пожалуйста, выберите другой."
            else
                echo "Выбран порт: $selected_port"
                break
            fi
        else
            echo "Некорректный ввод. Пожалуйста, введите число в диапазоне от 1024 до 65535."
        fi
    done
    
    # Возвращаем выбранный порт
    echo "$selected_port"
}

# Массив для хранения уже выбранных портов
declare -a selected_ports=()

# Запрашиваем порты
PORT_standart=$(get_port_input "ssh-соединения" "22" selected_ports)
selected_ports+=("$PORT_standart")

PORT_cloud=$(get_port_input "связи с облаком" "" selected_ports)
selected_ports+=("$PORT_cloud")

# Выводим подтверждение введенных значений
echo "
Стандартный порт: $PORT_standart
Порт для облака: $PORT_cloud"

# Проверяем, какой брандмауэр активен, и открываем порты
# Добавлена проверка успешности выполнения команд с `sudo`
if sudo ufw status | grep -q "Status: active"; then
    echo "UFW активен, открываем порты..."
    if ! sudo ufw allow "$PORT_standart"/tcp; then echo "Ошибка: не удалось добавить правило UFW." >&2; exit 1; fi
    if ! sudo ufw allow "$PORT_cloud"/tcp; then echo "Ошибка: не удалось добавить правило UFW." >&2; exit 1; fi
    if ! sudo ufw reload; then echo "Ошибка: не удалось перезагрузить UFW." >&2; exit 1; fi
    echo "Порты $PORT_standart и $PORT_cloud успешно открыты."
elif sudo systemctl is-active firewalld &> /dev/null; then
    echo "Firewalld активен, открываем порты..."
    if ! sudo firewall-cmd --zone=public --add-port="$PORT_standart"/tcp --permanent; then echo "Ошибка: не удалось добавить порт в Firewalld." >&2; exit 1; fi
    if ! sudo firewall-cmd --zone=public --add-port="$PORT_cloud"/tcp --permanent; then echo "Ошибка: не удалось добавить порт в Firewalld." >&2; exit 1; fi
    if ! sudo firewall-cmd --reload; then echo "Ошибка: не удалось перезагрузить Firewalld." >&2; exit 1; fi
    echo "Порты $PORT_standart и $PORT_cloud успешно открыты."
else
    echo "UFW и Firewalld не найдены или не активны. Открываем порты через Iptables..."
    
    # Проверяем, какой пакетный менеджер доступен, и устанавливаем нужный пакет
    if command -v apt &> /dev/null; then
        echo "Используем apt для установки iptables-persistent..."
        if ! sudo apt-get update && sudo apt-get install -y iptables-persistent; then
            echo "Ошибка: не удалось установить iptables-persistent." >&2; exit 1;
        fi
    elif command -v dnf &> /dev/null; then
        echo "Используем dnf для установки iptables-services..."
        if ! sudo dnf install -y iptables-services; then
            echo "Ошибка: не удалось установить iptables-services." >&2; exit 1;
        fi
    elif command -v yum &> /dev/null; then
        echo "Используем yum для установки iptables-services..."
        if ! sudo yum install -y iptables-services; then
            echo "Ошибка: не удалось установить iptables-services." >&2; exit 1;
        fi
    fi

    # Открываем порты для Iptables
    if ! sudo iptables -A INPUT -p tcp --dport "$PORT_standart" -j ACCEPT; then echo "Ошибка: не удалось добавить правило в Iptables." >&2; exit 1; fi
    if ! sudo iptables -A INPUT -p tcp --dport "$PORT_cloud" -j ACCEPT; then echo "Ошибка: не удалось добавить правило в Iptables." >&2; exit 1; fi
    
    # Сохраняем правила, только если установлена соответствующая утилита
    if command -v netfilter-persistent &> /dev/null; then
        if ! sudo netfilter-persistent save; then echo "Ошибка: не удалось сохранить правила Iptables." >&2; exit 1; fi
        echo "Правила Iptables добавлены и сохранены."
    else
        echo "Предупреждение: утилита для сохранения правил Iptables не найдена."
    fi
fi
# Настраиваем конфиг SSH (sshd_config)
echo "Настраиваем конфигурационный файл sshd_config..."
SSHD_CONFIG_FILE="/etc/ssh/sshd_config"

# Использование более надёжной замены, чтобы избежать дублирования строк
# Заменяем Port 22 или добавляем новую строку, если её нет
if grep -q "^#Port 22" "$SSHD_CONFIG_FILE"; then
    sudo sed -i "s/^#Port 22/Port $PORT_standart/" "$SSHD_CONFIG_FILE"
elif ! grep -q "^Port" "$SSHD_CONFIG_FILE"; then
    echo "Port $PORT_standart" | sudo tee -a "$SSHD_CONFIG_FILE" > /dev/null
fi

# Заменяем или добавляем GatewayPorts
if grep -q "^#GatewayPorts no" "$SSHD_CONFIG_FILE"; then
    sudo sed -i "s/^#GatewayPorts no/GatewayPorts yes/" "$SSHD_CONFIG_FILE"
elif ! grep -q "^GatewayPorts" "$SSHD_CONFIG_FILE"; then
    echo "GatewayPorts yes" | sudo tee -a "$SSHD_CONFIG_FILE" > /dev/null
fi

# Настройка доступа для root
while true; do
    echo "Хотите запретить вход root по паролю? (y/n)"
    read -r ROOT_LOGIN_CHOICE
    
    ROOT_LOGIN_CHOICE=$(echo "$ROOT_LOGIN_CHOICE" | tr '[:upper:]' '[:lower:]')

    if [[ "$ROOT_LOGIN_CHOICE" == "y" ]]; then
        sudo sed -i -e 's/^[#]*PermitRootLogin yes/PermitRootLogin prohibit-password/' "$SSHD_CONFIG_FILE"
        echo "Вход для root по паролю запрещен."
        break
    elif [[ "$ROOT_LOGIN_CHOICE" == "n" ]]; then
        echo "Вход для root по паролю не будет изменен."
        break
    else
        echo "Неверный символ. Пожалуйста, введите 'y' или 'n'."
    fi
done

echo "Конфигурация SSH-сервера обновлена. Перезапускаем службу SSH..."
if ! sudo systemctl restart sshd; then echo "Ошибка: не удалось перезапустить службу sshd." >&2; exit 1; fi
echo "Настройка SSH-сервера завершена."
