# Owner policy, project purpose, agent workflow and debt

> **Relocated source guidance — 2026-11-07.** Original sections from root `AGENTS.md` at commit `27ebe8cd2cfe055c86b14d2078053131ee625143`; only relative Markdown link destinations were rebased. Inline file names and old phrases such as "this file" refer to the original repository root. Dated measurements, prior fixes and field results are historical evidence, **not** current production truth or approval.
>
> The [short root AGENTS.md](../../AGENTS.md) is binding on every task. Read this guide **only for work affecting its subject**; do not preload it or the entire docs tree by default.

---

> **Обязательный контракт для всех агентов и авторов ТЗ (30.10.2026):** [подробная постановка задач без «эффекта обезьяньей лапки»](https://github.com/saymer-alt/saymer-alt/blob/main/AGENT-TASK-CONTRACT.md). Перед работой проверить исходные refs/SHA, готовые результаты, точную цель, scope/non-goals, сохранность данных и сервисов, зависимости, границы разрешений/owner GO, негативную приёмку и доказательства. Не сокращать существенные требования ради токенов. Буквальное выполнение в ущерб цели считается **FAIL**. Местные правила безопасности и архитектуры обязательны.

> **Владелец, 26.10.2026 — общее правило для всех проектов:** перед внедрением новой функции / серьёзной переделки требуется короткая «защита идеи» — доказать проблему, сравнить альтернативы (включая ничего не менять / штатную ОС / ждать upstream), оценить пользу, **ТЭО**, стоимость сопровождения, риски, измеримый тест и критерии STOP. Нет доказательства пользы — DEFER/SKIP. Мелкие исправления не требуют отдельной бюрократии. **Источник:** [Proof Before Build](https://github.com/saymer-alt/saymer-alt/blob/main/PROOF-BEFORE-BUILD.md) ([центральный PR #9](https://github.com/saymer-alt/saymer-alt/pull/9)). Существующие safety/CI/permissions сохраняются.

# AGENTS.md — amnezia-mihomo-gateway

## Owner-wide design gate — SIMPLICITY-FIRST (2026-10-24)

Before adding a new subsystem, UI, installer/uninstaller, controller, watcher, multi-stage recovery mechanism, or expensive CI path, apply the [common saymer-alt simplicity rule](https://github.com/saymer-alt/saymer-alt/pull/7): compare (A) the existing/manual workflow, (B) the smallest safe solution, and (C) extended architecture. Choose A/B by default; C needs evidence of need, a maintenance/test-cost estimate and explicit owner approval. If supporting logic grows into its own platform or repeated full E2E runs add no new evidence, STOP expanding and report alternatives. Preserve existing safety invariants, user data, foreign resources and working behavior; this does not authorize refactoring stable code or changing production. [KAS uninstall #225](https://github.com/saymer-alt/keenetic-auto-setup/issues/225) is an **anti-pattern retrospective**, not a template to copy.

Persistent instructions for AI agents (primarily ZCode) working with this repository.
This file complements `README.md` and `install.md` rather than duplicating them: README is user documentation
(architecture, Mihomo TUN configuration, verification, troubleshooting), while this file contains working rules and traps for
the agent. The project and documentation language is Russian. Owner: `saymer-alt`. Branches: `main` is integration; `stable` is production.

## Purpose

A one-command installer (bash, root) for VPS hosts: routes traffic from AmneziaWG clients
(Docker container `amnezia-awg`) through the Mihomo (Clash Meta) TUN interface `tun-mihomo`, so
clients access the Internet using a Cloudflare WARP IP while the real VPS IP remains hidden.
Target environment: Debian 12 / Ubuntu 22.04+, systemd, Docker, with Mihomo installed
(`mihomo.service` or a Docker container). The owner's development host is Windows (Git Bash): project scripts
run ONLY on the target VPS, never on the development host.

## Agent working rules

1. Before changing existing behavior, understand why it exists (the comment at the top of
   install.sh and the README record measured results), and verify idempotency of repeated
   installation on an already deployed server.
2. Do not remove or rewrite working functionality merely to "simplify" code — only do so for
   an explicit owner task.
3. Environment values (subnet, WG_PORT, interface, 198.18.0.0/16, table
   100, fwmark 0x88, priorities 100/40, mtu 1420) must not be changed without understanding their purpose; in
   heredocs they are substituted from auto-detection — do not hardcode them.
4. Auto-detection is fail-fast: if container/subnet/port detection fails, the script exits.
   Do not replace the failure with guesses or defaults.
5. Before significant changes, reread README.md (the "Mihomo configuration" and
   "Troubleshooting" sections), the relevant heredocs, and templates. Behavioral changes belong in
   install.sh — it is the source of truth.
6. After changes: run `bash -n install.sh`, `bash -n uninstall.sh`, `sh -n scripts/*.sh`,
   `bash tests/test-mihomo-config-patch.sh`, `bash tests/test-fail-secure.sh`,
   `bash tests/test-installer-reconcile.sh`, `bash tests/test-watchdog.sh`,
   and `shellcheck -S error` when available. CI runs the same lightweight
   checks. Explicitly report which checks were performed and which are possible only on a VPS.
7. For an ambiguous task, first investigate the repository and state the constraints you found,
   then ask the owner; do not make assumptions.
8. Release flow: feature/fix branches -> PR into `main` -> green CI -> live VPS validation when behavior touches routing,
   installer, systemd, Docker, or Mihomo -> PR `main` -> `stable`. README/install.md point to
   `raw.githubusercontent.com/.../stable/install.sh`, so only `stable` is the public installer channel.
   Do not push unvalidated behavioral changes directly to `stable`.

## Technical debt

- Treat technical debt as a separate engineering risk, but do not confuse it with cosmetics, personal style preferences, or merely "ugly" working code.
- For each debt item, provide evidence first and classify its impact: **High** (breakage/security/data-loss risk or blocks operation), **Medium** (impedes development, creates duplication or logic divergence, or materially increases maintenance cost), **Low** (local complexity with little current risk).
- Do not refactor for cleanliness alone. Pay down debt when the benefit and risk reduction justify the change; do not rewrite stable, verified code without a concrete reason.
- Debt fixes must keep minimal scope, preserve existing safety boundaries, and pass the project's normal regression/safety checks. If the fix creates greater risk or new debt, stop and propose a safer alternative.
- If debt is discovered outside the current task, do not silently expand scope: record the finding and recommendation, and implement it only when it is in scope or explicitly approved by the operator.
- If debt is discovered outside the current task, do not change code or documentation solely to record the finding. In the final report, state the location, brief description, evidence, **High / Medium / Low** level, risk, and recommended action. If the finding deserves separate tracking, propose creating a GitHub Issue. Create an Issue, add a `TODO`, or change files to record debt only with explicit operator permission. `TODO (TechDebt ...)` is acceptable when such a comment is within the approved scope and is genuinely needed next to the code.
