"""Tests for live agent activity: the per-tool status readers and enrich()."""

from __future__ import annotations

import json
import sys
import sqlite3
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from helpers import _write_jsonl

from activity import codex_status_for_file


# ---------------------------------------------------------------- live activity


def test_claude_activity_status_and_frontmost_label(tmp_path: Path):
    from activity import claude_activity

    root = tmp_path / "claude"
    (root / "sessions").mkdir(parents=True)
    (root / "statusbar").mkdir(parents=True)
    (root / "sessions" / "4523.json").write_text(json.dumps({"sessionId": "S1", "status": "busy"}))
    (root / "sessions" / "999.json").write_text(json.dumps({"sessionId": "S2", "status": "idle"}))
    (root / "statusbar" / "state.json").write_text(
        json.dumps({"sessionId": "S1", "state": "tool", "label": "Running command", "tool": "Bash"})
    )

    acts = claude_activity(root)
    assert acts[4523].state == "working"
    assert acts[4523].label == "Running command"  # frontmost session gets the live action
    assert acts[999].state == "idle"
    assert acts[999].label == ""  # not frontmost -> no action detail


def test_claude_activity_waiting_on_permission(tmp_path: Path):
    from activity import claude_activity

    root = tmp_path / "claude"
    (root / "sessions").mkdir(parents=True)
    (root / "statusbar").mkdir(parents=True)
    (root / "sessions" / "12.json").write_text(json.dumps({"sessionId": "S1", "status": "busy"}))
    (root / "statusbar" / "state.json").write_text(
        json.dumps({"sessionId": "S1", "state": "permission", "label": "Awaiting permission"})
    )
    assert claude_activity(root)[12].state == "waiting"


def test_codex_activity_working_then_idle(tmp_path: Path):
    from activity import codex_activity

    day = tmp_path / "codex" / "sessions" / "2026" / "07" / "20"
    day.mkdir(parents=True)
    _write_jsonl(day / "rollout-a.jsonl", [
        {"timestamp": "t", "type": "session_meta", "payload": {"session_id": "c1"}},
        {"timestamp": "t", "type": "event_msg",
         "payload": {"type": "token_count", "info": {"total_token_usage": {"total_tokens": 1234}}}},
        {"timestamp": "t", "type": "response_item", "payload": {"type": "function_call"}},
    ])
    st = codex_activity(tmp_path / "codex" / "sessions")
    assert st.state == "working" and st.tokens == 1234 and "tool" in st.label

    # a newer rollout that has finished its turn
    _write_jsonl(day / "rollout-b.jsonl", [
        {"timestamp": "t", "type": "event_msg",
         "payload": {"type": "token_count", "info": {"total_token_usage": {"total_tokens": 40}}}},
        {"timestamp": "t", "type": "event_msg", "payload": {"type": "task_complete"}},
    ])
    st2 = codex_activity(tmp_path / "codex" / "sessions")
    assert st2.state == "idle" and st2.tokens == 40


def test_codex_activity_none_when_empty(tmp_path: Path):
    from activity import codex_activity
    assert codex_activity(tmp_path / "nope") is None


def test_opencode_activity_generating(tmp_path: Path):
    from activity import opencode_activity

    db = tmp_path / "oc.db"
    con = sqlite3.connect(db)
    con.execute("CREATE TABLE session (id TEXT, tokens_input INT, tokens_output INT, "
                "tokens_reasoning INT, time_updated INT, time_archived INT)")
    con.execute("CREATE TABLE message (id TEXT, session_id TEXT, time_created INT, data TEXT)")
    con.execute("INSERT INTO session VALUES ('s1', 100, 50, 10, 2000, NULL)")
    con.execute("INSERT INTO message VALUES ('m1', 's1', 1000, ?)",
                (json.dumps({"role": "assistant", "time": {"created": 1, "completed": None}}),))
    con.commit()
    con.close()

    st = opencode_activity(db)
    assert st.tokens == 160 and st.state == "working"


def test_enrich_matches_claude_by_pid(tmp_path: Path):
    from activity import enrich
    from agents import RunningAgent

    root = tmp_path / "claude"
    (root / "sessions").mkdir(parents=True)
    (root / "statusbar").mkdir(parents=True)
    (root / "sessions" / "1.json").write_text(json.dumps({"sessionId": "S1", "status": "busy"}))
    (root / "statusbar" / "state.json").write_text(
        json.dumps({"sessionId": "S1", "state": "tool", "label": "Running command"}))

    agents = [
        RunningAgent(tool="claude", pid=1, tty="t1", elapsed="5m", cwd="/tmp"),
        RunningAgent(tool="codex", pid=2, tty="t2", elapsed="9m", cwd="/tmp"),
    ]
    enrich(agents, claude_root=root, codex_root=tmp_path / "no-codex",
           opencode_db=tmp_path / "no.db")
    assert agents[0].state == "working" and agents[0].label == "Running command"
    assert agents[1].state == "unknown"  # no codex rollout -> left untouched





def test_codex_status_for_file_reports_working_then_idle(tmp_path: Path):
    working = tmp_path / "working.jsonl"
    _write_jsonl(working, [
        {"type": "session_meta", "payload": {"session_id": "w", "cwd": "/tmp/cx", "thread_source": "user"}},
        {"type": "response_item", "payload": {"type": "function_call", "name": "shell"}},
    ])
    assert codex_status_for_file(working).state == "working"

    idle = tmp_path / "idle.jsonl"
    _write_jsonl(idle, [
        {"type": "session_meta", "payload": {"session_id": "i", "cwd": "/tmp/cx", "thread_source": "user"}},
        {"type": "response_item", "payload": {"type": "function_call", "name": "shell"}},
        {"type": "event_msg", "payload": {"type": "task_complete"}},
    ])
    assert codex_status_for_file(idle).state == "idle"


