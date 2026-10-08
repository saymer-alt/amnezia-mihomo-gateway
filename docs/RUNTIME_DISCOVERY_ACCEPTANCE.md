# Runtime-aware discovery: candidate and acceptance boundary (#20)

This candidate replaces the first-file search with a read-only binding to one running Mihomo executable. It runs before installer state creation. Python 3.9+ is required (available in the supported Debian 12 / Ubuntu 22.04+ targets).

The authoritative inputs are `/proc/PID/cmdline`, start time, environment identity, executable, root and cwd; systemd `MainPID`/`ActiveState`/`ExecStart`; or the exact Docker container ID, init PID, command arguments and mount map. `-f` is relative to process cwd; `-d` supplies `config.yaml` only when `-f` is absent. Backup filenames and directory enumeration do not select a config. Directory bind mounts must resolve to the same device/inode visible through `/proc/PID/root`. The existing atomic/scoped patcher remains the only YAML writer.

The candidate checks the binding before state creation, before backup/config-state writes and immediately before atomic rename. It verifies the controller again before restart, allowing only its own config inode/content replacement. Installer and generated watchdog restart the exact selected service/container, never the first name match.

Supported fixtures: systemd `-d`, absolute/relative `-f`, repeated discovery, backup configs, Docker `-d`/`-f` with a writable directory bind, runtime/config/controller changes and mismatched file devices. Ambiguity, no running process (including provisioning Mihomo later), unbound/wrapper processes, duplicate flags, unknown flags, default-path guessing, environment-supplied/in-memory/encrypted/stdin config, symlink/hardlink files, overlapping mounts, read-only/volume/single-file bind mounts fail closed. Provision and start Mihomo before gateway installation. Arbitrarily renamed executables other than `mihomo`/`mihomo-*` are unsupported.

## Why this PR remains draft

The installer still may create `daemon.json` and restart Docker before the config phase. That legitimate transition can change a Docker Mihomo PID and make the subsequent guard refuse **after earlier sysctl/DNS/Docker changes**. The initial ambiguous/no-runtime preflight writes nothing; a later runtime change is not a rollback transaction for earlier installer phases. Do not silently rediscover and accept a different runtime. A full transition needs an explicitly modeled, tested ownership boundary before main integration.

An exact container ID also means container recreation requires reinstall; the watchdog must never silently switch to a replacement with an unproven config. A stale ID stops recovery until admission is rerun. This is a deliberate conservative candidate, not live acceptance.

## Disposable acceptance required before integration/release

Use a separately authorized, disposable host with console and captured baseline. Test a running systemd service with `-d`, `-f`, cwd-relative `-f`, extra backups and override/drop-in ExecStart. Repeat install, uninstall and compare the original YAML/ownership state. Inject service restart, PID reuse, argv/cwd/config edits between discovery, first write and rename; refusal must preserve the selected config and report earlier side effects honestly.

For Docker, test real directory mounts, `/proc/PID/root` device/inode mapping, custom command, no host mihomo.service, initial absent/present daemon.json, Docker restart behavior, read-only/single-file/volume mounts, wrappers, container replacement and reboot. Resolve the daemon-restart transition with automated orchestration fixtures before merge. Verify the same config actually drives the restarted runtime, then exercise fail-secure and rollback. Keep #20 open until all acceptance criteria are met.

Sources checked against Mihomo v1.19.31: [main.go](https://raw.githubusercontent.com/MetaCubeX/mihomo/v1.19.31/main.go), [constant/path.go](https://raw.githubusercontent.com/MetaCubeX/mihomo/v1.19.31/constant/path.go). Fixture green status does not prove real systemd/Docker/Mihomo behavior.
