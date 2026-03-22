#!/usr/bin/env python3
"""
Regression test: `phatmux claude-teams` reuses an existing tmux shim.
"""

from __future__ import annotations

import os
import stat
import subprocess
import tempfile
from pathlib import Path

from claude_teams_test_utils import resolve_phatmux_cli


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def main() -> int:
    try:
        cli_path = resolve_phatmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    with tempfile.TemporaryDirectory(prefix="phatmux-claude-teams-shim-") as td:
        tmp = Path(td)
        home = tmp / "home"
        real_bin = tmp / "real-bin"
        home.mkdir(parents=True, exist_ok=True)
        real_bin.mkdir(parents=True, exist_ok=True)

        shim_dir = home / ".phatmux" / "claude-teams-bin"
        shim_dir.mkdir(parents=True, exist_ok=True)
        shim_path = shim_dir / "tmux"
        shim_path.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "exec \"${PHATMUX_CLAUDE_TEAMS_CLI_BIN:-phatmux}\" __tmux-compat \"$@\"\n",
            encoding="utf-8",
        )
        shim_path.chmod(0o555)
        shim_dir.chmod(0o555)

        make_executable(
            real_bin / "claude",
            """#!/usr/bin/env bash
set -euo pipefail
printf 'shim=%s\\n' "$(command -v tmux)"
""",
        )

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["PATH"] = f"{real_bin}:/usr/bin:/bin"

        proc = subprocess.run(
            [cli_path, "claude-teams", "--version"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=30,
        )

        shim_dir.chmod(0o755)
        shim_path.chmod(0o755)

        if proc.returncode != 0:
            print("FAIL: `phatmux claude-teams --version` failed with an existing shim")
            print(f"exit={proc.returncode}")
            print(f"stdout={proc.stdout.strip()}")
            print(f"stderr={proc.stderr.strip()}")
            return 1

        expected = str(shim_path)
        actual = proc.stdout.strip()
        if actual != f"shim={expected}":
            print(f"FAIL: expected existing shim path {expected!r}, got {actual!r}")
            return 1

    print("PASS: phatmux claude-teams reuses an existing tmux shim")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
