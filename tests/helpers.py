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


def write_claude_tree(
    home: Path,
    name: str,
    *,
    org_uuid: str | None = None,
    org_name: str = "",
    org_type: str = "",
    sub_type: str = "",
    token: str = "",
    account_uuid: str = "acct-same-person",
) -> Path:
    """Build a Claude config tree the way Claude Code lays one out.

    The default `~/.claude` keeps its account metadata *beside* the tree at
    `~/.claude.json`; a tree opened with CLAUDE_CONFIG_DIR keeps its own copy
    inside itself. Reading the wrong one is the bug these fixtures exist to
    catch, so they reproduce the real layout rather than a convenient one.

    Every tree shares one `accountUuid` by default, because that is the true
    state of a machine where one person holds two subscriptions — and keying on
    it would wrongly fold them into one.

    `org_uuid=None` builds a tree with no readable account, i.e. signed out.
    """
    tree = home / name
    tree.mkdir(parents=True, exist_ok=True)
    if org_uuid is not None:
        account = {
            "accountUuid": account_uuid,
            "emailAddress": "joseph@carepilot.com",
            "organizationUuid": org_uuid,
            "organizationName": org_name,
            "organizationType": org_type,
        }
        metadata = home / ".claude.json" if name == ".claude" else tree / ".claude.json"
        metadata.write_text(json.dumps({"oauthAccount": account}))
    if token:
        (tree / ".credentials.json").write_text(
            json.dumps({"claudeAiOauth": {"accessToken": token, "subscriptionType": sub_type}})
        )
    return tree
