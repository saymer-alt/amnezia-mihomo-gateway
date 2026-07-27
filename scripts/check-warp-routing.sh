#!/bin/sh

PROXY_IF="tun-mihomo"
DOCKER_NETS="<DOCKER_SUBNET>"

if ! ip link show "$PROXY_IF" >/dev/null 2>&1; then
    logger "warp-check: Interface $PROXY_IF not found."

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

if ! ip rule | grep -q "from $DOCKER_NETS lookup 100"; then
    logger "warp-check: Routing rules lost. Restoring..."
    systemctl restart warp-docker-routing.service
    exit 1
fi

exit 0
