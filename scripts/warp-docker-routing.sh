#!/bin/sh
set -eu

PROXY_IF="tun-mihomo"
DOCKER_NETS="<DOCKER_SUBNET>"
WG_PORT="<WG_PORT>"
TABLE_ID="100"
HOST_IF="<HOST_INTERFACE>"

if [ "${1:-}" = "cleanup" ]; then
    ip rule del fwmark 0x88 lookup main priority 40 2>/dev/null || true
    ip rule del from "$DOCKER_NETS" lookup "$TABLE_ID" priority 100 2>/dev/null || true
    ip route del default table "$TABLE_ID" 2>/dev/null || true

    iptables -t mangle -D PREROUTING -s "$DOCKER_NETS" -p udp --sport "$WG_PORT" -j MARK --set-mark 0x88 2>/dev/null || true
    iptables -t mangle -D FORWARD -s "$DOCKER_NETS" -o "$PROXY_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    iptables -t nat -D POSTROUTING -o "$PROXY_IF" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -s "$DOCKER_NETS" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -d "$DOCKER_NETS" -j ACCEPT 2>/dev/null || true

    echo "Cleanup done."
    exit 0
fi

for i in /proc/sys/net/ipv4/conf/*/rp_filter; do
    echo 0 > "$i"
done

if ! ip link show "$PROXY_IF" >/dev/null 2>&1; then
    echo "Error: Interface '$PROXY_IF' does not exist."
    exit 1
fi

ip rule del fwmark 0x88 lookup main priority 40 2>/dev/null || true
ip rule del from "$DOCKER_NETS" lookup "$TABLE_ID" priority 100 2>/dev/null || true

iptables -t mangle -D PREROUTING -s "$DOCKER_NETS" -p udp --sport "$WG_PORT" -j MARK --set-mark 0x88 2>/dev/null || true
iptables -t nat -D POSTROUTING -o "$PROXY_IF" -j MASQUERADE 2>/dev/null || true
iptables -D FORWARD -s "$DOCKER_NETS" -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -d "$DOCKER_NETS" -j ACCEPT 2>/dev/null || true

ip route replace default dev "$PROXY_IF" table "$TABLE_ID"

ip rule add from "$DOCKER_NETS" lookup "$TABLE_ID" priority 100 2>/dev/null || true
ip rule add fwmark 0x88 lookup main priority 40 2>/dev/null || true

iptables -t mangle -C PREROUTING -s "$DOCKER_NETS" -p udp --sport "$WG_PORT" -j MARK --set-mark 0x88 2>/dev/null || \
iptables -t mangle -I PREROUTING 1 -s "$DOCKER_NETS" -p udp --sport "$WG_PORT" -j MARK --set-mark 0x88

iptables -t mangle -C FORWARD -s "$DOCKER_NETS" -o "$PROXY_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
iptables -t mangle -A FORWARD -s "$DOCKER_NETS" -o "$PROXY_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

iptables -t nat -C POSTROUTING -o "$PROXY_IF" -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -o "$PROXY_IF" -j MASQUERADE

iptables -C FORWARD -s "$DOCKER_NETS" -j ACCEPT 2>/dev/null || \
iptables -I FORWARD 1 -s "$DOCKER_NETS" -j ACCEPT

iptables -C FORWARD -d "$DOCKER_NETS" -j ACCEPT 2>/dev/null || \
iptables -I FORWARD 2 -d "$DOCKER_NETS" -j ACCEPT
