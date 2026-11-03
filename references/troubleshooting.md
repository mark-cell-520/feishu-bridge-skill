# 故障排查

按"本机实测过"排序，不是按常见度猜的。2026-10-13 首版核对，2026-11-03 复校：
第 9 条已从"要改上游代码"更新为指向现成的 `patch-ui.sh` 补丁。

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
不是配置问题。

已定位到 `feishu_bridge/ui.py` 的 `_render_agent_progress`，并有现成补丁：

```bash
bash scripts/patch-ui.sh status   # 看是否已打
bash scripts/patch-ui.sh apply    # 打上（自动备份、可 revert）
bash scripts/restart-bridge.sh    # 重启生效
```

打之前先想清楚：这个元素每次更新都被拒，卡片上那个位置本来就是空的，
所以禁掉的是注定失败的请求，不是能用的功能；真正承载回复正文的
`streaming_output` 不走这个函数。补丁会被 pip 升级覆盖，`upgrade.sh` 会提醒重打。

### 同族的 code=300309 不需要单独补丁

`Element update failed (...): code=300309 msg=ErrMsg: streaming mode is closed`
看着和上面同源，其实是另一回事：流式窗口已经关了，桥接还在发更新请求。
本机日志里它累计出现过 1846 次（960 次 streaming_output、886 次 agent_status），
全天候分布，不是某个时段的问题。

排查结论（2026-11-03 实测）：

1. 它不丢内容。每一次 300309 之后都紧跟一条
   `INFO Deliver: content_len=... is_error=False cardkit=True`，
   正文由最终投递保证，失败的只是流式途中的增量更新。
2. 它已经被现有补丁解决。patch-ui 与 patch-tool-list 应用之后
   （本机 10:21）至今，300309 出现 0 次。之前那 1846 次全部产生于
   补丁应用之前，是历史包袱，不是现存故障。
3. 所以不要再为它写第四个补丁。判断方法：以补丁应用时刻为界切分日志，
   增量是 0 就不必动手；只看累计数会反复去修一个已经好了的问题。

`diagnose.sh` 的 `err_log_top` 报的就是这种累计值，看那个数字会误导。

## 10. 单轮越来越慢，最后按分钟计

**症状**：同一会话连续聊一段时间后，每轮从几秒变成几分钟。
日志里能看到 ctx 一路涨：

```
Idle auto-compact firing: sid=199ccc6d ctx=459542 tokens
```

**根因**：`worker.py` 的 `IdleCompactManager` 每轮成功后起一个
50 分钟定时器，下一轮 `touch()` 会 cancel 旧定时器再起新的。
两轮间隔小于 50 分钟，定时器永远被取消，compact 永远不触发。
那 50 分钟的设计意图是省钱（prompt cache TTL 1 小时，趁热 compact
按 cache_read 计价），没有覆盖密集连续对话这条路径。
ctx 于是涨到几十万 token，每轮 `--resume` 全量重放。

**先确认是不是这个问题**：

```bash
grep "Idle auto-compact firing" ~/.local/share/feishu-bridge/logs/bridge.err.log | tail -3
```

看 ctx 那一栏的数值。低于 5 万不是这个问题。

**处置**：

1. 立即见效：发 `/new` 开新会话（丢上下文，但马上快）
2. 保住上下文：`/compact` 做一次定向压缩，摘要质量比自动压缩好
3. 结构性修复：`bash scripts/patch-ctx-compact.sh apply`，
   给 ctx 加硬上限（默认 15 万 token），超限 15 秒后入队压缩，
   不等空闲；原有 50 分钟省钱路径不动。改完需重启桥接。

阈值可用环境变量调：`FEISHU_BRIDGE_CTX_LIMIT`（token 数）、
`FEISHU_BRIDGE_CTX_DELAY`（秒）。两个值解析失败或越界都退回默认，
不会因为拼错环境变量让桥接起不来。

## 日志位置

| 日志 | 位置 |
|---|---|
| 桥接 stdout | `~/.local/share/feishu-bridge/logs/bridge.log` |
| 桥接 stderr | `~/.local/share/feishu-bridge/logs/bridge.err.log` |
| 会话记录 | `~/.local/share/feishu-bridge/workspaces/claude-code/state/feishu-bridge/sessions-*.json` |
| 启发式日志 | `~/.local/share/feishu-bridge/workspaces/claude-code/state/feishu-bridge/heuristic-log-*.jsonl` |
| 部署副本设置 | `~/.feishu-bridge/bridge-settings.json`（会被覆盖，见第 2 条） |
| 控制套接字 | `~/.feishu-bridge/control-claude-code.sock` |
