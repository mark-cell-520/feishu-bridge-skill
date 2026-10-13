# 配置参考

本文件的每一条路径、每一个文件名都在 2026-10-13 的本机实况上核对过。
上游 1.0.0 版里那些 `/Users/apple/...` 是另一台机器的绝对路径，已全部改为 `$HOME` 派生。

## 目录

- [环境变量 (.env)](#环境变量)
- [配置文件 (config.json)](#配置文件)
- [launchd 配置](#launchd-配置)
- [权限设置（bridge-settings.json）](#权限设置bridge-settingsjson)
- [控制套接字](#控制套接字)

## 环境变量

位置：`~/.config/feishu-bridge/.env`

```bash
FEISHU_APP_ID=cli_xxxxxxxxxxxxxxxx
FEISHU_APP_SECRET=xxxxxxxxxxxxxxxx
FEISHU_DOMAIN=feishu  # 或 lark（国际版）
```

### 谁读这个文件——本机最大的坑

| 入口 | 读 `.env`？ |
|---|---|
| `feishu-cli`（`feishu_bridge/cli.py`） | ✅ 读，用 `os.environ.setdefault` |
| `feishu-bridge`（`feishu_bridge/main.py`） | ❌ 不读，只读 `os.environ` |

`main.py` 的 `load_config` 从 `os.environ` 取 `${FEISHU_APP_ID}` 这类占位符，
取不到就 `log.error("Unresolved env vars in config: ...")` 然后退出。
**launchd 直拉二进制必然起不来**，这就是必须有启动包装器的原因。
这个不对称在包的文档里没有任何说明，是排障踩出来的。

## 配置文件

位置：`~/.config/feishu-bridge/config.json`

```json
{
  "bots": [
    {
      "name": "claude-code",
      "app_id": "${FEISHU_APP_ID}",
      "app_secret": "${FEISHU_APP_SECRET}",
      "workspace": "$HOME/.local/share/feishu-bridge/workspaces/claude-code",
      "allowed_users": ["*"]
    }
  ],
  "agent": {
    "type": "claude",
    "command": "$HOME/.npm-global/bin/claude",
    "timeout_seconds": 300,
    "args": ["--permission-mode", "bypassPermissions"]
  }
}
```

三点注意：

1. `app_id` / `app_secret` 写 `${FEISHU_APP_ID}` 占位符，由包装器 source 过 `.env` 后展开。
2. `agent.command` 建议写 claude 的**绝对路径**。写裸 `claude` 也能跑，
   但要求 launchd plist 的 PATH 里含有 claude 所在目录（见下）。
3. `agent.args` 本机实际是 `["--permission-mode", "bypassPermissions"]`。
   上游 1.0.0 写的 `--mcp-config <workspace>/.claude/.mcp.json` **在本机不存在**：
   那个文件没有，`mcp-servers/` 目录没有，`.claude/` 下只有 `scheduled_tasks.json`。
   要启用 MCP 得自己建 `.mcp.json` 并在这里加回 `--mcp-config`。

## launchd 配置

位置：`~/Library/LaunchAgents/com.feishu.bridge.plist`
Label 是 `com.feishu.bridge`。上游 1.0.0 的 SKILL.md 里写的 `com.heartflow.mcp` 是错的，
照它执行 `launchctl bootout gui/$(id -u)/com.heartflow.mcp` 会静默失败（目标不存在）。

**正确形态（本机实况）**：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.feishu.bridge</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$HOME/.local/share/feishu-bridge/start-bridge.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>WorkingDirectory</key>
    <string>$HOME/.local/share/feishu-bridge</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>StandardOutPath</key>
    <string>$HOME/.local/share/feishu-bridge/logs/bridge.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/.local/share/feishu-bridge/logs/bridge.err.log</string>
</dict>
</plist>
```

三个要点，都是上游写错或没写的：

1. **ProgramArguments 必须指向包装器**（`/bin/bash` + `start-bridge.sh`），
   不能指向 `$VENV/bin/feishu-bridge`。原因见上一节。
2. **PATH 必须含 claude 所在目录**。上游的 PATH 是
   `/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`，不含 `~/.npm-global/bin`，
   于是 `agent.command: "claude"` 会找不到。本机 PATH 前面加了
   `~/.local/bin:~/.npm-global/bin`。
3. **日志文件名是 `bridge.log` / `bridge.err.log`**，不是 `bridge-stdout.log` /
   `bridge-stderr.log`。上游四个脚本全写错了后两个名字，
   结果 `status.sh` 永远走"日志目录不存在/文件不存在"分支，
   `tail -f` 跟的是一个从不增长的文件。

## 权限设置（bridge-settings.json）

两份，别改错：

| 路径 | 角色 |
|---|---|
| `$VENV/lib/python3.11/site-packages/feishu_bridge/data/bridge-settings.json` | 权威源 |
| `~/.feishu-bridge/bridge-settings.json` | 部署副本，**每次启动被无条件覆盖** |

覆盖逻辑在 `feishu_bridge/runtime.py` 的 `materialize_data_files()`：
`shutil.copy2` 没有任何存在性判断，桥接每次启动都会把包内那份重新拷过去。
所以**改部署副本是白改**——不只是"pip 升级后会还原"，下次启动就还原。
本机当前状态：`defaultMode = bypassPermissions`，`allow` / `deny` 均为空。

## 控制套接字

桥接自带一个 Unix socket 管理接口，比任何 HTTP 探针都可靠：

- `~/.feishu-bridge/control-claude-code.sock`
- `~/.feishu-bridge/control-claude-code.token`（0600）

协议：换行分隔 JSON，一次连接一行请求一行响应。

```json
{"id": 1, "token": "<token 文件内容>", "method": "status", "params": {}}
```

方法表见 `feishu_bridge/control_api.py`：
`health` / `status` / `config` / `sessions` / `quota` / `logs` / `tasks` /
`set_model` / `set_agent` / `set_provider` / `stop_session` / `shutdown`。

注意 `health` 只返回 `{"ok": true}`，不验证任何东西；有信息量的是 `status`
（会话数、队列深度、配额）。上游 `status.sh` 里的
`curl http://127.0.0.1:8090/health` 打的是一个**根本没有监听**的端口，
所以那个健康检查从来没通过过。本技能的 `health-check.sh` 已改为走这个套接字。
