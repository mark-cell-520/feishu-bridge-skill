#!/bin/bash
# feishu-bridge 一键安装脚本
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
BRIDGE_DIR="$HOME/.local/share/feishu-bridge"
CONFIG_DIR="$HOME/.config/feishu-bridge"
VENV_DIR="$HOME/.venv-feishu-bridge"
LOG_DIR="$BRIDGE_DIR/logs"
WRAPPER="$BRIDGE_DIR/start-bridge.sh"

echo "========================================="
echo "  Feishu Bridge 一键安装 v1.1.0"
echo "========================================="
echo ""

# 1. 检查依赖
echo "[1/7] 检查依赖..."
command -v python3 >/dev/null 2>&1 || { echo "❌ 未找到 python3，请先安装"; exit 1; }
PYV=$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])')
echo "   python3 $PYV"
# 上游版本写"Python 3.14+"，与实况不符：本机跑得好好的用的是 3.11。
# 包本身没有 3.14 专属语法，别用这个数字把人吓跑。
command -v pip3 >/dev/null 2>&1 || { echo "❌ 未找到 pip3，请先安装"; exit 1; }
if command -v node >/dev/null 2>&1; then
    echo "   node $(node --version)"
else
    echo "⚠️ 未找到 node（仅当你要自建 MCP 工具时才需要，桥接本身不依赖）"
fi
echo "✅ 依赖检查完成"
echo ""

# 2. 安装/升级 feishu-bridge
echo "[2/7] 安装 feishu-bridge..."
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
    echo "✅ 创建虚拟环境: $VENV_DIR"
else
    echo "✅ 虚拟环境已存在: $VENV_DIR"
fi

"$VENV_DIR/bin/pip" install --upgrade feishu-bridge 2>&1 | tail -3
echo "✅ feishu-bridge 安装完成"
echo ""

# 3. 配置
echo "[3/7] 配置飞书应用..."
if [ -f "$CONFIG_DIR/.env" ] && [ -f "$CONFIG_DIR/config.json" ]; then
    echo "✅ 配置已存在: $CONFIG_DIR"
    read -r -p "是否重新配置? (y/N): " reconfigure
    if [ "$reconfigure" != "y" ]; then
        echo "跳过配置"
    else
        "$SCRIPT_DIR/setup.sh"
    fi
else
    "$SCRIPT_DIR/setup.sh"
fi
echo ""

# 4. 创建目录
echo "[4/7] 创建工作目录..."
mkdir -p "$BRIDGE_DIR/workspaces/claude-code/state/feishu-bridge"
mkdir -p "$LOG_DIR"
echo "✅ 目录创建完成"
echo ""

# 5. 安装启动包装器（plist 的真正入口，负责 source .env）
echo "[5/7] 安装启动包装器..."
if [ -f "$SCRIPT_DIR/start-bridge-wrapper.sh" ]; then
    cp "$SCRIPT_DIR/start-bridge-wrapper.sh" "$WRAPPER"
    chmod +x "$WRAPPER"
    echo "✅ 已安装: $WRAPPER"
else
    echo "⚠️ 本技能缺少 scripts/start-bridge-wrapper.sh，桥接将因读不到 .env 而起不来"
fi
echo ""

# 6. 生成 config.json（若缺失）
echo "[6/7] 检查 config.json..."
if [ ! -f "$CONFIG_DIR/config.json" ]; then
    mkdir -p "$CONFIG_DIR"
    CLAUDE_BIN="$(command -v claude || echo "$HOME/.npm-global/bin/claude")"
    cat > "$CONFIG_DIR/config.json" << EOF
{
  "bots": [
    {
      "name": "claude-code",
      "app_id": "\${FEISHU_APP_ID}",
      "app_secret": "\${FEISHU_APP_SECRET}",
      "workspace": "$BRIDGE_DIR/workspaces/claude-code",
      "allowed_users": ["*"]
    }
  ],
  "agent": {
    "type": "claude",
    "command": "$CLAUDE_BIN",
    "timeout_seconds": 300,
    "args": ["--permission-mode", "bypassPermissions"]
  }
}
EOF
    echo "✅ 已生成: $CONFIG_DIR/config.json"
else
    echo "✅ 已存在: $CONFIG_DIR/config.json"
fi
echo ""

# 7. 启动服务
echo "[7/7] 启动桥接服务..."
bash "$SCRIPT_DIR/start-bridge.sh"
echo ""

echo "========================================="
echo "  安装完成！"
echo "========================================="
echo ""
echo "下一步："
echo "  1. 在飞书中给机器人发消息测试"
echo "  2. 查看状态: bash scripts/status.sh"
echo "  3. 健康检查: bash scripts/health-check.sh"
echo "  4. 查看日志: tail -f $LOG_DIR/bridge.err.log"
echo ""
echo "⚠️ 若要改权限（默认 bypassPermissions，deny 为空）："
echo "   改包内那一份，不要改部署副本——"
echo "   $VENV_DIR/lib/python3.11/site-packages/feishu_bridge/data/bridge-settings.json"
echo "   部署副本 ~/.feishu-bridge/bridge-settings.json 每次启动都会被无条件覆盖。"
echo ""
