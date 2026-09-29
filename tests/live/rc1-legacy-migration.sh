#!/bin/bash
# Live acceptance helper for v2.0.0-rc.1 legacy -> RC migration on Saymer3.
# It installs the published RC over the existing legacy AMG installation.
# It does NOT reboot or uninstall.

# Do not enable pipefail here: this live helper intentionally uses several
# first-match pipelines (for example find|head and docker|head). With pipefail,
# a correct early consumer exit can surface as SIGPIPE/141 from the producer
# and abort the helper before any real validation fails.
set -Eeu

TAG="v2.0.0-rc.1"
EXPECTED_RC_COMMIT="b72df223b57a167988e5125fbab278476d8271b2"
EXPECTED_INSTALLER_SHA256="8779570aa4604556bebc09707ab4c3c1b2bf70da1052294ad5603cf3a018d1cc"
BASELINE="/root/amg-before-rc1-20260929-150325.tar.gz"
EXPECTED_BASELINE_SHA256="f5665843ab73144e9c43ae688a6abfde96d8764b93763a6e45118de79fb36a39"

INSTALLER="/root/install-amg-$TAG.sh"
CONFIG="/etc/mihomo/config.yaml"
STATE="/var/lib/amnezia-mihomo-gateway"
TUN="tun-mihomo"
FAKE_IP_RANGE="198.18.0.0/16"
LOG="/root/amg-$TAG-legacy-migration-$(date +%Y%m%d-%H%M%S).log"

exec > >(tee -a "$LOG") 2>&1

fail() {
    echo
    echo "===== FAIL: $* ====="
    exit 1
}

on_err() {
    local rc=$?
    echo
    echo "===== SCRIPT STOPPED: rc=$rc line=$1 ====="
    echo "LOG=$LOG"
    exit "$rc"
}
trap 'on_err "$LINENO"' ERR

echo "===== AMG $TAG LEGACY MIGRATION ACCEPTANCE ====="
echo "DATE=$(date -Is)"
echo "HOST=$(hostname -f 2>/dev/null || hostname)"
echo "EXPECTED_RC_COMMIT=$EXPECTED_RC_COMMIT"
echo "LOG=$LOG"

echo
echo "===== 1. HOST / BASELINE GUARD ====="

[ "$(hostname)" = "Saymer3" ] || fail "unexpected host; expected Saymer3"
[ -f "$BASELINE" ] || fail "baseline archive missing: $BASELINE"

BASELINE_SHA256="$(sha256sum "$BASELINE" | awk '{print $1}')"
echo "BASELINE_SHA256=$BASELINE_SHA256"

[ "$BASELINE_SHA256" = "$EXPECTED_BASELINE_SHA256" ] \
    || fail "baseline archive checksum mismatch"

echo "[OK] intended host and baseline confirmed"

echo
echo "===== 2. RUNTIME IDENTITY / CONFIG DISCOVERY ====="

ps -eo pid,args | grep '[m]ihomo' || true

ps -eo args | grep -Fxq '/usr/local/bin/mihomo -d /etc/mihomo' \
    || fail "running Mihomo is not /usr/local/bin/mihomo -d /etc/mihomo"

FIRST_CONFIG="$(
    find /etc/mihomo /opt/mihomo /root /home \
        -maxdepth 3 -name config.yaml 2>/dev/null |
    head -n1
)"

echo "FIRST_CONFIG=$FIRST_CONFIG"
[ "$FIRST_CONFIG" = "$CONFIG" ] \
    || fail "current installer discovery would select unexpected config"

echo "[OK] runtime Mihomo and installer config target agree"

echo
echo "===== 3. AWG DISCOVERY ====="

AWG_CONTAINER="$(
    docker ps --filter 'name=amnezia-awg' \
        --format '{{.Names}}' |
    head -n1
)"
[ -n "$AWG_CONTAINER" ] || fail "AWG container not found"

NETWORK_NAME="$(
    docker inspect "$AWG_CONTAINER" \
      --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' |
    grep 'amnezia' |
    head -n1 || true
)"
if [ -z "$NETWORK_NAME" ]; then
    NETWORK_NAME="$(
        docker inspect "$AWG_CONTAINER" \
          --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' |
        head -n1
    )"
fi

DOCKER_NETS="$(
    docker network inspect "$NETWORK_NAME" \
        --format='{{range .IPAM.Config}}{{.Subnet}}{{end}}'
)"

WG_PORT="$(
    docker port "$AWG_CONTAINER" |
    grep '/udp' |
    head -n1 |
    awk -F/ '{print $1}'
)"

HOST_IF="$(ip -o -4 route show to default | awk '{print $5}' | head -n1)"

echo "AWG_CONTAINER=$AWG_CONTAINER"
echo "NETWORK_NAME=$NETWORK_NAME"
echo "DOCKER_NETS=$DOCKER_NETS"
echo "WG_PORT=$WG_PORT"
echo "HOST_IF=$HOST_IF"

[ -n "$DOCKER_NETS" ] || fail "Docker subnet not detected"
[ -n "$WG_PORT" ] || fail "AWG UDP port not detected"
[ -n "$HOST_IF" ] || fail "host uplink not detected"

echo
echo "===== 4. CAPTURE PRE-INSTALL CONTROL VALUES ====="

CONFIG_SHA_BEFORE="$(sha256sum "$CONFIG" | awk '{print $1}')"
CONFIG_META_BEFORE="$(stat -c '%a %U:%G' "$CONFIG")"
RESOLV_SHA_BEFORE="$(sha256sum /etc/resolv.conf | awk '{print $1}')"
RESOLV_ATTR_BEFORE="$(lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}')"
DAEMON_SHA_BEFORE="$(sha256sum /etc/docker/daemon.json | awk '{print $1}')"

RADIO_ID_BEFORE="$(docker inspect -f '{{.Id}}' radio)"
RADIO_STARTED_BEFORE="$(docker inspect -f '{{.State.StartedAt}}' radio)"

echo "CONFIG_SHA_BEFORE=$CONFIG_SHA_BEFORE"
echo "CONFIG_META_BEFORE=$CONFIG_META_BEFORE"
echo "RESOLV_SHA_BEFORE=$RESOLV_SHA_BEFORE"
echo "RESOLV_ATTR_BEFORE=$RESOLV_ATTR_BEFORE"
echo "DAEMON_SHA_BEFORE=$DAEMON_SHA_BEFORE"
echo "RADIO_STARTED_BEFORE=$RADIO_STARTED_BEFORE"

echo
echo "===== 5. DOWNLOAD / VERIFY PUBLISHED RC INSTALLER ====="

curl -fSsL \
  "https://raw.githubusercontent.com/saymer-alt/amnezia-mihomo-gateway/$TAG/install.sh" \
  -o "$INSTALLER"

chmod 700 "$INSTALLER"
bash -n "$INSTALLER"

INSTALLER_SHA256="$(sha256sum "$INSTALLER" | awk '{print $1}')"
echo "INSTALLER_SHA256=$INSTALLER_SHA256"

[ "$INSTALLER_SHA256" = "$EXPECTED_INSTALLER_SHA256" ] \
    || fail "published RC installer checksum mismatch"

echo "[OK] exact published RC installer verified"

echo
echo "===== 6. RUN PUBLISHED RC INSTALLER ====="

bash "$INSTALLER"

echo
echo "===== 7. MIHOMO VALIDATION ====="

systemctl is-active --quiet mihomo.service || fail "mihomo inactive"
mihomo -t -d /etc/mihomo || fail "mihomo config validation failed"

echo "[OK] Mihomo active and config valid"

echo
echo "===== 8. SYSTEMD VALIDATION ====="

systemctl is-active --quiet warp-docker-routing.service \
    || fail "routing service inactive"
systemctl is-enabled --quiet warp-docker-routing.service \
    || fail "routing service disabled"
systemctl is-active --quiet check-warp-routing.timer \
    || fail "watchdog timer inactive"
systemctl is-enabled --quiet check-warp-routing.timer \
    || fail "watchdog timer disabled"

echo "[OK] routing service and watchdog active/enabled"

echo
echo "===== 9. POLICY ROUTING ====="

ip rule show
echo
ip route show table 100
echo
ip route show "$FAKE_IP_RANGE"

ip rule show | awk '
    $1=="40:" && $2=="from" && $3=="all" &&
    $4=="fwmark" && $5=="0x88" &&
    $6=="lookup" && ($7=="main" || $7=="254") { ok=1 }
    END { exit !ok }
' || fail "priority 40 fwmark rule missing"

ip rule show | awk -v subnet="$DOCKER_NETS" '
    $1=="100:" && $2=="from" && $3==subnet &&
    $4=="lookup" && ($5=="mihomo" || $5=="100") { ok=1 }
    END { exit !ok }
' || fail "priority 100 source rule missing"

ip route show table 100 | awk '
    $1=="default" && $2=="dev" && $3=="tun-mihomo" {
        for (i=1; i<=NF; i++) {
            if ($i=="metric" && $(i+1)=="10") ok=1
        }
    }
    END { exit !ok }
' || fail "preferred TUN default missing"

ip route show table 100 | awk '
    $1=="unreachable" && $2=="default" {
        for (i=1; i<=NF; i++) {
            if ($i=="metric" && $(i+1)=="42760") ok=1
        }
    }
    END { exit !ok }
' || fail "terminal unreachable route missing"

ip route show "$FAKE_IP_RANGE" |
    grep -q 'dev tun-mihomo' \
    || fail "fake-IP route in main missing"

echo "[OK] complete policy-routing topology"

echo
echo "===== 10. FAIL-SECURE CONTRACT ====="

iptables -C FORWARD \
    -s "$DOCKER_NETS" -j AMG_FAILSECURE \
    || fail "FORWARD -> AMG_FAILSECURE hook missing"

iptables -C AMG_FAILSECURE \
    -s "$DOCKER_NETS" -o "$TUN" -j ACCEPT \
    || fail "TUN allow missing"

iptables -C AMG_FAILSECURE \
    -s "$DOCKER_NETS" -m mark --mark 0x88 \
    -o "$HOST_IF" -j ACCEPT \
    || fail "marked WAN allow missing"

iptables -C AMG_FAILSECURE \
    -s "$DOCKER_NETS" \
    -j REJECT --reject-with icmp-admin-prohibited \
    || fail "terminal reject missing"

if iptables -C FORWARD -s "$DOCKER_NETS" -j ACCEPT 2>/dev/null; then
    fail "legacy broad source ACCEPT still exists"
fi

iptables -C FORWARD -d "$DOCKER_NETS" -j ACCEPT \
    || fail "reverse destination FORWARD allow missing"

iptables -nvL AMG_FAILSECURE

echo "[OK] fail-secure contract complete"

echo
echo "===== 11. MARK / MSS / NAT ====="

iptables -t mangle -C PREROUTING \
    -s "$DOCKER_NETS" \
    -p udp --sport "$WG_PORT" \
    -j MARK --set-mark 0x88 \
    || fail "outer AWG MARK rule missing"

iptables -t mangle -C FORWARD \
    -s "$DOCKER_NETS" -o "$TUN" \
    -p tcp --tcp-flags SYN,RST SYN \
    -j TCPMSS --clamp-mss-to-pmtu \
    || fail "TCPMSS clamp missing"

iptables -t nat -C POSTROUTING \
    -o "$TUN" -j MASQUERADE \
    || fail "TUN MASQUERADE missing"

echo "[OK] MARK / TCPMSS / NAT present"

echo
echo "===== 12. OWNERSHIP STATE ====="

[ -d "$STATE" ] || fail "state directory missing"
[ -f "$STATE/mihomo_config_original.yaml" ] \
    || fail "original Mihomo config snapshot missing"
[ -f "$STATE/mihomo_patched_sha256" ] \
    || fail "patched Mihomo checksum missing"
[ -f "$STATE/mihomo_config_path" ] \
    || fail "tracked Mihomo config path missing"

ls -la "$STATE"

ORIGINAL_SHA="$(sha256sum "$STATE/mihomo_config_original.yaml" | awk '{print $1}')"
CONFIG_SHA_AFTER="$(sha256sum "$CONFIG" | awk '{print $1}')"
PATCHED_SHA="$(cat "$STATE/mihomo_patched_sha256")"
CONFIG_PATH="$(cat "$STATE/mihomo_config_path")"

echo "ORIGINAL_SHA=$ORIGINAL_SHA"
echo "BEFORE_SHA=$CONFIG_SHA_BEFORE"
echo "PATCHED_SHA=$PATCHED_SHA"
echo "CURRENT_SHA=$CONFIG_SHA_AFTER"
echo "CONFIG_PATH=$CONFIG_PATH"

[ "$ORIGINAL_SHA" = "$CONFIG_SHA_BEFORE" ] \
    || fail "original snapshot differs from pre-install Mihomo config"
[ "$PATCHED_SHA" = "$CONFIG_SHA_AFTER" ] \
    || fail "tracked patched checksum differs from current config"
[ "$CONFIG_PATH" = "$CONFIG" ] \
    || fail "tracked Mihomo config path unexpected"

[ ! -e "$STATE/rt_table_added" ] \
    || fail "installer claimed ownership of pre-existing rt_tables entry"
[ ! -e "$STATE/docker_daemon_created" ] \
    || fail "installer claimed ownership of pre-existing daemon.json"

echo "[OK] legacy ownership tracking correct"

echo
echo "===== 13. METADATA / DNS / UNRELATED DOCKER SAFETY ====="

CONFIG_META_AFTER="$(stat -c '%a %U:%G' "$CONFIG")"
RESOLV_SHA_AFTER="$(sha256sum /etc/resolv.conf | awk '{print $1}')"
RESOLV_ATTR_AFTER="$(lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}')"
DAEMON_SHA_AFTER="$(sha256sum /etc/docker/daemon.json | awk '{print $1}')"
RADIO_ID_AFTER="$(docker inspect -f '{{.Id}}' radio)"
RADIO_STARTED_AFTER="$(docker inspect -f '{{.State.StartedAt}}' radio)"

echo "CONFIG_META_BEFORE=$CONFIG_META_BEFORE"
echo "CONFIG_META_AFTER=$CONFIG_META_AFTER"
echo "RESOLV_SHA_BEFORE=$RESOLV_SHA_BEFORE"
echo "RESOLV_SHA_AFTER=$RESOLV_SHA_AFTER"
echo "RESOLV_ATTR_BEFORE=$RESOLV_ATTR_BEFORE"
echo "RESOLV_ATTR_AFTER=$RESOLV_ATTR_AFTER"
echo "DAEMON_SHA_BEFORE=$DAEMON_SHA_BEFORE"
echo "DAEMON_SHA_AFTER=$DAEMON_SHA_AFTER"
echo "RADIO_STARTED_BEFORE=$RADIO_STARTED_BEFORE"
echo "RADIO_STARTED_AFTER=$RADIO_STARTED_AFTER"

[ "$CONFIG_META_BEFORE" = "$CONFIG_META_AFTER" ] \
    || fail "Mihomo config metadata changed"
[ "$RESOLV_SHA_BEFORE" = "$RESOLV_SHA_AFTER" ] \
    || fail "resolv.conf content changed unexpectedly"
[ "$RESOLV_ATTR_BEFORE" = "$RESOLV_ATTR_AFTER" ] \
    || fail "resolv.conf attributes changed unexpectedly"
[ "$DAEMON_SHA_BEFORE" = "$DAEMON_SHA_AFTER" ] \
    || fail "pre-existing Docker daemon.json changed"
[ "$RADIO_ID_BEFORE" = "$RADIO_ID_AFTER" ] \
    || fail "radio container identity changed"
[ "$RADIO_STARTED_BEFORE" = "$RADIO_STARTED_AFTER" ] \
    || fail "radio container restarted"

echo "[OK] metadata, DNS, daemon.json and radio container preserved"

echo
echo "===== 14. WATCHDOG STEADY-STATE ====="

ROUTING_TS_BEFORE="$(
    systemctl show warp-docker-routing.service \
        -p ActiveEnterTimestampMonotonic --value
)"

set +e
/usr/local/sbin/check-warp-routing.sh
WATCHDOG_RC=$?
set -e

ROUTING_TS_AFTER="$(
    systemctl show warp-docker-routing.service \
        -p ActiveEnterTimestampMonotonic --value
)"

echo "WATCHDOG_RC=$WATCHDOG_RC"
echo "ROUTING_TIMESTAMP_BEFORE=$ROUTING_TS_BEFORE"
echo "ROUTING_TIMESTAMP_AFTER=$ROUTING_TS_AFTER"

[ "$WATCHDOG_RC" -eq 0 ] || fail "watchdog returned non-zero"
[ "$ROUTING_TS_BEFORE" = "$ROUTING_TS_AFTER" ] \
    || fail "healthy-state watchdog unexpectedly restarted routing"

echo "[OK] healthy-state watchdog caused no restart"

echo
echo "===== RC1 LEGACY MIGRATION PASS ====="
echo "LOG=$LOG"
echo
echo "STOP HERE: do not reboot or uninstall until this log is reviewed."
