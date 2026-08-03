"""Tests for running-agent detection: the ps scan and the per-pid session id."""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))


# ---------------------------------------------------------------- agents


def test_parse_ps_detects_only_terminal_agents():
    from agents import _parse_ps

    ps_output = """\
 64028 ttys003   01:48:12 opencode
 59001 ttys005      12:03 /Users/josephtutera/.local/bin/claude --resume abc-123
 59002 ttys005      12:03 /bin/zsh -c claude --resume abc-123
  1046 ??      07-09:23:04 /Applications/Claude.app/Contents/Frameworks/Electron Framework.framework/Helpers/chrome_crashpad_handler --monitor-self
 30591 ??      07-03:02:18 node /Users/x/Repos/prototype-ehr/.claude/worktrees/foo/platform/node_modules/.bin/../tsx/dist/cli.mjs watch src/index.ts
 60200 ttys007      03:45 node /Users/josephtutera/.nvm/versions/node/v24.14.1/bin/codex
 61000 ttys008      01:10 nvim claude.md
"""
    agents = _parse_ps(ps_output)
    tools = sorted(a.tool for a in agents)
    assert tools == ["claude", "codex", "opencode"]  # shell wrapper, desktop app, dev server, editor all excluded
    opencode = next(a for a in agents if a.tool == "opencode")
    assert opencode.pid == 64028
    assert opencode.tty == "ttys003"
    assert opencode.elapsed == "1h 48m"


def test_parse_ps_keeps_one_codex_agent_per_terminal():
    from agents import _parse_ps

    ps_output = """\
 60200 ttys007      03:45 node /Users/josephtutera/.nvm/versions/node/v24.14.1/bin/codex
 60201 ttys007      03:45 /Users/josephtutera/.nvm/versions/node/v24.14.1/lib/node_modules/@openai/codex/vendor/bin/codex
"""

    agents = _parse_ps(ps_output)

    assert [(agent.tool, agent.pid, agent.tty) for agent in agents] == [("codex", 60200, "ttys007")]


def test_elapsed_formatting():
    from agents import _elapsed

    assert _elapsed("12:03") == "12m"
    assert _elapsed("01:48:12") == "1h 48m"
    assert _elapsed("07-09:23:04") == "7d 9h"




def test_claude_session_id_read_from_pid_file(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    # Claude Code writes ~/.claude/sessions/<pid>.json naming the live transcript;
    # reading it is what lets a running agent resolve to its exact session.
    import agents as agents_module

    monkeypatch.setenv("HOME", str(tmp_path))
    sessions_dir = tmp_path / ".claude" / "sessions"
    sessions_dir.mkdir(parents=True)
    (sessions_dir / "56817.json").write_text(json.dumps(
        {"pid": 56817, "sessionId": "4b5d8bef-52fc", "status": "busy"}))
    assert agents_module._claude_session_id_for_pid(56817) == "4b5d8bef-52fc"
    assert agents_module._claude_session_id_for_pid(99999) == ""  # no file for this pid
    (sessions_dir / "42.json").write_text("not json{")
    assert agents_module._claude_session_id_for_pid(42) == ""  # malformed, tolerated


def test_running_agents_tags_claude_with_its_exact_session_id(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    # end-to-end guard for the mislabel bug: a running claude agent must carry
    # its real session id, not just its directory, so recency can't override it.
    import agents as agents_module

    monkeypatch.setenv("HOME", str(tmp_path))
    sessions_dir = tmp_path / ".claude" / "sessions"
    sessions_dir.mkdir(parents=True)
    (sessions_dir / "56817.json").write_text(json.dumps({"sessionId": "sess-4b5d"}))

    class _Result:
        def __init__(self, stdout: str):
            self.stdout = stdout

    def fake_run(cmd, **kwargs):
        if cmd[0] == "ps":
            return _Result("56817 ttys003 05:00 claude\n")
        if cmd[0] == "lsof":
            return _Result("p56817\nn/Users/josephtutera/Repos/agent-hud\n")
        return _Result("")

    monkeypatch.setattr(agents_module.subprocess, "run", fake_run)
    agents = agents_module.running_agents()
    assert len(agents) == 1
    assert agents[0].tool == "claude"
    assert agents[0].session_id == "sess-4b5d"
    assert agents[0].cwd == "/Users/josephtutera/Repos/agent-hud"


