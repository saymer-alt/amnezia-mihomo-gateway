#!/bin/bash
# Read-only post-uninstall verifier for v2.0.0-rc.1 on Saymer3.
# Does not modify system state.

set -Eeu

DOCKER_NETS="172.29.172.0/24"
WG_PORT="51820"
TUN="tun-mihomo"
STATE="/var/lib/amnezia-mihomo-gateway"
CONFIG="/etc/mihomo/config.yaml"

EXPECTED_CONFIG_SHA="203e2b6991b371824dd7679169eea40d3dd3de60efaf72c08ab1aebfe44261cb"
EXPECTED_DAEMON_SHA="f6fa37aa80b0f18d68dc2a380392336374911dc4411fbaafa177fe6cda5f114f"
EXPECTED_RESOLV_SHA="d81df71864c22f2c533ffc040479c874fb01cffea7646a572d06d7650baed6e1"
EXPECTED_RESOLV_ATTR="----i---------e-------"
EXPECTED_RADIO_STARTED="2026-09-29T12:57:06.463012975Z"

fail() {
  echo
  echo "===== FAIL: $* ====="
  exit 1
}

echo "===== RC1 POST-UNINSTALL VERIFY ====="
echo "DATE=$(date -Is)"
echo "HOST=$(hostname)"

[ "$(hostname)" = "Saymer3" ] || fail "unexpected host"

echo
echo "===== 1. PROJECT FILES / UNITS ====="

for unit in   warp-docker-routing.service   check-warp-routing.service   check-warp-routing.timer
do
  if systemctl is-active --quiet "$unit" 2>/dev/null; then
    fail "$unit still active"
  fi
done

for f in   /usr/local/sbin/warp-docker-routing.sh   /usr/local/sbin/check-warp-routing.sh   /etc/systemd/system/warp-docker-routing.service   /etc/systemd/system/check-warp-routing.service   /etc/systemd/system/check-warp-routing.timer   /etc/sysctl.d/99-amnezia-mihomo.conf
do
  [ ! -e "$f" ] || fail "project file remains: $f"
done

echo "[OK] project files/units removed"

echo
echo "===== 2. POLICY ROUTING ====="
ip rule show
echo
ip route show table 100 2>/dev/null || true
echo
ip route show 198.18.0.0/16 2>/dev/null || true

if ip rule show | awk '$1=="40:" && $4=="fwmark" && $5=="0x88" {found=1} END{exit !found}'; then
  fail "priority 40 fwmark rule remains"
fi

if ip rule show | awk -v subnet="$DOCKER_NETS" '$1=="100:" && $2=="from" && $3==subnet {found=1} END{exit !found}'; then
  fail "priority 100 source rule remains"
fi

if ip route show table 100 2>/dev/null | grep -q .; then
  fail "table 100 still contains runtime routes"
fi

if ip route show 198.18.0.0/16 2>/dev/null | grep -q 'dev tun-mihomo'; then
  fail "fake-IP route remains"
fi

echo "[OK] project policy routing removed"

echo
echo "===== 3. IPTABLES ====="

iptables-save -t filter | grep -E 'AMG_FAILSECURE|172\.29\.172\.0/24' || true
iptables-save -t mangle | grep -E '172\.29\.172\.0/24|51820|tun-mihomo' || true
iptables-save -t nat | grep -E '172\.29\.172\.0/24|tun-mihomo' || true

if iptables -S FORWARD 2>/dev/null | grep -q 'AMG_FAILSECURE'; then
  fail "AMG_FAILSECURE hook remains"
fi

if iptables -S AMG_FAILSECURE >/dev/null 2>&1; then
  fail "AMG_FAILSECURE chain remains"
fi

if iptables -t mangle -C PREROUTING -s "$DOCKER_NETS" -p udp --sport "$WG_PORT" -j MARK --set-mark 0x88 2>/dev/null; then
  fail "outer AWG MARK remains"
fi

if iptables -t mangle -C FORWARD -s "$DOCKER_NETS" -o "$TUN"   -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
  fail "TCPMSS remains"
fi

if iptables -t nat -C POSTROUTING -o "$TUN" -j MASQUERADE 2>/dev/null; then
  fail "TUN MASQUERADE remains"
fi

if iptables -C FORWARD -s "$DOCKER_NETS" -j ACCEPT 2>/dev/null; then
  fail "legacy broad source ACCEPT exists"
fi

if iptables -C FORWARD -d "$DOCKER_NETS" -j ACCEPT 2>/dev/null; then
  fail "project reverse destination ACCEPT remains"
fi

echo "[OK] project iptables state removed"

echo
echo "===== 4. PRE-EXISTING / UNRELATED STATE ====="

grep -q '^100 mihomo$' /etc/iproute2/rt_tables   || fail "pre-existing rt_tables entry was removed"

CONFIG_SHA="$(sha256sum "$CONFIG" | awk '{print $1}')"
DAEMON_SHA="$(sha256sum /etc/docker/daemon.json | awk '{print $1}')"
RESOLV_SHA="$(sha256sum /etc/resolv.conf | awk '{print $1}')"
RESOLV_ATTR="$(lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}')"
RADIO_STARTED="$(docker inspect -f '{{.State.StartedAt}}' radio)"

echo "CONFIG_SHA=$CONFIG_SHA"
echo "DAEMON_SHA=$DAEMON_SHA"
echo "RESOLV_SHA=$RESOLV_SHA"
echo "RESOLV_ATTR=$RESOLV_ATTR"
echo "RADIO_STARTED=$RADIO_STARTED"

[ "$CONFIG_SHA" = "$EXPECTED_CONFIG_SHA" ] || fail "Mihomo config changed during current-RC uninstall"
[ "$DAEMON_SHA" = "$EXPECTED_DAEMON_SHA" ] || fail "daemon.json changed"
[ "$RESOLV_SHA" = "$EXPECTED_RESOLV_SHA" ] || fail "resolv.conf changed"
[ "$RESOLV_ATTR" = "$EXPECTED_RESOLV_ATTR" ] || fail "resolv.conf attributes changed"
[ "$RADIO_STARTED" = "$EXPECTED_RADIO_STARTED" ] || fail "radio restarted"

systemctl is-active --quiet mihomo.service || fail "Mihomo should remain active"

echo "[OK] pre-existing/unrelated state preserved"

echo
echo "===== 5. KNOWN CURRENT-RC ROLLBACK LIMITATION ====="

if [ -d "$STATE" ]; then
  echo "[INFO] ownership state directory still exists: expected for current RC"
else
  fail "ownership state directory unexpectedly removed"
fi

echo "[INFO] patched Mihomo config remains unchanged by current RC uninstall"
echo "[INFO] full ownership-aware rollback is intentionally NOT claimed here; that remains PR #4"

echo
echo "===== RC1 UNINSTALL / PURGE GATE PASS ====="
