"""Setup health, read from ~/.agents/bin/check-setup.sh.

`check-setup.sh --json` already answers "is this machine's agent setup
consistent, and is all of it in the repo". This module runs it and hands the
answer to the snapshot. It deliberately does no checking of its own: duplicating
the checks here would mean the HUD and the terminal could disagree about what
healthy means, and the HUD is the one nobody re-derives.

Everything here fails closed. The check exiting non-zero is *success* — that is
how it reports problems — but anything that means "we could not ask" (no script,
an old script that predates `--json`, a crash, a hang, output that is not JSON)
produces no block at all, so the card can say "setup unknown" rather than show a
green panel that is really an unanswered question.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

# The check reads a lot of small files and spawns python a dozen times, but it is
# still well under a second in practice. This is generous enough that a slow
# machine does not lose the block, and short enough that a wedged check cannot
# hold a poll thread forever.
CHECK_TIMEOUT_SECONDS = 30.0

# Exit 2 is the script's own "I could not run", as opposed to 1, which means it
# ran and found problems.
_EXIT_COULD_NOT_RUN = 2


def check_setup_path(agents_dir: Path | None = None) -> Path:
    """Where the gate lives. AGENTS_DIR overrides it, exactly as the script's own
    tests do, so this can be pointed at a throwaway copy."""
    root = agents_dir or Path(os.environ.get("AGENTS_DIR") or Path.home() / ".agents")
    return Path(root) / "bin" / "check-setup.sh"


def collect_setup(agents_dir: Path | None = None) -> dict | None:
    """The setup block, or None when the question could not be asked.

    None is not "the setup is fine". Callers must render it as unknown, because
    a green panel that is really "we could not ask" is worse than no panel.
    """
    script = check_setup_path(agents_dir)
    if not script.is_file():
        return None
    try:
        out = subprocess.run(
            ["bash", str(script), "--json"],
            capture_output=True,
            text=True,
            timeout=CHECK_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    # A non-zero exit is how the check reports problems, so it is not a failure
    # here — except for the code it uses to say it could not run at all, which
    # is also what an older script does when handed a flag it does not know.
    if out.returncode == _EXIT_COULD_NOT_RUN:
        return None
    try:
        block = json.loads(out.stdout)
    except ValueError:
        # An older check-setup.sh ignores the flag and prints its human report,
        # which is not JSON. Omit the block rather than crash the snapshot.
        return None
    return block if _is_wellformed(block) else None


def _is_wellformed(block) -> bool:
    """The block has to be the contract, not merely valid JSON. A malformed one
    reaching the app would render as a confident panel built from nothing."""
    if not isinstance(block, dict):
        return False
    if not isinstance(block.get("problems"), int):
        return False
    sections = block.get("sections")
    if not isinstance(sections, list):
        return False
    return all(
        isinstance(s, dict)
        and isinstance(s.get("title"), str)
        and isinstance(s.get("status"), str)
        and isinstance(s.get("results"), list)
        for s in sections
    )
