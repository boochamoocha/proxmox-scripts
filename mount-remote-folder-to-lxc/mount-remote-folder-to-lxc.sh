#!/bin/bash

set -euo pipefail

# Проверка интерактивного режима
if [[ ! -t 0 ]] && [[ ! -c /dev/tty ]]; then
    echo "❌ Ошибка: Скрипт требует интерактивного ввода"
    echo ""
    echo "🔧 Решение:"
    echo "1. Скачайте скрипт локально:"
    echo "   wget https://raw.githubusercontent.com/boochamoocha/proxmox-scripts/main/mount-remote-folder-to-lxc/mount-remote-folder-to-lxc.sh"
    echo ""
    echo "2. Сделайте исполняемым и запустите:"
    echo "   chmod +x mount-remote-folder-to-lxc.sh"
    echo "   ./mount-remote-folder-to-lxc.sh"
    exit 1
fi

# Функция безопасного чтения с TTY
safe_read() {
    if [[ -t 0 ]]; then
        read "$@"
    else
        read "$@" < /dev/tty
    fi
}

# Функция валидации пустых значений
validate_input() {
    local input="$1"
    local field_name="$2"
    if [[ -z "$input" ]]; then
        echo "❌ Ошибка: $field_name не может быть пустым"
        exit 1
    fi
}

# Функция очистки пробелов
trim_input() {
    local input="$1"
    echo "$input" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# Функция проверки существования контейнера
check_container_exists() {
    local ctid="$1"
    if ! pct status "$ctid" >/dev/null 2>&1; then
        echo "❌ Ошибка: Контейнер $ctid не существует"
        exit 1
    fi
}

echo "=== 🧩 Конфигурация монтирования в Proxmox LXC ==="

# Ввод ID контейнера с валидацией
while true; do
    safe_read -p "Введите ID контейнера: " CTID
    validate_input "$CTID" "ID контейнера"
    if [[ "$CTID" =~ ^[0-9]+$ ]]; then
        check_container_exists "$CTID"
        break
    else
        echo "❌ ID контейнера должен быть числом"
    fi
done

# Выбор режима работы
echo ""
echo "Выберите режим работы:"
echo "1) host-managed (рекомендуемый) - монтирование на хосте + bind mount"
echo "2) container-direct - прямое монтирование в контейнере"
while true; do
    safe_read -p "Режим (1-2): " MODE_CHOICE
    case "$MODE_CHOICE" in
        1)
            MODE="host-managed"
            break
            ;;
        2)
            MODE="container-direct"
            break
            ;;
        *)
            echo "❌ Выберите 1 или 2"
            ;;
    esac
done

# Выбор типа источника данных
echo ""
echo "💡 Выберите тип источника данных:"
echo "1) nfs - сетевая NFS шара (будет смонтирована на хосте)"
echo "2) cifs - сетевая CIFS/SMB шара (будет смонтирована на хосте + учетные данные)"
echo "3) mounted - уже доступная директория на хосте (прямой bind mount)"
while true; do
    safe_read -p "Тип источника (1-3): " SHARE_TYPE_CHOICE
    SHARE_TYPE_CHOICE=$(trim_input "$SHARE_TYPE_CHOICE")
    case "$SHARE_TYPE_CHOICE" in
        1)
            SHARE_TYPE="nfs"
            break
            ;;
        2)
            SHARE_TYPE="cifs"
            break
            ;;
        3)
            SHARE_TYPE="mounted"
            break
            ;;
        *)
            echo "❌ Выберите 1, 2 или 3"
            ;;
    esac
done

# Ввод источника в зависимости от типа
case "$SHARE_TYPE" in
  nfs)
    echo "📌 Пример адреса источника NFS: 192.168.1.10:/media/nfs"
    while true; do
        safe_read -p "Введите адрес источника NFS: " RAW_SHARE_SRC
        validate_input "$RAW_SHARE_SRC" "Адрес источника NFS"
        SHARE_SRC="$RAW_SHARE_SRC"
        break
    done
    ;;
  cifs)
    echo "📌 Пример адреса источника CIFS: 192.168.1.10/Movies"
    while true; do
        safe_read -p "Введите адрес источника CIFS (без //): " RAW_SHARE_SRC
        validate_input "$RAW_SHARE_SRC" "Адрес источника CIFS"
        if [[ "$RAW_SHARE_SRC" != //* ]]; then
            SHARE_SRC="//${RAW_SHARE_SRC}"
        else
            SHARE_SRC="$RAW_SHARE_SRC"
        fi
        break
    done
    ;;
  mounted)
    echo "📌 Пример уже доступной директории: /mnt/dsm/data"
    while true; do
        safe_read -p "Введите путь к директории на хосте: " SHARE_SRC
        validate_input "$SHARE_SRC" "Путь к директории на хосте"
        if [[ ! -d "$SHARE_SRC" ]]; then
            echo "❌ Директория $SHARE_SRC не существует"
        else
            break
        fi
    done
    ;;
esac

# Ввод пути на хосте (только для NFS/CIFS в host-managed режиме)
if [[ "$MODE" == "host-managed" && "$SHARE_TYPE" != "mounted" ]]; then
    while true; do
        safe_read -p "Введите путь монтирования на хосте Proxmox (например, /mnt/share): " HOST_MOUNT
        validate_input "$HOST_MOUNT" "Путь монтирования на хосте"
        break
    done
fi

# Ввод пути в контейнере
while true; do
    safe_read -p "Введите путь в контейнере (например, /mnt/media): " CT_MOUNT
    validate_input "$CT_MOUNT" "Путь в контейнере"
    break
done

# Выбор уровня доступа
echo ""
echo "Выберите уровень доступа:"
echo "1) Read-Write (rw) - чтение и запись"
echo "2) Read-Only (ro) - только чтение"
while true; do
    safe_read -p "Доступ (1-2): " ACCESS_CHOICE
    case "$ACCESS_CHOICE" in
        1)
            ACCESS_MODE="rw"
            RO_PARAM=""
            break
            ;;
        2)
            ACCESS_MODE="ro"
            RO_PARAM=",ro=1"
            break
            ;;
        *)
            echo "❌ Выберите 1 или 2"
            ;;
    esac
done

# Получение учетных данных для CIFS (если необходимо)
if [[ "$SHARE_TYPE" == "cifs" ]]; then
    while true; do
        safe_read -p "Введите имя пользователя CIFS: " CIFS_USER
        validate_input "$CIFS_USER" "Имя пользователя CIFS"
        break
    done
    while true; do
        safe_read -s -p "Введите пароль CIFS: " CIFS_PASS
        echo
        validate_input "$CIFS_PASS" "Пароль CIFS"
        break
    done
fi

echo ""
echo "=== 🔧 Выполнение конфигурации ==="

# === HOST-MANAGED РЕЖИМ ===
if [[ "$MODE" == "host-managed" ]]; then
    echo "📋 Режим: Host-managed"
    
    # Создание папки на хосте (только для сетевых шар)
    if [[ "$SHARE_TYPE" != "mounted" ]]; then
        echo "📁 Создание директории на хосте: $HOST_MOUNT"
        mkdir -p "$HOST_MOUNT"
    fi

    # Монтирование на хосте (для network shares)
    if [[ "$SHARE_TYPE" != "mounted" ]]; then
        # Установка зависимостей
        echo "📦 Установка зависимостей..."
        if [[ "$SHARE_TYPE" == "nfs" ]]; then
            apt-get update -qq && apt-get install -y nfs-common
            echo "🔗 Монтирование NFS на хосте..."
            mount -t nfs "$SHARE_SRC" "$HOST_MOUNT"
        elif [[ "$SHARE_TYPE" == "cifs" ]]; then
            apt-get update -qq && apt-get install -y cifs-utils
            echo "🔗 Монтирование CIFS на хосте..."
            mount -t cifs "$SHARE_SRC" "$HOST_MOUNT" -o username="$CIFS_USER",password="$CIFS_PASS",vers=3.0
        fi

        # Проверка монтирования
        if mount | grep -q "$HOST_MOUNT"; then
            echo "✅ Смонтировано успешно на хосте: $HOST_MOUNT"
        else
            echo "❌ Ошибка монтирования на хосте. Подробности:"
            dmesg | tail -n 10
            exit 1
        fi
    else
        # Для mounted - просто используем существующую директорию
        HOST_MOUNT="$SHARE_SRC"
        echo "📂 Использование уже доступной директории: $HOST_MOUNT"
    fi

    # === Найдём свободный mpX ===
    CONF_PATH="/etc/pve/lxc/$CTID.conf"
    MP_INDEX=""
    for i in $(seq 0 31); do
        MP_TEST="mp$i"
        if ! grep -q "^$MP_TEST:" "$CONF_PATH"; then
            MP_INDEX="$MP_TEST"
            echo "📎 Автоматически выбран индекс точки монтирования: $MP_INDEX"
            break
        fi
    done

    if [[ -z "$MP_INDEX" ]]; then
        echo "❌ Не удалось найти свободный mpX (все mp0..mp31 заняты)"
        exit 1
    fi

    # Добавление в конфиг LXC
    if grep -q "$CT_MOUNT" "$CONF_PATH"; then
        echo "⚠️ Точка монтирования уже присутствует в конфиге"
    else
        echo "$MP_INDEX: $HOST_MOUNT,mp=$CT_MOUNT$RO_PARAM" >> "$CONF_PATH"
        echo "✅ Добавлено в конфигурацию LXC: $CONF_PATH"
    fi

# === CONTAINER-DIRECT РЕЖИМ ===
elif [[ "$MODE" == "container-direct" ]]; then
    echo "📋 Режим: Container-direct"
    
    if [[ "$SHARE_TYPE" == "mounted" ]]; then
        echo "❌ Container-direct режим не поддерживается для уже смонтированных директорий"
        echo "Существующие директории хоста могут быть доступны только через host-managed режим"
        exit 1
    fi

    # Установка пакетов в контейнер
    echo "📦 Установка зависимостей в контейнер..."
    if [[ "$SHARE_TYPE" == "nfs" ]]; then
        pct exec "$CTID" -- bash -c "apt-get update -qq && apt-get install -y nfs-common"
    elif [[ "$SHARE_TYPE" == "cifs" ]]; then
        pct exec "$CTID" -- bash -c "apt-get update -qq && apt-get install -y cifs-utils"
    fi

    # Создание директории в контейнере
    echo "📁 Создание директории в контейнере: $CT_MOUNT"
    pct exec "$CTID" -- mkdir -p "$CT_MOUNT"

    # Настройка автомонтирования в /etc/fstab контейнера
    echo "📝 Настройка автомонтирования в контейнере..."
    
    if [[ "$SHARE_TYPE" == "nfs" ]]; then
        FSTAB_ENTRY="$SHARE_SRC $CT_MOUNT nfs defaults,_netdev"
        if [[ "$ACCESS_MODE" == "ro" ]]; then
            FSTAB_ENTRY="$FSTAB_ENTRY,ro"
        fi
        FSTAB_ENTRY="$FSTAB_ENTRY 0 0"
    elif [[ "$SHARE_TYPE" == "cifs" ]]; then
        # Создание файла с учетными данными
        CREDS_FILE="/etc/cifs-credentials"
        pct exec "$CTID" -- bash -c "echo 'username=$CIFS_USER' > $CREDS_FILE"
        pct exec "$CTID" -- bash -c "echo 'password=$CIFS_PASS' >> $CREDS_FILE"
        pct exec "$CTID" -- chmod 600 "$CREDS_FILE"
        
        FSTAB_ENTRY="$SHARE_SRC $CT_MOUNT cifs credentials=$CREDS_FILE,vers=3.0,_netdev"
        if [[ "$ACCESS_MODE" == "ro" ]]; then
            FSTAB_ENTRY="$FSTAB_ENTRY,ro"
        fi
        FSTAB_ENTRY="$FSTAB_ENTRY 0 0"
    fi

    # Добавление записи в fstab, если её ещё нет
    if pct exec "$CTID" -- grep -q "$CT_MOUNT" /etc/fstab; then
        echo "⚠️ Запись в fstab уже существует"
    else
        pct exec "$CTID" -- bash -c "echo '$FSTAB_ENTRY' >> /etc/fstab"
        echo "✅ Добавлена запись в /etc/fstab контейнера"
    fi

    # Монтирование немедленно
    echo "🔗 Монтирование в контейнере..."
    if pct exec "$CTID" -- mount "$CT_MOUNT"; then
        echo "✅ Смонтировано успешно в контейнере"
    else
        echo "❌ Ошибка монтирования в контейнере"
        exit 1
    fi
fi

# === ОБЩИЕ ФИНАЛЬНЫЕ ШАГИ ===

# Создание каталога внутри контейнера (если ещё не создан)
echo "📁 Убеждаемся, что каталог создан в контейнере: $CT_MOUNT"
pct exec "$CTID" -- mkdir -p "$CT_MOUNT"

# Перезапуск контейнера для применения конфигурации
if [[ "$MODE" == "host-managed" ]]; then
    echo "🔄 Перезапуск контейнера для применения bind mount..."
    pct reboot "$CTID"
    echo "⏳ Ожидание запуска контейнера..."
    sleep 5
    
    # Ожидание готовности контейнера
    while ! pct status "$CTID" | grep -q "running"; do
        echo "⏳ Ожидание запуска контейнера..."
        sleep 2
    done
fi

# Проверка результата
echo ""
echo "=== ✅ Проверка результата ==="
echo "🔍 Проверка монтирования в контейнере..."

if pct exec "$CTID" -- test -d "$CT_MOUNT"; then
    echo "✅ Директория $CT_MOUNT существует в контейнере"
    
    echo "📂 Содержимое $CT_MOUNT в контейнере:"
    if pct exec "$CTID" -- ls -la "$CT_MOUNT" 2>/dev/null; then
        echo "✅ Монтирование успешно завершено!"
        echo ""
        echo "📋 Сводка конфигурации:"
        echo "   Контейнер: $CTID"
        echo "   Режим: $MODE"
        echo "   Тип: $SHARE_TYPE"
        if [[ "$SHARE_TYPE" != "mounted" ]]; then
            echo "   Источник: $SHARE_SRC"
        else
            echo "   Директория хоста: $SHARE_SRC"
        fi
        echo "   Путь в контейнере: $CT_MOUNT"
        echo "   Доступ: $ACCESS_MODE"
        if [[ "$MODE" == "host-managed" && "$SHARE_TYPE" != "mounted" ]]; then
            echo "   Путь на хосте: $HOST_MOUNT"
        fi
    else
        echo "⚠️ Директория пуста или недоступна"
        echo "Это может быть нормально для новой/пустой шары"
    fi
else
    echo "❌ Директория $CT_MOUNT не найдена в контейнере"
    exit 1
fi
