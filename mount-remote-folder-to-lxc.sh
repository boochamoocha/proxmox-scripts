#!/bin/bash

echo "=== 🧩 Конфигурация монтирования в Proxmox LXC ==="

read -p "Введите ID контейнера: " CTID
read -p "Введите тип шаринга (nfs/cifs): " SHARE_TYPE
read -p "Введите адрес источника (например, 192.168.1.10:/media или //192.168.1.10/media): " SHARE_SRC
read -p "Введите путь монтирования на хосте Proxmox (например, /mnt/nfs-media): " HOST_MOUNT
read -p "Введите путь в контейнере (например, /mnt/media): " CT_MOUNT
read -p "Введите индекс mountpoint (например, mp0, mp1): " MP_INDEX

# Создание точки монтирования
mkdir -p "$HOST_MOUNT"

if [[ "$SHARE_TYPE" == "nfs" ]]; then
    apt-get update && apt-get install -y nfs-common
    mount -t nfs "$SHARE_SRC" "$HOST_MOUNT"
elif [[ "$SHARE_TYPE" == "cifs" ]]; then
    apt-get update && apt-get install -y cifs-utils
    read -p "Введите имя пользователя CIFS: " CIFS_USER
    read -s -p "Введите пароль CIFS: " CIFS_PASS
    echo
    mount -t cifs "$SHARE_SRC" "$HOST_MOUNT" -o username=$CIFS_USER,password=$CIFS_PASS,vers=3.0
else
    echo "❌ Неподдерживаемый тип: $SHARE_TYPE"
    exit 1
fi

# Проверка успешности монтирования
if mount | grep "$HOST_MOUNT" > /dev/null; then
    echo "✅ Смонтировано успешно: $HOST_MOUNT"
else
    echo "❌ Ошибка монтирования"
    exit 1
fi

# Обновление конфигурации контейнера
CONF_PATH="/etc/pve/lxc/$CTID.conf"

if grep "$CT_MOUNT" "$CONF_PATH" > /dev/null; then
    echo "⚠️ Точка монтирования уже существует в конфиге"
else
    echo "$MP_INDEX: $HOST_MOUNT,mp=$CT_MOUNT" >> "$CONF_PATH"
    echo "✅ Добавлено в $CONF_PATH"
fi

# Перезапуск контейнера
pct restart "$CTID"
echo "🚀 Контейнер $CTID перезапущен"

# Проверка внутри контейнера
echo "📂 Проверка содержимого в контейнере:"
pct exec "$CTID" -- ls "$CT_MOUNT"
