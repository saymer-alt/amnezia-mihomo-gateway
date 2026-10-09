# Owner Experience Gate v1.0 — Amnezia Mihomo Gateway

**Aim:** CI must check what the operator sees and can safely conclude, not
just that install scripts parse and unit assertions pass. This complements
existing fail-secure, ownership rollback, watchdog, installer reconciliation,
sysctl and disposable-live-kit tests.

## Automated CI contract

`python3 tests/owner-experience-gate.py` executes the actual read-only
`doctor.sh` against isolated `AMG_DIAGNOSTIC_ROOT` fixtures. It proves:

- Missing runtime evidence reports UNKNOWN/WARN, never success.
- Healthy all/default/interface values produce meaningful OK output.
- Conflicting runtime and persistent sysctl declarations produce actionable
  WARN, warn against blind reload, and exit nonzero.
- Unsupported `--fix` is refused with read-only usage guidance.
- Fixture contents are byte-identical before and after every diagnostic.

The test never installs, deletes, routes traffic or accesses a real VPS.
It **does not** prove live AWG handshake, leak freedom or applied system state.

## Owner/agent acceptance journey — disposable VM ONLY

1. Read the prerequisites and run Doctor as a novice; every WARN/UNKNOWN
   must indicate what was observed, what remains unknown and a safe next step.
2. Record pre-install Docker, AWG, Mihomo, sysctl, systemd and route state,
   with sensitive details redacted and an independent recovery path.
3. On a disposable VM with explicit opt-in, use `tests/live/` and its guard
   to test first install, repeated install, watchdog, service failure,
   fail-secure default, rollback, uninstall and reboot continuation.
4. Confirm actual network behavior with permitted client-side probes:
   connectivity, correct egress, failures and recovery. A successful parse
   or static snapshot is not evidence of packet-level safety.
5. Test declined confirmation, stale ownership, foreign sysctl files,
   interrupted installation and missing prerequisites. Fail closed without
   removing foreign state. Verify prompts, remediation and backup instructions.
6. Check 80/40-column terminal transcripts, NO_COLOR behavior, redaction,
   actionable exit codes and no ambiguous SUCCESS when egress is UNKNOWN.

Record exact SHA, fixture/version, safety guard, before/after state,
operator-visible output, PASS/FAIL/UNKNOWN/NOT RUN, CI and evidence links.
Do not turn an agent's positive impression into release authorization.

## Release rule

GitHub CI should run only isolated/non-mutating cases. Any real
network/firewall/systemd/VPS experiment requires a disposable environment
and explicit operator approval. Promotion to stable and publishing a release
require a separate owner's GO. New human-reported UX/safety defects receive
minimal reproducible regression tests where feasible.
