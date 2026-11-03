# 跨平台与多环境适配指南

本篇记录 v2.0.0 引入的平台抽象层，以及"同一套脚本在不同系统、不同状态下都能用"
是怎么做到的。v1.1.0 及以前是 macOS + launchd 专用，本篇同时是那份历史的修正说明。

## 一、为什么需要抽象层

v1.1.0 的脚本里散着四类平台假设，任何一类都足以让脚本在别的系统上静默失效：

| 类别 | v1.1.0 的写法 | Linux 实际情况 | Windows 实际情况 |
|---|---|---|---|
| 服务管理 | `launchctl bootstrap/bootout gui/$(id -u)` | 无 launchctl，用 `systemctl --user` | 无 launchctl/systemd，用计划任务或前台 |
| 文件 mtime | `stat -f%m`（BSD） | `stat -c%Y`（GNU） | 无 stat，用 Python 或 PowerShell |
| venv 布局 | `$VENV_DIR/bin/pip` | 同为 `bin/` | `Scripts/pip.exe` |
| Python 入口 | `python3` | 多为 `python3`，也有 `python` | `py` 启动器 / `python.exe` |

其中 `stat -f%m` 那处最隐蔽：脚本不报错，只是算出一个空值，于是日志新鲜度
恒为 `unknown`，看起来"检查通过了"其实什么都没探到。这类失败比直接报错更难发现，
所以抽象层的设计原则是**缺能力就明确说缺什么，不静默降级**。

## 二、platform.sh 提供什么

所有运维脚本开头都是这两行：

```bash
. "$SCRIPT_DIR/lib/platform.sh"
platform::init
```

之后可用的标准变量：

| 变量 | 取值 |
|---|---|
| `PLATFORM_OS` | `darwin` / `linux` / `windows` / `unknown` |
| `PLATFORM_INIT` | `launchd` / `systemd` / `windows` / `none` |
| `PLATFORM_PYTHON` | 探测到的解释器名，如 `python3` |

可用的跨平台函数：

| 函数 | 作用 |
|---|---|
| `platform::venv_bin` | 返回 `bin` 或 `Scripts` |
| `platform::venv_exe <名>` | venv 内可执行文件完整路径（自动补 `.exe`） |
| `platform::stat_mtime <文件>` | 文件 mtime（秒），三平台一套代码 |
| `platform::control_socket` | 控制套接字路径 |
| `platform::control_token` | 控制 token 路径 |
| `platform::service_start/stop/status/install` | 服务管理，底层自动选 launchd 或 systemd |
| `platform::capabilities` | 打印本机能力清单，排障第一步 |

`service_status` 的输出被刻意统一成 launchctl 的 `PID<TAB>退出码` 两列格式，
这样 status.sh / stop-bridge.sh / health-check.sh 的解析逻辑不用为 systemd
再写一遍。

## 三、路径全部可覆盖（多环境）

默认路径沿用 v1.1.0 的实况，但每一项都能用环境变量改，用来做环境隔离：

| 变量 | 默认值 | 用途 |
|---|---|---|
| `FEISHU_BRIDGE_HOME` | `~/.local/share/feishu-bridge` | 桥接数据目录 |
| `FEISHU_BRIDGE_CONFIG_HOME` | `~/.config/feishu-bridge` | 配置目录 |
| `FEISHU_BRIDGE_VENV` | `~/.venv-feishu-bridge` | venv 位置 |
| `FEISHU_BRIDGE_STATE_HOME` | `~/.feishu-bridge` | 套接字与 token 目录 |
| `FEISHU_BRIDGE_LABEL` | `com.feishu.bridge` | 服务标签（Linux 侧为 unit 名） |
| `FEISHU_BRIDGE_BOT` | `claude-code` | bot 名，多 bot 隔离用 |
| `FEISHU_BRIDGE_PYTHON` | 自动探测 | 指定 Python 解释器 |

典型场景：同一台机器同时跑 dev 与 prod 两个桥接，各自一套目录和服务标签：

```bash
FEISHU_BRIDGE_HOME=~/.local/share/feishu-bridge-dev \
FEISHU_BRIDGE_CONFIG_HOME=~/.config/feishu-bridge-dev \
FEISHU_BRIDGE_LABEL=com.feishu.bridge.dev \
  bash scripts/start-bridge.sh
```

注意 `FEISHU_BRIDGE_LABEL` 同时决定 plist 名与 systemd unit 名，改它就改了服务身份。

## 三之二、多环境实战：ws.sh

手写 6 个环境变量切环境容易漏，漏一个的后果是服务看起来起来了，
实际读写的是另一套数据。`scripts/ws.sh` 把整套环境存成命名配置：

```bash
# 保存当前环境为一套配置
bash scripts/ws.sh add dev

# 列出所有配置（标注哪套是当前，目录是否存在）
bash scripts/ws.sh list

# 切换到某套（输出 export 行，供 eval）
eval "$(bash scripts/ws.sh use dev)"

# 之后所有命令都认这套：不同的数据目录、不同的服务标签
bash scripts/start-bridge.sh
bash scripts/status.sh
```

配置存在 `~/.config/feishu-bridge/workspaces.json`，`current` 字段记录
当前套名，`ws.sh use` 会同时更新它，所以不带环境变量的后续命令也认这套。

典型用法是一台机器跑 dev 与 prod 两套桥接：

```bash
FEISHU_BRIDGE_HOME=~/.local/share/feishu-bridge-prod \
FEISHU_BRIDGE_CONFIG_HOME=~/.config/feishu-bridge-prod \
FEISHU_BRIDGE_LABEL=com.feishu.bridge.prod \
  bash scripts/ws.sh add prod
```

注意 `FEISHU_BRIDGE_LABEL` 同时决定 plist 名与 systemd unit 名，
改它就改了服务身份，这是两套服务能并存的关键。

## 四、各平台怎么托管服务

### macOS（launchd）

行为与 v1.1.0 一致：生成 `~/Library/LaunchAgents/<label>.plist`，
`launchctl bootstrap gui/$(id -u)` 加载。这是唯一在本机实跑验证过的路径。

### Linux（systemd --user）

`start-bridge.sh` 会把 `templates/feishu-bridge.user.service` 复制到
`~/.config/systemd/user/<label>.service`，再 `systemctl --user enable --now`。

模板里用 `%h` 让 systemd 自己展开 home，不把绝对路径写死。
日志用 `StandardOutput=append:`（需 systemd 236+，Debian 11 / Ubuntu 18.10 /
RHEL 8 及以上），选 append 而非 file 是为了不截断上一次的日志——排障时上一次的
现场往往正是要看的。

claude 所在目录通过 drop-in（`<label>.service.d/override.conf`）注入 PATH，
而不是改模板本身，这样上游模板升级不会丢掉本机定制。

手动操作等价命令：

```bash
systemctl --user daemon-reload
systemctl --user enable --now com.feishu.bridge.service
systemctl --user status com.feishu.bridge.service
journalctl --user -u com.feishu.bridge.service -f   # 看日志
```

注意：systemd --user 需要用户有 lingering 才能在未登录时运行，
`loginctl enable-linger $(whoami)`。

### Windows

bash 层不接 Windows 服务管理器，检测到即明确报错并给两条可行路径：

```powershell
# 1. 前台运行（调试用）
bash ~\.local\share\feishu-bridge\start-bridge.sh

# 2. 计划任务托管（登录时启动）
schtasks /Create /TN com.feishu.bridge /TR "bash <WRAPPER路径>" /SC ONLOGON
```

更推荐用 [NSSM](https://nssm.cc/) 或 [WinSW](https://github.com/winsw/winsw)
包成真正的 Windows 服务，两者都能把任意命令注册成服务并管理重启。

## 五、投递的跨平台实现

投递（把文本/文件/图片发到飞书）在 v1.1.0 里被删掉了，v2.0.0 以三层结构恢复：

```
send.py     跨平台核心：定位 CLI、解析 chat_id、大小检查、调 feishu-cli
send.sh     bash 薄封装（macOS / Linux）
send.ps1     PowerShell 薄封装（Windows）
```

核心逻辑放 Python 的理由很直接：`stat -f%z`（BSD）、`stat -c%s`（GNU）、
PowerShell 三套语法不可能在一个 shell 脚本里写对，而 `os.path.getsize`
一处写完三个平台都对。路径拼接、home 展开、中文编码也是同理。

用法三个平台一致：

```bash
# macOS / Linux
bash scripts/send.sh text  "消息内容"          # 发到当前会话
bash scripts/send.sh image ~/pic.png           # 图片（≤10MB）
bash scripts/send.sh file  ~/report.pdf        # 文件（≤30MB）
bash scripts/send.sh chat                      # 只看当前 chat_id

# Windows
.\scripts\send.ps1 text "消息内容"
.\scripts\send.ps1 image "$env:USERPROFILE\pic.png"
.\scripts\send.ps1 chat
```

退出码语义三平台一致：`0` 成功、`1` 用法或文件错误、`2` 超出大小上限、
`3` feishu-cli 报错。原来 bash 版把 feishu-cli 的退出码和本地用法错撞在一起，
无法区分"参数写错了"和"飞书那边失败了"，v2.0.0 把两者分开。

大小上限默认跟随飞书（图片 10MB / 文件 30MB），可用 `--max-mb` 覆盖以适配
自建飞书实例的不同限制。

## 六、健康检查的平台差异

健康检查依赖桥接的 Unix domain socket（`~/.feishu-bridge/control-<bot>.sock`）。
这是 POSIX 能力，Windows 原生没有对应物。

v2.0.0 的处理是在 JSON 输出里加 `platform` 与 `initManager` 字段，并且当平台
无 Unix socket 时把 `probe` 标为 `unsupported-platform`，而不是让它落到
`launchd-only` 分支——后者会被误读成"服务在跑但探不到会话"，实际是"这个平台
根本没有这条探针路"。

消费方据此可以区分三种状态：`control-socket`（真实探到）、
`state-file-fallback`（退化到数状态文件）、`unsupported-platform`（能力缺失）。

## 七、验证边界（重要）

本次改造在 macOS 27 + Python 3.14 + feishu-bridge 2026.6.20.12 上实跑验证了
`platform.sh` 的能力探测、`status.sh`、`health-check.sh`（含 mtime 跨平台取法）、
`send.py` / `send.sh` 的退出码语义与 CLI 定位。

**Linux 与 Windows 路径没有在对应平台实跑**，属于静态适配。已知的未验证点：

1. systemd 单元的 `%h` 展开与 `append:` 日志（依赖 systemd 版本）
2. `systemctl --user show -p MainPID` 的输出格式在不同版本间是否稳定
3. Windows 侧 `Scripts/` 目录与 `.exe` 后缀的探测
4. PowerShell 参数传递与 `$LASTEXITCODE` 的传递

在对应平台首次使用时，建议先跑 `bash scripts/status.sh` 确认能力探测正确，
再决定是否继续。发现问题请把输出贴到 issue，比按假设改代码更可靠。
