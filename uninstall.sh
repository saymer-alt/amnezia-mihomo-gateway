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

# Удаляем регистрацию таблицы только если installer сам добавил её и
# после routing cleanup таблица больше никем не используется.
if [ -f "$STATE_DIR/rt_table_added" ] &&
   [ -f "$RT_TABLES_FILE" ] &&
   grep -Eq "^[[:space:]]*${TABLE_ID}[[:space:]]+${TABLE_NAME}[[:space:]]*$" "$RT_TABLES_FILE"; then
    if ! ip rule show | grep -Eq "lookup ($TABLE_ID|$TABLE_NAME)( |$)" &&
       ! ip route show table "$TABLE_ID" 2>/dev/null | grep -q .; then
        sed -i -E "/^[[:space:]]*${TABLE_ID}[[:space:]]+${TABLE_NAME}[[:space:]]*$/d" "$RT_TABLES_FILE"
    else
        echo -e "${YELLOW}Таблица $TABLE_ID/$TABLE_NAME ещё используется; запись в rt_tables оставлена.${NC}"
    fi
elif [ -f "$RT_TABLES_FILE" ] &&
     grep -Eq "^[[:space:]]*${TABLE_ID}[[:space:]]+${TABLE_NAME}[[:space:]]*$" "$RT_TABLES_FILE"; then
    echo -e "${YELLOW}Найдена legacy-запись $TABLE_ID $TABLE_NAME без ownership marker; автоматически не удаляю.${NC}"
fi

# Восстанавливаем точный pre-install config Mihomo только когда можем доказать,
# что текущий файл всё ещё равен версии, пропатченной installer'ом.
MIHOMO_RESTORED=0
if [ -f "$STATE_DIR/mihomo_config_original.yaml" ] &&
   [ -f "$STATE_DIR/mihomo_config_path" ] &&
   [ -f "$STATE_DIR/mihomo_patched_sha256" ]; then
    MIHOMO_CONFIG_PATH=$(cat "$STATE_DIR/mihomo_config_path" 2>/dev/null || true)
    EXPECTED_PATCHED_SHA=$(cat "$STATE_DIR/mihomo_patched_sha256" 2>/dev/null || true)

    if [ -f "$STATE_DIR/mihomo_config_diverged" ]; then
        echo -e "${YELLOW}Mihomo config менялся после установки; automatic rollback пропущен, чтобы не затереть изменения администратора.${NC}"
        echo -e "${YELLOW}Оригинальный snapshot сохранён: $STATE_DIR/mihomo_config_original.yaml${NC}"
    elif [ -n "$MIHOMO_CONFIG_PATH" ] && [ -f "$MIHOMO_CONFIG_PATH" ]; then
        CURRENT_MIHOMO_SHA=$(sha256sum "$MIHOMO_CONFIG_PATH" 2>/dev/null | awk '{print $1}')
        if [ -n "$EXPECTED_PATCHED_SHA" ] && [ "$CURRENT_MIHOMO_SHA" = "$EXPECTED_PATCHED_SHA" ]; then
            RESTORE_GUARD="$MIHOMO_CONFIG_PATH.bak.before-uninstall.$(date +%s)"
            cp "$MIHOMO_CONFIG_PATH" "$RESTORE_GUARD"
            cp "$STATE_DIR/mihomo_config_original.yaml" "$MIHOMO_CONFIG_PATH"

            MIHOMO_BIN=$(command -v mihomo 2>/dev/null || true)
            if [ -z "$MIHOMO_BIN" ] && [ -x /usr/local/bin/mihomo ]; then
                MIHOMO_BIN=/usr/local/bin/mihomo
            fi

            if [ -n "$MIHOMO_BIN" ] &&
               ! "$MIHOMO_BIN" -t -d "$(dirname "$MIHOMO_CONFIG_PATH")" >/dev/null 2>&1; then
                cp "$RESTORE_GUARD" "$MIHOMO_CONFIG_PATH"
                echo -e "${RED}Восстановленный pre-install config не прошёл проверку Mihomo; текущий config возвращён.${NC}"
                echo -e "${YELLOW}Snapshot оставлен для ручной проверки: $STATE_DIR/mihomo_config_original.yaml${NC}"
            else
                MIHOMO_RESTORED=1
                echo -e "${GREEN}Mihomo config восстановлен в точное pre-install состояние.${NC}"
            fi
        else
            echo -e "${YELLOW}Mihomo config был изменён после установки; automatic rollback пропущен.${NC}"
            echo -e "${YELLOW}Оригинальный snapshot сохранён: $STATE_DIR/mihomo_config_original.yaml${NC}"
        fi
    else
        echo -e "${YELLOW}Не найден исходный путь config.yaml; snapshot Mihomo оставлен для ручного восстановления.${NC}"
    fi
fi

if [ "$MIHOMO_RESTORED" -eq 1 ]; then
    if systemctl list-unit-files 2>/dev/null | grep -q "^mihomo.service"; then
        systemctl restart mihomo.service || echo -e "${RED}Предупреждение: config восстановлен, но mihomo.service не удалось перезапустить.${NC}"
    elif command -v docker >/dev/null 2>&1; then
        MIHOMO_C=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep "mihomo" | head -n1 || true)
        if [ -n "$MIHOMO_C" ]; then
            docker restart "$MIHOMO_C" >/dev/null || echo -e "${RED}Предупреждение: config восстановлен, но контейнер Mihomo не удалось перезапустить.${NC}"
        fi
    fi

    rm -f "$STATE_DIR/mihomo_config_original.yaml"
    rm -f "$STATE_DIR/mihomo_config_path"
    rm -f "$STATE_DIR/mihomo_patched_sha256"
    rm -f "$STATE_DIR/mihomo_config_diverged"
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
echo -e "${YELLOW}Важно: live sysctl и systemd-resolved/original resolv.conf пока не восстанавливаются автоматически."
echo -e "Mihomo config восстанавливается только при безопасном checksum-match; иначе snapshot сохраняется для ручного rollback.${NC}"
