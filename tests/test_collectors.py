"""Tests for the session collectors and the shared session model."""

from __future__ import annotations

import json
import sys
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from helpers import _write_jsonl

import collectors
from models import Session, resume_command, resume_directory, resume_invocation


# ---------------------------------------------------------------- collectors


def test_claude_collector(claude_root: Path):
    sessions = collectors.collect_claude(root=claude_root)
    assert len(sessions) == 1
    s = sessions[0]
    assert s.tool == "claude"
    assert s.id == "sess-1"
    assert s.title == "Test session"
    assert s.project_dir == "/tmp/proj"
    assert s.tokens == 18
    assert s.n_messages == 3  # 2 real user prompts + 1 assistant; tool_result excluded
    assert s.first_prompt == "hello world"


def test_codex_collector_merges_and_filters(codex_root: Path):
    sessions = collectors.collect_codex(root=codex_root)
    assert len(sessions) == 1  # subagent rollout excluded
    s = sessions[0]
    assert s.tool == "codex"
    assert s.id == "1111-2222-3333-4444-555555555555"
    assert s.title == "Bug fix thread"
    assert s.tokens == 250  # cumulative: last token_count event wins
    assert s.first_prompt == "fix the bug"


def test_codex_collector_includes_archived_sessions(codex_root: Path):
    archived_id = "aaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    _write_jsonl(
        codex_root / "archived_sessions" / f"rollout-{archived_id}.jsonl",
        [
            {
                "type": "session_meta",
                "payload": {
                    "session_id": archived_id,
                    "cwd": "/tmp/archived",
                    "thread_source": "user",
                },
            },
            {
                "type": "event_msg",
                "payload": {
                    "type": "user_message",
                    "message": "keep archived conversations visible",
                },
            },
        ],
    )

    sessions = collectors.collect_codex(root=codex_root)

    assert {session.id for session in sessions} == {
        "1111-2222-3333-4444-555555555555",
        archived_id,
    }
    archived = next(session for session in sessions if session.id == archived_id)
    assert archived.title == "Keep archived conversations visible"


def test_codex_collector_titles_current_user_message_events(tmp_path: Path):
    """Codex 0.145 writes the typed prompt in event_msg, not response_item."""
    root = tmp_path / "codex"
    sid = "aaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    _write_jsonl(
        root / "sessions" / "2026" / "07" / "21" / f"rollout-{sid}.jsonl",
        [
            {"type": "session_meta", "payload": {"session_id": sid, "cwd": "/tmp/cx", "thread_source": "user"}},
            {"type": "response_item", "payload": {"type": "message", "role": "user",
             "content": [{"type": "input_text", "text": "# AGENTS.md instructions"}]}},
            {"type": "event_msg", "payload": {"type": "user_message",
             "message": "[Image #1] can you figure out why codex titles are missing?"}},
        ],
    )

    sessions = collectors.collect_codex(root=root)

    assert len(sessions) == 1
    assert sessions[0].first_prompt == "[Image #1] can you figure out why codex titles are missing?"
    assert sessions[0].title == "[Image #1] can you figure out why codex titles are missing?"


def test_opencode_collector(opencode_db: Path):
    sessions = collectors.collect_opencode(db_path=opencode_db)
    assert len(sessions) == 1  # archived session excluded
    s = sessions[0]
    assert s.id == "ses_1"
    assert s.tokens == 150
    assert s.cost == 0.5
    assert s.project_dir == "/tmp/oc"


def test_gemini_collector(gemini_root: Path):
    sessions = collectors.collect_gemini(root=gemini_root)
    assert len(sessions) == 1
    s = sessions[0]
    assert s.tool == "gemini"
    assert s.id == "11111111-2222-3333-4444-555555555555"  # from the metadata line
    assert s.project_dir == "/tmp/gem"  # resolved via projects.json
    assert s.first_prompt == "add gemini to agent hud"
    assert s.title == "Add gemini to agent hud"  # clean_title of the first prompt
    assert s.n_messages == 3  # 2 user + 1 gemini; the info message is excluded
    assert s.source_path.endswith("session-1784500000000-11111111.jsonl")


def test_gemini_collector_blank_dir_when_project_unmapped(tmp_path: Path):
    """A session in a temp dir with no projects.json entry still parses; its
    project dir is left blank (renders '?', resume falls back to home)."""
    root = tmp_path / "gemini"
    _write_jsonl(
        root / "tmp" / "orphan-slug" / "chats" / "session-1784500000000-99999999.jsonl",
        [
            {"sessionId": "99999999-0000-0000-0000-000000000000"},
            {"id": "m1", "type": "user", "content": "hello gemini", "timestamp": "2026-07-19T10:00:01.000Z"},
        ],
    )
    sessions = collectors.collect_gemini(root=root)
    assert len(sessions) == 1
    assert sessions[0].project_dir == ""
    assert sessions[0].first_prompt == "hello gemini"


def test_cache_roundtrip(claude_root: Path, tmp_path: Path):
    first = collectors.collect_all.__wrapped__ if hasattr(collectors.collect_all, "__wrapped__") else None
    cache: dict = {}
    s1 = collectors.collect_claude(root=claude_root, cache=cache)
    assert len(cache) == 1
    s2 = collectors.collect_claude(root=claude_root, cache=cache)
    assert [s.id for s in s1] == [s.id for s in s2]
    assert s1[0].tokens == s2[0].tokens


# ---------------------------------------------------------------- resume


def test_resume_command_quotes_paths(tmp_path: Path):
    spaced = tmp_path / "dir with spaces"
    spaced.mkdir()
    s = Session(tool="claude", id="abc", title="t", project_dir=str(spaced),
                last_active=datetime.now(timezone.utc))
    assert resume_command(s) == f"cd '{spaced}' && claude --resume abc"


def test_resume_command_missing_dir_falls_home():
    s = Session(tool="codex", id="xyz", title="t", project_dir="/does/not/exist",
                last_active=datetime.now(timezone.utc))
    cmd = resume_command(s)
    assert "codex resume xyz" in cmd
    assert "/does/not/exist" not in cmd


def test_resume_invocation_has_no_cd_and_directory_falls_home(tmp_path: Path):
    # The Warp resume tab sets the directory itself, so the invocation must be
    # the bare tool command with no `cd`.
    here = Session(tool="claude", id="abc", title="t", project_dir=str(tmp_path),
                   last_active=datetime.now(timezone.utc))
    assert resume_invocation(here) == "claude --resume abc"
    assert resume_directory(here) == str(tmp_path)

    gone = Session(tool="opencode", id="s1", title="t", project_dir="/does/not/exist",
                   last_active=datetime.now(timezone.utc))
    assert resume_invocation(gone) == "opencode --session s1"
    assert resume_directory(gone) == str(Path.home())


def test_gemini_resume_invocation(tmp_path: Path):
    s = Session(tool="gemini", id="g-123", title="t", project_dir=str(tmp_path),
                last_active=datetime.now(timezone.utc))
    assert resume_invocation(s) == "gemini --resume g-123"
    assert resume_command(s) == f"cd {tmp_path} && gemini --resume g-123"



# ---------------------------------------------------------------- titles


def test_claude_title_from_slash_command(tmp_path: Path):
    root = tmp_path / "claude" / "projects"
    _write_jsonl(
        root / "-tmp-proj" / "sess-cmd.jsonl",
        [
            {"type": "user", "cwd": "/tmp/proj", "message": {"role": "user",
             "content": "<command-message>fix-pr</command-message>\n<command-name>/fix-pr-feedback</command-name>\n<command-args>3059</command-args>"}},
            {"type": "user", "cwd": "/tmp/proj", "message": {"role": "user", "content": [{"type": "tool_result", "content": "ok"}]}},
        ],
    )
    sessions = collectors.collect_claude(root=root)
    assert sessions[0].title == "/fix-pr-feedback 3059"


def test_bare_slash_command_loses_to_a_real_prompt(tmp_path: Path):
    """"/model" says nothing about which session this is, so a prompt typed
    afterwards is the better title. A command with args already describes the
    work, so that still wins."""
    root = tmp_path / "claude" / "projects"
    _write_jsonl(
        root / "-tmp-bare" / "sess-bare.jsonl",
        [
            {"type": "user", "cwd": "/tmp/bare", "message": {"role": "user",
             "content": "<command-message>model</command-message>\n<command-name>/model</command-name>"}},
            {"type": "user", "cwd": "/tmp/bare", "message": {"role": "user", "content": "wire up the billing webhook"}},
        ],
    )
    _write_jsonl(
        root / "-tmp-args" / "sess-args.jsonl",
        [
            {"type": "user", "cwd": "/tmp/args", "message": {"role": "user",
             "content": "<command-message>review</command-message>\n<command-name>/review</command-name>\n<command-args>412</command-args>"}},
            {"type": "user", "cwd": "/tmp/args", "message": {"role": "user", "content": "wire up the billing webhook"}},
        ],
    )
    titles = {s.id: s.title for s in collectors.collect_claude(root=root)}
    assert titles["sess-bare"] == "Wire up the billing webhook"
    assert titles["sess-args"] == "/review 412"


def test_claude_title_skips_injected_messages(tmp_path: Path):
    root = tmp_path / "claude" / "projects"
    _write_jsonl(
        root / "-tmp-proj" / "sess-skill.jsonl",
        [
            {"type": "user", "cwd": "/tmp/proj", "message": {"role": "user", "content": "Base directory for this skill: /Users/x/skills/review"}},
            {"type": "user", "cwd": "/tmp/proj", "message": {"role": "user", "content": "actually review my PR please"}},
        ],
    )
    sessions = collectors.collect_claude(root=root)
    assert sessions[0].title == "Actually review my PR please"




# ---------------------------------------------------------------- titles



def test_clean_title():
    from models import clean_title

    assert clean_title("can you help me update my personal claude.md") == "Update my personal claude.md"
    assert clean_title("please check out the dev branch") == "Check out the dev branch"
    assert clean_title("If i wanted to use datadog") == "If i wanted to use datadog"
    assert clean_title("https://finance.yahoo.com/quote/CCLD/ if i wanted") == "https://finance.yahoo.com/quote/CCLD/ if i wanted"
    long_prompt = "word " * 30
    result = clean_title(long_prompt.strip(), width=40)
    assert len(result) <= 41 and result.endswith("…") and "  " not in result


def test_clean_title_strips_extended_filler():
    from models import clean_title

    # dictated-style filler and typos should peel off, leaving a readable title
    assert clean_title("can u set up the onepass cli") == "Set up the onepass cli"
    assert clean_title("pls pull down dev for web app") == "Pull down dev for web app"
    assert clean_title("just fix the laborder empty unit") == "Fix the laborder empty unit"
    assert clean_title("so i wanna audit the CarePilot screens") == "Audit the CarePilot screens"
    # stacked filler still peels within the pass budget
    assert clean_title("ok so can you help me brainstorm") == "Brainstorm"


