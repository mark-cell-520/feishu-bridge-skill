# 配置参考

## 目录

- [环境变量 (.env)](#环境变量)
- [配置文件 (config.json)](#配置文件)
- [MCP 配置](#mcp-配置)
- [launchd 配置](#launchd-配置)

## 环境变量

位置：`~/.config/feishu-bridge/.env`

```bash
FEISHU_APP_ID=cli_xxxxxxxxxxxxxxxx
FEISHU_APP_SECRET=xxxxxxxxxxxxxxxx
FEISHU_DOMAIN=feishu  # 或 lark（国际版）
```

## 配置文件

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

## MCP 配置

位置：`<workspace>/.claude/.mcp.json`

```json
{
  "mcpServers": {
    "heartflow": {
      "command": "/opt/homebrew/bin/node",
      "args": ["/Users/apple/.claude/skills/mark-heartflow-skill/mcp/mcp-server-stdio.js"],
      "description": "HeartFlow 心虫认知判别引擎"
    },
    "web-search": {
      "command": "/opt/homebrew/bin/python3",
      "args": ["<bridge-workspace>/.claude/mcp-servers/web_search.py"],
      "description": "网页搜索"
    }
  }
}
```

## launchd 配置

位置：`~/Library/LaunchAgents/com.feishu.bridge.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.feishu.bridge</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/apple/.venv-feishu-bridge/bin/python3</string>
        <string>/Users/apple/.venv-feishu-bridge/bin/feishu-bridge</string>
        <string>--config</string>
        <string>/Users/apple/.config/feishu-bridge/config.json</string>
        <string>--bot</string>
        <string>claude-code</string>
        <string>--log-level</string>
        <string>INFO</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>WorkingDirectory</key>
    <string>/Users/apple/.local/share/feishu-bridge</string>
</dict>
</plist>
```
