#!/bin/bash
# restart-bridge.sh — 一键重启桥接（含补丁生效检查）
#
# 为什么需要它：patch-post-image.sh 与 patch-ui.sh 改的都是 pip 包内的
# 代码，必须重启桥接才生效。而手动重启要跑两条命令、还要记住顺序，
# 补丁打完忘了重启是常见的"改了却没生效"。
#
# 这个脚本做三件事：停 → 起 → 报告补丁是否生效。
#
# 注意：重启会中断当前正在处理的会话。若你是在飞书里让机器人自己重启，
#   机器人这条回复可能发不出去——所以更适合由你在终端手动执行。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/platform.sh"
platform::init

echo "平台: $PLATFORM_OS / $PLATFORM_INIT"
echo

echo "── 1/3 停止 ─────────────────────────────"
bash "$SCRIPT_DIR/stop-bridge.sh" || true
sleep 2

echo
echo "── 2/3 启动 ─────────────────────────────"
if ! bash "$SCRIPT_DIR/start-bridge.sh"; then
    echo
    platform::err "启动失败，最后 20 行错误日志："
    tail -20 "$LOG_DIR/bridge.err.log" 2>/dev/null
    exit 1
fi

echo
echo "── 3/3 补丁生效检查 ─────────────────────"
# 补丁改的是 pip 包内代码，重启后才加载。这里确认两个补丁都在位。
for p in patch-ui.sh patch-post-image.sh patch-tool-list.sh; do
    [ -f "$SCRIPT_DIR/$p" ] || continue
    STATE="$(bash "$SCRIPT_DIR/$p" status 2>/dev/null | grep '补丁状态:' | awk '{print $2}')"
    case "$p" in
        patch-ui.sh)         DESC="禁用失效的 agent_status 元素" ;;
        patch-post-image.sh) DESC="图文混排时提取图片" ;;
        patch-tool-list.sh)  DESC="工具调用列表编号逐行显示" ;;
        *)                   DESC="$p" ;;
    esac
    if [ "$STATE" = "已打" ]; then
        echo "  ✅ ${DESC}：补丁在位，本次重启已加载"
    else
        echo "  ℹ️ ${DESC}：未打补丁（bash scripts/$p apply）"
    fi
done

echo
echo "── 健康检查 ─────────────────────────────"
bash "$SCRIPT_DIR/health-check.sh" 2>&1 | head -18
echo
echo "重启完成。现在发一条图文混排的消息，图片应该能收到了。"
