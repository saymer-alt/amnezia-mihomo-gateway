#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

GENERATED="$TMP_DIR/warp-docker-routing.sh"
FRAGMENT="$TMP_DIR/generate-routing.sh"
MOCK_BIN="$TMP_DIR/bin"
LOG="$TMP_DIR/calls.log"
mkdir -p "$MOCK_BIN"

awk '
  /cat << EOF > \/usr\/local\/sbin\/warp-docker-routing\.sh/ { capture=1 }
  capture { print }
  capture && /^EOF$/ { exit }
' "$ROOT_DIR/install.sh" \
  | sed "s#> /usr/local/sbin/warp-docker-routing.sh#> \"$GENERATED\"#" \
  > "$FRAGMENT"

PROXY_IF="tun-mihomo"
DOCKER_NETS="172.29.172.0/24"
WG_PORT="51820"
TABLE_ID="100"
HOST_IF="ens3"
FAKE_IP_RANGE="198.18.0.0/16"
export PROXY_IF DOCKER_NETS WG_PORT TABLE_ID HOST_IF FAKE_IP_RANGE

bash "$FRAGMENT"
sh -n "$GENERATED"
chmod +x "$GENERATED"

cat > "$MOCK_BIN/ip" <<'EOF'
#!/usr/bin/env bash
printf 'ip %s\n' "$*" >> "${CALL_LOG:?}"
exit 0
EOF

cat > "$MOCK_BIN/iptables" <<'EOF'
#!/usr/bin/env bash
printf 'iptables %s\n' "$*" >> "${CALL_LOG:?}"
# Pretend checks miss on first creation so the generated script exercises -A/-I.
if [[ "${1:-}" == "-C" ]]; then
  exit 1
fi
# remove_guard uses a while loop; report that no duplicate hook remains.
if [[ "$*" == "-D FORWARD -s 172.29.172.0/24 -j AMG_FAILSECURE" ]]; then
  exit 1
fi
exit 0
EOF

cat > "$MOCK_BIN/logger" <<'EOF'
#!/usr/bin/env bash
printf 'logger %s\n' "$*" >> "${CALL_LOG:?}"
exit 0
EOF

chmod +x "$MOCK_BIN/ip" "$MOCK_BIN/iptables" "$MOCK_BIN/logger"

run_mode() {
  local mode="$1"
  : > "$LOG"
  PATH="$MOCK_BIN:$PATH" CALL_LOG="$LOG" "$GENERATED" "$mode"
}

assert_has() {
  local needle="$1"
  if ! grep -Fq -- "$needle" "$LOG"; then
    echo "FAIL: missing: $needle" >&2
    cat "$LOG" >&2
    exit 1
  fi
}

assert_absent() {
  local needle="$1"
  if grep -Fq -- "$needle" "$LOG"; then
    echo "FAIL: unexpected: $needle" >&2
    cat "$LOG" >&2
    exit 1
  fi
}

run_mode guard
assert_has "iptables -N AMG_FAILSECURE"
assert_has "iptables -A AMG_FAILSECURE -s 172.29.172.0/24 -o tun-mihomo -j ACCEPT"
assert_has "iptables -A AMG_FAILSECURE -s 172.29.172.0/24 -m mark --mark 0x88 -o ens3 -j ACCEPT"
assert_has "iptables -A AMG_FAILSECURE -s 172.29.172.0/24 -j REJECT --reject-with icmp-admin-prohibited"
assert_has "ip route replace unreachable default metric 42760 table 100"
echo "PASS: guard installs independent forwarding and terminal barriers"

run_mode cleanup
assert_has "ip route del default dev tun-mihomo table 100"
assert_absent "ip route del unreachable default metric 42760 table 100"
assert_absent "iptables -X AMG_FAILSECURE"
echo "PASS: runtime cleanup keeps fail-secure barriers"

run_mode purge
assert_has "ip route del unreachable default metric 42760 table 100"
assert_has "iptables -X AMG_FAILSECURE"
echo "PASS: explicit purge removes fail-secure barriers"

echo "All fail-secure lifecycle regression tests passed."
