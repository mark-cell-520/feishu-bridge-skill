#!/bin/bash
# feishu-bridge 停止脚本
# 对应 SKILL.md 目录结构里一直列着、但仓库里从来没有的那个文件。
set -uo pipefail

LABEL="com.feishu.bridge"

if ! launchctl list | grep -q "$LABEL"; then
    echo "ℹ️ 服务未在运行"
    exit 0
fi

echo "停止 $LABEL ..."
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

# bootout 是异步的，给一点时间让进程退出
for _ in 1 2 3 4 5; do
    launchctl list | grep -q "$LABEL" || break
    sleep 1
done

if launchctl list | grep -q "$LABEL"; then
    echo "⚠️ 仍在运行，强杀..." >&2
    PID=$(launchctl list "$LABEL" | head -1 | awk '{print $1}')
    [ -n "${PID//-/}" ] && kill "$PID" 2>/dev/null || true
    sleep 1
fi

if launchctl list | grep -q "$LABEL"; then
    echo "❌ 停止失败" >&2
    exit 1
fi
echo "✅ 已停止"
