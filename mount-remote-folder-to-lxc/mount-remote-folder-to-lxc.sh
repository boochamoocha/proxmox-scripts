А#!/bin/bash

echo "=== 🧩 Конфигурация монтирования в Proxmox LXC ==="

read -p "Введите ID контейнера: " CTID
read -p "Введите тип шаринга (nfs/cifs): " SHARE_TYPE

# Подсказка и ввод адреса
case "$SHARE_TYPE" in
  nfs)
    echo "📌 Пример адреса источника NFS: 192.168.1.10:/media/nfs"
    read -p "Введите адрес источника NFS: " RAW_SHARE_SRC
    SHARE_SRC="$RAW_SHARE_SRC"
    ;;
  cifs)
    echo "📌 Пример адреса источника CIFS: 192.168.1.10/Movies"
    read -p "Введите адрес источника CIFS (без //): " RAW_SHARE_SRC
    if [[ "$RAW_SHARE_SRC" != //* ]]; then
        SHARE_SRC="//${RAW_SHARE_SRC}"
    else
        SHARE_SRC="$RAW_SHARE_SRC"
    fi
    ;;
  *)
    echo "❌ Неподдерживаемый тип: $SHARE_TYPE"
    exit 1
    ;;
esac

read -p "Введите путь монтирования на хосте Proxmox (например, /mnt/share): " HOST_MOUNT
read -p "Введите путь в контейнере (например, /mnt/media): " CT_MOUNT

# Создание папки на хосте
mkdir -p "$HOST_MOUNT"

# Установка зависимостей и монтирование
if [[ "$SHARE_TYPE" == "nfs" ]]; then
    apt-get update && apt-get install -y nfs-common
    mount -t nfs "$SHARE_SRC" "$HOST_MOUNT"
elif [[ "$SHARE_TYPE" == "cifs" ]]; then
    apt-get update && apt-get install -y cifs-utils
    read -p "Введите имя пользователя CIFS: " CIFS_USER
    read -s -p "Введите пароль CIFS: " CIFS_PASS
    echo
    mount -t cifs "$SHARE_SRC" "$HOST_MOUNT" -o username="$CIFS_USER",password="$CIFS_PASS",vers=3.0
fi

# Проверка монтирования
if mount | grep -q "$HOST_MOUNT"; then
    echo "✅ Смонтировано успешно: $HOST_MOUNT"
else
    echo "❌ Ошибка монтирования. Подробности:"
    dmesg | tail -n 10
    exit 1
fi

# === Найдём свободный mpX ===
CONF_PATH="/etc/pve/lxc/$CTID.conf"
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
    echo "$MP_INDEX: $HOST_MOUNT,mp=$CT_MOUNT" >> "$CONF_PATH"
    echo "✅ Добавлено в конфигурацию LXC: $CONF_PATH"
fi

# Создание каталога внутри контейнера
echo "📁 Создание каталога $CT_MOUNT в контейнере $CTID..."
pct exec "$CTID" -- mkdir -p "$CT_MOUNT"

# Перезапуск контейнера
pct reboot "$CTID"
echo "🚀 Контейнер $CTID перезапущен"

# Проверка содержимого
echo "📂 Содержимое внутри контейнера:"
pct exec "$CTID" -- ls -la "$CT_MOUNT"
