#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

GENERATED="$TMP_DIR/check-warp-routing.sh"
FRAGMENT="$TMP_DIR/generate-watchdog.sh"
MOCK_BIN="$TMP_DIR/bin"
STATE_FILE="$TMP_DIR/healed"
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
export PROXY_IF DOCKER_NETS TABLE_ID TABLE_NAME

bash "$FRAGMENT"
sh -n "$GENERATED"
chmod +x "$GENERATED"

cat > "$MOCK_BIN/ip" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
  "link show tun-mihomo")
    exit 0
    ;;
  "rule show")
    case "${TEST_MODE:?}" in
      named)
        echo "0: from all lookup local"
        echo "100: from 172.29.172.0/24 lookup mihomo"
        ;;
      numeric)
        echo "0: from all lookup local"
        echo "100: from 172.29.172.0/24 lookup 100"
        ;;
      heal-success)
        if [[ -f "${STATE_FILE:?}" ]]; then
          echo "100: from 172.29.172.0/24 lookup mihomo"
        fi
        ;;
      heal-failure)
        ;;
      *)
        echo "unknown TEST_MODE=$TEST_MODE" >&2
        exit 2
        ;;
    esac
    exit 0
    ;;
  "route show table 100")
    echo "default dev tun-mihomo scope link"
    exit 0
    ;;
esac

echo "unexpected ip invocation: $*" >&2
exit 2
EOF

cat > "$MOCK_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == "restart warp-docker-routing.service" ]]; then
  if [[ "${TEST_MODE:?}" == "heal-success" ]]; then
    : > "${STATE_FILE:?}"
  fi
  exit 0
fi

echo "unexpected systemctl invocation: $*" >&2
exit 2
EOF

cat > "$MOCK_BIN/logger" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF

chmod +x "$MOCK_BIN/ip" "$MOCK_BIN/systemctl" "$MOCK_BIN/logger"

run_expect_success() {
  local mode="$1"
  rm -f "$STATE_FILE"
  PATH="$MOCK_BIN:$PATH" TEST_MODE="$mode" STATE_FILE="$STATE_FILE" "$GENERATED"
  echo "PASS: $mode"
}

run_expect_failure() {
  local mode="$1"
  rm -f "$STATE_FILE"
  if PATH="$MOCK_BIN:$PATH" TEST_MODE="$mode" STATE_FILE="$STATE_FILE" "$GENERATED"; then
    echo "FAIL: $mode unexpectedly succeeded" >&2
    exit 1
  fi
  echo "PASS: $mode failed as expected"
}

run_expect_success named
run_expect_success numeric
run_expect_success heal-success
run_expect_failure heal-failure

echo "All watchdog regression tests passed."
