# feishu-bridge-skill

A Claude Code skill for managing the **Feishu ↔ Claude Code bridge service**:
install, configure, start, stop, status, and health monitoring.

[中文](README.zh.md) | English

> v1.1.0 (2026-10-13) — rewritten after line-by-line verification against a live
> instance. v1.0.0 contained hardcoded `/Users/apple/...` paths, wrong log
> filenames (`bridge-stdout.log` / `bridge-stderr.log`), a wrong launchd label
> (`com.heartflow.mcp`), and an entire HeartFlow discrimination-gate feature
> that is not wired up on this machine. Full changelog at the end of
> [SKILL.md](SKILL.md).

## Overview

`feishu-bridge` is a Claude Code skill that manages the Feishu long-connection
bridge under macOS launchd: Feishu messages arrive over WebSocket, a `claude`
CLI subprocess is spawned to handle them, and the reply is sent back to Feishu.

It provides:

- One-command install (`bash scripts/install.sh`)
- Service management (start / stop / restart / status)
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
bash scripts/start-bridge.sh         # start (writes plist and loads it)
bash scripts/stop-bridge.sh          # stop
bash scripts/status.sh               # human-readable status
bash scripts/health-check.sh         # JSON health check
```

## Features

- ✅ Official Feishu WebSocket long connection (not webhook)
- ✅ Auto-reconnect + message dedup + per-chat serial queue
- ✅ Real health probe: Unix-socket control API, not a dead HTTP port
- ✅ Log names, launchd label, and paths all verified against a live install

## Verified Environment (2026-10-13)

| Item | Value |
|---|---|
| launchd label | `com.feishu.bridge` |
| Python | 3.11.15 |
| Runtime | feishu-bridge 2026.6.20.12 |
| Logs | `logs/bridge.log`, `logs/bridge.err.log` |
| Discrimination gate | not enabled |
| MCP | not configured |

## Requirements

- macOS (launchd)
- Python 3.11+ (3.11.15 verified; the 3.14+ in v1.0.0 was wrong and has been dropped)
- A Feishu app (App ID + App Secret)
- `node` only if you build your own MCP tools — the bridge itself does not need it

## Documentation

- [SKILL.md](SKILL.md) — main doc, including "three gotchas you must remember"
  and the v1.0.0 → v1.1.0 changelog
- [Configuration](references/config.md)
- [Troubleshooting](references/troubleshooting.md)
- [Architecture](references/architecture.md)

## License

MIT © yun520-1
