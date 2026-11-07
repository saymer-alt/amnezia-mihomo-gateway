# AGENTS.md — amnezia-mihomo-gateway essentials

Small mandatory startup contract for AI coding agents. **Do not preload** the entire `docs/` tree, historic field reports or the relocated detailed guides. Read only relevant guides below. Current `install.sh`, `uninstall.sh`, `doctor.sh` and regression tests outrank dated descriptions. `README.md` and `install.md` serve users.

## Project, branches and operator authority

This is a root-capable VPS installer routing AmneziaWG clients in Docker through Mihomo TUN/WARP. It can modify routing, firewall, DNS, systemd, Docker and thus SSH reachability. `main` is integration; **`stable` is the public production installer channel**. Use isolated branches and Draft PRs. Green exact-SHA CI and separately authorized disposable/live-VPS acceptance are mandatory before release of behavior-changing code. Never alter `stable` directly, merge, publish/tag, update VPS or restart services without separate explicit **owner GO** for that action. A docs/code request does not authorize VPS access or mutation.

For complex changes follow the [cross-project task contract](https://github.com/saymer-alt/saymer-alt/blob/main/AGENT-TASK-CONTRACT.md): true user intent, checked base SHA, protected scenarios, scope/non-goals, negative tests, approval boundaries and testable acceptance. Do not achieve literal compliance by breaking working routes or user data. For large features use [Proof Before Build](https://github.com/saymer-alt/saymer-alt/blob/main/PROOF-BEFORE-BUILD.md) and compare no change, smallest safe fix and extended system. Avoid speculative refactoring and repeated unrelated licensing audits.

## Must-preserve VPS and privacy safety

- **Protect host SSH and routing**: the server's own traffic must NEVER enter `tun-mihomo`. Preserve top-level Mihomo `tun.auto-route: false`, keep project routing in **table 100** (not host `main`), and scope AWG source policy to the detected Docker subnet. Failure can lock out the operator.
- **Fail closed; no direct WAN escape. No DIRECT fallback.** Before altering source rules, restarting Mihomo/TUN or reconciling routes, retain the independent `AMG_FAILSECURE` FORWARD chain and `unreachable default metric 42760` in table 100. Never flush the guard through an empty/allow window. Only `tun-mihomo` or already-marked legitimate AWG return packets may pass. Distinguish service stopped (possible direct egress) from TUN crashed (blackhole); both require evidence.
- Preserve WG reply **fwmark `0x88`**, priority **40**, AWG source rule priority **100**, TUN/fake-IP routes, TCPMSS clamp, MASQUERADE, reverse-forward allowance and strict ICMP privacy (`disable-icmp-forwarding: true`). Lost priority-100 rule can expose the real VPS IP. Watchdog must never install a direct fallback; reconcile/repair the **complete** firewall/routes contract, allowing named or numeric table 100 aliases.
- Keep necessary `rp_filter=0` for asymmetric Docker/TUN traffic, the measured server `gvisor` baseline (unless new verified measurements justify change), MTU/MSS defaults and current IPv4-only behavior. Do not invent IPv6 safety: with `::/0`, IPv6 leakage is possible. Any change to these contracts requires new tests and owner decision.
- **Fail-fast discovery**, not guesses: missing/ambiguous `amnezia-awg` container, Docker network/subnet, WG port, host interface, TUN or Mihomo config must not trigger default routes or hard-coded guesses. Keep permissions and host context explicit.
- **Ownership-aware rollback**: protect administrator/foreign `/etc/docker/daemon.json`, `resolv.conf`, `systemd-resolved`, sysctl, `rt_tables`, Mihomo config and other system state. Restore installer-owned data only with verified ownership markers/checksums and no divergence; preserve failed/unproven rollback state for inspection, report failure rather than claiming baseline restored.
- Mihomo YAML edits must be top-level/path-scoped, preserve unrelated nested fields, filesystem metadata, symlink/hardlink protections, validation and same-filesystem atomic replacement. Never reintroduce global `sed`, shared `/tmp` staging or unvalidated output.
- Installer heredocs in **`install.sh` are authoritative**; `scripts/` templates may lag and must not be synchronized casually. Generated `oneshot` routing unit uses `RemainAfterExit`; on reinstall explicitly rerun service after daemon reload with barriers already installed, rather than trusting `enable --now` to reconcile.
- No unapproved live root/SSH/iptables/Docker/sysctl/DNS/firewall/route commands, no removal of foreign resources, no credential disclosure, no bypass of safety gates. CI or synthetic tests **do not** prove SSH recovery, production traffic privacy, live WARP, rollback or absence of leaks.

## Focused agent workflow

1. Check current branch/HEAD SHA, existing PRs, task intent and affected source/tests. Read only the topic-specific guide(s), not all project history. For impactful changes review README and target `install.sh` heredocs first.
2. Use the smallest reversible diff and keep working behavior, generated configuration and foreign state. Do not make unrelated changes or reformat an entire script.
3. For changes to shell code, run appropriate non-live checks: `bash -n install.sh uninstall.sh doctor.sh`, `sh -n scripts/*.sh`, `shellcheck -S error` when available, tests for fail-secure, installer-reconcile, config patch, watchdog and ownership rollback. The CI matrix is not a replacement for separately approved real VPS acceptance.
4. Review exact diff and final SHA. Report `PASS`, `FAIL`, `BLOCKED`, `NOT TESTED` distinctly; do not claim live success from unit tests. Stop on risky ambiguity and request owner GO, while continuing authorized read-only repository investigation.
5. Deliver only a Draft PR for owner review. No automatic `main`/ `stable` merge, tag, release, VPS change or deploy.

## Read detailed source instructions only when needed

- [01 — owner decisions, purpose, workflow and technical debt](docs/agent-guidance/01-owner-policy-and-workflow.md): architecture or scope decisions.
- [02 — file structure, installer sequence and testing](docs/agent-guidance/02-repository-and-install-lifecycle.md): installation/uninstallation and general developer work.
- [03 — routing invariants, SSH and fail-secure hazard analysis](docs/agent-guidance/03-routing-and-live-safety.md): Docker/Mihomo/TUN/firewall/DNS/watchdog changes.
- [04 — VPS helper tools and historical inconsistencies](docs/agent-guidance/04-vps-tools-and-historical-cases.md): CLI discovery, legacy behavior, regressions, older measurements.

Dated benchmarks, old incidents and field successes are **not today's machine state or production permission**. Only load history when relevant.
