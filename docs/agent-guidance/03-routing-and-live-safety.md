# Routing invariants and dangerous live operations

> **Relocated source guidance — 2026-11-07.** Original sections from root `AGENTS.md` at commit `27ebe8cd2cfe055c86b14d2078053131ee625143`; only relative Markdown link destinations were rebased. Inline file names and old phrases such as "this file" refer to the original repository root. Dated measurements, prior fixes and field results are historical evidence, **not** current production truth or approval.
>
> The [short root AGENTS.md](../../AGENTS.md) is binding on every task. Read this guide **only for work affecting its subject**; do not preload it or the entire docs tree by default.

---

## Core logic (change only with understanding and an owner decision)

- **The main table is not touched**: all policy routing lives in table 100 — this keeps server SSH safe.
- **`auto-route: false` in Mihomo TUN** is critical: with `true`, Mihomo captures all server traffic
  and SSH dies.
- **fwmark 0x88 + priority 40**: WireGuard replies (UDP source port WG_PORT) must leave through main,
  bypassing the tunnel — otherwise the handshake never completes and clients cannot connect.
- **Priority 100 / table 100**: removing the rule makes client traffic leave directly using the real
  VPS IP (de-anonymization), rather than merely "stopping working".
- **`rp_filter=0`**: with 1, the kernel drops asymmetric packets (docker bridge → TUN).
- **Fail-secure is independent of the normal TUN route**: table 100 retains a terminal `unreachable default`, while
  `AMG_FAILSECURE` blocks AWG-subnet forwarding to ordinary WAN unless the packet is the marked outer AWG reply.
  Losing the TUN route or the source rule must fail closed. Runtime `ExecStop=cleanup` keeps these barriers; only
  explicit uninstall `purge` may remove them. The watchdog repairs the barriers and must NEVER add a direct fallback route.
- **Strict ICMP privacy**: Mihomo 1.19.31 with gVisor can create host ICMP sockets outside normal TCP/UDP proxy matching.
  The project contract therefore requires top-level `tun.disable-icmp-forwarding: true`.
- **`TCPMSS --clamp-mss-to-pmtu` + `mtu: 1420`**: double encapsulation AWG+WARP; according to
  the owner's measurements, clamp gives roughly 2x speed. Do not change without new measurements.
- **An IPv4 address on the TUN is required for the IPv4/NAT scenario**, but on **Mihomo 1.19.31** the top-level `RawTun.Inet4Address` field is not parsed. `parseTun()` derives the effective TUN IPv4 prefix from `dns.fake-ip-range` and forces a `/30` prefix. Do not claim that writing top-level `tun.inet4-address` controls the live address on this version. Per-proxy TUN listeners use a different config path where `inet4-address` is supported.
- **Server TUN baseline remains `gvisor` (2026-09-21)**: testing was done with **Mihomo 1.19.31**. The owner tested `mips` on three VPS hosts and ran three comparative speed tests on the EE server. Recorded results in that EE test series were 28.9/40.0, 25.8/45.9, and 34.7/47.6 Mbps (download/upload); the owner's practical comparison showed `mips` roughly 10 Mbps worse on download than the current `gvisor` baseline. Do not switch the installer/server baseline to `mips` merely because it is newer or performs well on routers. Re-evaluate only with new VPS measurements after later Mihomo/mipstack updates.
- **IPv4-only**: IPv6 is not routed; with `::/0` in AWG, an IPv6 leak is possible.

## Dangerous areas (can cut off SSH or break the server)

- Any rule that sends the SERVER'S OWN traffic into `tun-mihomo` (`auto-route: true`,
  rules without `from <docker-subnet>`, changes to the main table) — loss of SSH access.
- Application order: the independent fail-secure guard and terminal route must exist BEFORE any source-rule deletion,
  TUN restart or routing reconciliation. Do not flush the guard chain during a normal reconcile: rebuilding it through
  an empty state would recreate the exposure window this protection is intended to close.
- `resolv.conf`, systemd-resolved, `/etc/docker/daemon.json` are system-wide state not
  owned by this project; preserve the current behavior ("only if absent/active").
- Mihomo config mutation must remain path-scoped and atomic. Never restore global `sed`/unscoped key replacement,
  fixed `/tmp/mihomo_config.yaml` staging, or replacement that changes owner/group/mode. Comments are not keys;
  nested listener/proxy fields must survive unchanged. Unsupported structures must fail before replacing the source file.
- Source-side forwarding is owned by `AMG_FAILSECURE`; the legacy broad source `FORWARD ... ACCEPT` is removed. The reverse `-d <docker-subnet>` allowance remains for return traffic.
- Repeated installation must not rely on `systemctl enable --now warp-docker-routing.service` to apply a rewritten
  oneshot unit/script. With `RemainAfterExit=yes`, an already-active unit is not re-executed. Installer must perform
  a synchronous routing-service restart after `daemon-reload`, while fail-secure barriers are already installed.
- The watchdog restarts Mihomo once per minute if `tun-mihomo` is absent and restarts
  `warp-docker-routing.service` if the gateway topology is incomplete — check changes to this loop for
  restart loops. Its healthy-state contract includes the source/fwmark rules, preferred TUN default,
  terminal unreachable and fake-IP routes, the FORWARD hook plus all three `AMG_FAILSECURE` rules,
  outer-AWG MARK, TCPMSS clamp, TUN MASQUERADE, reverse-destination FORWARD allowance, and absence of
  the legacy broad source ACCEPT.
  Table 100 is registered as `100 mihomo`, so `ip rule show` may render the same rule as
  `lookup mihomo` instead of `lookup 100`; watchdog checks must accept both forms and must
  re-check the full contract after self-heal before returning success.
- Do not unify the "service stopped" and "tun-mihomo crashed" scenarios — they have different effects
  (direct egress vs black hole).

