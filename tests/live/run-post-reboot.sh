#!/usr/bin/env bash
# run-post-reboot.sh — guarded orchestration of the post-reboot live-acceptance half.
#
# Usage: run-post-reboot.sh --run-dir <dir> [--yes-uninstall]
# Requires: AMG_DISPOSABLE_TEST_HOST=YES  AND  --confirm-disposable
#
# Continues a run prepared by run-pre-reboot.sh: verifies the rebooted
# gateway, proves DDP/fake-ip persistence, then (explicitly confirmed)
# uninstalls and compares against the pre-install baseline.
set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SRC_DIR/lib.sh"

RUN_DIR_ARG=""
YES_UNINSTALL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --run-dir)       RUN_DIR_ARG="${2:-}"; shift 2 ;;
    --yes-uninstall) YES_UNINSTALL=1; shift ;;
    *) shift ;;
  esac
done
[ -n "$RUN_DIR_ARG" ] || { err "refusing: --run-dir <dir> of the pre-reboot run is required"; exit 1; }
RUN_DIR="$RUN_DIR_ARG"

stage_fail() { err "STAGE FAILED: $* (evidence kept in $RUN_DIR)"; exit 1; }

# --- Hard guard: opt-in + checkpoint identity + root ---------------------------
require_disposable_optin "$@" || exit 1
require_root || exit 1
checkpoint_read "$RUN_DIR" || stage_fail "no CHECKPOINT in $RUN_DIR (wrong run-dir?)"
[ "$CK_STAGE" = "READY-FOR-REBOOT" ] ||
  stage_fail "checkpoint stage is '$CK_STAGE', expected READY-FOR-REBOOT (wrong stage / incomplete pre-reboot run)"
[ "$CK_MACHINE_ID" = "$(machine_id)" ] ||
  stage_fail "machine-id mismatch: checkpoint=$CK_MACHINE_ID this-host=$(machine_id) — refusing to continue another host's run"

echo "=============================================================="
echo " Disposable VPS live acceptance — POST-REBOOT half"
echo " run-dir: $RUN_DIR"
echo "=============================================================="

# --- reboot survival ------------------------------------------------------------
bash "$SRC_DIR/collect-baseline.sh" "$RUN_DIR" postreboot || stage_fail "post-reboot collection failed"
bash "$SRC_DIR/verify-gateway.sh" "$(slot_dir "$RUN_DIR" postreboot)" ||
  stage_fail "gateway did not restore cleanly after reboot"
bash "$SRC_DIR/verify-ddp.sh" "$RUN_DIR" baseline post1 post2 postreboot ||
  stage_fail "DDP contract violated across the reboot"
ok "gateway + DDP survived reboot"

# --- fake-ip persistence ----------------------------------------------------------
PROBE_DOMAIN="${AMG_FAKEIP_PROBE_DOMAIN:-www.example.com}"
ANS="$(resolve_fakeip "$PROBE_DOMAIN")"
if [ -f "$RUN_DIR/fakeip-before.txt" ] && grep -q '^fakeip=' "$RUN_DIR/fakeip-before.txt"; then
  BEFORE="$(grep '^fakeip=' "$RUN_DIR/fakeip-before.txt" | cut -d= -f2)"
  if [ -n "$ANS" ] && [ "$ANS" = "$BEFORE" ]; then
    ok "fake-ip persistence: $PROBE_DOMAIN -> $ANS (same as pre-reboot)"
    printf 'PERSISTENCE=PROVEN\n' > "$RUN_DIR/fakeip-verdict.txt"
  else
    warn "fake-ip mapping changed or unresolvable (before=$BEFORE after=${ANS:-none})"
    printf 'PERSISTENCE=DIFFERS\n' > "$RUN_DIR/fakeip-verdict.txt"
    stage_fail "fake-ip persistence check failed (store-fake-ip semantics) — see fakeip-verdict.txt"
  fi
else
  warn "MANUAL STEP REQUIRED: compare the pre-reboot fake-ip answer with: dig +short @127.0.0.1 $PROBE_DOMAIN"
  printf 'PERSISTENCE=MANUAL\n' > "$RUN_DIR/fakeip-verdict.txt"
fi

# --- watchdog healthy path must NOT falsely repair --------------------------------
NR_BEFORE="$(grep '^NRestarts=' "$(slot_dir "$RUN_DIR" postreboot)/units.txt" | cut -d= -f2)"
if [ -x "$AMG_SBIN_DIR/check-warp-routing.sh" ]; then
  bash "$AMG_SBIN_DIR/check-warp-routing.sh" >> "$RUN_DIR/watchdog-manual-run.log" 2>&1 &&
    ok "watchdog manual run exited 0 on healthy topology" ||
    stage_fail "watchdog reported the healthy topology as broken (see watchdog-manual-run.log)"
  bash "$SRC_DIR/collect-baseline.sh" "$RUN_DIR" postreboot || stage_fail "re-collection failed"
  NR_AFTER="$(grep '^NRestarts=' "$(slot_dir "$RUN_DIR" postreboot)/units.txt" | cut -d= -f2)"
  [ "$NR_BEFORE" = "$NR_AFTER" ] ||
    stage_fail "watchdog restarted the routing service on a healthy topology (false repair; $NR_BEFORE -> $NR_AFTER)"
  ok "no false watchdog repair (NRestarts stable at $NR_AFTER)"
else
  warn "watchdog script not found — skipping healthy-path check"
fi

# --- traffic/privacy probe (optional) ------------------------------------------------
if [ "${AMG_TRAFFIC_PROBE:-}" = "YES" ]; then
  HOST_TRACE="$(mktemp "${TMPDIR:-/tmp}/amg-host-trace.XXXXXX")"
  AWG_TRACE="$(mktemp "${TMPDIR:-/tmp}/amg-awg-trace.XXXXXX")"
  if curl -fsS --max-time 20 https://www.cloudflare.com/cdn-cgi/trace > "$HOST_TRACE" 2>/dev/null &&
     curl -fsS --max-time 20 https://www.cloudflare.com/cdn-cgi/trace > "$RUN_DIR/trace-host.txt" 2>/dev/null; then
    HOST_IP="$(grep '^ip=' "$HOST_TRACE" | cut -d= -f2)"
    AWG_NET="$(grep '^awg.network=' "$(slot_dir "$RUN_DIR" postreboot)/awg.txt" | cut -d= -f2)"
    if [ -n "$AWG_NET" ] && docker pull -q curlimages/curl >/dev/null 2>&1; then
      docker run --rm --network "$AWG_NET" curlimages/curl -fsS --max-time 25 https://www.cloudflare.com/cdn-cgi/trace > "$AWG_TRACE" 2>/dev/null &&
        cp "$AWG_TRACE" "$RUN_DIR/trace-awg-net.txt" || warn "probe container could not reach the trace endpoint"
    fi
    if [ -s "$RUN_DIR/trace-awg-net.txt" ]; then
      AWG_IP="$(grep '^ip=' "$RUN_DIR/trace-awg-net.txt" | cut -d= -f2)"
      AWG_WARP="$(grep '^warp=' "$RUN_DIR/trace-awg-net.txt" | cut -d= -f2)"
      if [ "$AWG_WARP" = "on" ] && [ -n "$HOST_IP" ] && [ "$AWG_IP" != "$HOST_IP" ]; then
        ok "traffic probe: AWG-subnet egress warp=on, egress IP differs from host IP (no real-IP leak)"
      else
        stage_fail "traffic probe FAILED: warp=$AWG_WARP awg_ip=${AWG_IP:-none} host_ip=$HOST_IP (possible de-anonymization)"
      fi
    else
      warn "MANUAL STEP REQUIRED: from a real AWG client open https://www.cloudflare.com/cdn-cgi/trace — expect warp=on and ip != $HOST_IP"
    fi
  else
    warn "MANUAL STEP REQUIRED: host trace failed; verify client path manually via https://www.cloudflare.com/cdn-cgi/trace"
  fi
  rm -f "$HOST_TRACE" "$AWG_TRACE"
else
  warn "MANUAL STEP REQUIRED (traffic): set AMG_TRAFFIC_PROBE=YES or verify from a real AWG client: https://www.cloudflare.com/cdn-cgi/trace must show warp=on and an IP different from the host's"
fi

# --- uninstall (explicit confirmation) ------------------------------------------------
echo
if [ -z "$YES_UNINSTALL" ]; then
  printf 'About to run uninstall.sh (ownership-aware rollback) on this DISPOSABLE host.\n'
  printf 'Type UNINSTALL to proceed, anything else to stop here: '
  read -r ANSWER
  [ "$ANSWER" = "UNINSTALL" ] || { info "stopped before uninstall (run compare manually)"; exit 0; }
fi
checkpoint_write "$RUN_DIR" "UNINSTALL-IN-PROGRESS"
set +e
bash "$RUN_DIR/downloads/uninstall.sh" 2>&1 | tee "$RUN_DIR/uninstall.log"
RC_U=${PIPESTATUS[0]}
if [ "$RC_U" -eq 2 ]; then
  stage_fail "uninstall reported INCOMPLETE rollback (exit 2, state-dir kept) — inspect uninstall.log"
elif [ "$RC_U" -ne 0 ]; then
  stage_fail "uninstall exited $RC_U (see uninstall.log)"
fi
ok "uninstall completed with proven rollback"

# --- final comparison -------------------------------------------------------------------
bash "$SRC_DIR/collect-baseline.sh" "$RUN_DIR" postuninstall || stage_fail "post-uninstall collection failed"
if bash "$SRC_DIR/compare-baseline.sh" "$RUN_DIR"; then
  checkpoint_write "$RUN_DIR" "CYCLE-COMPLETE" "INSTALLER_SHA=$CK_INSTALLER_SHA"
  echo "=============================================================="
  ok "DESTRUCTIVE CYCLE VERDICT: BASELINE RESTORED"
  echo "  attach to the acceptance report: FINAL-VERDICT.txt, install-*.log,"
  echo "  uninstall.log, ddp-keys.txt slots, trace-awg-net.txt (no secrets)"
  echo "  NEVER attach: mihomo-config-copy.REDACTED.yaml, raw docker/sysctl dumps"
  echo "  NEXT: destroy this VPS"
  echo "=============================================================="
else
  checkpoint_write "$RUN_DIR" "COMPARE-FAILED"
  stage_fail "BASELINE NOT RESTORED — inspect the item table above"
fi
