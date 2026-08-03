# agent-hud

A macOS menu-bar readout for the two things that decide whether a working day
goes well: how much subscription quota is left across Claude and Codex, and
whether the shared agent setup in `~/.agents` is still healthy.

It is read-only. Nothing in here mutates the machine; the worst it can do is
tell you to go run something yourself.

Two halves:

- **`agenthud serve`** — a resident Python daemon that polls subscription usage
  and live agent activity, folds them into one snapshot, writes it atomically to
  `~/.cache/agenthud/hud.json`, and serves it on `http://127.0.0.1:8737/v1/hud`.
  Standard library only, so it runs against a bare `python3`.
- **`hud/`** — a SwiftPM package holding `HUDCore` (the contract structs, theme
  tokens, formatting helpers, and SwiftUI views) and `agenthud-hud`, the thin
  AppKit menu-bar shell that renders them.

This is a fork of [agent-dash](https://github.com/josephtutera/agent-dash),
which paired the same daemon with a terminal TUI. The TUI is gone; the daemon
and the HUD came across intact.

## Run it

```sh
cd hud
swift build -c release
swift run agenthud-hud          # menu-bar app, no dock icon
```

Launching the app is all it takes: it checks whether a daemon is already
answering on the loopback port and starts `python3 main.py serve` itself if not,
stopping it again on quit. To run the daemon on its own instead:

```sh
python3 main.py serve           # --host / --port to move it
```

## Install it as an app

```sh
cd hud
./build-app.sh --install        # builds AgentHUD.app and copies it to /Applications
```

The bundle records this checkout's path in `AHDaemonRoot`, so an installed copy
still finds the daemon as long as the checkout stays put. Add it under System
Settings > General > Login Items to have it start with the machine.

## Preview render (the review artifact)

The card renders headlessly to a PNG from a committed fixture snapshot, so a
reviewer can see the UI without running the menu bar:

```sh
swift run agenthud-hud --render-preview preview.png
swift run agenthud-hud --render-preview-light preview-light.png
swift run agenthud-hud --render-preview-menubar preview-menubar.png
```

## Tests

```sh
cd hud && swift test            # HUDCore: decoding, formatting, derivations, render smoke
python3 -m pytest tests         # the daemon: collectors, usage, pricing, snapshot, HTTP
```

## Where things live

| Path | What it is |
|---|---|
| `serve.py` | the daemon: polling, snapshot assembly, atomic write, loopback HTTP |
| `usage.py` | Claude usage over OAuth (with Keychain token refresh and 429 backoff), Codex from rollout files, OpenCode spend |
| `pricing.py` | what the same usage would have cost at published API rates |
| `agents.py` / `activity.py` | which agent sessions are running, and what each is doing |
| `collectors.py` / `models.py` | the shared session model the collectors are built on |
| `docs/hud-schema.md` | the frozen snapshot contract the Swift app decodes |
| `hud/Sources/HUDCore` | contract structs, theme, formatting, and every SwiftUI view |
| `hud/Sources/agenthud-hud` | the AppKit shell: status item, panel, daemon launcher |

## Safety

The HTTP API has no authentication and permissive CORS, so it refuses to bind
anything but loopback unless `AGENTHUD_SERVE_ALLOW_REMOTE=1` is set. No
credentials, tokens, or paths beyond an agent's working directory ever reach the
snapshot.
