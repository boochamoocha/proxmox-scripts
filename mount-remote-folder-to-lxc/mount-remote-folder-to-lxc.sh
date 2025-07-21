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

# Функция определения типа контейнера (privileged/unprivileged)
get_container_type() {
    local ctid="$1"
    local conf_path="/etc/pve/lxc/$ctid.conf"
    
    if [[ ! -f "$conf_path" ]]; then
        echo "❌ Не найден конфигурационный файл: $conf_path"
        exit 1
    fi
    
    # Проверка наличия unprivileged: 1 в конфиге
    if grep -q "^unprivileged:[[:space:]]*1" "$conf_path"; then
        echo "unprivileged"
    else
        echo "privileged"
    fi
}

# Функция получения UID/GID mapping для unprivileged контейнеров
get_lxc_mapping() {
    local ctid="$1"
    local conf_path="/etc/pve/lxc/$ctid.conf"
    
    # Ищем первую запись lxc.idmap для uid (поддерживаем оба формата: с : и без)
    local uid_line=$(grep -E "^lxc\.idmap[[:space:]]*[:=][[:space:]]*u[[:space:]]+0[[:space:]]+" "$conf_path" | head -n1)
    local gid_line=$(grep -E "^lxc\.idmap[[:space:]]*[:=][[:space:]]*g[[:space:]]+0[[:space:]]+" "$conf_path" | head -n1)
    
    if [[ -n "$uid_line" && -n "$gid_line" ]]; then
        # Извлекаем UID и GID из строк вида "lxc.idmap = u 0 100000 65536" или "lxc.idmap: u 0 100000 65536"
        local uid=$(echo "$uid_line" | awk '{print $4}')
        local gid=$(echo "$gid_line" | awk '{print $4}')
        echo "$uid:$gid"
    else
        # Если не найдены специфичные mapping для UID 0, проверим любые uid mapping
        uid_line=$(grep -E "^lxc\.idmap[[:space:]]*[:=][[:space:]]*u[[:space:]]+" "$conf_path" | head -n1)
        gid_line=$(grep -E "^lxc\.idmap[[:space:]]*[:=][[:space:]]*g[[:space:]]+" "$conf_path" | head -n1)
        
        if [[ -n "$uid_line" && -n "$gid_line" ]]; then
            # Для любых mapping берем host_uid (третье поле)
            local uid=$(echo "$uid_line" | awk '{print $4}')
            local gid=$(echo "$gid_line" | awk '{print $4}')
            echo "$uid:$gid"
        else
            echo "0:0"
        fi
    fi
}

# Функция настройки прав доступа для LXC user namespace
setup_lxc_permissions() {
    local mount_path="$1"
    local lxc_mapping="$2"
    local access_mode="$3"
    
    local uid=$(echo "$lxc_mapping" | cut -d: -f1)
    local gid=$(echo "$lxc_mapping" | cut -d: -f2)
    
    echo "🔧 Настройка владельца директории: $uid:$gid"
    chown -R "$uid:$gid" "$mount_path" || {
        echo "⚠️ Не удалось изменить владельца. Возможно, это нормально для некоторых типов файловых систем."
    }
    
    if [[ "$access_mode" == "rw" ]]; then
        echo "🔧 Настройка прав для записи..."
        chmod -R u+w "$mount_path" 2>/dev/null || {
            echo "⚠️ Не удалось изменить права доступа. Возможно, это нормально для некоторых типов файловых систем."
        }
    fi
}

# Функция тестирования прав записи
test_write_permissions() {
    local ctid="$1"
    local mount_path="$2" 
    local access_mode="$3"
    
    echo "🧪 Тестирование прав доступа..."
    
    if [[ "$access_mode" == "ro" ]]; then
        echo "📖 Режим Read-Only - тест записи пропущен"
        return 0
    fi
    
    # Тест записи от имени root в контейнере
    local test_file="$mount_path/.write_test_$(date +%s)"
    
    if pct exec "$ctid" -- bash -c "echo 'test' > '$test_file' && rm -f '$test_file'" 2>/dev/null; then
        echo "✅ Тест записи успешен"
        return 0
    else
        echo "❌ Тест записи неудачен - проблемы с правами доступа"
        return 1
    fi
}

echo "=== 🧩 Конфигурация монтирования в Proxmox LXC ==="

# Инициализация переменных
CONTAINER_TYPE=""
LXC_MAPPING=""
LXC_COMPAT_MODE="auto"

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

    # Анализ контейнера для правильного монтирования
    CONTAINER_TYPE=$(get_container_type "$CTID")
    echo "🔍 Тип контейнера: $CONTAINER_TYPE"
    
    if [[ "$LXC_COMPAT_MODE" == "auto" ]]; then
        LXC_MAPPING=$(get_lxc_mapping "$CTID")
        echo "🔍 Обнаружен mapping: UID:GID = $LXC_MAPPING"
        
        # Отладочная информация для диагностики
        if [[ "$CONTAINER_TYPE" == "unprivileged" && "$LXC_MAPPING" == "0:0" ]]; then
            echo "⚠️ Отладка: непривилегированный контейнер, но mapping = 0:0"
            echo "🔍 Содержимое конфига /etc/pve/lxc/$CTID.conf (строки idmap):"
            grep -E "idmap" "/etc/pve/lxc/$CTID.conf" || echo "❌ Строки idmap не найдены"
        fi
    elif [[ "$LXC_COMPAT_MODE" == "manual" ]]; then
        LXC_MAPPING="$MANUAL_UID:$MANUAL_GID"
        echo "🔧 Используется ручной mapping: UID:GID = $LXC_MAPPING"
    else
        LXC_MAPPING="0:0"
        echo "⚠️ Настройка mapping пропущена"
    fi

    # Монтирование на хосте (для network shares)
    if [[ "$SHARE_TYPE" != "mounted" ]]; then
        # Установка зависимостей
        echo "📦 Установка зависимостей..."
        if [[ "$SHARE_TYPE" == "nfs" ]]; then
            apt-get update -qq && apt-get install -y nfs-common
            echo "🔗 Монтирование NFS на хосте..."
            
            # Подготовка опций монтирования с учетом LXC mapping
            local mount_opts="vers=3,rw"
            if [[ "$CONTAINER_TYPE" == "unprivileged" && "$LXC_COMPAT_MODE" != "skip" ]]; then
                local uid=$(echo "$LXC_MAPPING" | cut -d: -f1)
                local gid=$(echo "$LXC_MAPPING" | cut -d: -f2)
                mount_opts="$mount_opts,all_squash,anonuid=$uid,anongid=$gid"
                echo "🔧 Использование LXC mapping для NFS: anonuid=$uid,anongid=$gid"
            fi
            
            mount -t nfs "$SHARE_SRC" "$HOST_MOUNT" -o "$mount_opts"
            
        elif [[ "$SHARE_TYPE" == "cifs" ]]; then
            apt-get update -qq && apt-get install -y cifs-utils
            echo "🔗 Монтирование CIFS на хосте..."
            
            # Подготовка опций монтирования с учетом LXC mapping
            local mount_opts="username=$CIFS_USER,password=$CIFS_PASS,vers=3.0"
            if [[ "$CONTAINER_TYPE" == "unprivileged" && "$LXC_COMPAT_MODE" != "skip" ]]; then
                local uid=$(echo "$LXC_MAPPING" | cut -d: -f1)
                local gid=$(echo "$LXC_MAPPING" | cut -d: -f2)
                mount_opts="$mount_opts,uid=$uid,gid=$gid,file_mode=0664,dir_mode=0775"
                echo "🔧 Использование LXC mapping для CIFS: uid=$uid,gid=$gid"
            fi
            
            mount -t cifs "$SHARE_SRC" "$HOST_MOUNT" -o "$mount_opts"
        fi

        # Проверка монтирования
        if mount | grep -q "$HOST_MOUNT"; then
            echo "✅ Смонтировано успешно на хосте: $HOST_MOUNT"
        else
            echo "❌ Ошибка монтирования на хосте. Подробности:"
            dmesg | tail -n 10
            exit 1
        fi
        
        # Настройка прав доступа после монтирования (для unprivileged контейнеров)
        if [[ "$CONTAINER_TYPE" == "unprivileged" && "$LXC_COMPAT_MODE" != "skip" ]]; then
            echo "🔧 Настройка прав доступа для непривилегированного контейнера..."
            setup_lxc_permissions "$HOST_MOUNT" "$LXC_MAPPING" "$ACCESS_MODE"
        fi
    else
        # Для mounted - просто используем существующую директорию
        HOST_MOUNT="$SHARE_SRC"
        echo "📂 Использование уже доступной директории: $HOST_MOUNT"
        
        # Настройка прав доступа для существующих директорий (если не skip)
        if [[ "$LXC_COMPAT_MODE" != "skip" && "$CONTAINER_TYPE" == "unprivileged" ]]; then
            echo "🔧 Настройка прав доступа для уже доступной директории..."
            setup_lxc_permissions "$HOST_MOUNT" "$LXC_MAPPING" "$ACCESS_MODE"
        fi
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
    
    # Выполняем тест прав доступа для host-managed режима
    if [[ "$MODE" == "host-managed" ]]; then
        if test_write_permissions "$CTID" "$CT_MOUNT" "$ACCESS_MODE"; then
            WRITE_TEST_STATUS="✅ успешно"
        else
            WRITE_TEST_STATUS="❌ ошибка"
        fi
    fi
    
    echo ""
    echo "📂 Содержимое $CT_MOUNT в контейнере:"
    if pct exec "$CTID" -- ls -la "$CT_MOUNT" 2>/dev/null; then
        echo ""
        if [[ "$WRITE_TEST_STATUS" == "✅ успешно" ]]; then
            echo "✅ Монтирование успешно завершено!"
        else
            echo "⚠️ Монтирование завершено, но есть проблемы с правами доступа"
        fi
        
        echo ""
        echo "📋 Сводка конфигурации:"
        echo "   Контейнер: $CTID ($CONTAINER_TYPE)"
        echo "   Режим: $MODE"
        echo "   Тип: $SHARE_TYPE"
        if [[ "$SHARE_TYPE" != "mounted" ]]; then
            echo "   Источник: $SHARE_SRC"
        else
            echo "   Директория хоста: $SHARE_SRC"
        fi
        echo "   Путь в контейнере: $CT_MOUNT"
        echo "   Доступ: $ACCESS_MODE"
        if [[ "$MODE" == "host-managed" ]]; then
            echo "   LXC mapping: $LXC_MAPPING (режим: $LXC_COMPAT_MODE)"
            if [[ "$SHARE_TYPE" != "mounted" ]]; then
                echo "   Путь на хосте: $HOST_MOUNT"
            fi
            if [[ -n "$WRITE_TEST_STATUS" ]]; then
                echo "   Тест записи: $WRITE_TEST_STATUS"
            fi
        fi
        
        # Дополнительные рекомендации при проблемах
        if [[ "$WRITE_TEST_STATUS" == "❌ ошибка" ]]; then
            echo ""
            echo "💡 Рекомендации для исправления проблем с правами:"
            echo "   1. Проверьте права на сетевой шаре"
            echo "   2. Убедитесь, что сервер поддерживает нужные UID/GID"
            echo "   3. При необходимости запустите скрипт с режимом 'manual' и укажите корректные UID/GID"
        fi
    else
        echo "⚠️ Директория пуста или недоступна"
        echo "Это может быть нормально для новой/пустой шары"
    fi
else
    echo "❌ Директория $CT_MOUNT не найдена в контейнере"
    exit 1
fi
