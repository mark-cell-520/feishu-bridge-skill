#!/bin/bash
# lib/platform.sh — 跨平台能力抽象层（macOS / Linux / Windows）
#
# 被所有运维脚本 source。职责只有一个：把"在哪台机器上、有什么能力"
# 收敛成一组标准变量与函数，让上层脚本不用到处写 if darwin。
#
# 设计约束：
#   1. 探测失败不静默降级——缺能力就明确报错并说明缺什么，避免
#      "看起来跑完了其实什么都没做"。
#   2. 所有路径支持环境变量覆盖（多环境：同一台机器跑 dev/prod、
#      或多 bot 隔离），覆盖不了的是平台能力，不是路径。
#   3. 兼容 bash 3.2（macOS 自带版本）。不用 declare -A / mapfile。
#      $var 后紧跟多字节字符必须写 ${var}——bash 3.2 在 LANG 空、
#      LC_CTYPE=C.UTF-8 下会把全角字符吞进变量名。
#
# 用法：
#   . "$(dirname "$0")/lib/platform.sh"
#   platform::init
#   echo "$PLATFORM_OS / $PLATFORM_INIT"

# ── 防止重复 source ──────────────────────────────────────────────
[ -n "${_PLATFORM_SH_LOADED:-}" ] && return 0
_PLATFORM_SH_LOADED=1

# ── 路径常量（支持环境变量覆盖，适配多环境）──────────────────────
: "${BRIDGE_HOME:=${FEISHU_BRIDGE_HOME:-$HOME/.local/share/feishu-bridge}}"
: "${CONFIG_HOME:=${FEISHU_BRIDGE_CONFIG_HOME:-$HOME/.config/feishu-bridge}}"
: "${VENV_HOME:=${FEISHU_BRIDGE_VENV:-$HOME/.venv-feishu-bridge}}"
: "${STATE_HOME:=${FEISHU_BRIDGE_STATE_HOME:-$HOME/.feishu-bridge}}"
: "${BRIDGE_LABEL:=${FEISHU_BRIDGE_LABEL:-com.feishu.bridge}}"
: "${BRIDGE_BOT:=${FEISHU_BRIDGE_BOT:-claude-code}}"

BRIDGE_DIR="$BRIDGE_HOME"
CONFIG_DIR="$CONFIG_HOME"
VENV_DIR="$VENV_HOME"
LOG_DIR="$BRIDGE_DIR/logs"
WRAPPER="$BRIDGE_DIR/start-bridge.sh"
PLIST="$HOME/Library/LaunchAgents/$BRIDGE_LABEL.plist"

# ── 输出助手 ─────────────────────────────────────────────────────
platform::err()  { printf '错误: %s\n' "$*" >&2; }
platform::warn() { printf '警告: %s\n' "$*" >&2; }
platform::info() { printf '%s\n' "$*"; }

# ── 平台探测 ─────────────────────────────────────────────────────
# PLATFORM_OS:     darwin | linux | windows | unknown
# PLATFORM_INIT:   launchd | systemd | windows | none
# PLATFORM_SHELL:  bash | powershell(检测到 Windows 原生)
platform::detect_os() {
    local uname_s
    uname_s="$(uname -s 2>/dev/null || echo unknown)"
    case "$uname_s" in
        Darwin)            PLATFORM_OS="darwin" ;;
        Linux)             PLATFORM_OS="linux" ;;
        MINGW*|MSYS*|CYGWIN*|Windows_NT)
                            # Git Bash / MSYS / Cygwin 仍在跑 bash，
                            # 归到 windows 但保留 bash 能力。
                            PLATFORM_OS="windows" ;;
        *)                  PLATFORM_OS="unknown" ;;
    esac
}

platform::detect_init() {
    case "$PLATFORM_OS" in
        darwin)
            PLATFORM_INIT="launchd" ;;
        linux)
            # systemd --user 优先；没有则退到 none（脚本会明确报错，
            # 不假装能管服务）。
            if command -v systemctl >/dev/null 2>&1 \
               && systemctl --user status >/dev/null 2>&1; then
                PLATFORM_INIT="systemd"
            else
                PLATFORM_INIT="none"
            fi
            ;;
        windows)
            PLATFORM_INIT="windows" ;;
        *)
            PLATFORM_INIT="none" ;;
    esac
}

# ── Python 探测 ──────────────────────────────────────────────────
# 多环境：不同系统/不同安装方式的 Python 入口名不同。
#   优先用户显式指定（FEISHU_BRIDGE_PYTHON），再按常见顺序找。
platform::detect_python() {
    if [ -n "${FEISHU_BRIDGE_PYTHON:-}" ]; then
        if command -v "$FEISHU_BRIDGE_PYTHON" >/dev/null 2>&1; then
            PLATFORM_PYTHON="$FEISHU_BRIDGE_PYTHON"
            return 0
        fi
        platform::err "FEISHU_BRIDGE_PYTHON=$FEISHU_BRIDGE_PYTHON 不在 PATH"
        return 1
    fi
    local c
    for c in python3 python py; do
        if command -v "$c" >/dev/null 2>&1; then
            PLATFORM_PYTHON="$c"
            return 0
        fi
    done
    PLATFORM_PYTHON=""
    return 1
}

# venv 可执行目录名：POSIX 用 bin，Windows 用 Scripts。
platform::venv_bin() {
    case "$PLATFORM_OS" in
        windows) echo "Scripts" ;;
        *)       echo "bin" ;;
    esac
}

# venv 里某个可执行文件的完整路径（自动处理 bin/Scripts 与 .exe）。
platform::venv_exe() {
    local name="$1" bin ext=""
    bin="$(platform::venv_bin)"
    [ "$PLATFORM_OS" = "windows" ] && ext=".exe"
    echo "$VENV_DIR/$bin/$name$ext"
}

# ── 跨平台文件 mtime（秒）────────────────────────────────────────
# BSD stat 是 -f%m，GNU stat 是 -c%Y。这是 v1.1.0 里写死 BSD 语法
# 导致 Linux 直接坏掉的一处。
platform::stat_mtime() {
    local f="$1"
    [ -e "$f" ] || return 1
    case "$PLATFORM_OS" in
        darwin) stat -f%m "$f" 2>/dev/null ;;
        linux)  stat -c%Y "$f" 2>/dev/null ;;
        windows)
            # Git Bash 的 stat 多为 GNU coreutils，但兜底用 Python 最稳。
            "$PLATFORM_PYTHON" -c "
import os,sys
try:
    print(int(os.path.getmtime(sys.argv[1])))
except OSError:
    sys.exit(1)" "$f" 2>/dev/null
            ;;
        *) return 1 ;;
    esac
}

# ── 控制套接字路径 ───────────────────────────────────────────────
# macOS/Linux 用 Unix domain socket；Windows 桥接若支持则走 named pipe，
# 不支持时健康检查必须明确说明"该平台无控制套接字"，不能假装健康。
platform::control_socket() {
    echo "$STATE_HOME/control-$BRIDGE_BOT.sock"
}

platform::control_token() {
    echo "$STATE_HOME/control-$BRIDGE_BOT.token"
}

# ── 服务管理抽象 ─────────────────────────────────────────────────
# 上层只调这三个，不直接碰 launchctl/systemctl。
#   platform::service_start <plist|unit>
#   platform::service_stop
#   platform::service_status   → 输出 "PID<TAB>退出码"，无服务输出空

platform::service_start() {
    local unit="$1"
    case "$PLATFORM_INIT" in
        launchd)
            launchctl bootstrap "gui/$(id -u)" "$unit" 2>/dev/null
            ;;
        systemd)
            # unit 由调用方保证已落到 ~/.config/systemd/user/
            systemctl --user daemon-reload 2>/dev/null
            systemctl --user start "$BRIDGE_LABEL.service" 2>/dev/null
            ;;
        *)
            platform::err "该平台无受支持的服务管理器（检测到 ${PLATFORM_INIT}）"
            platform::err "请以前台方式运行：$WRAPPER"
            return 1
            ;;
    esac
}

platform::service_stop() {
    case "$PLATFORM_INIT" in
        launchd)
            launchctl bootout "gui/$(id -u)/$BRIDGE_LABEL" 2>/dev/null || true
            ;;
        systemd)
            systemctl --user stop "$BRIDGE_LABEL.service" 2>/dev/null || true
            ;;
        windows)
            platform::warn "Windows 服务停止请用 PowerShell：Stop-ScheduledTask -TaskName $BRIDGE_LABEL"
            return 1
            ;;
        *)
            platform::err "该平台无受支持的服务管理器（检测到 ${PLATFORM_INIT}）"
            return 1
            ;;
    esac
}

platform::service_status() {
    case "$PLATFORM_INIT" in
        launchd)
            launchctl list 2>/dev/null | grep -F "$BRIDGE_LABEL" | head -1
            ;;
        systemd)
            # 转成与 launchctl 一致的 "PID<TAB>退出码" 两列，上层不用改解析。
            if ! systemctl --user list-unit-files 2>/dev/null | grep -qF "$BRIDGE_LABEL.service"; then
                return 0
            fi
            local pid active
            pid="$(systemctl --user show -p MainPID --value "$BRIDGE_LABEL.service" 2>/dev/null)"
            active="$(systemctl --user show -p ActiveState --value "$BRIDGE_LABEL.service" 2>/dev/null)"
            if [ "$active" = "active" ] && [ -n "$pid" ] && [ "$pid" != "0" ]; then
                printf '%s\t0\n' "$pid"
            else
                printf -- '-\t1\n'
            fi
            ;;
        *)
            return 0
            ;;
    esac
}

platform::service_install() {
    local unit="$1"
    case "$PLATFORM_INIT" in
        launchd)
            launchctl bootstrap "gui/$(id -u)" "$unit" 2>/dev/null
            ;;
        systemd)
            local dir="$HOME/.config/systemd/user"
            mkdir -p "$dir"
            cp "$unit" "$dir/$BRIDGE_LABEL.service" 2>/dev/null
            systemctl --user daemon-reload 2>/dev/null
            systemctl --user enable "$BRIDGE_LABEL.service" 2>/dev/null
            ;;
        *)
            platform::err "该平台无法安装服务（检测到 ${PLATFORM_INIT}）"
            return 1
            ;;
    esac
}

# ── 初始化入口 ───────────────────────────────────────────────────
platform::init() {
    platform::detect_os
    platform::detect_init

    if ! platform::detect_python; then
        platform::warn "未找到 Python（找过 python3/python/py）"
        platform::warn "可设置 FEISHU_BRIDGE_PYTHON 指定解释器路径"
    fi

    # Windows 原生（非 Git Bash）跑 bash 脚本本身就不可靠，提前说明。
    if [ "$PLATFORM_OS" = "windows" ] && [ -z "${MSYSTEM:-}" ]; then
        platform::warn "检测到 Windows 但不在 Git Bash/MSYS 环境"
        platform::warn "bash 层仅保证 macOS 与 Linux；Windows 请用 scripts/*.ps1"
    fi
    return 0
}

# ── 能力自检（供 health-check 与安装后验证复用）──────────────────
# 输出每项能力的 OK / MISSING，便于定位"这台机器缺什么"。
platform::capabilities() {
    platform::info "平台: $PLATFORM_OS"
    platform::info "服务管理器: $PLATFORM_INIT"
    if [ -n "$PLATFORM_PYTHON" ]; then
        local pv
        pv="$("$PLATFORM_PYTHON" -c 'import sys;print("%d.%d.%d"%sys.version_info[:3])' 2>/dev/null || echo '?')"
        platform::info "Python: $PLATFORM_PYTHON ($pv)"
    else
        platform::info "Python: 缺失"
    fi
    platform::info "venv 可执行目录: $(platform::venv_bin)"
    platform::info "控制套接字: $(platform::control_socket)"
    platform::info "桥接目录: $BRIDGE_DIR"
    platform::info "配置目录: $CONFIG_DIR"
    platform::info "venv 目录: $VENV_DIR"
    case "$PLATFORM_INIT" in
        none|windows)
            platform::warn "该平台不能托管为系统服务，只能前台运行"
            ;;
    esac
}
