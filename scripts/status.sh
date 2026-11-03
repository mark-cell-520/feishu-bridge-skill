#!/bin/bash
# feishu-bridge 状态检查脚本（跨平台：macOS / Linux）
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/platform.sh"
platform::init

echo "========================================="
echo "  飞书桥接服务状态"
echo "========================================="
echo ""

# 1. 服务状态（平台差异已在 platform.sh 收敛成统一的 "PID<TAB>退出码" 两列）
echo "平台: $PLATFORM_OS / 服务管理器: $PLATFORM_INIT"
if [ "$PLATFORM_INIT" = "none" ] || [ "$PLATFORM_INIT" = "windows" ]; then
    echo "⚠️ 该平台无法托管为系统服务，只能前台运行"
    echo "   前台启动: bash $WRAPPER"
    echo ""
fi

ROW="$(platform::service_status)"
if [ -n "$ROW" ]; then
    PID="$(printf '%s' "$ROW" | awk '{print $1}')"
    EXIT="$(printf '%s' "$ROW" | awk '{print $2}')"
    if [ "$EXIT" = "0" ]; then
        echo "✅ 服务运行中 (PID: $PID)"
    else
        echo "⚠️ 服务异常 (PID: ${PID:--}, 上次退出码: $EXIT)"
        echo "   非零退出码通常意味着起来后又崩了，先看错误日志。"
    fi
else
    echo "❌ 服务未运行"
    echo "   启动: bash scripts/start-bridge.sh"
fi
echo ""

# 2. 配置文件
if [ -f "$CONFIG_DIR/.env" ]; then
    echo "✅ .env 存在: $CONFIG_DIR/.env"
    # 只取 App ID 前 12 位，Secret 一概不打印
    AID=$(grep -m1 '^FEISHU_APP_ID=' "$CONFIG_DIR/.env" | cut -d= -f2 | tr -d '"'"'" )
    [ -n "$AID" ] && echo "   APP_ID: ${AID:0:12}..."
    if grep -q '^FEISHU_APP_SECRET=..*' "$CONFIG_DIR/.env"; then
        echo "   APP_SECRET: 已设置（不回显）"
    else
        echo "   ⚠️ APP_SECRET 为空"
    fi
else
    echo "❌ .env 缺失: $CONFIG_DIR/.env"
    echo "   配置: bash scripts/setup.sh"
fi

if [ -f "$CONFIG_DIR/config.json" ]; then
    echo "✅ config.json 存在"
else
    echo "❌ config.json 缺失: $CONFIG_DIR/config.json"
fi
echo ""

# 3. 日志（真实文件名是 bridge.log / bridge.err.log，不是 bridge-stdout/-stderr）
if [ -d "$LOG_DIR" ]; then
    echo "📄 日志目录: $LOG_DIR"
    for f in "$LOG_DIR/bridge.log" "$LOG_DIR/bridge.err.log"; do
        if [ -f "$f" ]; then
            SZ=$(wc -c < "$f" | tr -d ' ')
            # mtime 取法跨平台：BSD 是 date -r <file>，GNU 也是 -r <file>，
            # 但为免歧义统一走 platform::stat_mtime 拿 epoch 再格式化。
            MT="$(platform::stat_mtime "$f" || echo '')"
            if [ -n "$MT" ]; then
                echo "   $(basename "$f"): ${SZ} 字节, 最后修改 $(date -r "$MT" '+%m-%d %H:%M')"
            else
                echo "   $(basename "$f"): ${SZ} 字节"
            fi
        fi
    done
    ERRLOG="$LOG_DIR/bridge.err.log"
    if [ -f "$ERRLOG" ]; then
        echo ""
        echo "   错误日志最后 10 行:"
        tail -10 "$ERRLOG" | sed 's/^/      /'
    fi
else
    echo "❌ 日志目录不存在: $LOG_DIR"
fi
echo ""

# 4. 权限设置物化副本（每次启动都会被包内版本覆盖，见 references/troubleshooting.md）
BS="$STATE_HOME/bridge-settings.json"
echo "🔐 权限设置: $BS"
if [ -f "$BS" ]; then
    MODE=$("$PLATFORM_PYTHON" -c "import json,sys;print(json.load(open(sys.argv[1])).get('permissions',{}).get('defaultMode','?'))" "$BS" 2>/dev/null || echo "?")
    DENY=$("$PLATFORM_PYTHON" -c "import json,sys;print(len(json.load(open(sys.argv[1])).get('permissions',{}).get('deny') or []))" "$BS" 2>/dev/null || echo "?")
    echo "   defaultMode = $MODE, deny 条数 = $DENY"
    echo "   注意：此文件每次桥接启动都会被包内 data/bridge-settings.json 无条件覆盖，"
    echo "   要改就改包内那一份，别改这份。"
else
    echo "   （尚未物化，首次启动后出现）"
fi
echo ""
echo "========================================="
