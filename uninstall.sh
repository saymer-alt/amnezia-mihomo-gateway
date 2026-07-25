#!/bin/bash
# Удаление маршрутизации Amnezia -> Mihomo

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}=== Удаление скриптов маршрутизации ===${NC}"

# Остановка и отключение служ
systemctl disable --now warp-docker-routing.service 2>/dev/null || true
systemctl disable --now check-warp-routing.timer 2>/dev/null || true
systemctl disable --now check-warp-routing.service 2>/dev/null || true

# Вызов очистки iptables (если скрипт еще на месте)
if [ -f /usr/local/sbin/warp-docker-routing.sh ]; then
    /usr/local/sbin/warp-docker-routing.sh cleanup
fi

# Удаление файлов
rm -f /etc/systemd/system/warp-docker-routing.service
rm -f /etc/systemd/system/check-warp-routing.service
rm -f /etc/systemd/system/check-warp-routing.timer
rm -f /usr/local/sbin/warp-docker-routing.sh
rm -f /usr/local/sbin/check-warp-routing.sh
rm -f /etc/sysctl.d/99-amnezia-mihomo.conf

systemctl daemon-reload

echo -e "${GREEN}Удаление завершено. Сервер вернулся к стандартным настройкам.${NC}"
