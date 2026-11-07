# VPS PATH/tool discovery and historical discrepancies

> **Relocated source guidance — 2026-11-07.** Original sections from root `AGENTS.md` at commit `27ebe8cd2cfe055c86b14d2078053131ee625143`; only relative Markdown link destinations were rebased. Inline file names and old phrases such as "this file" refer to the original repository root. Dated measurements, prior fixes and field results are historical evidence, **not** current production truth or approval.
>
> The [short root AGENTS.md](../../AGENTS.md) is binding on every task. Read this guide **only for work affecting its subject**; do not preload it or the entire docs tree by default.

---

## VPS helper tools and PATH

- When preparing or auditing a new Debian/Ubuntu VPS, do not assume that a CLI tool is absent just because \`command -v <tool>\` or a bare command returns \`command not found\`. User-local installers commonly place binaries in \`~/.local/bin\`, and root's non-login/non-interactive PATH may not include that directory.
- **warpscout:** before reinstalling it, check both \`command -v warpscout\` and \`~/.local/bin/warpscout\`. The official installer may report that warpscout is already installed in \`/root/.local/bin\` even though typing \`warpscout\` fails.
- If \`~/.local/bin/warpscout\` exists, use that binary and make \`~/.local/bin\` persistently available in PATH for future administration/automation. Prefer an idempotent PATH change (do not add duplicate PATH entries), then verify in a fresh shell with \`command -v warpscout\` and \`warpscout version\`.
- This check should be part of future VPS bootstrap/automation work so an agent does not unnecessarily download/reinstall an already present warpscout binary.

## Known inconsistencies (do not "fix" silently)

- `scripts/warp-docker-routing.sh` lags behind install.sh: commits 8eb641d and cc3ae73 (2026-07-29)
  changed only install.sh, while the templates are a snapshot from 2026-07-27. The template lacks the FAKE_IP_RANGE route,
  30-second interface wait, `txqueuelen 5000`, and logger messages. Synchronizing templates is
  a separate owner decision, not a "small fix".
- Historical TUN examples used an explicit top-level `inet4-address`, but Mihomo 1.19.31 derives the effective top-level TUN IPv4 prefix from `dns.fake-ip-range`. The installer now removes only the legacy top-level field while preserving per-proxy listener `inet4-address`. Keep future docs/tests tied to the target Mihomo version and live interface evidence.
- `install.md` is headed with the old name "awg-warp-router".
- Historical entry, resolved in v2.0.0 (PR #24): pre-#24 `uninstall.sh` claimed "the server returned
  to standard settings" while leaving installer-owned changes in place. The current uninstaller
  performs an ownership-aware rollback driven by `/var/lib/amnezia-mihomo-gateway` and its contract is:
  the Mihomo config is restored to the exact pre-install content only with a proven checksum match
  and no divergence flag — restoration goes through a temporary file, `mihomo -t -f` validation and a
  same-filesystem atomic replace, and an admin-modified config is never overwritten; installer-created
  `/etc/docker/daemon.json` is removed only with the ownership marker plus checksum match; the
  `100 mihomo` entry is removed from `rt_tables` only with proven ownership and no runtime consumers;
  `systemd-resolved`/`resolv.conf` are restored only when the DNS state belongs to the installer and
  the managed state has not diverged, preserving the original resolv.conf semantics (symlink/file/
  missing) and the immutable attribute; sysctl file and live values (including per-interface
  `rp_filter`) are restored only with proven ownership — admin-modified values are preserved.
  On an incomplete or unproven rollback the state-dir is kept for manual inspection and uninstall
  exits with code 2; pre-existing system state is never removed. Live acceptance ran the full
  baseline → install → reboot → repeated install → uninstall → baseline-compare cycle on Ubuntu
  24.04 for the v2.0.0 release; regression coverage lives in `tests/test-ownership-rollback.sh`.
  See also `docs/LIVE_AUDIT_2026-09-23.md`.

