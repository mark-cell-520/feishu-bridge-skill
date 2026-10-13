#!/bin/bash
# feishu-bridge 启动脚本
#
# 关键点（本机实测，2026-10-13）：
# plist 的 ProgramArguments 必须指向 /bin/bash + start-bridge.sh 包装器，
# 不能直接指向 venv 里的 feishu-bridge 二进制。
# 原因：feishu-bridge 入口不读 ~/.config/feishu-bridge/.env（只读 os.environ，
# 缺变量就 log.error "Unresolved env vars in config" 然后起不来）。
# 读 .env 的逻辑只在 feishu-cli 入口。包装器负责 source 后再 exec。
set -e

CONFIG_DIR="$HOME/.config/feishu-bridge"
BRIDGE_DIR="$HOME/.local/share/feishu-bridge"
VENV_DIR="$HOME/.venv-feishu-bridge"
WRAPPER="$BRIDGE_DIR/start-bridge.sh"
PLIST="$HOME/Library/LaunchAgents/com.feishu.bridge.plist"
LOG_DIR="$BRIDGE_DIR/logs"

if [ ! -f "$CONFIG_DIR/.env" ]; then
    echo "❌ 未找到配置，请先运行: bash scripts/setup.sh" >&2
    exit 1
fi

if [ ! -x "$VENV_DIR/bin/feishu-bridge" ]; then
    echo "❌ 未找到 feishu-bridge，请先运行: bash scripts/install.sh" >&2
    exit 1
fi

if [ ! -f "$WRAPPER" ]; then
    echo "❌ 未找到启动包装器: $WRAPPER" >&2
    echo "   它是 plist 的真正入口，负责 source .env。缺失时请从本技能 scripts/ 恢复：" >&2
    echo "   cp scripts/start-bridge-wrapper.sh $WRAPPER && chmod +x $WRAPPER" >&2
    exit 1
fi

# 已在运行则先停掉，避免 bootstrap 报 Label already exists
if launchctl list | grep -q "com.feishu.bridge"; then
    echo "ℹ️ 服务已在运行，重启中..."
    bash "$(dirname "$0")/stop-bridge.sh" || true
fi

mkdir -p "$LOG_DIR"

# claude 的所在目录必须进 plist 的 PATH，否则 agent.command 用相对名 "claude" 会找不到。
# 这里从当前 shell 解析，解析不到就退回 npm-global 的常规位置。
CLAUDE_DIR="$(dirname "$(command -v claude 2>/dev/null || echo "$HOME/.npm-global/bin/claude")")"
PATH_VALUE="$CLAUDE_DIR:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

cat > "$PLIST" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.feishu.bridge</string>
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

launchctl bootstrap "gui/$(id -u)" "$PLIST"

sleep 2

if launchctl list | grep -q "com.feishu.bridge"; then
    PID=$(launchctl list | grep "com.feishu.bridge" | head -1 | awk '{print $1}')
    echo "✅ 飞书桥接已启动 (PID: ${PID:--})"
    echo "   日志: $LOG_DIR/bridge.log"
    echo "   错误: $LOG_DIR/bridge.err.log"
else
    echo "❌ 启动失败，请查看日志:" >&2
    echo "   tail -30 $LOG_DIR/bridge.err.log" >&2
    exit 1
fi
