#!/bin/bash
# =========================================================
# AmneziaAWG to Mihomo (TUN) Routing Installer (Production Ready v1.5)
# Включает: полное отключение systemd-resolved, статический resolv.conf,
# разделение DNS, именованную таблицу, логирование и кросс-дистрибутивность.
# =========================================================

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}=== Запуск установки маршрутизации Amnezia -> Mihomo ===${NC}"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Ошибка: Этот скрипт должен быть запущен от имени root.${NC}" 
   exit 1
fi

if ! command -v docker &> /dev/null; then
    echo -e "${RED}Ошибка: Docker не установлен.${NC}"
    exit 1
fi

# 1. Автоопределение параметров
echo -e "${YELLOW}[*] Поиск контейнера Amnezia AWG...${NC}"
AWG_CONTAINER=$(docker ps --filter "name=amnezia-awg" --format "{{.Names}}" | head -n1)
if [ -z "$AWG_CONTAINER" ]; then
    echo -e "${RED}Ошибка: Контейнер amnezia-awg не найден! Убедись, что Amnezia запущена.${NC}"
    exit 1
fi
echo -e "${GREEN}Найден контейнер: $AWG_CONTAINER${NC}"

NETWORK_NAME=$(docker inspect "$AWG_CONTAINER" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' | grep 'amnezia' | head -n1)
if [ -z "$NETWORK_NAME" ]; then
    NETWORK_NAME=$(docker inspect "$AWG_CONTAINER" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' | head -n1)
fi

DOCKER_NETS=$(docker network inspect "$NETWORK_NAME" --format='{{range .IPAM.Config}}{{.Subnet}}{{end}}')
if [ -z "$DOCKER_NETS" ]; then
    echo -e "${RED}Ошибка: Не удалось определить подсеть Docker.${NC}"
    exit 1
fi

WG_PORT=$(docker port "$AWG_CONTAINER" | grep '/udp' | head -n1 | awk -F'/' '{print $1}')
if [ -z "$WG_PORT" ]; then
    WG_PORT=$(docker inspect "$AWG_CONTAINER" --format '{{range $k, $v := .NetworkSettings.Ports}}{{$k}}{{end}}' | grep '/udp' | head -n1 | awk -F'/' '{print $1}')
fi
if [ -z "$WG_PORT" ]; then
    echo -e "${RED}Ошибка: Не удалось определить порт AWG (UDP).${NC}"
    exit 1
fi

HOST_IF=$(ip -o -4 route show to default | awk '{print $5}')
PROXY_IF="tun-mihomo"
TABLE_ID="100"
TABLE_NAME="mihomo"

echo -e "${GREEN}Настройки определены:${NC}"
echo -e " - Сеть Docker: $DOCKER_NETS"
echo -e " - Порт AWG:    $WG_PORT"
echo -e " - Интерфейс:   $HOST_IF"
echo -e " - Прокси TUN:  $PROXY_IF"

# 2. Настройка ядра
echo -e "${YELLOW}[*] Настройка sysctl...${NC}"
cat << 'EOF' > /etc/sysctl.d/99-amnezia-mihomo.conf
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
EOF
sysctl -p /etc/sysctl.d/99-amnezia-mihomo.conf > /dev/null
for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$i"; done

# 2.5 Именованная таблица маршрутизации
if ! grep -q "^$TABLE_ID $TABLE_NAME$" /etc/iproute2/rt_tables; then
    echo "$TABLE_ID $TABLE_NAME" >> /etc/iproute2/rt_tables
fi

# 2.6 КРИТИЧЕСКИЙ ФИКС: Жесткая статика DNS для хоста
echo -e "${YELLOW}[*] Настройка DNS (отключение systemd-resolved и статика resolv.conf)...${NC}"
# Отключаем systemd-resolved, если он активен (Ubuntu)
systemctl disable --now systemd-resolved 2>/dev/null || true

# Снимаем блокировку immutable, если она была
chattr -i /etc/resolv.conf 2>/dev/null || true
# Удаляем симлинк или старый файл
rm -f /etc/resolv.conf
# Пишем прямые DNS сервера
cat << 'EOF' > /etc/resolv.conf
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:2 attempts:3
EOF
# Блокируем файл от перезаписи Mihomo, NetworkManager или DHCP
chattr +i /etc/resolv.conf

# Docker использует шлюз docker0, чтобы получать фейковые IP от Mihomo напрямую
DOCKER_GW=$(ip -4 addr show docker0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
if [ -n "$DOCKER_GW" ]; then
    echo -e "${YELLOW}[*] Настройка Docker DNS (daemon.json -> $DOCKER_GW)...${NC}"
    if [ ! -f /etc/docker/daemon.json ]; then
        cat << EOF > /etc/docker/daemon.json
{
  "dns": ["$DOCKER_GW"]
}
EOF
        systemctl restart docker
    else
        echo -e "${YELLOW}    Внимание: /etc/docker/daemon.json уже существует. Убедитесь, что в нем прописан DNS: [\"$DOCKER_GW\"]${NC}"
    fi
fi

# 3. Скрипт маршрутизации
echo -e "${YELLOW}[*] Создание скрипта маршрутизации...${NC}"
cat << EOF > /usr/local/sbin/warp-docker-routing.sh
#!/bin/sh
set -eu

PROXY_IF="$PROXY_IF"
DOCKER_NETS="$DOCKER_NETS"
WG_PORT="$WG_PORT"
TABLE_ID="$TABLE_ID"
HOST_IF="$HOST_IF"

if [ "\${1:-}" = "cleanup" ]; then
    logger "warp-routing: Выполняется очистка правил..."
    ip rule del fwmark 0x88 lookup main priority 40 2>/dev/null || true
    ip rule del from "\$DOCKER_NETS" lookup "\$TABLE_ID" priority 100 2>/dev/null || true
    ip route del default table "\$TABLE_ID" 2>/dev/null || true
    ip route del 240.0.0.0/4 dev "\$PROXY_IF" 2>/dev/null || true
    iptables -t mangle -D PREROUTING -s "\$DOCKER_NETS" -p udp --sport "\$WG_PORT" -j MARK --set-mark 0x88 2>/dev/null || true
    iptables -t mangle -D FORWARD -s "\$DOCKER_NETS" -o "\$PROXY_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    iptables -t nat -D POSTROUTING -o "\$PROXY_IF" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -s "\$DOCKER_NETS" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -d "\$DOCKER_NETS" -j ACCEPT 2>/dev/null || true
    logger "warp-routing: Очистка завершена."
    exit 0
fi

logger "warp-routing: Запуск применения правил..."

for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "\$i"; done

if ! ip link show "\$PROXY_IF" >/dev/null 2>&1; then
    logger "warp-routing: ОШИБКА - Интерфейс '\$PROXY_IF' не существует."
    echo "Error: Interface '\$PROXY_IF' does not exist."
    exit 1
fi

# Очистка старых правил перед добавлением
ip rule del fwmark 0x88 lookup main priority 40 2>/dev/null || true
ip rule del from "\$DOCKER_NETS" lookup "\$TABLE_ID" priority 100 2>/dev/null || true
iptables -t mangle -D PREROUTING -s "\$DOCKER_NETS" -p udp --sport "\$WG_PORT" -j MARK --set-mark 0x88 2>/dev/null || true
iptables -t nat -D POSTROUTING -o "\$PROXY_IF" -j MASQUERADE 2>/dev/null || true
iptables -D FORWARD -s "\$DOCKER_NETS" -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -d "\$DOCKER_NETS" -j ACCEPT 2>/dev/null || true

# Маршруты
ip route replace default dev "\$PROXY_IF" table "\$TABLE_ID"
ip route replace 240.0.0.0/4 dev "\$PROXY_IF"
logger "warp-routing: Маршруты обновлены."

ip rule add from "\$DOCKER_NETS" lookup "\$TABLE_ID" priority 100 2>/dev/null || true
ip rule add fwmark 0x88 lookup main priority 40 2>/dev/null || true

# Iptables правила
iptables -t mangle -C PREROUTING -s "\$DOCKER_NETS" -p udp --sport "\$WG_PORT" -j MARK --set-mark 0x88 2>/dev/null || \
iptables -t mangle -I PREROUTING 1 -s "\$DOCKER_NETS" -p udp --sport "\$WG_PORT" -j MARK --set-mark 0x88

iptables -t mangle -C FORWARD -s "\$DOCKER_NETS" -o "\$PROXY_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
iptables -t mangle -A FORWARD -s "\$DOCKER_NETS" -o "\$PROXY_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

iptables -t nat -C POSTROUTING -o "\$PROXY_IF" -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -o "\$PROXY_IF" -j MASQUERADE

iptables -C FORWARD -s "\$DOCKER_NETS" -j ACCEPT 2>/dev/null || \
iptables -I FORWARD 1 -s "\$DOCKER_NETS" -j ACCEPT

iptables -C FORWARD -d "\$DOCKER_NETS" -j ACCEPT 2>/dev/null || \
iptables -I FORWARD 2 -d "\$DOCKER_NETS" -j ACCEPT

logger "warp-routing: Правила успешно применены."
EOF
chmod +x /usr/local/sbin/warp-docker-routing.sh

# 4. Systemd
echo -e "${YELLOW}[*] Создание systemd сервиса...${NC}"
cat << 'EOF' > /etc/systemd/system/warp-docker-routing.service
[Unit]
Description=Route Amnezia Docker traffic through Mihomo TUN
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/warp-docker-routing.sh
ExecStop=/usr/local/sbin/warp-docker-routing.sh cleanup
RemainAfterExit=yes
ExecReload=/usr/local/sbin/warp-docker-routing.sh

[Install]
WantedBy=multi-user.target
EOF

# 5. Watchdog
echo -e "${YELLOW}[*] Настройка watchdog-таймера...${NC}"
cat << EOF > /usr/local/sbin/check-warp-routing.sh
#!/bin/sh
PROXY_IF="$PROXY_IF"
DOCKER_NETS="$DOCKER_NETS"

if ! ip link show "\$PROXY_IF" >/dev/null 2>&1; then
    logger "warp-check: Интерфейс \$PROXY_IF отсутствует. Пытаюсь перезапустить Mihomo..."
    if systemctl list-unit-files | grep -q "^mihomo.service"; then
        systemctl restart mihomo.service
    elif command -v docker >/dev/null 2>&1; then
        MIHOMO_C=\$(docker ps -a --format '{{.Names}}' | grep "mihomo" | head -n1)
        if [ -n "\$MIHOMO_C" ]; then
            docker restart "\$MIHOMO_C"
        fi
    fi
    for i in \$(seq 1 10); do
        if ip link show "\$PROXY_IF" >/dev/null 2>&1; then break; fi
        sleep 2
    done
fi

if ! ip rule | grep -q "from \$DOCKER_NETS lookup 100"; then
    logger "warp-check: Правила слетели. Восстанавливаю..."
    systemctl restart warp-docker-routing.service
    exit 1
fi
exit 0
EOF
chmod +x /usr/local/sbin/check-warp-routing.sh

cat << 'EOF' > /etc/systemd/system/check-warp-routing.service
[Unit]
Description=Check WARP Docker routing

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/check-warp-routing.sh
EOF

cat << 'EOF' > /etc/systemd/system/check-warp-routing.timer
[Unit]
Description=Periodic WARP routing check

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
EOF

# 6. Запуск
echo -e "${YELLOW}[*] Перезагрузка systemd и запуск...${NC}"
systemctl daemon-reload
systemctl enable --now warp-docker-routing.service
systemctl enable --now check-warp-routing.timer

echo -e "${GREEN}========================================================${NC}"
echo -e "${GREEN}УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО!${NC}"
echo -e "${GREEN}========================================================${NC}"
echo -e "${YELLOW}ВНИМАНИЕ! Обязательные настройки в config.yaml Mihomo:${NC}"
echo -e "  1. fake-ip-range: 240.0.0.1/4  (использовать только этот диапазон!)"
echo -e "  2. inet4-address: 198.18.0.1/30"
echo -e "  3. auto-route: false           (строго false!)${NC}"
