#!/bin/bash
# feishu-bridge 启动脚本（跨平台：macOS / Linux）
#
# 关键点（本机实测，2026-10-13）：
# 服务入口必须指向 /bin/bash + start-bridge.sh 包装器，
# 不能直接指向 venv 里的 feishu-bridge 二进制。
# 原因：feishu-bridge 入口不读 ~/.config/feishu-bridge/.env（只读 os.environ，
# 缺变量就 log.error "Unresolved env vars in config" 然后起不来）。
# 读 .env 的逻辑只在 feishu-cli 入口。包装器负责 source 后再 exec。
#
# v2.0.0 多平台化：平台差异全部下沉到 lib/platform.sh，本脚本只留流程。
#   macOS  → launchd，plist 落 ~/Library/LaunchAgents/
#   Linux  → systemd --user，单元落 ~/.config/systemd/user/
#   Windows→ bash 层不支持，明确报错并指向 PowerShell 方案
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/platform.sh"
platform::init

WRAPPER="$BRIDGE_DIR/start-bridge.sh"
SERVICE_UNIT_TEMPLATE="$SCRIPT_DIR/../templates/feishu-bridge.user.service"

if [ ! -f "$CONFIG_DIR/.env" ]; then
    platform::err "未找到配置，请先运行: bash scripts/setup.sh"
    exit 1
fi

if [ ! -x "$(platform::venv_exe feishu-bridge)" ]; then
    platform::err "未找到 feishu-bridge，请先运行: bash scripts/install.sh"
    platform::err "期望位置: $(platform::venv_exe feishu-bridge)"
    exit 1
fi

if [ ! -f "$WRAPPER" ]; then
    platform::err "未找到启动包装器: $WRAPPER"
    platform::err "它是服务的真正入口，负责 source .env。缺失时请从本技能 scripts/ 恢复："
    platform::err "cp scripts/start-bridge-wrapper.sh $WRAPPER && chmod +x $WRAPPER"
    exit 1
fi

# 已在运行则先停掉，避免 bootstrap 报 Label already exists
if [ -n "$(platform::service_status)" ]; then
    platform::info "ℹ️ 服务已在运行，重启中..."
    bash "$SCRIPT_DIR/stop-bridge.sh" || true
fi

mkdir -p "$LOG_DIR"

# claude 的所在目录必须进服务环境的 PATH，否则 agent.command 用相对名
# "claude" 会找不到。这里从当前 shell 解析，解析不到就退回 npm-global 的
# 常规位置——两种安装方式都覆盖。
CLAUDE_DIR="$(dirname "$(command -v claude 2>/dev/null || echo "$HOME/.npm-global/bin/claude")")"
PATH_VALUE="$CLAUDE_DIR:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

case "$PLATFORM_INIT" in
    launchd)
        cat > "$PLIST" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0//DTD/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$BRIDGE_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$WRAPPER</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>WorkingDirectory</key>
    <string>$BRIDGE_DIR</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$PATH_VALUE</string>
    </dict>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/bridge.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/bridge.err.log</string>
</dict>
</plist>
PLISTEOF
        platform::service_start "$PLIST"
        ;;
    systemd)
        if [ ! -f "$SERVICE_UNIT_TEMPLATE" ]; then
            platform::err "缺少 systemd 单元模板: $SERVICE_UNIT_TEMPLATE"
            exit 1
        fi
        local_dir="$HOME/.config/systemd/user"
        mkdir -p "$local_dir"
        # 模板里的 %h 由 systemd 自己展开，这里只需落位。
        cp "$SERVICE_UNIT_TEMPLATE" "$local_dir/$BRIDGE_LABEL.service"
        # PATH 覆盖：模板里的默认值不含 claude 目录，用 drop-in 精准追加，
        # 不改动上游模板本身（升级模板不会丢掉本机定制）。
        mkdir -p "$local_dir/$BRIDGE_LABEL.service.d"
        cat > "$local_dir/$BRIDGE_LABEL.service.d/override.conf" << UNITEOF
[Service]
Environment=PATH=$PATH_VALUE
UNITEOF
        platform::service_install "$local_dir/$BRIDGE_LABEL.service"
        platform::service_start "$local_dir/$BRIDGE_LABEL.service"
        ;;
    windows)
        platform::err "Windows 上请用 PowerShell 托管（bash 层不接服务管理器）"
        platform::err "前台运行: bash $WRAPPER"
        platform::err "计划任务托管: schtasks /Create /TN $BRIDGE_LABEL /TR \"bash $WRAPPER\" /SC ONLOGON"
        exit 1
        ;;
    *)
        platform::err "该平台无受支持的服务管理器（检测到 ${PLATFORM_INIT}）"
        platform::err "可前台运行: bash $WRAPPER"
        exit 1
        ;;
esac

sleep 2

STATUS_ROW="$(platform::service_status)"
if [ -n "$STATUS_ROW" ]; then
    PID="$(printf '%s' "$STATUS_ROW" | awk '{print $1}')"
    platform::info "✅ 飞书桥接已启动 (PID: ${PID:--}, 平台: $PLATFORM_OS/$PLATFORM_INIT)"
    platform::info "   日志: $LOG_DIR/bridge.log"
    platform::info "   错误: $LOG_DIR/bridge.err.log"
else
    platform::err "启动失败，请查看日志:"
    platform::err "   tail -30 $LOG_DIR/bridge.err.log"
    exit 1
fi
