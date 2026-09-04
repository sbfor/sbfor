#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
MAGENTA='\033[1;35m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m'

# ============================================================
# БЭКАПЫ В /root/ddos_backup/
# ============================================================
BACKUP_BASE_DIR="/root/ddos_backup"
mkdir -p "$BACKUP_BASE_DIR" 2>/dev/null || true
BACKUP_DIR="$BACKUP_BASE_DIR/backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR" 2>/dev/null || true

ERRORS_FOUND=0
IPTABLES_SAVE_FILE="/etc/iptables/rules.v4"

get_ubuntu_version() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "${VERSION_ID:-unknown}"
    else
        echo "unknown"
    fi
}

UBUNTU_VERSION=$(get_ubuntu_version)

check_iptables_type() {
    if command -v iptables &> /dev/null; then
        if iptables --version 2>/dev/null | grep -q "nf_tables"; then
            echo "nf_tables"
        else
            echo "legacy"
        fi
    else
        echo "not_installed"
    fi
}

IPTABLES_TYPE=$(check_iptables_type)

check_ipv6() {
    if [ -f /proc/net/if_inet6 ] 2>/dev/null; then
        echo "yes"
    else
        echo "no"
    fi
}

IPV6_AVAILABLE=$(check_ipv6)

get_server_ip() {
    IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "")
    if [ -z "$IP" ]; then
        IP=$(ip route get 1 2>/dev/null | awk '{print $NF;exit}' || echo "")
    fi
    if [ -z "$IP" ]; then
        IP=$(curl -s -4 ifconfig.me 2>/dev/null || echo "")
    fi
    if [ -z "$IP" ]; then
        IP="localhost"
    fi
    echo "$IP"
}

SERVER_IP=$(get_server_ip)

# ===================================================================
# УНИВЕРСАЛЬНОЕ ОПРЕДЕЛЕНИЕ SSH-ПОРТА
# ===================================================================
get_ssh_port() {
    local ssh_port="22"
    
    if command -v sshd &> /dev/null; then
        local detected_port=$(sshd -T 2>/dev/null | grep -E "^port\s+[0-9]+" | awk '{print $2}' | head -1)
        if [ -n "$detected_port" ] && [[ "$detected_port" =~ ^[0-9]+$ ]]; then
            echo "$detected_port"
            return 0
        fi
    fi
    
    if [ -f /etc/ssh/sshd_config ]; then
        local config_files=("/etc/ssh/sshd_config")
        
        if [ -d /etc/ssh/sshd_config.d ]; then
            for f in $(ls -r /etc/ssh/sshd_config.d/*.conf 2>/dev/null); do
                [ -f "$f" ] && config_files+=("$f")
            done
        fi
        
        for ((i=${#config_files[@]}-1; i>=0; i--)); do
            local port=$(grep -E "^Port\s+[0-9]+" "${config_files[$i]}" 2>/dev/null | awk '{print $2}' | head -1)
            if [ -n "$port" ] && [[ "$port" =~ ^[0-9]+$ ]]; then
                echo "$port"
                return 0
            fi
        done
    fi
    
    local detected_port=$(ss -tulpn 2>/dev/null | grep -E "sshd|ssh" | grep LISTEN | awk '{print $5}' | cut -d: -f2 | sort -u | head -1)
    if [ -n "$detected_port" ] && [[ "$detected_port" =~ ^[0-9]+$ ]]; then
        echo "$detected_port"
        return 0
    fi
    
    echo "22"
}

SSH_PORT=$(get_ssh_port)

# ===================================================================
# УНИВЕРСАЛЬНЫЙ ПЕРЕЗАПУСК SSH
# ===================================================================
restart_ssh() {
    if systemctl is-active --quiet sshd.service 2>/dev/null; then
        systemctl restart sshd 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    elif systemctl is-active --quiet ssh.service 2>/dev/null; then
        systemctl restart ssh 2>/dev/null || systemctl reload ssh 2>/dev/null || true
    elif systemctl is-active --quiet ssh.socket 2>/dev/null; then
        systemctl restart ssh.socket 2>/dev/null || true
    else
        service ssh restart 2>/dev/null || service sshd restart 2>/dev/null || true
    fi
    sleep 2
}

detect_3xui_ports() {
    echo -e "\n${CYAN}📌 Сканирование внешних портов Xray/V2Ray...${NC}"
    # Обрабатываем только реальные LISTEN-сокеты Xray/V2Ray на внешнем адресе.
    # Порты localhost, порты панели x-ui и номера из конфигурационных файлов
    # намеренно не открываются автоматически.
    PORTS_ARRAY=()
    while IFS='|' read -r local_addr port; do
        [ -n "$port" ] || continue
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        [ "$port" -gt 0 ] && [ "$port" -lt 65536 ] || continue
        case "$local_addr" in
            127.*|127.*:|\[::1\]*|::1:*|localhost:*) continue ;;
        esac
        case " ${PORTS_ARRAY[*]} " in
            *" $port "*) ;;
            *) PORTS_ARRAY+=("$port") ;;
        esac
    done < <(
        sudo ss -H -ltnup 2>/dev/null \
        | awk '
            /xray|v2ray/ {
                addr=$5
                port=addr
                sub(/^.*:/, "", port)
                if (port ~ /^[0-9]+$/ && addr !~ /^127[.]/ && addr !~ /^\[::1\]/ && addr !~ /^::1:/)
                    print addr "|" port
            }' \
        | sort -t'|' -k2,2n -u
    )
    if [ "${#PORTS_ARRAY[@]}" -eq 0 ]; then
        echo -e "  ${YELLOW}⚠️  Внешние порты Xray/V2Ray не обнаружены; открываются только базовые порты.${NC}"
    else
        echo -e "  ${GREEN}✅ Внешние Xray/V2Ray-порты:${NC} ${PORTS_ARRAY[*]}"
        echo -e "  ${WHITE}ℹ️  Порты Nginx, x-ui и localhost автоматически не открываются.${NC}"
    fi
}

print_title() {
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  ${1}${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_success() {
    echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  ✅ ${1}${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_error() {
    echo -e "\n${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}  ❌ ${1}${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

show_progress() {
    echo -e "${CYAN}  ⏳ ${1}...${NC}"
}

show_ok() {
    echo -e "  ${GREEN}✅ Готово!${NC}"
}

show_warn() {
    echo -e "  ${YELLOW}⚠️  ${1}${NC}"
}

show_error() {
    echo -e "  ${RED}❌ ${1}${NC}"
    ERRORS_FOUND=1
}

auto_confirm() {
    export DEBIAN_FRONTEND=noninteractive
    echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | sudo debconf-set-selections 2>/dev/null || true
    echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | sudo debconf-set-selections 2>/dev/null || true
}

fix_apt_lock() {
    # Не убиваем apt/dpkg и не удаляем lock-файлы принудительно.
    if pgrep -x apt >/dev/null 2>&1 || pgrep -x apt-get >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1; then
        show_warn "Менеджер пакетов уже занят; автоматическое вмешательство запрещено"
        return 1
    fi
    if ! sudo dpkg --audit >/dev/null 2>&1; then
        show_warn "Обнаружено незавершённое состояние dpkg; автоматическое исправление пропущено"
        return 1
    fi
    return 0
}

install_package() {
    local package=$1
    local name=$2
    if ! command -v "$package" &> /dev/null; then
        show_progress "Устанавливаем ${name}"
        if ! fix_apt_lock; then
            return 1
        fi
        auto_confirm
        sudo apt-get update -qq 2>/dev/null || {
            show_warn "Не удалось обновить список пакетов"
            return 1
        }
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$package" 2>/dev/null || {
            show_warn "Не удалось установить ${name}"
            return 1
        }
        show_ok
        return 0
    else
        show_warn "${name} уже установлен"
        return 0
    fi
}

setup_iptables_mode() {
    print_title "🔧 НАСТРОЙКА IPTABLES"
    echo -e "\n${CYAN}📌 Определение системы:${NC}"
    echo -e "  ${WHITE}Ubuntu:${NC} $UBUNTU_VERSION"
    echo -e "  ${WHITE}Текущий iptables:${NC} $IPTABLES_TYPE"
    echo -e "  ${WHITE}IPv6:${NC} $IPV6_AVAILABLE"
    echo -e "  ${WHITE}SSH порт:${NC} $SSH_PORT"
    if ! command -v iptables &> /dev/null; then
        install_package iptables "iptables" || true
        IPTABLES_TYPE=$(check_iptables_type)
    fi
    if [[ "$IPTABLES_TYPE" == "nf_tables" ]]; then
        echo -e "  ${GREEN}✅ Используется системный iptables-nft; backend не изменяется${NC}"
    elif [[ "$IPTABLES_TYPE" == "legacy" ]]; then
        echo -e "  ${YELLOW}⚠️  Обнаружен legacy backend; переключение не выполняется${NC}"
    else
        echo -e "  ${YELLOW}⚠️  Backend iptables не определён; используется системная команда${NC}"
    fi
    if ! iptables -L &> /dev/null; then
        show_error "iptables не работает!"
        return 1
    fi
    return 0
}

setup_ufw() {
    print_title "🔧 НАСТРОЙКА UFW"
    echo -e "\n${CYAN}📌 Настройка UFW...${NC}"
    echo -e "\n${YELLOW}📦 ПРИНУДИТЕЛЬНАЯ УСТАНОВКА UFW...${NC}"
    show_progress "Обновление списка пакетов"
    sudo apt-get update -qq 2>/dev/null || true
    show_ok
    show_progress "Принудительная установка UFW"
    if ! fix_apt_lock; then
        show_error "Установка UFW пропущена: менеджер пакетов занят или dpkg требует ручного восстановления"
        return 1
    fi
    auto_confirm
    sudo DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y -qq ufw 2>/dev/null || {
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw 2>/dev/null || {
            show_error "Не удалось установить UFW!"
            return 1
        }
    }
    show_ok
    hash -r 2>/dev/null || true
    if command -v ufw &> /dev/null; then
        echo -e "  ${GREEN}✅ UFW успешно установлен (принудительно)!${NC}"
    else
        show_error "UFW не установлен!"
        return 1
    fi
    UFW_VERSION=$(ufw --version 2>/dev/null | head -1 || echo "неизвестно")
    echo -e "  ${WHITE}Версия UFW:${NC} $UFW_VERSION"
    echo -e "\n${BLUE}ℹ️  Политика IPv6 UFW не изменяется пунктом 1${NC}"
    echo -e "  ${WHITE}Управление IPv6 выполняется только через отдельный пункт меню${NC}"
    echo -e "\n${YELLOW}🔓 Проверяем базовые доступы без изменения VPN/панели...${NC}"
    # Пункт 1 не сканирует listener-порты и не открывает их автоматически.
    # Сохраняем только обязательные базовые доступы, а существующие правила
    # UFW для VPN, Docker, 3X-UI и других сервисов не удаляем и не заменяем.
    show_progress "  • SSH (${SSH_PORT}/tcp)"
    sudo ufw allow "${SSH_PORT}/tcp" 2>/dev/null || true
    show_ok
    show_progress "  • HTTP (80/tcp)"
    sudo ufw allow 80/tcp 2>/dev/null || true
    show_ok
    show_progress "  • HTTPS (443/tcp, 443/udp)"
    sudo ufw allow 443/tcp 2>/dev/null || true
    sudo ufw allow 443/udp 2>/dev/null || true
    show_ok
    echo -e "  ${GREEN}✅ Автоматические VPN/3X-UI/Docker-порты не изменяются${NC}"
    echo -e "\n${YELLOW}🔧 Активация UFW...${NC}"
    if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
        echo -e "  ${GREEN}✅ UFW уже активен${NC}"
        return 0
    fi
    show_progress "Сброс UFW"
    sudo ufw --force disable 2>/dev/null || true
    sudo systemctl stop ufw 2>/dev/null || true
    sleep 2
    show_progress "Активация UFW"
    sudo ufw --force enable 2>/dev/null || true
    sleep 3
    if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
        echo -e "  ${GREEN}✅ UFW успешно активирован!${NC}"
        return 0
    fi
    echo -e "  ${RED}❌ НЕ УДАЛОСЬ АКТИВИРОВАТЬ UFW!${NC}"
    ERRORS_FOUND=1
    return 1
}

setup_fail2ban() {
    print_title "🔧 НАСТРОЙКА FAIL2BAN"
    echo -e "\n${CYAN}📌 Настройка fail2ban...${NC}"
    if ! command -v fail2ban-client &> /dev/null; then
        install_package fail2ban "fail2ban" || true
    else
        show_warn "fail2ban уже установлен"
    fi
    show_progress "Создаём конфигурацию"
    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 600
findtime = 300
maxretry = 3
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 600

[nginx-http-auth]
enabled = true
port = http,https
filter = nginx-http-auth
logpath = /var/log/nginx/error.log
maxretry = 5

[recidive]
enabled = true
logpath = /var/log/fail2ban.log
maxretry = 2
bantime = 86400
EOF
    show_ok
    show_progress "Перезапускаем fail2ban"
    systemctl restart fail2ban > /dev/null 2>&1
    systemctl enable fail2ban > /dev/null 2>&1
    show_ok
}

setup_nginx() {
    print_title "🔧 НАСТРОЙКА NGINX"
    echo -e "\n${CYAN}📌 Настройка Nginx...${NC}"
    if command -v nginx &> /dev/null; then
        show_warn "Nginx уже установлен"
        if nginx -t > /dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
            echo -e "  ${GREEN}✅ Nginx уже настроен и работает — пропускаем без изменений${NC}"
            echo -e "  ${WHITE}ℹ️  Существующая конфигурация, лимиты и reverse proxy не изменяются${NC}"
            return 0
        fi
        show_error "Nginx установлен, но не прошёл проверку или не активен. Существующая конфигурация не изменяется."
        return 1
    fi
    if install_package nginx "nginx"; then
        systemctl start nginx 2>/dev/null || true
        systemctl enable nginx 2>/dev/null || true
    else
        show_error "Не удалось установить Nginx"
        return 1
    fi
    show_progress "Создаём конфигурацию защиты"
    cat > /etc/nginx/conf.d/ddos_protect.conf <<'EOF'
limit_conn_zone $binary_remote_addr zone=addr_limit:10m;
limit_req_zone $binary_remote_addr zone=req_limit:10m rate=10r/s;

server {
    location / {
        limit_conn addr_limit 20;
        limit_req zone=req_limit burst=30 nodelay;
        limit_req_status 429;
    }
}
EOF
    show_ok
    if nginx -t > /dev/null 2>&1; then
        systemctl reload nginx > /dev/null 2>&1
        echo -e "  ${GREEN}✅ Nginx настроен${NC}"
    else
        show_error "Ошибка в конфигурации Nginx!"
    fi
}

setup_outgoing_limit() {
    print_title "🔧 НАСТРОЙКА ИСХОДЯЩЕЙ ЗАЩИТЫ"
    echo -e "\n${CYAN}📌 Настройка OUTGOING_LIMIT...${NC}"
    echo -e "  ${WHITE}• Xray порты:${NC} БЕЗ ОГРАНИЧЕНИЙ!"
    echo -e "  ${WHITE}• HTTP (80):${NC} БЕЗ ОГРАНИЧЕНИЙ"
    echo -e "  ${WHITE}• HTTPS (443):${NC} БЕЗ ОГРАНИЧЕНИЙ"
    echo -e "  ${WHITE}• DNS (53):${NC} 50 запросов/сек"
    echo -e "  ${WHITE}• SMTP, SMB, NetBIOS:${NC} ЗАБЛОКИРОВАНЫ"
    show_progress "Удаляем старые правила исходящего трафика"
    iptables -D OUTPUT -j OUTGOING_LIMIT 2>/dev/null || true
    iptables -F OUTGOING_LIMIT 2>/dev/null || true
    iptables -X OUTGOING_LIMIT 2>/dev/null || true
    show_ok
    show_progress "Создаем цепочку OUTGOING_LIMIT"
    iptables -N OUTGOING_LIMIT 2>/dev/null || {
        show_warn "Цепочка уже существует, очищаем"
        iptables -F OUTGOING_LIMIT
    }
    show_ok
    echo -e "\n  ${YELLOW}Добавляем Xray порты в исключения:${NC}"
    for port in "${PORTS_ARRAY[@]}"; do
        if [[ "$port" == "80" ]] || [[ "$port" == "443" ]] || [[ "$port" == "$SSH_PORT" ]]; then
            continue
        fi
        if [[ "$port" =~ ^[0-9]+$ ]]; then
            show_progress "  • Порт $port — БЕЗ ОГРАНИЧЕНИЙ (TCP+UDP)"
            iptables -I OUTGOING_LIMIT 1 -p tcp --dport $port -j ACCEPT 2>/dev/null || true
            iptables -I OUTGOING_LIMIT 1 -p udp --dport $port -j ACCEPT 2>/dev/null || true
            show_ok
        fi
    done
    echo -e "\n  ${YELLOW}Добавляем HTTP/HTTPS без ограничений:${NC}"
    show_progress "  • HTTP (80) — БЕЗ ОГРАНИЧЕНИЙ"
    iptables -A OUTGOING_LIMIT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
    show_ok
    show_progress "  • HTTPS (443) — БЕЗ ОГРАНИЧЕНИЙ"
    iptables -A OUTGOING_LIMIT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
    show_ok
    echo -e "\n  ${YELLOW}Добавляем ограничения для остального:${NC}"
    show_progress "  • DNS (53) — 50 запросов/сек"
    iptables -A OUTGOING_LIMIT -p udp --dport 53 -m limit --limit 50/sec -j ACCEPT 2>/dev/null || true
    iptables -A OUTGOING_LIMIT -p udp --dport 53 -j DROP 2>/dev/null || true
    show_ok
    show_progress "  • Блокировка вредоносных портов"
    for port in 25 465 587 135 445; do
        iptables -A OUTGOING_LIMIT -p tcp --dport $port -j DROP 2>/dev/null || true
    done
    for port in 135 137 138 139 445; do
        iptables -A OUTGOING_LIMIT -p udp --dport $port -j DROP 2>/dev/null || true
    done
    show_ok
    show_progress "Активируем цепочку OUTGOING_LIMIT"
    iptables -I OUTPUT 1 -j OUTGOING_LIMIT 2>/dev/null || true
    show_ok
}

create_autostart() {
    print_title "🔧 СОЗДАНИЕ АВТОЗАГРУЗКИ"
    echo -e "\n${CYAN}📌 Настройка автозагрузки...${NC}"
    echo -e "\n${YELLOW}📦 Установка iptables-persistent...${NC}"
    if ! dpkg -l | grep -q iptables-persistent; then
        show_progress "Устанавливаем iptables-persistent"
        fix_apt_lock
        auto_confirm
        sudo apt-get update -qq 2>/dev/null || true
        if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent 2>>/var/log/security_script_apt_errors.log; then
            show_warn "Не удалось установить iptables-persistent (см. /var/log/security_script_apt_errors.log)"
            show_warn "Не критично: автозагрузка правил всё равно обеспечена через systemd-сервис restore-iptables.service"
            ERRORS_FOUND=1
        else
            show_ok
        fi
    else
        show_warn "iptables-persistent уже установлен"
    fi
    echo -e "\n${YELLOW}📦 ПРИНУДИТЕЛЬНАЯ ПЕРЕУСТАНОВКА UFW...${NC}"
    hash -r 2>/dev/null || true
    show_progress "Переустановка UFW"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y -qq ufw 2>/dev/null || {
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw 2>/dev/null || {
            show_error "Не удалось установить UFW!"
        }
    }
    show_ok
    if command -v ufw &> /dev/null; then
        echo -e "  ${GREEN}✅ UFW успешно переустановлен!${NC}"
    else
        echo -e "  ${RED}❌ UFW НЕ УСТАНОВЛЕН!${NC}"
    fi
    echo -e "\n${YELLOW}🔧 ОТКЛЮЧЕНИЕ IPV6 В UFW...${NC}"
    sudo sed -i 's/IPV6=yes/IPV6=no/g' /etc/default/ufw 2>/dev/null || true
    echo -e "  ${GREEN}✅ IPv6 отключён в UFW${NC}"
    echo -e "\n${YELLOW}⚙️  Настройка сервисов...${NC}"
    if systemctl list-unit-files | grep -q netfilter-persistent; then
        show_progress "Включаем netfilter-persistent"
        sudo systemctl enable netfilter-persistent 2>/dev/null || true
        sudo systemctl start netfilter-persistent 2>/dev/null || true
        show_ok
    fi
    if systemctl list-unit-files | grep -q iptables-persistent; then
        show_progress "Включаем iptables-persistent"
        sudo systemctl enable iptables-persistent 2>/dev/null || true
        sudo systemctl start iptables-persistent 2>/dev/null || true
        show_ok
    fi
    echo -e "\n${YELLOW}🔧 Активация UFW...${NC}"
    if command -v ufw &> /dev/null; then
        show_progress "Открываем порты"
        sudo ufw allow ${SSH_PORT}/tcp 2>/dev/null || true
        sudo ufw allow 80/tcp 2>/dev/null || true
        sudo ufw allow 443/tcp 2>/dev/null || true
        sudo ufw allow 443/udp 2>/dev/null || true
        for port in "${PORTS_ARRAY[@]}"; do
            if [[ "$port" =~ ^[0-9]+$ ]]; then
                sudo ufw allow $port/tcp 2>/dev/null || true
                sudo ufw allow $port/udp 2>/dev/null || true
            fi
        done
        show_ok
        show_progress "Активация UFW"
        sudo ufw --force enable 2>/dev/null || true
        sleep 3
        if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
            echo -e "  ${GREEN}✅ UFW успешно активирован!${NC}"
        else
            echo -e "  ${YELLOW}⚠️  UFW не активировался, попробуйте вручную:${NC}"
            echo -e "  ${WHITE}   sudo ufw --force enable${NC}"
        fi
    fi
    echo -e "\n${YELLOW}💾 Сохранение правил...${NC}"
    show_progress "Сохраняем в ${IPTABLES_SAVE_FILE}"
    sudo mkdir -p /etc/iptables 2>/dev/null || true
    sudo iptables-save > ${IPTABLES_SAVE_FILE} 2>/dev/null || true
    show_ok
    if command -v netfilter-persistent &>/dev/null; then
        show_progress "Сохраняем через netfilter-persistent"
        sudo netfilter-persistent save 2>/dev/null || true
        show_ok
    fi
    if [ -f /etc/init.d/iptables-persistent ]; then
        show_progress "Сохраняем через iptables-persistent"
        sudo /etc/init.d/iptables-persistent save 2>/dev/null || true
        show_ok
    fi
    echo -e "\n${YELLOW}📄 Создаём загрузчик через if-up...${NC}"
    cat > /etc/network/if-up.d/iptables-restore <<'EOF'
#!/bin/sh
if [ -f /etc/iptables/rules.v4 ]; then
    /sbin/iptables-restore < /etc/iptables/rules.v4 2>/dev/null || true
fi
EOF
    chmod +x /etc/network/if-up.d/iptables-restore
    show_ok
    echo -e "\n${YELLOW}📄 Создаём systemd-сервис с задержкой...${NC}"
    cat > /etc/systemd/system/restore-iptables.service <<'EOF'
[Unit]
Description=Restore iptables rules
After=network.target network-online.target
Wants=network-online.target
Before=fail2ban.service

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 5
ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable restore-iptables.service 2>/dev/null || true
    show_ok
    echo -e "\n${YELLOW}🔍 Проверка сохранения...${NC}"
    if [ -f ${IPTABLES_SAVE_FILE} ] && grep -q "DDoS_PROTECT" ${IPTABLES_SAVE_FILE} 2>/dev/null; then
        echo -e "  ${GREEN}✅ Правила сохранены в ${IPTABLES_SAVE_FILE}${NC}"
    else
        echo -e "  ${RED}❌ Правила НЕ сохранены!${NC}"
        ERRORS_FOUND=1
    fi
    echo -e "\n${GREEN}✅ Автозагрузка настроена!${NC}"
}

create_backup() {
    print_title "📦 СОЗДАНИЕ БЭКАПА"
    show_progress "Сохраняем правила iptables"
    iptables-save > "$BACKUP_DIR/iptables.rules" 2>/dev/null || true
    show_ok
    show_progress "Сохраняем настройки ядра"
    cp /etc/sysctl.conf "$BACKUP_DIR/sysctl.conf" 2>/dev/null || true
    show_ok
    if command -v ufw &> /dev/null; then
        show_progress "Сохраняем конфигурацию UFW"
        ufw status verbose > "$BACKUP_DIR/ufw_status.txt" 2>/dev/null || true
        cp /etc/ufw/ufw.conf "$BACKUP_DIR/" 2>/dev/null || true
        cp /etc/default/ufw "$BACKUP_DIR/ufw_default" 2>/dev/null || true
        show_ok
    fi
    echo -e "\n${GREEN}✅ Бэкап создан: ${WHITE}$BACKUP_DIR${NC}"
}

restore_backup() {
    print_title "⚠️  ПОЛНЫЙ ОТКАТ НАСТРОЕК"
    
    if [ -d "/root/ddos_backup" ]; then
        BACKUPS=($(ls -td /root/ddos_backup/backup_* 2>/dev/null || true))
    else
        BACKUPS=($(ls -td /root/ddos_backup_* 2>/dev/null || true))
    fi
    
    if [ ${#BACKUPS[@]} -eq 0 ]; then
        print_error "Бэкапы не найдены!"
        exit 1
    fi
    echo -e "\n${YELLOW}📁 Найдены бэкапы:${NC}"
    for i in "${!BACKUPS[@]}"; do
        echo -e "  ${WHITE}[$i]${NC} ${BACKUPS[$i]}"
    done
    echo -e "\n${WHITE}Выберите бэкап для восстановления:${NC}"
    echo -e "  ${YELLOW}0${NC} - Последний бэкап (по умолчанию)"
    read -p "Ваш выбор [0-${#BACKUPS[@]}] (0 = последний): " choice
    if [ -z "$choice" ] || [ "$choice" == "0" ]; then
        LATEST_BACKUP="${BACKUPS[0]}"
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -lt "${#BACKUPS[@]}" ]; then
        LATEST_BACKUP="${BACKUPS[$choice]}"
    else
        echo -e "${RED}❌ Неверный выбор! Использую последний бэкап.${NC}"
        LATEST_BACKUP="${BACKUPS[0]}"
    fi
    echo -e "\n${YELLOW}📁 Выбран бэкап: ${WHITE}$LATEST_BACKUP${NC}"
    echo -e "${RED}⚠️  Это восстановит ВСЕ настройки к состоянию на момент создания бэкапа!${NC}"
    read -p "Продолжить? (y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}❌ Отмена.${NC}"
        exit 0
    fi
    print_title "🔄 ВОССТАНОВЛЕНИЕ"
    show_progress "Удаляем правила DDoS_PROTECT"
    iptables -D INPUT -j DDoS_PROTECT 2>/dev/null || true
    iptables -F DDoS_PROTECT 2>/dev/null || true
    iptables -X DDoS_PROTECT 2>/dev/null || true
    show_ok
    show_progress "Удаляем правила OUTGOING_LIMIT"
    iptables -D OUTPUT -j OUTGOING_LIMIT 2>/dev/null || true
    iptables -F OUTGOING_LIMIT 2>/dev/null || true
    iptables -X OUTGOING_LIMIT 2>/dev/null || true
    show_ok
    show_progress "Восстанавливаем iptables"
    if [ -f "$LATEST_BACKUP/iptables.rules" ]; then
        iptables-restore < "$LATEST_BACKUP/iptables.rules" 2>/dev/null || true
    fi
    show_ok
    show_progress "Восстанавливаем sysctl"
    if [ -f "$LATEST_BACKUP/sysctl.conf" ]; then
        cp "$LATEST_BACKUP/sysctl.conf" /etc/sysctl.conf 2>/dev/null || true
    fi
    show_ok
    if command -v ufw &> /dev/null; then
        show_progress "Восстанавливаем UFW"
        if [ -f "$LATEST_BACKUP/ufw.conf" ]; then
            cp "$LATEST_BACKUP/ufw.conf" /etc/ufw/ufw.conf 2>/dev/null || true
        fi
        if [ -f "$LATEST_BACKUP/ufw_default" ]; then
            cp "$LATEST_BACKUP/ufw_default" /etc/default/ufw 2>/dev/null || true
        fi
        ufw reload > /dev/null 2>&1
        show_ok
    fi
    show_progress "Перезапускаем сервисы"
    restart_ssh
    systemctl restart ufw 2>/dev/null || true
    systemctl restart nginx 2>/dev/null || true
    systemctl restart fail2ban 2>/dev/null || true
    systemctl restart xray 2>/dev/null || true
    systemctl restart 3x-ui 2>/dev/null || true
    show_ok
    print_success "ВОССТАНОВЛЕНИЕ ЗАВЕРШЕНО!"
    echo -e "\n${YELLOW}Текущее состояние UFW:${NC}"
    ufw status verbose 2>/dev/null || echo -e "  ${RED}UFW не установлен${NC}"
    echo -e "\n${GREEN}✅ Восстановлен бэкап: ${WHITE}$LATEST_BACKUP${NC}"
}

check_ssh() {
    if iptables -L DDoS_PROTECT -n 2>/dev/null | grep -q "dpt:${SSH_PORT}"; then
        echo -e "  ${GREEN}✅ Защищён (порт ${SSH_PORT})${NC}"
        return 0
    else
        echo -e "  ${RED}❌ НЕ защищён!${NC}"
        return 1
    fi
}

check_http() {
    if iptables -L DDoS_PROTECT -n 2>/dev/null | grep -q "dpt:80"; then
        echo -e "  ${GREEN}✅ БЕЗ ОГРАНИЧЕНИЙ${NC}"
        return 0
    else
        echo -e "  ${RED}❌ НЕТ ПРАВИЛ!${NC}"
        return 1
    fi
}

check_https() {
    if iptables -L DDoS_PROTECT -n 2>/dev/null | grep -q "dpt:443"; then
        echo -e "  ${GREEN}✅ БЕЗ ОГРАНИЧЕНИЙ${NC}"
        return 0
    else
        echo -e "  ${RED}❌ НЕТ ПРАВИЛ!${NC}"
        return 1
    fi
}

# ===================================================================
# ФУНКЦИЯ: УПРАВЛЕНИЕ IPV6 (БЕЗОПАСНАЯ)
# ===================================================================
manage_ipv6() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}    🌐 БЕЗОПАСНОЕ УПРАВЛЕНИЕ IPV6${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""

    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[ОШИБКА]${NC} Пожалуйста, запустите скрипт от root (sudo)."
        return 1
    fi

    echo -e "${BLUE}[ИНФО]${NC} Выполняется безопасная проверка состояния IPv6..."
    echo ""

    declare -A IPV6_CHECKS
    
    if grep -qE "^[[:space:]]*net.ipv6.conf.all.disable_ipv6[[:space:]]*=[[:space:]]*1" /etc/sysctl.conf 2>/dev/null; then
        IPV6_CHECKS["sysctl.conf"]="отключён"
    else
        IPV6_CHECKS["sysctl.conf"]="включён"
    fi
    
    if grep -rqE "^[[:space:]]*net.ipv6.conf.all.disable_ipv6[[:space:]]*=[[:space:]]*1" /etc/sysctl.d/ 2>/dev/null; then
        IPV6_CHECKS["sysctl.d"]="отключён"
    else
        IPV6_CHECKS["sysctl.d"]="включён"
    fi
    
    if grep -qE "^[[:space:]]*IPV6[[:space:]]*=[[:space:]]*no" /etc/default/ufw 2>/dev/null; then
        IPV6_CHECKS["UFW"]="отключён"
    else
        IPV6_CHECKS["UFW"]="включён"
    fi
    
    if grep -rqE "^[[:space:]]*blacklist[[:space:]]+ipv6" /etc/modprobe.d/ 2>/dev/null; then
        IPV6_CHECKS["modprobe"]="отключён"
    else
        IPV6_CHECKS["modprobe"]="включён"
    fi
    
    KERNEL_IPV6=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "0")
    if [ "$KERNEL_IPV6" == "1" ]; then
        IPV6_CHECKS["kernel"]="отключён"
    else
        IPV6_CHECKS["kernel"]="включён"
    fi
    
    IPV6_ADDR_COUNT=$(ip -6 addr show 2>/dev/null | awk '/inet6/ {n++} END {print n+0}')
    [[ "$IPV6_ADDR_COUNT" =~ ^[0-9]+$ ]] || IPV6_ADDR_COUNT=0
    if [ "$IPV6_ADDR_COUNT" -gt 0 ]; then
        IPV6_CHECKS["addresses"]="есть ($IPV6_ADDR_COUNT)"
    else
        IPV6_CHECKS["addresses"]="нет"
    fi

    echo -e "${BLUE}📋 РЕЗУЛЬТАТЫ БЕЗОПАСНОЙ ПРОВЕРКИ:${NC}"
    echo ""
    echo -e "  ${WHITE}Проверка${NC}                           ${WHITE}Статус${NC}"
    echo -e "  ${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    for key in "sysctl.conf" "sysctl.d" "UFW" "modprobe" "kernel" "addresses"; do
        status="${IPV6_CHECKS[$key]}"
        if [[ "$status" == "включён" ]] || [[ "$status" == "есть"* ]]; then
            color="$GREEN"
            symbol="✅"
        elif [[ "$status" == "отключён" ]]; then
            color="$RED"
            symbol="❌"
        else
            color="$YELLOW"
            symbol="⚠️"
        fi
        printf "  ${color}%-30s${NC} ${color}%s %s${NC}\n" "$key" "$symbol" "$status"
    done
    
    echo ""

    # Итог определяем только по фактическому состоянию ядра,
    # интерфейсов, IPv6-адресов и маршрутов. UFW, sysctl-файлы и
    # modprobe показываются отдельно и не подменяют реальное состояние.
    KERNEL_IPV6=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "1")
    IPV6_ENABLED_INTERFACES=0
    IPV6_DISABLED_INTERFACES=0
    IPV6_INTERFACE_COUNT=0
    while IFS= read -r iface; do
        [ -n "$iface" ] || continue
        [ "$iface" = "lo" ] && continue
        IPV6_INTERFACE_COUNT=$((IPV6_INTERFACE_COUNT + 1))
        iface_state=$(sysctl -n "net.ipv6.conf.${iface}.disable_ipv6" 2>/dev/null || echo "0")
        if [ "$iface_state" = "1" ]; then
            IPV6_DISABLED_INTERFACES=$((IPV6_DISABLED_INTERFACES + 1))
        else
            IPV6_ENABLED_INTERFACES=$((IPV6_ENABLED_INTERFACES + 1))
        fi
    done < <(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1)
    IPV6_ROUTE_COUNT=$(ip -6 route show 2>/dev/null | awk 'NF {n++} END {print n+0}')
    [[ "$IPV6_ROUTE_COUNT" =~ ^[0-9]+$ ]] || IPV6_ROUTE_COUNT=0

    if [ "$KERNEL_IPV6" = "1" ] && [ "$IPV6_ENABLED_INTERFACES" -eq 0 ]; then
        echo -e "${RED}❌ ОБЩЕЕ СОСТОЯНИЕ: IPv6 отключён на уровне ядра и интерфейсов${NC}"
        CURRENT_STATUS="disabled"
    elif [ "$KERNEL_IPV6" = "1" ] || [ "$IPV6_DISABLED_INTERFACES" -gt 0 ]; then
        echo -e "${YELLOW}⚠️  ОБЩЕЕ СОСТОЯНИЕ: IPv6 отключён частично; проверьте интерфейсы${NC}"
        CURRENT_STATUS="partial"
    elif [ "$IPV6_ENABLED_INTERFACES" -gt 0 ] && [ "${IPV6_CHECKS[addresses]}" != "нет" ]; then
        echo -e "${GREEN}✅ ОБЩЕЕ СОСТОЯНИЕ: IPv6 фактически работает${NC}"
        CURRENT_STATUS="enabled"
    else
        echo -e "${YELLOW}⚠️  ОБЩЕЕ СОСТОЯНИЕ: IPv6 включён, но активных адресов нет${NC}"
        CURRENT_STATUS="partial"
    fi
    echo -e "  ${WHITE}Фактические маршруты IPv6:${NC} ${IPV6_ROUTE_COUNT}"
    echo ""

    echo -e "${CYAN}Выберите действие:${NC}"
    echo ""
    if [ "$CURRENT_STATUS" == "enabled" ] || [ "$CURRENT_STATUS" == "partial" ]; then
        echo -e "  ${RED}[1]${NC} 🔴 ОТКЛЮЧИТЬ IPv6 (безопасно, без GRUB)"
    else
        echo -e "  ${GREEN}[1]${NC} ✅ ВКЛЮЧИТЬ IPv6 (безопасно, без GRUB)"
    fi
    echo -e "  ${BLUE}[2]${NC} 🔄 Перезагрузить сеть (применить изменения)"
    echo -e "  ${YELLOW}[3]${NC} 📋 Показать ДЕТАЛЬНУЮ информацию об IPv6"
    echo -e "  ${MAGENTA}[4]${NC} 🔧 Ручное редактирование конфигов"
    echo -e "  ${RED}[5]${NC} ❌ Выйти"
    echo ""
    read -p "Ваш выбор [1-5]: " ipv6_choice

    case "$ipv6_choice" in
        1)
            if [ "$CURRENT_STATUS" == "enabled" ] || [ "$CURRENT_STATUS" == "partial" ]; then
                ipv6_disable_safe
            else
                ipv6_enable_safe
            fi
            ;;
        2)
            echo -e "\n${BLUE}[ИНФО]${NC} Перезагрузка сетевых служб..."
            systemctl restart networking 2>/dev/null || systemctl restart systemd-networkd 2>/dev/null || true
            echo -e "${GREEN}✅ Сеть перезагружена${NC}"
            read -p "Нажмите ENTER, чтобы продолжить..."
            manage_ipv6
            ;;
        3)
            show_ipv6_detailed_info
            ;;
        4)
            ipv6_manual_edit
            ;;
        5|*)
            echo -e "\n${YELLOW}👋 Выход.${NC}"
            return 0
            ;;
    esac
}

ipv6_disable_safe() {
    echo -e "\n${RED}🔴 БЕЗОПАСНОЕ ОТКЛЮЧЕНИЕ IPV6...${NC}"
    echo -e "${YELLOW}⚠️  ВНИМАНИЕ: Это отключит IPv6 безопасными способами (без изменения GRUB).${NC}"
    echo -e "${YELLOW}   Если вы используете IPv6 для доступа к серверу, вы можете потерять связь!${NC}"
    echo ""
    read -p "Продолжить? Введите YES: " confirm
    if [ "$confirm" != "YES" ]; then
        echo -e "${YELLOW}Отмена.${NC}"
        read -p "Нажмите ENTER, чтобы продолжить..."
        manage_ipv6
        return 0
    fi

    BACKUP_DIR_IPV6="/root/ipv6_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR_IPV6"
    echo -e "${GREEN}[ИНФО]${NC} Резервная копия создана в: $BACKUP_DIR_IPV6"

    cp /etc/sysctl.conf "$BACKUP_DIR_IPV6/sysctl.conf" 2>/dev/null || true
    sed -i '/^net.ipv6.conf.all.disable_ipv6/d' /etc/sysctl.conf 2>/dev/null || true
    sed -i '/^net.ipv6.conf.default.disable_ipv6/d' /etc/sysctl.conf 2>/dev/null || true
    echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
    echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf

    for f in /etc/sysctl.d/*.conf; do
        [ -f "$f" ] || continue
        cp "$f" "$BACKUP_DIR_IPV6/" 2>/dev/null || true
        sed -i '/^net.ipv6.conf.all.disable_ipv6/d' "$f" 2>/dev/null || true
        sed -i '/^net.ipv6.conf.default.disable_ipv6/d' "$f" 2>/dev/null || true
    done
    echo "net.ipv6.conf.all.disable_ipv6 = 1" > /etc/sysctl.d/99-disable-ipv6.conf
    echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.d/99-disable-ipv6.conf

    cp /etc/default/ufw "$BACKUP_DIR_IPV6/ufw" 2>/dev/null || true
    sed -i 's/IPV6=yes/IPV6=no/g' /etc/default/ufw 2>/dev/null || echo "IPV6=no" >> /etc/default/ufw

    cp /etc/modprobe.d/blacklist.conf "$BACKUP_DIR_IPV6/blacklist.conf" 2>/dev/null || touch "$BACKUP_DIR_IPV6/blacklist.conf"
    echo "Модуль IPv6 не блокируется через modprobe; управление выполняется через sysctl."

    sysctl -p 2>/dev/null || true
    sysctl -p /etc/sysctl.d/99-disable-ipv6.conf 2>/dev/null || true

    while IFS= read -r iface; do
        [ -n "$iface" ] || continue
        iface=${iface%%@*}
        sysctl -w "net.ipv6.conf.${iface}.disable_ipv6=1" 2>/dev/null || true
    done < <(ip -o link show 2>/dev/null | awk -F': ' '{print $2}')

    echo -e "\n${GREEN}✅ IPv6 БЕЗОПАСНО ОТКЛЮЧЁН!${NC}"
    echo -e "${BLUE}📌 Для полного применения изменений рекомендуется перезагрузить сервер:${NC}"
    echo -e "  ${WHITE}sudo reboot${NC}"
    echo -e "${YELLOW}📌 Если что-то пошло не так, восстановите:${NC}"
    echo -e "  ${WHITE}sudo cp -r $BACKUP_DIR_IPV6/* /etc/ && sudo sysctl -p${NC}"
    echo ""
    read -p "Нажмите ENTER, чтобы продолжить..."
    manage_ipv6
}

ipv6_enable_safe() {
    echo -e "\n${GREEN}✅ БЕЗОПАСНОЕ ВКЛЮЧЕНИЕ IPV6...${NC}"

    BACKUP_DIR_IPV6="/root/ipv6_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR_IPV6"
    echo -e "${GREEN}[ИНФО]${NC} Резервная копия создана в: $BACKUP_DIR_IPV6"

    cp /etc/sysctl.conf "$BACKUP_DIR_IPV6/sysctl.conf" 2>/dev/null || true
    sed -i '/^net.ipv6.conf.all.disable_ipv6/d' /etc/sysctl.conf 2>/dev/null || true
    sed -i '/^net.ipv6.conf.default.disable_ipv6/d' /etc/sysctl.conf 2>/dev/null || true
    echo "net.ipv6.conf.all.disable_ipv6 = 0" >> /etc/sysctl.conf
    echo "net.ipv6.conf.default.disable_ipv6 = 0" >> /etc/sysctl.conf

    for f in /etc/sysctl.d/*.conf; do
        [ -f "$f" ] || continue
        cp "$f" "$BACKUP_DIR_IPV6/" 2>/dev/null || true
        sed -i '/^net.ipv6.conf.all.disable_ipv6/d' "$f" 2>/dev/null || true
        sed -i '/^net.ipv6.conf.default.disable_ipv6/d' "$f" 2>/dev/null || true
    done
    rm -f /etc/sysctl.d/99-disable-ipv6.conf 2>/dev/null || true

    cp /etc/default/ufw "$BACKUP_DIR_IPV6/ufw" 2>/dev/null || true
    sed -i 's/IPV6=no/IPV6=yes/g' /etc/default/ufw 2>/dev/null || echo "IPV6=yes" >> /etc/default/ufw

    cp /etc/modprobe.d/blacklist.conf "$BACKUP_DIR_IPV6/blacklist.conf" 2>/dev/null || true
    # Удаляем только точную устаревшую строку, которую мог добавить старый скрипт.
    # Новый режим IPv6 никогда не добавляет blacklist сам.
    sed -i -E '/^[[:space:]]*blacklist[[:space:]]+ipv6[[:space:]]*$/d' /etc/modprobe.d/blacklist.conf 2>/dev/null || true
    echo "Модуль IPv6 не используется для управления; состояние задаётся через sysctl."

    sysctl -p 2>/dev/null || true

    while IFS= read -r iface; do
        [ -n "$iface" ] || continue
        iface=${iface%%@*}
        sysctl -w "net.ipv6.conf.${iface}.disable_ipv6=0" 2>/dev/null || true
    done < <(ip -o link show 2>/dev/null | awk -F': ' '{print $2}')

    echo -e "\n${GREEN}✅ IPv6 БЕЗОПАСНО ВКЛЮЧЁН!${NC}"
    echo -e "${BLUE}📌 Для полного применения изменений рекомендуется перезагрузить сервер:${NC}"
    echo -e "  ${WHITE}sudo reboot${NC}"
    echo -e "${YELLOW}📌 Если что-то пошло не так, восстановите:${NC}"
    echo -e "  ${WHITE}sudo cp -r $BACKUP_DIR_IPV6/* /etc/ && sudo sysctl -p${NC}"
    echo ""
    read -p "Нажмите ENTER, чтобы продолжить..."
    manage_ipv6
}

show_ipv6_detailed_info() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}    📋 ДЕТАЛЬНАЯ ИНФОРМАЦИЯ О IPV6${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""

    echo -e "${BLUE}📌 ПАРАМЕТРЫ ЯДРА:${NC}"
    echo -e "  ${WHITE}net.ipv6.conf.all.disable_ipv6:${NC} $(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 'недоступно')"
    echo -e "  ${WHITE}net.ipv6.conf.default.disable_ipv6:${NC} $(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || echo 'недоступно')"
    echo ""

    echo -e "${BLUE}📌 СОСТОЯНИЕ ИНТЕРФЕЙСОВ:${NC}"
    for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v lo); do
        status=$(sysctl -n net.ipv6.conf.$iface.disable_ipv6 2>/dev/null || echo "0")
        if [ "$status" == "1" ]; then
            echo -e "  ${RED}• $iface: IPv6 ОТКЛЮЧЁН${NC}"
        else
            echo -e "  ${GREEN}• $iface: IPv6 ВКЛЮЧЁН${NC}"
        fi
    done
    echo ""

    echo -e "${BLUE}📌 ФАЙЛЫ КОНФИГУРАЦИИ:${NC}"
    
    echo -e "  ${WHITE}/etc/sysctl.conf:${NC}"
    grep -E "^[[:space:]]*net.ipv6" /etc/sysctl.conf 2>/dev/null | while read line; do
        echo -e "    ${CYAN}•${NC} $line"
    done || echo -e "    ${YELLOW}• Нет настроек IPv6${NC}"
    
    echo -e "  ${WHITE}/etc/sysctl.d/:${NC}"
    grep -rE "^[[:space:]]*net.ipv6" /etc/sysctl.d/ 2>/dev/null | while read line; do
        echo -e "    ${CYAN}•${NC} $line"
    done || echo -e "    ${YELLOW}• Нет настроек IPv6${NC}"
    
    echo -e "  ${WHITE}/etc/default/ufw:${NC}"
    grep "^IPV6" /etc/default/ufw 2>/dev/null | while read line; do
        echo -e "    ${CYAN}•${NC} $line"
    done || echo -e "    ${YELLOW}• Нет настроек IPv6${NC}"
    
    echo -e "  ${WHITE}/etc/modprobe.d/:${NC}"
    grep -r "ipv6" /etc/modprobe.d/ 2>/dev/null | while read line; do
        echo -e "    ${CYAN}•${NC} $line"
    done || echo -e "    ${YELLOW}• Нет настроек IPv6${NC}"
    echo ""

    echo -e "${BLUE}📌 IPV6-АДРЕСА:${NC}"
    ip -6 addr show 2>/dev/null | grep -E "inet6" | while read line; do
        echo -e "  ${GREEN}•${NC} $line"
    done
    if [ $? -ne 0 ]; then
        echo -e "  ${YELLOW}⚠️  IPv6-адреса не найдены${NC}"
    fi
    echo ""

    echo -e "${BLUE}📌 МАРШРУТЫ IPV6:${NC}"
    ip -6 route show 2>/dev/null | while read line; do
        echo -e "  ${GREEN}•${NC} $line"
    done
    if [ $? -ne 0 ]; then
        echo -e "  ${YELLOW}⚠️  Маршруты IPv6 не найдены${NC}"
    fi
    echo ""

    echo -e "${BLUE}📌 ДИАГНОСТИКА:${NC}"
    if ping6 -c 1 ::1 &>/dev/null; then
        echo -e "  ${GREEN}✅ IPv6 loopback (::1) работает${NC}"
    else
        echo -e "  ${RED}❌ IPv6 loopback (::1) не отвечает${NC}"
    fi

    if ping6 -c 1 2001:4860:4860::8888 &>/dev/null 2>&1; then
        echo -e "  ${GREEN}✅ IPv6 интернет-доступ есть (ping Google DNS)${NC}"
    else
        echo -e "  ${YELLOW}⚠️  IPv6 интернет-доступ отсутствует${NC}"
    fi
    echo ""

    echo -e "${BLUE}📌 СТАТИСТИКА:${NC}"
    echo -e "  ${WHITE}Всего IPv6-адресов:${NC} $(ip -6 addr show 2>/dev/null | grep -c "inet6" || echo "0")"
    echo -e "  ${WHITE}IPv6 маршрутов:${NC} $(ip -6 route show 2>/dev/null | wc -l || echo "0")"
    echo ""

    read -p "Нажмите ENTER, чтобы продолжить..."
    manage_ipv6
}

ipv6_manual_edit() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}    🔧 РУЧНОЕ РЕДАКТИРОВАНИЕ КОНФИГОВ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""

    echo -e "${BLUE}Выберите файл для редактирования:${NC}"
    echo ""
    echo -e "  ${GREEN}[1]${NC} /etc/sysctl.conf"
    echo -e "  ${BLUE}[2]${NC} /etc/default/ufw"
    echo -e "  ${YELLOW}[3]${NC} /etc/sysctl.d/ (папка с конфигами)"
    echo -e "  ${MAGENTA}[4]${NC} /etc/modprobe.d/blacklist.conf"
    echo -e "  ${RED}[5]${NC} Назад"
    echo ""
    read -p "Ваш выбор [1-5]: " edit_choice

    case "$edit_choice" in
        1) nano /etc/sysctl.conf ;;
        2) nano /etc/default/ufw ;;
        3) ls -la /etc/sysctl.d/ && read -p "Нажмите ENTER для редактирования файлов..." && find /etc/sysctl.d/ -name "*.conf" -exec nano {} \+ ;;
        4) nano /etc/modprobe.d/blacklist.conf ;;
        5|*) manage_ipv6 ;;
    esac
    
    if [[ "$edit_choice" =~ ^[1-4]$ ]]; then
        echo -e "\n${GREEN}✅ Файл сохранён${NC}"
        echo -e "${YELLOW}⚠️  Не забудьте применить изменения:${NC}"
        echo -e "  ${WHITE}• sysctl -p${NC}"
        echo -e "  ${WHITE}• ufw reload (если меняли UFW)${NC}"
        read -p "Нажмите ENTER, чтобы продолжить..."
        manage_ipv6
    fi
}

# ===================================================================
# ФУНКЦИЯ: СЕТЕВЫЕ ИНСТРУМЕНТЫ
# ===================================================================
network_tools_menu() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}    🔧 СЕТЕВЫЕ ИНСТРУМЕНТЫ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""

    echo -e "${WHITE}Выберите действие:${NC}"
    echo ""
    echo -e "  ${GREEN}[1]${NC} 📊 Показать все открытые порты"
    echo -e "  ${BLUE}[2]${NC} 🔗 Показать активные соединения"
    echo -e "  ${CYAN}[3]${NC} 🌐 Показать IP-адреса сервера"
    echo -e "  ${MAGENTA}[4]${NC} 🛤️  Трассировка маршрута"
    echo -e "  ${GREEN}[5]${NC} 📡 Проверка DNS"
    echo -e "  ${YELLOW}[6]${NC} 🌍 WHOIS информация"
    echo -e "  ${RED}[7]${NC} 📶 Проверка скорости интернета"
    echo -e "  ${BLUE}[8]${NC} 📊 Статистика сетевых интерфейсов"
    echo -e "  ${CYAN}[9]${NC} 🔍 Проверка доступности хоста"
    echo -e "  ${MAGENTA}[10]${NC} 📋 КОМПЛЕКСНЫЙ ОТЧЁТ"
    echo -e "  ${GREEN}[11]${NC} 🚀 БЫСТРАЯ ДИАГНОСТИКА"
    echo -e "  ${YELLOW}[12]${NC} 📊 ЗАПУСК HTOP (мониторинг процессов)"
    echo -e "  ${RED}[13]${NC} ❌ Назад"
    echo ""
    read -p "Ваш выбор [1-13]: " net_choice

    case "$net_choice" in
        1) network_ports ;;
        2) network_connections ;;
        3) network_ips ;;
        4) network_traceroute ;;
        5) network_dns ;;
        6) network_whois ;;
        7) network_speedtest ;;
        8) network_stats ;;
        9) network_ping ;;
        10) network_full_report ;;
        11) network_quick_diagnostic ;;
        12) run_htop ;;
        13|*) return 0 ;;
    esac
    
    read -p "Нажмите ENTER, чтобы продолжить..."
    network_tools_menu
}

# ===================================================================
# УНИВЕРСАЛЬНЫЕ ФУНКЦИИ-ОБЁРТКИ ДЛЯ СЕТЕВЫХ ИНСТРУМЕНТОВ
# ===================================================================
has_command() {
    command -v "$1" &> /dev/null
}

get_listening_ports() {
    if has_command ss; then
        ss -tulpn 2>/dev/null | grep LISTEN
    elif has_command netstat; then
        netstat -tulpn 2>/dev/null | grep LISTEN
    else
        echo "❌ Нет доступных инструментов для просмотра портов"
        return 1
    fi
}

get_active_connections() {
    if has_command ss; then
        ss -tun 2>/dev/null | grep -E "ESTAB|SYN-SENT|SYN-RECV"
    elif has_command netstat; then
        netstat -tun 2>/dev/null | grep -E "ESTABLISHED|SYN_SENT|SYN_RECV"
    else
        echo "❌ Нет доступных инструментов для просмотра соединений"
        return 1
    fi
}

count_connections() {
    if has_command ss; then
        ss -tn 2>/dev/null | grep ESTAB | wc -l
    elif has_command netstat; then
        netstat -tn 2>/dev/null | grep ESTABLISHED | wc -l
    else
        echo "0"
    fi
}

get_ip_addresses() {
    if has_command ip; then
        ip -4 addr show 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1
    elif has_command ifconfig; then
        ifconfig 2>/dev/null | grep "inet " | awk '{print $2}'
    else
        echo "Не удалось определить IP-адреса"
    fi
}

do_ping() {
    local target="$1"
    local count="${2:-4}"
    if has_command ping; then
        ping -c "$count" -W 2 "$target" 2>/dev/null
    else
        echo "❌ ping не установлен"
    fi
}

do_traceroute() {
    local target="$1"
    if has_command traceroute; then
        traceroute -n "$target" 2>/dev/null
    elif has_command tracepath; then
        tracepath "$target" 2>/dev/null
    else
        echo "❌ traceroute не установлен. Установите: sudo apt install traceroute -y"
    fi
}

do_dns_lookup() {
    local domain="$1"
    if has_command dig; then
        dig "$domain" 2>/dev/null
    elif has_command nslookup; then
        nslookup "$domain" 2>/dev/null
    elif has_command host; then
        host "$domain" 2>/dev/null
    else
        echo "❌ DNS-инструменты не установлены. Установите: sudo apt install dnsutils -y"
    fi
}

do_whois() {
    local domain="$1"
    if has_command whois; then
        whois "$domain" 2>/dev/null
    else
        echo "❌ whois не установлен. Установите: sudo apt install whois -y"
    fi
}

do_speedtest() {
    if has_command speedtest-cli; then
        speedtest-cli --simple 2>/dev/null
    elif has_command speedtest; then
        speedtest --accept-license 2>/dev/null | grep -E "Download|Upload|Ping"
    else
        echo "❌ speedtest не установлен"
        echo ""
        echo "Установите один из вариантов:"
        echo "  sudo apt install speedtest-cli -y"
        echo "  или"
        echo "  curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | sudo bash && sudo apt install speedtest -y"
    fi
}

# ===================================================================
# 1. ОТКРЫТЫЕ ПОРТЫ
# ===================================================================
network_ports() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}    📊 ОТКРЫТЫЕ ПОРТЫ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    
    echo -e "${YELLOW}📌 ВСЕ СЛУШАЮЩИЕ ПОРТЫ (TCP+UDP):${NC}"
    echo ""
    get_listening_ports | while read line; do
        echo -e "  ${GREEN}•${NC} $line"
    done
    
    echo ""
    echo -e "${YELLOW}📌 ПОРТЫ ДОСТУПНЫЕ ИЗВНЕ (0.0.0.0):${NC}"
    echo ""
    if has_command ss; then
        ss -tulpn 2>/dev/null | grep LISTEN | grep "0.0.0.0" | while read line; do
            echo -e "  ${RED}🌐${NC} $line"
        done
    elif has_command netstat; then
        netstat -tulpn 2>/dev/null | grep LISTEN | grep "0.0.0.0" | while read line; do
            echo -e "  ${RED}🌐${NC} $line"
        done
    fi
    if [ $? -ne 0 ]; then
        echo -e "  ${YELLOW}⚠️  Нет портов, доступных извне${NC}"
    fi
    
    echo ""
    echo -e "${YELLOW}📌 UFW СТАТУС:${NC}"
    if has_command ufw; then
        ufw status 2>/dev/null | head -20 || echo -e "  ${RED}❌ UFW не активен${NC}"
    else
        echo -e "  ${RED}❌ UFW не установлен${NC}"
    fi
}

# ===================================================================
# 2. АКТИВНЫЕ СОЕДИНЕНИЯ
# ===================================================================
network_connections() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}    🔗 АКТИВНЫЕ СОЕДИНЕНИЯ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    
    echo -e "${YELLOW}📌 ВСЕ АКТИВНЫЕ TCP-СОЕДИНЕНИЯ:${NC}"
    echo ""
    get_active_connections | while read line; do
        echo -e "  ${GREEN}•${NC} $line"
    done
    if [ -z "$(get_active_connections)" ]; then
        echo -e "  ${YELLOW}⚠️  Активных TCP-соединений нет${NC}"
    fi
    
    echo ""
    echo -e "${YELLOW}📌 ТОП-20 IP ПО КОЛИЧЕСТВУ СОЕДИНЕНИЙ:${NC}"
    echo ""
    if has_command ss; then
        ss -tn 2>/dev/null | grep ESTAB | awk '{print $5}' | cut -d: -f1 | sort | uniq -c | sort -rn | head -20 | while read count ip; do
            if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo -e "  ${WHITE}$count${NC} - ${GREEN}$ip${NC}"
            fi
        done
    elif has_command netstat; then
        netstat -tn 2>/dev/null | grep ESTABLISHED | awk '{print $5}' | cut -d: -f1 | sort | uniq -c | sort -rn | head -20 | while read count ip; do
            if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo -e "  ${WHITE}$count${NC} - ${GREEN}$ip${NC}"
            fi
        done
    fi
    
    echo ""
    echo -e "${YELLOW}📌 ОБЩЕЕ КОЛИЧЕСТВО АКТИВНЫХ СОЕДИНЕНИЙ:${NC}"
    total=$(count_connections)
    echo -e "  ${WHITE}$total${NC}"
}

# ===================================================================
# 3. IP-АДРЕСА
# ===================================================================
network_ips() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}    🌐 IP-АДРЕСА СЕРВЕРА${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    
    echo -e "${YELLOW}📌 ЛОКАЛЬНЫЕ IP-АДРЕСА:${NC}"
    echo ""
    get_ip_addresses | while read ip; do
        echo -e "  ${GREEN}•${NC} $ip"
    done
    
    echo ""
    echo -e "${YELLOW}📌 ВНЕШНИЙ IP-АДРЕС:${NC}"
    external=$(curl -s -4 ifconfig.me 2>/dev/null || curl -s -4 icanhazip.com 2>/dev/null || echo "Не удалось определить")
    echo -e "  ${GREEN}•${NC} $external"
    
    echo ""
    echo -e "${YELLOW}📌 ИМЯ ХОСТА:${NC}"
    echo -e "  ${GREEN}•${NC} $(hostname -f 2>/dev/null || hostname)"
}

# ===================================================================
# 4. TRACEROUTE
# ===================================================================
network_traceroute() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}    🛤️  ТРАССИРОВКА МАРШРУТА${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    
    read -p "Введите IP или домен для traceroute: " target
    
    if [ -z "$target" ]; then
        echo -e "${RED}❌ Цель не указана${NC}"
        return
    fi
    
    echo ""
    echo -e "${YELLOW}📌 ТРАССИРОВКА ДО $target:${NC}"
    echo ""
    do_traceroute "$target" | while read line; do
        echo -e "  ${GREEN}•${NC} $line"
    done
}

# ===================================================================
# 5. DNS
# ===================================================================
network_dns() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}    📡 ПРОВЕРКА DNS${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    
    read -p "Введите домен для проверки DNS: " domain
    
    if [ -z "$domain" ]; then
        echo -e "${RED}❌ Домен не указан${NC}"
        return
    fi
    
    echo ""
    echo -e "${YELLOW}📌 DNS-ЗАПИСИ ДЛЯ $domain:${NC}"
    echo ""
    do_dns_lookup "$domain" | head -30 | while read line; do
        echo -e "  ${GREEN}•${NC} $line"
    done
    
    echo ""
    echo -e "${YELLOW}📌 DNS-СЕРВЕРА СИСТЕМЫ:${NC}"
    echo ""
    cat /etc/resolv.conf 2>/dev/null | grep nameserver | while read line; do
        echo -e "  ${GREEN}•${NC} $line"
    done || echo -e "  ${YELLOW}⚠️  Не найдены DNS-сервера${NC}"
}

# ===================================================================
# 6. WHOIS
# ===================================================================
network_whois() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}    🌍 WHOIS ИНФОРМАЦИЯ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    
    read -p "Введите домен для WHOIS: " domain
    
    if [ -z "$domain" ]; then
        echo -e "${RED}❌ Домен не указан${NC}"
        return
    fi
    
    echo ""
    echo -e "${YELLOW}📌 WHOIS $domain:${NC}"
    echo ""
    do_whois "$domain" | head -40 | while read line; do
        echo -e "  ${GREEN}•${NC} $line"
    done
}

# ===================================================================
# 7. SPEEDTEST
# ===================================================================
network_speedtest() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}    📶 ПРОВЕРКА СКОРОСТИ ИНТЕРНЕТА${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    
    echo -e "${YELLOW}⏳ Выполняется тест скорости... (это может занять 30-60 секунд)${NC}"
    echo ""
    do_speedtest | while read line; do
        echo -e "  ${GREEN}•${NC} $line"
    done
}

# ===================================================================
# 8. СТАТИСТИКА ИНТЕРФЕЙСОВ
# ===================================================================
network_stats() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}    📊 СТАТИСТИКА СЕТЕВЫХ ИНТЕРФЕЙСОВ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    
    echo -e "${YELLOW}📌 ВСЕ ИНТЕРФЕЙСЫ:${NC}"
    echo ""
    if has_command ip; then
        ip -s link 2>/dev/null | while read line; do
            echo -e "  ${GREEN}•${NC} $line"
        done
    elif has_command ifconfig; then
        ifconfig 2>/dev/null | while read line; do
            echo -e "  ${GREEN}•${NC} $line"
        done
    else
        echo -e "  ${RED}❌ Нет доступных инструментов для просмотра интерфейсов${NC}"
    fi
    
    echo ""
    echo -e "${YELLOW}📌 АКТИВНЫЕ ИНТЕРФЕЙСЫ:${NC}"
    echo ""
    if has_command ip; then
        ip -o link show 2>/dev/null | grep UP | while read line; do
            echo -e "  ${GREEN}✅${NC} $line"
        done
    elif has_command ifconfig; then
        ifconfig 2>/dev/null | grep -E "^[a-z]" | grep -v LOOPBACK | while read line; do
            echo -e "  ${GREEN}✅${NC} $line"
        done
    fi
}

# ===================================================================
# 9. PING
# ===================================================================
network_ping() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}    🔍 ПРОВЕРКА ДОСТУПНОСТИ ХОСТА${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    
    read -p "Введите IP или домен для ping: " target
    
    if [ -z "$target" ]; then
        echo -e "${RED}❌ Цель не указана${NC}"
        return
    fi
    
    echo ""
    echo -e "${YELLOW}📌 PING $target:${NC}"
    echo ""
    do_ping "$target" 4 | while read line; do
        echo -e "  ${GREEN}•${NC} $line"
    done
}

# ===================================================================
# 10. КОМПЛЕКСНЫЙ ОТЧЁТ
# ===================================================================
network_full_report() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}    📋 КОМПЛЕКСНЫЙ СЕТЕВОЙ ОТЧЁТ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    
    echo -e "${YELLOW}📌 IP-АДРЕСА:${NC}"
    get_ip_addresses | while read ip; do
        echo -e "  ${GREEN}•${NC} $ip"
    done
    
    echo ""
    echo -e "${YELLOW}📌 ВНЕШНИЙ IP:${NC}"
    external=$(curl -s -4 ifconfig.me 2>/dev/null || echo "Не определен")
    echo -e "  ${GREEN}•${NC} $external"
    
    echo ""
    echo -e "${YELLOW}📌 ОТКРЫТЫЕ ПОРТЫ (0.0.0.0):${NC}"
    if has_command ss; then
        ss -tulpn 2>/dev/null | grep LISTEN | grep "0.0.0.0" | awk '{print $5}' | cut -d: -f2 | sort -n | uniq | while read port; do
            echo -e "  ${RED}🌐${NC} порт $port"
        done
    elif has_command netstat; then
        netstat -tulpn 2>/dev/null | grep LISTEN | grep "0.0.0.0" | awk '{print $4}' | cut -d: -f2 | sort -n | uniq | while read port; do
            echo -e "  ${RED}🌐${NC} порт $port"
        done
    fi
    if [ $? -ne 0 ]; then
        echo -e "  ${YELLOW}⚠️  Нет портов, доступных извне${NC}"
    fi
    
    echo ""
    echo -e "${YELLOW}📌 АКТИВНЫХ СОЕДИНЕНИЙ:${NC}"
    total=$(count_connections)
    echo -e "  ${WHITE}$total${NC}"
    
    echo ""
    echo -e "${YELLOW}📌 ТОП-5 IP ПО СОЕДИНЕНИЯМ:${NC}"
    if has_command ss; then
        ss -tn 2>/dev/null | grep ESTAB | awk '{print $5}' | cut -d: -f1 | sort | uniq -c | sort -rn | head -5 | while read count ip; do
            if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo -e "  ${WHITE}$count${NC} - ${GREEN}$ip${NC}"
            fi
        done
    elif has_command netstat; then
        netstat -tn 2>/dev/null | grep ESTABLISHED | awk '{print $5}' | cut -d: -f1 | sort | uniq -c | sort -rn | head -5 | while read count ip; do
            if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo -e "  ${WHITE}$count${NC} - ${GREEN}$ip${NC}"
            fi
        done
    fi
    
    echo ""
    echo -e "${YELLOW}📌 СТАТУС UFW:${NC}"
    if has_command ufw; then
        ufw status 2>/dev/null | head -5 || echo -e "  ${RED}❌ UFW не активен${NC}"
    else
        echo -e "  ${RED}❌ UFW не установлен${NC}"
    fi
    
    echo ""
    echo -e "${YELLOW}📌 СТАТУС SSH:${NC}"
    if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
        echo -e "  ${GREEN}✅ SSH работает${NC}"
        if has_command ss; then
            port=$(ss -tulpn 2>/dev/null | grep LISTEN | grep -E "sshd|ssh" | awk '{print $5}' | cut -d: -f2 | head -1)
        elif has_command netstat; then
            port=$(netstat -tulpn 2>/dev/null | grep LISTEN | grep -E "sshd|ssh" | awk '{print $4}' | cut -d: -f2 | head -1)
        fi
        echo -e "  ${WHITE}Порт:${NC} $port"
    else
        echo -e "  ${RED}❌ SSH не работает${NC}"
    fi
    
    echo ""
    echo -e "${YELLOW}📌 СТАТУС NGINX:${NC}"
    if systemctl is-active --quiet nginx 2>/dev/null; then
        echo -e "  ${GREEN}✅ Nginx работает${NC}"
    else
        echo -e "  ${RED}❌ Nginx не работает${NC}"
    fi
    
    echo ""
    echo -e "${YELLOW}📌 ИМЯ ХОСТА:${NC}"
    echo -e "  ${GREEN}•${NC} $(hostname -f 2>/dev/null || hostname)"
    
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✅ ОТЧЁТ ГОТОВ!${NC}"
}

# ===================================================================
# 11. БЫСТРАЯ ДИАГНОСТИКА
# ===================================================================
network_quick_diagnostic() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}    🚀 БЫСТРАЯ ДИАГНОСТИКА${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    
    echo -e "${YELLOW}📌 ВНЕШНИЙ IP:${NC}"
    external=$(curl -s -4 ifconfig.me 2>/dev/null || echo "Не определен")
    echo -e "  ${GREEN}$external${NC}"
    
    echo ""
    echo -e "${YELLOW}📌 ОТКРЫТЫЕ ПОРТЫ (0.0.0.0):${NC}"
    if has_command ss; then
        ports=$(ss -tulpn 2>/dev/null | grep LISTEN | grep "0.0.0.0" | awk '{print $5}' | cut -d: -f2 | sort -n | uniq | tr '\n' ' ')
    elif has_command netstat; then
        ports=$(netstat -tulpn 2>/dev/null | grep LISTEN | grep "0.0.0.0" | awk '{print $4}' | cut -d: -f2 | sort -n | uniq | tr '\n' ' ')
    fi
    echo -e "  ${GREEN}$ports${NC}"
    
    echo ""
    echo -e "${YELLOW}📌 АКТИВНЫХ СОЕДИНЕНИЙ:${NC}"
    total=$(count_connections)
    echo -e "  ${GREEN}$total${NC}"
    
    echo ""
    echo -e "${YELLOW}📌 UFW:${NC}"
    if has_command ufw; then
        ufw_status=$(ufw status 2>/dev/null | grep "Status:" | awk '{print $2}')
        if [ "$ufw_status" == "active" ]; then
            echo -e "  ${GREEN}✅ Активен${NC}"
        else
            echo -e "  ${RED}❌ Неактивен${NC}"
        fi
    else
        echo -e "  ${RED}❌ Не установлен${NC}"
    fi
    
    echo ""
    echo -e "${YELLOW}📌 SSH:${NC}"
    if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
        if has_command ss; then
            port=$(ss -tulpn 2>/dev/null | grep LISTEN | grep -E "sshd|ssh" | awk '{print $5}' | cut -d: -f2 | head -1)
        elif has_command netstat; then
            port=$(netstat -tulpn 2>/dev/null | grep LISTEN | grep -E "sshd|ssh" | awk '{print $4}' | cut -d: -f2 | head -1)
        fi
        echo -e "  ${GREEN}✅ Работает (порт $port)${NC}"
    else
        echo -e "  ${RED}❌ Не работает${NC}"
    fi
    
    echo ""
    echo -e "${YELLOW}📌 NGINX:${NC}"
    if systemctl is-active --quiet nginx 2>/dev/null; then
        echo -e "  ${GREEN}✅ Работает${NC}"
    else
        echo -e "  ${RED}❌ Не работает${NC}"
    fi
    
    echo ""
    echo -e "${YELLOW}📌 ЗАГРУЗКА СИСТЕМЫ:${NC}"
    uptime | awk -F'load average:' '{print $2}' | while read load; do
        echo -e "  ${GREEN}$load${NC}"
    done
    
    echo ""
    echo -e "${YELLOW}📌 ДОСТУПНОСТЬ ИНТЕРНЕТА:${NC}"
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        echo -e "  ${GREEN}✅ Интернет доступен${NC}"
    else
        echo -e "  ${RED}❌ Интернет НЕ доступен${NC}"
    fi
    
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✅ ДИАГНОСТИКА ЗАВЕРШЕНА!${NC}"
}

# ===================================================================
# 12. ЗАПУСК HTOP
# ===================================================================
run_htop() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}    📊 ЗАПУСК HTOP${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""

    if ! command -v htop &> /dev/null; then
        echo -e "${YELLOW}⚠️  htop не установлен!${NC}"
        echo -e "${BLUE}[ИНФО]${NC} htop - это интерактивный менеджер процессов."
        echo ""
        echo -e "${CYAN}Хотите установить htop?${NC}"
        echo -e "  ${GREEN}[y]${NC} — Да, установить"
        echo -e "  ${RED}[n]${NC} — Нет, пропустить"
        echo ""
        read -p "Ваш выбор (y/n): " install_htop
        
        if [[ "$install_htop" =~ ^[Yy]$ ]]; then
            echo -e "\n${BLUE}[ИНФО]${NC} Установка htop..."
            sudo apt-get update -qq 2>/dev/null || true
            sudo apt-get install -y htop 2>/dev/null || {
                echo -e "${RED}❌ Не удалось установить htop${NC}"
                echo -e "${YELLOW}Установите вручную: sudo apt install htop -y${NC}"
                read -p "Нажмите ENTER, чтобы продолжить..."
                return 1
            }
            echo -e "${GREEN}✅ htop успешно установлен!${NC}"
            echo ""
        else
            echo -e "${YELLOW}Пропускаем.${NC}"
            read -p "Нажмите ENTER, чтобы продолжить..."
            return 0
        fi
    fi

    echo -e "\n${BLUE}[ИНФО]${NC} Запуск htop..."
    echo -e "${YELLOW}📌 Управление:${NC}"
    echo -e "  ${WHITE}F1${NC} - справка"
    echo -e "  ${WHITE}F2${NC} - настройки"
    echo -e "  ${WHITE}F3${NC} - поиск"
    echo -e "  ${WHITE}F4${NC} - фильтр"
    echo -e "  ${WHITE}F5${NC} - дерево процессов"
    echo -e "  ${WHITE}F6${NC} - сортировка"
    echo -e "  ${WHITE}F9${NC} - убить процесс"
    echo -e "  ${WHITE}F10${NC} - выход"
    echo -e "  ${WHITE}q${NC} - выход"
    echo ""
    echo -e "${YELLOW}Нажмите ENTER, чтобы запустить htop...${NC}"
    read -r
    
    htop 2>/dev/null || {
        echo -e "${RED}❌ Ошибка запуска htop${NC}"
        read -p "Нажмите ENTER, чтобы продолжить..."
        return 1
    }
}

# ===================================================================
# ФУНКЦИЯ: БЕЗОПАСНАЯ ОЧИСТКА СИСТЕМЫ
# ===================================================================
system_cleanup() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}    🧹 БЕЗОПАСНАЯ ОЧИСТКА СИСТЕМЫ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""

    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[ОШИБКА]${NC} Пожалуйста, запустите скрипт от root (sudo)."
        return 1
    fi

    echo -e "${WHITE}Выберите действие:${NC}"
    echo ""
    echo -e "  ${GREEN}[1]${NC} 🧹 ПОЛНАЯ ОЧИСТКА СИСТЕМЫ (освободить место)"
    echo -e "  ${BLUE}[2]${NC} 📊 АНАЛИЗ ДИСКА (ncdu) - корневая папка /"
    echo -e "  ${CYAN}[3]${NC} 📊 АНАЛИЗ ДИСКА (ncdu) - домашняя папка /home"
    echo -e "  ${MAGENTA}[4]${NC} 📊 АНАЛИЗ ДИСКА (ncdu) - указать папку вручную"
    echo -e "  ${RED}[5]${NC} ❌ Назад"
    echo ""
    read -p "Ваш выбор [1-5]: " clean_choice

    case "$clean_choice" in
        1) system_cleanup_full ;;
        2) system_ncdu "/" ;;
        3) system_ncdu "/home" ;;
        4) 
            read -p "Введите путь для анализа (например, /var/log): " custom_path
            if [ -d "$custom_path" ]; then
                system_ncdu "$custom_path"
            else
                echo -e "${RED}❌ Папка $custom_path не существует${NC}"
                read -p "Нажмите ENTER, чтобы продолжить..."
                system_cleanup
            fi
            ;;
        5|*) return 0 ;;
    esac
    
    read -p "Нажмите ENTER, чтобы продолжить..."
    system_cleanup
}

# ===================================================================
# ЗАПУСК NCDU
# ===================================================================
system_ncdu() {
    local path="$1"
    
    if ! command -v ncdu &> /dev/null; then
        echo -e "\n${YELLOW}⚠️  ncdu не установлен!${NC}"
        echo -e "${BLUE}[ИНФО]${NC} ncdu - это интерактивный анализатор дискового пространства."
        echo ""
        echo -e "${CYAN}Хотите установить ncdu?${NC}"
        echo -e "  ${GREEN}[y]${NC} — Да, установить"
        echo -e "  ${RED}[n]${NC} — Нет, пропустить"
        echo ""
        read -p "Ваш выбор (y/n): " install_ncdu
        
        if [[ "$install_ncdu" =~ ^[Yy]$ ]]; then
            echo -e "\n${BLUE}[ИНФО]${NC} Установка ncdu..."
            sudo apt-get update -qq 2>/dev/null || true
            sudo apt-get install -y ncdu 2>/dev/null || {
                echo -e "${RED}❌ Не удалось установить ncdu${NC}"
                echo -e "${YELLOW}Установите вручную: sudo apt install ncdu -y${NC}"
                read -p "Нажмите ENTER, чтобы продолжить..."
                return 1
            }
            echo -e "${GREEN}✅ ncdu успешно установлен!${NC}"
            echo ""
        else
            echo -e "${YELLOW}Пропускаем.${NC}"
            read -p "Нажмите ENTER, чтобы продолжить..."
            return 0
        fi
    fi

    if [ ! -d "$path" ]; then
        echo -e "${RED}❌ Папка $path не существует${NC}"
        read -p "Нажмите ENTER, чтобы продолжить..."
        return 1
    fi

    echo -e "\n${BLUE}[ИНФО]${NC} Запуск ncdu для анализа: ${WHITE}$path${NC}"
    echo -e "${YELLOW}📌 Управление:${NC}"
    echo -e "  ${WHITE}↑/↓${NC} - навигация"
    echo -e "  ${WHITE}Enter${NC} - войти в папку"
    echo -e "  ${WHITE}d${NC} - удалить выбранный элемент (будьте осторожны!)"
    echo -e "  ${WHITE}q${NC} - выход"
    echo -e "  ${WHITE}?${NC} - справка"
    echo ""
    echo -e "${YELLOW}Нажмите ENTER, чтобы запустить ncdu...${NC}"
    read -r
    
    ncdu --color dark -x "$path" 2>/dev/null || ncdu -x "$path" 2>/dev/null || {
        echo -e "${RED}❌ Ошибка запуска ncdu${NC}"
        read -p "Нажмите ENTER, чтобы продолжить..."
        return 1
    }
}

# ===================================================================
# ПОЛНАЯ ОЧИСТКА СИСТЕМЫ
# ===================================================================
system_cleanup_full() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}    🧹 ПОЛНАЯ ОЧИСТКА СИСТЕМЫ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""

    echo -e "${BLUE}[ИНФО]${NC} Архитектура: $(uname -m)"
    echo ""

    FREE_BEFORE=$(df / | awk 'NR==2 {print $4}')
    FREE_BEFORE_MB=$((FREE_BEFORE / 1024))
    echo -e "${BLUE}[ИНФО]${NC} Свободно ДО очистки: ${GREEN}${FREE_BEFORE_MB} MB${NC}"
    echo ""

    echo -e "${YELLOW}⚠️  ВНИМАНИЕ: Очистка удалит старые ядра, кэши, логи и временные файлы.${NC}"
    echo -e "${YELLOW}   Система останется работоспособной. Это БЕЗОПАСНО для всех серверов.${NC}"
    echo ""
    read -p "Продолжить? Введите YES: " confirm
    if [ "$confirm" != "YES" ]; then
        echo -e "${YELLOW}Отмена.${NC}"
        return 0
    fi

    echo ""
    echo -e "${BLUE}Начинаем очистку...${NC}"
    echo ""

    echo -e "${BLUE}[1/8]${NC} Удаление старых ядер Linux..."
    echo ""
    sudo apt-get purge -y $(dpkg -l 'linux-*' | sed '/^ii/!d;/'"$(uname -r | sed "s/\(.*\)-\([^0-9]\+\)/\1/")"'/d;s/^[^ ]* [^ ]* \([^ ]*\).*/\1/;/[0-9]/!d' | head -n -1) 2>/dev/null || echo -e "  ${YELLOW}⚠️  Старых ядер для удаления нет${NC}"
    echo ""

    echo -e "${BLUE}[2/8]${NC} Удаление неиспользуемых пакетов..."
    echo ""
    dpkg -l | awk '/^rc/ {print $2}' | xargs sudo dpkg --purge 2>/dev/null || echo -e "  ${YELLOW}⚠️  Нет пакетов для удаления${NC}"
    echo ""

    echo -e "${BLUE}[3/8]${NC} Очистка кэша APT и временных файлов..."
    echo ""
    sudo apt --purge autoremove -y 2>/dev/null
    sudo apt clean 2>/dev/null
    sudo apt autoclean -y 2>/dev/null
    sudo rm -rf /var/lib/cache/ 2>/dev/null
    sudo rm -rf /tmp/* /var/tmp/* 2>/dev/null
    sudo rm -rf /var/cache/fontconfig/ 2>/dev/null
    sudo rm -rf /var/cache/apt/ 2>/dev/null
    sudo rm -rf /var/cache/man/ 2>/dev/null
    echo -e "  ${GREEN}✅ Готово${NC}"
    echo ""

    echo -e "${BLUE}[4/8]${NC} Обновление загрузчика..."
    echo ""
    case $(uname -m) in
        aarch64|armv7l)
            sudo update-initramfs -u -k all 2>/dev/null || echo -e "  ${YELLOW}⚠️  update-initramfs не выполнен${NC}"
            ;;
        x86_64)
            sudo update-grub 2>/dev/null || echo -e "  ${YELLOW}⚠️  update-grub не выполнен${NC}"
            sudo update-grub2 2>/dev/null || echo -e "  ${YELLOW}⚠️  update-grub2 не выполнен${NC}"
            ;;
        riscv64)
            echo -e "  ${YELLOW}⚠️  RISC-V: обновление загрузчика не требуется${NC}"
            ;;
        *)
            echo -e "  ${YELLOW}⚠️  Неизвестная архитектура${NC}"
            ;;
    esac
    echo ""

    echo -e "${BLUE}[5/8]${NC} Очистка системных логов..."
    echo ""
    sudo journalctl --vacuum-time=3d 2>/dev/null || echo -e "  ${YELLOW}⚠️  journalctl не выполнен${NC}"
    sudo journalctl --vacuum-size=10M 2>/dev/null || echo -e "  ${YELLOW}⚠️  journalctl не выполнен${NC}"
    sudo find /var/log/ -name "*.log" -type f -exec sudo truncate -s 0 {} \; 2>/dev/null || echo -e "  ${YELLOW}⚠️  Нет логов для очистки${NC}"
    sudo systemctl restart rsyslog 2>/dev/null || echo -e "  ${YELLOW}⚠️  rsyslog не перезапущен${NC}"
    echo -e "  ${GREEN}✅ Готово${NC}"
    echo ""

    echo -e "${BLUE}[6/8]${NC} Удаление старых Snap приложений..."
    echo ""
    if command -v snap &> /dev/null; then
        echo -e "  ${GREEN}✅ Snap установлен${NC}"
        snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' | while read snapname revision; do
            echo -e "  ${WHITE}Удаляем:${NC} $snapname (revision: $revision)"
            sudo snap remove "$snapname" --revision="$revision" 2>/dev/null || echo -e "    ${YELLOW}⚠️  Не удалось удалить${NC}"
        done
    else
        echo -e "  ${YELLOW}⚠️  Snap не установлен${NC}"
    fi
    echo ""

    echo -e "${BLUE}[7/8]${NC} Удаление тестовых папок..."
    echo ""
    
    if [ -d "/var/www/diagnostics/testfiles/" ]; then
        echo -e "  ${YELLOW}⚠️  Найдена папка /var/www/diagnostics/testfiles/${NC}"
        echo -e "  ${WHITE}Удаляем...${NC}"
        rm -rf /var/www/diagnostics/testfiles/ 2>/dev/null || echo -e "  ${RED}❌ Не удалось удалить${NC}"
        echo -e "  ${GREEN}✅ Папка удалена${NC}"
    else
        echo -e "  ${YELLOW}⚠️  Папка /var/www/diagnostics/testfiles/ не найдена${NC}"
    fi
    
    if [ -d "/var/www/diagnostics/" ] && [ -z "$(ls -A /var/www/diagnostics/ 2>/dev/null)" ]; then
        echo -e "  ${WHITE}Удаляем пустую папку /var/www/diagnostics/${NC}"
        rm -rf /var/www/diagnostics/ 2>/dev/null || true
        echo -e "  ${GREEN}✅ Папка diagnostics удалена${NC}"
    fi
    echo ""

    echo -e "${BLUE}[8/8]${NC} Очистка кэша пользователей..."
    echo ""
    rm -rf /root/.cache/thumbnails/* 2>/dev/null
    rm -rf /root/.local/share/Trash/* 2>/dev/null
    for user_home in /home/*; do
        if [ -d "$user_home/.cache/thumbnails" ]; then
            rm -rf "$user_home/.cache/thumbnails/*" 2>/dev/null
        fi
        if [ -d "$user_home/.local/share/Trash" ]; then
            rm -rf "$user_home/.local/share/Trash/*" 2>/dev/null
        fi
        if [ -d "$user_home/.cache" ]; then
            rm -rf "$user_home/.cache/*" 2>/dev/null
        fi
    done
    echo -e "  ${GREEN}✅ Готово${NC}"
    echo ""

    FREE_AFTER=$(df / | awk 'NR==2 {print $4}')
    FREE_AFTER_MB=$((FREE_AFTER / 1024))
    FREED_MB=$((FREE_AFTER_MB - FREE_BEFORE_MB))

    echo -e "${CYAN}=============================================${NC}"
    echo -e "${GREEN}✅ ОЧИСТКА ЗАВЕРШЕНА!${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${BLUE}📌 Освобождено:${NC} ${GREEN}${FREED_MB} MB${NC}"
    echo -e "${BLUE}📌 Свободно сейчас:${NC} ${GREEN}${FREE_AFTER_MB} MB${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
}

# ===================================================================
# ФУНКЦИЯ: УПРАВЛЕНИЕ UFW
# ===================================================================
manage_ufw() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}    🔥 УПРАВЛЕНИЕ UFW${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""

    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[ОШИБКА]${NC} Пожалуйста, запустите скрипт от root (sudo)."
        return 1
    fi

    if ! command -v ufw &> /dev/null; then
        echo -e "${YELLOW}⚠️  UFW не установлен!${NC}"
        echo ""
        echo -e "${CYAN}Хотите установить UFW?${NC}"
        echo -e "  ${GREEN}[y]${NC} — Да, установить"
        echo -e "  ${RED}[n]${NC} — Нет, пропустить"
        echo ""
        read -p "Ваш выбор (y/n): " install_ufw
        
        if [[ "$install_ufw" =~ ^[Yy]$ ]]; then
            echo -e "\n${BLUE}[ИНФО]${NC} Установка UFW..."
            sudo apt-get update -qq 2>/dev/null || true
            sudo apt-get install -y ufw 2>/dev/null || {
                echo -e "${RED}❌ Не удалось установить UFW${NC}"
                read -p "Нажмите ENTER, чтобы продолжить..."
                return 1
            }
            echo -e "${GREEN}✅ UFW успешно установлен!${NC}"
            echo ""
        else
            echo -e "${YELLOW}Пропускаем.${NC}"
            read -p "Нажмите ENTER, чтобы продолжить..."
            return 0
        fi
    fi

    UFW_STATUS=$(ufw status 2>/dev/null | grep "Status:" | awk '{print $2}')
    if [ "$UFW_STATUS" == "active" ]; then
        UFW_STATUS_ICON="${GREEN}✅ АКТИВЕН${NC}"
        UFW_STATUS_CODE="active"
    else
        UFW_STATUS_ICON="${RED}❌ НЕАКТИВЕН${NC}"
        UFW_STATUS_CODE="inactive"
    fi

    echo -e "${BLUE}📌 СТАТУС UFW:${NC} $UFW_STATUS_ICON"
    echo ""
    
    echo -e "${BLUE}📋 ПОСЛЕДНИЕ ПРАВИЛА (первые 10):${NC}"
    ufw status numbered 2>/dev/null | head -12 || echo -e "  ${YELLOW}⚠️  Нет правил или UFW не активен${NC}"
    echo ""

    echo -e "${WHITE}Выберите действие:${NC}"
    echo ""
    echo -e "  ${GREEN}[1]${NC} 📊 ПОКАЗАТЬ СТАТУС И ВСЕ ПРАВИЛА"
    echo -e "  ${BLUE}[2]${NC} 🔓 ВКЛЮЧИТЬ UFW"
    echo -e "  ${RED}[3]${NC} 🔒 ОТКЛЮЧИТЬ UFW"
    echo -e "  ${CYAN}[4]${NC} ➕ ДОБАВИТЬ ПОРТ (разрешить)"
    echo -e "  ${MAGENTA}[5]${NC} ❌ УДАЛИТЬ ПОРТ (запретить)"
    echo -e "  ${YELLOW}[6]${NC} 🔄 ПЕРЕЗАГРУЗИТЬ UFW"
    echo -e "  ${GREEN}[7]${NC} 📋 ПОКАЗАТЬ ПРАВИЛА С НОМЕРАМИ"
    echo -e "  ${BLUE}[8]${NC} 📊 СТАТИСТИКА ПОРТОВ (открытые/закрытые)"
    echo -e "  ${CYAN}[9]${NC} 🔍 ПРОВЕРКА ДОСТУПНОСТИ ПОРТА (извне)"
    echo -e "  ${RED}[10]${NC} ❌ Назад"
    echo ""
    read -p "Ваш выбор [1-10]: " ufw_choice

    case "$ufw_choice" in
        1) ufw_show_status ;;
        2) ufw_enable ;;
        3) ufw_disable ;;
        4) ufw_add_port ;;
        5) ufw_delete_port ;;
        6) ufw_reload ;;
        7) ufw_show_rules ;;
        8) ufw_port_stats ;;
        9) ufw_check_port ;;
        10|*) return 0 ;;
    esac
    
    read -p "Нажмите ENTER, чтобы продолжить..."
    manage_ufw
}

ufw_show_status() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}    📊 СТАТУС UFW${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    ufw status verbose 2>/dev/null || echo -e "${RED}❌ Не удалось получить статус UFW${NC}"
    echo ""
}

ufw_enable() {
    echo -e "\n${BLUE}[ИНФО]${NC} Включение UFW..."
    
    if [ "$UFW_STATUS_CODE" == "active" ]; then
        echo -e "${YELLOW}⚠️  UFW уже активен${NC}"
        return 0
    fi
    
    ufw --force enable 2>/dev/null || {
        echo -e "${RED}❌ Не удалось включить UFW${NC}"
        return 1
    }
    
    sleep 2
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        echo -e "${GREEN}✅ UFW успешно включён!${NC}"
    else
        echo -e "${RED}❌ Не удалось включить UFW${NC}"
    fi
}

ufw_disable() {
    echo -e "\n${BLUE}[ИНФО]${NC} Отключение UFW..."
    
    if [ "$UFW_STATUS_CODE" != "active" ]; then
        echo -e "${YELLOW}⚠️  UFW уже неактивен${NC}"
        return 0
    fi
    
    echo -e "${RED}⚠️  ВНИМАНИЕ: Отключение UFW может быть небезопасно!${NC}"
    read -p "Продолжить? Введите YES: " confirm
    if [ "$confirm" != "YES" ]; then
        echo -e "${YELLOW}Отмена.${NC}"
        return 0
    fi
    
    ufw --force disable 2>/dev/null || {
        echo -e "${RED}❌ Не удалось отключить UFW${NC}"
        return 1
    }
    
    echo -e "${GREEN}✅ UFW отключён${NC}"
}

ufw_add_port() {
    echo -e "\n${BLUE}[ИНФО]${NC} Добавление порта в UFW"
    echo ""
    
    read -p "Введите номер порта (например, 8080): " port
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${RED}❌ Неверный номер порта${NC}"
        return 1
    fi
    
    echo ""
    echo -e "${CYAN}Выберите протокол:${NC}"
    echo -e "  ${GREEN}[1]${NC} TCP"
    echo -e "  ${BLUE}[2]${NC} UDP"
    echo -e "  ${YELLOW}[3]${NC} TCP+UDP (оба)"
    echo ""
    read -p "Ваш выбор [1-3]: " proto_choice
    
    case "$proto_choice" in
        1) proto="tcp" ;;
        2) proto="udp" ;;
        3) proto="both" ;;
        *) echo -e "${RED}❌ Неверный выбор${NC}"; return 1 ;;
    esac
    
    echo ""
    echo -e "${CYAN}Выберите действие:${NC}"
    echo -e "  ${GREEN}[1]${NC} Разрешить (allow)"
    echo -e "  ${RED}[2]${NC} Запретить (deny)"
    echo ""
    read -p "Ваш выбор [1-2]: " action_choice
    
    case "$action_choice" in
        1) action="allow" ;;
        2) action="deny" ;;
        *) echo -e "${RED}❌ Неверный выбор${NC}"; return 1 ;;
    esac
    
    if [ "$proto" == "both" ]; then
        ufw $action $port/tcp 2>/dev/null && ufw $action $port/udp 2>/dev/null
        echo -e "${GREEN}✅ Порт $port (TCP+UDP) $action добавлен${NC}"
    else
        ufw $action $port/$proto 2>/dev/null
        echo -e "${GREEN}✅ Порт $port/$proto $action добавлен${NC}"
    fi
}

ufw_delete_port() {
    echo -e "\n${BLUE}[ИНФО]${NC} Удаление порта из UFW"
    echo ""
    
    ufw status numbered 2>/dev/null | head -20 || echo -e "${YELLOW}⚠️  Нет правил для удаления${NC}"
    echo ""
    
    read -p "Введите номер правила для удаления: " rule_num
    if ! [[ "$rule_num" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}❌ Неверный номер${NC}"
        return 1
    fi
    
    ufw delete $rule_num 2>/dev/null || {
        echo -e "${RED}❌ Не удалось удалить правило${NC}"
        return 1
    }
    echo -e "${GREEN}✅ Правило $rule_num удалено${NC}"
}

ufw_reload() {
    echo -e "\n${BLUE}[ИНФО]${NC} Перезагрузка UFW..."
    ufw reload 2>/dev/null || {
        echo -e "${RED}❌ Не удалось перезагрузить UFW${NC}"
        return 1
    }
    echo -e "${GREEN}✅ UFW перезагружен${NC}"
}

ufw_show_rules() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}    📋 ПРАВИЛА UFW С НОМЕРАМИ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    ufw status numbered 2>/dev/null || echo -e "${RED}❌ Не удалось получить правила${NC}"
    echo ""
}

ufw_port_stats() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}    📊 СТАТИСТИКА ПОРТОВ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    
    echo -e "${BLUE}📌 ПОРТЫ UFW (разрешённые):${NC}"
    echo ""
    ufw status 2>/dev/null | grep ALLOW | while read line; do
        echo -e "  ${GREEN}✅${NC} $line"
    done
    if [ $? -ne 0 ]; then
        echo -e "  ${YELLOW}⚠️  Нет разрешённых портов${NC}"
    fi
    
    echo ""
    echo -e "${BLUE}📌 ПОРТЫ UFW (запрещённые):${NC}"
    echo ""
    ufw status 2>/dev/null | grep DENY | while read line; do
        echo -e "  ${RED}❌${NC} $line"
    done
    if [ $? -ne 0 ]; then
        echo -e "  ${YELLOW}⚠️  Нет запрещённых портов${NC}"
    fi
    
    echo ""
    echo -e "${BLUE}📌 ВСЕ ОТКРЫТЫЕ ПОРТЫ (реально слушающие):${NC}"
    echo ""
    ss -tulpn 2>/dev/null | grep LISTEN | awk '{print $5}' | cut -d: -f2 | sort -n | uniq | while read port; do
        if [ -n "$port" ]; then
            if ufw status 2>/dev/null | grep -q "$port/tcp\|$port/udp"; then
                echo -e "  ${GREEN}✅${NC} порт $port (в UFW)"
            else
                echo -e "  ${YELLOW}⚠️${NC} порт $port (НЕ в UFW!)"
            fi
        fi
    done
    echo ""
}

ufw_check_port() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}    🔍 ПРОВЕРКА ДОСТУПНОСТИ ПОРТА${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    
    read -p "Введите порт для проверки: " port
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${RED}❌ Неверный номер порта${NC}"
        return 1
    fi
    
    echo ""
    echo -e "${YELLOW}📌 ПРОВЕРКА ПОРТА $port:${NC}"
    echo ""
    
    if ufw status 2>/dev/null | grep -q "$port/tcp"; then
        echo -e "  ${GREEN}✅${NC} Порт $port/tcp разрешён в UFW"
    elif ufw status 2>/dev/null | grep -q "$port/udp"; then
        echo -e "  ${GREEN}✅${NC} Порт $port/udp разрешён в UFW"
    else
        echo -e "  ${RED}❌${NC} Порт $port НЕ разрешён в UFW"
    fi
    
    if ss -tulpn 2>/dev/null | grep -q ":$port "; then
        echo -e "  ${GREEN}✅${NC} Порт $port слушается (есть процесс)"
        process=$(ss -tulpn 2>/dev/null | grep ":$port " | head -1)
        echo -e "  ${WHITE}   Процесс:${NC} $process"
    else
        echo -e "  ${YELLOW}⚠️${NC} Порт $port НЕ слушается (нет процесса)"
    fi
    
    server_ip=$(curl -s ifconfig.me 2>/dev/null || echo "не определён")
    if [ "$server_ip" != "не определён" ]; then
        echo ""
        echo -e "${BLUE}[ИНФО]${NC} Проверка извне через telnet (локально)..."
        if timeout 2 nc -zv 127.0.0.1 $port 2>&1 | grep -q "succeeded\|Connected"; then
            echo -e "  ${GREEN}✅${NC} Порт $port доступен локально"
        else
            echo -e "  ${RED}❌${NC} Порт $port НЕ доступен локально"
        fi
    fi
    
    echo ""
}

# ===================================================================
# ФУНКЦИЯ: РЕДАКТИРОВАНИЕ КОНФИГОВ
# ===================================================================
edit_configs() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}    📝 РЕДАКТИРОВАНИЕ КОНФИГОВ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""

    echo -e "${WHITE}Выберите файл для редактирования:${NC}"
    echo ""
    echo -e "  ${GREEN}[1]${NC} /etc/ssh/sshd_config — SSH сервер"
    echo -e "  ${BLUE}[2]${NC} /etc/ssh/sshd_config.d/ — папка переопределений SSH"
    echo -e "  ${CYAN}[3]${NC} /etc/default/ufw — настройки UFW"
    echo -e "  ${MAGENTA}[4]${NC} /etc/ufw/before.rules — правила UFW (перед основными)"
    echo -e "  ${YELLOW}[5]${NC} /etc/ufw/after.rules — правила UFW (после основных)"
    echo -e "  ${GREEN}[6]${NC} /etc/sysctl.conf — настройки ядра"
    echo -e "  ${BLUE}[7]${NC} /etc/default/grub — настройки загрузчика"
    echo -e "  ${CYAN}[8]${NC} /etc/hosts — файл хостов"
    echo -e "  ${MAGENTA}[9]${NC} /etc/hostname — имя сервера"
    echo -e "  ${YELLOW}[10]${NC} /etc/resolv.conf — DNS-сервера"
    echo -e "  ${GREEN}[11]${NC} /etc/fail2ban/jail.local — настройки fail2ban"
    echo -e "  ${BLUE}[12]${NC} /etc/nginx/nginx.conf — основной конфиг Nginx"
    echo -e "  ${CYAN}[13]${NC} /etc/nginx/sites-available/ — папка сайтов Nginx"
    echo -e "  ${MAGENTA}[14]${NC} /var/www/ — папка веб-сайтов"
    echo -e "  ${RED}[15]${NC} ❌ Назад"
    echo ""
    read -p "Ваш выбор [1-15]: " edit_choice

    case "$edit_choice" in
        1) edit_file "/etc/ssh/sshd_config" ;;
        2) edit_dir "/etc/ssh/sshd_config.d/" "*.conf" ;;
        3) edit_file "/etc/default/ufw" ;;
        4) edit_file "/etc/ufw/before.rules" ;;
        5) edit_file "/etc/ufw/after.rules" ;;
        6) edit_file "/etc/sysctl.conf" ;;
        7) edit_file "/etc/default/grub" ;;
        8) edit_file "/etc/hosts" ;;
        9) edit_file "/etc/hostname" ;;
        10) edit_file "/etc/resolv.conf" ;;
        11) edit_file "/etc/fail2ban/jail.local" ;;
        12) edit_file "/etc/nginx/nginx.conf" ;;
        13) edit_dir "/etc/nginx/sites-available/" "*.conf" ;;
        14) edit_dir "/var/www/" "*" ;;
        15|*) return 0 ;;
    esac
    
    read -p "Нажмите ENTER, чтобы продолжить..."
    edit_configs
}

edit_file() {
    local file="$1"
    
    if [ ! -f "$file" ]; then
        echo -e "\n${RED}❌ Файл $file не существует!${NC}"
        
        echo -e "${CYAN}Хотите создать файл?${NC}"
        echo -e "  ${GREEN}[y]${NC} — Да, создать и открыть"
        echo -e "  ${RED}[n]${NC} — Нет, пропустить"
        echo ""
        read -p "Ваш выбор (y/n): " create_file
        
        if [[ "$create_file" =~ ^[Yy]$ ]]; then
            mkdir -p "$(dirname "$file")" 2>/dev/null || true
            touch "$file"
            echo -e "${GREEN}✅ Файл создан: $file${NC}"
            echo ""
            echo -e "${YELLOW}Открываю файл для редактирования...${NC}"
            sleep 1
            nano "$file"
        else
            echo -e "${YELLOW}Пропускаем.${NC}"
        fi
        return
    fi
    
    echo -e "\n${BLUE}[ИНФО]${NC} Редактирование файла: ${WHITE}$file${NC}"
    echo -e "${YELLOW}📌 Совет: создайте резервную копию перед редактированием!${NC}"
    echo -e "${YELLOW}📌 Команда для бэкапа: cp $file ${file}.backup.$(date +%Y%m%d)${NC}"
    echo ""
    read -p "Нажмите ENTER, чтобы открыть файл в nano..."
    
    BACKUP_FILE="${file}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$file" "$BACKUP_FILE" 2>/dev/null || true
    echo -e "${GREEN}✅ Создана резервная копия: $BACKUP_FILE${NC}"
    echo ""
    
    nano "$file"
    
    echo -e "\n${GREEN}✅ Редактирование завершено${NC}"
    echo -e "${YELLOW}📌 Если что-то сломали, восстановите:${NC}"
    echo -e "  ${WHITE}cp $BACKUP_FILE $file${NC}"
}

edit_dir() {
    local dir="$1"
    local pattern="$2"
    
    if [ ! -d "$dir" ]; then
        echo -e "\n${RED}❌ Папка $dir не существует!${NC}"
        echo -e "${CYAN}Хотите создать папку?${NC}"
        echo -e "  ${GREEN}[y]${NC} — Да, создать"
        echo -e "  ${RED}[n]${NC} — Нет, пропустить"
        echo ""
        read -p "Ваш выбор (y/n): " create_dir
        
        if [[ "$create_dir" =~ ^[Yy]$ ]]; then
            mkdir -p "$dir" 2>/dev/null || true
            echo -e "${GREEN}✅ Папка создана: $dir${NC}"
        else
            echo -e "${YELLOW}Пропускаем.${NC}"
            return
        fi
    fi
    
    echo -e "\n${BLUE}[ИНФО]${NC} Папка: ${WHITE}$dir${NC}"
    echo ""
    
    echo -e "${YELLOW}📌 Содержимое папки:${NC}"
    ls -la "$dir" 2>/dev/null | head -20 || echo -e "  ${YELLOW}⚠️  Папка пуста${NC}"
    echo ""
    
    echo -e "${CYAN}Выберите действие:${NC}"
    echo -e "  ${GREEN}[1]${NC} Открыть папку в редакторе (nano) — можно выбрать файл"
    echo -e "  ${BLUE}[2]${NC} Создать новый файл в папке"
    echo -e "  ${YELLOW}[3]${NC} Назад"
    echo ""
    read -p "Ваш выбор [1-3]: " dir_action
    
    case "$dir_action" in
        1)
            echo -e "\n${BLUE}[ИНФО]${NC} Введите имя файла для редактирования (или Enter для просмотра всех):"
            read -p "Имя файла: " filename
            
            if [ -z "$filename" ]; then
                echo -e "${YELLOW}Показываю все файлы:${NC}"
                ls -la "$dir"
            elif [ -f "${dir}${filename}" ]; then
                edit_file "${dir}${filename}"
            else
                echo -e "${RED}❌ Файл ${dir}${filename} не существует${NC}"
                echo -e "${CYAN}Хотите создать его? (y/n): ${NC}"
                read create_new
                if [[ "$create_new" =~ ^[Yy]$ ]]; then
                    edit_file "${dir}${filename}"
                fi
            fi
            ;;
        2)
            echo -e "\n${BLUE}[ИНФО]${NC} Введите имя нового файла:"
            read -p "Имя файла: " new_filename
            
            if [ -z "$new_filename" ]; then
                echo -e "${RED}❌ Имя файла не может быть пустым${NC}"
                return
            fi
            
            new_file="${dir}${new_filename}"
            touch "$new_file" 2>/dev/null || {
                echo -e "${RED}❌ Не удалось создать файл${NC}"
                return
            }
            echo -e "${GREEN}✅ Файл создан: $new_file${NC}"
            echo -e "${YELLOW}Открываю файл для редактирования...${NC}"
            sleep 1
            nano "$new_file"
            ;;
        3|*) return ;;
    esac
}

# ===================================================================
# ФУНКЦИЯ: ТЕСТ ПРОИЗВОДИТЕЛЬНОСТИ
# ===================================================================
run_benchmark() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}    📊 ТЕСТ ПРОИЗВОДИТЕЛЬНОСТИ СЕРВЕРА${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""

    echo -e "${BLUE}[ИНФО]${NC} bench.sh — скрипт для тестирования производительности сервера."
    echo -e "${BLUE}[ИНФО]${NC} Проверяет: CPU, память, диск, сеть."
    echo ""
    
    echo -e "${YELLOW}⚠️  ВНИМАНИЕ:${NC}"
    echo -e "  • Тест может занять 3-5 минут"
    echo -e "  • Использует ресурсы сервера (CPU, диск, сеть)"
    echo -e "  • Данные отправляются на сервер bench.sh для обработки"
    echo ""
    
    echo -e "${CYAN}Выберите способ запуска:${NC}"
    echo ""
    echo -e "  ${GREEN}[1]${NC} Запустить bench.sh (wget)"
    echo -e "  ${BLUE}[2]${NC} Запустить bench.sh (curl)"
    echo -e "  ${YELLOW}[3]${NC} Запустить yabs.sh (Yet Another Bench Script) — более подробный"
    echo -e "  ${MAGENTA}[4]${NC} Запустить s6 (serverreview) — тест сети"
    echo -e "  ${RED}[5]${NC} ❌ Назад"
    echo ""
    read -p "Ваш выбор [1-5]: " bench_choice

    case "$bench_choice" in
        1)
            echo -e "\n${BLUE}[ИНФО]${NC} Запуск bench.sh через wget..."
            echo -e "${YELLOW}⏳ Пожалуйста, подождите... (3-5 минут)${NC}"
            echo ""
            wget -qO- bench.sh | bash
            ;;
        2)
            echo -e "\n${BLUE}[ИНФО]${NC} Запуск bench.sh через curl..."
            echo -e "${YELLOW}⏳ Пожалуйста, подождите... (3-5 минут)${NC}"
            echo ""
            curl -Lso- bench.sh | bash
            ;;
        3)
            echo -e "\n${BLUE}[ИНФО]${NC} Запуск yabs.sh (Yet Another Bench Script)..."
            echo -e "${YELLOW}⏳ Пожалуйста, подождите... (3-5 минут)${NC}"
            echo ""
            curl -sL yabs.sh | bash -s -- -i
            ;;
        4)
            echo -e "\n${BLUE}[ИНФО]${NC} Запуск s6 (serverreview)..."
            echo -e "${YELLOW}⏳ Пожалуйста, подождите... (тест сети, 2-3 минуты)${NC}"
            echo ""
            curl -sL s6.agency | bash -s -- -r
            ;;
        5|*)
            echo -e "\n${YELLOW}👋 Отмена.${NC}"
            return 0
            ;;
    esac
    
    echo ""
    echo -e "${GREEN}✅ Тест завершён!${NC}"
    
    echo ""
    echo -e "${CYAN}Хотите сохранить результат в файл?${NC}"
    echo -e "  ${GREEN}[y]${NC} — Да, сохранить"
    echo -e "  ${RED}[n]${NC} — Нет"
    echo ""
    read -p "Ваш выбор (y/n): " save_result
    
    if [[ "$save_result" =~ ^[Yy]$ ]]; then
        RESULT_FILE="/root/bench_result_$(date +%Y%m%d_%H%M%S).txt"
        echo -e "${BLUE}[ИНФО]${NC} Сохранение результата в: $RESULT_FILE"
        
        echo -e "${YELLOW}⏳ Перезапуск теста с сохранением...${NC}"
        case "$bench_choice" in
            1) wget -qO- bench.sh | bash 2>&1 | tee "$RESULT_FILE" ;;
            2) curl -Lso- bench.sh | bash 2>&1 | tee "$RESULT_FILE" ;;
            3) curl -sL yabs.sh | bash -s -- -i 2>&1 | tee "$RESULT_FILE" ;;
            4) curl -sL s6.agency | bash -s -- -r 2>&1 | tee "$RESULT_FILE" ;;
        esac
        
        echo -e "${GREEN}✅ Результат сохранён в: $RESULT_FILE${NC}"
    fi
    
    read -p "Нажмите ENTER, чтобы продолжить..."
}

# ===================================================================
# УНИВЕРСАЛЬНОЕ СОХРАНЕНИЕ СОСТОЯНИЯ FIREWALL
# ===================================================================
save_firewall_state() {
    local save_file="${IPTABLES_SAVE_FILE:-/etc/iptables/rules.v4}"
    sudo mkdir -p "$(dirname "$save_file")" 2>/dev/null || return 1
    sudo iptables-save | sudo tee "$save_file" >/dev/null || return 1
    if command -v netfilter-persistent >/dev/null 2>&1; then
        sudo netfilter-persistent save >/dev/null 2>&1 || true
    fi
    if [ -x /etc/init.d/iptables-persistent ]; then
        sudo /etc/init.d/iptables-persistent save >/dev/null 2>&1 || true
    fi
    return 0
}

restore_firewall_state() {
    local backup="$1"
    [ -s "$backup" ] || return 1
    sudo iptables-restore < "$backup" || return 1
    save_firewall_state || true
    return 0
}

add_ssh_rules_to_ddos_chain() {
    local port="$1"
    if ! sudo iptables -nL DDoS_PROTECT >/dev/null 2>&1; then
        return 0
    fi
    sudo iptables -I DDoS_PROTECT 1 -p tcp --dport "$port" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
    sudo iptables -I DDoS_PROTECT 1 -p tcp --dport "$port" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    sudo iptables -I DDoS_PROTECT 2 -p tcp --dport "$port" -m conntrack --ctstate NEW -m recent --set --name SSH 2>/dev/null || \
    sudo iptables -I DDoS_PROTECT 2 -p tcp --dport "$port" -m state --state NEW -m recent --set --name SSH 2>/dev/null || true
    sudo iptables -I DDoS_PROTECT 3 -p tcp --dport "$port" -m conntrack --ctstate NEW -m recent --update --seconds 60 --hitcount 5 --name SSH -j DROP 2>/dev/null || \
    sudo iptables -I DDoS_PROTECT 3 -p tcp --dport "$port" -m state --state NEW -m recent --update --seconds 60 --hitcount 5 --name SSH -j DROP 2>/dev/null || true
    sudo iptables -I DDoS_PROTECT 4 -p tcp --dport "$port" -m connlimit --connlimit-above 10 --connlimit-mask 32 -j DROP 2>/dev/null || true
    sudo iptables -I DDoS_PROTECT 5 -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
}

remove_ssh_rules_from_ddos_chain() {
    local port="$1"
    local args
    if ! sudo iptables -nL DDoS_PROTECT >/dev/null 2>&1; then
        return 0
    fi
    while sudo iptables -D DDoS_PROTECT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; do :; done
    while sudo iptables -D DDoS_PROTECT -p tcp --dport "$port" -m connlimit --connlimit-above 10 --connlimit-mask 32 -j DROP 2>/dev/null; do :; done
    while sudo iptables -D DDoS_PROTECT -p tcp --dport "$port" -m state --state NEW -m recent --update --seconds 60 --hitcount 5 --name SSH -j DROP 2>/dev/null; do :; done
    while sudo iptables -D DDoS_PROTECT -p tcp --dport "$port" -m conntrack --ctstate NEW -m recent --update --seconds 60 --hitcount 5 --name SSH -j DROP 2>/dev/null; do :; done
    while sudo iptables -D DDoS_PROTECT -p tcp --dport "$port" -m state --state NEW -m recent --set --name SSH 2>/dev/null; do :; done
    while sudo iptables -D DDoS_PROTECT -p tcp --dport "$port" -m conntrack --ctstate NEW -m recent --set --name SSH 2>/dev/null; do :; done
    while sudo iptables -D DDoS_PROTECT -p tcp --dport "$port" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; do :; done
    while sudo iptables -D DDoS_PROTECT -p tcp --dport "$port" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; do :; done
}

update_fail2ban_ssh_port() {
    local port="$1"
    local file=/etc/fail2ban/jail.local
    [ -f "$file" ] || return 0
    local tmp
    tmp=$(mktemp)
    awk -v p="$port" '
        BEGIN { in_sshd=0; changed=0 }
        /^\[/ {
            if (in_sshd && !changed) { print "port = " p }
            in_sshd = ($0 == "[sshd]"); changed=0; print; next
        }
        {
            if (in_sshd && $0 ~ /^[[:space:]]*port[[:space:]]*=/) {
                if (!changed) { print "port = " p; changed=1 }
                next
            }
            print
        }
        END { if (in_sshd && !changed) print "port = " p }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    if ! grep -q '^\[sshd\]' "$tmp"; then
        printf '\n[sshd]\nenabled = true\nport = %s\n' "$port" >> "$tmp"
    fi
    sudo install -m 0644 "$tmp" "$file"
    rm -f "$tmp"
    sudo fail2ban-client reload >/dev/null 2>&1 || sudo systemctl restart fail2ban >/dev/null 2>&1 || true
}


# ===================================================================
# ПЕРЕЗАПУСК SSH С УЧЁТОМ SOCKET ACTIVATION
# ===================================================================
restart_ssh_for_port_change() {
    local expected_port="${1:-}"
    local listen_value=""

    if systemctl is-active --quiet ssh.socket 2>/dev/null || systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
        # ssh.socket may have a generated drop-in based on sshd_config.
        # Recreate it only after daemon-reload; do not edit /usr/lib or /run directly.
        systemctl stop ssh.service 2>/dev/null || true
        systemctl stop ssh.socket 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
        systemctl reset-failed ssh.socket ssh.service 2>/dev/null || true
        if ! systemctl start ssh.socket 2>/dev/null; then
            echo -e "${RED}[ОШИБКА] Не удалось запустить ssh.socket после изменения порта.${NC}"
            return 1
        fi
    else
        restart_ssh || return 1
    fi

    # Do not proceed until systemd and the kernel both report the requested port.
    if [ -n "$expected_port" ]; then
        local i
        for i in $(seq 1 10); do
            listen_value=$(systemctl show ssh.socket -p Listen --value 2>/dev/null || true)
            if printf '%s\n' "$listen_value" | grep -Eq "(^|[[:space:]])(0\\.0\\.0\\.0:|\\[::\\]:|:)$expected_port([[:space:]]|$)"; then
                if ss -H -ltn 2>/dev/null | awk -v p="$expected_port" '{ addr=$4; sub(/^.*:/, "", addr); if (addr == p) found=1 } END { exit !found }'; then
                    return 0
                fi
            fi
            sleep 1
        done
        echo -e "${RED}[ОШИБКА] ssh.socket/sshd не подтвердили прослушивание порта ${expected_port}.${NC}"
        echo -e "${YELLOW}Фактический Listen: ${listen_value:-не определён}${NC}"
        return 1
    fi

    sleep 2
    return 0
}

# ===================================================================
# ДИАГНОСТИКА НЕУДАЧИ СМЕНЫ SSH-ПОРТА
# ===================================================================
diagnose_ssh_port_failure() {
    local port="$1"
    local report_dir="${BACKUP_BASE_DIR:-/root/ddos_backup}"
    local report="$report_dir/ssh_port_diagnostic_$(date +%Y%m%d_%H%M%S).log"
    sudo mkdir -p "$report_dir" 2>/dev/null || true
    {
        echo "SSH port diagnostic: $(date -Is)"
        echo "Requested port: $port"
        echo
        echo '=== OS ==='
        cat /etc/os-release 2>/dev/null || true
        echo
        echo '=== SSH units ==='
        systemctl is-active ssh.service sshd.service ssh.socket 2>&1 || true
        systemctl is-enabled ssh.service sshd.service ssh.socket 2>&1 || true
        echo
        echo '=== Listening TCP sockets ==='
        ss -H -ltnp 2>&1 || true
        echo
        echo '=== Effective sshd configuration ==='
        sshd -T 2>&1 | grep -E '^(port|listenaddress|addressfamily)' || true
        echo
        echo '=== sshd syntax ==='
        sshd -t 2>&1 || true
        echo
        echo '=== SSH service status ==='
        systemctl --no-pager --full status ssh.service sshd.service ssh.socket 2>&1 || true
        echo
        echo '=== Recent SSH journal ==='
        journalctl --no-pager -u ssh.service -u sshd.service -u ssh.socket -b -n 80 2>&1 || true
        echo
        echo '=== UFW ==='
        command -v ufw >/dev/null 2>&1 && { ufw status verbose 2>&1 || true; ufw show raw 2>&1 || true; } || echo 'ufw: not installed'
        echo
        echo '=== firewalld ==='
        command -v firewall-cmd >/dev/null 2>&1 && { firewall-cmd --state 2>&1 || true; firewall-cmd --list-all 2>&1 || true; } || echo 'firewalld: not installed'
        echo
        echo '=== iptables filter rules ==='
        iptables -S 2>&1 || true
        echo
        echo '=== iptables saved rules containing SSH port ==='
        [ -f /etc/iptables/rules.v4 ] && grep -E "(DDoS_PROTECT|dport|--dport|$port)" /etc/iptables/rules.v4 2>&1 || true
        echo
        echo '=== fail2ban ==='
        command -v fail2ban-client >/dev/null 2>&1 && { fail2ban-client status sshd 2>&1 || true; grep -n -A12 -B2 '^\[sshd\]' /etc/fail2ban/jail.local 2>&1 || true; } || echo 'fail2ban: not installed'
        echo
        echo '=== systemd socket configuration ==='
        systemctl cat ssh.socket 2>&1 || true
    } | sudo tee "$report" >/dev/null
    echo -e "${YELLOW}[ДИАГНОСТИКА] Отчёт сохранён: $report${NC}"
    echo -e "${YELLOW}[ДИАГНОСТИКА] Вывод: sudo sed -n '1,240p' $report${NC}"
}

# ===================================================================
# ПРОВЕРКА ПРОСЛУШИВАНИЯ TCP-ПОРТА SSH
# ===================================================================
port_is_listening() {
    local port="$1"
    sudo ss -H -ltn 2>/dev/null | awk -v p="$port" '{ addr=$4; sub(/^.*:/, "", addr); if (addr == p) found=1 } END { exit !found }'
}

# ===================================================================
# ФУНКЦИЯ: СМЕНА ПОРТА SSH
# ===================================================================
change_ssh_port() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}    🔒 СМЕНА ПОРТА SSH (БЕЗОПАСНЫЙ РЕЖИМ)${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""

    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[ОШИБКА]${NC} Пожалуйста, запустите скрипт от root (sudo)."
        return 1
    fi

    CURRENT_PORT=$(get_ssh_port)
    echo -e "${GREEN}[ИНФО]${NC} Текущий порт SSH: $CURRENT_PORT"
    echo -e "${BLUE}[ВВОД]${NC} Введите новый порт для SSH (1024-65535):"
    while read -r SSHPORT; do
        if ! [[ "$SSHPORT" =~ ^[0-9]+$ ]] || [ "$SSHPORT" -lt 1024 ] || [ "$SSHPORT" -gt 65535 ]; then
            echo -e "${RED}[ОШИБКА]${NC} Порт должен быть числом от 1024 до 65535. Попробуйте снова:"
            continue
        fi
        if [ "$SSHPORT" -eq "$CURRENT_PORT" ]; then
            echo -e "${YELLOW}[ПРЕДУПРЕЖДЕНИЕ]${NC} Это текущий порт. Введите другой:"
            continue
        fi
        if port_is_listening "$SSHPORT"; then
            echo -e "${RED}[ОШИБКА]${NC} Порт $SSHPORT уже используется другим сервисом!"
            continue
        fi
        break
    done

    local config_backup_dir firewall_backup f tmp file
    config_backup_dir=$(mktemp -d /tmp/ssh-port-backup.XXXXXX)
    firewall_backup="$config_backup_dir/iptables.rules"
    sudo iptables-save > "$firewall_backup" 2>/dev/null || true
    sudo cp -a /etc/ssh/sshd_config "$config_backup_dir/sshd_config" || { rm -rf "$config_backup_dir"; return 1; }
    if [ -d /etc/ssh/sshd_config.d ]; then
        sudo cp -a /etc/ssh/sshd_config.d "$config_backup_dir/sshd_config.d" 2>/dev/null || true
    fi
    if [ -f /etc/fail2ban/jail.local ]; then
        sudo cp -a /etc/fail2ban/jail.local "$config_backup_dir/jail.local" 2>/dev/null || true
    fi

    echo -e "${BLUE}[ИНФО]${NC} Меняем все активные Port-директивы и задаём единый порт $SSHPORT..."
    sudo sed -i -E '/^[[:space:]]*#?[[:space:]]*Port[[:space:]]+[0-9]+[[:space:]]*$/d' /etc/ssh/sshd_config
    if [ -d /etc/ssh/sshd_config.d ]; then
        while IFS= read -r -d '' file; do
            sudo sed -i -E '/^[[:space:]]*#?[[:space:]]*Port[[:space:]]+[0-9]+[[:space:]]*$/d' "$file"
        done < <(find /etc/ssh/sshd_config.d -maxdepth 1 -type f -name '*.conf' -print0 2>/dev/null)
    fi
    tmp=$(mktemp)
    printf 'Port %s\n' "$SSHPORT" | cat - /etc/ssh/sshd_config > "$tmp"
    sudo install -m 0644 "$tmp" /etc/ssh/sshd_config
    rm -f "$tmp"

    if ! sudo sshd -t 2>/dev/null; then
        echo -e "${RED}[ОШИБКА]${NC} Ошибка конфигурации SSH; выполняется откат."
        sudo cp -a "$config_backup_dir/sshd_config" /etc/ssh/sshd_config
        [ -d "$config_backup_dir/sshd_config.d" ] && sudo rm -rf /etc/ssh/sshd_config.d && sudo cp -a "$config_backup_dir/sshd_config.d" /etc/ssh/sshd_config.d
        restart_ssh_for_port_change
        rm -rf "$config_backup_dir"
        return 1
    fi

    echo -e "${BLUE}[ИНФО]${NC} Открываем новый порт во всех обнаруженных локальных фильтрах..."
    if command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -q 'Status: active'; then
        sudo ufw allow "$SSHPORT/tcp" || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        sudo firewall-cmd --permanent --add-port="$SSHPORT/tcp" >/dev/null 2>&1 || true
        sudo firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    add_ssh_rules_to_ddos_chain "$SSHPORT"
    update_fail2ban_ssh_port "$SSHPORT" || true

    echo -e "${BLUE}[ИНФО]${NC} Перезапускаем SSH и проверяем фактическое прослушивание порта..."
    if ! restart_ssh_for_port_change "$SSHPORT" || ! port_is_listening "$SSHPORT"; then
        echo -e "${RED}[ОШИБКА]${NC} SSH не подтвердил новый порт; выполняется диагностика и полный откат."
        diagnose_ssh_port_failure "$SSHPORT"
        restore_firewall_state "$firewall_backup" || true
        sudo cp -a "$config_backup_dir/sshd_config" /etc/ssh/sshd_config
        [ -d "$config_backup_dir/sshd_config.d" ] && sudo rm -rf /etc/ssh/sshd_config.d && sudo cp -a "$config_backup_dir/sshd_config.d" /etc/ssh/sshd_config.d
        [ -f "$config_backup_dir/jail.local" ] && sudo cp -a "$config_backup_dir/jail.local" /etc/fail2ban/jail.local
        restart_ssh_for_port_change "$CURRENT_PORT" || restart_ssh
        rm -rf "$config_backup_dir"
        return 1
    fi

    echo -e "${YELLOW}Проверьте новое подключение в отдельном окне.${NC}"
    echo -e "${YELLOW}[Y] Немедленно сохранить новый порт.${NC}"
    echo -e "${YELLOW}[N] Ничего не менять сейчас и оставить безопасное ожидание 60 секунд.${NC}"
    echo -e "${YELLOW}Любая другая клавиша выполнит безопасный откат.${NC}"
    confirm_key=""
    if IFS= read -r -t 60 -n 1 -s confirm_key < /dev/tty 2>/dev/null; then
        if [[ "$confirm_key" =~ ^[Yy]$ ]]; then
            echo -e "\n${GREEN}Подтверждено пользователем: сохраняем новый порт без ожидания.${NC}"
        elif [[ "$confirm_key" =~ ^[Nn]$ ]]; then
            echo -e "\n${YELLOW}Отмена подтверждена: выполняется безопасный откат...${NC}"
            restore_firewall_state "$firewall_backup" || true
            sudo cp -a "$config_backup_dir/sshd_config" /etc/ssh/sshd_config
            [ -d "$config_backup_dir/sshd_config.d" ] && sudo rm -rf /etc/ssh/sshd_config.d && sudo cp -a "$config_backup_dir/sshd_config.d" /etc/ssh/sshd_config.d
            [ -f "$config_backup_dir/jail.local" ] && sudo cp -a "$config_backup_dir/jail.local" /etc/fail2ban/jail.local
            restart_ssh_for_port_change
            rm -rf "$config_backup_dir"
            echo -e "${GREEN}Откат завершён. SSH-порт: $CURRENT_PORT${NC}"
            return 0
        else
            echo -e "\n${YELLOW}Выполняется откат...${NC}"
            restore_firewall_state "$firewall_backup" || true
            sudo cp -a "$config_backup_dir/sshd_config" /etc/ssh/sshd_config
            [ -d "$config_backup_dir/sshd_config.d" ] && sudo rm -rf /etc/ssh/sshd_config.d && sudo cp -a "$config_backup_dir/sshd_config.d" /etc/ssh/sshd_config.d
            [ -f "$config_backup_dir/jail.local" ] && sudo cp -a "$config_backup_dir/jail.local" /etc/fail2ban/jail.local
            restart_ssh_for_port_change
            rm -rf "$config_backup_dir"
            echo -e "${GREEN}Откат завершён. SSH-порт: $CURRENT_PORT${NC}"
            return 0
        fi
    else
        echo -e "\n${GREEN}Тайм-аут истёк: сохраняем новый порт.${NC}"
    fi

    remove_ssh_rules_from_ddos_chain "$CURRENT_PORT"
    if command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -q 'Status: active'; then
        sudo ufw delete allow "$CURRENT_PORT/tcp" >/dev/null 2>&1 || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        sudo firewall-cmd --permanent --remove-port="$CURRENT_PORT/tcp" >/dev/null 2>&1 || true
        sudo firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    save_firewall_state || { echo -e "${RED}[ОШИБКА] Не удалось сохранить firewall после смены порта.${NC}"; return 1; }
    SSH_PORT="$SSHPORT"
    rm -rf "$config_backup_dir"
    echo -e "${GREEN}✅ Порт SSH изменён и сохранён: $SSHPORT${NC}"
    echo -e "${GREEN}✅ Новый порт будет восстановлен после перезагрузки.${NC}"

    if ! port_is_listening "$SSHPORT"; then
        echo -e "${RED}❌ Проверка перед перезагрузкой не пройдена: SSH не слушает порт $SSHPORT.${NC}"
        return 1
    fi
    if [ ! -s "${IPTABLES_SAVE_FILE:-/etc/iptables/rules.v4}" ] || ! grep -Eq -- "(--dport|dpt:)\\s*${SSHPORT}\\b" "${IPTABLES_SAVE_FILE:-/etc/iptables/rules.v4}" 2>/dev/null; then
        echo -e "${RED}❌ Проверка перед перезагрузкой не пройдена: порт $SSHPORT не найден в сохранённых iptables-правилах.${NC}"
        return 1
    fi

    echo ""
    echo -e "${YELLOW}Перезагрузить сервер сейчас? [Y/n]${NC}"
    read -r reboot_choice
    case "${reboot_choice:-n}" in
        [Yy])
            echo -e "${YELLOW}Перезагрузка сервера... Текущее SSH-соединение будет закрыто.${NC}"
            sync
            systemctl reboot
            ;;
        *)
            echo -e "${GREEN}Перезагрузка отменена. Сервер продолжает работу.${NC}"
            ;;
    esac
}

# ===================================================================
# ФУНКЦИЯ: УПРАВЛЕНИЕ АУТЕНТИФИКАЦИЕЙ SSH
# ===================================================================
manage_ssh_auth() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}    🔐 УПРАВЛЕНИЕ АУТЕНТИФИКАЦИЕЙ SSH${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""

    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[ОШИБКА]${NC} Пожалуйста, запустите скрипт от root (sudo)."
        return 1
    fi

    echo -e "${BLUE}[ИНФО]${NC} Получение реальных параметров SSH через sshd -T..."
    
    if command -v sshd &> /dev/null; then
        SSHD_CONFIG=$(sshd -T 2>/dev/null)
        
        if [ -n "$SSHD_CONFIG" ]; then
            PASSWORD_AUTH=$(echo "$SSHD_CONFIG" | grep -E "^passwordauthentication\s+" | awk '{print $2}' | head -1)
            PUBKEY_AUTH=$(echo "$SSHD_CONFIG" | grep -E "^pubkeyauthentication\s+" | awk '{print $2}' | head -1)
            PERMIT_ROOT=$(echo "$SSHD_CONFIG" | grep -E "^permitrootlogin\s+" | awk '{print $2}' | head -1)
            MAX_AUTH_TRIES=$(echo "$SSHD_CONFIG" | grep -E "^maxauthtries\s+" | awk '{print $2}' | head -1)
        fi
    fi
    
    if [ -z "$PASSWORD_AUTH" ] || [ -z "$PUBKEY_AUTH" ]; then
        echo -e "${YELLOW}[ИНФО]${NC} sshd -T не сработал, используем ручной анализ конфигов..."
        
        PASSWORD_AUTH=$(grep -E "^[[:space:]]*PasswordAuthentication" /etc/ssh/sshd_config 2>/dev/null | tail -1 | awk '{print $2}')
        PUBKEY_AUTH=$(grep -E "^[[:space:]]*PubkeyAuthentication" /etc/ssh/sshd_config 2>/dev/null | tail -1 | awk '{print $2}')
        PERMIT_ROOT=$(grep -E "^[[:space:]]*PermitRootLogin" /etc/ssh/sshd_config 2>/dev/null | tail -1 | awk '{print $2}')
        
        for f in /etc/ssh/sshd_config.d/*.conf; do
            [ -f "$f" ] || continue
            if grep -qiE "^[[:space:]]*PasswordAuthentication[[:space:]]+no" "$f" 2>/dev/null; then
                PASSWORD_AUTH="no"
            fi
            if grep -qiE "^[[:space:]]*PasswordAuthentication[[:space:]]+yes" "$f" 2>/dev/null; then
                PASSWORD_AUTH="yes"
            fi
            if grep -qiE "^[[:space:]]*PubkeyAuthentication[[:space:]]+no" "$f" 2>/dev/null; then
                PUBKEY_AUTH="no"
            fi
            if grep -qiE "^[[:space:]]*PubkeyAuthentication[[:space:]]+yes" "$f" 2>/dev/null; then
                PUBKEY_AUTH="yes"
            fi
        done
    fi

    if [ -z "$PASSWORD_AUTH" ]; then
        PASSWORD_AUTH="yes"
    fi
    if [ -z "$PUBKEY_AUTH" ]; then
        PUBKEY_AUTH="yes"
    fi
    if [ -z "$PERMIT_ROOT" ]; then
        PERMIT_ROOT="prohibit-password"
    fi
    if [ -z "$MAX_AUTH_TRIES" ]; then
        MAX_AUTH_TRIES="3"
    fi

    if [ "$PASSWORD_AUTH" == "no" ] && [ "$PUBKEY_AUTH" == "yes" ]; then
        CURRENT_MODE="🔐 ТОЛЬКО КЛЮЧИ (без пароля)"
        CURRENT_MODE_CODE="keys_only"
    elif [ "$PASSWORD_AUTH" == "yes" ] && [ "$PUBKEY_AUTH" == "yes" ]; then
        CURRENT_MODE="🔓 КЛЮЧИ + ПАРОЛЬ"
        CURRENT_MODE_CODE="both"
    elif [ "$PASSWORD_AUTH" == "yes" ] && [ "$PUBKEY_AUTH" == "no" ]; then
        CURRENT_MODE="🔑 ТОЛЬКО ПАРОЛЬ (без ключей)"
        CURRENT_MODE_CODE="password_only"
    else
        CURRENT_MODE="⚠️  НЕИЗВЕСТНЫЙ РЕЖИМ"
        CURRENT_MODE_CODE="unknown"
    fi

    echo -e "${BLUE}📌 ТЕКУЩИЙ РЕЖИМ АУТЕНТИФИКАЦИИ:${NC}"
    echo -e "  ${GREEN}→ ${CURRENT_MODE}${NC}"
    echo ""
    echo -e "${BLUE}📌 ПАРАМЕТРЫ:${NC}"
    echo -e "  ${WHITE}PasswordAuthentication:${NC} $PASSWORD_AUTH"
    echo -e "  ${WHITE}PubkeyAuthentication:${NC}  $PUBKEY_AUTH"
    echo -e "  ${WHITE}PermitRootLogin:${NC}      $PERMIT_ROOT"
    echo -e "  ${WHITE}MaxAuthTries:${NC}         $MAX_AUTH_TRIES"
    echo ""

    HAS_KEYS=0
    while IFS=: read -r username _ uid _ _ home _; do
        if [ "$uid" -ge 1000 ] || [ "$username" == "root" ]; then
            if [ -s "$home/.ssh/authorized_keys" ] 2>/dev/null; then
                HAS_KEYS=1
                break
            fi
        fi
    done < /etc/passwd

    if [ $HAS_KEYS -eq 0 ]; then
        echo -e "${YELLOW}⚠️  ВНИМАНИЕ: На сервере НЕТ настроенных SSH-ключей!${NC}"
        echo -e "${YELLOW}   Если вы включите режим 'ТОЛЬКО КЛЮЧИ', вы можете потерять доступ!${NC}"
        echo ""
    fi

    echo -e "${CYAN}Выберите режим аутентификации:${NC}"
    echo ""
    echo -e "  ${GREEN}[1]${NC} 🔐 ТОЛЬКО КЛЮЧИ (без пароля) — ${BOLD}МАКСИМАЛЬНАЯ БЕЗОПАСНОСТЬ${NC}"
    echo -e "  ${BLUE}[2]${NC} 🔓 КЛЮЧИ + ПАРОЛЬ — ${BOLD}ГИБКИЙ РЕЖИМ${NC}"
    echo -e "  ${YELLOW}[3]${NC} 🔑 ТОЛЬКО ПАРОЛЬ (без ключей) — ${BOLD}ДЛЯ ТЕСТИРОВАНИЯ${NC}"
    echo -e "  ${MAGENTA}[4]${NC} 🔑 НАСТРОИТЬ SSH-КЛЮЧИ (добавить или сгенерировать)"
    echo -e "  ${RED}[5]${NC} ❌ Выйти без изменений"
    echo ""
    read -p "Ваш выбор [1-5]: " mode_choice

    case "$mode_choice" in
        1)
            if [ $HAS_KEYS -eq 0 ]; then
                echo -e "\n${RED}[ОШИБКА]${NC} Нет SSH-ключей! Сначала добавьте ключи (выберите пункт 4)."
                read -p "Нажмите ENTER, чтобы продолжить..."
                return 1
            fi
            set_ssh_mode "keys_only"
            ;;
        2)
            set_ssh_mode "both"
            ;;
        3)
            set_ssh_mode "password_only"
            ;;
        4)
            generate_ssh_keys
            manage_ssh_auth
            ;;
        5|*)
            echo -e "\n${YELLOW}👋 Выход без изменений.${NC}"
            return 0
            ;;
    esac
}

set_ssh_mode() {
    local mode="$1"
    
    NOW=$(date +"%Y-%m-%d_%H-%M-%S")
    BACKUP_FILE="/etc/ssh/sshd_config.backup.$NOW"
    cp /etc/ssh/sshd_config "$BACKUP_FILE" 2>/dev/null || {
        echo -e "${RED}[ОШИБКА]${NC} Не удалось создать резервную копию!"
        return 1
    }
    echo -e "${GREEN}[ИНФО]${NC} Резервная копия: $BACKUP_FILE"

    case "$mode" in
        keys_only)
            echo -e "${BLUE}[ИНФО]${NC} Устанавливаем режим: ТОЛЬКО КЛЮЧИ"
            sed -i "/^#\?[[:space:]]*PasswordAuthentication[[:space:]]/Id" /etc/ssh/sshd_config
            sed -i "/^#\?[[:space:]]*PubkeyAuthentication[[:space:]]/Id" /etc/ssh/sshd_config
            echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
            echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config
            NEW_MODE="🔐 ТОЛЬКО КЛЮЧИ (без пароля)"
            ;;
        both)
            echo -e "${BLUE}[ИНФО]${NC} Устанавливаем режим: КЛЮЧИ + ПАРОЛЬ"
            sed -i "/^#\?[[:space:]]*PasswordAuthentication[[:space:]]/Id" /etc/ssh/sshd_config
            sed -i "/^#\?[[:space:]]*PubkeyAuthentication[[:space:]]/Id" /etc/ssh/sshd_config
            echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
            echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config
            NEW_MODE="🔓 КЛЮЧИ + ПАРОЛЬ"
            ;;
        password_only)
            echo -e "${BLUE}[ИНФО]${NC} Устанавливаем режим: ТОЛЬКО ПАРОЛЬ"
            sed -i "/^#\?[[:space:]]*PasswordAuthentication[[:space:]]/Id" /etc/ssh/sshd_config
            sed -i "/^#\?[[:space:]]*PubkeyAuthentication[[:space:]]/Id" /etc/ssh/sshd_config
            echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
            echo "PubkeyAuthentication no" >> /etc/ssh/sshd_config
            NEW_MODE="🔑 ТОЛЬКО ПАРОЛЬ (без ключей)"
            ;;
        *)
            echo -e "${RED}[ОШИБКА]${NC} Неизвестный режим!"
            return 1
            ;;
    esac

    echo -e "${BLUE}[ИНФО]${NC} Исправляем переопределения..."
    for f in /etc/ssh/sshd_config.d/*.conf; do
        [ -f "$f" ] || continue
        if grep -qiE "^[[:space:]]*PasswordAuthentication" "$f" 2>/dev/null; then
            cp "$f" "${f}.backup.$NOW" 2>/dev/null || true
            sed -i "/^[[:space:]]*PasswordAuthentication/d" "$f"
            echo -e "  ${YELLOW}⚠️  Исправлен:${NC} $f"
        fi
        if grep -qiE "^[[:space:]]*PubkeyAuthentication" "$f" 2>/dev/null; then
            cp "$f" "${f}.backup.$NOW" 2>/dev/null || true
            sed -i "/^[[:space:]]*PubkeyAuthentication/d" "$f"
            echo -e "  ${YELLOW}⚠️  Исправлен:${NC} $f"
        fi
    done

    if ! sshd -t 2>/dev/null; then
        echo -e "${RED}[ОШИБКА]${NC} Ошибка в конфигурации! Восстанавливаем..."
        cp "$BACKUP_FILE" /etc/ssh/sshd_config
        restart_ssh
        echo -e "${RED}[ОШИБКА]${NC} Конфиг восстановлен."
        return 1
    fi

    restart_ssh

    if systemctl is-active --quiet sshd.service 2>/dev/null || systemctl is-active --quiet ssh.service 2>/dev/null || systemctl is-active --quiet ssh.socket 2>/dev/null; then
        echo -e "${GREEN}✅ SSH успешно перезапущен!${NC}"
    else
        echo -e "${RED}[ОШИБКА]${NC} SSH не запустился! Восстанавливаем..."
        cp "$BACKUP_FILE" /etc/ssh/sshd_config
        restart_ssh
        echo -e "${RED}[ОШИБКА]${NC} Конфиг восстановлен."
        return 1
    fi

    echo ""
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${GREEN}✅ РЕЖИМ ИЗМЕНЕН!${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${BLUE}📌 Новый режим:${NC} $NEW_MODE"
    echo -e "${BLUE}📌 Резервная копия:${NC} $BACKUP_FILE"
    echo ""
    echo -e "${YELLOW}🔴 ВАЖНО:${NC}"
    echo -e "1. ${YELLOW}НЕ ЗАКРЫВАЙТЕ${NC} это окно!"
    echo -e "2. Откройте НОВОЕ окно и проверьте подключение:"
    echo -e "   ${GREEN}ssh -p ${SSH_PORT} пользователь@${SERVER_IP}${NC}"
    echo ""
        echo -e "${YELLOW}⏳ Проверьте подключение в новом окне.${NC}"
    echo -e "${GREEN}[Y]${NC} Немедленно сохранить новый режим"
    echo -e "${RED}[N]${NC} Немедленно отменить и выполнить откат"
    echo -e "${WHITE}Другая клавиша или отсутствие быстрого ответа — обычное ожидание 60 секунд.${NC}"
    echo ""
    echo -e "${CYAN}Ожидание 60 секунд...${NC}"
    echo -e "${WHITE}Нажмите Y или y в любой момент, чтобы сразу сохранить новый режим.${NC}"
    echo -e "${WHITE}Нажмите N или n в любой момент, чтобы сразу выполнить откат.${NC}"
    deadline=$((SECONDS + 60))
    while (( SECONDS < deadline )); do
        remaining=$((deadline - SECONDS))
        printf "\r${CYAN}Осталось секунд: %-2d${NC} " "$remaining"
        quick_confirm=""
        if IFS= read -r -n 1 -s -t 1 quick_confirm < /dev/tty 2>/dev/null; then
            case "$quick_confirm" in
                Y|y)
                    echo -e "\n${GREEN}✅ Подтверждено: новый режим сохранён без ожидания.${NC}"
                    echo -e "${BLUE}📌 Новый режим:${NC} $NEW_MODE"
                    return 0
                    ;;
                N|n)
                    echo -e "\n${YELLOW}⚠️  Отмена подтверждена: выполняется безопасный откат...${NC}"
                    cp "$BACKUP_FILE" /etc/ssh/sshd_config
                    restart_ssh
                    echo -e "${GREEN}✅ Конфигурация восстановлена!${NC}"
                    echo -e "${BLUE}📌 Режим восстановлен:${NC} ${CURRENT_MODE:-неизвестно}"
                    return 0
                    ;;
                *)
                    echo -e "\n${YELLOW}⚠️  Нераспознанная клавиша: выполняется безопасный откат...${NC}"
                    cp "$BACKUP_FILE" /etc/ssh/sshd_config
                    restart_ssh
                    echo -e "${GREEN}✅ Конфигурация восстановлена!${NC}"
                    echo -e "${BLUE}📌 Режим восстановлен:${NC} ${CURRENT_MODE:-неизвестно}"
                    return 0
                    ;;
            esac
        fi
    done
    echo -e "\n${GREEN}✅ 60 секунд истекли. Изменения сохранены!${NC}"
    echo -e "${BLUE}📌 Новый режим:${NC} $NEW_MODE"
    echo -e "${YELLOW}💡 Если что-то пошло не так, восстановите вручную:${NC}"
    echo -e "   ${GREEN}cp $BACKUP_FILE /etc/ssh/sshd_config && sudo systemctl restart ssh${NC}"
    echo -e "${CYAN}=============================================${NC}"
}

# ===================================================================
# ФУНКЦИЯ: ГЕНЕРАЦИЯ SSH-КЛЮЧЕЙ
# ===================================================================
generate_ssh_keys() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}    🔑 НАСТРОЙКА SSH-КЛЮЧЕЙ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""

    echo -e "${BLUE}[ИНФО]${NC} Для какого пользователя настроить ключи?"
    echo ""
    
    USER_LIST=()
    while IFS=: read -r username _ uid _ _ home _; do
        if [ "$uid" -ge 1000 ] || [ "$username" == "root" ]; then
            USER_LIST+=("$username")
        fi
    done < /etc/passwd

    if [ ${#USER_LIST[@]} -eq 0 ]; then
        echo -e "${RED}[ОШИБКА]${NC} Не найдено ни одного пользователя!"
        return 1
    fi

    for i in "${!USER_LIST[@]}"; do
        echo -e "  ${GREEN}[$i]${NC} ${USER_LIST[$i]}"
    done
    echo ""
    read -p "Введите номер пользователя [0-$((${#USER_LIST[@]}-1))]: " user_idx

    if ! [[ "$user_idx" =~ ^[0-9]+$ ]] || [ "$user_idx" -ge "${#USER_LIST[@]}" ]; then
        echo -e "${RED}[ОШИБКА]${NC} Неверный выбор!"
        return 1
    fi

    TARGET_USER="${USER_LIST[$user_idx]}"
    USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    SSH_DIR="$USER_HOME/.ssh"
    AUTH_FILE="$SSH_DIR/authorized_keys"

    echo -e "${GREEN}[ИНФО]${NC} Выбран пользователь: ${TARGET_USER}"

    echo ""
    echo -e "${CYAN}Как добавить ключ?${NC}"
    echo -e "  ${GREEN}[1]${NC} Сгенерировать НОВЫЙ ключ (автоматически)"
    echo -e "  ${BLUE}[2]${NC} Вставить СВОЙ существующий публичный ключ"
    echo -e "  ${YELLOW}[3]${NC} Отмена"
    echo ""
    read -p "Ваш выбор [1-3]: " key_method

    case "$key_method" in
        1)
            generate_new_keys "$TARGET_USER" "$SSH_DIR" "$AUTH_FILE"
            ;;
        2)
            insert_existing_key "$TARGET_USER" "$SSH_DIR" "$AUTH_FILE"
            ;;
        3|*)
            echo -e "${YELLOW}Отмена.${NC}"
            return 1
            ;;
    esac

    if [ -s "$AUTH_FILE" ]; then
        KEY_COUNT=$(grep -v "^#" "$AUTH_FILE" 2>/dev/null | wc -l)
        echo ""
        echo -e "${GREEN}✅ Ключ УСПЕШНО добавлен!${NC}"
        echo -e "  ${WHITE}Пользователь:${NC} $TARGET_USER"
        echo -e "  ${WHITE}Файл:${NC} $AUTH_FILE"
        echo -e "  ${WHITE}Количество ключей:${NC} $KEY_COUNT"
        echo ""
        echo -e "${YELLOW}Теперь можно безопасно отключать вход по паролю.${NC}"
    else
        echo -e "${RED}❌ Ключ НЕ добавлен!${NC}"
        return 1
    fi

    read -p "Нажмите ENTER, чтобы продолжить..."
}

generate_new_keys() {
    local TARGET_USER="$1"
    local SSH_DIR="$2"
    local AUTH_FILE="$3"

    echo -e "\n${BLUE}[ИНФО]${NC} Генерация новой пары ключей..."

    mkdir -p "$SSH_DIR" 2>/dev/null || {
        echo -e "${RED}[ОШИБКА]${NC} Не удалось создать $SSH_DIR"
        return 1
    }
    chmod 700 "$SSH_DIR"
    chown "$TARGET_USER":"$TARGET_USER" "$SSH_DIR" 2>/dev/null || true

    KEY_NAME="id_ed25519_$(date +%Y%m%d_%H%M%S)"
    KEY_PATH="$SSH_DIR/$KEY_NAME"

    echo -e "${BLUE}[ИНФО]${NC} Генерация ключей... (это займёт пару секунд)"
    ssh-keygen -t ed25519 -a 100 -C "$TARGET_USER@$(hostname)-$(date +%Y%m%d)" -f "$KEY_PATH" -N "" 2>/dev/null || {
        echo -e "${YELLOW}⚠️  ed25519 не поддерживается, используем RSA 4096...${NC}"
        ssh-keygen -t rsa -b 4096 -C "$TARGET_USER@$(hostname)-$(date +%Y%m%d)" -f "$KEY_PATH" -N "" 2>/dev/null || {
            echo -e "${RED}[ОШИБКА]${NC} Не удалось сгенерировать ключи!"
            return 1
        }
    }

    chown "$TARGET_USER":"$TARGET_USER" "$KEY_PATH" "$KEY_PATH.pub" 2>/dev/null || true
    chmod 600 "$KEY_PATH"
    chmod 644 "$KEY_PATH.pub"

    echo -e "${GREEN}✅ Ключи сгенерированы!${NC}"
    echo -e "  ${WHITE}Приватный:${NC} $KEY_PATH"
    echo -e "  ${WHITE}Публичный:${NC} $KEY_PATH.pub"

    cat "$KEY_PATH.pub" >> "$AUTH_FILE" 2>/dev/null || {
        echo -e "${RED}[ОШИБКА]${NC} Не удалось добавить ключ в $AUTH_FILE"
        return 1
    }
    chmod 600 "$AUTH_FILE"
    chown "$TARGET_USER":"$TARGET_USER" "$AUTH_FILE" 2>/dev/null || true

    echo -e "${GREEN}✅ Публичный ключ добавлен в authorized_keys${NC}"

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}🔑 ПРИВАТНЫЙ КЛЮЧ (скопируйте и сохраните на СВОЁМ КОМПЬЮТЕРЕ)${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    cat "$KEY_PATH"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}📌 ПУБЛИЧНЫЙ КЛЮЧ (можно сохранить как резервную копию)${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    cat "$KEY_PATH.pub"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    echo -e "${RED}🔴 БЕЗОПАСНОСТЬ: Удаляем приватный ключ с сервера...${NC}"
    rm -f "$KEY_PATH" 2>/dev/null || true
    echo -e "${GREEN}✅ Приватный ключ удалён с сервера. Оставлен только публичный ключ.${NC}"
    echo ""

    echo -e "${YELLOW}📌 ИНСТРУКЦИЯ:${NC}"
    echo ""
    echo -e "  ${WHITE}1. ПРИВАТНЫЙ КЛЮЧ (для подключения):${NC}"
    echo -e "     • Скопируйте ВЕСЬ блок с приватным ключом (между BEGIN и END)"
    echo -e "     • Сохраните на локальном компьютере: ${GREEN}~/.ssh/id_ed25519_server${NC}"
    echo -e "     • Установите права: ${GREEN}chmod 600 ~/.ssh/id_ed25519_server${NC}"
    echo -e "     • Подключение: ${GREEN}ssh -i ~/.ssh/id_ed25519_server -p ${SSH_PORT} ${TARGET_USER}@${SERVER_IP}${NC}"
    echo ""
    echo -e "  ${WHITE}2. ПУБЛИЧНЫЙ КЛЮЧ (резервная копия):${NC}"
    echo -e "     • Можете сохранить в безопасном месте"
    echo -e "     • Уже автоматически добавлен на ЭТОТ сервер в: ${GREEN}$AUTH_FILE${NC}"
    echo ""
    echo -e "  ${WHITE}3. Файлы на сервере:${NC}"
    echo -e "     • Приватный: ${RED}УДАЛЁН (безопасно)${NC}"
    echo -e "     • Публичный: ${GREEN}$KEY_PATH.pub${NC} (оставлен)"
    echo ""
}

insert_existing_key() {
    local TARGET_USER="$1"
    local SSH_DIR="$2"
    local AUTH_FILE="$3"

    echo -e "\n${BLUE}[ИНФО]${NC} Вставьте ваш ПУБЛИЧНЫЙ SSH-ключ."
    echo -e "${YELLOW}📌 Обычно это строка, начинающаяся с:${NC}"
    echo -e "  ${WHITE}ssh-rsa AAAAB3NzaC1yc2E...${NC}"
    echo -e "  ${WHITE}или${NC}"
    echo -e "  ${WHITE}ssh-ed25519 AAAAC3NzaC1lZDI1NTE5...${NC}"
    echo ""
    echo -e "${YELLOW}Чтобы получить свой публичный ключ на локальном компьютере:${NC}"
    echo -e "  ${WHITE}cat ~/.ssh/id_rsa.pub${NC}"
    echo -e "  ${WHITE}или${NC}"
    echo -e "  ${WHITE}cat ~/.ssh/id_ed25519.pub${NC}"
    echo ""
    echo -e "${BLUE}➡️  Вставьте ключ и нажмите ENTER (для завершения введите пустую строку):${NC}"
    echo ""

    KEY_LINES=""
    while IFS= read -r line; do
        if [ -z "$line" ]; then
            break
        fi
        KEY_LINES="${KEY_LINES}${line}\n"
    done

    PUBLIC_KEY=$(echo -e "$KEY_LINES" | tr -d '\n\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    if [ -z "$PUBLIC_KEY" ]; then
        echo -e "${RED}[ОШИБКА]${NC} Ключ не может быть пустым!"
        return 1
    fi

    if ! echo "$PUBLIC_KEY" | grep -qE "^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp|ssh-dss)"; then
        echo -e "${RED}[ОШИБКА]${NC} Не похоже на SSH-ключ! Должен начинаться с: ssh-rsa, ssh-ed25519 и т.д."
        echo -e "${YELLOW}Вы ввели:${NC} ${PUBLIC_KEY:0:50}..."
        return 1
    fi

    mkdir -p "$SSH_DIR" 2>/dev/null || {
        echo -e "${RED}[ОШИБКА]${NC} Не удалось создать $SSH_DIR"
        return 1
    }
    chmod 700 "$SSH_DIR"
    chown "$TARGET_USER":"$TARGET_USER" "$SSH_DIR" 2>/dev/null || true

    if [ -f "$AUTH_FILE" ] && grep -qF "$PUBLIC_KEY" "$AUTH_FILE" 2>/dev/null; then
        echo -e "${YELLOW}⚠️  Этот ключ уже есть в authorized_keys!${NC}"
        return 0
    fi

    echo "$PUBLIC_KEY" >> "$AUTH_FILE" 2>/dev/null || {
        echo -e "${RED}[ОШИБКА]${NC} Не удалось добавить ключ в $AUTH_FILE"
        return 1
    }
    chmod 600 "$AUTH_FILE"
    chown "$TARGET_USER":"$TARGET_USER" "$AUTH_FILE" 2>/dev/null || true

    echo -e "${GREEN}✅ Ключ успешно добавлен!${NC}"
    echo -e "  ${WHITE}Пользователь:${NC} $TARGET_USER"
    echo -e "  ${WHITE}Файл:${NC} $AUTH_FILE"
    echo ""
    echo -e "${YELLOW}📌 Проверьте подключение:${NC}"
    echo -e "  ${GREEN}ssh -p ${SSH_PORT} ${TARGET_USER}@${SERVER_IP}${NC}"
    echo ""
}

harden_ssh_auth() {
    echo -e "${YELLOW}⚠️  Эта функция устарела. Используйте пункт 4 'УПРАВЛЕНИЕ АУТЕНТИФИКАЦИЕЙ SSH'${NC}"
    echo -e "${BLUE}Переключаем вас на пункт 4...${NC}"
    sleep 2
    manage_ssh_auth
}

apply_protection() {
    print_title "🛡️  ПОЛНАЯ ЗАЩИТА + 3X-UI"
    export DEBIAN_FRONTEND=noninteractive
    auto_confirm
    # Пункт 1 не открывает автоматически порты Xray/3X-UI.
    # VPN, Docker/AmneziaWG и панель могут работать через уже настроенные
    # правила; прямые порты изменяются только вручную через пункт 4.
    PORTS_ARRAY=()
    if ! setup_iptables_mode; then
        print_error "Не удалось настроить iptables!"
        exit 1
    fi
    print_title "📦 НАСТРОЙКА КОМПОНЕНТОВ"
    setup_ufw || { show_warn "Проблема с настройкой UFW, продолжаем без остановки"; ERRORS_FOUND=1; }
    setup_nginx
    # Автоматические VPN-порты намеренно не добавляются в пункте 1.
    # Внешний доступ через Nginx/443 сохраняется; прямые Xray-порты
    # открываются только явным действием в меню управления портами.
    echo -e "  ${GREEN}✅ Автоматическое открытие портов Xray/3X-UI отключено${NC}"
    echo -e "  ${WHITE}ℹ️  Для прямого inbound используйте пункт 4 — управление портами${NC}"
    # Первый backup создаётся в main() до показа меню и до любых изменений.
    # Не создаём его повторно после настройки UFW/iptables, иначе исходный
    # снимок будет перезаписан уже изменёнными правилами.
    print_title "⚙️  НАСТРОЙКА СИСТЕМЫ"
    echo -e "\n${CYAN}📌 Настройка параметров ядра...${NC}"
    if ! grep -q "DDoS Protection Settings" /etc/sysctl.conf 2>/dev/null; then
        show_progress "Добавляем настройки в sysctl.conf"
        cat >> /etc/sysctl.conf <<EOF

# DDoS Protection Settings
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_tw_recycle = 0
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15
net.core.netdev_max_backlog = 5000
net.core.somaxconn = 1024
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
EOF
        show_ok
        sysctl -p > /dev/null 2>&1 || true
        echo -e "  ${GREEN}✅ Настройки применены${NC}"
    else
        show_warn "Настройки ядра уже добавлены"
    fi
    echo -e "\n${CYAN}📌 Настройка входящей защиты (DDoS_PROTECT)...${NC}"
    echo -e "  ${WHITE}• SSH (порт ${SSH_PORT}):${NC} 5 попыток за 60 секунд, макс. 10 соединений"
    echo -e "  ${WHITE}• HTTP (80):${NC} БЕЗ ОГРАНИЧЕНИЙ!"
    echo -e "  ${WHITE}• HTTPS (443):${NC} БЕЗ ОГРАНИЧЕНИЙ!"
    echo -e "  ${WHITE}• 3x-ui порты:${NC} БЕЗ ОГРАНИЧЕНИЙ!"
    
    echo -e "\n${YELLOW}⚠️  СОХРАНЕНИЕ ТЕКУЩЕГО SSH СОЕДИНЕНИЯ...${NC}"
    CURRENT_SSH_IP=$(who am i 2>/dev/null | awk '{print $NF}' | tr -d '()' 2>/dev/null || echo "")
    if [ -n "$CURRENT_SSH_IP" ] && [[ "$CURRENT_SSH_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        show_progress "Добавляем исключение для текущего IP: $CURRENT_SSH_IP"
        iptables -I INPUT 1 -s "$CURRENT_SSH_IP" -p tcp --dport ${SSH_PORT} -j ACCEPT 2>/dev/null || true
        show_ok
    else
        show_warn "Не удалось определить IP, добавляем правило для установленных соединений"
        iptables -I INPUT 1 -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
        show_ok
    fi
    
    show_progress "Удаляем старые правила"
    iptables -D INPUT -j DDoS_PROTECT 2>/dev/null || true
    iptables -F DDoS_PROTECT 2>/dev/null || true
    iptables -X DDoS_PROTECT 2>/dev/null || true
    show_ok
    
    show_progress "Создаем цепочку DDoS_PROTECT"
    iptables -N DDoS_PROTECT 2>/dev/null || {
        show_warn "Цепочка уже существует, очищаем"
        iptables -F DDoS_PROTECT
    }
    show_ok
    echo -e "\n  ${YELLOW}Порты VPN/3X-UI/Docker не добавляются в исключения автоматически.${NC}"
    echo -e "  ${WHITE}Их существующие правила и сетевые настройки не изменяются.${NC}"
    echo -e "\n  ${YELLOW}Добавляем правила входящей защиты:${NC}"
    
    show_progress "  • SSH защита (порт ${SSH_PORT}) - 5 попыток за 60 сек"
    iptables -A DDoS_PROTECT -p tcp --dport ${SSH_PORT} -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    iptables -A DDoS_PROTECT -p tcp --dport ${SSH_PORT} -m state --state NEW -m recent --set --name SSH 2>/dev/null || true
    iptables -A DDoS_PROTECT -p tcp --dport ${SSH_PORT} -m state --state NEW -m recent --update --seconds 60 --hitcount 5 --name SSH -j DROP 2>/dev/null || true
    iptables -A DDoS_PROTECT -p tcp --dport ${SSH_PORT} -m connlimit --connlimit-above 10 --connlimit-mask 32 -j DROP 2>/dev/null || true
    iptables -A DDoS_PROTECT -p tcp --dport ${SSH_PORT} -j ACCEPT 2>/dev/null || true
    show_ok
    
    show_progress "  • SYN-flood защита (1000 SYN/сек, с передачей разрешения в UFW)"
    # RETURN после лимита сохраняет DDoS-защиту, но не обходит UFW для неизвестных портов.
    iptables -A DDoS_PROTECT -p tcp --syn -m limit --limit 1000/sec --limit-burst 2000 -j RETURN 2>/dev/null || true
    iptables -A DDoS_PROTECT -p tcp --syn -j DROP 2>/dev/null || true
    show_ok
    
    show_progress "  • HTTP (80) — БЕЗ ОГРАНИЧЕНИЙ"
    iptables -A DDoS_PROTECT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
    show_ok
    
    show_progress "  • HTTPS (443) — БЕЗ ОГРАНИЧЕНИЙ"
    iptables -A DDoS_PROTECT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
    show_ok
    
    show_progress "  • ICMP защита (1 пинг в секунду)"
    iptables -A DDoS_PROTECT -p icmp --icmp-type echo-request -m limit --limit 1/sec -j ACCEPT 2>/dev/null || true
    iptables -A DDoS_PROTECT -p icmp --icmp-type echo-request -j DROP 2>/dev/null || true
    show_ok
    
    show_progress "Применяем DDoS_PROTECT к INPUT"
    iptables -I INPUT 1 -j DDoS_PROTECT 2>/dev/null || true
    show_ok
    
    setup_outgoing_limit
    
    echo -e "\n${CYAN}📌 НАСТРОЙКА FAIL2BAN (в конце — чтобы его баны были приоритетнее)...${NC}"
    setup_fail2ban || { show_warn "Проблема с настройкой fail2ban, продолжаем без остановки"; ERRORS_FOUND=1; }
    
    echo -e "\n${CYAN}📌 СОХРАНЕНИЕ ПРАВИЛ...${NC}"
    show_progress "Сохраняем в ${IPTABLES_SAVE_FILE}"
    sudo mkdir -p /etc/iptables 2>/dev/null || true
    sudo iptables-save > ${IPTABLES_SAVE_FILE} 2>/dev/null || true
    show_ok
    
    if command -v netfilter-persistent &>/dev/null; then
        show_progress "Сохраняем через netfilter-persistent"
        sudo netfilter-persistent save 2>/dev/null || true
        show_ok
    fi
    
    if [ -f /etc/init.d/iptables-persistent ]; then
        show_progress "Сохраняем через iptables-persistent"
        sudo /etc/init.d/iptables-persistent save 2>/dev/null || true
        show_ok
    fi
    
    create_autostart || { show_warn "Проблема с настройкой автозагрузки, продолжаем без остановки"; ERRORS_FOUND=1; }
    
    print_title "🔍 ФИНАЛЬНАЯ ПРОВЕРКА"
    echo -e "\n${CYAN}▶ Система:${NC}"
    echo -e "  ${WHITE}Ubuntu:${NC} $UBUNTU_VERSION"
    echo -e "  ${WHITE}iptables:${NC} $IPTABLES_TYPE"
    echo -e "  ${WHITE}IPv6:${NC} $IPV6_AVAILABLE"
    echo -e "  ${WHITE}IP:${NC} $SERVER_IP"
    echo -e "  ${WHITE}SSH порт:${NC} $SSH_PORT"
    echo -e "\n${CYAN}▶ Входящая защита (DDoS_PROTECT):${NC}"
    if iptables -L DDoS_PROTECT -n 2>/dev/null | grep -q "Chain DDoS_PROTECT"; then
        RULES=$(iptables -L DDoS_PROTECT -n 2>/dev/null | grep -c "DROP\|ACCEPT" 2>/dev/null || echo "0")
        echo -e "  ${GREEN}✅ Активна (${RULES} правил)${NC}"
        if iptables -L INPUT -n 2>/dev/null | grep -q "DDoS_PROTECT"; then
            echo -e "  ${GREEN}✅ Применена к INPUT${NC}"
        else
            echo -e "  ${RED}❌ НЕ применена к INPUT! Применяем...${NC}"
            iptables -I INPUT 1 -j DDoS_PROTECT
        fi
    else
        echo -e "  ${RED}❌ НЕ активна!${NC}"
        ERRORS_FOUND=1
    fi
    echo -e "\n${CYAN}▶ SSH защита (порт ${SSH_PORT}):${NC}"
    check_ssh || ERRORS_FOUND=1
    echo -e "\n${CYAN}▶ HTTP (80):${NC}"
    check_http || ERRORS_FOUND=1
    echo -e "\n${CYAN}▶ HTTPS (443):${NC}"
    check_https || ERRORS_FOUND=1
    echo -e "\n${CYAN}▶ 3x-ui порты (без ограничений):${NC}"
    found=0
    for port in "${PORTS_ARRAY[@]}"; do
        if [[ "$port" == "80" ]] || [[ "$port" == "443" ]] || [[ "$port" == "${SSH_PORT}" ]]; then
            continue
        fi
        if [[ "$port" =~ ^[0-9]+$ ]]; then
            if iptables -L DDoS_PROTECT -n 2>/dev/null | grep -q "dpt:$port"; then
                echo -e "  ${GREEN}✅ Порт $port — БЕЗ ОГРАНИЧЕНИЙ${NC}"
                found=1
            fi
        fi
    done
    if [ $found -eq 0 ]; then
        echo -e "  ${YELLOW}⚠️  Порты не найдены в правилах${NC}"
    fi
    echo -e "\n${CYAN}▶ Исходящая защита (OUTGOING_LIMIT):${NC}"
    if iptables -L OUTGOING_LIMIT -n 2>/dev/null | grep -q "Chain OUTGOING_LIMIT"; then
        RULES=$(iptables -L OUTGOING_LIMIT -n 2>/dev/null | grep -c "DROP\|ACCEPT" 2>/dev/null || echo "0")
        echo -e "  ${GREEN}✅ Активна (${RULES} правил)${NC}"
        if iptables -L OUTPUT -n 2>/dev/null | grep -q "OUTGOING_LIMIT"; then
            echo -e "  ${GREEN}✅ Применена к OUTPUT${NC}"
        else
            echo -e "  ${RED}❌ НЕ применена к OUTPUT! Применяем...${NC}"
            iptables -I OUTPUT 1 -j OUTGOING_LIMIT
        fi
    else
        echo -e "  ${RED}❌ НЕ активна!${NC}"
        ERRORS_FOUND=1
    fi
    echo -e "\n${CYAN}▶ Сохранение правил:${NC}"
    if [ -f ${IPTABLES_SAVE_FILE} ] && grep -q "DDoS_PROTECT" ${IPTABLES_SAVE_FILE} 2>/dev/null; then
        echo -e "  ${GREEN}✅ Правила сохранены в ${IPTABLES_SAVE_FILE}${NC}"
        echo -e "  ${GREEN}✅ ПОСЛЕ ПЕРЕЗАГРУЗКИ ЗАЩИТА ОСТАНЕТСЯ!${NC}"
    else
        echo -e "  ${RED}❌ Правила НЕ сохранены!${NC}"
        ERRORS_FOUND=1
    fi
    echo -e "\n${CYAN}▶ UFW:${NC}"
    if command -v ufw &> /dev/null; then
        if ufw status 2>/dev/null | grep -q "Status: active"; then
            echo -e "  ${GREEN}✅ Активен${NC}"
        else
            echo -e "  ${RED}❌ Неактивен!${NC}"
            echo -e "  ${YELLOW}⚠️  Попробуйте активировать вручную:${NC}"
            echo -e "  ${WHITE}   sudo ufw --force enable${NC}"
            ERRORS_FOUND=1
        fi
    else
        echo -e "  ${RED}❌ UFW не установлен!${NC}"
        ERRORS_FOUND=1
    fi
    echo -e "\n${CYAN}▶ fail2ban:${NC}"
    if command -v fail2ban-client &> /dev/null && systemctl is-active --quiet fail2ban 2>/dev/null; then
        echo -e "  ${GREEN}✅ Работает${NC}"
        JAILS=$(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*Jail list://' | tr -d ' ' 2>/dev/null || echo "неизвестно")
        echo -e "  ${WHITE}Джейлы:${NC} $JAILS"
    else
        echo -e "  ${YELLOW}⚠️  Не работает${NC}"
    fi
    echo -e "\n${CYAN}▶ Nginx:${NC}"
    if command -v nginx &> /dev/null && systemctl is-active --quiet nginx 2>/dev/null; then
        echo -e "  ${GREEN}✅ Работает${NC}"
    else
        echo -e "  ${RED}❌ Не работает!${NC}"
        ERRORS_FOUND=1
    fi
    echo -e "\n${CYAN}▶ Доступность:${NC}"
    if curl -I http://localhost 2>/dev/null | grep -q "200\|301\|302"; then
        echo -e "  ${GREEN}✅ HTTP (80) доступен${NC}"
    else
        echo -e "  ${RED}❌ HTTP (80) НЕ доступен!${NC}"
        ERRORS_FOUND=1
    fi
    if curl -I https://localhost -k 2>/dev/null | grep -q "200\|301\|302"; then
        echo -e "  ${GREEN}✅ HTTPS (443) доступен${NC}"
    else
        echo -e "  ${YELLOW}ℹ️  HTTPS (443) недоступен локально (может быть настроен на домен)${NC}"
    fi
    echo "$BACKUP_DIR" > /root/.ddos_backup_location 2>/dev/null || true
    generate_security_report
    if [ $ERRORS_FOUND -eq 0 ]; then
        echo -e "\n${GREEN}${BOLD}✅ ВСЁ ОТЛИЧНО! Сервер полностью защищён!${NC}"
    else
        echo -e "\n${YELLOW}${BOLD}⚠️  ВНИМАНИЕ: Обнаружены проблемы!${NC}"
        echo -e "${YELLOW}Проверьте логи: journalctl -xe${NC}"
    fi
    echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}${BOLD}  🎉 СКРИПТ УСПЕШНО ВЫПОЛНЕН!${NC}"
    echo -e "${GREEN}${BOLD}  🛡️  СЕРВЕР ЗАЩИЩЁН, XRAY И САЙТ РАБОТАЮТ!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

generate_security_report() {
    print_title "📊 ОТЧЁТ О ЗАЩИТЕ СЕРВЕРА"
    
    local date_time=$(date "+%Y-%m-%d %H:%M:%S")
    local hostname=$(hostname)
    local uptime_info=$(uptime -p 2>/dev/null || echo "неизвестно")
    local load_avg=$(uptime | awk -F'load average:' '{print $2}' 2>/dev/null | cut -d, -f1-3 || echo "неизвестно")
    local memory_total=$(free -h | grep Mem | awk '{print $2}' 2>/dev/null || echo "неизвестно")
    local memory_used=$(free -h | grep Mem | awk '{print $3}' 2>/dev/null || echo "неизвестно")
    local memory_free=$(free -h | grep Mem | awk '{print $4}' 2>/dev/null || echo "неизвестно")
    local disk_used=$(df -h / | awk 'NR==2 {print $3}' 2>/dev/null || echo "неизвестно")
    local disk_total=$(df -h / | awk 'NR==2 {print $2}' 2>/dev/null || echo "неизвестно")
    local disk_percent=$(df -h / | awk 'NR==2 {print $5}' 2>/dev/null || echo "неизвестно")
    
    local ddos_rules=$(iptables -L DDoS_PROTECT -n 2>/dev/null | grep -c "DROP\|ACCEPT" 2>/dev/null || echo "0")
    local outgoing_rules=$(iptables -L OUTGOING_LIMIT -n 2>/dev/null | grep -c "DROP\|ACCEPT" 2>/dev/null || echo "0")
    local ddos_packets=$(iptables -L DDoS_PROTECT -v -n 2>/dev/null | tail -1 | awk '{print $1}' 2>/dev/null || echo "0")
    local ddos_bytes=$(iptables -L DDoS_PROTECT -v -n 2>/dev/null | tail -1 | awk '{print $2}' 2>/dev/null || echo "0")
    
    local ufw_status=$(ufw status 2>/dev/null | grep "Status:" | awk '{print $2}' 2>/dev/null || echo "неизвестно")
    
    local f2b_status="неактивен"
    local f2b_jails="0"
    if command -v fail2ban-client &> /dev/null && systemctl is-active --quiet fail2ban 2>/dev/null; then
        f2b_status="активен"
        f2b_jails=$(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*Jail list://' | tr -d ' ' | awk -F',' '{print NF}' 2>/dev/null || echo "0")
    fi
    
    local nginx_status="неактивен"
    if command -v nginx &> /dev/null && systemctl is-active --quiet nginx 2>/dev/null; then
        nginx_status="активен"
    fi
    
    local ssh_open=$(ss -tulpn 2>/dev/null | grep -E ":${SSH_PORT}\s" | grep LISTEN > /dev/null && echo "✅" || echo "❌")
    local http_open=$(ss -tulpn 2>/dev/null | grep ":80\s" | grep LISTEN > /dev/null && echo "✅" || echo "❌")
    local https_open=$(ss -tulpn 2>/dev/null | grep ":443\s" | grep LISTEN > /dev/null && echo "✅" || echo "❌")
    
    local xray_ports_found=""
    for port in "${PORTS_ARRAY[@]}"; do
        if [[ "$port" =~ ^[0-9]+$ ]]; then
            if ss -tulpn 2>/dev/null | grep -E ":${port}\s" | grep LISTEN > /dev/null; then
                xray_ports_found="${xray_ports_found} ${port}"
            fi
        fi
    done
    
    local ddos_total=$(iptables -L DDoS_PROTECT -n 2>/dev/null | grep -E "ACCEPT|DROP" | wc -l 2>/dev/null || echo "0")
    local outgoing_total=$(iptables -L OUTGOING_LIMIT -n 2>/dev/null | grep -E "ACCEPT|DROP" | wc -l 2>/dev/null || echo "0")
    local ddos_show=10
    local outgoing_show=10
    
    if [ "$ddos_total" -le "$ddos_show" ]; then
        ddos_show=$ddos_total
    fi
    
    if [ "$outgoing_total" -le "$outgoing_show" ]; then
        outgoing_show=$outgoing_total
    fi
    
    local ddos_rules_text=$(iptables -L DDoS_PROTECT -n 2>/dev/null | grep -E "ACCEPT|DROP" | head -${ddos_show} | while read line; do echo "  ├─ ${line}"; done || echo "  ├─ Нет правил")
    local outgoing_rules_text=$(iptables -L OUTGOING_LIMIT -n 2>/dev/null | grep -E "ACCEPT|DROP" | head -${outgoing_show} | while read line; do echo "  ├─ ${line}"; done || echo "  ├─ Нет правил")
    
    local xray_ports_list=""
    for port in "${PORTS_ARRAY[@]}"; do
        if [[ "$port" != "80" ]] && [[ "$port" != "443" ]] && [[ "$port" != "$SSH_PORT" ]]; then
            xray_ports_list="${xray_ports_list} ${port}"
        fi
    done
    
    echo ""
    echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║${NC}  ${BOLD}🛡️  ОТЧЁТ О ЗАЩИТЕ СЕРВЕРА${NC}"
    echo -e "${MAGENTA}║${NC}  ${WHITE}${date_time}${NC}"
    echo -e "${MAGENTA}╠══════════════════════════════════════════════════════════════════════════════╣${NC}"
    echo ""
    echo -e "${CYAN}  📌 СИСТЕМНАЯ ИНФОРМАЦИЯ${NC}"
    echo -e "  ├─ ${WHITE}Хост:${NC}     ${hostname}"
    echo -e "  ├─ ${WHITE}Ubuntu:${NC}   ${UBUNTU_VERSION}"
    echo -e "  ├─ ${WHITE}IP адрес:${NC} ${SERVER_IP}"
    echo -e "  ├─ ${WHITE}SSH порт:${NC} ${SSH_PORT}"
    echo -e "  ├─ ${WHITE}Время:${NC}    ${date_time}"
    echo -e "  ├─ ${WHITE}Аптайм:${NC}   ${uptime_info}"
    echo -e "  └─ ${WHITE}Нагрузка:${NC} ${load_avg}"
    echo ""
    echo -e "${CYAN}  💾 РЕСУРСЫ СИСТЕМЫ${NC}"
    echo -e "  ├─ ${WHITE}ОЗУ:${NC}     ${memory_used} / ${memory_total} (свободно: ${memory_free})"
    echo -e "  └─ ${WHITE}Диск (/):${NC} ${disk_used} / ${disk_total} (${disk_percent})"
    echo ""
    echo -e "${CYAN}  🔥 СТАТУС ЗАЩИТЫ${NC}"
    echo -e "  ├─ ${WHITE}Входящая защита (DDoS_PROTECT):${NC}      ${GREEN}✅ АКТИВНА${NC} (${ddos_rules} правил)"
    echo -e "  │  ├─ ${WHITE}Обработано пакетов:${NC}    ${ddos_packets}"
    echo -e "  │  └─ ${WHITE}Обработано байт:${NC}      ${ddos_bytes}"
    echo -e "  ├─ ${WHITE}Исходящая защита (OUTGOING_LIMIT):${NC}   ${GREEN}✅ АКТИВНА${NC} (${outgoing_rules} правил)"
    if [ "$ufw_status" == "active" ]; then
        echo -e "  ├─ ${WHITE}UFW:${NC}                                 ${GREEN}✅ АКТИВЕН${NC}"
    else
        echo -e "  ├─ ${WHITE}UFW:${NC}                                 ${RED}❌ НЕАКТИВЕН${NC}"
    fi
    if [ "$f2b_status" == "активен" ]; then
        echo -e "  ├─ ${WHITE}fail2ban:${NC}                             ${GREEN}✅ АКТИВЕН${NC} (${f2b_jails} джейлов)"
    else
        echo -e "  ├─ ${WHITE}fail2ban:${NC}                             ${RED}❌ НЕАКТИВЕН${NC}"
    fi
    if [ "$nginx_status" == "активен" ]; then
        echo -e "  └─ ${WHITE}Nginx:${NC}                               ${GREEN}✅ АКТИВЕН${NC}"
    else
        echo -e "  └─ ${WHITE}Nginx:${NC}                               ${RED}❌ НЕАКТИВЕН${NC}"
    fi
    echo ""
    echo -e "${CYAN}  🌐 СТАТУС ПОРТОВ${NC}"
    if [ "$ssh_open" == "✅" ]; then
        echo -e "  ├─ ${WHITE}SSH (${SSH_PORT}):${NC}   ✅  ${GREEN}открыт${NC}"
    else
        echo -e "  ├─ ${WHITE}SSH (${SSH_PORT}):${NC}   ❌  ${RED}закрыт${NC}"
    fi
    if [ "$http_open" == "✅" ]; then
        echo -e "  ├─ ${WHITE}HTTP (80):${NC}    ✅  ${GREEN}открыт${NC}"
    else
        echo -e "  ├─ ${WHITE}HTTP (80):${NC}    ❌  ${RED}закрыт${NC}"
    fi
    if [ "$https_open" == "✅" ]; then
        echo -e "  ├─ ${WHITE}HTTPS (443):${NC}  ✅  ${GREEN}открыт${NC}"
    else
        echo -e "  ├─ ${WHITE}HTTPS (443):${NC}  ❌  ${RED}закрыт${NC}"
    fi
    if [ -n "$xray_ports_found" ]; then
        echo -e "  └─ ${WHITE}Xray порты:${NC}   ${GREEN}✅${NC} ${xray_ports_found}"
    else
        echo -e "  └─ ${WHITE}Xray порты:${NC}   ${YELLOW}⚠️  не обнаружены${NC}"
    fi
    echo ""
    echo -e "${CYAN}  🛡️  ПРАВИЛА ВХОДЯЩЕЙ ЗАЩИТЫ (DDoS_PROTECT)${NC}"
    echo "${ddos_rules_text}"
    if [ "$ddos_total" -gt "$ddos_show" ]; then
        echo "  └─ ${YELLOW}...и ещё $((ddos_total - ddos_show)) правил${NC}"
    else
        echo "  └─ ${GREEN}Все правила отображены${NC}"
    fi
    echo ""
    echo -e "${CYAN}  🛡️  ПРАВИЛА ИСХОДЯЩЕЙ ЗАЩИТЫ (OUTGOING_LIMIT)${NC}"
    echo "${outgoing_rules_text}"
    if [ "$outgoing_total" -gt "$outgoing_show" ]; then
        echo "  └─ ${YELLOW}...и ещё $((outgoing_total - outgoing_show)) правил${NC}"
    else
        echo "  └─ ${GREEN}Все правила отображены${NC}"
    fi
    echo ""
    echo -e "${CYAN}  📋 ИСКЛЮЧЕНИЯ (порты без ограничений)${NC}"
    echo -e "  ├─ ${WHITE}HTTP (80):${NC}     ${GREEN}✅ БЕЗ ОГРАНИЧЕНИЙ${NC}"
    echo -e "  ├─ ${WHITE}HTTPS (443):${NC}   ${GREEN}✅ БЕЗ ОГРАНИЧЕНИЙ${NC}"
    echo -e "  ├─ ${WHITE}SSH (${SSH_PORT}):${NC}  ${YELLOW}⚠️  С ОГРАНИЧЕНИЯМИ (5 попыток/60 сек)${NC}"
    echo -e "  └─ ${WHITE}Xray порты:${NC}    ${GREEN}✅ БЕЗ ОГРАНИЧЕНИЙ${NC} ${xray_ports_list}"
    echo ""
    echo -e "${CYAN}  📁 БЭКАП${NC}"
    echo -e "  └─ ${WHITE}Путь:${NC} ${BACKUP_DIR}"
    echo ""
    echo -e "${MAGENTA}╠══════════════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${MAGENTA}║${NC}  ${BOLD}📋 ПОЛЕЗНЫЕ КОМАНДЫ${NC}"
    echo -e "${MAGENTA}║${NC}"
    echo -e "${MAGENTA}║${NC}  ${WHITE}sudo iptables -L DDoS_PROTECT -v -n${NC}    - входящая защита"
    echo -e "${MAGENTA}║${NC}  ${WHITE}sudo iptables -L OUTGOING_LIMIT -v -n${NC}  - исходящая защита"
    echo -e "${MAGENTA}║${NC}  ${WHITE}sudo ufw status verbose${NC}                 - статус UFW"
    echo -e "${MAGENTA}║${NC}  ${WHITE}sudo fail2ban-client status${NC}             - статус fail2ban"
    echo -e "${MAGENTA}║${NC}  ${WHITE}sudo systemctl status nginx${NC}             - статус Nginx"
    echo -e "${MAGENTA}║${NC}  ${WHITE}sudo ss -tulpn${NC}                          - открытые порты"
    echo -e "${MAGENTA}║${NC}  ${WHITE}sudo netfilter-persistent save${NC}          - сохранить правила"
    echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ===================================================================
# УНИВЕРСАЛЬНОЕ УПРАВЛЕНИЕ ПОРТАМИ
# ===================================================================
remove_iptables_port_rules() {
    local chain="$1" proto="$2" port="$3" target="$4"
    command -v iptables >/dev/null 2>&1 || return 0
    while sudo iptables -D "$chain" -p "$proto" --dport "$port" -j "$target" 2>/dev/null; do :; done
}

add_iptables_port_rule() {
    local chain="$1" proto="$2" port="$3" target="$4"
    command -v iptables >/dev/null 2>&1 || return 0
    sudo iptables -C "$chain" -p "$proto" --dport "$port" -j "$target" 2>/dev/null || \
        sudo iptables -I "$chain" 1 -p "$proto" --dport "$port" -j "$target" 2>/dev/null || true
}

manage_one_firewall_port() {
    local action="$1" proto="$2" port="$3"
    local ufw_active=0 firewalld_active=0 ddos_chain=0 outgoing_chain=0
    if command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -q 'Status: active'; then ufw_active=1; fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then firewalld_active=1; fi
    if command -v iptables >/dev/null 2>&1 && sudo iptables -nL DDoS_PROTECT >/dev/null 2>&1; then ddos_chain=1; fi
    if command -v iptables >/dev/null 2>&1 && sudo iptables -nL OUTGOING_LIMIT >/dev/null 2>&1; then outgoing_chain=1; fi

    for p in $proto; do
        case "$action" in
            open)
                [ "$ufw_active" -eq 1 ] && sudo ufw allow "$port/$p" || true
                if [ "$firewalld_active" -eq 1 ]; then
                    sudo firewall-cmd --permanent --add-port="$port/$p" >/dev/null 2>&1 || true
                fi
                if [ "$ddos_chain" -eq 1 ] && [ "$p" = tcp ]; then
                    remove_iptables_port_rules DDoS_PROTECT tcp "$port" DROP
                    add_iptables_port_rule DDoS_PROTECT tcp "$port" ACCEPT
                fi
                ;;
            close)
                if [ "$ufw_active" -eq 1 ]; then
                    sudo ufw --force delete allow "$port/$p" >/dev/null 2>&1 || true
                    sudo ufw deny "$port/$p" >/dev/null 2>&1 || true
                fi
                if [ "$firewalld_active" -eq 1 ]; then
                    sudo firewall-cmd --permanent --remove-port="$port/$p" >/dev/null 2>&1 || true
                fi
                if [ "$ddos_chain" -eq 1 ] && [ "$p" = tcp ]; then
                    remove_iptables_port_rules DDoS_PROTECT tcp "$port" ACCEPT
                    add_iptables_port_rule DDoS_PROTECT tcp "$port" DROP
                fi
                ;;
            remove)
                if [ "$ufw_active" -eq 1 ]; then
                    sudo ufw --force delete allow "$port/$p" >/dev/null 2>&1 || true
                    sudo ufw --force delete deny "$port/$p" >/dev/null 2>&1 || true
                    sudo ufw --force delete reject "$port/$p" >/dev/null 2>&1 || true
                fi
                if [ "$firewalld_active" -eq 1 ]; then
                    sudo firewall-cmd --permanent --remove-port="$port/$p" >/dev/null 2>&1 || true
                fi
                if [ "$ddos_chain" -eq 1 ]; then
                    remove_iptables_port_rules DDoS_PROTECT "$p" "$port" ACCEPT
                    remove_iptables_port_rules DDoS_PROTECT "$p" "$port" DROP
                fi
                if [ "$outgoing_chain" -eq 1 ]; then
                    remove_iptables_port_rules OUTGOING_LIMIT "$p" "$port" ACCEPT
                    remove_iptables_port_rules OUTGOING_LIMIT "$p" "$port" DROP
                fi
                ;;
        esac
    done
    if [ "$firewalld_active" -eq 1 ]; then sudo firewall-cmd --reload >/dev/null 2>&1 || true; fi
    save_firewall_state || return 1
}

port_management_menu() {
    while true; do
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}    🔥 УНИВЕРСАЛЬНОЕ УПРАВЛЕНИЕ ПОРТАМИ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${WHITE}Работает с активными UFW, firewalld, DDoS_PROTECT и persistent iptables.${NC}"
    echo ""
    echo -e "  ${GREEN}[1]${NC} Открыть порт"
    echo -e "  ${RED}[2]${NC} Закрыть порт (оставить явный DROP)"
    echo -e "  ${YELLOW}[3]${NC} Удалить порт из всех механизмов защиты"
    echo -e "  ${CYAN}[4]${NC} Изменить порт"
    echo -e "  ${BLUE}[5]${NC} Показать состояние портов и firewall"
    echo -e "  ${MAGENTA}[6]${NC} Назад"
    echo ""
    read -r -p "Ваш выбор [1-6]: " port_action
    case "$port_action" in
        1|2|3|4)
            read -r -p "Введите порт (1-65535): " port_old
            if ! [[ "$port_old" =~ ^[0-9]+$ ]] || [ "$port_old" -lt 1 ] || [ "$port_old" -gt 65535 ]; then
                echo -e "${RED}Неверный порт.${NC}"; read -r -p "ENTER..."; return 1
            fi
            port_new="$port_old"
            if [ "$port_action" = 4 ]; then
                read -r -p "Введите новый порт (1-65535): " port_new
                if ! [[ "$port_new" =~ ^[0-9]+$ ]] || [ "$port_new" -lt 1 ] || [ "$port_new" -gt 65535 ] || [ "$port_new" -eq "$port_old" ]; then
                    echo -e "${RED}Неверный новый порт.${NC}"; read -r -p "ENTER..."; return 1
                fi
            fi
            if [ "$port_old" -eq "$SSH_PORT" ] || [ "$port_new" -eq "$SSH_PORT" ]; then
                echo -e "${RED}Текущий SSH-порт нельзя закрывать или менять этим пунктом.${NC}"
                echo -e "${YELLOW}Для SSH используйте пункт 3 главного меню.${NC}"
                read -r -p "ENTER..."; return 1
            fi
            read -r -p "Протокол [1=TCP, 2=UDP, 3=TCP+UDP]: " proto_choice
            case "$proto_choice" in 1) proto="tcp";; 2) proto="udp";; 3) proto=$'tcp\nudp';; *) echo -e "${RED}Неверный протокол.${NC}"; return 1;; esac
            backup_file="$BACKUP_BASE_DIR/ports_before_$(date +%Y%m%d_%H%M%S).rules"
            sudo iptables-save > "$backup_file" 2>/dev/null || true
            if [ "$port_action" = 1 ]; then
                manage_one_firewall_port open "$proto" "$port_old"
            elif [ "$port_action" = 2 ]; then
                manage_one_firewall_port close "$proto" "$port_old"
            elif [ "$port_action" = 3 ]; then
                read -r -p "Удалить порт $port_old из всех firewall-механизмов? Введите YES: " remove_confirm
                if [ "$remove_confirm" != "YES" ]; then
                    echo -e "${YELLOW}Удаление отменено.${NC}"; read -r -p "ENTER..."; continue
                fi
                manage_one_firewall_port remove "$proto" "$port_old"
            else
                manage_one_firewall_port close "$proto" "$port_old"
                manage_one_firewall_port open "$proto" "$port_new"
            fi
            echo -e "${GREEN}Операция применена и сохранена для перезагрузки.${NC}"
            echo -e "${WHITE}Резервная копия iptables: $backup_file${NC}"
            ;;
        5)
            echo -e "${CYAN}--- Слушающие порты ---${NC}"; ss -ltnup 2>/dev/null || true
            echo -e "${CYAN}--- UFW ---${NC}"; command -v ufw >/dev/null 2>&1 && sudo ufw status verbose || echo "не установлен"
            echo -e "${CYAN}--- firewalld ---${NC}"; command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --list-all || echo "не установлен/неактивен"
            echo -e "${CYAN}--- DDoS_PROTECT ---${NC}"; sudo iptables -L DDoS_PROTECT -n 2>/dev/null || echo "цепочка отсутствует"
            ;;
        6|*) return 0;;
    esac
    read -r -p "Нажмите ENTER, чтобы продолжить..."
    done
}

# ===================================================================
# БЕЗОПАСНЫЙ СНИМОК ПЕРЕД ОБНОВЛЕНИЕМ
# ===================================================================
create_update_snapshot() {
    local dir="$1"
    mkdir -p "$dir"
    iptables-save > "$dir/iptables.v4" 2>/dev/null || true
    command -v ip6tables-save >/dev/null 2>&1 && ip6tables-save > "$dir/iptables.v6" 2>/dev/null || true
    command -v ufw >/dev/null 2>&1 && ufw status verbose > "$dir/ufw.status" 2>/dev/null || true
    ss -ltnup > "$dir/listeners" 2>/dev/null || true
    systemctl list-units --type=service --state=active --no-legend > "$dir/active.services" 2>/dev/null || true
    for path in /etc/ssh /etc/ufw /etc/fail2ban /etc/nginx /etc/xray /usr/local/etc/xray /etc/systemd/system; do
        [ -e "$path" ] && cp -a "$path" "$dir/" 2>/dev/null || true
    done
}

check_update_services() {
    local out="$1"
    {
        echo "=== SSH listener ==="
        ss -ltnp 2>/dev/null | grep -E ":(${SSH_PORT:-22})\\b" || true
        echo "=== SSH units ==="
        systemctl is-active ssh.service sshd.service ssh.socket 2>/dev/null || true
        echo "=== firewall ==="
        ufw status verbose 2>/dev/null || true
        iptables -L INPUT -n --line-numbers 2>/dev/null || true
        echo "=== important services ==="
        for svc in fail2ban nginx xray x-ui qemu-guest-agent; do
            systemctl is-active "$svc" 2>/dev/null && echo "$svc: active" || true
        done
    } > "$out" 2>&1
}

# ===================================================================
# ОБНОВЛЕНИЕ И ОБСЛУЖИВАНИЕ СЕРВЕРА
# ===================================================================
server_update_menu() {
    while true; do
        clear
        echo -e "${CYAN}=============================================${NC}"
        echo -e "${CYAN}    🔄 ОБНОВЛЕНИЕ И ОБСЛУЖИВАНИЕ СЕРВЕРА${NC}"
        echo -e "${CYAN}=============================================${NC}"
        echo -e "${WHITE}Операции выполняются только после явного подтверждения.${NC}"
        echo ""
        echo -e "  ${GREEN}[1]${NC} Проверить доступные обновления"
        echo -e "  ${GREEN}[2]${NC} Показать обновления безопасности"
        echo -e "  ${YELLOW}[3]${NC} Установить только обновления безопасности"
        echo -e "  ${YELLOW}[4]${NC} Обновить все пакеты"
        echo -e "  ${BLUE}[5]${NC} Проверить необходимость перезагрузки"
        echo -e "  ${BLUE}[6]${NC} Показать состояние автоматических обновлений"
        echo -e "  ${YELLOW}[7]${NC} Настроить автоматические обновления (вкл/выкл)"
        echo -e "  ${YELLOW}[8]${NC} Безопасная очистка старых пакетов"
        echo -e "  ${MAGENTA}[9]${NC} Показать журналы обновлений"
        echo -e "  ${RED}[10]${NC} Перезагрузить сервер"
        echo -e "  ${WHITE}[11]${NC} Назад"
        echo ""
        read -r -p "Ваш выбор [1-11]: " update_choice
        case "$update_choice" in
            1)
                apt-get update
                echo ""
                apt list --upgradable 2>/dev/null || true
                read -r -p "Нажмите ENTER, чтобы продолжить..."
                ;;
            2)
                if command -v unattended-upgrade >/dev/null 2>&1; then
                    unattended-upgrade --dry-run --debug 2>&1 | grep -E 'Packages that will be upgraded|security|Allowed origins|No packages found' || true
                else
                    echo "unattended-upgrades не установлен."
                    echo "Установите его через пункт 7 или командой: sudo apt-get install unattended-upgrades"
                fi
                read -r -p "Нажмите ENTER, чтобы продолжить..."
                ;;
            3)
                if ! command -v unattended-upgrade >/dev/null 2>&1; then
                    echo "Устанавливаю компонент unattended-upgrades..."
                    apt-get update && apt-get install -y unattended-upgrades
                fi
                UPDATE_LOG="/var/log/ddos-server-security-updates.log"
                touch "$UPDATE_LOG" 2>/dev/null || UPDATE_LOG="/tmp/ddos-server-security-updates.log"
                echo ""
                echo "Проверяю, не занят ли менеджер пакетов..."
                if pgrep -x apt-get >/dev/null 2>&1 || pgrep -x apt >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1 || pgrep -x unattended-upgrade >/dev/null 2>&1; then
                    echo -e "${YELLOW}Операция отменена: apt/dpkg уже занят другим процессом.${NC}"
                    echo "Проверьте: sudo ps -ef | grep -E '[a]pt|[d]pkg|[u]nattended'"
                    read -r -p "Нажмите ENTER, чтобы продолжить..."
                    continue
                fi
                SNAPSHOT_DIR="/root/ddos_backup/update_$(date +%Y%m%d_%H%M%S)"
                create_update_snapshot "$SNAPSHOT_DIR"
                echo "Резервная копия конфигураций и состояния сохранена: $SNAPSHOT_DIR"
                echo ""
                echo "[1/5] Обновляю списки пакетов..."
                apt-get update
                echo "[2/5] Предварительный просмотр security-обновлений..."
                DRYRUN_LOG="$(mktemp)"
                DEBIAN_FRONTEND=noninteractive unattended-upgrade --dry-run --verbose 2>&1 | tee "$DRYRUN_LOG"
                if grep -Eiq '(openssh|^ssh |systemd|linux-image|linux-firmware|netplan|network-manager|cloud-init|nginx|fail2ban|ufw|iptables|xray|x-ui)' "$DRYRUN_LOG"; then
                    echo -e "${YELLOW}ВНИМАНИЕ: среди обновлений есть критичные системные или сетевые компоненты.${NC}"
                    echo "После обновления может потребоваться ручная проверка VPN, SSH и служб."
                    read -r -p "Подтвердить установку этих обновлений? [y/N]: " critical_confirm
                    if ! [[ "$critical_confirm" =~ ^[Yy]$ ]]; then
                        echo "Операция отменена. Резервная копия сохранена: $SNAPSHOT_DIR"
                        rm -f "$DRYRUN_LOG"
                        read -r -p "Нажмите ENTER, чтобы продолжить..."
                        continue
                    fi
                else
                    read -r -p "Установить показанные security-обновления? [y/N]: " confirm
                    if ! [[ "$confirm" =~ ^[Yy]$ ]]; then
                        echo "Операция отменена. Резервная копия сохранена: $SNAPSHOT_DIR"
                        rm -f "$DRYRUN_LOG"
                        read -r -p "Нажмите ENTER, чтобы продолжить..."
                        continue
                    fi
                fi
                rm -f "$DRYRUN_LOG"
                echo "[3/5] Установка началась. Вывод идёт на экран и в журнал: $UPDATE_LOG"
                echo "Пустая пауза не означает зависание; не нажимайте Ctrl+C без диагностики."
                echo "----- НАЧАЛО ОБНОВЛЕНИЯ $(date -Is) -----" | tee -a "$UPDATE_LOG"
                if DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a stdbuf -oL -eL unattended-upgrade --verbose 2>&1 | tee -a "$UPDATE_LOG"; then
                    echo "----- КОНЕЦ ОБНОВЛЕНИЯ $(date -Is) -----" | tee -a "$UPDATE_LOG"
                    echo -e "${GREEN}Установка завершена без ошибки.${NC}"
                else
                    rc=${PIPESTATUS[0]}
                    echo "----- ОШИБКА ОБНОВЛЕНИЯ $(date -Is), код $rc -----" | tee -a "$UPDATE_LOG"
                    echo -e "${RED}Обновление завершилось с ошибкой. Автоматического отката пакетов не выполняется.${NC}"
                fi
                echo "[4/5] Проверяю dpkg, SSH, firewall и важные службы..."
                dpkg --audit || true
                POSTCHECK="${SNAPSHOT_DIR}/after-update"
                mkdir -p "$POSTCHECK"
                check_update_services "$POSTCHECK/services"
                cat "$POSTCHECK/services"
                if [ -e /run/reboot-required ]; then
                    echo -e "${YELLOW}[5/5] Требуется ручная перезагрузка. Сначала проверьте SSH-порт и VPN во втором сеансе.${NC}"
                    [ -f /run/reboot-required.pkgs ] && cat /run/reboot-required.pkgs
                else
                    echo -e "${GREEN}[5/5] Перезагрузка не требуется.${NC}"
                fi
                echo "Резервная копия: $SNAPSHOT_DIR"
                echo "Журнал: $UPDATE_LOG"
                read -r -p "Нажмите ENTER, чтобы продолжить..."
                ;;
            4)
                apt-get update
                echo ""
                apt-get -s upgrade
                echo ""
                read -r -p "Установить все доступные обновления? [y/N]: " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    DEBIAN_FRONTEND=noninteractive apt-get upgrade
                else
                    echo "Операция отменена."
                fi
                read -r -p "Нажмите ENTER, чтобы продолжить..."
                ;;
            5)
                if [ -e /run/reboot-required ]; then
                    echo -e "${YELLOW}Требуется перезагрузка сервера.${NC}"
                    [ -f /run/reboot-required.pkgs ] && cat /run/reboot-required.pkgs
                else
                    echo -e "${GREEN}Перезагрузка по результатам проверки не требуется.${NC}"
                fi
                dpkg --audit || true
                read -r -p "Нажмите ENTER, чтобы продолжить..."
                ;;
            6)
                if command -v unattended-upgrade >/dev/null 2>&1; then
                    echo "unattended-upgrades: установлен"
                    [ -f /etc/apt/apt.conf.d/20auto-upgrades ] && cat /etc/apt/apt.conf.d/20auto-upgrades || echo "20auto-upgrades не найден"
                    systemctl is-active apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
                else
                    echo "unattended-upgrades: не установлен"
                fi
                read -r -p "Нажмите ENTER, чтобы продолжить..."
                ;;
            7)
                echo ""
                echo "[1] Отключить автоматическую проверку и установку обновлений"
                echo "[2] Включить автоматические security-обновления"
                echo "[3] Назад"
                read -r -p "Выберите действие [1-3]: " auto_choice
                mkdir -p /root/ddos_backup/apt
                [ -f /etc/apt/apt.conf.d/20auto-upgrades ] && cp -a /etc/apt/apt.conf.d/20auto-upgrades /root/ddos_backup/apt/20auto-upgrades.$(date +%Y%m%d_%H%M%S) || true
                case "$auto_choice" in
                    1)
                        cat > /etc/apt/apt.conf.d/20auto-upgrades <<'APTCONF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
APTCONF
                        systemctl disable --now unattended-upgrades.service >/dev/null 2>&1 || true
                        systemctl disable --now apt-daily-upgrade.timer apt-daily.timer >/dev/null 2>&1 || true
                        echo "Автоматические обновления отключены. Пакеты устанавливаются только вручную."
                        echo "Автоматическая перезагрузка не включалась."
                        ;;
                    2)
                        apt-get update && apt-get install -y unattended-upgrades
                        cat > /etc/apt/apt.conf.d/20auto-upgrades <<'APTCONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APTCONF
                        systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
                        systemctl enable --now unattended-upgrades.service >/dev/null 2>&1 || true
                        echo "Автоматические security-обновления включены. Автоматическая перезагрузка не включалась."
                        ;;
                    *) echo "Операция отменена." ;;
                esac
                read -r -p "Нажмите ENTER, чтобы продолжить..."
                ;;
            8)
                apt-get -s autoremove
                echo ""
                read -r -p "Удалить показанные ненужные пакеты? [y/N]: " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    apt-get autoremove
                else
                    echo "Операция отменена."
                fi
                read -r -p "Нажмите ENTER, чтобы продолжить..."
                ;;
            9)
                echo "=== Последние операции dpkg ==="
                grep -E ' (install|upgrade|remove) ' /var/log/dpkg.log 2>/dev/null | tail -50 || true
                echo ""
                echo "=== unattended-upgrades ==="
                find /var/log/unattended-upgrades -type f -maxdepth 1 -print 2>/dev/null | sort | tail -5 | while read -r f; do echo "--- $f"; tail -20 "$f"; done
                read -r -p "Нажмите ENTER, чтобы продолжить..."
                ;;
            10)
                if [ -e /run/reboot-required ]; then
                    echo "Система сообщает, что перезагрузка необходима."
                fi
                echo "Перед перезагрузкой убедитесь, что текущее SSH-соединение работает на порту ${SSH_PORT}."
                read -r -p "Перезагрузить сервер сейчас? [y/N]: " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    systemctl reboot
                    return 0
                fi
                echo "Перезагрузка отменена."
                read -r -p "Нажмите ENTER, чтобы продолжить..."
                ;;
            11|*) return 0 ;;
        esac
    done
}

# ===================================================================
# ОСНОВНОЕ МЕНЮ
# ===================================================================
main() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}❌ Запустите с sudo: sudo $0 [--restore]${NC}"
        exit 1
    fi
    if [[ "${1:-}" == "--restore" ]] || [[ "${1:-}" == "-r" ]]; then
        restore_backup
        exit 0
    fi
    if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
        echo -e "${GREEN}Использование:${NC}"
        echo "  sudo $0              - Применить защиту"
        echo "  sudo $0 --restore    - Полный откат"
        echo "  sudo $0 -r           - Полный откат (сокращённо)"
        echo ""
        echo -e "${CYAN}Поддерживаемые версии Ubuntu:${NC}"
        echo "  18.04, 20.04, 22.04, 24.04 и новее"
        echo ""
        echo -e "${GREEN}✅ Особенности:${NC}"
        echo "  - Универсальное определение SSH порта через sshd -T"
        echo "  - Универсальный перезапуск SSH (sshd/ssh/socket)"
        echo "  - Автоопределение и исправление переопределений в sshd_config.d/"
        echo "  - ПРИНУДИТЕЛЬНАЯ установка UFW"
        echo "  - Принудительное отключение IPv6"
        echo "  - HTTP/HTTPS — БЕЗ ОГРАНИЧЕНИЙ"
        echo "  - Xray порты — БЕЗ ОГРАНИЧЕНИЙ"
        echo "  - Входящая + исходящая защита"
        echo "  - Тройная автозагрузка"
        echo "  - БЕЗОПАСНОЕ применение правил (SSH не теряется)"
        echo "  - Универсальное управление аутентификацией SSH (через sshd -T)"
        echo "  - Безопасное управление IPv6 (без GRUB)"
        echo "  - Сетевые инструменты (диагностика, htop)"
        echo "  - Безопасная очистка системы (освобождение места, ncdu)"
        echo "  - Управление UFW (фаервол)"
        echo "  - Редактирование конфигов с авто-бэкапом"
        echo "  - Тест производительности сервера (bench.sh)"
        echo "  - Автоматическое добавление недостающих параметров в sshd_config"
        echo "  - Генерация или вставка SSH-ключей"
        echo "  - Показ обоих ключей (приватного и публичного) при генерации"
        echo "  - БЕЗОПАСНОЕ УДАЛЕНИЕ приватного ключа с сервера после генерации"
        echo "  - Автоматический откат при неудачном подключении"
        echo "  - Все бэкапы в одной папке /root/ddos_backup/ (без мусора в корне)"
        exit 0
    fi

    if [ ! -f "/root/.ddos_backup_created" ]; then
        echo -e "${CYAN}📌 Первый запуск скрипта! Создаём бэкап текущих настроек...${NC}"
        create_backup
        echo -e "${GREEN}✅ Бэкап создан: ${WHITE}$BACKUP_DIR${NC}"
        touch "/root/.ddos_backup_created"
        echo ""
    fi
    
    echo -e "${GREEN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}  ${BOLD}🛡️  ЗАЩИТА + XRAY (С UFW)${NC}"
    echo -e "${GREEN}╠═══════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}Ubuntu:${NC} $UBUNTU_VERSION"
    echo -e "${GREEN}║${NC}  ${CYAN}iptables:${NC} $IPTABLES_TYPE"
    echo -e "${GREEN}║${NC}  ${CYAN}IPv6:${NC} $IPV6_AVAILABLE"
    echo -e "${GREEN}║${NC}  ${CYAN}SSH порт:${NC} $SSH_PORT"
    echo -e "${GREEN}║${NC}  ${CYAN}HTTP/HTTPS:${NC} ✅ БЕЗ ОГРАНИЧЕНИЙ"
    echo -e "${GREEN}║${NC}  ${CYAN}Xray:${NC} ✅ АВТООПРЕДЕЛЕНИЕ + ИСКЛЮЧЕНИЯ"
    echo -e "${GREEN}║${NC}  ${CYAN}UFW:${NC} ✅ ПРИНУДИТЕЛЬНАЯ УСТАНОВКА"
    echo -e "${GREEN}║${NC}  ${CYAN}Автозагрузка:${NC} ✅ ТРОЙНАЯ"
    echo -e "${GREEN}║${NC}  ${CYAN}SSH безопасность:${NC} ✅ СОХРАНЕНИЕ СЕССИИ"
    echo -e "${GREEN}╚═══════════════════════════════════════════════╝${NC}"
    
    echo -e "\n${WHITE}Выберите действие:${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} Применить защиту (с UFW)"
    echo -e "  ${YELLOW}2)${NC} Полный откат к исходному состоянию"
    echo -e "  ${CYAN}3)${NC} 🔒 СМЕНИТЬ ПОРТ SSH"
    echo -e "  ${RED}4)${NC} 🔥 УПРАВЛЕНИЕ ПОРТАМИ (UFW/firewalld/iptables)"
    echo -e "  ${BLUE}5)${NC} 🔄 ОБНОВЛЕНИЕ И ОБСЛУЖИВАНИЕ СЕРВЕРА"
    echo -e "  ${BLUE}6)${NC} 🔐 УПРАВЛЕНИЕ АУТЕНТИФИКАЦИЕЙ SSH"
    echo -e "  ${MAGENTA}7)${NC} 🔑 НАСТРОИТЬ SSH-КЛЮЧИ"
    echo -e "  ${CYAN}8)${NC} 🌐 БЕЗОПАСНОЕ УПРАВЛЕНИЕ IPV6"
    echo -e "  ${GREEN}9)${NC} 🔧 СЕТЕВЫЕ ИНСТРУМЕНТЫ"
    echo -e "  ${YELLOW}10)${NC} 🧹 БЕЗОПАСНАЯ ОЧИСТКА СИСТЕМЫ"
    echo -e "  ${BLUE}11)${NC} 🔥 УПРАВЛЕНИЕ UFW"
    echo -e "  ${MAGENTA}12)${NC} 📝 РЕДАКТИРОВАНИЕ КОНФИГОВ"
    echo -e "  ${CYAN}13)${NC} 📊 ТЕСТ ПРОИЗВОДИТЕЛЬНОСТИ"
    echo -e "  ${RED}14)${NC} Выйти"
    echo ""
    read -r -p "Ваш выбор [1-14]: " choice
    case $choice in
        1) apply_protection ;;
        2) restore_backup ;;
        3) change_ssh_port ;;
        4) port_management_menu ;;
        5) server_update_menu ;;
        6) manage_ssh_auth ;;
        7) generate_ssh_keys ;;
        8) manage_ipv6 ;;
        9) network_tools_menu ;;
        10) system_cleanup ;;
        11) manage_ufw ;;
        12) edit_configs ;;
        13) run_benchmark ;;
        14) echo -e "\n${YELLOW}👋 Выход...${NC}"; exit 0 ;;
        *) echo -e "\n${RED}❌ Неверный выбор!${NC}"; exit 1 ;;
    esac
}

main "$@"
