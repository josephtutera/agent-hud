"""Tests for reading setup health out of check-setup.sh.

Everything here is about failing closed. The check exiting non-zero is success —
that is how it reports problems — but every way of not getting an answer has to
produce no block at all, because a green panel that is really "we could not ask"
is worse than no panel.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))

import setup_health
from setup_health import collect_setup

GOOD = {
    "version": 1,
    "generated_at": "2026-08-03T01:23:32+00:00",
    "problems": 1,
    "sections": [
        {"title": "every Claude account behaves the same", "label": "accounts",
         "summary": "model", "status": "problem",
         "results": [{"status": "problem", "message": "differs in: model",
                      "fix": "pick one for both, then", "fix_command": "bin/capture.sh"}]},
    ],
}


def _fake_agents_dir(tmp_path: Path, script: str) -> Path:
    """A throwaway ~/.agents whose check-setup.sh is whatever we say it is."""
    root = tmp_path / "agents"
    (root / "bin").mkdir(parents=True)
    path = root / "bin" / "check-setup.sh"
    path.write_text(script)
    path.chmod(0o755)
    return root


def test_a_healthy_check_is_read_straight_through(tmp_path: Path):
    root = _fake_agents_dir(tmp_path, f"#!/bin/sh\ncat <<'EOF'\n{json.dumps(GOOD)}\nEOF\n")
    assert collect_setup(root) == GOOD


def test_a_non_zero_exit_is_success_not_failure(tmp_path: Path):
    """check-setup exits 1 whenever there are problems. Treating that as a failed
    run would mean the panel goes blank exactly when it has something to say."""
    root = _fake_agents_dir(
        tmp_path, f"#!/bin/sh\ncat <<'EOF'\n{json.dumps(GOOD)}\nEOF\nexit 1\n"
    )
    block = collect_setup(root)
    assert block is not None
    assert block["problems"] == 1


def test_exit_two_means_the_check_could_not_run(tmp_path: Path):
    """Distinct from exit 1. The script uses it for "I could not run", so there
    is nothing to report and nothing to claim."""
    root = _fake_agents_dir(tmp_path, "#!/bin/sh\necho 'unknown option' >&2\nexit 2\n")
    assert collect_setup(root) is None


def test_a_check_that_predates_the_flag_omits_the_block(tmp_path: Path):
    """The cross-repo case: merge order does not guarantee install order, so the
    HUD can meet a check-setup.sh that ignores --json and prints its human report.
    That is not JSON, and must not crash the snapshot or read as an all-clear."""
    root = _fake_agents_dir(tmp_path, "#!/bin/sh\necho '  ok    ~/.claude/CLAUDE.md'\nexit 0\n")
    assert collect_setup(root) is None


def test_a_missing_script_omits_the_block(tmp_path: Path):
    assert collect_setup(tmp_path / "nowhere") is None


def test_a_crashing_script_omits_the_block(tmp_path: Path):
    root = _fake_agents_dir(tmp_path, "#!/bin/sh\nexit 137\n")
    assert collect_setup(root) is None


def test_a_hung_check_gives_up_rather_than_holding_the_poll(tmp_path: Path, monkeypatch):
    monkeypatch.setattr(setup_health, "CHECK_TIMEOUT_SECONDS", 0.2)
    root = _fake_agents_dir(tmp_path, "#!/bin/sh\nsleep 30\n")
    assert collect_setup(root) is None


@pytest.mark.parametrize("payload", [
    '"a string"',
    "[]",
    '{"problems": "two", "sections": []}',      # count is not a number
    '{"problems": 0}',                          # no sections at all
    '{"problems": 0, "sections": [{"title": "x"}]}',  # a section missing its results
])
def test_json_that_is_not_the_contract_is_refused(tmp_path: Path, payload: str):
    """Valid JSON is not the same as the contract. A malformed block reaching the
    app would render as a confident panel built out of nothing."""
    root = _fake_agents_dir(tmp_path, f"#!/bin/sh\ncat <<'EOF'\n{payload}\nEOF\n")
    assert collect_setup(root) is None


def test_a_clean_machine_reports_zero_problems(tmp_path: Path):
    clean = {"version": 1, "generated_at": "x", "problems": 0,
             "sections": [{"title": "t", "label": "l", "summary": "8 links",
                           "status": "ok", "results": []}]}
    root = _fake_agents_dir(tmp_path, f"#!/bin/sh\ncat <<'EOF'\n{json.dumps(clean)}\nEOF\n")
    assert collect_setup(root)["problems"] == 0


def test_agents_dir_env_var_points_it_somewhere_else(tmp_path: Path, monkeypatch):
    root = _fake_agents_dir(tmp_path, "#!/bin/sh\nexit 0\n")
    monkeypatch.setenv("AGENTS_DIR", str(root))
    assert setup_health.check_setup_path() == root / "bin" / "check-setup.sh"
