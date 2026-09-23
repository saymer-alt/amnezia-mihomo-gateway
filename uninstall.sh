#!/bin/bash
# Удаление маршрутизации Amnezia -> Mihomo

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

STATE_DIR="${AMG_STATE_DIR:-/var/lib/amnezia-mihomo-gateway}"
DOCKER_DAEMON_FILE="${AMG_DOCKER_DAEMON_FILE:-/etc/docker/daemon.json}"
RT_TABLES_FILE="${AMG_RT_TABLES_FILE:-/etc/iproute2/rt_tables}"
SYSTEMD_DIR="${AMG_SYSTEMD_DIR:-/etc/systemd/system}"
SBIN_DIR="${AMG_SBIN_DIR:-/usr/local/sbin}"
SYSCTL_FILE="${AMG_SYSCTL_FILE:-/etc/sysctl.d/99-amnezia-mihomo.conf}"
TABLE_ID="100"
TABLE_NAME="mihomo"

echo -e "${YELLOW}=== Удаление скриптов маршрутизации ===${NC}"

# Остановка и отключение служб
systemctl disable --now warp-docker-routing.service 2>/dev/null || true
systemctl disable --now check-warp-routing.timer 2>/dev/null || true
systemctl disable --now check-warp-routing.service 2>/dev/null || true

# Вызов очистки iptables/ip rule/routes, пока generated script ещё на месте.
if [ -f "$SBIN_DIR/warp-docker-routing.sh" ]; then
    "$SBIN_DIR/warp-docker-routing.sh" cleanup
fi

# Удаляем Docker DNS override только если installer действительно владеет файлом.
# Для legacy-установок без state marker распознаём только точное содержимое,
# которое старый installer создавал сам: {"dns": ["<docker0-gateway>"]}.
DOCKER_RESTART_NEEDED=0
if [ -f "$DOCKER_DAEMON_FILE" ]; then
    REMOVE_DOCKER_DAEMON=0

    if [ -f "$STATE_DIR/docker_daemon_created" ] && [ -f "$STATE_DIR/docker_daemon_sha256" ]; then
        EXPECTED_SHA=$(cat "$STATE_DIR/docker_daemon_sha256" 2>/dev/null || true)
        CURRENT_SHA=$(sha256sum "$DOCKER_DAEMON_FILE" 2>/dev/null | awk '{print $1}')
        if [ -n "$EXPECTED_SHA" ] && [ "$CURRENT_SHA" = "$EXPECTED_SHA" ]; then
            REMOVE_DOCKER_DAEMON=1
        else
            echo -e "${YELLOW}Docker daemon.json был изменён после установки; оставляю его без изменений.${NC}"
        fi
    else
        DOCKER_GW=$(ip -4 addr show docker0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || true)
        if [ -n "$DOCKER_GW" ]; then
            LEGACY_EXPECTED=$(mktemp)
            printf '{\n  "dns": ["%s"]\n}\n' "$DOCKER_GW" > "$LEGACY_EXPECTED"
            if cmp -s "$DOCKER_DAEMON_FILE" "$LEGACY_EXPECTED"; then
                REMOVE_DOCKER_DAEMON=1
                echo -e "${YELLOW}Найден legacy Docker DNS override старого installer'а; удаляю его.${NC}"
            fi
            rm -f "$LEGACY_EXPECTED"
        fi
    fi

    if [ "$REMOVE_DOCKER_DAEMON" -eq 1 ]; then
        rm -f "$DOCKER_DAEMON_FILE"
        DOCKER_RESTART_NEEDED=1
    fi
fi

if [ "$DOCKER_RESTART_NEEDED" -eq 1 ]; then
    if ! systemctl restart docker; then
        echo -e "${RED}Предупреждение: daemon.json удалён, но Docker не удалось перезапустить.${NC}"
    fi
fi

# Удаляем регистрацию таблицы только когда она больше никем не используется.
if [ -f "$RT_TABLES_FILE" ] &&
   grep -Eq "^[[:space:]]*$TABLE_ID[[:space:]]+$TABLE_NAME[[:space:]]*$" "$RT_TABLES_FILE"; then
    if ! ip rule show | grep -Eq "lookup ($TABLE_ID|$TABLE_NAME)( |$)" &&
       ! ip route show table "$TABLE_ID" 2>/dev/null | grep -q .; then
        sed -i -E "/^[[:space:]]*$TABLE_ID[[:space:]]+$TABLE_NAME[[:space:]]*$/d" "$RT_TABLES_FILE"
    else
        echo -e "${YELLOW}Таблица $TABLE_ID/$TABLE_NAME ещё используется; запись в rt_tables оставлена.${NC}"
    fi
fi

# Удаление generated files
rm -f "$SYSTEMD_DIR/warp-docker-routing.service"
rm -f "$SYSTEMD_DIR/check-warp-routing.service"
rm -f "$SYSTEMD_DIR/check-warp-routing.timer"
rm -f "$SBIN_DIR/warp-docker-routing.sh"
rm -f "$SBIN_DIR/check-warp-routing.sh"
rm -f "$SYSCTL_FILE"

# State markers нужны только для безопасного удаления ресурсов, созданных installer'ом.
rm -f "$STATE_DIR/docker_daemon_created"
rm -f "$STATE_DIR/docker_daemon_sha256"
rm -f "$STATE_DIR/docker_dns_gateway"
rm -f "$STATE_DIR/rt_table_added"
rmdir "$STATE_DIR" 2>/dev/null || true

systemctl daemon-reload

echo -e "${GREEN}Маршрутизация проекта удалена.${NC}"
echo -e "${YELLOW}Важно: live sysctl, systemd-resolved/resolv.conf и пропатченный config.yaml Mihomo"
echo -e "пока не восстанавливаются автоматически; проверь README перед ручным rollback.${NC}"
