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

## What stable does now

The production installer now records **state only** in `/var/lib/amnezia-mihomo-gateway`:

- whether it added `100 mihomo`;
- whether it created `/etc/docker/daemon.json`, plus its checksum and docker0 gateway;
- the exact first pre-install Mihomo config snapshot and path;
- the checksum of the installer-patched Mihomo config;
- a divergence marker if repeated installation detects that Mihomo config changed afterwards.

This tracking does **not** change routing, DNS behavior, Mihomo patch values, or current uninstall behavior.
It exists so future rollback can prove ownership instead of guessing.

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
  TUN address `198.18.0.0/30`. Root cause is not proven.
- Martian log messages were not eliminated entirely by removing TUN, so TUN is not established as
  their sole cause.
- WARPSCOUT showed a strong H2/H3 difference on a fresh separate WARP account, but this does not
  directly prove the current Mihomo MASQUE QUIC proxy is unhealthy because account/SNI/endpoints differ.

## Release gate for automatic rollback

Before PR #4 automatic rollback is promoted to production, use a disposable VPS and test:

1. clean install -> verify gateway -> reboot -> uninstall -> before/after comparison;
2. repeated install -> uninstall;
3. manual Mihomo edit after install -> uninstall must preserve the edit;
4. pre-existing custom `/etc/docker/daemon.json` -> must remain untouched;
5. Ubuntu/systemd-resolved scenario;
6. no project-owned routes/rules/units/generated files left after successful uninstall.
