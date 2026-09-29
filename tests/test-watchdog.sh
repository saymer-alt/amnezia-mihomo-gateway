#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

GENERATED="$TMP_DIR/check-warp-routing.sh"
FRAGMENT="$TMP_DIR/generate-watchdog.sh"
MOCK_BIN="$TMP_DIR/bin"
STATE_FILE="$TMP_DIR/healed"
RESTART_FILE="$TMP_DIR/restarts"
mkdir -p "$MOCK_BIN"

awk '
  /cat << EOF > \/usr\/local\/sbin\/check-warp-routing\.sh/ { capture=1 }
  capture { print }
  capture && /^EOF$/ { exit }
' "$ROOT_DIR/install.sh" \
  | sed "s#> /usr/local/sbin/check-warp-routing.sh#> \"$GENERATED\"#" \
  > "$FRAGMENT"

if ! grep -q '^cat << EOF' "$FRAGMENT"; then
  echo "FAIL: watchdog heredoc was not found in install.sh" >&2
  exit 1
fi

PROXY_IF="tun-mihomo"
DOCKER_NETS="172.29.172.0/24"
TABLE_ID="100"
TABLE_NAME="mihomo"
HOST_IF="ens3"
WG_PORT="39551"
FAKE_IP_RANGE="198.18.0.0/16"
export PROXY_IF DOCKER_NETS TABLE_ID TABLE_NAME HOST_IF WG_PORT FAKE_IP_RANGE

bash "$FRAGMENT"
sh -n "$GENERATED"
chmod +x "$GENERATED"

cat > "$MOCK_BIN/ip" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

missing() {
  [[ "${MISSING_COMPONENT:-}" == "$1" && ! -f "${STATE_FILE:?}" ]]
}

case "$*" in
  "link show tun-mihomo")
    exit 0
    ;;
  "rule show")
    echo "0: from all lookup local"
    if ! missing fwmark-rule; then
      echo "40: from all fwmark 0x88 lookup main"
    fi
    if ! missing source-rule; then
      if [[ "${TABLE_RENDER:-named}" == "numeric" ]]; then
        echo "100: from 172.29.172.0/24 lookup 100"
      else
        echo "100: from 172.29.172.0/24 lookup mihomo"
      fi
    fi
    exit 0
    ;;
  "route show table 100")
    if ! missing tun-default; then
      echo "default dev tun-mihomo scope link metric 10"
    fi
    if ! missing terminal-route; then
      echo "unreachable default metric 42760"
    fi
    exit 0
    ;;
  "route show 198.18.0.0/16")
    if ! missing fake-route; then
      echo "198.18.0.0/16 dev tun-mihomo scope link"
    fi
    exit 0
    ;;
esac

echo "unexpected ip invocation: $*" >&2
exit 2
EOF

cat > "$MOCK_BIN/iptables" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

missing() {
  [[ "${MISSING_COMPONENT:-}" == "$1" && ! -f "${STATE_FILE:?}" ]]
}

case "$*" in
  "-C FORWARD -s 172.29.172.0/24 -j AMG_FAILSECURE")
    missing guard-hook && exit 1
    exit 0
    ;;
  "-C AMG_FAILSECURE -s 172.29.172.0/24 -o tun-mihomo -j ACCEPT")
    missing guard-tun && exit 1
    exit 0
    ;;
  "-C AMG_FAILSECURE -s 172.29.172.0/24 -m mark --mark 0x88 -o ens3 -j ACCEPT")
    missing guard-mark && exit 1
    exit 0
    ;;
  "-C AMG_FAILSECURE -s 172.29.172.0/24 -j REJECT --reject-with icmp-admin-prohibited")
    missing guard-reject && exit 1
    exit 0
    ;;
  "-t mangle -C PREROUTING -s 172.29.172.0/24 -p udp --sport 39551 -j MARK --set-mark 0x88")
    missing mark-rule && exit 1
    exit 0
    ;;
  "-t mangle -C FORWARD -s 172.29.172.0/24 -o tun-mihomo -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu")
    missing mss-rule && exit 1
    exit 0
    ;;
  "-t nat -C POSTROUTING -o tun-mihomo -j MASQUERADE")
    missing nat-rule && exit 1
    exit 0
    ;;
  "-C FORWARD -d 172.29.172.0/24 -j ACCEPT")
    missing reverse-allow && exit 1
    exit 0
    ;;
  "-C FORWARD -s 172.29.172.0/24 -j ACCEPT")
    # For this one, exit 0 means the forbidden legacy rule exists.
    missing legacy-broad && exit 0
    exit 1
    ;;
esac

echo "unexpected iptables invocation: $*" >&2
exit 2
EOF

cat > "$MOCK_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == "restart warp-docker-routing.service" ]]; then
  echo restart >> "${RESTART_FILE:?}"
  case "${HEAL_MODE:?}" in
    success)
      : > "${STATE_FILE:?}"
      exit 0
      ;;
    not-healed)
      exit 0
      ;;
    restart-failure)
      exit 1
      ;;
  esac
fi

echo "unexpected systemctl invocation: $*" >&2
exit 2
EOF

cat > "$MOCK_BIN/logger" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF

cat > "$MOCK_BIN/sleep" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF

chmod +x "$MOCK_BIN/ip" "$MOCK_BIN/iptables" "$MOCK_BIN/systemctl" "$MOCK_BIN/logger" "$MOCK_BIN/sleep"

run_steady() {
  local render="$1"
  rm -f "$STATE_FILE" "$RESTART_FILE"
  PATH="$MOCK_BIN:$PATH" \
    TABLE_RENDER="$render" MISSING_COMPONENT="" HEAL_MODE="restart-failure" \
    STATE_FILE="$STATE_FILE" RESTART_FILE="$RESTART_FILE" \
    "$GENERATED"
  if [[ -e "$RESTART_FILE" ]]; then
    echo "FAIL: steady/$render unexpectedly restarted routing" >&2
    exit 1
  fi
  echo "PASS: steady/$render"
}

run_heal_component() {
  local component="$1"
  rm -f "$STATE_FILE" "$RESTART_FILE"
  PATH="$MOCK_BIN:$PATH" \
    TABLE_RENDER="named" MISSING_COMPONENT="$component" HEAL_MODE="success" \
    STATE_FILE="$STATE_FILE" RESTART_FILE="$RESTART_FILE" \
    "$GENERATED"
  [[ -f "$STATE_FILE" ]]
  [[ "$(wc -l < "$RESTART_FILE")" -eq 1 ]]
  echo "PASS: healed missing $component"
}

run_expect_failure() {
  local mode="$1"
  rm -f "$STATE_FILE" "$RESTART_FILE"
  if PATH="$MOCK_BIN:$PATH" \
       TABLE_RENDER="named" MISSING_COMPONENT="mark-rule" HEAL_MODE="$mode" \
       STATE_FILE="$STATE_FILE" RESTART_FILE="$RESTART_FILE" \
       "$GENERATED"; then
    echo "FAIL: $mode unexpectedly succeeded" >&2
    exit 1
  fi
  echo "PASS: $mode failed as expected"
}

run_steady named
run_steady numeric

for component in \
  source-rule \
  fwmark-rule \
  tun-default \
  terminal-route \
  fake-route \
  guard-hook \
  guard-tun \
  guard-mark \
  guard-reject \
  mark-rule \
  mss-rule \
  nat-rule \
  reverse-allow \
  legacy-broad
do
  run_heal_component "$component"
done

run_expect_failure not-healed
run_expect_failure restart-failure

echo "All watchdog topology regression tests passed."
