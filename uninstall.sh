#!/bin/bash
# Удаление маршрутизации Amnezia -> Mihomo с ownership-aware rollback.

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

STATE_DIR="${AMG_STATE_DIR:-/var/lib/amnezia-mihomo-gateway}"
DOCKER_DAEMON_FILE="${AMG_DOCKER_DAEMON_FILE:-/etc/docker/daemon.json}"
RT_TABLES_FILE="${AMG_RT_TABLES_FILE:-/etc/iproute2/rt_tables}"
SYSTEMD_DIR="${AMG_SYSTEMD_DIR:-/etc/systemd/system}"
SBIN_DIR="${AMG_SBIN_DIR:-/usr/local/sbin}"
SYSCTL_FILE="${AMG_SYSCTL_FILE:-/etc/sysctl.d/99-amnezia-mihomo.conf}"
RESOLV_CONF="${AMG_RESOLV_CONF:-/etc/resolv.conf}"
PROC_CONF_DIR="${AMG_PROC_CONF_DIR:-/proc/sys/net/ipv4/conf}"
TABLE_ID="100"
TABLE_NAME="mihomo"

ROLLBACK_COMPLETE=1

warn_incomplete() {
    ROLLBACK_COMPLETE=0
    echo -e "${YELLOW}$*${NC}" >&2
}

echo -e "${YELLOW}=== Удаление Amnezia -> Mihomo и безопасный rollback ===${NC}"

# 1. Остановить watchdog/routing; explicit purge убирает fail-secure runtime state.
systemctl disable --now check-warp-routing.timer 2>/dev/null || true
systemctl disable --now check-warp-routing.service 2>/dev/null || true
systemctl disable --now warp-docker-routing.service 2>/dev/null || true

if [ -f "$SBIN_DIR/warp-docker-routing.sh" ]; then
    if ! "$SBIN_DIR/warp-docker-routing.sh" purge; then
        warn_incomplete "WARN: routing purge завершился с ошибкой; продолжаю безопасный rollback остальных ресурсов."
    fi
fi

# 2. Docker daemon.json: удаляем только доказанно installer-owned файл и только без admin divergence.
DOCKER_RESTART_NEEDED=0
if [ -f "$STATE_DIR/docker_daemon_created" ]; then
    if [ -L "$DOCKER_DAEMON_FILE" ] ||
       { [ -e "$DOCKER_DAEMON_FILE" ] &&
         { [ ! -f "$DOCKER_DAEMON_FILE" ] || [ "$(stat -c '%h' -- "$DOCKER_DAEMON_FILE" 2>/dev/null)" != 1 ]; }; }; then
        warn_incomplete "Docker daemon.json изменил тип/identity; оставляю без изменений."
    elif [ ! -e "$DOCKER_DAEMON_FILE" ]; then
        :
    elif [ -f "$STATE_DIR/docker_daemon_sha256" ]; then
        EXPECTED_SHA=$(cat "$STATE_DIR/docker_daemon_sha256" 2>/dev/null || true)
        CURRENT_SHA=$(sha256sum "$DOCKER_DAEMON_FILE" 2>/dev/null | awk '{print $1}')
        if [ -n "$EXPECTED_SHA" ] && [ "$CURRENT_SHA" = "$EXPECTED_SHA" ]; then
            rm -f -- "$DOCKER_DAEMON_FILE"
            DOCKER_RESTART_NEEDED=1
            echo -e "${CYAN}Docker daemon.json, созданный installer'ом, удалён.${NC}"
        else
            warn_incomplete "Docker daemon.json менялся после установки; оставляю без изменений."
        fi
    else
        warn_incomplete "Нет checksum для installer-owned daemon.json; автоматическое удаление пропущено."
    fi
fi

if [ "$DOCKER_RESTART_NEEDED" -eq 1 ]; then
    if ! systemctl restart docker; then
        warn_incomplete "WARN: daemon.json удалён, но Docker не удалось перезапустить."
    fi
fi

# 3. rt_tables: удаляем запись только при marker'е владения и отсутствии runtime-потребителей.
if [ -f "$STATE_DIR/rt_table_added" ]; then
    if [ -f "$RT_TABLES_FILE" ] &&
       grep -Eq "^[[:space:]]*${TABLE_ID}[[:space:]]+${TABLE_NAME}[[:space:]]*$" "$RT_TABLES_FILE"; then
        if ! ip rule show | grep -Eq "lookup (${TABLE_ID}|${TABLE_NAME})( |$)" &&
           ! ip route show table "$TABLE_ID" 2>/dev/null | grep -q .; then
            sed -i -E "/^[[:space:]]*${TABLE_ID}[[:space:]]+${TABLE_NAME}[[:space:]]*$/d" "$RT_TABLES_FILE"
            echo -e "${CYAN}Installer-owned запись 100 mihomo удалена из rt_tables.${NC}"
        else
            warn_incomplete "Таблица 100/mihomo всё ещё используется; запись rt_tables сохранена."
        fi
    fi
fi

# 4. Mihomo config: возвращаем точное исходное содержимое только при checksum-match.
MIHOMO_RESTORED=0
if [ -f "$STATE_DIR/mihomo_config_original.yaml" ] ||
   [ -f "$STATE_DIR/mihomo_config_path" ] ||
   [ -f "$STATE_DIR/mihomo_patched_sha256" ]; then
    if [ ! -f "$STATE_DIR/mihomo_config_original.yaml" ] ||
       [ ! -f "$STATE_DIR/mihomo_config_path" ] ||
       [ ! -f "$STATE_DIR/mihomo_patched_sha256" ]; then
        warn_incomplete "Mihomo rollback-state неполон; snapshot/state сохранён для ручной проверки."
    elif [ -f "$STATE_DIR/mihomo_config_diverged" ]; then
        warn_incomplete "Mihomo config менялся после установки; automatic rollback пропущен."
    else
        MIHOMO_CONFIG_PATH=$(cat "$STATE_DIR/mihomo_config_path" 2>/dev/null || true)
        EXPECTED_PATCHED_SHA=$(cat "$STATE_DIR/mihomo_patched_sha256" 2>/dev/null || true)
        if [ -z "$MIHOMO_CONFIG_PATH" ] || [ ! -f "$MIHOMO_CONFIG_PATH" ]; then
            warn_incomplete "Исходный путь Mihomo config не найден; snapshot сохранён."
        else
            CURRENT_MIHOMO_SHA=$(sha256sum "$MIHOMO_CONFIG_PATH" 2>/dev/null | awk '{print $1}')
            if [ -z "$EXPECTED_PATCHED_SHA" ] || [ "$CURRENT_MIHOMO_SHA" != "$EXPECTED_PATCHED_SHA" ]; then
                warn_incomplete "Mihomo config изменён после установки; текущий файл сохранён."
            else
                CONFIG_DIR=$(dirname -- "$MIHOMO_CONFIG_PATH")
                CONFIG_BASE=$(basename -- "$MIHOMO_CONFIG_PATH")
                TMP_CONFIG=$(mktemp "$CONFIG_DIR/.${CONFIG_BASE}.amg-rollback.XXXXXX")
                trap 'rm -f -- "${TMP_CONFIG:-}"' EXIT HUP INT TERM
                cp --preserve=all -- "$MIHOMO_CONFIG_PATH" "$TMP_CONFIG"
                cat -- "$STATE_DIR/mihomo_config_original.yaml" > "$TMP_CONFIG"

                MIHOMO_BIN=$(command -v mihomo 2>/dev/null || true)
                if [ -z "$MIHOMO_BIN" ] && [ -x /usr/local/bin/mihomo ]; then
                    MIHOMO_BIN=/usr/local/bin/mihomo
                fi

                if [ -n "$MIHOMO_BIN" ] && ! "$MIHOMO_BIN" -t -f "$TMP_CONFIG" >/dev/null 2>&1; then
                    rm -f -- "$TMP_CONFIG"
                    TMP_CONFIG=""
                    warn_incomplete "Исходный Mihomo config не прошёл mihomo -t; рабочий config не изменён."
                else
                    mv -f -- "$TMP_CONFIG" "$MIHOMO_CONFIG_PATH"
                    TMP_CONFIG=""
                    trap - EXIT HUP INT TERM
                    MIHOMO_RESTORED=1
                    echo -e "${GREEN}Mihomo config восстановлен в точное pre-install состояние.${NC}"
                fi
            fi
        fi
    fi
fi

if [ "$MIHOMO_RESTORED" -eq 1 ]; then
    if systemctl list-unit-files 2>/dev/null | grep -q "^mihomo.service"; then
        if ! systemctl restart mihomo.service; then
            warn_incomplete "WARN: config восстановлен, но mihomo.service не удалось перезапустить."
        fi
    elif command -v docker >/dev/null 2>&1; then
        MIHOMO_C=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep "mihomo" | head -n1 || true)
        if [ -n "$MIHOMO_C" ] && ! docker restart "$MIHOMO_C" >/dev/null; then
            warn_incomplete "WARN: config восстановлен, но контейнер Mihomo не удалось перезапустить."
        fi
    fi
fi

# 5. DNS/systemd-resolved: rollback только если текущий resolv.conf всё ещё наш.
if [ -f "$STATE_DIR/dns_state_recorded" ]; then
    DNS_SAFE=1
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        DNS_SAFE=0
    fi
    if [ "$(systemctl show systemd-resolved --property=ActiveState --value 2>/dev/null)" != inactive ] ||
       [ "$(systemctl is-enabled systemd-resolved 2>/dev/null || true)" != disabled ]; then
        DNS_SAFE=0
    fi
    if [ ! -f "$STATE_DIR/resolv_managed_sha256" ] || [ ! -f "$RESOLV_CONF" ] || [ -L "$RESOLV_CONF" ]; then
        DNS_SAFE=0
    else
        EXPECTED_RESOLV_SHA=$(cat "$STATE_DIR/resolv_managed_sha256" 2>/dev/null || true)
        CURRENT_RESOLV_SHA=$(sha256sum "$RESOLV_CONF" 2>/dev/null | awk '{print $1}')
        if [ -z "$EXPECTED_RESOLV_SHA" ] || [ "$CURRENT_RESOLV_SHA" != "$EXPECTED_RESOLV_SHA" ]; then
            DNS_SAFE=0
        fi
        CURRENT_RESOLV_ATTRS=$(lsattr -d "$RESOLV_CONF" 2>/dev/null | awk '{print $1}')
        if [ "$(stat -c '%h' -- "$RESOLV_CONF" 2>/dev/null)" != 1 ] ||
           ! printf '%s\n' "$CURRENT_RESOLV_ATTRS" | grep -q i; then
            DNS_SAFE=0
        fi
    fi

    # Prove exactly one supported original-state form BEFORE any DNS mutation.
    ORIGINAL_RESOLV="$STATE_DIR/resolv.conf.original"
    if [ -f "$STATE_DIR/resolv_original_missing" ]; then
        if [ -e "$ORIGINAL_RESOLV" ] || [ -L "$ORIGINAL_RESOLV" ] ||
           [ -f "$STATE_DIR/resolv_original_immutable" ]; then DNS_SAFE=0; fi
    elif [ -L "$ORIGINAL_RESOLV" ]; then
        if [ -f "$STATE_DIR/resolv_original_immutable" ]; then DNS_SAFE=0; fi
    elif [ ! -f "$ORIGINAL_RESOLV" ]; then
        DNS_SAFE=0
    fi

    if [ "$DNS_SAFE" -eq 1 ]; then
        # Stage the original before clearing immutable. Atomic rename keeps the
        # managed resolver available if snapshot copy fails. Subshell owns trap.
        restore_owned_dns() (
            TMP_RESOLV=""
            trap 'rm -f -- "${TMP_RESOLV:-}"' EXIT HUP INT TERM
            if [ ! -f "$STATE_DIR/resolv_original_missing" ]; then
                TMP_RESOLV=$(mktemp "$(dirname -- "$RESOLV_CONF")/.resolv.amg-rollback.XXXXXX") || return 1
                cp -a --no-dereference --remove-destination -- "$ORIGINAL_RESOLV" "$TMP_RESOLV" || return 1
            fi
            # Staging must not widen the admission window for an admin edit.
            [ -f "$RESOLV_CONF" ] && [ ! -L "$RESOLV_CONF" ] || return 1
            [ "$(stat -c '%h' -- "$RESOLV_CONF" 2>/dev/null)" = 1 ] || return 1
            [ "$(sha256sum "$RESOLV_CONF" | awk '{print $1}')" = "$EXPECTED_RESOLV_SHA" ] || return 1
            [ "$(systemctl show systemd-resolved --property=ActiveState --value)" = inactive ] || return 1
            [ "$(systemctl is-enabled systemd-resolved 2>/dev/null || true)" = disabled ] || return 1
            chattr -i "$RESOLV_CONF" || return 1
            if [ -f "$STATE_DIR/resolv_original_missing" ]; then
                rm -f -- "$RESOLV_CONF" || return 1
            else
                mv -Tf -- "$TMP_RESOLV" "$RESOLV_CONF" || return 1
                TMP_RESOLV=""
            fi
            if [ -f "$STATE_DIR/resolv_original_immutable" ]; then
                chattr +i "$RESOLV_CONF" || return 1
            fi
            if [ -f "$RESOLV_CONF" ] && [ ! -L "$RESOLV_CONF" ]; then
                RESTORED_ATTRS=$(lsattr -d "$RESOLV_CONF" 2>/dev/null) || return 1
                RESTORED_FLAGS=$(printf '%s\n' "$RESTORED_ATTRS" | awk '{print $1}')
                [ -n "$RESTORED_FLAGS" ] || return 1
                if [ -f "$STATE_DIR/resolv_original_immutable" ]; then
                    printf '%s\n' "$RESTORED_FLAGS" | grep -q i || return 1
                elif printf '%s\n' "$RESTORED_FLAGS" | grep -q i; then
                    return 1
                fi
            fi

            if [ -f "$STATE_DIR/resolved_was_enabled" ]; then
                systemctl enable systemd-resolved || return 1
                [ "$(systemctl is-enabled systemd-resolved 2>/dev/null || true)" = enabled ] || return 1
            else
                systemctl disable systemd-resolved || return 1
                [ "$(systemctl is-enabled systemd-resolved 2>/dev/null || true)" = disabled ] || return 1
            fi
            if [ -f "$STATE_DIR/resolved_was_active" ]; then
                systemctl start systemd-resolved || return 1
                [ "$(systemctl show systemd-resolved --property=ActiveState --value)" = active ] || return 1
            else
                systemctl stop systemd-resolved || return 1
                [ "$(systemctl show systemd-resolved --property=ActiveState --value)" = inactive ] || return 1
            fi
        )
        if restore_owned_dns; then
            echo -e "${GREEN}systemd-resolved/resolv.conf восстановлены по pre-install state.${NC}"
        else
            warn_incomplete "DNS restore завершился с ошибкой; state/snapshot сохранены для ручной проверки."
        fi
    else
        warn_incomplete "DNS state изменён/не доказан или snapshot неполон; systemd-resolved/resolv.conf оставлены без изменений."
    fi
fi

# 6. sysctl: файл и live values возвращаются только при доказанном ownership.
if [ -f "$STATE_DIR/sysctl_state_recorded" ]; then
    SYSCTL_SAFE=1
    if [ ! -f "$STATE_DIR/sysctl_file_managed_sha256" ] || [ ! -f "$SYSCTL_FILE" ] || [ -L "$SYSCTL_FILE" ]; then
        SYSCTL_SAFE=0
    else
        EXPECTED_SYSCTL_SHA=$(cat "$STATE_DIR/sysctl_file_managed_sha256" 2>/dev/null || true)
        CURRENT_SYSCTL_SHA=$(sha256sum "$SYSCTL_FILE" 2>/dev/null | awk '{print $1}')
        if [ -z "$EXPECTED_SYSCTL_SHA" ] || [ "$CURRENT_SYSCTL_SHA" != "$EXPECTED_SYSCTL_SHA" ]; then
            SYSCTL_SAFE=0
        fi
    fi

    if [ "$SYSCTL_SAFE" -eq 1 ]; then
        rm -f -- "$SYSCTL_FILE"
        if [ -f "$STATE_DIR/sysctl_file_existed" ] &&
           { [ -e "$STATE_DIR/sysctl_file_original" ] || [ -L "$STATE_DIR/sysctl_file_original" ]; }; then
            cp -a --no-dereference -- "$STATE_DIR/sysctl_file_original" "$SYSCTL_FILE"
        fi

        restore_sysctl_if_owned() {
            local marker="$1" key="$2" expected="$3" original_file="$4"
            [ -f "$STATE_DIR/$marker" ] || return 0
            [ -s "$STATE_DIR/$original_file" ] || return 0
            local current original
            current=$(sysctl -n "$key" 2>/dev/null || true)
            original=$(cat "$STATE_DIR/$original_file" 2>/dev/null || true)
            if [ "$current" = "$expected" ]; then
                if ! sysctl -w "$key=$original" >/dev/null; then
                    warn_incomplete "Не удалось восстановить live sysctl $key."
                fi
            elif [ "$current" != "$original" ]; then
                warn_incomplete "Live sysctl $key изменён администратором; сохраняю текущее значение."
            fi
        }

        restore_sysctl_if_owned "sysctl_changed_default_qdisc" "net.core.default_qdisc" "fq" "sysctl_original_default_qdisc"
        restore_sysctl_if_owned "sysctl_changed_tcp_congestion_control" "net.ipv4.tcp_congestion_control" "bbr" "sysctl_original_tcp_congestion_control"
        restore_sysctl_if_owned "sysctl_changed_ip_forward" "net.ipv4.ip_forward" "1" "sysctl_original_ip_forward"

        if [ -f "$STATE_DIR/sysctl_original_rp_filter" ]; then
            while IFS=$'\t' read -r iface original; do
                [ -n "$iface" ] || continue
                path="$PROC_CONF_DIR/$iface/rp_filter"
                [ -e "$path" ] || continue
                current=$(cat "$path" 2>/dev/null || true)
                if [ "$current" = "0" ]; then
                    printf '%s\n' "$original" > "$path" || warn_incomplete "Не удалось восстановить rp_filter для $iface."
                elif [ "$current" != "$original" ]; then
                    warn_incomplete "rp_filter для $iface изменён администратором; сохраняю текущее значение."
                fi
            done < "$STATE_DIR/sysctl_original_rp_filter"
        fi
        echo -e "${GREEN}Installer-owned sysctl file/live values обработаны.${NC}"
    else
        warn_incomplete "sysctl state изменён после установки; файл и live sysctl оставлены без изменений."
    fi
fi

# 7. Удаление generated project files.
rm -f "$SYSTEMD_DIR/warp-docker-routing.service"
rm -f "$SYSTEMD_DIR/check-warp-routing.service"
rm -f "$SYSTEMD_DIR/check-warp-routing.timer"
rm -f "$SBIN_DIR/warp-docker-routing.sh"
rm -f "$SBIN_DIR/check-warp-routing.sh"

systemctl daemon-reload

# State-dir удаляется только после полного доказанного rollback.
if [ "$ROLLBACK_COMPLETE" -eq 1 ]; then
    rm -rf -- "$STATE_DIR"
    echo -e "${GREEN}Удаление и ownership-aware rollback завершены; state-dir удалён.${NC}"
else
    echo -e "${YELLOW}Удаление runtime завершено, но rollback неполон; state-dir сохранён: $STATE_DIR${NC}"
    exit 2
fi
