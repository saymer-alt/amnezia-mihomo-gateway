#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR" /tmp/mihomo_config.yaml' EXIT

CONFIG="$TMP_DIR/config.yaml"
FRAGMENT="$TMP_DIR/patch-config.sh"

cat > "$CONFIG" <<'EOF'
mixed-port: 7890
find-process-mode: strict
dns:
  enable: true
  fake-ip-range: 240.0.0.1/4
tun:
  enable: true
  stack: system
  auto-route: true
  auto-detect-interface: false
  inet4-address: 10.255.255.1/30
  mtu: 1300
  gso: false
listeners:
  - name: mihomo-tun-1
    type: tun
    device: mitun0
    inet4-address:
      - 198.19.0.1/30
    stack: gvisor
    auto-route: false
profile:
  store-selected: true
  store-fake-ip: true
endpoint-independent-nat: true
EOF

awk '
  /# 1\. fake-ip-range/ { capture=1 }
  capture && /echo -e .*Патчи применены/ { exit }
  capture { print }
' "$ROOT_DIR/install.sh" > "$FRAGMENT"

if ! grep -q 'fake-ip-range' "$FRAGMENT"; then
  echo "FAIL: Mihomo config patch fragment was not found in install.sh" >&2
  exit 1
fi

MIHOMO_CONFIG="$CONFIG"
FAKE_IP_RANGE="198.18.0.0/16"
STATE_DIR="$TMP_DIR/state"
mkdir -p "$STATE_DIR"
export MIHOMO_CONFIG FAKE_IP_RANGE STATE_DIR
bash "$FRAGMENT"

if [[ ! -s "$STATE_DIR/mihomo_patched_sha256" ]]; then
  echo "FAIL: installer patch did not record the patched Mihomo checksum" >&2
  exit 1
fi

assert_line() {
  local pattern="$1"
  local message="$2"
  if ! grep -Eq "$pattern" "$CONFIG"; then
    echo "FAIL: $message" >&2
    cat "$CONFIG" >&2
    exit 1
  fi
}

assert_absent() {
  local pattern="$1"
  local message="$2"
  if grep -Eq "$pattern" "$CONFIG"; then
    echo "FAIL: $message" >&2
    cat "$CONFIG" >&2
    exit 1
  fi
}

assert_line '^[[:space:]]+fake-ip-range:[[:space:]]+198\.18\.0\.0/16$' 'fake-ip-range was not normalized'
assert_line '^[[:space:]]+stack:[[:space:]]+gvisor$' 'stack was not normalized to gvisor'
assert_line '^[[:space:]]+auto-route:[[:space:]]+false$' 'auto-route was not disabled'
assert_line '^[[:space:]]+disable-icmp-forwarding:[[:space:]]+true$' 'ICMP forwarding was not disabled for strict privacy'
assert_line '^[[:space:]]+auto-detect-interface:[[:space:]]+true$' 'auto-detect-interface was not enabled'
assert_line '^[[:space:]]+mtu:[[:space:]]+1420$' 'MTU was not normalized'
assert_line '^[[:space:]]+gso:[[:space:]]+true$' 'GSO was not enabled'
assert_line '^find-process-mode:[[:space:]]+off$' 'find-process-mode was not disabled'
assert_line '^[[:space:]]+store-selected:[[:space:]]+false$' 'store-selected was not disabled'
assert_line '^[[:space:]]+store-fake-ip:[[:space:]]+false$' 'store-fake-ip was not disabled'
assert_absent '^endpoint-independent-nat:' 'endpoint-independent-nat was not removed'

# Mihomo 1.19.31 ignores top-level RawTun.Inet4Address, so legacy desired-state
# must disappear from the top-level tun block.
top_tun="$TMP_DIR/top-tun.txt"
awk '
  /^tun:[[:space:]]*$/ { in_tun=1; next }
  in_tun && /^[^#[:space:]]/ { exit }
  in_tun { print }
' "$CONFIG" > "$top_tun"
if grep -Eq '^[[:space:]]+inet4-address:' "$top_tun"; then
  echo "FAIL: legacy top-level tun.inet4-address survived installer patch" >&2
  cat "$CONFIG" >&2
  exit 1
fi

# Per-proxy TUN listener uses a different Mihomo config path where inet4-address
# is supported and must remain untouched.
assert_line '^[[:space:]]+inet4-address:$' 'per-proxy listener inet4-address key was removed'
assert_line '^[[:space:]]+-[[:space:]]+198\.19\.0\.1/30$' 'per-proxy listener inet4-address value was removed'

echo "PASS: Mihomo config patch matches the 1.19.31 TUN address contract."
