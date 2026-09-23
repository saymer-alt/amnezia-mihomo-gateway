# Live audit — 2026-09-23

This note records findings from live VPS checks before the next production rollback changes.

## Confirmed on SE2

- Legacy uninstall left `/etc/docker/daemon.json` with `"dns": ["172.17.0.1"]`.
  The AWG container then failed DNS resolution. Removing that override and restarting Docker
  immediately restored real DNS answers and HTTPS.
- Legacy uninstall left installer-era Mihomo config changes behind. Manual cleanup on SE2
  removed the obsolete TUN/fake-IP related state; Mihomo config validation succeeded and the
  explicit mixed-port WARP path continued to work.
- `100 mihomo` remained in `/etc/iproute2/rt_tables` after the old gateway rules/services were gone.
- The earlier watchdog bug around `lookup 100` vs `lookup mihomo` was confirmed live and fixed separately.

## Confirmed on EE / Ubuntu 24.04

A second live VPS was inspected while the older gateway integration was still active. This is useful
because it distinguishes uninstall residue from failures that can occur during a running gateway.

- The host was Ubuntu 24.04 with Mihomo 1.19.31, an active `tun-mihomo`, policy rule
  `from 172.29.172.0/24 lookup mihomo`, table 100 defaulting to `tun-mihomo`, and the
  legacy Docker DNS override `"dns": ["172.17.0.1"]`.
- Mihomo listened on TCP/UDP `:53`. DNS queries issued on the host to both
  `127.0.0.1:53` and `172.17.0.1:53` succeeded immediately and returned a fake-IP answer.
  The AWG container, however, timed out when querying the same host address.
- The host firewall used UFW with default incoming deny. There was no rule allowing the Docker
  bridge to reach the host DNS listener. Adding narrow rules for
  `docker0 / 172.17.0.0/16 -> 172.17.0.1:53` over both UDP and TCP immediately restored
  container DNS resolution; an HTTPS request from the container then succeeded with HTTP 301.
  This proves that the current Docker-DNS design has a host-firewall dependency that the installer
  does not yet own or validate.
- The live machine also carried the old watchdog implementation that checked only textual
  `lookup 100`. Because iproute2 rendered the installed rule as `lookup mihomo`, the watchdog
  falsely reported missing rules, restarted `warp-docker-routing.service` every minute, and
  returned failure. Replacing only the watchdog with the current stable alias-aware logic made
  every subsequent timer run finish with status 0 without the restart loop.
- Direct Cloudflare trace on this host reported `loc=EE`, `colo=ARN`, `warp=off`; the
  explicit Mihomo/WARP path reported `loc=EE`, `colo=ARN`, `warp=on`. This is recorded as
  path evidence only, not as a routing invariant.

### Design consequence from the EE firewall case

If a future installer continues to make Docker use a DNS service on the host, reachability of that
host service is part of the same integration transaction. A production implementation must:

1. discover the Docker bridge/subnet and the effective host DNS address/port;
2. discover the active firewall architecture and existing rules;
3. add only the narrow rule(s) required for that owned path;
4. record ownership of any created firewall rule;
5. validate DNS from inside the actual AWG container, not only from the host;
6. remove only project-owned firewall state during rollback/uninstall.

No firewall mutation from this finding is promoted to stable yet. The live manual UFW rules are
evidence for the required behavior, not a tested installer implementation.

## What stable does now

The production installer now records **state only** in `/var/lib/amnezia-mihomo-gateway`:

- whether it added `100 mihomo`;
- whether it created `/etc/docker/daemon.json`, plus its checksum and docker0 gateway;
- the exact first pre-install Mihomo config snapshot and path;
- the checksum of the installer-patched Mihomo config;
- a divergence marker if repeated installation detects that Mihomo config changed afterwards.

This tracking does **not** change routing, DNS behavior, Mihomo patch values, or current uninstall behavior.
It exists so future rollback can prove ownership instead of guessing.

### Rollout decision made on 2026-09-23

The rollback work was intentionally split into two stages instead of waiting for a disposable VPS
before saving any of today's progress:

1. **Promoted to `stable` now:** tracking-only state capture in the installer plus this audit
   documentation. New installations immediately start preserving ownership/snapshots needed for a
   future safe rollback.
2. **Kept out of `stable` for now:** the new automatic rollback logic from PR #4. It remains gated
   on a disposable-VPS `install -> reboot -> uninstall` test.

This compromise is deliberate. It avoids shipping unvalidated automatic host-state restoration while
also avoiding another generation of "blind" installations that cannot later prove which system state
the project itself created or modified.

## Implemented in PR #4 but not promoted to stable yet

A new uninstall implementation can use the recorded state to:

- remove only installer-owned Docker DNS state;
- remove only a tracked/unused `100 mihomo` registration;
- restore the exact original Mihomo config only on checksum match;
- preserve administrator-modified files.

Repository CI/regression tests pass, but the system-level `install -> reboot -> uninstall` flow has not yet
been validated on a disposable VPS. Therefore those automatic rollback actions are intentionally not in
`stable` yet.

## Known rollback gaps

- `systemd-resolved` / original `/etc/resolv.conf` / immutable attribute are not restored.
- live sysctl values are not fully restored.
- legacy installations created before state tracking cannot safely reconstruct all original state.

## Observed, not proven

- On SE2 with Mihomo 1.19.31, configured `inet4-address: 10.255.255.1/30` differed from the live
  TUN address `198.18.0.0/30`. The same config-vs-live mismatch was observed again on the EE
  Ubuntu 24.04 host while its gateway was active. Repetition makes this worth investigating, but
  the root cause is still not proven.
- Martian log messages were not eliminated entirely by removing TUN, so TUN is not established as
  their sole cause.
- On the EE production Mihomo runtime, logs contained `H3_REQUEST_CANCELLED`,
  `use of closed network connection` for `WARP-MASQUE-QUIC`, and repeated
  `Fastest_MASQUE failed multiple times` health-check activation. At the time of inspection the
  URLTest group selected H2. This is direct production evidence of H3 instability on that path,
  but it is not proof that H3 is universally broken or that the configured QUIC proxy always fails.
- WARPSCOUT showed a strong H2/H3 difference on a fresh separate WARP account. With the default SNI,
  MASQUE/QUIC had 1/14 working while MASQUE-H2 had 70/70. Repeating both scans with the same
  `SNI=4pda.to` used by the current Mihomo proxies changed QUIC only to 2/14, while H2 remained 70/70.
  Both transports still reported `SEEN AS SE` via `FRA`. This strengthens the observation that H2 is
  much more robust on this SE2 path, but it still does **not** prove that the currently configured Mihomo
  `WARP-MASQUE-QUIC` proxy is broken: WARPSCOUT used a separate fresh WARP account and different
  tested endpoints/ports. Mihomo's own health data at the same time showed QUIC ~40 ms, H2 ~42 ms,
  with `Fastest_MASQUE` currently selecting H2.

## Cross-project impact

Today's findings are not isolated to this repository. They define a shared contract across three projects:

- **`link-generators`** produces the Mihomo configuration for the VPS Gateway profile. Its
  `docs/VPS-GATEWAY.md` values and assumptions must stay compatible with this project's real routing,
  TUN, DNS and lifecycle behavior. Generator output alone is not proof that host integration is correct.
- **`amnezia-mihomo-gateway`** owns the current host-side AWG -> Mihomo integration: policy routing,
  Docker interaction, TUN expectations, systemd/watchdog and rollback state.
- **`vps-gateway-bootstrap`** is the future orchestration layer. It should discover both the generated
  Mihomo state and the host integration, model ownership explicitly, plan the smallest change, validate
  end-to-end behavior, and roll back only state it can prove it owns.

The 2026-09-23 SE2 incident is therefore reusable evidence for all three repositories: system-wide
Docker DNS, routing-table registrations and Mihomo config edits must never be treated as disposable
side effects. Their pre-install/ownership state must be discoverable or recorded before mutation.

## Release gate for automatic rollback

Before PR #4 automatic rollback is promoted to production, use a disposable VPS and test:

1. clean install -> verify gateway -> reboot -> uninstall -> before/after comparison;
2. repeated install -> uninstall;
3. manual Mihomo edit after install -> uninstall must preserve the edit;
4. pre-existing custom `/etc/docker/daemon.json` -> must remain untouched;
5. Ubuntu/systemd-resolved scenario;
6. no project-owned routes/rules/units/generated files left after successful uninstall;
7. Ubuntu/UFW-active gateway: container -> host DNS must work, and any installer-created firewall
   allowance must be tracked and removed only when proven owned.
