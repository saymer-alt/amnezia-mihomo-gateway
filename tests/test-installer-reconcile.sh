#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT_DIR/install.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TAIL="$TMP_DIR/install-tail.sh"
awk '
  /# 6\. Перед рестартом Mihomo/ { capture=1 }
  capture { print }
' "$INSTALL" > "$TAIL"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

grep -Fq '/usr/local/sbin/warp-docker-routing.sh guard' "$TAIL" ||
  fail "installer does not install fail-secure guard before restart"

grep -Fq 'systemctl daemon-reload' "$TAIL" ||
  fail "installer does not reload systemd"

grep -Fq 'systemctl enable warp-docker-routing.service' "$TAIL" ||
  fail "routing service is not explicitly enabled"

grep -Fq 'systemctl restart warp-docker-routing.service' "$TAIL" ||
  fail "routing service is not explicitly reconciled after unit/script rewrite"

if grep -Fq 'systemctl enable --now warp-docker-routing.service' "$TAIL"; then
  fail "installer still relies on enable --now for an already-active oneshot service"
fi

line_of() {
  local needle="$1"
  grep -nF "$needle" "$TAIL" | head -n1 | cut -d: -f1
}

guard_line="$(line_of '/usr/local/sbin/warp-docker-routing.sh guard')"
mihomo_line="$(line_of 'systemctl restart mihomo.service')"
reload_line="$(line_of 'systemctl daemon-reload')"
enable_line="$(line_of 'systemctl enable warp-docker-routing.service')"
restart_line="$(line_of 'systemctl restart warp-docker-routing.service')"
timer_line="$(line_of 'systemctl enable --now check-warp-routing.timer')"

[[ -n "$guard_line" && -n "$mihomo_line" && -n "$reload_line" &&
   -n "$enable_line" && -n "$restart_line" && -n "$timer_line" ]] ||
  fail "could not resolve installer activation ordering"

(( guard_line < mihomo_line )) ||
  fail "fail-secure guard must be installed before Mihomo restart"

(( mihomo_line < reload_line )) ||
  fail "systemd reload must happen after Mihomo restart section"

(( reload_line < enable_line )) ||
  fail "routing service enable must happen after daemon-reload"

(( enable_line < restart_line )) ||
  fail "routing service restart must happen after enable"

(( restart_line < timer_line )) ||
  fail "watchdog timer must be enabled only after synchronous routing reconcile"

echo "PASS: repeated install performs synchronous fail-secure routing reconcile."
