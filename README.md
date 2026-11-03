# feishu-bridge-skill

A Claude Code skill for managing the **Feishu ↔ Claude Code bridge service**:
install, configure, start, stop, status, and health monitoring.

[中文](README.zh.md) | English

> v2.22.1 (2026-11-03) — current.
>
> History: v1.0.0 contained hardcoded `/Users/apple/...` paths, wrong log
> filenames (`bridge-stdout.log` / `bridge-stderr.log`), a wrong launchd label
> (`com.heartflow.mcp`), and an entire HeartFlow discrimination-gate feature
> that is not wired up on this machine. v1.1.0 (2026-10-13) rewrote the skill
> line-by-line against a live instance and fixed all of it. v2.0.0 onward made
> the whole thing cross-platform and added diagnostics, a watchdog, perf
> metrics, a safe upgrade path, and the `ui.py` / `main.py` patches.
> Full history: `git log`.

## Overview

`feishu-bridge` is a Claude Code skill that manages the Feishu long-connection
bridge on macOS / Linux / Windows: Feishu messages arrive over WebSocket, a `claude`
CLI subprocess is spawned to handle them, and the reply is sent back to Feishu.

It provides:

- One-command install (`bash scripts/install.sh`)
- Cross-platform: macOS (launchd) / Linux (systemd --user) / Windows (foreground or Task Scheduler)
- Service management (start / stop / restart / status)
- One-shot diagnostics (`diagnose.sh`, human or `--json`) — platform, service, config, permissions, log health, Feishu API reachability, control socket, media dirs
- Multi-workspace / multi-environment profiles (`ws.sh`)
- Safe upgrade (`upgrade.sh`) that re-applies the permission patch pip would revert
- Watchdog (`watchdog.sh`): three-layer health check (process / control socket /
  log freshness) that catches the "alive but not serving" state KeepAlive cannot see,
  with a cooldown to prevent restart storms
- Fluency & performance metrics (`perf.sh`): end-to-end latency percentiles,
  streaming-card failure rate, log noise ratio (`logs.sh`) with error aggregation — a single repeated warning shows once with a count
- Cross-platform delivery (`send.py` core + `send.sh` / `send.ps1`)
- Feishu app configuration (CLI wizard, secret not echoed)
- Health monitoring via the bridge's own control socket — real session count and
  queue depth, not a probe against an HTTP port nothing listens on

## Quick Start

```bash
cd feishu-bridge-skill
bash scripts/install.sh
```

## Commands

```bash
bash scripts/install.sh              # one-command install
bash scripts/setup.sh                # reconfigure (switch app)
bash scripts/start-bridge.sh         # start (writes plist / unit and loads it)
bash scripts/stop-bridge.sh          # stop
bash scripts/status.sh               # human-readable status
bash scripts/health-check.sh         # JSON health check
bash scripts/diagnose.sh             # one-shot diagnostics report
bash scripts/restart-bridge.sh       # restart + verify patches took effect
bash scripts/ws.sh list              # multi-workspace profiles
bash scripts/upgrade.sh              # smooth upgrade (re-applies patches)
bash scripts/logs.sh errors          # error aggregation
bash scripts/perf.sh                 # fluency & performance report
bash scripts/watchdog.sh --once      # single health check
bash scripts/patch-ui.sh status      # optional patch status
bash scripts/patch-post-image.sh status   # image-in-post fix status
bash scripts/patch-tool-list.sh status    # numbered tool list status
bash scripts/patch-ctx-compact.sh status  # ctx hard limit forces compact
bash scripts/setup-format-rule.sh status  # output format rule injection status
bash scripts/send.sh text "message" # deliver to the current Feishu chat
```

## Features

- ✅ Official Feishu WebSocket long connection (not webhook)
- ✅ Auto-reconnect + message dedup + per-chat serial queue
- ✅ Real health probe: Unix-socket control API, not a dead HTTP port
- ✅ Log names, launchd label, and paths all verified against a live install
- ✅ Cross-platform service units: launchd (macOS), systemd --user (Linux),
  foreground / Task Scheduler (Windows)
- ✅ Patches for three upstream defects that cannot be configured away
  (see SKILL.md), each with automatic backup and revert

## Verified Environment (2026-11-03)

| Item | Value |
|---|---|
| launchd label | `com.feishu.bridge` |
| Python | 3.11.17 |
| Runtime | feishu-bridge 2026.6.20.12 |
| Logs | `logs/bridge.log`, `logs/bridge.err.log` |
| Discrimination gate | not enabled |
| MCP | not configured |
| Platforms | macOS 27 verified live; Linux / Windows adapted, not run on-device |

## Requirements

- macOS (launchd), Linux (systemd --user), or Windows (foreground / Task Scheduler)
- Python 3.11+ (3.11.17 verified; the 3.14+ in v1.0.0 was wrong and has been dropped)
- A Feishu app (App ID + App Secret)
- `node` only if you build your own MCP tools — the bridge itself does not need it

## Documentation

- [SKILL.md](SKILL.md) — main doc, including "three gotchas you must remember"
  and the v1.0.0 → v1.1.0 changelog
- [Configuration](references/config.md)
- [Troubleshooting](references/troubleshooting.md)
- [Architecture](references/architecture.md)
- [Platforms & environments](references/platforms.md)

## License

MIT © yun520-1
