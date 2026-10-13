---
name: feishu-bridge
description: >
  飞书 ↔ Claude Code 桥接服务管理技能。一键安装、配置、启动、停止、状态检查、
  健康监控。健康检查走桥接自带的管理套接字，能拿到真实会话数与队列深度，
  不是探一个不存在的 HTTP 端口。
whenToUse: >
  当用户需要管理飞书桥接服务时使用：安装/启动/停止/重启/查看状态/更新/卸载。
  当用户需要配置飞书应用、检查桥接健康、或排查飞书消息收发故障时使用。
  典型触发词：桥接没反应、机器人不回、launchd 起不来、Unresolved env vars、
  权限改了不生效、日志 tail 不到东西。
metadata:
  version: "1.1.0"
  supersedes: "1.0.0（2026-09-18，提交 477d2090）"
  verifiedOn: "2026-10-13"
  verifiedEnv: "macOS / Python 3.11.15 / feishu-bridge 2026.6.20.12 / launchd com.feishu.bridge"
  author: "yun520-1"
  platform: "feishu"
  category: "integration"
  runtime: "feishu-bridge"
  runtimeVersion: "2026.6.20.12"
---

# 飞书桥接服务（Feishu Bridge）管理技能

> **v1.1.0** — 2026-10-13 对着一台在跑的实例逐条核对后重写。
> 1.0.0 里 `/Users/apple/` 的绝对路径、`bridge-stdout.log` 的日志名、
> `com.heartflow.mcp` 的 launchd 标签、以及整条 HeartFlow 判别门禁，
> 都与实况不符，已全部修正。差异清单见文末。

## 本机实况速查（2026-10-13 实测）

| 项 | 值 |
|---|---|
| launchd 标签 | `com.feishu.bridge` |
| plist 入口 | `/bin/bash` + `~/.local/share/feishu-bridge/start-bridge.sh`（包装器） |
| venv | `~/.venv-feishu-bridge`，Python **3.11.15** |
| 包版本 | `feishu_bridge-2026.6.20.12` |
| 日志 | `logs/bridge.log`（stdout）、`logs/bridge.err.log`（stderr） |
| 配置 | `~/.config/feishu-bridge/{.env,config.json}` |
| 权限 | `defaultMode: bypassPermissions`，allow/deny 均空 |
| MCP | **未配置**（无 `.mcp.json`，无 `mcp-servers/`） |
| 判别门禁 | **未启用**（见 references/architecture.md 第 3 节） |
| 健康探针 | Unix socket `~/.feishu-bridge/control-claude-code.sock` |

## 快速开始

```bash
bash scripts/install.sh
```

安装脚本自动完成：

1. 检查依赖（`python3` / `pip3`；`node` 仅自建 MCP 才需要）
2. 安装/升级 `feishu-bridge` Python 包
3. 引导配置飞书应用凭证（`FEISHU_APP_ID` + `FEISHU_APP_SECRET`）
4. 建目录、安装启动包装器、生成 `config.json`
5. 启动桥接服务（launchd 后台守护）
6. 健康检查验证

## 目录结构

```
feishu-bridge-skill/
├── SKILL.md                    # 本文档
├── scripts/
│   ├── install.sh              # 一键安装 + 配置 + 启动
│   ├── setup.sh                # 交互式配置（换应用 / 迁移凭证）
│   ├── start-bridge.sh         # 生成 plist 并启动
│   ├── start-bridge-wrapper.sh # 包装器：source .env 后 exec 二进制（plist 的真正入口）
│   ├── stop-bridge.sh          # 停止服务
│   ├── status.sh               # 服务状态检查
│   └── health-check.sh         # 健康检查（走控制套接字，输出 JSON）
├── references/
│   ├── config.md               # 配置参考（.env / config.json / plist / 权限 / 套接字）
│   ├── troubleshooting.md      # 故障排查（按实测排序）
│   └── architecture.md         # 架构说明
├── templates/
│   └── config.json             # 配置模板
└── .gitignore
```

## 常用命令

```bash
# 一键安装
bash scripts/install.sh

# 重新配置（换新应用）
bash scripts/setup.sh

# 启动 / 停止
bash scripts/start-bridge.sh
bash scripts/stop-bridge.sh

# 查看状态（人类可读）
bash scripts/status.sh

# 健康检查（JSON，供工具消费）
bash scripts/health-check.sh
# → {"ok":true,"probe":"control-socket","sessions":1,"queuePending":0,...}
```

`health-check.sh` 的 `probe` 字段说明数据可信度：
`control-socket`（最可信）> `state-file-fallback` > `launchd-only`。

## 三个必须记住的坑

这三个都不是"配置写错了"，是包自身的设计与文档不一致，1.0.0 完全没提。

### 1. plist 必须指向包装器，不能指向二进制

`feishu-bridge` 入口（`main.py`）**不读** `~/.config/feishu-bridge/.env`，
只读 `os.environ`；取不到 `${FEISHU_APP_ID}` 就
`log.error("Unresolved env vars in config")` 然后退出。
读 `.env` 的逻辑只在 `feishu-cli` 入口（`cli.py`）里。

所以 launchd 直拉二进制的形态必然起不来，而且 KeepAlive 会无限重启。
正确形态是 `/bin/bash` + `start-bridge.sh` 包装器，由它 source 过 `.env` 再 exec。
`scripts/start-bridge.sh` 生成的 plist 已经是这个形态，别手工改回二进制。

### 2. 权限设置要改包内那份，改部署副本会被覆盖

`runtime.py` 的 `materialize_data_files()` 每次桥接启动都
`shutil.copy2` 包内的 `data/bridge-settings.json` 到 `~/.feishu-bridge/`，
**没有存在性判断**。所以不只是 pip 升级会还原——下次启动就还原。

要改权限，改这里：

```bash
~/.venv-feishu-bridge/lib/python3.11/site-packages/feishu_bridge/data/bridge-settings.json
```

本机当前是 `defaultMode: bypassPermissions`、allow/deny 全空
（即 `bridge-settings.json` 与 `config.json` 的 `agent.args` 双保险都开着）。

### 3. 日志名是 bridge.log / bridge.err.log

不是 `bridge-stdout.log` / `bridge-stderr.log`。1.0.0 四个脚本全写的后两个名字，
导致 `status.sh` 永远认为日志不存在、`tail -f` 跟一个从不增长的文件。

## 服务管理

### launchd 守护进程

```bash
# 加载（start-bridge.sh 内部会做）
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.feishu.bridge.plist

# 卸载
launchctl bootout gui/$(id -u)/com.feishu.bridge

# 状态
launchctl list | grep feishu.bridge
```

注意 `launchctl list <label>` 输出的是 plist 转储（首行是 `{`），
要取 PID/退出码得用 `launchctl list | grep <label>` 那种
`PID ⇥ 退出码 ⇥ Label` 三列格式。

### 日志

```bash
tail -f ~/.local/share/feishu-bridge/logs/bridge.err.log   # 错误（信息量最大）
tail -f ~/.local/share/feishu-bridge/logs/bridge.log       # stdout
```

## 排错

见 [references/troubleshooting.md](references/troubleshooting.md)，按实测排序。
最常见的四条：`Unresolved env vars`（坑 1）、权限改了不生效（坑 2）、
日志名错（坑 3）、claude spawn 失败（plist 的 PATH 缺 `~/.npm-global/bin`）。

## 相关技能

要把文件/图片/文本**主动发到飞书**（不是回复正文，回复由桥接自动送回），
用 `feishu-bridge` 投递技能 `~/.claude/skills/feishu-bridge/`，
它封装 `~/.venv-feishu-bridge/bin/feishu-cli`。本技能只管桥接自身运维，不管投递。

## 版本

- **技能版本**: 1.1.0（2026-10-13）
- **运行时**: feishu-bridge 2026.6.20.12
- **Python**: 3.11.15 实测可跑（1.0.0 写 3.14+，与实况不符）
- **HeartFlow 门禁**: 未启用，见 references/architecture.md

## 1.0.0 → 1.1.0 改了什么

| # | 1.0.0 的问题 | 1.1.0 的处理 |
|---|---|---|
| 1 | 14 处 `/Users/apple/...` 硬编码（另一台机器的用户名） | 全部改为 `$HOME` 派生 |
| 2 | 日志名 `bridge-stdout.log` / `bridge-stderr.log`，实际不存在 | 改为真实的 `bridge.log` / `bridge.err.log`，涉及 4 个脚本 |
| 3 | launchd 标签写成 `com.heartflow.mcp` | 改为 `com.feishu.bridge` |
| 4 | plist 直指 venv 二进制，必然 `Unresolved env vars` | 改为 `/bin/bash` + 包装器；包装器作为新脚本入库 |
| 5 | plist 的 PATH 缺 `~/.npm-global/bin`，`claude` 找不到 | PATH 前缀补上，`agent.command` 改绝对路径 |
| 6 | 整条 HeartFlow 判别门禁在本机不存在（无 `.mcp.json`、无 skill、无 `--mcp-config`） | 从特性列表、架构图、监督表、版本信息中移除，改为在 architecture.md 说明实况 |
| 7 | `Python 3.14+` 与实况 3.11.15 矛盾 | 删掉版本门槛，改为实测可跑 |
| 8 | 目录结构和常用命令里列了 `stop-bridge.sh`，仓库里没这个文件 | 补上该脚本 |
| 9 | `install.sh` 的 heredoc 里 `<BRIDGE_DIR>` 是字面占位符，从没被替换 | 删掉 MCP 生成步骤，改为生成正确的 `config.json` |
| 10 | `install.sh` 建 `mcp-servers/` 目录但不写 `web_search.py`，配置指向不存在的文件 | 一并移除 |
| 11 | `status.sh` 探 `curl 127.0.0.1:8090/health`，该端口无监听 | 改走控制套接字 |
| 12 | `health-check.sh` 文档承诺输出 `sessions` 字段，脚本不输出 | 真从套接字取，并补 `probe`/`queuePending`/`quotaDataAvailable`/`errLogAge` |
| 13 | `setup.sh` 用 `read -p` 收 Secret，回显且进历史 | 改 `read -s`，并说明安全层会把说出来的密钥替换成占位符 |
| 14 | `.env` 加载不对称（cli 读、bridge 不读）完全没提 | 提升为"坑 1" |
| 15 | 部署副本每次启动被覆盖这件事没提 | 提升为"坑 2" |
| 16 | `architecture.md` 写了某次运行的 PID 快照 | 移除 |

## 许可证

MIT © yun520-1
