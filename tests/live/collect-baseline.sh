#!/usr/bin/env bash
# collect-baseline.sh — read-only evidence collector for the live acceptance kit.
#
# Usage: collect-baseline.sh <run-dir> <slot>
#   slot ∈ baseline | post1 | post2 | postreboot | postuninstall
#
# Every command is read-only and absence-tolerant. Output files are normalized
# so compare-baseline.sh can diff slot pairs. Secrets are redacted (config
# copy) or never collected at all (docker inspect env, full journal dumps).
set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SRC_DIR/lib.sh"

[ $# -eq 2 ] || die "usage: collect-baseline.sh <run-dir> <slot>"
RUN_DIR="$1"
SLOT="$2"
case "$SLOT" in
  baseline|post1|post2|postreboot|postuninstall) ;;
  *) die "unknown slot: $SLOT" ;;
esac
OUT="$(slot_dir "$RUN_DIR" "$SLOT")"
mkdir -p "$OUT"

note() { printf '%s\n' "$*" >> "$OUT/README-unsafe-files.txt"; }

# --- meta (volatile; never compared) ----------------------------------------
{
  date -u 2>/dev/null
  hostname 2>/dev/null
  printf 'machine-id: %s\n' "$(machine_id)"
  cat /etc/os-release 2>/dev/null | grep -E '^(PRETTY_NAME|VERSION_ID)='
  uname -r 2>/dev/null
  uptime 2>/dev/null
} > "$OUT/meta.txt" 2>/dev/null

# --- network -----------------------------------------------------------------
ip -o addr 2>/dev/null | redact_yaml_stream > "$OUT/ip-addr.txt"
ip route show 2>/dev/null > "$OUT/ip-route.txt"
ip route show table 100 2>/dev/null > "$OUT/ip-route-table100.txt"
ip route show 198.18.0.0/16 2>/dev/null > "$OUT/ip-route-fakeip.txt"
ip rule show 2>/dev/null > "$OUT/ip-rule.txt"
if ip -d link show tun-mihomo > "$OUT/tun-link.txt" 2>&1; then
  ip -4 addr show tun-mihomo >> "$OUT/tun-link.txt" 2>/dev/null
fi

# --- routing policy files ----------------------------------------------------
if [ -f "$AMG_RT_TABLES_FILE" ]; then
  cat "$AMG_RT_TABLES_FILE" > "$OUT/rt-tables.txt"
else
  printf 'missing: %s\n' "$AMG_RT_TABLES_FILE" > "$OUT/rt-tables.txt"
fi

# --- firewall ----------------------------------------------------------------
if command -v iptables-save >/dev/null 2>&1; then
  iptables-save 2>/dev/null > "$OUT/iptables-save.txt"
elif command -v nft >/dev/null 2>&1; then
  # nft backend without the iptables shim: still structure-only evidence
  { echo "# nft list ruleset (iptables-save unavailable)"; nft list ruleset 2>/dev/null; } > "$OUT/iptables-save.txt"
else
  printf 'no iptables-save/nft available\n' > "$OUT/iptables-save.txt"
fi

# --- sysctl (values only) ----------------------------------------------------
{
  sysctl -n net.ipv4.ip_forward 2>/dev/null | sed 's/^/ip_forward=/'
  sysctl -n net.core.default_qdisc 2>/dev/null | sed 's/^/default_qdisc=/'
  sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | sed 's/^/tcp_congestion_control=/'
  sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null | sed 's/^/rp_filter.all=/'
  sysctl -n net.ipv4.conf.default.rp_filter 2>/dev/null | sed 's/^/rp_filter.default=/'
  for p in /proc/sys/net/ipv4/conf/*/rp_filter; do
    [ -r "$p" ] || continue
    iface="${p#/proc/sys/net/ipv4/conf/}"; iface="${iface%/rp_filter}"
    printf 'rp_filter.%s=%s\n' "$iface" "$(cat "$p" 2>/dev/null)"
  done
} > "$OUT/sysctl.txt"

# --- docker ------------------------------------------------------------------
{
  if command -v docker >/dev/null 2>&1; then
    docker version --format 'client={{.Client.Version}} server={{.Server.Version}}' 2>/dev/null || echo "docker: version unavailable"
    echo "--- ps (name/image/status) ---"
    docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null
    echo "--- networks ---"
    docker network ls --format '{{.Name}}\t{{.Driver}}' 2>/dev/null
    echo "--- docker0 ---"
    ip -o addr show docker0 2>/dev/null || echo "no docker0"
  else
    echo "docker: not installed"
  fi
} > "$OUT/docker.txt"

# daemon.json: presence + sha + content (dns/gateway values are not secrets,
# but redact anyway for the public-evidence policy).
DAEMON_FILE="/etc/docker/daemon.json"
{
  if [ -f "$DAEMON_FILE" ]; then
    printf 'present\n'
    printf 'sha256=%s\n' "$(sha256sum "$DAEMON_FILE" 2>/dev/null | awk '{print $1}')"
    redact_yaml_stream < "$DAEMON_FILE"
  else
    printf 'absent\n'
  fi
} > "$OUT/daemon-json.state"

# --- DNS ----------------------------------------------------------------------
{
  printf 'resolved.enabled=%s\n' "$(systemctl is-enabled systemd-resolved 2>/dev/null || echo unavailable)"
  printf 'resolved.active=%s\n'  "$(systemctl is-active  systemd-resolved 2>/dev/null || echo unavailable)"
  if [ -L /etc/resolv.conf ]; then
    printf 'resolv.type=symlink\n'
    printf 'resolv.target=%s\n' "$(readlink /etc/resolv.conf 2>/dev/null)"
  elif [ -f /etc/resolv.conf ]; then
    printf 'resolv.type=file\n'
    printf 'resolv.immutable=%s\n' "$(lsattr /etc/resolv.conf 2>/dev/null | grep -q '\-i\-' && echo yes || echo no)"
  else
    printf 'resolv.type=missing\n'
  fi
  printf 'resolv.sha256=%s\n' "$(sha256sum /etc/resolv.conf 2>/dev/null | awk '{print $1}')"
  echo "--- content ---"
  redact_yaml_stream < /etc/resolv.conf 2>/dev/null
} > "$OUT/dns-state.txt"

# --- mihomo -------------------------------------------------------------------
CONFIG_PATH=""
if [ -s "$AMG_STATE_DIR/mihomo_config_path" ]; then
  CONFIG_PATH="$(cat "$AMG_STATE_DIR/mihomo_config_path")"
else
  CONFIG_PATH="$(find_mihomo_configs | head -n1)"
fi
{
  if command -v mihomo >/dev/null 2>&1; then
    printf 'mihomo.binary=%s\n' "$(mihomo -v 2>/dev/null | head -n1)"
  fi
  if systemctl list-unit-files 2>/dev/null | grep -q '^mihomo.service'; then
    printf 'mihomo.kind=service\n'
    printf 'mihomo.active=%s\n' "$(systemctl is-active mihomo.service 2>/dev/null || echo unknown)"
    printf 'mihomo.enabled=%s\n' "$(systemctl is-enabled mihomo.service 2>/dev/null || echo unknown)"
  elif command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -q mihomo; then
    printf 'mihomo.kind=container-running\n'
    printf 'mihomo.container=%s\n' "$(docker ps --format '{{.Names}}' 2>/dev/null | grep mihomo | head -n1)"
  elif command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q mihomo; then
    printf 'mihomo.kind=container-stopped\n'
    printf 'mihomo.container=%s\n' "$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep mihomo | head -n1)"
  else
    printf 'mihomo.kind=unknown\n'
  fi
  printf 'mihomo.config.path=%s\n' "${CONFIG_PATH:-none}"
  if [ -n "$CONFIG_PATH" ] && [ -f "$CONFIG_PATH" ]; then
    printf 'mihomo.config.sha256=%s\n' "$(sha256sum "$CONFIG_PATH" | awk '{print $1}')"
  fi
} > "$OUT/mihomo.txt"

printf '%s\n' "$CONFIG_PATH" > "$OUT/config.path"
if [ -n "$CONFIG_PATH" ] && [ -f "$CONFIG_PATH" ]; then
  sha256sum "$CONFIG_PATH" | awk '{print $1}' > "$OUT/config.sha"
  extract_ddp_keys "$CONFIG_PATH" > "$OUT/ddp-keys.txt"
  redact_yaml_stream < "$CONFIG_PATH" > "$OUT/mihomo-config-copy.REDACTED.yaml"
  ls -1 "$(dirname "$CONFIG_PATH")" 2>/dev/null > "$OUT/config-dir-listing.txt"
  note "mihomo-config-copy.REDACTED.yaml is NEVER safe to attach publicly: \
redaction is best-effort, the real config may contain credentials in other \
forms. Keep it on the disposable host; compare via config.sha instead."
else
  printf 'no config found\n' > "$OUT/ddp-keys.txt"
  : > "$OUT/config.sha"
  : > "$OUT/config-dir-listing.txt"
fi

# --- amnezia (safe fields only; never dump container env/inspect) -------------
{
  if command -v docker >/dev/null 2>&1; then
    AWG_C="$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep "^${AWG_CONTAINER_PREFIX}" | head -n1 || true)"
    if [ -n "$AWG_C" ]; then
      printf 'awg.container=%s\n' "$AWG_C"
      printf 'awg.status=%s\n' "$(docker ps -a --format '{{.Names}}\t{{.Status}}' 2>/dev/null | grep "^${AWG_C}" | cut -f2)"
      printf 'awg.image=%s\n' "$(docker inspect "$AWG_C" --format '{{index .Config.Image}}' 2>/dev/null)"
      printf 'awg.network=%s\n' "$(docker inspect "$AWG_C" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null | grep -o 'amnezia[a-zA-Z0-9_-]*' | head -n1)"
      printf 'awg.udp=%s\n' "$(docker port "$AWG_C" 2>/dev/null | grep '/udp' | head -n1 | awk -F'/' '{print $1}')"
    else
      echo "awg: no container matching ${AWG_CONTAINER_PREFIX}"
    fi
  else
    echo "awg: docker not installed"
  fi
} > "$OUT/awg.txt"

# --- systemd units (project + mihomo only) ------------------------------------
{
  systemctl list-unit-files 2>/dev/null | grep -E '^(warp-docker-routing|check-warp-routing)' || true
  for u in warp-docker-routing.service check-warp-routing.service check-warp-routing.timer; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^$u"; then
      printf '%s enabled=%s active=%s\n' "$u" \
        "$(systemctl is-enabled "$u" 2>/dev/null || echo unknown)" \
        "$(systemctl is-active "$u" 2>/dev/null || echo unknown)"
    fi
  done
  systemctl show warp-docker-routing.service -p NRestarts 2>/dev/null || true
} > "$OUT/units.txt"

ok "collected slot '$SLOT' into $OUT"
