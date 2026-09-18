#!/bin/bash
# feishu-bridge 一键安装脚本
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
BRIDGE_DIR="$HOME/.local/share/feishu-bridge"
CONFIG_DIR="$HOME/.config/feishu-bridge"
VENV_DIR="$HOME/.venv-feishu-bridge"
LOG_DIR="$BRIDGE_DIR/logs"

echo "========================================="
echo "  Feishu Bridge 一键安装 v1.0.0"
echo "========================================="
echo ""

# 1. 检查依赖
echo "[1/6] 检查依赖..."
command -v python3 >/dev/null 2>&1 || { echo "❌ 未找到 python3，请先安装"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "⚠️ 未找到 node（HeartFlow MCP 将不可用）"; }
command -v pip3 >/dev/null 2>&1 || { echo "❌ 未找到 pip3，请先安装"; exit 1; }
echo "✅ 依赖检查完成"
echo ""

# 2. 安装/升级 feishu-bridge
echo "[2/6] 安装 feishu-bridge..."
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
echo "[3/6] 配置飞书应用..."
if [ -f "$CONFIG_DIR/.env" ] && [ -f "$CONFIG_DIR/config.json" ]; then
    echo "✅ 配置已存在: $CONFIG_DIR"
    read -p "是否重新配置? (y/N): " reconfigure
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
echo "[4/6] 创建工作目录..."
mkdir -p "$BRIDGE_DIR/workspaces/claude-code/.claude/mcp-servers"
mkdir -p "$BRIDGE_DIR/workspaces/claude-code/state/feishu-bridge"
mkdir -p "$LOG_DIR"
echo "✅ 目录创建完成"
echo ""

# 5. 配置 MCP
echo "[5/6] 配置 MCP..."
MCP_CONFIG="$BRIDGE_DIR/workspaces/claude-code/.claude/.mcp.json"
if [ ! -f "$MCP_CONFIG" ]; then
    mkdir -p "$(dirname "$MCP_CONFIG")"
    cat > "$MCP_CONFIG" << 'MCPEOF'
{
  "mcpServers": {
    "web-search": {
      "command": "/opt/homebrew/bin/python3",
      "args": ["<BRIDGE_DIR>/workspaces/claude-code/.claude/mcp-servers/web_search.py"],
      "description": "网页搜索（Bing，无需 API Key）"
    }
  }
}
MCPEOF
    echo "✅ MCP 配置已创建: $MCP_CONFIG"
else
    echo "✅ MCP 配置已存在: $MCP_CONFIG"
fi
echo ""

# 6. 启动服务
echo "[6/6] 启动桥接服务..."
if [ -f "$SCRIPT_DIR/start-bridge.sh" ]; then
    bash "$SCRIPT_DIR/start-bridge.sh"
else
    echo "⚠️ 未找到 start-bridge.sh，请手动启动："
    echo "  source $CONFIG_DIR/.env"
    echo "  $VENV_DIR/bin/feishu-bridge --config $CONFIG_DIR/config.json --bot claude-code --log-level INFO"
fi
echo ""

echo "========================================="
echo "  安装完成！"
echo "========================================="
echo ""
echo "下一步："
echo "  1. 在飞书中给机器人发消息测试"
echo "  2. 查看状态: bash scripts/status.sh"
echo "  3. 查看日志: tail -f $LOG_DIR/bridge.log"
echo ""
