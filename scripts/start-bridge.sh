#!/bin/bash
# feishu-bridge 启动脚本
set -e

CONFIG_DIR="$HOME/.config/feishu-bridge"
BRIDGE_DIR="$HOME/.local/share/feishu-bridge"
VENV_DIR="$HOME/.venv-feishu-bridge"
PLIST="$HOME/Library/LaunchAgents/com.feishu.bridge.plist"
LOG_DIR="$BRIDGE_DIR/logs"

# 检查配置
if [ ! -f "$CONFIG_DIR/.env" ]; then
    echo "❌ 未找到配置，请先运行: bash scripts/setup.sh"
    exit 1
fi

# 检查依赖
if [ ! -f "$VENV_DIR/bin/feishu-bridge" ]; then
    echo "❌ 未找到 feishu-bridge，请先运行: bash scripts/install.sh"
    exit 1
fi

# 检查是否已在运行
if launchctl list | grep -q "com.feishu.bridge"; then
    echo "ℹ️ 服务已在运行，重启中..."
    launchctl bootout gui/$(id -u)/com.feishu.bridge 2>/dev/null || true
fi

# 创建 plist
cat > "$PLIST" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.feishu.bridge</string>
    <key>ProgramArguments</key>
    <array>
        <string>$VENV_DIR/bin/python3</string>
        <string>$VENV_DIR/bin/feishu-bridge</string>
        <string>--config</string>
        <string>$CONFIG_DIR/config.json</string>
        <string>--bot</string>
        <string>claude-code</string>
        <string>--log-level</string>
        <string>INFO</string>
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
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/bridge-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/bridge-stderr.log</string>
</dict>
</plist>
PLISTEOF

# 加载服务
launchctl bootstrap gui/$(id -u) "$PLIST"

sleep 2

# 检查状态
if launchctl list | grep -q "com.feishu.bridge"; then
    PID=$(launchctl list com.feishu.bridge | head -1 | awk '{print $1}')
    echo "✅ 飞书桥接已启动 (PID: $PID)"
    echo "   日志: $LOG_DIR/bridge-stdout.log"
else
    echo "❌ 启动失败，请查看日志:"
    echo "   tail -f $LOG_DIR/bridge-stderr.log"
    exit 1
fi
