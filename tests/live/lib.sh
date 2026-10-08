#!/usr/bin/env bash
# lib.sh — shared helpers for the Disposable VPS Live Acceptance Kit.
#
# This library is orchestration/evidence/verification ONLY. It contains no
# gateway logic: product behavior lives exclusively in the public stable
# install.sh / uninstall.sh. The kit never reproduces, patches or wraps
# installer semantics.

# Path overrides mirror the uninstall.sh convention so fixture tests can
# sandbox every detection point without root.
AMG_STATE_DIR="${AMG_STATE_DIR:-/var/lib/amnezia-mihomo-gateway}"
AMG_SBIN_DIR="${AMG_SBIN_DIR:-/usr/local/sbin}"
AMG_SYSTEMD_DIR="${AMG_SYSTEMD_DIR:-/etc/systemd/system}"
AMG_RT_TABLES_FILE="${AMG_RT_TABLES_FILE:-/etc/iproute2/rt_tables}"

# Public production channel pinned for the v2.0.1 acceptance run.
# If stable ever moves, these pins make the kit REFUSE: re-pin only after an
# independent re-audit of the new stable blob (git show origin/stable:...).
AMG_RAW_BASE="https://raw.githubusercontent.com/saymer-alt/amnezia-mihomo-gateway/stable"
EXPECTED_INSTALL_SHA256="71fd217aba7411abe4388d18eb6ddfb3051d9188258f479bd5c7a0a4271101b8"
EXPECTED_UNINSTALL_SHA256="a4e0de5364ed7ecec603d24683ca81f864920cb4c6840598c01eaa819f081fcd"

AWG_CONTAINER_PREFIX="amnezia-awg"
TUN_IF="tun-mihomo"
TABLE_ID="100"
TABLE_NAME="mihomo"
FAILSAFE_METRIC="42760"
FWMARK="0x88"
GUARD_CHAIN="AMG_FAILSECURE"

# --- output contract (repo standard): green=OK, cyan=INFO, yellow=WARN,
# --- red=ERROR/FAIL; ANSI only on a TTY; NO_COLOR/TERM=dumb honored.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
  C_G=$'\033[0;32m'; C_I=$'\033[0;36m'; C_W=$'\033[1;33m'; C_E=$'\033[0;31m'; C_N=$'\033[0m'
else
  C_G=""; C_I=""; C_W=""; C_E=""; C_N=""
fi
ok()   { printf '%s[OK]%s %s\n'   "$C_G" "$C_N" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$C_I" "$C_N" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_W" "$C_N" "$*"; }
err()  { printf '%s[ERROR]%s %s\n' "$C_E" "$C_N" "$*" >&2; }
die()  { err "$*"; exit 1; }

require_root() {
  if [ "$(id -u 2>/dev/null || echo 1)" != "0" ]; then
    err "refusing: this step must run as root on the disposable VPS (got uid $(id -u 2>/dev/null || echo '?'))"
    return 1
  fi
}

# --- Hard disposable-host guard -------------------------------------------
# NO EXPLICIT DISPOSABLE OPT-IN -> NO DESTRUCTIVE ACTION.
# Two independent confirmations are required: the AMG_DISPOSABLE_TEST_HOST=YES
# environment variable AND the --confirm-disposable command-line flag.
# Neither a hostname nor an IP ever proves disposable status.
require_disposable_optin() {
  if [ "${AMG_DISPOSABLE_TEST_HOST:-}" != "YES" ]; then
    err "refusing: destructive live-acceptance step requires AMG_DISPOSABLE_TEST_HOST=YES"
    info "export AMG_DISPOSABLE_TEST_HOST=YES   # only on a clean disposable VPS"
    return 1
  fi
  local arg confirmed=""
  for arg in "$@"; do
    if [ "$arg" = "--confirm-disposable" ]; then
      confirmed=1
    fi
  done
  if [ "$confirmed" != "1" ]; then
    err "refusing: second confirmation missing — pass --confirm-disposable on the command line"
    return 1
  fi
}

# Prints evidence lines and returns 0 when ANY prior gateway state is found
# (caller must then refuse: this is either a production host or a previous
# kit run — both must never be re-installed over).
detect_prior_gateway_state() {
  local found=""
  if [ -e "$AMG_STATE_DIR" ]; then
    printf 'ownership state-dir exists: %s\n' "$AMG_STATE_DIR"
    found=1
  fi
  if [ -f "$AMG_SYSTEMD_DIR/warp-docker-routing.service" ] ||
     [ -f "$AMG_SYSTEMD_DIR/check-warp-routing.service" ] ||
     [ -f "$AMG_SYSTEMD_DIR/check-warp-routing.timer" ]; then
    printf 'generated units exist under: %s\n' "$AMG_SYSTEMD_DIR"
    found=1
  fi
  if [ -f "$AMG_SBIN_DIR/warp-docker-routing.sh" ] ||
     [ -f "$AMG_SBIN_DIR/check-warp-routing.sh" ]; then
    printf 'generated scripts exist under: %s\n' "$AMG_SBIN_DIR"
    found=1
  fi
  if [ -f "$AMG_RT_TABLES_FILE" ] &&
     grep -Eq "^[[:space:]]*${TABLE_ID}[[:space:]]+${TABLE_NAME}[[:space:]]*$" "$AMG_RT_TABLES_FILE" 2>/dev/null; then
    printf 'rt_tables already registers: %s %s\n' "$TABLE_ID" "$TABLE_NAME"
    found=1
  fi
  if command -v iptables >/dev/null 2>&1; then
    if iptables -nL 2>/dev/null | grep -q -- "$GUARD_CHAIN"; then
      printf 'iptables already references: %s\n' "$GUARD_CHAIN"
      found=1
    fi
  fi
  if command -v ip >/dev/null 2>&1; then
    if ip rule show 2>/dev/null | grep -Eq "lookup (${TABLE_ID}|${TABLE_NAME})( |$)"; then
      printf 'policy rule already points at table 100/mihomo\n'
      found=1
    fi
  fi
  [ -n "$found" ]
}

refuse_if_prior_gateway_state() {
  local evidence
  if evidence="$(detect_prior_gateway_state)"; then
    err "refusing: this host already carries gateway state — it is NOT a clean disposable host"
    printf '%s\n' "$evidence" >&2
    info "use a freshly provisioned disposable VPS (see tests/live/README.md)"
    return 1
  fi
}

# --- Run directory / checkpoint -------------------------------------------
machine_id() {
  if [ -r /etc/machine-id ]; then
    tr -d '\n' < /etc/machine-id
  else
    printf 'no-machine-id'
  fi
}

new_run_dir() {
  local root="${AMG_EVIDENCE_ROOT:-$HOME/amg-live-acceptance}"
  mkdir -p "$root"
  RUN_DIR="$root/live-acceptance-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$RUN_DIR"
  printf '%s\n' "$RUN_DIR"
}

slot_dir() { printf '%s/%s' "$1" "$2"; }

checkpoint_write() { # $1=run-dir $2=stage $3=extra key=value...
  local dir="$1" stage="$2" extra="${3:-}"
  {
    printf 'STAGE=%s\n' "$stage"
    printf 'HOSTNAME=%s\n' "$(hostname 2>/dev/null || echo unknown-host)"
    printf 'MACHINE_ID=%s\n' "$(machine_id)"
    printf 'CREATED=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown-time)"
    if [ -n "$extra" ]; then
      printf '%s\n' "$extra"
    fi
  } > "$dir/CHECKPOINT"
}

checkpoint_read() { # $1=run-dir → sets CK_STAGE CK_HOSTNAME CK_MACHINE_ID CK_INSTALLER_SHA
  local dir="$1" line key val
  CK_STAGE=""; CK_HOSTNAME=""; CK_MACHINE_ID=""; CK_INSTALLER_SHA=""
  [ -f "$dir/CHECKPOINT" ] || return 1
  while IFS='=' read -r key val; do
    case "$key" in
      STAGE)         CK_STAGE="$val" ;;
      HOSTNAME)      CK_HOSTNAME="$val" ;;
      MACHINE_ID)    CK_MACHINE_ID="$val" ;;
      INSTALLER_SHA) CK_INSTALLER_SHA="$val" ;;
    esac
  done < "$dir/CHECKPOINT"
  [ -n "$CK_STAGE" ]
}

# --- Secret redaction -------------------------------------------------------
# Value-only redaction: key names survive, credential material does not.
# Used for the config copy and any free-form text that might carry secrets.
redact_yaml_stream() {
  sed -E \
    -e 's/^([[:space:]]*(private-key|password|psk|uuid|token|secret|shared-secret|public-key|server|port)[[:space:]]*:[[:space:]]*).*/\1[REDACTED]/' \
    -e 's#([a-zA-Z][a-zA-Z0-9+.-]*)://[^/@[:space:]]+:[^@[:space:]]+@#\1://[REDACTED]@#g'
}

# --- DDP key extraction -----------------------------------------------------
# Prints ONLY whitelisted, non-secret key lines from a Mihomo config:
# profile.store-fake-ip / store-selected, dns.fake-ip-range, tun.device /
# auto-route / stack / dns-hijack (+ list entries), sniffer core keys.
extract_ddp_keys() { # $1 = config file
  awk '
    /^[[:space:]]*#/ { next }
    /^profile:/  { sec="profile";  next }
    /^dns:/      { sec="dns";      next }
    /^tun:/      { sec="tun";      next }
    /^sniffer:/  { sec="sniffer";  next }
    /^[^[:space:]#][^:]*:/ { sec=""; hijack=0 }
    sec == "profile" && /^[[:space:]]+(store-fake-ip|store-selected):/ { print; next }
    sec == "dns" && /^[[:space:]]+fake-ip-range:/ { print; next }
    sec == "tun" && /^[[:space:]]+(device|auto-route|stack):/ { print; next }
    sec == "tun" && /^[[:space:]]+dns-hijack:/ { print; hijack=1; next }
    sec == "tun" && hijack && /^[[:space:]]+-[[:space:]]/ { print; next }
    { hijack=0 }
    sec == "sniffer" && /^[[:space:]]+(enable|parse-pure-ip|force-dns-mapping|override-destination):/ { print }
  ' "$1"
}

# --- Installer discovery ----------------------------------------------------
find_mihomo_configs() {
  find /etc/mihomo /opt/mihomo /root /home -maxdepth 3 -name config.yaml 2>/dev/null
}

require_single_config() { # prints the path; non-zero when ambiguous/absent
  local n
  n=$(find_mihomo_configs | wc -l | tr -d ' ')
  if [ "$n" -ne 1 ]; then
    err "refusing: expected exactly one Mihomo config.yaml, found $n (installer would take the first match)"
    find_mihomo_configs 2>/dev/null | sed 's/^/  candidate: /' >&2
    return 1
  fi
  find_mihomo_configs
}

live_config_path() { # post-install: the exact path recorded by the installer
  if [ -s "$AMG_STATE_DIR/mihomo_config_path" ]; then
    cat "$AMG_STATE_DIR/mihomo_config_path"
  else
    require_single_config
  fi
}

# --- Evidence pair classification -------------------------------------------
# verdict: EXACT MATCH | EXPECTED DIFFERENCE | UNEXPECTED DIFFERENCE
# Optional $4 = sed -E normalize expression applied to both sides first.
# The only residue allowed in the post side is installer config backups
# (config.yaml.bak.<epoch>), which uninstall intentionally leaves in place.
classify_pair() { # $1=label $2=baseline-file $3=post-file $4=normalize-sed (optional)
  local label="$1" base="$2" post="$3" norm="${4:-}" verdict
  local b="$base" p="$post" tmp_b="" tmp_p=""
  if [ -n "$norm" ]; then
    tmp_b="$(mktemp "${TMPDIR:-/tmp}/amg-cmp-b.XXXXXX")"
    tmp_p="$(mktemp "${TMPDIR:-/tmp}/amg-cmp-p.XXXXXX")"
    sed -E "$norm" "$base" > "$tmp_b" 2>/dev/null || cp "$base" "$tmp_b"
    sed -E "$norm" "$post" > "$tmp_p" 2>/dev/null || cp "$post" "$tmp_p"
    b="$tmp_b"; p="$tmp_p"
  fi
  if cmp -s "$b" "$p"; then
    verdict="EXACT MATCH"
  else
    local bad=0 line content
    while IFS= read -r line; do
      case "$line" in
        '>'*)
          content="${line#> }"
          case "$content" in
            config.yaml.bak.[0-9]*) ;;      # installer backup residue: expected
            *) bad=1; break ;;
          esac
          ;;
        '<'*) bad=1; break ;;               # baseline content disappeared
        *) ;;                                # diff headers
      esac
    done < <(diff "$b" "$p" 2>/dev/null)
    if [ "$bad" -eq 0 ]; then
      verdict="EXPECTED DIFFERENCE"
    else
      verdict="UNEXPECTED DIFFERENCE"
    fi
  fi
  if [ -n "$tmp_b" ]; then
    rm -f "$tmp_b" "$tmp_p"
  fi
  printf '%s: %s\n' "$label" "$verdict"
}

# --- Fake-IP persistence probe ----------------------------------------------
resolve_fakeip() { # $1 = probe domain; prints the 198.18.x.x answer or nothing
  local domain="$1" ans=""
  if command -v dig >/dev/null 2>&1; then
    ans=$(dig +short +time=3 +tries=1 @127.0.0.1 "$domain" A 2>/dev/null | grep -E '^198\.18\.' | head -n1)
  elif command -v nslookup >/dev/null 2>&1; then
    ans=$(nslookup -timeout=3 "$domain" 127.0.0.1 2>/dev/null | awk '/^Address/ {print $2}' | grep -E '^198\.18\.' | head -n1)
  fi
  [ -n "$ans" ] && printf '%s\n' "$ans"
  return 0
}
