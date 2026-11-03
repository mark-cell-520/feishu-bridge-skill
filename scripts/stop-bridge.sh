#!/bin/bash
# feishu-bridge 停止脚本（跨平台：macOS / Linux）
# 对应 SKILL.md 目录结构里一直列着、但仓库里从来没有的那个文件。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/platform.sh"
platform::init

if [ -z "$(platform::service_status)" ]; then
    platform::info "ℹ️ 服务未在运行"
    exit 0
fi

platform::info "停止 ${BRIDGE_LABEL}（$PLATFORM_OS/${PLATFORM_INIT}）..."
platform::service_stop

# bootout / systemctl stop 都是异步的，给一点时间让进程退出
for _ in 1 2 3 4 5; do
    [ -z "$(platform::service_status)" ] && break
    sleep 1
done

if [ -n "$(platform::service_status)" ]; then
    platform::warn "仍在运行，强杀..."
    ROW="$(platform::service_status)"
    PID="$(printf '%s' "$ROW" | awk '{print $1}')"
    case "${PID:-}" in
        ''|-) ;;
        *) kill "$PID" 2>/dev/null || true ;;
    esac
    sleep 1
fi

if [ -n "$(platform::service_status)" ]; then
    platform::err "停止失败"
    exit 1
fi
platform::info "✅ 已停止"
