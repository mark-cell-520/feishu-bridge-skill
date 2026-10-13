# 故障排查

按"本机实测过"排序，不是按常见度猜的。2026-10-13 核对。

## 0. 先跑这两个，别凭猜

```bash
bash scripts/status.sh        # launchd 状态 + 配置 + 日志新鲜度 + 权限副本
bash scripts/health-check.sh  # JSON，走控制套接字拿真实会话数/队列深度
```

`health-check.sh` 输出里的 `probe` 字段说明数据从哪来：

1. `control-socket` — 真实探针，最可信
2. `state-file-fallback` — 套接字不可用，退化成数会话状态文件里的 chat 数
3. `launchd-only` — 连状态文件都没有，只确认服务在跑

## 1. 服务起不来，日志里是 Unresolved env vars

**症状**：`bridge.err.log` 里
`Unresolved env vars in config: ['FEISHU_APP_ID', 'FEISHU_APP_SECRET']`，进程退出。

**原因**：plist 直拉了 `feishu-bridge` 二进制，而那个入口不读 `.env`。

**解法**：确认 plist 的 `ProgramArguments` 指向包装器：

```bash
/usr/libexec/PlistBuddy -c "Print :ProgramArguments" \
  ~/Library/LaunchAgents/com.feishu.bridge.plist
# 应该是 ["/bin/bash", "/Users/<你>/.local/share/feishu-bridge/start-bridge.sh"]
```

不是这个形态就跑 `bash scripts/start-bridge.sh` 重写 plist，
或手工把包装器补回来：

```bash
cp scripts/start-bridge-wrapper.sh ~/.local/share/feishu-bridge/start-bridge.sh
chmod +x ~/.local/share/feishu-bridge/start-bridge.sh
```

## 2. 权限设置改了不生效

**症状**：往 `~/.feishu-bridge/bridge-settings.json` 里加 deny 规则，
重启桥接后规则消失。

**原因**：`runtime.py` 的 `materialize_data_files()` 每次启动都
`shutil.copy2` 包内那份覆盖过来，无存在性判断。

**解法**：改包内权威源，不是部署副本：

```bash
$HOME/.venv-feishu-bridge/lib/python3.11/site-packages/feishu_bridge/data/bridge-settings.json
```

改完重启。注意 `pip install --upgrade feishu-bridge` 会把包内那份也还原，
升级后要重打。

## 3. 机器人无响应

```bash
launchctl list | grep feishu.bridge                      # 在不在跑
cat ~/.config/feishu-bridge/.env                         # 凭证在不在
tail -50 ~/.local/share/feishu-bridge/logs/bridge.err.log # 真实错误日志
```

**可能原因**：

1. 应用未发布（飞书开放平台要发布版本）
2. 事件订阅没启用 `im.message.receive_v1`（长连接模式）
3. 凭证无效 → `bash scripts/setup.sh` 重配
4. claude 找不到 → 看 `bridge.err.log` 里有没有 spawn 失败；
   plist 的 PATH 缺 `~/.npm-global/bin` 时会这样

## 4. 日志文件"不存在"或 tail 不到新内容

**症状**：`tail -f ~/.local/share/feishu-bridge/logs/bridge-stdout.log` 没输出。

**原因**：真实文件名是 `bridge.log` 和 `bridge.err.log`。
上游 1.0.0 的脚本全写的 `bridge-stdout.log` / `bridge-stderr.log`，那两个文件从不被创建。

```bash
tail -f ~/.local/share/feishu-bridge/logs/bridge.err.log
tail -f ~/.local/share/feishu-bridge/logs/bridge.log
```

## 5. launchctl bootout 静默失败

下面这条**是错的样子**，别用（标签不存在，命令返回 0 但什么都没发生）：

```bash
launchctl bootout gui/$(id -u)/com.heartflow.mcp    # ❌ 错标签
```

正确的是：

```bash
launchctl bootout gui/$(id -u)/com.feishu.bridge    # ✅
```

或者直接 `bash scripts/stop-bridge.sh`。

## 6. 消息重复

桥接有去重。若仍重复：

```bash
wc -l ~/.local/share/feishu-bridge/workspaces/claude-code/state/feishu-bridge/*.jsonl
```

## 7. 连接频繁断开

1. 看网络稳定性
2. 看飞书应用配额（`health-check.sh` 的 `quotaDataAvailable`）
3. `bridge.err.log` 里 ws reconnect 的频率

## 8. 想给 claude 加 MCP 工具

本机当前**没有**接任何 MCP：workspace 下没有 `.mcp.json`，
没有 `mcp-servers/` 目录，`config.json` 的 `agent.args` 里也没有 `--mcp-config`。
桥接本身不依赖 MCP，纯文本收发不受影响。

要启用的话：建 `<workspace>/.claude/.mcp.json`，写清服务器绝对路径，
再在 `config.json` 的 `agent.args` 里加回 `--mcp-config <该文件>`。
上游 1.0.0 提到的 `mark-heartflow-skill` 与 HeartFlow 门禁在本机不存在
（`~/.claude/skills/` 下没有这个目录），别照它的路径抄。

## 9. 流式卡片报 field validation failed

`bridge.err.log` 里成片的
`Element update failed (agent_status): code=99992402 msg=field validation failed`
是 CardKit 元素更新被飞书拒。本机 2026-10-13 实测：连续 10 次后桥接自己会打
`streaming/agent_status may be stalled` 警告。不影响消息正文投递，
但状态栏不更新。这是飞书侧 schema 与桥接发的字段不匹配，
需要改 `feishu_bridge` 里构造 agent_status 元素的代码，不是配置问题。

## 日志位置

| 日志 | 位置 |
|---|---|
| 桥接 stdout | `~/.local/share/feishu-bridge/logs/bridge.log` |
| 桥接 stderr | `~/.local/share/feishu-bridge/logs/bridge.err.log` |
| 会话记录 | `~/.local/share/feishu-bridge/workspaces/claude-code/state/feishu-bridge/sessions-*.json` |
| 启发式日志 | `~/.local/share/feishu-bridge/workspaces/claude-code/state/feishu-bridge/heuristic-log-*.jsonl` |
| 部署副本设置 | `~/.feishu-bridge/bridge-settings.json`（会被覆盖，见第 2 条） |
| 控制套接字 | `~/.feishu-bridge/control-claude-code.sock` |
