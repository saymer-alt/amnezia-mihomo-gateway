#!/usr/bin/env bash
# run-pre-reboot.sh — guarded orchestration of the pre-reboot live-acceptance half.
#
# Usage: run-pre-reboot.sh [--run-dir <dir>] [--expected-sha <hex>]
# Requires: AMG_DISPOSABLE_TEST_HOST=YES  AND  --confirm-disposable
#
# Stages (each recorded in <run-dir>/CHECKPOINT):
#   ASSERTIONS -> BASELINE -> INSTALL-1 -> VERIFY-1 -> REPEAT -> VERIFY-2
#   -> READY-FOR-REBOOT (checkpoint for run-post-reboot.sh)
#
# The installer is downloaded from the PUBLIC stable channel and its SHA256
# must match the pinned value (or --expected-sha override) — otherwise STOP.
set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SRC_DIR/lib.sh"

RUN_DIR_ARG=""
EXPECTED_SHA_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --run-dir)       RUN_DIR_ARG="${2:-}"; shift 2 ;;
    --expected-sha)  EXPECTED_SHA_ARG="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

stage_fail() { err "STAGE FAILED: $* (evidence kept; fix the cause or use a fresh host/run)"; exit 1; }

# --- Hard guard: opt-in, prior-state refusal, root ---------------------------
require_disposable_optin "$@" || exit 1
refuse_if_prior_gateway_state || exit 1
require_root || exit 1

echo "=============================================================="
echo " Disposable VPS live acceptance — PRE-REBOOT half"
echo "=============================================================="

# --- run dir ------------------------------------------------------------------
if [ -n "$RUN_DIR_ARG" ]; then
  RUN_DIR="$RUN_DIR_ARG"
  mkdir -p "$RUN_DIR"
else
  RUN_DIR="$(new_run_dir)"
fi
info "evidence dir: $RUN_DIR"

# --- stage: ASSERTIONS (FAIL BEFORE MUTATION) ---------------------------------
checkpoint_write "$RUN_DIR" "ASSERTIONS"
command -v docker >/dev/null 2>&1 || stage_fail "docker not found"
docker info >/dev/null 2>&1 || stage_fail "docker daemon unreachable"
AWG_C="$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep "^${AWG_CONTAINER_PREFIX}" | head -n1)"
[ -n "$AWG_C" ] || stage_fail "no AWG container matching '${AWG_CONTAINER_PREFIX}' (provision it first, see README)"
if command -v mihomo >/dev/null 2>&1 || systemctl list-unit-files 2>/dev/null | grep -q '^mihomo.service'; then
  :
else
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q mihomo || stage_fail "no Mihomo (service or container) found"
fi
CONFIG_PATH="$(require_single_config)" || stage_fail "ambiguous/absent Mihomo config — fix before installing"
[ -w "$RUN_DIR" ] || stage_fail "evidence dir not writable: $RUN_DIR"
ok "pre-install assertions pass (awg=$AWG_C config=$CONFIG_PATH)"

# --- stage: BASELINE ------------------------------------------------------------
checkpoint_write "$RUN_DIR" "BASELINE-IN-PROGRESS"
bash "$SRC_DIR/collect-baseline.sh" "$RUN_DIR" baseline || stage_fail "baseline collection failed"
grep -q '^  store-fake-ip: true$' "$(slot_dir "$RUN_DIR" baseline)/ddp-keys.txt" ||
  stage_fail "DDP scenario requires store-fake-ip: true in the pre-install config (see tests/live/fixtures/ddp-config-skeleton.yaml)"
bash "$SRC_DIR/verify-gateway.sh" --self-test >/dev/null || stage_fail "verifier self-test failed"
checkpoint_write "$RUN_DIR" "BASELINE-OK"
ok "baseline collected; DDP scenario confirmed (store-fake-ip: true)"

# --- stage: installer download + SHA proof (§ public stable channel) ------------
EXPECTED_SHA="${EXPECTED_SHA_ARG:-$EXPECTED_INSTALL_SHA256}"
DL="$RUN_DIR/downloads"
mkdir -p "$DL"
checkpoint_write "$RUN_DIR" "INSTALL-DOWNLOAD"
curl -fsSL --retry 3 --retry-delay 2 "$AMG_RAW_BASE/install.sh" -o "$DL/install.sh" ||
  stage_fail "public stable install.sh download failed"
curl -fsSL --retry 3 --retry-delay 2 "$AMG_RAW_BASE/uninstall.sh" -o "$DL/uninstall.sh" ||
  stage_fail "public stable uninstall.sh download failed"
head -n1 "$DL/install.sh" | grep -q '^#!/' || stage_fail "downloaded install.sh does not look like a shell script"
GOT_INSTALL_SHA="$(sha256sum "$DL/install.sh" | awk '{print $1}')"
GOT_UNINSTALL_SHA="$(sha256sum "$DL/uninstall.sh" | awk '{print $1}')"
printf '%s  install.sh\n%s  uninstall.sh\n' "$GOT_INSTALL_SHA" "$GOT_UNINSTALL_SHA" > "$DL/SHA256SUMS"
[ "$GOT_INSTALL_SHA" = "$EXPECTED_SHA" ] ||
  stage_fail "public stable install.sh SHA mismatch: got $GOT_INSTALL_SHA expected $EXPECTED_SHA — stable moved? STOP."
[ "$GOT_UNINSTALL_SHA" = "$EXPECTED_UNINSTALL_SHA256" ] ||
  stage_fail "public stable uninstall.sh SHA mismatch: got $GOT_UNINSTALL_SHA expected $EXPECTED_UNINSTALL_SHA256 — STOP."
ok "public stable installer verified: $GOT_INSTALL_SHA"

# --- stage: first install ---------------------------------------------------------
checkpoint_write "$RUN_DIR" "INSTALL-1-IN-PROGRESS"
set +e
bash "$DL/install.sh" 2>&1 | tee "$RUN_DIR/install-1.log"
RC1=${PIPESTATUS[0]}
[ "$RC1" -eq 0 ] || stage_fail "first install exited $RC1 (see install-1.log)"
bash "$SRC_DIR/collect-baseline.sh" "$RUN_DIR" post1 || stage_fail "post-install collection failed"
bash "$SRC_DIR/verify-gateway.sh" "$(slot_dir "$RUN_DIR" post1)" || stage_fail "gateway invariants failed after first install"
bash "$SRC_DIR/verify-ddp.sh" "$RUN_DIR" baseline post1 || stage_fail "DDP proof failed after first install"
checkpoint_write "$RUN_DIR" "INSTALL-1-OK"
ok "first install verified (gateway invariants + DDP preservation)"

# --- stage: repeated install -------------------------------------------------------
checkpoint_write "$RUN_DIR" "REPEAT-IN-PROGRESS"
set +e
bash "$DL/install.sh" 2>&1 | tee "$RUN_DIR/install-2.log"
RC2=${PIPESTATUS[0]}
[ "$RC2" -eq 0 ] || stage_fail "repeated install exited $RC2 (see install-2.log)"
bash "$SRC_DIR/collect-baseline.sh" "$RUN_DIR" post2 || stage_fail "post-repeat collection failed"
bash "$SRC_DIR/verify-gateway.sh" "$(slot_dir "$RUN_DIR" post2)" || stage_fail "gateway invariants failed after repeated install"
bash "$SRC_DIR/verify-ddp.sh" "$RUN_DIR" baseline post1 post2 || stage_fail "DDP proof failed after repeated install"

# duplicate checks on the repeated-install state
P2="$(slot_dir "$RUN_DIR" post2)"
SUBNET="$(grep -Eo 'from [0-9.]+/[0-9]+ lookup (100|mihomo)' "$P2/ip-rule.txt" | awk '{print $2}' | head -n1)"
dup_check() { # $1=desc $2=count $3=expected
  if [ "$2" = "$3" ]; then ok "no duplicate: $1 (count=$2)"; else stage_fail "duplicate detected: $1 count=$2 expected=$3"; fi
}
dup_check "FORWARD $GUARD_CHAIN hook" "$(grep -Ec -- "-A FORWARD -s $SUBNET -j $GUARD_CHAIN" "$P2/iptables-save.txt")" 1
dup_check "fwmark bypass rule" "$(grep -Ec 'from all fwmark 0x88 lookup main' "$P2/ip-rule.txt")" 1
dup_check "source policy rule" "$(grep -Ec "from $SUBNET lookup (100|mihomo)( |$)" "$P2/ip-rule.txt")" 1
dup_check "terminal unreachable route" "$(grep -Ec "unreachable default metric $FAILSAFE_METRIC" "$P2/ip-route-table100.txt")" 1
dup_check "preferred TUN default" "$(grep -Ec "default dev $TUN_IF .*metric 10" "$P2/ip-route-table100.txt")" 1
dup_check "TCPMSS clamp" "$(grep -Ec -- '--clamp-mss-to-pmtu' "$P2/iptables-save.txt")" 1
dup_check "TUN MASQUERADE" "$(grep -Ec -- "-A POSTROUTING -o $TUN_IF -j MASQUERADE" "$P2/iptables-save.txt")" 1
dup_check "store-fake-ip key" "$(grep -Ec '^  store-fake-ip:' "$P2/ddp-keys.txt")" 1
CONFIG_PATH2="$(cat "$P2/config.path")"
dup_check "config .bak backups (one per install is expected: 2)" \
  "$(ls -1 "$(dirname "$CONFIG_PATH2")" 2>/dev/null | grep -Ec '^config\.yaml\.bak\.[0-9]+$')" 2
checkpoint_write "$RUN_DIR" "REPEAT-OK"
ok "repeated install verified (no duplicates, DDP still true)"

# --- stage: fake-ip persistence BEFORE snapshot -------------------------------------
PROBE_DOMAIN="${AMG_FAKEIP_PROBE_DOMAIN:-www.example.com}"
ANS="$(resolve_fakeip "$PROBE_DOMAIN")"
if [ -n "$ANS" ]; then
  printf 'domain=%s\nfakeip=%s\n' "$PROBE_DOMAIN" "$ANS" > "$RUN_DIR/fakeip-before.txt"
  ok "fake-ip before reboot: $PROBE_DOMAIN -> $ANS"
else
  printf 'MANUAL STEP REQUIRED: resolve %s against 127.0.0.1 before reboot and keep the answer\ndig +short @127.0.0.1 %s\n' "$PROBE_DOMAIN" "$PROBE_DOMAIN" > "$RUN_DIR/fakeip-before.txt"
  warn "no dig/nslookup or no 127.0.0.1:53 listener — fake-ip persistence check degrades to MANUAL STEP (see fakeip-before.txt)"
fi

# --- checkpoint: READY-FOR-REBOOT ----------------------------------------------------
checkpoint_write "$RUN_DIR" "READY-FOR-REBOOT" "INSTALLER_SHA=$GOT_INSTALL_SHA"
echo "=============================================================="
ok "PRE-REBOOT half complete"
echo "  evidence: $RUN_DIR"
echo "  NEXT (operator): reboot the disposable host, then run:"
echo "    sudo AMG_DISPOSABLE_TEST_HOST=YES $SRC_DIR/run-post-reboot.sh --run-dir '$RUN_DIR' --confirm-disposable"
echo "=============================================================="
