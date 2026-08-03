"""Shared fixtures, plus the hardening that keeps the suite deterministic
regardless of where and under what wrapper it runs.

- Several collectors read relative paths, and CI runs pytest from anywhere,
  including inside an agent worktree, so every test runs chdir'd into its own
  temp directory to make cwd-derived behavior reproducible.
- The serve tests hit `http://127.0.0.1` with urllib, which honors HTTP_PROXY
  from the environment. Proxy wrappers (Socket Firewall, corporate proxies)
  would intercept those loopback requests and fail them, so proxy variables
  are stripped for every test.
"""

from __future__ import annotations

import json
import sqlite3
import time
from pathlib import Path

import pytest

from helpers import _write_jsonl


@pytest.fixture(autouse=True)
def _neutral_cwd(tmp_path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.chdir(tmp_path)


@pytest.fixture(autouse=True)
def _no_proxies(monkeypatch: pytest.MonkeyPatch):
    for var in (
        "HTTP_PROXY", "http_proxy",
        "HTTPS_PROXY", "https_proxy",
        "ALL_PROXY", "all_proxy",
    ):
        monkeypatch.delenv(var, raising=False)
    monkeypatch.setenv("NO_PROXY", "127.0.0.1,localhost")
    monkeypatch.setenv("no_proxy", "127.0.0.1,localhost")


# ---------------------------------------------------------------- fixtures




@pytest.fixture
def claude_root(tmp_path: Path) -> Path:
    root = tmp_path / "claude" / "projects"
    _write_jsonl(
        root / "-tmp-proj" / "sess-1.jsonl",
        [
            {"type": "ai-title", "aiTitle": "Test session", "sessionId": "sess-1"},
            {"type": "user", "cwd": "/tmp/proj", "message": {"role": "user", "content": "hello world"}},
            {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "hi"}],
                                              "usage": {"input_tokens": 10, "output_tokens": 5,
                                                        "cache_read_input_tokens": 2, "cache_creation_input_tokens": 1}}},
            {"type": "user", "cwd": "/tmp/proj", "message": {"role": "user", "content": [{"type": "tool_result", "content": "ok"}]}},
            {"type": "user", "cwd": "/tmp/proj", "message": {"role": "user", "content": [{"type": "text", "text": "second prompt"}]}},
        ],
    )
    return root


@pytest.fixture
def codex_root(tmp_path: Path) -> Path:
    root = tmp_path / "codex"
    sid = "1111-2222-3333-4444-555555555555"
    _write_jsonl(
        root / "sessions" / "2026" / "07" / "19" / f"rollout-2026-07-19T10-00-00-{sid}.jsonl",
        [
            {"type": "session_meta", "payload": {"session_id": sid, "id": sid, "cwd": "/tmp/cx", "thread_source": "user"}},
            {"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "fix the bug"}]}},
            {"type": "event_msg", "payload": {"type": "token_count", "info": {"total_token_usage": {"total_tokens": 100}}}},
            {"type": "event_msg", "payload": {"type": "token_count", "info": {"total_token_usage": {"total_tokens": 250}}}},
        ],
    )
    # a subagent rollout for the same thread: must be excluded
    _write_jsonl(
        root / "sessions" / "2026" / "07" / "19" / "rollout-2026-07-19T11-00-00-9999-0000-0000-0000-000000000000.jsonl",
        [
            {"type": "session_meta", "payload": {"session_id": sid, "id": "9999-0000-0000-0000-000000000000", "cwd": "/tmp/cx", "thread_source": "subagent"}},
            {"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "subagent prompt"}]}},
        ],
    )
    with (root / "session_index.jsonl").open("w") as fh:
        fh.write(json.dumps({"id": sid, "thread_name": "Bug fix thread", "updated_at": "2026-07-19T10:00:00Z"}) + "\n")
    return root


@pytest.fixture
def opencode_db(tmp_path: Path) -> Path:
    db = tmp_path / "opencode.db"
    # The spend collector only counts the last 7 days, so these rows are stamped
    # relative to now. A fixed epoch would quietly stop being counted the moment
    # the calendar moved past it, and the test would pass by measuring nothing.
    updated = int(time.time() * 1000)
    created = updated - 60_000
    con = sqlite3.connect(db)
    con.execute(
        """CREATE TABLE session (id text PRIMARY KEY, title text, directory text,
              tokens_input integer, tokens_output integer, tokens_reasoning integer,
              cost real, time_created integer, time_updated integer, time_archived integer)"""
    )
    con.execute(
        "INSERT INTO session VALUES ('ses_1', 'OC session', '/tmp/oc', 100, 40, 10, 0.5, ?, ?, NULL)",
        (created, updated),
    )
    con.execute(
        "INSERT INTO session VALUES ('ses_2', 'Archived', '/tmp/oc', 1, 1, 1, 0.0, ?, ?, ?)",
        (created, updated, updated + 10_000),
    )
    con.commit()
    con.close()
    return db


@pytest.fixture
def gemini_root(tmp_path: Path) -> Path:
    root = tmp_path / "gemini"
    root.mkdir(parents=True, exist_ok=True)
    # projects.json maps a project path to the temp-dir slug; the collector
    # inverts it to resolve a session's cwd from its <slug> directory.
    with (root / "projects.json").open("w") as fh:
        json.dump({"projects": {"/tmp/gem": "proj-slug"}}, fh)
    sid = "11111111-2222-3333-4444-555555555555"
    _write_jsonl(
        root / "tmp" / "proj-slug" / "chats" / "session-1784500000000-11111111.jsonl",
        [
            {"sessionId": sid, "projectHash": "deadbeef", "startTime": "2026-07-19T10:00:00.000Z"},
            {"id": "m1", "type": "user", "content": "add gemini to agent hud", "timestamp": "2026-07-19T10:00:01.000Z"},
            {"id": "m2", "type": "gemini", "content": "Sure, here is the plan.", "timestamp": "2026-07-19T10:00:02.000Z"},
            {"id": "m3", "type": "user", "content": "now write tests too", "timestamp": "2026-07-19T10:00:03.000Z"},
            {"id": "m4", "type": "info", "content": "context loaded", "timestamp": "2026-07-19T10:00:04.000Z"},
        ],
    )
    return root

