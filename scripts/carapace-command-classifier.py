#!/usr/bin/env python3
"""Proof-of-concept CLI to classify shell lines using carapace.

It does not execute candidate commands. It parses each line and checks whether
carapace has a completer (or the first token exists on PATH / as a shell builtin).

Sandbox (default each run: /tmp/test-<8-char-hex>):
  - Carapace cache/config (XDG_*) is written only under that directory.
  - With nono, `nono run --allow <sandbox> -- …` grants filesystem access to that path.
  - The `nono` and `carapace` binaries themselves still load from your PATH (not under /tmp);
    this script never runs your sample lines as a shell command.

If `carapace` is not on PATH, set `CARAPACE` or `CARAPACE_BIN` to the binary, pass `--carapace`,
or install e.g. `brew install carapace-bin` (often `/opt/homebrew/bin/carapace`).

Use --sanity for a one-shot smoke test: nono + carapace (version + echo completer)
and nono + /bin/echo (safe subprocess, not your shell history lines).

Lines are organized into four groups for the default sample:
  simple      — single command name only (e.g. ls)
  with_args   — command + arguments (e.g. ls -la)
  not_cmd     — short words that are not shell commands (natural language / noise)
  not_macos   — real Linux/common-Unix style invocations unlikely to work on macOS
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Set, Tuple

NONO_BIN = "nono"

# Tried after `shutil.which("carapace")` when resolving the binary.
_CARAPACE_FALLBACK_PATHS: Tuple[Path, ...] = (
    Path("/opt/homebrew/bin/carapace"),
    Path("/usr/local/bin/carapace"),
)


def default_sandbox_path() -> Path:
    """Fresh directory under /tmp for each run: /tmp/test-<8 hex chars>."""

    return (Path("/tmp") / f"test-{uuid.uuid4().hex[:8]}").resolve()


def resolve_sandbox(arg: Optional[Path]) -> Path:
    if arg is not None:
        return arg.expanduser().resolve()
    return default_sandbox_path()


def _is_regular_file(path: Path) -> bool:
    """True if path exists and is a regular file (or symlink to one).

    We intentionally do not require os.access(X_OK): on some macOS setups the
    kernel still executes the binary while access() reports false.
    """

    try:
        return path.is_file()
    except OSError:
        return False


def resolve_carapace_binary(explicit: Optional[Path]) -> Tuple[Optional[str], str]:
    """Return (absolute path to carapace, or None) and a short failure reason."""

    def try_path(p: Path, label: str) -> tuple[Optional[str], str]:
        try:
            p = p.expanduser().resolve(strict=False)
        except OSError as exc:
            return None, f"{label}: invalid path ({exc})"
        if not p.exists():
            return None, f"{label}: no such file or directory"
        if not _is_regular_file(p):
            return None, f"{label}: not a regular file (got directory or broken symlink?)"
        return str(p), ""

    if explicit is not None:
        return try_path(explicit, f"--carapace {explicit}")

    for key in ("CARAPACE", "CARAPACE_BIN"):
        raw = os.environ.get(key)
        if raw:
            raw = raw.strip()
            if not raw:
                continue
            result, err = try_path(Path(raw), f"{key}={raw!r}")
            if result is not None:
                return result, ""
            # User explicitly set the variable; report failure instead of ignoring.
            return None, err

    which = shutil.which("carapace")
    if which:
        return which, ""

    for p in _CARAPACE_FALLBACK_PATHS:
        result, err = try_path(p, str(p))
        if result is not None:
            return result, ""

    return None, "not found on PATH and no file at common Homebrew locations"

SAFE_BUILTIN_COMMANDS: Set[str] = {
    "alias",
    "bg",
    "cd",
    "command",
    "false",
    "fg",
    "hash",
    "history",
    "jobs",
    "true",
    "type",
    "umask",
    "unfunction",
    "wait",
}

# ---------------------------------------------------------------------------
# Four default groups (~50 lines total)
# ---------------------------------------------------------------------------

GROUP_SIMPLE: List[str] = [
    "ls",
    "pwd",
    "echo",
    "cat",
    "grep",
    "sed",
    "awk",
    "sort",
    "uniq",
    "head",
    "tail",
    "wc",
    "curl",
]

GROUP_WITH_ARGS: List[str] = [
    "ls -la",
    "ls -la /tmp",
    "echo hello world",
    "grep -r foo .",
    "find . -name '*.py'",
    "head -n 5 /etc/hosts",
    "tail -n 3 /etc/hosts",
    "wc -l",
    "sort -u",
    "cut -d: -f1 /etc/passwd",
    "ssh -V",
    "git --version",
    "python3 --version",
]

GROUP_NOT_COMMANDS: List[str] = [
    "lol",
    "sat",
    "brb",
    "omg",
    "wtf",
    "foo",
    "bar",
    "baz",
    "qux",
    "hey",
    "yep",
    "nah",
]

# Valid-looking commands that typically do not exist or are wrong on stock macOS.
GROUP_NOT_MACOS: List[str] = [
    "apt-get update",
    "apt install vim",
    "yum install git",
    "dnf search curl",
    "systemctl status sshd",
    "dpkg -l",
    "rpm -qa",
    "iptables -L",
    "ip link show",
    "adduser nobody",
    "usermod -aG wheel alice",
    "snap install hello",
]


def default_grouped_lines() -> List[Tuple[str, str]]:
    """Return (line, group_id) for the full default sample."""
    out: List[Tuple[str, str]] = []
    for line in GROUP_SIMPLE:
        out.append((line, "simple"))
    for line in GROUP_WITH_ARGS:
        out.append((line, "with_args"))
    for line in GROUP_NOT_COMMANDS:
        out.append((line, "not_cmd"))
    for line in GROUP_NOT_MACOS:
        out.append((line, "not_macos"))
    return out


def first_token(line: str) -> str | None:
    line = line.strip()
    if not line:
        return None
    try:
        parts = shlex.split(line, posix=True)
    except ValueError:
        # Unclosed quote etc. — treat whole first word-ish token
        return line.split()[0] if line.split() else None
    return parts[0] if parts else None


def is_available(program: str) -> bool:
    return program in SAFE_BUILTIN_COMMANDS or shutil.which(program) is not None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Classify shell lines via carapace completion metadata (PoC)."
    )
    parser.add_argument(
        "--commands",
        nargs="*",
        default=[],
        help="Lines to classify. If omitted, uses the built-in four-group sample.",
    )
    parser.add_argument(
        "--carapace",
        type=Path,
        default=None,
        metavar="EXE",
        help=(
            "Path to the carapace binary. If omitted, uses $CARAPACE, $CARAPACE_BIN, "
            "PATH, then /opt/homebrew/bin/carapace and /usr/local/bin/carapace."
        ),
    )
    parser.add_argument(
        "--sandbox",
        type=Path,
        default=None,
        metavar="DIR",
        help=(
            "Directory for nono --allow and carapace XDG state. "
            "Default: /tmp/test-<random 8 hex> (new directory each run)."
        ),
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit machine-readable JSON output.",
    )
    parser.add_argument(
        "--no-nono",
        action="store_true",
        help="Run carapace directly instead of via `nono run`.",
    )
    parser.add_argument(
        "--sanity",
        action="store_true",
        help=(
            "Smoke test only: run carapace -v and carapace echo under nono, "
            "then /bin/echo under nono (exits 0 if all succeed)."
        ),
    )
    return parser.parse_args()


def build_samples(explicit: Sequence[str]) -> List[Tuple[str, str]]:
    if explicit:
        return [(line, "custom") for line in dict.fromkeys(explicit)]
    return default_grouped_lines()


def ensure_sandbox(path: Path) -> None:
    """Create a sandbox directory with a read-only root path."""

    path.mkdir(parents=True, exist_ok=True)
    cache_dir = path / "carapace-cache"
    config_dir = path / "carapace-config"
    cache_dir.mkdir(parents=True, exist_ok=True)
    config_dir.mkdir(parents=True, exist_ok=True)
    cache_dir.chmod(0o777)
    config_dir.chmod(0o777)
    path.chmod(0o555)


def run_carapace(
    carapace_exe: str,
    args: Sequence[str],
    sandbox: Path,
    *,
    use_nono: bool,
    env: Dict[str, str],
    timeout: int = 12,
) -> subprocess.CompletedProcess:
    command: List[str] = [carapace_exe, *args]
    if use_nono:
        command = [NONO_BIN, "run", "--silent", "--allow-cwd", "--allow", str(sandbox), "--", *command]

    return subprocess.run(
        command,
        capture_output=True,
        text=True,
        env=env,
        timeout=timeout,
        stdin=subprocess.DEVNULL,
    )


def run_under_nono(
    argv: Sequence[str],
    sandbox: Path,
    *,
    use_nono: bool,
    env: Dict[str, str],
    timeout: int = 12,
) -> subprocess.CompletedProcess:
    """Run an arbitrary argv[0] (e.g. /bin/echo) under nono when enabled."""

    command: List[str] = list(argv)
    if use_nono:
        command = [NONO_BIN, "run", "--silent", "--allow-cwd", "--allow", str(sandbox), "--", *command]
    return subprocess.run(
        command,
        capture_output=True,
        text=True,
        env=env,
        timeout=timeout,
        stdin=subprocess.DEVNULL,
    )


def run_sanity(
    carapace_exe: str,
    sandbox: Path,
    use_nono: bool,
    env: Dict[str, str],
) -> int:
    """Minimal checks: nono+carapace and nono+echo binary."""

    label = "nono+carapace" if use_nono else "carapace"
    checks: List[Tuple[str, subprocess.CompletedProcess]] = []

    r_ver = run_carapace(carapace_exe, ["-v"], sandbox, use_nono=use_nono, env=env)
    checks.append((f"{label} -v", r_ver))

    r_echo_comp = run_carapace(carapace_exe, ["echo"], sandbox, use_nono=use_nono, env=env)
    checks.append((f"{label} echo (completer)", r_echo_comp))

    r_echo_bin = run_under_nono(
        ["/bin/echo", "sanity-ok"],
        sandbox,
        use_nono=use_nono,
        env=env,
    )
    checks.append(
        (
            "nono+/bin/echo" if use_nono else "/bin/echo",
            r_echo_bin,
        )
    )

    ok = True
    for name, proc in checks:
        status = "OK" if proc.returncode == 0 else "FAIL"
        if proc.returncode != 0:
            ok = False
        err = (proc.stderr or "").strip()[:200]
        out = (proc.stdout or "").strip()[:120]
        print(f"[{status}] {name} (exit {proc.returncode})")
        if out:
            print(f"       stdout: {out!r}")
        if err:
            print(f"       stderr: {err!r}")

    if ok:
        print("\nSanity: all checks passed.")
        return 0
    print("\nSanity: one or more checks failed.", file=sys.stderr)
    return 1


def get_completer_set(
    carapace_exe: str,
    sandbox: Path,
    use_nono: bool,
    env: Dict[str, str],
) -> Set[str]:
    try:
        result = run_carapace(
            carapace_exe,
            ["--list", "--names"],
            sandbox,
            use_nono=use_nono,
            env=env,
        )
    except FileNotFoundError as exc:
        if use_nono and exc.filename == NONO_BIN:
            print(
                "nono is not available; falling back to direct carapace invocation.",
                file=sys.stderr,
            )
            return get_completer_set(carapace_exe, sandbox, False, env)
        raise

    if result.returncode != 0:
        print(
            "Could not fetch carapace completer list; falling back to invoke checks.",
            file=sys.stderr,
        )
        return set()

    return {
        line.strip()
        for line in result.stdout.splitlines()
        if line.strip() and not line.strip().startswith("#")
    }


def classify_line(
    carapace_exe: str,
    line: str,
    completers: Set[str],
    sandbox: Path,
    use_nono: bool,
    env: Dict[str, str],
) -> Dict[str, object]:
    start_time = time.perf_counter()
    prog = first_token(line)
    if prog is None:
        return {
            "line": line,
            "first": "",
            "valid": False,
            "method": "empty",
            "raw": "empty line",
            "latency_ms": (time.perf_counter() - start_time) * 1000,
        }

    if prog in completers:
        return {
            "line": line,
            "first": prog,
            "valid": True,
            "method": "list",
            "raw": "",
            "latency_ms": (time.perf_counter() - start_time) * 1000,
        }

    if is_available(prog):
        return {
            "line": line,
            "first": prog,
            "valid": True,
            "method": "path",
            "raw": "command available on PATH or built-in",
            "latency_ms": (time.perf_counter() - start_time) * 1000,
        }

    try:
        result = run_carapace(carapace_exe, [prog], sandbox, use_nono=use_nono, env=env)
    except FileNotFoundError:
        raise

    valid = result.returncode == 0 and bool(result.stdout.strip())
    return {
        "line": line,
        "first": prog,
        "valid": valid,
        "method": "invoke",
        "raw": result.stderr.strip()[:160],
        "latency_ms": (time.perf_counter() - start_time) * 1000,
    }


def print_table(results: Sequence[Dict[str, object]]) -> None:
    print(" # | group      | line (first token used for carapace)              | valid | method | latency")
    print("-" * 105)
    for idx, row in enumerate(results, start=1):
        status = "yes" if row["valid"] else "no"
        note = row.get("raw") or "-"
        line = str(row["line"])
        group = str(row.get("group", "-"))
        latency = f"{row.get('latency_ms', 0):.1f}ms"
        display = line if len(line) <= 45 else line[:42] + "..."
        print(
            f"{idx:>2} | {group:<10} | {display:<45} | {status:<5} | {row['method']:<6} | {latency}"
        )
        if note and note != "-":
            print(f"    |            | note: {note}")

    print("\n" + "=" * 60)
    print(" CONFUSION MATRIX & LATENCY (Group vs Validity)")
    print("=" * 60)
    
    # Tally up counts and latency
    counts: Dict[str, Dict[bool, int]] = {}
    latency_sums: Dict[str, Dict[bool, float]] = {}
    
    for row in results:
        group = str(row.get("group", "-"))
        valid = bool(row.get("valid"))
        lat = float(row.get("latency_ms", 0.0))
        
        if group not in counts:
            counts[group] = {True: 0, False: 0}
            latency_sums[group] = {True: 0.0, False: 0.0}
            
        counts[group][valid] += 1
        latency_sums[group][valid] += lat
        
    print(f" {'Group':<15} | {'Valid (yes)':<12} | {'Invalid (no)':<12} | {'Avg Latency'}")
    print("-" * 65)
    for group in sorted(counts.keys()):
        yes_c = counts[group][True]
        no_c = counts[group][False]
        
        total_c = yes_c + no_c
        total_lat = latency_sums[group][True] + latency_sums[group][False]
        avg_lat = total_lat / total_c if total_c > 0 else 0.0
        
        print(f" {group:<15} | {yes_c:<12} | {no_c:<12} | {avg_lat:.1f}ms")
    print("=" * 60)


def main() -> int:
    args = parse_args()

    carapace_exe, carapace_err = resolve_carapace_binary(args.carapace)
    if carapace_exe is None:
        print(
            "Could not find a carapace binary.",
            file=sys.stderr,
        )
        if carapace_err:
            print(f"  Reason: {carapace_err}", file=sys.stderr)
        print(
            "  Add it to PATH, or: export CARAPACE=/path/to/carapace",
            file=sys.stderr,
        )
        print(
            "  Or: python3 scripts/carapace-command-classifier.py --carapace /opt/homebrew/bin/carapace",
            file=sys.stderr,
        )
        print(
            "  Install (Homebrew): brew install carapace",
            file=sys.stderr,
        )
        return 2

    sandbox = resolve_sandbox(args.sandbox)
    ensure_sandbox(sandbox)
    print(f"Using carapace: {carapace_exe}", file=sys.stderr)
    print(f"Sandbox (nono --allow + carapace XDG): {sandbox}", file=sys.stderr)

    use_nono = not args.no_nono
    if use_nono and shutil.which(NONO_BIN) is None:
        print(
            "nono is not available; running carapace directly.",
            file=sys.stderr,
        )
        use_nono = False

    env = os.environ.copy()
    env["XDG_CACHE_HOME"] = str(sandbox / "carapace-cache")
    env["XDG_CONFIG_HOME"] = str(sandbox / "carapace-config")
    env["CARAPACE_LENIENT"] = "1"

    if args.sanity:
        return run_sanity(carapace_exe, sandbox, use_nono=use_nono, env=env)

    samples = build_samples(args.commands)

    completers = get_completer_set(carapace_exe, sandbox, use_nono=use_nono, env=env)

    results: List[Dict[str, object]] = []
    for line, group in samples:
        row = classify_line(
            carapace_exe,
            line,
            completers,
            sandbox,
            use_nono=use_nono,
            env=env,
        )
        row["group"] = group
        results.append(row)

    valid_count = sum(1 for row in results if row["valid"])

    print_table(results)
    print(f"\nValid (carapace/PATH for first token): {valid_count}/{len(results)}")
    print(
        "Executed via nono:",
        "yes" if use_nono else "no",
        f"| carapace={carapace_exe}",
        f"| sandbox={sandbox}",
    )

    if args.json:
        print(
            json.dumps(
                {
                    "lines": results,
                    "summary": {
                        "total": len(results),
                        "valid": valid_count,
                        "sandbox": str(sandbox),
                        "carapace": carapace_exe,
                        "used_nono": use_nono,
                    },
                },
                indent=2,
            )
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
