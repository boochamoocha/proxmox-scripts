# Установка Avahi в LXC-контейнер на Proxmox

Bash-скрипт для автоматической установки и настройки службы `avahi-daemon` внутри LXC-контейнера на Proxmox. Позволяет обращаться к контейнеру из локальной сети по имени с суффиксом `.local` (например, `ubuntu-server.local`).

## Поддерживаемые ОС

- **Debian-based системы**: Debian, Ubuntu
- **Alpine Linux**

## Возможности

- ✅ Автоматическое определение ОС в контейнере
- ✅ Установка необходимых пакетов для каждой ОС
- ✅ Настройка systemd для работы в LXC (Debian/Ubuntu)
- ✅ Настройка OpenRC (Alpine Linux)
- ✅ Проверка работоспособности после установки
- ✅ Откат изменений при ошибках
- ✅ Подробное логирование процесса

## Требования

### На хосте Proxmox

- Proxmox VE с поддержкой LXC
- Утилита `pct` (входит в состав Proxmox)
- Права root на хосте

### LXC-контейнер

- Контейнер должен быть запущен (`running`)
- Поддерживаемая ОС (Debian/Ubuntu/Alpine)
- Доступ к интернету для загрузки пакетов

## Установка

### 1. Скачивание скрипта

```bash
# На хосте Proxmox
wget https://raw.githubusercontent.com/your-repo/install-avahi-lxc/main/install_avahi_lxc.sh
# или
curl -O https://raw.githubusercontent.com/your-repo/install-avahi-lxc/main/install_avahi_lxc.sh
```

### 2. Установка прав на выполнение

```bash
chmod +x install_avahi_lxc.sh
```

## Использование

### Базовое использование

```bash
./install_avahi_lxc.sh <CONTAINER_ID>
```

**Пример:**
```bash
./install_avahi_lxc.sh 101
```

### Просмотр доступных контейнеров

```bash
pct list
```

## Что делает скрипт

### 1. Проверки
- Проверяет корректность ID контейнера
- Убеждается, что контейнер существует и запущен
- Определяет тип ОС внутри контейнера

### 2. Установка пакетов

**Для Debian/Ubuntu:**
```bash
apt-get update
apt-get install -y avahi-daemon avahi-utils
```

**Для Alpine Linux:**
```bash
apk update
apk add avahi avahi-tools
```

### 3. Настройка службы

**Для Debian/Ubuntu (systemd):**
- Создает override файл `/etc/systemd/system/avahi-daemon.service.d/lxc.conf`
- Добавляет флаг `--no-rlimits` для работы в LXC
- Выполняет `systemctl daemon-reload`
- Включает и запускает службу

**Для Alpine Linux (OpenRC):**
- Добавляет службу в автозагрузку
- Запускает службу

### 4. Проверка работы
- Проверяет статус службы
- Тестирует резолвинг `<hostname>.local`

## Примеры вывода

### Успешное выполнение

```
[INFO] Начало установки Avahi в контейнер 101
[INFO] Проверка контейнера 101...
[INFO] Контейнер 101 найден и запущен. Hostname: ubuntu-server
[INFO] Определение операционной системы в контейнере...
[INFO] Обнаружена Debian-based система: Ubuntu 22.04.3 LTS
[INFO] Обновление списка пакетов...
[INFO] Установка пакетов avahi-daemon и avahi-utils...
[SUCCESS] Пакеты успешно установлены
[INFO] Настройка systemd для работы в LXC...
[INFO] Перезагрузка конфигурации systemd...
[INFO] Включение и запуск службы avahi-daemon...
[SUCCESS] Служба avahi-daemon настроена и запущена
[INFO] Проверка работы Avahi...
[INFO] Тестирование резолвинга ubuntu-server.local...
[SUCCESS] Резолвинг работает корректно
[SUCCESS] Установка завершена успешно!
[SUCCESS] Контейнер теперь доступен по адресу: ubuntu-server.local
```

### При ошибке

```
[INFO] Начало установки Avahi в контейнер 999
[INFO] Проверка контейнера 999...
[ERROR] Контейнер с ID 999 не существует
```

## Устранение неполадок

### Контейнер не найден

```
[ERROR] Контейнер с ID <ID> не существует
```

**Решение:** Проверьте список контейнеров командой `pct list`

### Контейнер не запущен

```
[ERROR] Контейнер <ID> не запущен (текущий статус: stopped)
```

**Решение:** Запустите контейнер командой `pct start <ID>`

### Неподдерживаемая ОС

```
[ERROR] Неподдерживаемая операционная система
```

**Решение:** Убедитесь, что в контейнере установлена Debian, Ubuntu или Alpine Linux

### Ошибка установки пакетов

Скрипт автоматически выполнит откат изменений:

```
[ERROR] Произошла ошибка. Выполняется откат изменений...
[INFO] Удаление установленных пакетов...
[INFO] Отключение службы avahi-daemon...
[ERROR] Откат завершен. Скрипт прерван.
```

### Проблемы с резолвингом

Если после установки резолвинг не работает:

1. **Проверьте статус службы:**
   ```bash
   pct exec <ID> -- systemctl status avahi-daemon
   # или для Alpine
   pct exec <ID> -- service avahi-daemon status
   ```

2. **Проверьте логи:**
   ```bash
   pct exec <ID> -- journalctl -u avahi-daemon
   # или для Alpine
   pct exec <ID> -- tail -f /var/log/messages
   ```

3. **Проверьте сетевые настройки:**
   ```bash
   pct exec <ID> -- ip addr show
   ```

## Дополнительная настройка

### Конфигурация Avahi

Файл конфигурации находится в `/etc/avahi/avahi-daemon.conf`. Основные параметры:

```ini
[server]
host-name=your-hostname
domain-name=local
browse-domains=local
use-ipv4=yes
use-ipv6=yes
```

### Безопасность

Avahi по умолчанию публикует только основные службы. Для публикации дополнительных служб создайте файлы в `/etc/avahi/services/`.

## Лицензия

MIT License

## Поддержка

При возникновении проблем проверьте:
1. Статус контейнера (`pct status <ID>`)
2. Логи Proxmox (`journalctl -u pve-container@<ID>`)
3. Сетевое подключение контейнера