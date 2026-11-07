#!/usr/bin/env python3
"""Static, read-only contract check for bounded agent startup instructions."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
GUIDES = ["docs/agent-guidance/01-owner-policy-and-workflow.md","docs/agent-guidance/02-repository-and-install-lifecycle.md","docs/agent-guidance/03-routing-and-live-safety.md","docs/agent-guidance/04-vps-tools-and-historical-cases.md"]
HEADINGS = ["## Owner-wide design gate — SIMPLICITY-FIRST (2026-10-24)","## Purpose","## Repository structure","## Stack and available checks","## What install.sh does on the target server (in order)","## Core logic (change only with understanding and an owner decision)","## Dangerous areas (can cut off SSH or break the server)","## VPS helper tools and PATH","## Agent working rules","## Known inconsistencies (do not \"fix\" silently)","## Technical debt"]
REQUIRED = ["main","stable","owner GO","auto-route: false","AMG_FAILSECURE","unreachable default metric 42760","table 100","SSH","0x88","priority","fail closed","No DIRECT fallback","checksum","atomic","RemainAfterExit","watchdog","gvisor","rp_filter=0","Draft PR","NOT TESTED"]

def main():
    text = (ROOT / "AGENTS.md").read_text(encoding="utf-8")
    size = len(text.encode("utf-8"))
    assert size <= 12_288, f"root AGENTS.md is {size} bytes, exceeds 12 KiB"
    for term in REQUIRED:
        assert term.casefold() in text.casefold(), f"missing root safety guard: {term}"
    corpus = ""
    for guide in GUIDES:
        assert f"]({guide})" in text, f"guide not linked: {guide}"
        content = (ROOT / guide).read_text(encoding="utf-8")
        assert "Relocated source guidance" in content
        corpus += content + "\n"
    for heading in HEADINGS:
        assert heading in corpus, f"original AGENTS.md section missing: {heading}"
    for doc in ["AGENTS.md", *GUIDES]:
        for match in re.findall(r"(?<!!)\[[^\]]+\]\(([^)]+)\)", (ROOT / doc).read_text(encoding="utf-8")):
            target = match.split("#", 1)[0]
            if not target or re.match(r"^(?:https?:|mailto:|/)", target, re.I):
                continue
            assert ((ROOT / doc).parent / target).is_file(), f"broken Markdown link: {doc} -> {match}"
    print(f"Agent context contract: PASS ({size} bytes, {len(GUIDES)} guides, {len(HEADINGS)} headings)")

if __name__ == "__main__":
    main()
