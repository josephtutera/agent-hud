"""Small helpers shared by the test modules."""

from __future__ import annotations

import json
from pathlib import Path


def _write_jsonl(path: Path, lines: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as fh:
        for line in lines:
            # compact separators, matching what claude/codex actually write
            fh.write(json.dumps(line, separators=(",", ":")) + "\n")
