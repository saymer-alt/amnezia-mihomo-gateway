#!/bin/bash
# Repeated-install/idempotency acceptance helper for published v2.0.0-rc.1 on Saymer3.
# Runs the published installer once more, then verifies no duplicate topology/state drift.
# It does NOT reboot or uninstall.

set -Eeu

TAG="v2.0.0-rc.1"
EXPECTED_INSTALLER_SHA256="8779570aa4604556bebc09707ab4c3c1b2bf70da1052294ad5603cf3a018d1cc"
CONFIG="/etc/mihomo/config.yaml"
STATE="/var/lib/amnezia-mihomo-gateway"
INSTALLER="/root/install-amg-$TAG-reinstall.sh"
DOCKER_NETS="172.29.172.0/24"
WG_PORT="51820"
HOST_IF="ens3"
TUN="tun-mihomo"
FAKE_IP_RANGE="198.18.0.0/16"
EXPECTED_ORIGINAL_SHA="2f300dd3ee195f99b70f8ae92838e2aca69129bbd2e59ab2e0ca66ca0c6dfb55"

fail() {
  echo
  echo "===== FAIL: $* ====="
  exit 1
}

count_exact() {
  local expected="$1"
  shift
  local actual="$("$@" | wc -l | tr -d ' ')"
  [ "$actual" = "$expected" ] || fail "expected count=$expected, got $actual for: $*"
}

echo "===== RC1 REPEATED-INSTALL / IDEMPOTENCY TEST ====="
echo "DATE=$(date -Is)"
echo "HOST=$(hostname)"

[ "$(hostname)" = "Saymer3" ] || fail "unexpected host"

echo
echo "===== 1. PRE-CHECK ====="
[ -d "$STATE" ] || fail "state dir missing before reinstall"
[ -f "$STATE/mihomo_config_original.yaml" ] || fail "original config snapshot missing"
[ -f "$STATE/mihomo_patched_sha256" ] || fail "patched checksum missing"
[ -f "$STATE/mihomo_config_path" ] || fail "config path missing"

ORIGINAL_SHA_BEFORE="$(sha256sum "$STATE/mihomo_config_original.yaml" | awk '{print $1}')"
CONFIG_SHA_BEFORE="$(sha256sum "$CONFIG" | awk '{print $1}')"
PATCHED_SHA_BEFORE="$(cat "$STATE/mihomo_patched_sha256")"
CONFIG_META_BEFORE="$(stat -c '%a %U:%G' "$CONFIG")"
DAEMON_SHA_BEFORE="$(sha256sum /etc/docker/daemon.json | awk '{print $1}')"
RESOLV_SHA_BEFORE="$(sha256sum /etc/resolv.conf | awk '{print $1}')"
RESOLV_ATTR_BEFORE="$(lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}')"
RADIO_ID_BEFORE="$(docker inspect -f '{{.Id}}' radio)"
RADIO_STARTED_BEFORE="$(docker inspect -f '{{.State.StartedAt}}' radio)"

echo "ORIGINAL_SHA_BEFORE=$ORIGINAL_SHA_BEFORE"
echo "CONFIG_SHA_BEFORE=$CONFIG_SHA_BEFORE"
echo "PATCHED_SHA_BEFORE=$PATCHED_SHA_BEFORE"
echo "CONFIG_META_BEFORE=$CONFIG_META_BEFORE"
echo "RADIO_STARTED_BEFORE=$RADIO_STARTED_BEFORE"

[ "$ORIGINAL_SHA_BEFORE" = "$EXPECTED_ORIGINAL_SHA" ] || fail "original snapshot already drifted"
[ "$CONFIG_SHA_BEFORE" = "$PATCHED_SHA_BEFORE" ] || fail "current config does not match tracked patched checksum before reinstall"
[ ! -e "$STATE/mihomo_config_diverged" ] || fail "divergence marker exists before reinstall"

echo "[OK] pre-state consistent"

echo
echo "===== 2. DOWNLOAD / VERIFY PUBLISHED RC ====="
curl -fSsL \
  "https://raw.githubusercontent.com/saymer-alt/amnezia-mihomo-gateway/$TAG/install.sh" \
  -o "$INSTALLER"
chmod 700 "$INSTALLER"
bash -n "$INSTALLER" || fail "installer syntax"
INSTALLER_SHA="$(sha256sum "$INSTALLER" | awk '{print $1}')"
echo "INSTALLER_SHA=$INSTALLER_SHA"
[ "$INSTALLER_SHA" = "$EXPECTED_INSTALLER_SHA256" ] || fail "installer checksum mismatch"

echo
echo "===== 3. RUN REPEATED INSTALL ====="
bash "$INSTALLER"

echo
echo "===== 4. SERVICES / MIHOMO ====="
systemctl is-active --quiet mihomo.service || fail "mihomo inactive"
mihomo -t -d /etc/mihomo || fail "mihomo config invalid"
systemctl is-active --quiet warp-docker-routing.service || fail "routing service inactive"
systemctl is-active --quiet check-warp-routing.timer || fail "watchdog timer inactive"
echo "[OK] services"

echo
echo "===== 5. STATE IDEMPOTENCY ====="
ORIGINAL_SHA_AFTER="$(sha256sum "$STATE/mihomo_config_original.yaml" | awk '{print $1}')"
CONFIG_SHA_AFTER="$(sha256sum "$CONFIG" | awk '{print $1}')"
PATCHED_SHA_AFTER="$(cat "$STATE/mihomo_patched_sha256")"
CONFIG_META_AFTER="$(stat -c '%a %U:%G' "$CONFIG")"

echo "ORIGINAL_SHA_AFTER=$ORIGINAL_SHA_AFTER"
echo "CONFIG_SHA_AFTER=$CONFIG_SHA_AFTER"
echo "PATCHED_SHA_AFTER=$PATCHED_SHA_AFTER"
echo "CONFIG_META_AFTER=$CONFIG_META_AFTER"

[ "$ORIGINAL_SHA_AFTER" = "$ORIGINAL_SHA_BEFORE" ] || fail "original snapshot was overwritten"
[ "$CONFIG_SHA_AFTER" = "$CONFIG_SHA_BEFORE" ] || fail "repeated install changed already-normalized config content"
[ "$PATCHED_SHA_AFTER" = "$CONFIG_SHA_AFTER" ] || fail "patched checksum mismatch after reinstall"
[ "$CONFIG_META_AFTER" = "$CONFIG_META_BEFORE" ] || fail "config metadata changed"
[ ! -e "$STATE/mihomo_config_diverged" ] || fail "reinstall incorrectly marked config diverged"
[ ! -e "$STATE/rt_table_added" ] || fail "reinstall claimed ownership of pre-existing rt_tables entry"
[ ! -e "$STATE/docker_daemon_created" ] || fail "reinstall claimed ownership of pre-existing daemon.json"
echo "[OK] state idempotency"

echo
echo "===== 6. TOPOLOGY / DUPLICATE CHECKS ====="
ip rule show
echo
ip route show table 100
echo
iptables -nvL AMG_FAILSECURE

PRIO40_COUNT="$(ip rule show | awk '$1=="40:" && $4=="fwmark" && $5=="0x88" {n++} END{print n+0}')"
PRIO100_COUNT="$(ip rule show | awk -v subnet="$DOCKER_NETS" '$1=="100:" && $2=="from" && $3==subnet {n++} END{print n+0}')"
TUN_DEFAULT_COUNT="$(ip route show table 100 | awk '$1=="default" && $2=="dev" && $3=="tun-mihomo" {n++} END{print n+0}')"
UNREACH_COUNT="$(ip route show table 100 | awk '$1=="unreachable" && $2=="default" {n++} END{print n+0}')"
GUARD_HOOK_COUNT="$(iptables-save -t filter | grep -F -- "-A FORWARD -s $DOCKER_NETS -j AMG_FAILSECURE" | wc -l | tr -d ' ')"
LEGACY_ACCEPT_COUNT="$(iptables-save -t filter | grep -F -- "-A FORWARD -s $DOCKER_NETS -j ACCEPT" | wc -l | tr -d ' ')"
MARK_COUNT="$(iptables-save -t mangle | grep -F -- "-A PREROUTING -s $DOCKER_NETS -p udp -m udp --sport $WG_PORT -j MARK --set-xmark 0x88/0xffffffff" | wc -l | tr -d ' ')"
MSS_COUNT="$(iptables-save -t mangle | grep -F -- "-A FORWARD -s $DOCKER_NETS -o $TUN -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu" | wc -l | tr -d ' ')"
NAT_COUNT="$(iptables-save -t nat | grep -F -- "-A POSTROUTING -o $TUN -j MASQUERADE" | wc -l | tr -d ' ')"

echo "PRIO40_COUNT=$PRIO40_COUNT"
echo "PRIO100_COUNT=$PRIO100_COUNT"
echo "TUN_DEFAULT_COUNT=$TUN_DEFAULT_COUNT"
echo "UNREACH_COUNT=$UNREACH_COUNT"
echo "GUARD_HOOK_COUNT=$GUARD_HOOK_COUNT"
echo "LEGACY_ACCEPT_COUNT=$LEGACY_ACCEPT_COUNT"
echo "MARK_COUNT=$MARK_COUNT"
echo "MSS_COUNT=$MSS_COUNT"
echo "NAT_COUNT=$NAT_COUNT"

[ "$PRIO40_COUNT" = "1" ] || fail "prio40 duplicate/missing"
[ "$PRIO100_COUNT" = "1" ] || fail "prio100 duplicate/missing"
[ "$TUN_DEFAULT_COUNT" = "1" ] || fail "TUN default duplicate/missing"
[ "$UNREACH_COUNT" = "1" ] || fail "terminal unreachable duplicate/missing"
[ "$GUARD_HOOK_COUNT" = "1" ] || fail "guard hook duplicate/missing"
[ "$LEGACY_ACCEPT_COUNT" = "0" ] || fail "legacy broad ACCEPT present"
[ "$MARK_COUNT" = "1" ] || fail "MARK duplicate/missing"
[ "$MSS_COUNT" = "1" ] || fail "TCPMSS duplicate/missing"
[ "$NAT_COUNT" = "1" ] || fail "TUN MASQUERADE duplicate/missing"

ip route show "$FAKE_IP_RANGE" | grep -q 'dev tun-mihomo' || fail "fake-IP route missing"
echo "[OK] topology remains singular/complete"

echo
echo "===== 7. UNRELATED STATE ====="
DAEMON_SHA_AFTER="$(sha256sum /etc/docker/daemon.json | awk '{print $1}')"
RESOLV_SHA_AFTER="$(sha256sum /etc/resolv.conf | awk '{print $1}')"
RESOLV_ATTR_AFTER="$(lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}')"
RADIO_ID_AFTER="$(docker inspect -f '{{.Id}}' radio)"
RADIO_STARTED_AFTER="$(docker inspect -f '{{.State.StartedAt}}' radio)"

echo "RADIO_STARTED_BEFORE=$RADIO_STARTED_BEFORE"
echo "RADIO_STARTED_AFTER=$RADIO_STARTED_AFTER"

[ "$DAEMON_SHA_AFTER" = "$DAEMON_SHA_BEFORE" ] || fail "daemon.json changed"
[ "$RESOLV_SHA_AFTER" = "$RESOLV_SHA_BEFORE" ] || fail "resolv.conf changed"
[ "$RESOLV_ATTR_AFTER" = "$RESOLV_ATTR_BEFORE" ] || fail "resolv.conf attributes changed"
[ "$RADIO_ID_AFTER" = "$RADIO_ID_BEFORE" ] || fail "radio identity changed"
[ "$RADIO_STARTED_AFTER" = "$RADIO_STARTED_BEFORE" ] || fail "radio restarted during repeated install"
echo "[OK] unrelated Docker/DNS state untouched"

echo
echo "===== 8. WATCHDOG STEADY-STATE ====="
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
[ "$BEFORE" = "$AFTER" ] || fail "healthy watchdog restarted routing"
echo "[OK] watchdog steady-state"

echo
echo "===== RC1 REPEATED-INSTALL PASS ====="
echo "STOP HERE: do not uninstall until reviewed."
