#!/usr/bin/env python3
"""Refuse to let a credential reach a remote. Ever, private repo or not.

Operator's rule, 2026-09-28: NO CREDS IN REMOTES EVER. This is the mechanism for it, and
it lives in git rather than in the agent's hooks on purpose — a rule enforced only in
main.py binds psykes and nobody else, while this one binds every commit from this working
tree, whether it came from psykes, from a Claude Code session, or from a human at a
terminal.

Usage:
    scan-secrets.py --staged        what `git commit` is about to record
    scan-secrets.py --range A..B    what `git push` is about to send
    scan-secrets.py FILE...         explicit paths

Exit 0 clean, 1 on a finding. Prints file, line and what matched — never the value.
"""
from __future__ import annotations

import re
import subprocess
import sys

# Paths that must never be committed at all, whatever their contents look like.
FORBIDDEN_PATHS = (
    ".config/psykes",
    ".credentials.json",
    ".config/google-chrome",
    ".config/chromium",
    ".psykes/browser-profile",
    "/.env",
)

# Shapes of real credentials. Each needs a value that actually looks like one — matching a
# bare key name would flag every mention in STATE.md and HANDOFF.md, and a scanner that
# cries wolf is one people start skipping with --no-verify.
PATTERNS: tuple[tuple[str, str], ...] = (
    ("anthropic key",       r"sk-ant-[A-Za-z0-9_\-]{24,}"),
    ("github token",        r"\b(gho|ghp|ghs|ghu|ghr)_[A-Za-z0-9]{30,}\b"),
    ("github fine-grained", r"\bgithub_pat_[A-Za-z0-9_]{50,}\b"),
    ("google api key",      r"\bAIza[A-Za-z0-9_\-]{30,}\b"),
    ("slack token",         r"\bxox[baprs]-[A-Za-z0-9\-]{10,}\b"),
    ("telegram bot token",  r"\b\d{8,11}:AA[A-Za-z0-9_\-]{32,}\b"),
    ("openai key",          r"\bsk-[A-Za-z0-9]{32,}\b"),
    ("aws access key",      r"\b(AKIA|ASIA)[A-Z0-9]{16}\b"),
    ("private key block",   r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    ("oauth refresh token", r'"refreshToken"\s*:\s*"[^"]{20,}"'),
    # KEY=<real value>. The value must be long and secret-shaped; KEY=<set>, KEY=,
    # KEY="", KEY=${VAR} and prose all fall through, which is what keeps the docs clean.
    ("assigned secret",
     r"\b(?:[A-Z][A-Z0-9_]*_)?(?:TOKEN|SECRET|PASSWORD|PASSWD|APIKEY|API_KEY|CREDENTIAL)"
     r"\s*=\s*[\"']?(?!\$|<|\{|\s|$)[A-Za-z0-9_\-\.]{24,}[\"']?"),
)
COMPILED = [(name, re.compile(rx)) for name, rx in PATTERNS]

# An explicit, reviewed way through — for a test fixture that must contain a fake secret.
ALLOW_MARKER = "scan-secrets: allow"


def git(*args: str) -> str:
    return subprocess.run(["git", *args], capture_output=True, text=True).stdout


def scan_blob(path: str, text: str) -> list[str]:
    hits = []
    for n, line in enumerate(text.splitlines(), 1):
        if ALLOW_MARKER in line:
            continue
        for name, rx in COMPILED:
            if rx.search(line):
                hits.append(f"  {path}:{n}  {name}")
                break
    return hits


def main() -> int:
    argv = sys.argv[1:]
    findings: list[str] = []
    paths: list[str] = []

    if argv and argv[0] == "--staged":
        paths = [p for p in git("diff", "--cached", "--name-only",
                                "--diff-filter=ACMR").splitlines() if p]
        read = lambda p: git("show", f":{p}")            # noqa: E731
    elif argv and argv[0] == "--range":
        rng = argv[1]
        paths = [p for p in git("diff", "--name-only", "--diff-filter=ACMR",
                                rng).splitlines() if p]
        read = lambda p: git("show", f"{rng.split('..')[-1]}:{p}")   # noqa: E731
    else:
        paths = argv
        def read(p: str) -> str:
            try:
                with open(p, encoding="utf-8", errors="replace") as fh:
                    return fh.read()
            except OSError:
                return ""

    for path in paths:
        low = path.lower()
        if any(f.strip("/") in low for f in FORBIDDEN_PATHS):
            findings.append(f"  {path}  forbidden path — this file holds credentials")
            continue
        findings.extend(scan_blob(path, read(path)))

    if findings:
        print("REFUSED: credential material in what you are about to publish.\n",
              file=sys.stderr)
        for f in findings:
            print(f, file=sys.stderr)
        print(f"\n{len(findings)} finding(s) across {len(paths)} file(s).", file=sys.stderr)
        print("\nNo credential reaches a remote, private or not. Remove it, rotate it if it\n"
              "was ever real, and commit again. A line that must contain a fake secret can\n"
              f"carry the marker: {ALLOW_MARKER}", file=sys.stderr)
        return 1

    print(f"scan-secrets: clean ({len(paths)} file(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
