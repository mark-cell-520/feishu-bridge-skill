# feishu-bridge-skill

管理 **飞书 ↔ Claude Code 桥接服务**的 Claude Code 技能：安装、配置、启动、停止、
状态检查、健康监控。

[English](README.md) | 中文

> v2.22.0（2026-11-03）— 当前版本。
>
> 历史：1.0.0 里的 `/Users/apple/` 绝对路径、`bridge-stdout.log` 日志名、
> `com.heartflow.mcp` 标签、以及整条 HeartFlow 判别门禁都与实况不符。
> v1.1.0（2026-10-13）对着在跑实例逐条核对后重写，把这些问题全部修掉。
> v2.0.0 起做跨平台改造，并陆续加入一键诊断、服务看护、流畅度度量、
> 平滑升级，以及对 `ui.py` / `main.py` 的三个补丁。
> 完整历史见 `git log`。

## 概述

`feishu-bridge` 是一个 Claude Code 技能，托管飞书长连接桥接，覆盖 macOS / Linux / Windows：
飞书消息经 WebSocket 进来，拉起 `claude` CLI 子进程处理，回复再发回飞书。

提供能力：

- 一键安装（`bash scripts/install.sh`）
- 跨平台：macOS (launchd) / Linux (systemd --user) / Windows（前台或计划任务）
- 服务管理（启动 / 停止 / 重启 / 状态）
- 一键诊断报告（diagnose.sh，人读或 --json）——覆盖平台、服务、配置、权限、
  日志健康度、飞书 API 连通性、控制套接字、媒体目录
- 多工作区 / 多环境配置管理（ws.sh）
- 平滑升级（upgrade.sh），会自动重打 pip 升级会还原的权限补丁
- 服务看护（watchdog.sh）：三层检查进程/控制套接字/日志新鲜度，
  专抓 launchd KeepAlive 看不见的「进程活着但不服务」假死，带冷却期防重启风暴
- 流畅度与性能度量（perf.sh）：端到端耗时分位、流式卡片失败率、日志噪音占比（logs.sh）带错误聚合：刷屏的同一条警告只显示一次并给出次数
- 跨平台投递（send.py 核心 + send.sh / send.ps1）
- 飞书应用配置（命令行向导，Secret 不回显）
- 健康监控（走桥接自带的管理套接字，拿真实会话数与队列深度）

## 快速开始

```bash
cd feishu-bridge-skill
bash scripts/install.sh
```

## 命令

```bash
bash scripts/install.sh              # 一键安装
bash scripts/setup.sh                # 重新配置（换应用）
bash scripts/start-bridge.sh         # 启动（生成 plist / unit 并加载）
bash scripts/stop-bridge.sh          # 停止
bash scripts/status.sh               # 人类可读状态
bash scripts/health-check.sh         # JSON 健康检查
bash scripts/diagnose.sh             # 一键诊断报告
bash scripts/restart-bridge.sh       # 重启 + 补丁生效检查
bash scripts/ws.sh list              # 多工作区配置
bash scripts/upgrade.sh              # 平滑升级（自动重打补丁）
bash scripts/logs.sh errors          # 错误聚合
bash scripts/perf.sh                 # 流畅度与性能报告
bash scripts/watchdog.sh --once      # 单次看护检查
bash scripts/patch-ui.sh status      # 可选补丁状态
bash scripts/patch-post-image.sh status   # 图文混排修复状态
bash scripts/patch-tool-list.sh status    # 工具进度编号化状态
bash scripts/patch-ctx-compact.sh status  # ctx 超限立即压缩状态
bash scripts/setup-format-rule.sh status  # 输出规则注入状态
bash scripts/send.sh text "消息"     # 投递到当前飞书会话
```

## 特性

- ✅ 官方 WebSocket 长连接（非 webhook）
- ✅ 自动重连 + 消息去重 + 按会话串行队列
- ✅ 真实健康探针：Unix socket 控制接口，不是探一个没人监听的 HTTP 端口
- ✅ 日志名 / launchd 标签 / 路径全部按实况核对过
- ✅ 跨平台服务单元：launchd（macOS）、systemd --user（Linux）、
  前台 / 计划任务（Windows）
- ✅ 三个上游缺陷的补丁（无法通过配置规避，见 SKILL.md），
  各自带自动备份与回退

## 本机实况（2026-11-03）

| 项 | 值 |
|---|---|
| launchd 标签 | `com.feishu.bridge` |
| Python | 3.11.17 |
| 运行时 | feishu-bridge 2026.6.20.12 |
| 日志 | `logs/bridge.log`、`logs/bridge.err.log` |
| 判别门禁 | 未启用 |
| MCP | 未配置 |
| 平台 | macOS 27 实测；Linux / Windows 为适配，未在对应平台实跑 |

## 系统要求

- macOS（launchd）/ Linux（systemd --user）/ Windows（前台或计划任务）
- Python 3.11+（实测 3.11.17 可跑；1.0.0 写的 3.14+ 与实况不符，已删）
- 飞书应用（App ID + App Secret）
- `node` 仅在你自建 MCP 工具时才需要，桥接本身不依赖

## 文档

- [SKILL.md](SKILL.md) — 技能正文，含"三个必须记住的坑"与 1.0.0 → 1.1.0 差异清单
- [配置参考](references/config.md)
- [故障排查](references/troubleshooting.md)
- [架构说明](references/architecture.md)
- [跨平台与多环境](references/platforms.md)

## 许可证

MIT © yun520-1
