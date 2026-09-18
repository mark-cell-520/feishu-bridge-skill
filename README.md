# feishu-bridge

[中文](README.zh.md) | English

## Overview

`feishu-bridge` is a Claude Code skill that manages the **Feishu ↔ Claude Code bridge service**.

It provides:
- One-command installation (`bash scripts/install.sh`)
- Service management (start/stop/restart/status)
- Feishu app configuration (QR code guided setup)
- HeartFlow integration (input/output gatekeeping)
- Health monitoring

## Quick Start

```bash
cd feishu-bridge-skill
bash scripts/install.sh
```

## Features

- ✅ Official WebSocket long connection
- ✅ Auto-reconnect + message deduplication
- ✅ HeartFlow 47-dimension discrimination gate
- ✅ MCP tools expansion
- ✅ Multi-bot support

## Requirements

- macOS (launchd)
- Python 3.14+
- Node.js (for HeartFlow MCP)
- Feishu app (App ID + App Secret)

## Documentation

- [Configuration](references/config.md)
- [Troubleshooting](references/troubleshooting.md)
- [Architecture](references/architecture.md)

## License

MIT © yun520-1
