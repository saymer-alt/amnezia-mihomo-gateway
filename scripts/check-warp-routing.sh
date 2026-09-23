#!/bin/sh

PROXY_IF="tun-mihomo"
DOCKER_NETS="<DOCKER_SUBNET>"
TABLE_ID="100"
TABLE_NAME="mihomo"

routing_ok() {
    ip link show "$PROXY_IF" >/dev/null 2>&1 &&
    ip rule show | grep -F "from $DOCKER_NETS lookup " | grep -Eq "lookup ($TABLE_ID|$TABLE_NAME)( |$)" &&
    ip route show table "$TABLE_ID" | grep -Fq "default dev $PROXY_IF"
}

if ! ip link show "$PROXY_IF" >/dev/null 2>&1; then
    logger "warp-check: Interface $PROXY_IF not found. Restarting Mihomo..."

    if systemctl list-unit-files | grep -q "^mihomo.service"; then
        systemctl restart mihomo.service
    elif command -v docker >/dev/null 2>&1; then
        MIHOMO_C=$(docker ps -a --format '{{.Names}}' | grep "mihomo" | head -n1)
        if [ -n "$MIHOMO_C" ]; then
            docker restart "$MIHOMO_C"
        fi
    fi

    for i in $(seq 1 10); do
        ip link show "$PROXY_IF" >/dev/null 2>&1 && break
        sleep 2
    done
fi

if routing_ok; then
    exit 0
fi

logger "warp-check: Routing rules are missing or incomplete. Restoring..."
if ! systemctl restart warp-docker-routing.service; then
    logger "warp-check: ERROR - failed to restart warp-docker-routing.service"
    exit 1
fi

sleep 1

if routing_ok; then
    logger "warp-check: Routing rules restored successfully."
    exit 0
fi

logger "warp-check: ERROR - routing rules were not restored."
exit 1
