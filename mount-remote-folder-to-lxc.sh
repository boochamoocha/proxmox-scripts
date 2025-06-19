#!/bin/bash

echo "=== 🧩 Конфигурация монтирования в Proxmox LXC ==="

read -p "Введите ID контейнера: " CTID
read -p "Введите тип шаринга (nfs/cifs): " SHARE_TYPE
read -p "Введите адрес источника (пример для NFS: 192.168.1.10:/media, для CIFS: 192.168.1.10/media): " RAW_SHARE_SRC
read -p "Введите путь монтирования на хосте Proxmox (например, /mnt/share): " HOST_MOUNT
read -p "Введите путь в контейнере (например, /mnt/media): " CT_MOUNT
read -p "Введите индекс mountpoint (например, mp0, mp1): " MP_INDEX

mkdir -p "$HOST_MOUNT"

# Формируем путь для CIFS, если не начинается с //
if [[ "$SHARE_TYPE" == "cifs" ]]; then
    if [[ "$RAW_SHARE_SRC" != //* ]]; then
        SHARE_SRC="//${RAW_SHARE_SRC}"
    else
        SHARE_SRC="$RAW_SHARE_SRC"
    fi
else
    SHARE_SRC="$RAW_SHARE_SRC"
fi

if [[ "$SHARE_TYPE" == "nfs" ]]; then
    apt-get update && apt-get install -y nfs-common
    mount -t nfs "$SHARE_SRC" "$HOST_MOUNT"
elif [[ "$SHARE_TYPE" == "cifs" ]]; then
    apt-get update && apt-get install -y cifs-utils
    read -p "Введите имя пользователя CIFS: " CIFS_USER
    read -s -p "Введите пароль CIFS: " CIFS_PASS
    echo
    mount -t cifs "$SHARE_SRC" "$HOST_MOUNT" -o username="$CIFS_USER",password="$CIFS_PASS",vers=3.0
else
    echo "❌ Неподдерживаемый тип: $SHARE_TYPE"
    exit 1
fi

# Проверка монтирования
if mount | grep -q "$HOST_MOUNT"; then
    echo "✅ Смонтировано успешно: $HOST_MOUNT"
else
    echo "❌ Ошибка монтирования. Подробности:"
    dmesg | tail -n 10
    exit 1
fi

# Обновление конфигурации LXC
CONF_PATH="/etc/pve/lxc/$CTID.conf"
if grep -q "$CT_MOUNT" "$CONF_PATH"; then
    echo "⚠️ Точка монтирования уже присутствует в конфиге"
else
    echo "$MP_INDEX: $HOST_MOUNT,mp=$CT_MOUNT" >> "$CONF_PATH"
    echo "✅ Добавлено в конфигурацию LXC: $CONF_PATH"
fi

# Создание точки в контейнере
echo "📁 Создание каталога $CT_MOUNT в контейнере $CTID..."
pct exec "$CTID" -- mkdir -p "$CT_MOUNT"

# Перезапуск контейнера
pct reboot "$CTID"
echo "🚀 Контейнер $CTID перезапущен"

# Проверка содержимого
echo "📂 Содержимое внутри контейнера:"
pct exec "$CTID" -- ls -la "$CT_MOUNT"


