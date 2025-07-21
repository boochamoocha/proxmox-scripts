#!/bin/bash

# Скрипт для автоматической установки Avahi в LXC-контейнер на Proxmox
# Автор: Claude
# Использование: ./install_avahi_lxc.sh [CONTAINER_ID]

set -euo pipefail

CONTAINER_ID=""
CONTAINER_HOSTNAME=""
OS_TYPE=""
INSTALLED_PACKAGES=""
SYSTEMD_OVERRIDE_CREATED=false
SERVICE_ENABLED=false

show_usage() {
    echo "Использование: $0 [CONTAINER_ID]"
    echo "Пример: $0 101"
    echo ""
    echo "Если CONTAINER_ID не указан, скрипт запросит его интерактивно"
}

log_info() {
    echo "[INFO] $1"
}

log_error() {
    echo "[ERROR] $1" >&2
}

log_success() {
    echo "[SUCCESS] $1"
}

cleanup_on_error() {
    log_error "Произошла ошибка. Выполняется откат изменений..."
    
    if [[ "$INSTALLED_PACKAGES" != "" ]]; then
        log_info "Удаление установленных пакетов..."
        case "$OS_TYPE" in
            "debian")
                pct exec "$CONTAINER_ID" -- apt-get remove -y avahi-daemon avahi-utils || true
                pct exec "$CONTAINER_ID" -- apt-get autoremove -y || true
                ;;
            "alpine")
                pct exec "$CONTAINER_ID" -- apk del avahi avahi-tools || true
                ;;
        esac
    fi
    
    if [[ "$SERVICE_ENABLED" == true ]]; then
        log_info "Отключение службы avahi-daemon..."
        case "$OS_TYPE" in
            "debian")
                pct exec "$CONTAINER_ID" -- systemctl disable avahi-daemon || true
                pct exec "$CONTAINER_ID" -- systemctl stop avahi-daemon || true
                ;;
            "alpine")
                pct exec "$CONTAINER_ID" -- rc-update del avahi-daemon || true
                pct exec "$CONTAINER_ID" -- service avahi-daemon stop || true
                ;;
        esac
    fi
    
    if [[ "$SYSTEMD_OVERRIDE_CREATED" == true ]]; then
        log_info "Удаление systemd override файла..."
        pct exec "$CONTAINER_ID" -- rm -rf /etc/systemd/system/avahi-daemon.service.d/ || true
        pct exec "$CONTAINER_ID" -- systemctl daemon-reload || true
    fi
    
    log_error "Откат завершен. Скрипт прерван."
    exit 1
}

trap cleanup_on_error ERR

show_containers() {
    echo ""
    echo "Доступные контейнеры:"
    echo "ID    STATUS    NAME"
    echo "---   -------   ----"
    pct list | tail -n +2 | while read -r line; do
        echo "$line"
    done
    echo ""
}

prompt_container_id() {
    local input_id
    
    show_containers
    
    while true; do
        read -p "Введите ID контейнера: " input_id
        
        if [[ -z "$input_id" ]]; then
            echo "ID контейнера не может быть пустым. Попробуйте снова."
            continue
        fi
        
        if ! [[ "$input_id" =~ ^[0-9]+$ ]]; then
            echo "ID контейнера должен быть числом. Попробуйте снова."
            continue
        fi
        
        CONTAINER_ID="$input_id"
        break
    done
}

parse_arguments() {
    if [[ $# -gt 1 ]]; then
        log_error "Слишком много аргументов"
        show_usage
        exit 1
    fi
    
    if [[ $# -eq 1 ]]; then
        if ! [[ "$1" =~ ^[0-9]+$ ]]; then
            log_error "ID контейнера должен быть числом"
            show_usage
            exit 1
        fi
        CONTAINER_ID="$1"
    else
        # Интерактивный режим
        prompt_container_id
    fi
}

check_container() {
    log_info "Проверка контейнера $CONTAINER_ID..."
    
    if ! pct list | grep -q "^$CONTAINER_ID "; then
        log_error "Контейнер с ID $CONTAINER_ID не существует"
        exit 1
    fi
    
    local status
    status=$(pct status "$CONTAINER_ID" | awk '{print $2}')
    if [[ "$status" != "running" ]]; then
        log_error "Контейнер $CONTAINER_ID не запущен (текущий статус: $status)"
        exit 1
    fi
    
    CONTAINER_HOSTNAME=$(pct exec "$CONTAINER_ID" -- hostname)
    log_info "Контейнер $CONTAINER_ID найден и запущен. Hostname: $CONTAINER_HOSTNAME"
}

detect_os() {
    log_info "Определение операционной системы в контейнере..."
    
    if pct exec "$CONTAINER_ID" -- test -f /etc/debian_version; then
        OS_TYPE="debian"
        local os_name
        os_name=$(pct exec "$CONTAINER_ID" -- cat /etc/os-release | grep "^PRETTY_NAME=" | cut -d'"' -f2)
        log_info "Обнаружена Debian-based система: $os_name"
    elif pct exec "$CONTAINER_ID" -- test -f /etc/alpine-release; then
        OS_TYPE="alpine"
        local os_version
        os_version=$(pct exec "$CONTAINER_ID" -- cat /etc/alpine-release)
        log_info "Обнаружена Alpine Linux: $os_version"
    else
        log_error "Неподдерживаемая операционная система"
        exit 1
    fi
}

install_packages_debian() {
    log_info "Обновление списка пакетов..."
    pct exec "$CONTAINER_ID" -- apt-get update
    
    log_info "Установка пакетов avahi-daemon и avahi-utils..."
    pct exec "$CONTAINER_ID" -- apt-get install -y avahi-daemon avahi-utils
    INSTALLED_PACKAGES="avahi-daemon avahi-utils"
    
    log_success "Пакеты успешно установлены"
}

install_packages_alpine() {
    log_info "Обновление списка пакетов..."
    pct exec "$CONTAINER_ID" -- apk update
    
    log_info "Установка пакетов avahi и avahi-tools..."
    pct exec "$CONTAINER_ID" -- apk add avahi avahi-tools
    INSTALLED_PACKAGES="avahi avahi-tools"
    
    log_success "Пакеты успешно установлены"
}

configure_systemd() {
    log_info "Настройка systemd для работы в LXC..."
    
    pct exec "$CONTAINER_ID" -- mkdir -p /etc/systemd/system/avahi-daemon.service.d/
    
    pct exec "$CONTAINER_ID" -- tee /etc/systemd/system/avahi-daemon.service.d/lxc.conf > /dev/null << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/sbin/avahi-daemon -s --no-rlimits
EOF
    
    SYSTEMD_OVERRIDE_CREATED=true
    
    log_info "Перезагрузка конфигурации systemd..."
    pct exec "$CONTAINER_ID" -- systemctl daemon-reload
    
    log_info "Включение и запуск службы avahi-daemon..."
    pct exec "$CONTAINER_ID" -- systemctl enable avahi-daemon
    pct exec "$CONTAINER_ID" -- systemctl start avahi-daemon
    SERVICE_ENABLED=true
    
    log_success "Служба avahi-daemon настроена и запущена"
}

configure_openrc() {
    log_info "Настройка OpenRC..."
    
    log_info "Включение и запуск службы avahi-daemon..."
    pct exec "$CONTAINER_ID" -- rc-update add avahi-daemon
    pct exec "$CONTAINER_ID" -- service avahi-daemon start
    SERVICE_ENABLED=true
    
    log_success "Служба avahi-daemon настроена и запущена"
}

test_avahi() {
    log_info "Проверка работы Avahi..."
    
    sleep 3
    
    if ! pct exec "$CONTAINER_ID" -- systemctl is-active avahi-daemon > /dev/null 2>&1 && \
       ! pct exec "$CONTAINER_ID" -- service avahi-daemon status > /dev/null 2>&1; then
        log_error "Служба avahi-daemon не запущена"
        return 1
    fi
    
    log_info "Тестирование резолвинга $CONTAINER_HOSTNAME.local..."
    
    if pct exec "$CONTAINER_ID" -- which avahi-resolve > /dev/null 2>&1; then
        if pct exec "$CONTAINER_ID" -- timeout 10 avahi-resolve -n "$CONTAINER_HOSTNAME.local" > /dev/null 2>&1; then
            log_success "Резолвинг работает корректно"
            return 0
        fi
    fi
    
    if pct exec "$CONTAINER_ID" -- which getent > /dev/null 2>&1; then
        if pct exec "$CONTAINER_ID" -- timeout 10 getent hosts "$CONTAINER_HOSTNAME.local" > /dev/null 2>&1; then
            log_success "Резолвинг работает корректно"
            return 0
        fi
    fi
    
    log_error "Не удается разрешить $CONTAINER_HOSTNAME.local"
    return 1
}

main() {
    log_info "Начало установки Avahi в контейнер $CONTAINER_ID"
    
    parse_arguments "$@"
    check_container
    detect_os
    
    case "$OS_TYPE" in
        "debian")
            install_packages_debian
            configure_systemd
            ;;
        "alpine")
            install_packages_alpine
            configure_openrc
            ;;
        *)
            log_error "Неподдерживаемая ОС: $OS_TYPE"
            exit 1
            ;;
    esac
    
    test_avahi
    
    log_success "Установка завершена успешно!"
    log_success "Контейнер теперь доступен по адресу: $CONTAINER_HOSTNAME.local"
}

main "$@"