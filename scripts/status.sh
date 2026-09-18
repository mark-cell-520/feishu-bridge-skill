#!/bin/bash
# feishu-bridge 状态检查脚本

CONFIG_DIR="$HOME/.config/feishu-bridge"
LOG_DIR="$HOME/.local/share/feishu-bridge/logs"

echo "========================================="
echo "  飞书桥接服务状态"
echo "========================================="
echo ""

# 检查服务状态
if launchctl list | grep -q "com.feishu.bridge"; then
    PID=$(launchctl list com.feishu.bridge | head -1 | awk '{print $1}')
    STATUS=$(launchctl list com.feishu.bridge | head -1 | awk '{print $2}')

    if [ "$STATUS" = "0" ]; then
        echo "✅ 服务运行中 (PID: $PID)"
    else
        echo "⚠️ 服务异常 (PID: $PID, Exit code: $STATUS)"
    fi
else
    echo "❌ 服务未运行"
fi
echo ""

# 检查配置
if [ -f "$CONFIG_DIR/.env" ]; then
    echo "✅ 配置文件存在: $CONFIG_DIR/.env"
    source "$CONFIG_DIR/.env"
    echo "   APP_ID: ${FEISHU_APP_ID:0:15}..."
else
    echo "❌ 配置文件缺失: $CONFIG_DIR/.env"
fi
echo ""

# 检查日志
if [ -d "$LOG_DIR" ]; then
    echo "📄 日志目录: $LOG_DIR"
    if [ -f "$LOG_DIR/bridge-stdout.log" ]; then
        echo "   最后 5 行:"
        tail -5 "$LOG_DIR/bridge-stdout.log" | sed 's/^/      /'
    fi
else
    echo "❌ 日志目录不存在"
fi
echo ""

# 检查健康
echo "🏥 健康检查..."
curl -s http://127.0.0.1:8090/health 2>/dev/null || echo "   (健康检查端点未配置)"
echo ""
echo "========================================="
