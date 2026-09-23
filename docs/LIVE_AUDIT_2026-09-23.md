# Live audit — 2026-09-23

This note records findings from live VPS checks performed before the next production release.
It intentionally separates **proven behavior** from **implemented but not yet live-validated fixes**
and from **observations whose root cause is not yet proven**.

The goal is to prevent later documentation or agents from turning a plausible explanation into a
claimed fact.

## Confirmed on live servers

### Watchdog accepted only numeric table name

**Status: CONFIRMED AND FIXED.**

On a live server the routing table was registered as `100 mihomo`. Linux therefore rendered the
policy rule as `lookup mihomo`, while the old watchdog expected literal `lookup 100`. The watchdog
incorrectly treated healthy routing as broken and restarted `warp-docker-routing.service` every minute.

The watchdog now accepts both numeric and named representations and re-checks routing state after
self-heal. The fix was live-tested and has regression coverage.

### Legacy Docker DNS override survived gateway removal

**Status: CONFIRMED ON SE2; CODE FIX IMPLEMENTED; NEW UNINSTALL NOT YET LIVE-VALIDATED.**

SE2 had no gateway service/routing rules anymore, but `/etc/docker/daemon.json` still contained the
legacy installer-created DNS override:

```json
{
  "dns": ["172.17.0.1"]
}
```

Docker's embedded resolver in `amnezia-awg2` therefore forwarded external DNS to the host bridge
address. The container produced `Resolving timed out` and could not resolve `google.com`.

After removing the override and restarting Docker, the container immediately used the host's normal
resolvers (1.1.1.1 / 8.8.8.8), returned real Google addresses, and HTTPS worked again.

New installer/uninstall code tracks ownership and checksum of an installer-created
`daemon.json`. Uninstall removes it only when it is still project-owned and unchanged. For legacy
installs it recognizes only the exact old one-purpose file; custom or modified files are preserved.

### Legacy Mihomo patches survived old uninstall

**Status: CONFIRMED ON SE2; CODE FIX IMPLEMENTED FOR NEW INSTALLS; NOT YET LIVE-VALIDATED.**

After the old gateway had been removed, SE2 still contained installer-era Mihomo settings such as
TUN/fake-IP related values and profile changes. Removing the unused TUN block and old fake-IP/DNS
settings did not break the active mixed-port proxy path: WARP still exited as `SE` via `FRA`, and
container DNS/HTTPS continued working after Docker DNS was corrected.

For new installs the installer now stores an exact first pre-install Mihomo snapshot and the checksum
of the installer-patched config. Uninstall restores the original config only when the current file
still matches the installer-managed checksum. If an administrator has edited the config, automatic
rollback is skipped and the snapshot is preserved.

Legacy installs have no trustworthy ownership metadata, so automatic reconstruction of their original
Mihomo config is intentionally not attempted.

### `100 mihomo` entry can survive old uninstall

**Status: CONFIRMED ON SE2; TRACKED CLEANUP IMPLEMENTED FOR NEW INSTALLS.**

SE2 retained `100 mihomo` in `/etc/iproute2/rt_tables` after the old routing service and policy
rules were gone.

New installs record whether this project actually added the entry. Uninstall removes it only when that
ownership marker exists and table 100 is no longer in use. A legacy entry without an ownership marker
is reported but deliberately preserved; removing an untracked system-wide routing-table registration
automatically would be unsafe.

## Known rollback gaps

### systemd-resolved and /etc/resolv.conf

**Status: BEHAVIOR KNOWN; ORIGIN ON SE2 NOT PROVEN; FIX NOT IMPLEMENTED YET.**

Current installer code disables active `systemd-resolved`, replaces `/etc/resolv.conf` with
1.1.1.1 / 8.8.8.8 and applies the immutable attribute. Current uninstall does not restore the previous
resolver manager, original file/symlink, or file attributes.

SE2 was observed with exactly that resulting state, but the July legacy installer did not contain this
logic, so the live state cannot be attributed to a specific historical installer run with certainty.

Before automatic rollback is implemented, test on a disposable Debian/Ubuntu VPS and preserve:
service enabled/active state, original `/etc/resolv.conf` type/target/content, and immutable attributes.

### Live sysctl values

**Status: CODE BEHAVIOR KNOWN; ROLLBACK NOT IMPLEMENTED OR LIVE-VALIDATED.**

Installer writes `99-amnezia-mihomo.conf` and also changes live values, including `rp_filter`
for interfaces. Removing the sysctl file does not by itself restore all previous live values.

A safe rollback needs a pre-install snapshot and a disposable-VPS test before production use.

## Observed, but not proven as project bugs

### Configured TUN address differed from runtime TUN address

**Status: OBSERVED; ROOT CAUSE NOT PROVEN.**

On SE2 with Mihomo 1.19.31 the config contained
`inet4-address: 10.255.255.1/30`, while the live `tun-mihomo` interface used
`198.18.0.0/30`. The config validated successfully.

Do not change installer TUN-address logic based on this observation alone. It needs a controlled test
against the current Mihomo syntax/behavior.

### Martian log messages are not explained solely by TUN

**Status: HYPOTHESIS DISPROVED AS A SOLE CAUSE.**

SE2 had repeated `Martian packet dropped with loopback source address` messages while the old TUN
was present. At least one additional martian message appeared after the TUN block was removed, so
"the unused TUN is the sole cause" is false. Further diagnosis is separate from uninstall rollback.

## Findings outside this repository

These were discovered during the same server session but must not be presented as
`amnezia-mihomo-gateway` bugs:

- a duplicate custom logrotate rule caused `logrotate.service` failure; removing that unrelated custom
  rule restored a clean systemd state;
- WARPSCOUT on SE2 showed WG mostly healthy, MASQUE-H2 70/70 working via FRA, while MASQUE/QUIC had
  only 1/14 working in that run. This is useful operational evidence for the server's WARP transport
  choice, not evidence about installer/uninstaller correctness.

## Required validation before release

The current rollback changes pass repository CI, but system-level behavior still needs a disposable VPS.

Minimum live matrix:

1. clean install -> verify gateway -> reboot -> uninstall -> compare before/after state;
2. repeated install -> uninstall;
3. edit Mihomo config after install -> uninstall must preserve the edit and snapshot;
4. pre-existing custom `/etc/docker/daemon.json` -> install/uninstall must preserve it;
5. Ubuntu/systemd-resolved scenario -> validate resolver snapshot/restore before implementing it;
6. verify no project routes, rules, units, generated files, Docker DNS override or tracked Mihomo patch
   remain after a successful uninstall.

Do not promote these rollback changes to `stable` until the system-level cases that affect real host
state have been exercised on a disposable VPS.
