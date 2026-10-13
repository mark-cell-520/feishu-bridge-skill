# 架构说明

2026-10-13 按本机实况重写。上游 1.0.0 的图里画了 HeartFlow MCP 判别层，
并写了具体的 PID（25323 / 49314）——那个层在本机不存在，PID 是某次运行的快照，
两者都已移除。

## 整体架构（本机实际形态）

```
飞书用户
  │ 发送消息
  ▼
飞书官方 WebSocket 长连接（lark-oapi）
  · im.message.receive_v1 事件
  · 自动重连
  ▼
feishu-bridge（Python，launchd 守护）
  · 消息标准化 / 去重
  · allowed_users 白名单
  · ChatTaskQueue 排队（按 chat 串行）
  │ 每消息拉起子进程
  ▼
claude（Claude Code CLI）
  · cwd = <workspace>
  · 读该处 CLAUDE.md
  · 无 MCP（本机未配置 .mcp.json）
  │ 回复文本
  ▼
飞书 API 发送回复
  · 文本消息
  · CardKit 流式卡片（agent_status 元素，见 troubleshooting 第 9 条）
```

## 核心组件

### 1. 飞书 WebSocket 连接

用飞书官方 SDK `lark-oapi`，长连接模式（非 webhook），自动重连。

### 2. 消息处理流水线

```
接收 → 去重 → 标准化 → 白名单验证 → 入队 → 子进程调用 → 回复发送
```

队列按 chat 串行，所以同一会话的多条消息不会并发打到 claude。
`health-check.sh` 的 `queuePending` 就是这个队列的待处理深度。

### 3. 判别门禁 —— 本机未启用

上游 1.0.0 宣传的"HeartFlow 47 维判别门禁（输入 checkInput + 输出 checkOutput）"
在本机**没有接线**。核查结果（2026-10-13）：

1. `<workspace>/.claude/.mcp.json` 不存在
2. `<workspace>/.claude/mcp-servers/` 目录不存在
3. `~/.claude/skills/mark-heartflow-skill` 不存在
4. `config.json` 的 `agent.args` 里没有 `--mcp-config`

也就是说，飞书消息进出的路上**没有任何判别层**。
桥接做的是投递，不是审查。要加判别层见 troubleshooting 第 8 条。

### 4. 进程结构

```
launchd (com.feishu.bridge, KeepAlive)
  └─ /bin/bash ~/.local/share/feishu-bridge/start-bridge.sh   ← 包装器，source .env
      └─ feishu-bridge (Python)
          ├─ 控制套接字 ~/.feishu-bridge/control-claude-code.sock
          └─ 按需拉起: claude (Claude Code CLI)
```

包装器那一层不是可选装饰：没有它，`feishu-bridge` 读不到 `.env`，
直接 `Unresolved env vars in config` 退出，launchd 再 KeepAlive 重启，
陷入循环。这是本机排障第一课。

### 5. 管理接口

Unix socket + 换行分隔 JSON，token 在
`~/.feishu-bridge/control-claude-code.token`。

```
{"id":1,"token":"<token>","method":"status","params":{}}
```

方法：health / status / config / sessions / quota / logs / tasks /
set_model / set_agent / set_provider / stop_session / shutdown。
详见 `feishu_bridge/control_api.py`。
