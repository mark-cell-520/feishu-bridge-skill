#!/bin/bash
# feishu-bridge 健康检查（跨平台：macOS / Linux）
#
# 输出 JSON（供其他工具消费），字段见下。
#
# 探针来源（本机实测，2026-10-13）：
#   上游版本用 curl http://127.0.0.1:8090/health —— 那个端口根本没有监听，
#   curl 永远失败，于是健康检查永远走 "(健康检查端点未配置)" 分支。
#   真实探针是桥接自带的管理套接字：
#     ~/.feishu-bridge/control-claude-code.sock   （Unix socket，换行分隔 JSON）
#     ~/.feishu-bridge/control-claude-code.token  （同一份 token，0600）
#   协议：{"id":1,"token":"<token>","method":"status","params":{}}
#   方法表见 feishu_bridge/control_api.py：health / status / config / sessions /
#   quota / logs / tasks / set_model / set_agent / stop_session / shutdown。
#   其中 health 只返回 {"ok":True} 不验证任何东西，真正有信息量的是 status。
#
# v2.0.0 跨平台：Unix domain socket 是 POSIX 能力，Windows 原生没有
#   （桥接若在 Windows 提供 named pipe 则另说）。所以 Windows 上不是
#   "探测失败"，而是明确在输出里声明 probe=unsupported-platform，
#   避免把"没探到"误读成"不健康"。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/platform.sh"
platform::init

CTRL_DIR="$STATE_HOME"
SOCK="$(platform::control_socket)"
TOKENF="$(platform::control_token)"
STATE_DIR="$BRIDGE_DIR/workspaces/$BRIDGE_BOT/state/feishu-bridge"

fail() { echo "{\"ok\": false, \"error\": \"$1\"}"; exit 1; }

# 服务在不在：平台抽象已把 launchd/systemd 收敛成同一格式
[ -n "$(platform::service_status)" ] || fail "服务未运行"
[ -f "$CONFIG_DIR/.env" ] || fail "配置缺失: $CONFIG_DIR/.env"
[ -f "$CONFIG_DIR/config.json" ] || fail "配置缺失: $CONFIG_DIR/config.json"

APP_ID=$(grep -m1 '^FEISHU_APP_ID=' "$CONFIG_DIR/.env" | cut -d= -f2 | tr -d '"'"'" )

SESSIONS=0
QUEUE_DEPTH=0
QUOTA="unknown"
PROBE="launchd-only"
# 平台无 Unix socket 时改写探针名，让消费方知道这是能力缺失而非故障
if [ "$PLATFORM_OS" = "windows" ]; then
    PROBE="unsupported-platform"
fi

if [ "$PROBE" != "unsupported-platform" ] && [ -S "$SOCK" ] && [ -r "$TOKENF" ]; then
    TOKEN=$(cat "$TOKENF" 2>/dev/null || true)
    if [ -n "$TOKEN" ]; then
        RESP=$("$PLATFORM_PYTHON" - "$SOCK" "$TOKEN" <<'PY' 2>/dev/null
import json, socket, sys
sock_path, token = sys.argv[1], sys.argv[2]
req = json.dumps({"id": 1, "token": token, "method": "status", "params": {}})
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(8)
    s.connect(sock_path)
    s.sendall(req.encode() + b"\n")
    buf = b""
    while b"\n" not in buf:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    s.close()
    print(buf.decode("utf-8", "replace").strip())
except Exception as e:
    sys.stderr.write(str(e))
PY
)
        if [ -n "$RESP" ]; then
            PROBE="control-socket"
            PARSED=$(printf '%s' "$RESP" | "$PLATFORM_PYTHON" -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: print('|||'); sys.exit()
r=d.get('result') or {}
sess=r.get('sessions') or {}
q=r.get('queue') or {}
quota=r.get('quota') or {}
active=sess.get('active', sess.get('active_count', 0)) or 0
pend=q.get('pending') or {}
if isinstance(pend,dict):
    pending=sum(len(v) if isinstance(v,list) else 0 for v in pend.values())
else:
    pending=0
avail=quota.get('available')
# 原样透传成 JSON 字面量：布尔就是 true/false，缺了就 null
if isinstance(avail,bool): avail_s=json.dumps(avail)
elif avail is None: avail_s='null'
else: avail_s=json.dumps(avail)
print(f'{active}|{pending}|{avail_s}')
" 2>/dev/null)
            if [ -n "$PARSED" ] && [ "$PARSED" != "|||" ]; then
                SESSIONS=$(printf '%s' "$PARSED" | cut -d'|' -f1)
                QUEUE_DEPTH=$(printf '%s' "$PARSED" | cut -d'|' -f2)
                # quota.available 是布尔（配额数据是否就绪），不是配额余量，原样透传
                QUOTA_RAW=$(printf '%s' "$PARSED" | cut -d'|' -f3)
            fi
        fi
    fi
fi

# 套接字不可用时的退化口径：从会话状态文件数 chat 数
if [ "$SESSIONS" = "0" ] && [ "$PROBE" = "launchd-only" ]; then
    if [ -f "$STATE_DIR/sessions-$BRIDGE_BOT.json" ]; then
        SESSIONS=$(grep -o 'oc_[a-z0-9]\{8,\}' "$STATE_DIR/sessions-$BRIDGE_BOT.json" | sort -u | wc -l | tr -d ' ')
        PROBE="state-file-fallback"
    fi
fi

# 日志新鲜度：错误日志 5 分钟内有过写入视为活跃
# mtime 取法跨平台（BSD -f%m / GNU -c%Y），已收敛进 platform::stat_mtime
LOG_AGE="unknown"
if [ -f "$LOG_DIR/bridge.err.log" ]; then
    MT="$(platform::stat_mtime "$LOG_DIR/bridge.err.log" || echo '')"
    if [ -n "$MT" ]; then
        AGE=$(( $(date +%s) - MT ))
        LOG_AGE="${AGE}s"
    fi
fi

cat << EOF
{
  "ok": true,
  "platform": "$PLATFORM_OS",
  "initManager": "$PLATFORM_INIT",
  "feishuApp": "${APP_ID}",
  "service": "running",
  "probe": "${PROBE}",
  "sessions": ${SESSIONS:-0},
  "queuePending": ${QUEUE_DEPTH:-0},
  "quotaDataAvailable": ${QUOTA_RAW:-null},
  "errLogAge": "${LOG_AGE}",
  "config": "${CONFIG_DIR}",
  "logs": "${LOG_DIR}"
}
EOF
