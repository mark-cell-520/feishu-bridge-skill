# 故障排查

## 常见问题

### 1. 机器人无响应

**检查清单**：
```bash
# 服务是否运行
launchctl list | grep feishu.bridge

# 配置是否存在
cat ~/.config/feishu-bridge/.env

# 查看日志
tail -50 ~/.local/share/feishu-bridge/logs/bridge-stderr.log
```

**可能原因**：
- 应用未发布（需在飞书开放平台发布版本）
- 事件订阅未启用（需订阅 `im.message.receive_v1`）
- 凭证无效（重新运行 `scripts/setup.sh`）

### 2. 消息重复

桥接自动去重，如果仍出现重复：
```bash
# 查看去重缓存
cat ~/.local/share/feishu-bridge/workspaces/claude-code/state/feishu-bridge/*.jsonl | wc -l
```

### 3. 连接断开

桥接自动重连，如果频繁断开：
- 检查网络稳定性
- 检查飞书应用配额
- 查看日志中的错误信息

### 4. MCP 工具不可用

```bash
# 检查 .mcp.json
cat ~/.local/share/feishu-bridge/workspaces/claude-code/.claude/.mcp.json

# 验证 HeartFlow MCP
node -e "const hf=require('/Users/apple/.claude/skills/mark-heartflow-skill/src/index.js'); console.log('OK', hf.version);"
```

### 5. 健康检查失败

```bash
# 手动健康检查
bash scripts/health-check.sh

# 检查端口
lsof -i :8090 2>/dev/null
```

## 日志位置

| 日志 | 位置 |
|------|------|
| 桥接 stdout | `~/.local/share/feishu-bridge/logs/bridge-stdout.log` |
| 桥接 stderr | `~/.local/share/feishu-bridge/logs/bridge-stderr.log` |
| 会话记录 | `~/.local/share/feishu-bridge/workspaces/claude-code/state/feishu-bridge/sessions-*.json` |
| 启发式日志 | `~/.local/share/feishu-bridge/workspaces/claude-code/state/feishu-bridge/heuristic-log-*.jsonl` |
