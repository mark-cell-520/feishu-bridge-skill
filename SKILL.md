---
name: feishu-bridge
description: >
  飞书 ↔ Claude Code 桥接服务管理技能。提供一键安装、配置、启动、状态检查，
  以及桥接健康监控能力。自动与 HeartFlow 心虫判别引擎集成，对飞书消息做输入/输出双门禁监督。
whenToUse: >
  当用户需要管理飞书桥接服务时使用：安装/启动/停止/重启/查看状态/更新/卸载。
  当用户需要配置飞书应用、检查桥接健康、或排查飞书消息收发故障时使用。
metadata:
  version: "1.0.0"
  author: "yun520-1"
  platform: "feishu"
  category: "integration"
  runtime: "feishu-bridge"
  runtimeVersion: "2026.6.20.12"
---

# 飞书桥接服务（Feishu Bridge）管理技能

> **v1.0.0** — 管理飞书 ↔ Claude Code 桥接服务 + HeartFlow 心虫监督

## 快速开始（一条命令）

```bash
bash scripts/install.sh
```

安装脚本自动完成：
1. ✅ 检查依赖（`python3` / `node` / `pip`）
2. 📦 安装/升级 `feishu-bridge` Python 包
3. ⚙️ 引导配置飞书应用凭证（`FEISHU_APP_ID` + `FEISHU_APP_SECRET`）
4. 🚀 启动桥接服务（launchd 后台守护进程）
5. ✅ 健康检查验证

## 桥接架构

```
飞书用户发消息
  → 飞书官方 WebSocket 长连接（im.message.receive_v1）
  → Claude Code 子进程（--mcp-config / --settings）
  → HeartFlow 心虫判别（输入 checkInput + 输出 checkOutput）
  → 飞书 API 回复
```

**关键特性**：
- 官方 WebSocket 长连接（非 webhook）
- 自动重连 + 消息去重 + 会话保持
- HeartFlow 47 维判别门禁（输入拦截 + 输出监督）
- MCP 工具扩展（web-search / heartflow / 其他）
- 多 bot 支持（`--bot claude-code`）

## 目录结构

```
feishu-bridge-skill/
├── SKILL.md              # 本文档
├── scripts/
│   ├── install.sh        # 一键安装 + 配置 + 启动
│   ├── setup.sh          # 交互式配置（换应用 / 迁移凭证）
│   ├── start-bridge.sh   # 启动桥接服务
│   ├── stop-bridge.sh    # 停止桥接服务
│   ├── status.sh         # 服务状态检查
│   └── health-check.sh   # 健康检查
├── references/
│   ├── config.md         # 配置参考（config.json / .env）
│   ├── troubleshooting.md # 故障排查
│   └── architecture.md   # 架构详细说明
├── templates/
│   └── config.json       # 配置模板
└── .gitignore
```

## 常用命令

```bash
# 一键安装
bash scripts/install.sh

# 重新配置（换新应用）
bash scripts/setup.sh

# 启动服务
bash scripts/start-bridge.sh

# 停止服务
bash scripts/stop-bridge.sh

# 查看状态
bash scripts/status.sh

# 健康检查
bash scripts/health-check.sh
# → {"ok": true, "feishuApp": "cli_xxx...", "sessions": N, ...}
```

## 配置

### 环境变量（.env）

| 变量 | 必填 | 说明 |
|------|------|------|
| `FEISHU_APP_ID` | ✅ | 飞书应用 App ID（`cli_` 开头） |
| `FEISHU_APP_SECRET` | ✅ | 飞书应用 App Secret |
| `FEISHU_DOMAIN` | ❌ | 域名：`feishu`（国内）或 `lark`（国际），默认 `feishu` |

### 配置文件（config.json）

位置：`~/.config/feishu-bridge/config.json`

```json
{
  "bots": [
    {
      "name": "claude-code",
      "app_id": "${FEISHU_APP_ID}",
      "app_secret": "${FEISHU_APP_SECRET}",
      "workspace": "/Users/apple/.local/share/feishu-bridge/workspaces/claude-code",
      "allowed_users": ["*"]
    }
  ],
  "agent": {
    "type": "claude",
    "command": "claude",
    "timeout_seconds": 300,
    "args": [
      "--mcp-config",
      "/Users/apple/.local/share/feishu-bridge/workspaces/claude-code/.claude/.mcp.json"
    ]
  }
}
```

### HeartFlow 集成

桥接服务通过 MCP 配置自动集成 HeartFlow 心虫判别引擎：

```json
{
  "mcpServers": {
    "heartflow": {
      "command": "/opt/homebrew/bin/node",
      "args": ["/Users/apple/.claude/skills/mark-heartflow-skill/mcp/mcp-server-stdio.js"],
      "description": "HeartFlow 心虫认知判别引擎（v6.7.47 stdio 模式）"
    },
    "web-search": {
      "command": "/opt/homebrew/bin/python3",
      "args": ["/Users/apple/.local/share/feishu-bridge/workspaces/claude-code/.claude/mcp-servers/web_search.py"],
      "description": "网页搜索（Bing，无需 API Key）"
    }
  }
}
```

## 心虫监督

桥接内置 HeartFlow 判别门禁：

| 检查 | 时机 | 动作 |
|------|------|------|
| `heartflow_checkInput` | 用户消息进入时 | `block` → 拦截并告知原因 |
| `heartflow_checkOutput` | AI 回复发出前 | `block` → 不发送；`rewrite` → 标注风险后发送；`pass` → 正常发送 |

## 服务管理

### launchd 守护进程

桥接服务通过 macOS launchd 管理：

```bash
# 加载服务
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.heartflow.mcp.plist

# 卸载服务
launchctl bootout gui/$(id -u)/com.heartflow.mcp

# 查看状态
launchctl list | grep heartflow
```

### 日志

```bash
# 桥接日志
tail -f ~/.local/share/feishu-bridge/workspaces/claude-code/state/feishu-bridge/*.log

# HeartFlow 日志
tail -f ~/.claude/logs/heartflow*.log
```

## 故障排查

常见问题请参见 [references/troubleshooting.md](references/troubleshooting.md)。

## 版本

- **技能版本**: 1.0.0
- **运行时**: feishu-bridge 2026.6.20.12
- **HeartFlow**: v6.7.47

## 许可证

MIT © yun520-1
