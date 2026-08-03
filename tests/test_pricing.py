"""Tests for the API-rate value estimate: the price table, the log scanners,
the per-file scan cache, and the HUD value contract."""

from __future__ import annotations

import json
import os
import sys
import time
import tomllib
from datetime import datetime, timezone
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))

from helpers import _write_jsonl


# ---------------------------------------------------------------- value at API rates

import pricing  # noqa: E402


# A tiny hand-built price table: rates in whole dollars per token so the pricing
# math is trivial to check by hand (1 input token = $1, etc.).
_TEST_TABLE = {
    "claude-opus-4-8": {
        "input_cost_per_token": 1.0,
        "output_cost_per_token": 2.0,
        "cache_creation_input_token_cost": 0.5,
        "cache_read_input_token_cost": 0.1,
        "litellm_provider": "anthropic",
    },
    # a model missing both cache keys, to exercise the fallback rules
    "gpt-5.6": {
        "input_cost_per_token": 10.0,
        "output_cost_per_token": 20.0,
        "litellm_provider": "openai",
    },
}


def _resolver() -> "pricing.PriceResolver":
    return pricing.PriceResolver(_TEST_TABLE)


def test_pricing_all_four_token_buckets():
    """input/output/cache_creation/cache_read each priced at its own rate."""
    resolver = _resolver()
    rates = resolver.rates_for("claude-opus-4-8")
    bucket = pricing._Buckets(input=100, output=10, cache_creation=40, cache_read=1000)
    # 100*1 + 10*2 + 40*0.5 + 1000*0.1 = 100 + 20 + 20 + 100 = 240
    assert bucket.cost(rates) == 240.0


def test_pricing_cache_rate_fallbacks_when_table_omits_them():
    """Missing cache keys fall back to input rate (creation) and 0.1x (read)."""
    rates = _resolver().rates_for("gpt-5.6")
    assert rates.cache_creation == 10.0  # == input rate
    assert rates.cache_read == 1.0  # == 0.1 * input rate


def test_model_alias_resolution_strips_prefix_and_suffix():
    resolver = _resolver()
    # provider prefix stripped
    assert resolver.rates_for("anthropic/claude-opus-4-8").input == 1.0
    # codex internal alias peels down to gpt-5.6
    assert resolver.rates_for("gpt-5.6-terra").input == 10.0
    # a dated id still finds the undated table entry
    assert resolver.rates_for("gpt-5.6-2025-12-01").input == 10.0
    assert not resolver.skipped  # everything above resolved


def test_skipped_models_are_reported_not_priced_at_zero():
    resolver = _resolver()
    assert resolver.rates_for("some-unknown-model-9000") is None
    assert resolver.rates_for("") is None
    assert "some-unknown-model-9000" in resolver.skipped
    assert "(unknown)" in resolver.skipped


def _write_claude_assistant(root: Path, project: str, name: str, ts: str, model: str, usage: dict, cost=None):
    line = {"type": "assistant", "timestamp": ts, "message": {"role": "assistant", "model": model, "usage": usage}}
    if cost is not None:
        line["costUSD"] = cost
    _write_jsonl(root / project / name, [line])


def test_claude_scanner_prices_tokens_and_attributes_by_day(monkeypatch: pytest.MonkeyPatch, tmp_path: Path):
    monkeypatch.setattr(pricing, "load_price_table", lambda **kw: _TEST_TABLE)
    monkeypatch.setattr(pricing, "load_subscription_costs", lambda home=None: {})
    home = tmp_path
    projects = home / ".claude" / "projects"
    # two assistant turns on the same local day, plus one earlier this month
    _write_claude_assistant(
        projects, "-proj", "s1.jsonl", "2026-07-21T18:00:00+00:00", "claude-opus-4-8",
        {"input_tokens": 100, "output_tokens": 10, "cache_creation_input_tokens": 40, "cache_read_input_tokens": 1000},
    )
    _write_claude_assistant(
        projects, "-proj", "s2.jsonl", "2026-07-05T12:00:00+00:00", "claude-opus-4-8",
        {"input_tokens": 10, "output_tokens": 0, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0},
    )
    now = datetime(2026, 7, 21, 15, 0, tzinfo=timezone.utc)
    report = pricing.collect_value(now=now, home=home, cache_dir=tmp_path / "cache")

    team = report.sub("claude-team")
    assert team is not None
    assert team.today_usd == 240.0  # only the July 21 turn
    assert team.month_usd == 250.0  # July 21 ($240) + July 5 ($10)


def test_costusd_passthrough_beats_token_math(monkeypatch: pytest.MonkeyPatch, tmp_path: Path):
    monkeypatch.setattr(pricing, "load_price_table", lambda **kw: _TEST_TABLE)
    monkeypatch.setattr(pricing, "load_subscription_costs", lambda home=None: {})
    home = tmp_path
    projects = home / ".claude" / "projects"
    # this line would price to $240 from tokens, but its explicit costUSD wins
    _write_claude_assistant(
        projects, "-proj", "s1.jsonl", "2026-07-21T18:00:00+00:00", "claude-opus-4-8",
        {"input_tokens": 100, "output_tokens": 10, "cache_creation_input_tokens": 40, "cache_read_input_tokens": 1000},
        cost=3.5,
    )
    now = datetime(2026, 7, 21, 15, 0, tzinfo=timezone.utc)
    report = pricing.collect_value(now=now, home=home, cache_dir=tmp_path / "cache")
    assert report.sub("claude-team").today_usd == 3.5


def test_scanner_reports_skipped_model(monkeypatch: pytest.MonkeyPatch, tmp_path: Path):
    monkeypatch.setattr(pricing, "load_price_table", lambda **kw: _TEST_TABLE)
    monkeypatch.setattr(pricing, "load_subscription_costs", lambda home=None: {})
    home = tmp_path
    projects = home / ".claude" / "projects"
    _write_claude_assistant(
        projects, "-proj", "s1.jsonl", "2026-07-21T18:00:00+00:00", "no-such-model",
        {"input_tokens": 100, "output_tokens": 10},
    )
    now = datetime(2026, 7, 21, 15, 0, tzinfo=timezone.utc)
    report = pricing.collect_value(now=now, home=home, cache_dir=tmp_path / "cache")
    assert report.sub("claude-team").today_usd == 0.0  # unpriceable, not free-at-zero silently
    assert "no-such-model" in report.skipped_models


def test_scan_cache_invalidates_on_mtime_change(monkeypatch: pytest.MonkeyPatch, tmp_path: Path):
    monkeypatch.setattr(pricing, "load_price_table", lambda **kw: _TEST_TABLE)
    monkeypatch.setattr(pricing, "load_subscription_costs", lambda home=None: {})
    home = tmp_path
    cache_dir = tmp_path / "cache"
    projects = home / ".claude" / "projects"
    f = projects / "-proj" / "s1.jsonl"
    _write_claude_assistant(
        projects, "-proj", "s1.jsonl", "2026-07-21T18:00:00+00:00", "claude-opus-4-8",
        {"input_tokens": 100, "output_tokens": 0, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0},
    )
    now = datetime(2026, 7, 21, 15, 0, tzinfo=timezone.utc)
    first = pricing.collect_value(now=now, home=home, cache_dir=cache_dir)
    assert first.sub("claude-team").today_usd == 100.0

    # rewrite the file with different content and a newer mtime; the stale cache
    # entry must be dropped and the new tokens re-priced
    time.sleep(0.01)
    _write_claude_assistant(
        projects, "-proj", "s1.jsonl", "2026-07-21T18:00:00+00:00", "claude-opus-4-8",
        {"input_tokens": 250, "output_tokens": 0, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0},
    )
    os.utime(f, (time.time() + 5, time.time() + 5))
    second = pricing.collect_value(now=now, home=home, cache_dir=cache_dir)
    assert second.sub("claude-team").today_usd == 250.0


def _write_codex_rollout(root: Path, rel: str, sid: str, thread_source: str, model: str,
                         turns: list[tuple[str, dict]]):
    lines = [{"type": "session_meta", "timestamp": turns[0][0] if turns else "2026-07-21T00:00:00Z",
              "payload": {"session_id": sid, "id": sid, "cwd": "/tmp/cx", "thread_source": thread_source}}]
    if model:
        lines.append({"type": "turn_context", "payload": {"type": "turn_context", "model": model}})
    for ts, last in turns:
        lines.append({"type": "event_msg", "timestamp": ts,
                      "payload": {"type": "token_count", "info": {"last_token_usage": last}}})
    _write_jsonl(root / "sessions" / rel, lines)


def test_codex_scanner_prices_last_token_usage_and_skips_subagents(monkeypatch: pytest.MonkeyPatch, tmp_path: Path):
    monkeypatch.setattr(pricing, "load_price_table", lambda **kw: _TEST_TABLE)
    monkeypatch.setattr(pricing, "load_subscription_costs", lambda home=None: {})
    home = tmp_path
    codex = home / ".codex"
    # a user session: input_tokens includes the cached slice, so non-cached = 100-40 = 60
    _write_codex_rollout(
        codex, "2026/07/21/rollout-a.jsonl", "sid-a", "user", "gpt-5.6-terra",
        [("2026-07-21T18:00:00+00:00",
          {"input_tokens": 100, "cached_input_tokens": 40, "cache_write_input_tokens": 5, "output_tokens": 10})],
    )
    # a subagent rollout for a different sid: must be skipped entirely
    _write_codex_rollout(
        codex, "2026/07/21/rollout-b.jsonl", "sid-b", "subagent", "gpt-5.6",
        [("2026-07-21T18:30:00+00:00",
          {"input_tokens": 1000, "cached_input_tokens": 0, "cache_write_input_tokens": 0, "output_tokens": 1000})],
    )
    now = datetime(2026, 7, 21, 15, 0, tzinfo=timezone.utc)
    report = pricing.collect_value(now=now, home=home, cache_dir=tmp_path / "cache")
    codex_sub = report.sub("codex")
    # gpt-5.6 fallbacks: creation = input rate 10, read = 1
    # 60*10 (non-cached input) + 10*20 (output) + 5*10 (creation) + 40*1 (read) = 600+200+50+40 = 890
    assert codex_sub.today_usd == 890.0  # subagent tokens excluded


def test_today_and_month_boundary_attribution(monkeypatch: pytest.MonkeyPatch, tmp_path: Path):
    """A turn on the last day of the previous month is neither today nor this month."""
    monkeypatch.setattr(pricing, "load_price_table", lambda **kw: _TEST_TABLE)
    monkeypatch.setattr(pricing, "load_subscription_costs", lambda home=None: {})
    home = tmp_path
    projects = home / ".claude" / "projects"
    _write_claude_assistant(
        projects, "-proj", "june.jsonl", "2026-06-30T18:00:00+00:00", "claude-opus-4-8",
        {"input_tokens": 100, "output_tokens": 0, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0},
    )
    _write_claude_assistant(
        projects, "-proj", "julyfirst.jsonl", "2026-07-01T09:00:00+00:00", "claude-opus-4-8",
        {"input_tokens": 50, "output_tokens": 0, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0},
    )
    now = datetime(2026, 7, 21, 15, 0, tzinfo=timezone.utc)
    report = pricing.collect_value(now=now, home=home, cache_dir=tmp_path / "cache")
    team = report.sub("claude-team")
    assert team.today_usd == 0.0  # nothing today
    assert team.month_usd == 50.0  # June 30 excluded, July 1 included


def test_config_parsing_and_multiple(monkeypatch: pytest.MonkeyPatch, tmp_path: Path):
    if pricing.tomllib is None:
        pytest.skip("tomllib unavailable on this interpreter")
    monkeypatch.setattr(pricing, "load_price_table", lambda **kw: _TEST_TABLE)
    home = tmp_path
    projects = home / ".claude" / "projects"
    _write_claude_assistant(
        projects, "-proj", "s.jsonl", "2026-07-10T18:00:00+00:00", "claude-opus-4-8",
        {"input_tokens": 300, "output_tokens": 0, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0},
    )
    cfg = home / ".config" / "agenthud"
    cfg.mkdir(parents=True)
    (cfg / "config.toml").write_text(
        "[subscriptions]\n"
        'claude-team = 150.0\n'
        'codex = 200\n'
    )
    now = datetime(2026, 7, 21, 15, 0, tzinfo=timezone.utc)
    report = pricing.collect_value(now=now, home=home, cache_dir=tmp_path / "cache")
    team = report.sub("claude-team")
    assert team.subs_cost_usd == 150.0
    assert team.month_usd == 300.0
    assert team.multiple == 2.0  # $300 of value over a $150 sub
    assert report.subs_cost_usd == 350.0  # 150 + 200
    assert report.multiple == 300.0 / 350.0


def test_config_missing_leaves_costs_none(monkeypatch: pytest.MonkeyPatch, tmp_path: Path):
    monkeypatch.setattr(pricing, "load_price_table", lambda **kw: _TEST_TABLE)
    now = datetime(2026, 7, 21, 15, 0, tzinfo=timezone.utc)
    report = pricing.collect_value(now=now, home=tmp_path, cache_dir=tmp_path / "cache")
    assert report.subs_cost_usd is None
    assert report.multiple is None
    for sub in report.subs:
        assert sub.subs_cost_usd is None and sub.multiple is None


def test_price_table_falls_back_to_snapshot_on_network_failure(monkeypatch: pytest.MonkeyPatch, tmp_path: Path):
    """No cache and a dead network still yields the committed snapshot."""
    monkeypatch.setattr(pricing, "_fetch_live_prices", lambda timeout=8.0: None)
    table = pricing.load_price_table(cache_dir=tmp_path / "empty-cache")
    assert "claude-opus-4-8" in table  # came from the bundled snapshot


def test_price_table_prefers_fresh_cache_over_network(monkeypatch: pytest.MonkeyPatch, tmp_path: Path):
    cache_dir = tmp_path / "cache"
    cache_dir.mkdir()
    (cache_dir / "model-prices.json").write_text(json.dumps({"cached-model": {"input_cost_per_token": 1.0}}))
    called = {"n": 0}

    def fake_fetch(timeout=8.0):
        called["n"] += 1
        return {"live-model": {"input_cost_per_token": 2.0}}

    monkeypatch.setattr(pricing, "_fetch_live_prices", fake_fetch)
    table = pricing.load_price_table(cache_dir=cache_dir)  # fresh cache (just written)
    assert "cached-model" in table
    assert called["n"] == 0  # never hit the network within the 24h window


def test_snapshot_file_is_present_and_parseable():
    """The committed offline fallback must exist and contain the models we price."""
    snap = pricing._read_json(pricing._snapshot_path())
    assert snap is not None
    assert "claude-opus-4-8" in snap and "gpt-5.6" in snap
    rates = pricing._rates_from_entry(snap["claude-opus-4-8"])
    assert rates is not None and rates.input > 0


def test_hud_value_is_json_safe_and_matches_contract():
    """The daemon consumes hud_value(); it must be plain json.dumps-able and carry
    exactly the contract keys (no set, no datetime leaking through)."""
    report = pricing.ValueReport(
        subs=[
            pricing.SubValue(id="claude-team", today_usd=8.334, month_usd=15209.651,
                             subs_cost_usd=150.0, multiple=101.4),
            pricing.SubValue(id="codex", today_usd=0.0, month_usd=3774.544),
        ],
        today_total_usd=8.334,
        month_total_usd=18984.201,
        subs_cost_usd=150.0,
        multiple=126.561,
        skipped_models={"<synthetic>"},  # a set: plain json.dumps would reject the raw report
        generated_at=datetime(2026, 7, 21, 15, 0, tzinfo=timezone.utc),  # a datetime: likewise
    )
    hud = pricing.hud_value(report)

    # serializes with the stdlib encoder, no custom default= needed
    encoded = json.dumps(hud)
    assert isinstance(encoded, str)

    # exactly the contract keys at the top level
    assert set(hud.keys()) == {"today_usd", "month_usd", "subs_cost_usd", "multiple", "by_sub"}
    # dropped: the CLI-only fields never reach the daemon
    assert "skipped_models" not in hud and "generated_at" not in hud

    # dollars rounded to cents
    assert hud["today_usd"] == 8.33 and hud["month_usd"] == 18984.2
    assert hud["subs_cost_usd"] == 150.0

    # by_sub keyed by subscription id, each with exactly today/month
    assert set(hud["by_sub"].keys()) == {"claude-team", "codex"}
    assert hud["by_sub"]["claude-team"] == {"today_usd": 8.33, "month_usd": 15209.65}
    assert set(hud["by_sub"]["codex"].keys()) == {"today_usd", "month_usd"}


def test_hud_value_carries_none_cost_and_multiple_through():
    report = pricing.ValueReport(
        subs=[pricing.SubValue(id="codex", today_usd=1.0, month_usd=2.0)],
        today_total_usd=1.0, month_total_usd=2.0,
        subs_cost_usd=None, multiple=None,
    )
    hud = pricing.hud_value(report)
    assert hud["subs_cost_usd"] is None and hud["multiple"] is None
    json.dumps(hud)  # None is JSON-safe


