#!/usr/bin/env python3
"""
Regression tests for Resources/bin/claude wrapper hook injection.
"""

from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_WRAPPER = ROOT / "Resources" / "bin" / "claude"


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def read_lines(path: Path) -> list[str]:
    if not path.exists():
        return []
    return [line.rstrip("\n") for line in path.read_text(encoding="utf-8").splitlines()]


def parse_settings_arg(argv: list[str]) -> dict:
    if "--settings" not in argv:
        return {}
    index = argv.index("--settings")
    if index + 1 >= len(argv):
        return {}
    return json.loads(argv[index + 1])


def run_wrapper(*, socket_state: str, argv: list[str]) -> tuple[int, list[str], list[str], str, str]:
    with tempfile.TemporaryDirectory(prefix="phatmux-claude-wrapper-test-") as td:
        tmp = Path(td)
        wrapper_dir = tmp / "wrapper-bin"
        real_dir = tmp / "real-bin"
        wrapper_dir.mkdir(parents=True, exist_ok=True)
        real_dir.mkdir(parents=True, exist_ok=True)

        wrapper = wrapper_dir / "claude"
        shutil.copy2(SOURCE_WRAPPER, wrapper)
        wrapper.chmod(0o755)

        real_args_log = tmp / "real-args.log"
        real_claudecode_log = tmp / "real-claudecode.log"
        phatmux_log = tmp / "phatmux.log"
        socket_path = str(tmp / "phatmux.sock")

        make_executable(
            real_dir / "claude",
            """#!/usr/bin/env bash
set -euo pipefail
: > "$FAKE_REAL_ARGS_LOG"
printf '%s\\n' "${CLAUDECODE-__UNSET__}" > "$FAKE_REAL_CLAUDECODE_LOG"
for arg in "$@"; do
  printf '%s\\n' "$arg" >> "$FAKE_REAL_ARGS_LOG"
done
""",
        )

        make_executable(
            wrapper_dir / "phatmux",
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s timeout=%s\\n' "$*" "${PHATMUXTERM_CLI_RESPONSE_TIMEOUT_SEC-__UNSET__}" >> "$FAKE_PHATMUX_LOG"
if [[ "${1:-}" == "--socket" ]]; then
  shift 2
fi
if [[ "${1:-}" == "ping" ]]; then
  if [[ "${FAKE_PHATMUX_PING_OK:-0}" == "1" ]]; then
    exit 0
  fi
  exit 1
fi
exit 0
""",
        )

        test_socket: socket.socket | None = None
        if socket_state in {"live", "stale"}:
            test_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            test_socket.bind(socket_path)

        env = os.environ.copy()
        env["PATH"] = f"{wrapper_dir}:{real_dir}:/usr/bin:/bin"
        env["PHATMUX_SURFACE_ID"] = "surface:test"
        env["PHATMUX_SOCKET_PATH"] = socket_path
        env["FAKE_REAL_ARGS_LOG"] = str(real_args_log)
        env["FAKE_REAL_CLAUDECODE_LOG"] = str(real_claudecode_log)
        env["FAKE_PHATMUX_LOG"] = str(phatmux_log)
        env["FAKE_PHATMUX_PING_OK"] = "1" if socket_state == "live" else "0"
        env["CLAUDECODE"] = "nested-session-sentinel"

        try:
            proc = subprocess.run(
                ["claude", *argv],
                cwd=tmp,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
        finally:
            if test_socket is not None:
                test_socket.close()

        claudecode_lines = read_lines(real_claudecode_log)
        claudecode_value = claudecode_lines[0] if claudecode_lines else ""
        return proc.returncode, read_lines(real_args_log), read_lines(phatmux_log), proc.stderr.strip(), claudecode_value


def expect(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def test_live_socket_injects_supported_hooks(failures: list[str]) -> None:
    code, real_argv, phatmux_log, stderr, claudecode = run_wrapper(socket_state="live", argv=["hello"])
    expect(code == 0, f"live socket: wrapper exited {code}: {stderr}", failures)
    expect("--settings" in real_argv, f"live socket: missing --settings in args: {real_argv}", failures)
    expect("--session-id" in real_argv, f"live socket: missing --session-id in args: {real_argv}", failures)
    expect(real_argv[-1] == "hello", f"live socket: expected original arg to pass through, got {real_argv}", failures)
    expect(any(" ping" in line for line in phatmux_log), f"live socket: expected phatmux ping, got {phatmux_log}", failures)
    expect(
        any("timeout=0.75" in line for line in phatmux_log),
        f"live socket: expected bounded ping timeout, got {phatmux_log}",
        failures,
    )
    expect(claudecode == "__UNSET__", f"live socket: expected CLAUDECODE unset, got {claudecode!r}", failures)

    settings = parse_settings_arg(real_argv)
    hooks = settings.get("hooks", {})
    expected_hooks = {"SessionStart", "Stop", "SessionEnd", "Notification", "UserPromptSubmit", "PreToolUse"}
    expect(set(hooks.keys()) == expected_hooks, f"unexpected hook keys: {hooks.keys()}, expected {expected_hooks}", failures)
    # PreToolUse should be async to avoid blocking tool execution
    pre_tool_use_hooks = hooks.get("PreToolUse", [{}])[0].get("hooks", [{}])
    expect(
        any(h.get("async") is True for h in pre_tool_use_hooks),
        f"PreToolUse hook should have async:true, got {pre_tool_use_hooks}",
        failures,
    )
    # SessionEnd should have a short timeout (session is exiting)
    session_end_hooks = hooks.get("SessionEnd", [{}])[0].get("hooks", [{}])
    expect(
        any(h.get("timeout", 999) <= 2 for h in session_end_hooks),
        f"SessionEnd hook should have short timeout, got {session_end_hooks}",
        failures,
    )


def test_missing_socket_skips_hook_injection(failures: list[str]) -> None:
    code, real_argv, phatmux_log, stderr, claudecode = run_wrapper(socket_state="missing", argv=["hello"])
    expect(code == 0, f"missing socket: wrapper exited {code}: {stderr}", failures)
    expect(real_argv == ["hello"], f"missing socket: expected passthrough args, got {real_argv}", failures)
    expect(phatmux_log == [], f"missing socket: expected no phatmux calls, got {phatmux_log}", failures)
    expect(claudecode == "__UNSET__", f"missing socket: expected CLAUDECODE unset, got {claudecode!r}", failures)


def test_stale_socket_skips_hook_injection(failures: list[str]) -> None:
    code, real_argv, phatmux_log, stderr, claudecode = run_wrapper(socket_state="stale", argv=["hello"])
    expect(code == 0, f"stale socket: wrapper exited {code}: {stderr}", failures)
    expect(real_argv == ["hello"], f"stale socket: expected passthrough args, got {real_argv}", failures)
    expect(any(" ping" in line for line in phatmux_log), f"stale socket: expected phatmux ping probe, got {phatmux_log}", failures)
    expect(
        any("timeout=0.75" in line for line in phatmux_log),
        f"stale socket: expected bounded ping timeout, got {phatmux_log}",
        failures,
    )
    expect(claudecode == "__UNSET__", f"stale socket: expected CLAUDECODE unset, got {claudecode!r}", failures)


def main() -> int:
    failures: list[str] = []
    test_live_socket_injects_supported_hooks(failures)
    test_missing_socket_skips_hook_injection(failures)
    test_stale_socket_skips_hook_injection(failures)

    if failures:
        print("FAIL: claude wrapper regression checks failed")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: claude wrapper hooks handle missing/stale sockets and inject only supported hooks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
