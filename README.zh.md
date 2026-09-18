# feishu-bridge

[English](README.md) | 中文

## 概述

`feishu-bridge` 是一个 Claude Code 技能，用于管理 **飞书 ↔ Claude Code 桥接服务**。

提供能力：
- 一键安装（`bash scripts/install.sh`）
- 服务管理（启动/停止/重启/状态）
- 飞书应用配置（二维码引导）
- HeartFlow 心虫集成（输入/输出门禁）
- 健康监控

## 快速开始

```bash
cd feishu-bridge-skill
bash scripts/install.sh
```

## 特性

- ✅ 官方 WebSocket 长连接
- ✅ 自动重连 + 消息去重
- ✅ HeartFlow 47维判别门禁
- ✅ MCP 工具扩展
- ✅ 多 bot 支持

## 系统要求

- macOS（launchd）
- Python 3.14+
- Node.js（用于 HeartFlow MCP）
- 飞书应用（App ID + App Secret）

## 文档

- [配置参考](references/config.md)
- [故障排查](references/troubleshooting.md)
- [架构说明](references/architecture.md)

## 许可证

MIT © yun520-1
