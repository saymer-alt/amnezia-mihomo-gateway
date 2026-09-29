#!/bin/bash
# Post-install verifier for the Saymer3 v2.0.0-rc.1 legacy migration.
# Does not run install.sh, reboot, or uninstall.

set -Eeu

CONFIG="/etc/mihomo/config.yaml"
STATE="/var/lib/amnezia-mihomo-gateway"
TUN="tun-mihomo"
DOCKER_NETS="172.29.172.0/24"
WG_PORT="51820"
HOST_IF="ens3"
FAKE_IP_RANGE="198.18.0.0/16"
BASELINE="/root/amg-before-rc1-20260929-150325.tar.gz"
EXPECTED_BASELINE_SHA256="f5665843ab73144e9c43ae688a6abfde96d8764b93763a6e45118de79fb36a39"

fail() {
  echo
  echo "===== FAIL: $* ====="
  exit 1
}

echo "===== RC1 POST-INSTALL VERIFY ====="
echo "DATE=$(date -Is)"
echo "HOST=$(hostname)"

[ "$(hostname)" = "Saymer3" ] || fail "unexpected host"
[ -f "$BASELINE" ] || fail "baseline archive missing"
[ "$(sha256sum "$BASELINE" | awk '{print $1}')" = "$EXPECTED_BASELINE_SHA256" ] || fail "baseline checksum mismatch"

echo
echo "===== 1. MIHOMO / SYSTEMD ====="
systemctl is-active --quiet mihomo.service || fail "mihomo inactive"
mihomo -t -d /etc/mihomo || fail "mihomo config invalid"
systemctl is-active --quiet warp-docker-routing.service || fail "routing service inactive"
systemctl is-enabled --quiet warp-docker-routing.service || fail "routing service disabled"
systemctl is-active --quiet check-warp-routing.timer || fail "watchdog timer inactive"
systemctl is-enabled --quiet check-warp-routing.timer || fail "watchdog timer disabled"
echo "[OK] services"

echo
echo "===== 2. POLICY ROUTING ====="
ip rule show
echo
ip route show table 100
echo
ip route show "$FAKE_IP_RANGE"

ip rule show | awk '
  $1=="40:" && $2=="from" && $3=="all" && $4=="fwmark" && $5=="0x88" &&
  $6=="lookup" && ($7=="main" || $7=="254") {ok=1}
  END {exit !ok}
' || fail "priority 40 fwmark rule missing"

ip rule show | awk -v subnet="$DOCKER_NETS" '
  $1=="100:" && $2=="from" && $3==subnet && $4=="lookup" &&
  ($5=="mihomo" || $5=="100") {ok=1}
  END {exit !ok}
' || fail "priority 100 source rule missing"

ip route show table 100 | awk '
  $1=="default" && $2=="dev" && $3=="tun-mihomo" {
    for(i=1;i<=NF;i++) if($i=="metric" && $(i+1)=="10") ok=1
  }
  END {exit !ok}
' || fail "preferred TUN default missing"

ip route show table 100 | awk '
  $1=="unreachable" && $2=="default" {
    for(i=1;i<=NF;i++) if($i=="metric" && $(i+1)=="42760") ok=1
  }
  END {exit !ok}
' || fail "terminal unreachable missing"

ip route show "$FAKE_IP_RANGE" | grep -q 'dev tun-mihomo' || fail "fake-IP route missing"
echo "[OK] routing topology"

echo
echo "===== 3. FAIL-SECURE ====="
iptables -C FORWARD -s "$DOCKER_NETS" -j AMG_FAILSECURE || fail "guard hook missing"
iptables -C AMG_FAILSECURE -s "$DOCKER_NETS" -o "$TUN" -j ACCEPT || fail "TUN allow missing"
iptables -C AMG_FAILSECURE -s "$DOCKER_NETS" -m mark --mark 0x88 -o "$HOST_IF" -j ACCEPT || fail "marked WAN allow missing"
iptables -C AMG_FAILSECURE -s "$DOCKER_NETS" -j REJECT --reject-with icmp-admin-prohibited || fail "terminal reject missing"
if iptables -C FORWARD -s "$DOCKER_NETS" -j ACCEPT 2>/dev/null; then
  fail "legacy broad source ACCEPT still exists"
fi
iptables -C FORWARD -d "$DOCKER_NETS" -j ACCEPT || fail "reverse destination allow missing"
iptables -nvL AMG_FAILSECURE
echo "[OK] fail-secure"

echo
echo "===== 4. MARK / MSS / NAT ====="
iptables -t mangle -C PREROUTING -s "$DOCKER_NETS" -p udp --sport "$WG_PORT" -j MARK --set-mark 0x88 || fail "MARK missing"
iptables -t mangle -C FORWARD -s "$DOCKER_NETS" -o "$TUN" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu || fail "TCPMSS missing"
iptables -t nat -C POSTROUTING -o "$TUN" -j MASQUERADE || fail "MASQUERADE missing"
echo "[OK] MARK / MSS / NAT"

echo
echo "===== 5. OWNERSHIP STATE ====="
[ -d "$STATE" ] || fail "state dir missing"
[ -f "$STATE/mihomo_config_original.yaml" ] || fail "original config snapshot missing"
[ -f "$STATE/mihomo_patched_sha256" ] || fail "patched checksum missing"
[ -f "$STATE/mihomo_config_path" ] || fail "config path missing"
ls -la "$STATE"

ORIGINAL_SHA="$(sha256sum "$STATE/mihomo_config_original.yaml" | awk '{print $1}')"
CURRENT_SHA="$(sha256sum "$CONFIG" | awk '{print $1}')"
PATCHED_SHA="$(cat "$STATE/mihomo_patched_sha256")"
CONFIG_PATH="$(cat "$STATE/mihomo_config_path")"

echo "ORIGINAL_SHA=$ORIGINAL_SHA"
echo "CURRENT_SHA=$CURRENT_SHA"
echo "PATCHED_SHA=$PATCHED_SHA"
echo "CONFIG_PATH=$CONFIG_PATH"

[ "$PATCHED_SHA" = "$CURRENT_SHA" ] || fail "patched checksum mismatch"
[ "$CONFIG_PATH" = "$CONFIG" ] || fail "tracked config path unexpected"
[ ! -e "$STATE/rt_table_added" ] || fail "claimed ownership of pre-existing rt_tables entry"
[ ! -e "$STATE/docker_daemon_created" ] || fail "claimed ownership of pre-existing daemon.json"
echo "[OK] ownership state"

echo
echo "===== 6. UNRELATED STATE ====="
DAEMON_SHA="$(sha256sum /etc/docker/daemon.json | awk '{print $1}')"
RESOLV_SHA="$(sha256sum /etc/resolv.conf | awk '{print $1}')"
RESOLV_ATTR="$(lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}')"
RADIO_STARTED="$(docker inspect -f '{{.State.StartedAt}}' radio)"

echo "DAEMON_SHA=$DAEMON_SHA"
echo "RESOLV_SHA=$RESOLV_SHA"
echo "RESOLV_ATTR=$RESOLV_ATTR"
echo "RADIO_STARTED=$RADIO_STARTED"

[ "$DAEMON_SHA" = "f6fa37aa80b0f18d68dc2a380392336374911dc4411fbaafa177fe6cda5f114f" ] || fail "daemon.json changed"
[ "$RESOLV_SHA" = "d81df71864c22f2c533ffc040479c874fb01cffea7646a572d06d7650baed6e1" ] || fail "resolv.conf changed"
[ "$RESOLV_ATTR" = "----i---------e-------" ] || fail "resolv.conf attributes changed"
[ "$RADIO_STARTED" = "2026-09-22T17:50:33.198868898Z" ] || fail "radio restarted"
echo "[OK] daemon.json / resolv.conf / radio untouched"

echo
echo "===== 7. WATCHDOG STEADY-STATE ====="
BEFORE="$(systemctl show warp-docker-routing.service -p ActiveEnterTimestampMonotonic --value)"
set +e
/usr/local/sbin/check-warp-routing.sh
RC=$?
set -e
AFTER="$(systemctl show warp-docker-routing.service -p ActiveEnterTimestampMonotonic --value)"
echo "WATCHDOG_RC=$RC"
echo "ROUTING_TIMESTAMP_BEFORE=$BEFORE"
echo "ROUTING_TIMESTAMP_AFTER=$AFTER"
[ "$RC" -eq 0 ] || fail "watchdog non-zero"
[ "$BEFORE" = "$AFTER" ] || fail "watchdog unexpectedly restarted routing"
echo "[OK] watchdog steady-state"

echo
echo "===== RC1 POST-INSTALL VERIFY PASS ====="
echo "STOP HERE: do not reboot or uninstall until reviewed."
