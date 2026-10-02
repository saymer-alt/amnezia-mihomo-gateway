#!/usr/bin/env bash
# compare-baseline.sh — final destructive-cycle verdict.
#
# Usage: compare-baseline.sh <run-dir>
#
# Compares the post-uninstall slot against the pre-install baseline.
# Volatile state (meta.txt: date/uptime/...) is reported, never compared.
# Controlled items must match EXACTLY after a proven rollback; the only
# allowed residue is installer config backups (config.yaml.bak.<epoch>).
# Verdict: BASELINE RESTORED / BASELINE NOT RESTORED (+ item table).
set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SRC_DIR/lib.sh"

[ $# -eq 1 ] || die "usage: compare-baseline.sh <run-dir>"
RUN_DIR="$1"
BASE="$(slot_dir "$RUN_DIR" baseline)"
POST="$(slot_dir "$RUN_DIR" postuninstall)"
[ -d "$BASE" ] || die "missing baseline slot: $BASE"
[ -d "$POST" ] || die "missing postuninstall slot: $POST"

ITEMS_FILE="$(mktemp "${TMPDIR:-/tmp}/amg-items.XXXXXX")"
trap 'rm -f "$ITEMS_FILE"' EXIT

# label|file|normalize-sed-expr (empty = compare raw)
cat > "$ITEMS_FILE" <<'EOF'
resolv.conf state|dns-state.txt|
sysctl values|sysctl.txt|
rt_tables|rt-tables.txt|
ip rule set|ip-rule.txt|
main routing table|ip-route.txt|
iptables ruleset|iptables-save.txt|
docker daemon.json|daemon-json.state|
mihomo config sha|config.sha|
project systemd units|units.txt|
config dir listing|config-dir-listing.txt|
docker containers|docker.txt|s/\t(Up|Created|Exited|Restarting)[[:print:]]*$/\tRUNTIME-STATUS/
EOF

UNEXPECTED=0
EXPECTED_ITEMS=0
EXACT_ITEMS=0
echo "=== baseline comparison: baseline vs postuninstall ==="
while IFS='|' read -r label file norm; do
  b="$BASE/$file"
  p="$POST/$file"
  if [ ! -f "$b" ] && [ ! -f "$p" ]; then
    printf '%-28s (absent on both sides)\n' "$label"
    continue
  fi
  [ -f "$b" ] || : > "$b"
  [ -f "$p" ] || : > "$p"
  if [ -n "$norm" ]; then
    verdict="$(classify_pair "$label" "$b" "$p" "$norm")"
  else
    verdict="$(classify_pair "$label" "$b" "$p")"
  fi
  case "$verdict" in
    *"EXACT MATCH")        EXACT_ITEMS=$((EXACT_ITEMS + 1)) ;;
    *"EXPECTED DIFFERENCE") EXPECTED_ITEMS=$((EXPECTED_ITEMS + 1)) ;;
    *)
      UNEXPECTED=$((UNEXPECTED + 1))
      echo "    --- diff ($label) ---"
      diff "$b" "$p" 2>/dev/null | head -n 20 | sed 's/^/    /'
      echo "    ---"
      ;;
  esac
  printf '%-28s %s\n' "$label" "$verdict"
done < "$ITEMS_FILE"

# Installer config backups are intentional residue (uninstall restores the
# original config content but leaves the installer's own .bak files).
echo "--- expected residue check ---"
CONFIG_PATH="$(cat "$BASE/config.path" 2>/dev/null || echo)"
if [ -n "$CONFIG_PATH" ]; then
  CFG_DIR="$(dirname "$CONFIG_PATH")"
  BAKS="$(ls "$CFG_DIR" 2>/dev/null | grep -E '^config\.yaml\.bak\.[0-9]+$' || true)"
  if [ -n "$BAKS" ]; then
    printf '%-28s EXPECTED DIFFERENCE (installer backups kept: %s)\n' "config backups" "$(echo "$BAKS" | tr '\n' ' ')"
    EXPECTED_ITEMS=$((EXPECTED_ITEMS + 1))
  else
    printf '%-28s EXACT MATCH\n' "config backups"
    EXACT_ITEMS=$((EXACT_ITEMS + 1))
  fi
fi
if [ -e "$AMG_STATE_DIR" ]; then
  printf '%-28s UNEXPECTED DIFFERENCE (state-dir still present: %s)\n' "ownership state-dir" "$AMG_STATE_DIR"
  UNEXPECTED=$((UNEXPECTED + 1))
else
  printf '%-28s EXACT MATCH (removed on proven rollback)\n' "ownership state-dir"
  EXACT_ITEMS=$((EXACT_ITEMS + 1))
fi

echo "=== summary: exact=$EXACT_ITEMS expected=$EXPECTED_ITEMS unexpected=$UNEXPECTED ==="
if [ "$UNEXPECTED" -eq 0 ]; then
  verdict="BASELINE RESTORED"
else
  verdict="BASELINE NOT RESTORED ($UNEXPECTED unexpected difference(s))"
fi
printf '%s\n' "$verdict" | tee "$RUN_DIR/FINAL-VERDICT.txt"
[ "$UNEXPECTED" -eq 0 ]
