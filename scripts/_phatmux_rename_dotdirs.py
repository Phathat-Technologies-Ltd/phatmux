#!/usr/bin/env python3
"""Apply phatmux renames under .github, .vscode, .claude, .agents (skipped by main bulk walker)."""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

DOT_PREFIXES = (".github", ".vscode", ".claude", ".agents")

REPLACEMENTS = [
    ("cmuxd-remote", "phatmuxd-remote"),
    ("cmuxd", "phatmuxd"),
    ("com.cmuxterm.app.debug.", "com.phatmux.app.debug."),
    ("com.cmuxterm.app.staging.", "com.phatmux.app.staging."),
    ("com.cmuxterm.app.nightly.", "com.phatmux.app.nightly."),
    ("com.cmuxterm.app.debug", "com.phatmux.app.debug"),
    ("com.cmuxterm.app.staging", "com.phatmux.app.staging"),
    ("com.cmuxterm.app.nightly", "com.phatmux.app.nightly"),
    ("com.cmuxterm.appuitests", "com.phatmux.appuitests"),
    ("com.cmuxterm.apptests", "com.phatmux.apptests"),
    ("com.cmuxterm.app", "com.phatmux.app"),
    ("com.cmuxterm", "com.phatmux"),
    ("ai.manaflow.cmuxterm.plist", "ai.phatmux.plist"),
    ("manaflow-ai/cmux", "amitpaz/phatmux"),
    ("cmuxterm_github", "phatmux_github"),
    ("cmuxterm_download", "phatmux_download"),
    ("cmuxterm", "phatmux"),
    ("cmuxOnly", "phatmuxOnly"),
    ("cmux-only", "phatmux-only"),
    ("cmux_once", "phatmux_once"),
    ("cmuxonly", "phatmuxonly"),
    ("com.cmux.", "com.phatmux."),
    ("cmux DEV", "phatmux DEV"),
    ("cmux STAGING", "phatmux STAGING"),
    ("cmux NIGHTLY", "phatmux NIGHTLY"),
    ("-cmuxUITestLaunchManifest", "-phatmuxUITestLaunchManifest"),
    ("cmuxUITestLaunchManifest", "phatmuxUITestLaunchManifest"),
    ("cmux-debug", "phatmux-debug"),
    ("cmux-last-", "phatmux-last-"),
    ("cmux-cli", "phatmux-cli"),
    ("cmux-unit", "phatmux-unit"),
    ("cmux-ci", "phatmux-ci"),
    ("cmux-macos.dmg", "phatmux-macos.dmg"),
    ("cmux-notary", "phatmux-notary"),
    ("homebrew-cmux", "homebrew-phatmux"),
    ("cmuxterm-hq", "phatmux-hq"),
    ("cmux-loopback", "phatmux-loopback"),
    ("cmux-dev-artifacts", "phatmux-dev-artifacts"),
    ("cmux-smoke", "phatmux-smoke"),
    ("cmux-panel-debug", "phatmux-panel-debug"),
    ("cmux-update", "phatmux-update"),
    ("cmux-focus", "phatmux-focus"),
    ("cmux-browser-screenshots", "phatmux-browser-screenshots"),
    ("cmux-screenshots", "phatmux-screenshots"),
    ("cmux-cjk-font-fallback", "phatmux-cjk-font-fallback"),
    ("cmux-socket", "phatmux-socket"),
    ("cmux-relay-auth", "phatmux-relay-auth"),
    ("cmux-ui-test", "phatmux-ui-test"),
    ("data-cmux-", "data-phatmux-"),
    ("__cmux-", "__phatmux-"),
    ("__cmux", "__phatmux"),
    ("cmuxEvaluate", "phatmuxEvaluate"),
    ("cmux_performKeyEquivalent", "phatmux_performKeyEquivalent"),
    ("cmux_uname", "phatmux_uname"),
    ("CMUX_", "PHATMUX_"),
    ("CMUXCommit", "PHATMUXCommit"),
    ("cmuxTests.xctest", "phatmuxTests.xctest"),
    ("cmuxUITests.xctest", "phatmuxUITests.xctest"),
    ("cmux.app", "phatmux.app"),
    ("cmux.entitlements", "phatmux.entitlements"),
]

CMUX_SKIP = re.compile(
    r"cmux(?!App\b)(?!-Bridging)(?!\.sdef\b)(?!\.swift\b)(?!Tests\b)(?!UITests\b)"
)


def process_file(path: str) -> bool:
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError:
        return False
    if b"\0" in raw[:4096]:
        return False
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return False
    if "cmux" not in text:
        return False
    orig = text
    for old, new in REPLACEMENTS:
        text = text.replace(old, new)
    text = CMUX_SKIP.sub("phatmux", text)
    if text == orig:
        return False
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)
    return True


def main():
    changed = 0
    for dot in DOT_PREFIXES:
        base = os.path.join(ROOT, dot)
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d != ".git"]
            for name in filenames:
                path = os.path.join(dirpath, name)
                if path.endswith((".png", ".ico", ".zip")):
                    continue
                if process_file(path):
                    changed += 1
                    print(path)
    print(f"Modified {changed} files", file=sys.stderr)


if __name__ == "__main__":
    main()
