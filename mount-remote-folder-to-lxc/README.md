# Mount Remote Folder to LXC Container

Скрипт для автоматического монтирования удаленных папок (NFS/CIFS) в контейнеры Proxmox LXC.

## Запуск

### Вариант 1: Прямой запуск из репозитория (рекомендуемый)

Запустите скрипт одной командой прямо из GitHub:

```bash
curl -s https://raw.githubusercontent.com/boochamoocha/proxmox-scripts/main/mount-remote-folder-to-lxc/mount-remote-folder-to-lxc.sh | bash
```

Или с wget:
```bash
wget -qO- https://raw.githubusercontent.com/boochamoocha/proxmox-scripts/main/mount-remote-folder-to-lxc/mount-remote-folder-to-lxc.sh | bash
```

### Вариант 2: Скачивание и запуск локально

1. Скачайте скрипт на ваш сервер Proxmox:
```bash
wget https://raw.githubusercontent.com/boochamoocha/proxmox-scripts/main/mount-remote-folder-to-lxc/mount-remote-folder-to-lxc.sh
```

2. Сделайте скрипт исполняемым и запустите:
```bash
chmod +x mount-remote-folder-to-lxc.sh
sudo ./mount-remote-folder-to-lxc.sh
```

## Использование

### Входные параметры

Скрипт запросит следующие данные:

1. **ID контейнера** - номер вашего LXC контейнера
2. **Тип шаринга** - `nfs` или `cifs`
3. **Адрес источника**:
   - Для NFS: `192.168.1.10:/media/nfs`
   - Для CIFS: `192.168.1.10/Movies` (без префикса //)
4. **Путь монтирования на хосте** - например, `/mnt/share`
5. **Путь в контейнере** - например, `/mnt/media`
6. **Для CIFS**: имя пользователя и пароль

## Что делает скрипт

1. Устанавливает необходимые пакеты (`nfs-common` или `cifs-utils`)
2. Монтирует удаленную папку на хост Proxmox
3. Находит свободный индекс точки монтирования (mp0-mp31)
4. Добавляет конфигурацию в файл контейнера LXC
5. Создает директорию внутри контейнера
6. Перезапускает контейнер для применения изменений
7. Проверяет успешность монтирования

## Требования

- Proxmox VE сервер
- Работающий LXC контейнер
- Доступ к удаленному NFS/CIFS ресурсу
- Права root на хосте Proxmox

## Устранение неполадок

Если монтирование не удалось, скрипт покажет последние 10 строк из `dmesg` для диагностики проблемы.

Проверить статус монтирования можно командой:
```bash
mount | grep /mnt/your-mount-point
```