#!/bin/bash
# watchdog.sh — 服务看护（跨平台）
#
# 为什么 launchd 的 KeepAlive 不够：
#   KeepAlive 只保证"进程活着"。进程活着但不服务是另一种故障——
#   WebSocket 断连后没重连、控制套接字无响应、事件循环卡死。
#   本机实测出现过 "3 consecutive failures for agent_status —
#   streaming/agent_status may be stalled"，进程 PID 一直在，但流式
#   状态更新已经废了。这类假死 KeepAlive 看不见。
#
# 三层检查，从轻到重：
#   1. 进程在不在（服务管理器视角）
#   2. 控制套接字能否响应（真的能干活）
#   3. 错误日志是否还在写（没有彻底僵住）
#   任一层不过且连续超过阈值 → 重启，带冷却期防重启风暴。
#
# 用法：
#   bash scripts/watchdog.sh --once          单次检查（默认）
#   bash scripts/watchdog.sh --loop          常驻循环（每 60s）
#   bash scripts/watchdog.sh --install       装成定时任务（launchd/systemd timer）
#   bash scripts/watchdog.sh --uninstall     卸载定时任务
#
# 环境变量：
#   FEISHU_WATCHDOG_INTERVAL   检查间隔秒（默认 60）
#   FEISHU_WATCHDOG_THRESHOLD  连续异常几次才重启（默认 2）
#   FEISHU_WATCHDOG_COOLDOWN   重启后静默秒（默认 300）
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/platform.sh"
platform::init

INTERVAL="${FEISHU_WATCHDOG_INTERVAL:-60}"
THRESHOLD="${FEISHU_WATCHDOG_THRESHOLD:-2}"
COOLDOWN="${FEISHU_WATCHDOG_COOLDOWN:-300}"
WD_LOG="$LOG_DIR/watchdog.log"
STATE_FILE="$STATE_HOME/watchdog-state.json"

mkdir -p "$LOG_DIR" "$STATE_HOME" 2>/dev/null || true

wd_log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$WD_LOG" 2>/dev/null || true
    printf '%s\n' "$*"
}

# ── 三层检查 ────────────────────────────────────────────────────
# 返回 0 = 健康；非 0 = 异常码（1 进程不在 / 2 套接字不通 / 3 日志僵住）
check_health() {
    # 第一层：进程
    if [ -z "$(platform::service_status)" ]; then
        return 1
    fi

    # 第二层：控制套接字（Windows 无 Unix socket，跳过这层）
    if [ "$PLATFORM_OS" != "windows" ]; then
        SOCK="$(platform::control_socket)"
        TOKENF="$(platform::control_token)"
        if [ -S "$SOCK" ] && [ -r "$TOKENF" ] && [ -n "$PLATFORM_PYTHON" ]; then
            # 注意两点，都是踩过的坑：
            # 1. 传给 Python 的是 token 文件路径，内容由 Python 自己读。
            #    把路径当 token 发出去，服务回 401，watchdog 误判成假死。
            # 2. 必须用 || rc=$? 捕退出码，不能用 $(...) 捕获 stdout——
            #    命令替换拿到的是标准输出，而探测成功时 Python 静默退出 0，
            #    于是 OK 恒为空字符串，健康也被判成故障。
            PROBE_RC=0
            "$PLATFORM_PYTHON" - "$SOCK" "$TOKENF" <<'PY' 2>/dev/null || PROBE_RC=$?
import json, socket, sys
sock_path, token_path = sys.argv[1], sys.argv[2]
try:
    token = open(token_path).read().strip()
except OSError:
    sys.exit(2)
req = json.dumps({"id": 1, "token": token, "method": "status", "params": {}})
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(8)
    s.connect(sock_path)
    s.sendall(req.encode() + b"\n")
    buf = b""
    while b"\n" not in buf:
        c = s.recv(65536)
        if not c:
            break
        buf += c
    s.close()
    d = json.loads(buf.decode("utf-8", "replace").strip() or "{}")
    # 401 说明 token 读错了或过期，那是 watchdog 自己的问题，不当服务故障
    if (d.get("error") or {}).get("code") == 401:
        sys.exit(3)
    sys.exit(0 if (d.get("ok") or "result" in d) else 1)
except Exception:
    sys.exit(1)
PY
            case "$PROBE_RC" in
                0) ;;  # 健康
                3) wd_log "⚠️ 控制套接字鉴权失败（token 读取问题），本次不判服务故障" ;;
                *) return 2 ;;
            esac
        fi
    fi

    # 第三层：错误日志新鲜度（超过 3 倍间隔没写入视为僵住）
    # 注意：空闲时日志本来就不写，所以这一层只在"曾经写过"的前提下判，
    # 且阈值放宽到 3 倍间隔，避免把正常闲置误判成僵死。
    if [ -f "$LOG_DIR/bridge.err.log" ]; then
        MT="$(platform::stat_mtime "$LOG_DIR/bridge.err.log" || echo '')"
        if [ -n "$MT" ]; then
            AGE=$(( $(date +%s) - MT ))
            STALE_LIMIT=$(( INTERVAL * 3 ))
            if [ "$AGE" -gt "$STALE_LIMIT" ]; then
                # 再确认一次服务是否真的在跑，避免误判
                if [ -n "$(platform::service_status)" ]; then
                    return 3
                fi
            fi
        fi
    fi

    return 0
}

# ── 状态读写（跨重启保留连续计数）──────────────────────────────
read_fails() {
    [ -f "$STATE_FILE" ] || { echo 0; return; }
    "$PLATFORM_PYTHON" -c "
import json,sys
try: print(int(json.load(open(sys.argv[1])).get('consecutive_fails',0)))
except Exception: print(0)" "$STATE_FILE" 2>/dev/null || echo 0
}

write_state() {
    local fails="$1" last_restart="$2"
    [ -n "$PLATFORM_PYTHON" ] || return 0
    "$PLATFORM_PYTHON" - "$STATE_FILE" "$fails" "$last_restart" <<'PY' 2>/dev/null || true
import json, sys, os
path, fails, last = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
try:
    d = json.load(open(path))
except Exception:
    d = {}
d["consecutive_fails"] = fails
d["last_restart_epoch"] = last
d["updated"] = os.popen("date +%s").read().strip()
json.dump(d, open(path, "w"), indent=2)
PY
}

restart_service() {
    wd_log "执行重启: bash scripts/stop-bridge.sh && start-bridge.sh"
    bash "$SCRIPT_DIR/stop-bridge.sh" >/dev/null 2>&1 || true
    sleep 2
    if bash "$SCRIPT_DIR/start-bridge.sh" >/dev/null 2>&1; then
        wd_log "✅ 重启成功"
        return 0
    fi
    wd_log "❌ 重启失败，查看 $LOG_DIR/bridge.err.log"
    return 1
}

# ── 单次检查 ────────────────────────────────────────────────────
run_once() {
    check_health
    local rc=$?
    local fails last_restart now
    fails="$(read_fails)"
    last_restart="$("$PLATFORM_PYTHON" -c "
import json,sys
try: print(int(json.load(open(sys.argv[1])).get('last_restart_epoch',0)))
except Exception: print(0)" "$STATE_FILE" 2>/dev/null || echo 0)"
    now="$(date +%s)"

    if [ "$rc" -eq 0 ]; then
        if [ "$fails" != "0" ]; then
            wd_log "服务恢复正常（此前连续异常 ${fails} 次）"
        fi
        write_state 0 "${last_restart:-0}"
        return 0
    fi

    fails=$(( fails + 1 ))
    local reason
    case "$rc" in
        1) reason="进程不在" ;;
        2) reason="控制套接字无响应（假死）" ;;
        3) reason="错误日志超过 $(( INTERVAL * 3 ))s 无写入（可能僵住）" ;;
        *) reason="未知异常 rc=$rc" ;;
    esac

    wd_log "⚠️ 异常: ${reason}（连续第 ${fails} 次，阈值 ${THRESHOLD}）"

    # 冷却期内不重启，避免重启风暴
    if [ -n "$last_restart" ] && [ "$last_restart" != "0" ]; then
        local since=$(( now - last_restart ))
        if [ "$since" -lt "$COOLDOWN" ]; then
            wd_log "   处于冷却期（距上次重启 ${since}s < ${COOLDOWN}s），本次不动作"
            write_state "$fails" "$last_restart"
            return 1
        fi
    fi

    if [ "$fails" -ge "$THRESHOLD" ]; then
        restart_service
        write_state 0 "$now"
    else
        write_state "$fails" "${last_restart:-0}"
    fi
    return 1
}

# ── 定时任务安装 ────────────────────────────────────────────────
install_timer() {
    case "$PLATFORM_INIT" in
        launchd)
            local PLIST="$HOME/Library/LaunchAgents/$BRIDGE_LABEL.watchdog.plist"
            cat > "$PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$BRIDGE_LABEL.watchdog</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SCRIPT_DIR/watchdog.sh</string>
        <string>--once</string>
    </array>
    <key>StartInterval</key>
    <integer>$INTERVAL</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$WD_LOG</string>
    <key>StandardErrorPath</key>
    <string>$WD_LOG</string>
</dict>
</plist>
EOF
            launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null \
                && platform::info "✅ 已安装 watchdog 定时任务（每 ${INTERVAL}s）: $PLIST" \
                || platform::err "安装失败（可能已存在，先 --uninstall）"
            ;;
        systemd)
            local DIR="$HOME/.config/systemd/user"
            mkdir -p "$DIR"
            cat > "$DIR/$BRIDGE_LABEL.watchdog.service" << EOF
[Unit]
Description=Feishu Bridge watchdog

[Service]
Type=oneshot
ExecStart=/bin/bash $SCRIPT_DIR/watchdog.sh --once
EOF
            cat > "$DIR/$BRIDGE_LABEL.watchdog.timer" << EOF
[Unit]
Description=Feishu Bridge watchdog timer

[Timer]
OnBootSec=30
OnUnitActiveSec=${INTERVAL}s

[Install]
WantedBy=timers.target
EOF
            systemctl --user daemon-reload 2>/dev/null
            systemctl --user enable --now "$BRIDGE_LABEL.watchdog.timer" 2>/dev/null \
                && platform::info "✅ 已安装 watchdog timer（每 ${INTERVAL}s）" \
                || platform::err "安装失败"
            ;;
        *)
            platform::err "该平台无受支持的服务管理器（${PLATFORM_INIT}），可改用 --loop 前台看护"
            return 1
            ;;
    esac
}

uninstall_timer() {
    case "$PLATFORM_INIT" in
        launchd)
            launchctl bootout "gui/$(id -u)/$BRIDGE_LABEL.watchdog" 2>/dev/null || true
            rm -f "$HOME/Library/LaunchAgents/$BRIDGE_LABEL.watchdog.plist"
            platform::info "✅ 已卸载 watchdog 定时任务"
            ;;
        systemd)
            systemctl --user disable --now "$BRIDGE_LABEL.watchdog.timer" 2>/dev/null || true
            rm -f "$HOME/.config/systemd/user/$BRIDGE_LABEL.watchdog".{service,timer}
            systemctl --user daemon-reload 2>/dev/null
            platform::info "✅ 已卸载 watchdog timer"
            ;;
        *)
            platform::err "该平台无受支持的服务管理器（${PLATFORM_INIT}）"
            return 1
            ;;
    esac
}

# ── 入口 ────────────────────────────────────────────────────────
case "${1:---once}" in
    --once)      run_once ;;
    --loop)
        wd_log "watchdog 常驻看护启动（间隔 ${INTERVAL}s，阈值 ${THRESHOLD}，冷却 ${COOLDOWN}s）"
        while true; do
            run_once || true
            sleep "$INTERVAL"
        done
        ;;
    --install)   install_timer ;;
    --uninstall) uninstall_timer ;;
    *) platform::err "未知参数: $1（可用 --once/--loop/--install/--uninstall）"; exit 1 ;;
esac
