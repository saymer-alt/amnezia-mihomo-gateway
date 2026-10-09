#!/usr/bin/env python3
"""Owner Experience Gate for AMG's read-only Doctor.

Fixtures redirect every rp_filter/sysctl read into a disposable temp directory.
No install, uninstall, Docker, iptables, systemctl or WAN calls.
"""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def doctor(fixture: Path, *args: str) -> subprocess.CompletedProcess:
    env = dict(os.environ, AMG_DIAGNOSTIC_ROOT=str(fixture), NO_COLOR="1", TERM="dumb")
    return subprocess.run(
        ["bash", str(ROOT / "doctor.sh"), *args],
        env=env, cwd=ROOT, capture_output=True, text=True, timeout=12, check=False,
    )


def snapshot(path: Path) -> dict:
    return {
        str(p.relative_to(path)): p.read_bytes()
        for p in path.rglob("*") if p.is_file()
    }


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="amg-owner-experience-") as d:
        root = Path(d)

        # Unavailable data is explicitly UNKNOWN, never a green success.
        absent = doctor(root)
        assert absent.returncode == 1, (absent.returncode, absent.stdout, absent.stderr)
        assert "[WARN] UNKNOWN: runtime rp_filter directory unavailable" in absent.stdout
        assert "No values or files changed." in absent.stdout
        print("PASS: no runtime evidence -> clear UNKNOWN, not false OK")

        runtime = root / "proc/sys/net/ipv4/conf"
        for iface in ("all", "default", "eth0"):
            p = runtime / iface / "rp_filter"
            p.parent.mkdir(parents=True)
            p.write_text("0\n")
        before = snapshot(root)
        healthy = doctor(root)
        assert healthy.returncode == 0, (healthy.returncode, healthy.stdout)
        assert all(f"[OK] runtime {iface}.rp_filter=0" in healthy.stdout for iface in ("all", "default", "eth0"))
        assert "[WARN]" not in healthy.stdout
        assert snapshot(root) == before, "Doctor mutated fixture on success"
        print("PASS: healthy fixture -> OK and unchanged files")

        (runtime / "all/rp_filter").write_text("1\n")
        override = root / "etc/sysctl.d/70-other.conf"
        override.parent.mkdir(parents=True)
        override.write_text("net.ipv4.conf.default.rp_filter = 2\n")
        before = snapshot(root)
        drift = doctor(root)
        assert drift.returncode == 1, (drift.returncode, drift.stdout)
        assert "runtime all.rp_filter=1 conflicts" in drift.stdout
        assert "may reintroduce drift on reload" in drift.stdout
        assert "never blindly reload" in drift.stdout
        assert snapshot(root) == before, "Doctor mutated fixture on warning"
        print("PASS: conflicting runtime/persistent state -> actionable WARN, no writes")

        invalid = doctor(root, "--fix")
        assert invalid.returncode == 2, (invalid.returncode, invalid.stderr)
        assert "read-only" in invalid.stderr and "Usage:" in invalid.stderr
        assert snapshot(root) == before, "Invalid command must not mutate"
        print("PASS: unsupported repair flag refused before any mutation")

    print("OWNER EXPERIENCE GATE: AMG read-only diagnostic journey PASS")


if __name__ == "__main__":
    main()
