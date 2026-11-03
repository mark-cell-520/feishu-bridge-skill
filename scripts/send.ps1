# send.ps1 — 经本机 feishu-cli 把文本/文件/图片投递到飞书（Windows 入口）
#
# 跨平台核心 send.py 的 PowerShell 薄封装。存在这个文件的原因是：
# Windows 原生没有 bash，Git Bash 也只是半个方案（PATH、权限、中文编码
# 都和原生 shell 不同）。给 Windows 一个原生入口，行为与 macOS/Linux 一致。
#
# 用法:
#   .\send.ps1 text  "<文本>"            [-ChatId oc_xxx]
#   .\send.ps1 file  "<本地路径>"        [-ChatId oc_xxx]
#   .\send.ps1 image "<本地图片路径>"    [-ChatId oc_xxx]
#   .\send.ps1 chat                      # 显示当前会话 chat_id 后退出
#
# 退出码: 0 成功 / 1 用法或文件错误 / 2 超出大小上限 / 3 feishu-cli 报错

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("text", "file", "image", "chat")]
    [string]$Kind,

    [Parameter(Position = 1)]
    [string]$Payload,

    [Parameter(Position = 2)]
    [string]$ChatId,

    [string]$Cli,
    [string]$Bot
)

$ErrorActionPreference = "Stop"
$Core = Join-Path $PSScriptRoot "send.py"

# Python 解释器：Windows 上常见入口是 py 启动器、python.exe、
# Microsoft Store 的 python3.exe。按顺序找第一个可用的。
function Get-Python {
    if ($env:FEISHU_BRIDGE_PYTHON) {
        if (Get-Command $env:FEISHU_BRIDGE_PYTHON -ErrorAction SilentlyContinue) {
            return $env:FEISHU_BRIDGE_PYTHON
        }
        Write-Error "FEISHU_BRIDGE_PYTHON=$env:FEISHU_BRIDGE_PYTHON 不在 PATH"
        exit 1
    }
    foreach ($c in @("py", "python", "python3")) {
        if (Get-Command $c -ErrorAction SilentlyContinue) {
            return $c
        }
    }
    Write-Error "未找到 Python。请安装 Python 3.8+，或设置 FEISHU_BRIDGE_PYTHON"
    exit 1
}

$Py = Get-Python

if (-not (Test-Path $Core)) {
    Write-Error "缺少跨平台核心: $Core"
    exit 1
}

# 组装参数：把 PowerShell 的命名参数翻译成 send.py 的位置参数
$args = @($Kind)
if ($Payload) { $args += $Payload }
if ($ChatId)  { $args += $ChatId }
if ($Cli)     { $args += @("--cli", $Cli) }
if ($Bot)     { $args += @("--bot", $Bot) }

& $Py $Core @args
exit $LASTEXITCODE
