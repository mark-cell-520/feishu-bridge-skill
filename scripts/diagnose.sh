#!/bin/bash
# diagnose.sh — 一键诊断报告（跨平台）
#
# 存在的理由：桥接出问题时，人工排查要跑十几条命令，还容易漏。
#   这个脚本把"平台能力 → 服务 → 配置 → 权限 → 日志 → API 连通性 →
#   控制套接字 → 媒体目录 → agent 可执行文件 → 磁盘"一次跑完，
#   输出一份可直接粘贴到 issue 的报告。
#
# 脱敏约定：App Secret、token 一概不回显，只报"已设置/为空"。
#   App ID 取前 12 位，足够定位是哪个应用又不泄露全量。
#
# 用法：
#   bash scripts/diagnose.sh            # 人读报告
#   bash scripts/diagnose.sh --json     # 机器可读
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/platform.sh"
platform::init

JSON=0
[ "${1:-}" = "--json" ] && JSON=1

# ── 收集器：每条检查记 name/status/detail ───────────────────────
# status: ok | warn | fail | info
RESULTS=""
add() { RESULTS="${RESULTS}${1}|${2}|${3}"$'\n'; }

# ── 1. 平台能力 ─────────────────────────────────────────────────
if [ -n "$PLATFORM_PYTHON" ]; then
    PYV="$("$PLATFORM_PYTHON" -c 'import sys;print("%d.%d.%d"%sys.version_info[:3])' 2>/dev/null || echo '?')"
    # 探测到的 python 未必是桥接实际用的那个。wrapper 会优先选 app bundle
    # 里的固化解释器（FDA 授权挂在那条路径上），PATH 里的 python3 只是
    # 本脚本自己用的。两个版本可能差很远，报成同一个数会让人以为桥接
    # 跑在这个版本上——本机实测：脚本侧 3.14.8，桥接侧 3.11.17。
    BRIDGE_PY="服务未运行，无法确认"
    SVC_PID="$(platform::service_status 2>/dev/null | awk '{print $1}')"
    if [ -n "$SVC_PID" ]; then
        REAL_PY="$(ps -o command= -p "$SVC_PID" 2>/dev/null | awk '{print $1}')"
        if [ -n "$REAL_PY" ] && [ -x "$REAL_PY" ]; then
            RPV="$("$REAL_PY" -c 'import sys;print("%d.%d.%d"%sys.version_info[:3])' 2>/dev/null || echo '?')"
            BRIDGE_PY="$REAL_PY ($RPV)"
        fi
    fi
    add "platform" "ok" \
        "$PLATFORM_OS / $PLATFORM_INIT / 脚本用 $PLATFORM_PYTHON ($PYV) / 桥接用 $BRIDGE_PY"
else
    add "platform" "fail" "$PLATFORM_OS / $PLATFORM_INIT / Python 未找到"
fi
case "$PLATFORM_INIT" in
    none|windows)
        add "service_manager" "warn" "$PLATFORM_INIT 不能托管为系统服务，只能前台运行"
        ;;
esac

# ── 2. 服务状态 ─────────────────────────────────────────────────
ROW="$(platform::service_status)"
if [ -n "$ROW" ]; then
    PID="$(printf '%s' "$ROW" | awk '{print $1}')"
    EXIT="$(printf '%s' "$ROW" | awk '{print $2}')"
    if [ "$EXIT" = "0" ]; then
        add "service" "ok" "运行中 PID=$PID"
    else
        add "service" "fail" "异常 PID=${PID:--} 上次退出码=$EXIT"
    fi
else
    add "service" "fail" "未运行（bash scripts/start-bridge.sh 启动）"
fi

# ── 3. 配置 ─────────────────────────────────────────────────────
if [ -f "$CONFIG_DIR/.env" ]; then
    AID="$(grep -m1 '^FEISHU_APP_ID=' "$CONFIG_DIR/.env" 2>/dev/null | cut -d= -f2 | tr -d '"'"'" )"
    if grep -q '^FEISHU_APP_SECRET=..*' "$CONFIG_DIR/.env" 2>/dev/null; then
        SEC="已设置"
    else
        SEC="为空"
    fi
    add "env_file" "ok" ".env 存在，APP_ID=${AID:0:12}...，SECRET=$SEC"
    [ "$SEC" = "为空" ] && add "env_file" "fail" ".env 存在但 APP_SECRET 为空"
else
    add "env_file" "fail" "缺失 $CONFIG_DIR/.env（bash scripts/setup.sh 配置）"
fi

if [ -f "$CONFIG_DIR/config.json" ]; then
    BOTS="$("$PLATFORM_PYTHON" -c "
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    b=d.get('bots') or []
    print(','.join(x.get('name','?') for x in b) or '无')
except Exception as e:
    print('解析失败')" "$CONFIG_DIR/config.json" 2>/dev/null || echo '?')"
    add "config_json" "ok" "存在，bots=[$BOTS]"
else
    add "config_json" "fail" "缺失 $CONFIG_DIR/config.json"
fi

# ── 4. 权限设置物化副本 ─────────────────────────────────────────
BS="$STATE_HOME/bridge-settings.json"
if [ -f "$BS" ]; then
    MODE="$("$PLATFORM_PYTHON" -c "
import json,sys
try: print(json.load(open(sys.argv[1])).get('permissions',{}).get('defaultMode','?'))
except Exception: print('?')" "$BS" 2>/dev/null || echo '?')"
    add "permissions" "info" "defaultMode=${MODE}（此文件每次启动被包内版本覆盖，要改得改包内那份）"
else
    add "permissions" "info" "尚未物化，首次启动后出现"
fi

# ── 5. 日志 ─────────────────────────────────────────────────────
ERRLOG="$LOG_DIR/bridge.err.log"
if [ -f "$ERRLOG" ]; then
    MT="$(platform::stat_mtime "$ERRLOG" || echo '')"
    if [ -n "$MT" ]; then
        AGE=$(( $(date +%s) - MT ))
        SZ="$(wc -c < "$ERRLOG" | tr -d ' ')"
        if [ "$AGE" -lt 300 ]; then
            add "err_log" "ok" "${SZ} 字节，${AGE}s 前有写入"
        else
            add "err_log" "warn" "${SZ} 字节，已 ${AGE}s 无写入（服务可能空转）"
        fi
        # 最近错误的分类统计，比直接 tail 更能看出是不是同一个错在刷屏。
        # 注意这是"日志文件自创建起"的累计值，不是本次进程启动后的增量——
        # 补丁是否生效要看增量，累计值只能看历史包袱有多重。
        TOP="$("$PLATFORM_PYTHON" - "$ERRLOG" <<'PY' 2>/dev/null
import re, sys, collections
pat = re.compile(r"(ERROR|WARNING|CRITICAL)\s+(.{0,80})")
c = collections.Counter()
try:
    with open(sys.argv[1], errors="replace") as f:
        for line in f:
            m = pat.search(line)
            if m:
                c[f"{m.group(1)} {m.group(2).strip()[:60]}"] += 1
except OSError:
    pass
for msg, n in c.most_common(3):
    print(f"{n}x {msg}")
PY
)"
        # RESULTS 用换行做行分隔，detail 里不能带换行，先把多行压成一行
        [ -n "$TOP" ] && add "err_log_top" "info" "$(printf '%s' "$TOP" | tr '\n' '@' | sed 's/@/ | /g')"
    fi
else
    add "err_log" "warn" "错误日志不存在: $ERRLOG"
fi

# ── 6. 飞书 API 连通性 ──────────────────────────────────────────
if [ -f "$CONFIG_DIR/.env" ] && [ -n "$PLATFORM_PYTHON" ]; then
    API_RESULT="$("$PLATFORM_PYTHON" - "$CONFIG_DIR/.env" <<'PY' 2>/dev/null
import json, sys, urllib.request
env = {}
for line in open(sys.argv[1], errors="replace"):
    line = line.strip()
    if "=" in line and not line.startswith("#"):
        k, v = line.split("=", 1)
        env[k] = v.strip().strip('"').strip("'")
req = urllib.request.Request(
    "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal",
    data=json.dumps({"app_id": env.get("FEISHU_APP_ID", ""),
                     "app_secret": env.get("FEISHU_APP_SECRET", "")}).encode(),
    headers={"Content-Type": "application/json"})
try:
    r = json.load(urllib.request.urlopen(req, timeout=15))
    print("ok" if r.get("code") == 0 else f"fail:{r.get('code')}:{r.get('msg')}")
except Exception as e:
    print(f"fail:{type(e).__name__}:{str(e)[:60]}")
PY
)"
    case "$API_RESULT" in
        ok)   add "feishu_api" "ok" "tenant_access_token 获取成功" ;;
        fail:*) add "feishu_api" "fail" "凭证或网络问题: $API_RESULT" ;;
        *)    add "feishu_api" "warn" "未检测（${API_RESULT}）" ;;
    esac
fi

# ── 7. 控制套接字 ───────────────────────────────────────────────
SOCK="$(platform::control_socket)"
if [ "$PLATFORM_OS" = "windows" ]; then
    add "control_socket" "info" "Windows 无 Unix socket，此探针不适用"
elif [ -S "$SOCK" ]; then
    add "control_socket" "ok" "存在: $SOCK"
else
    add "control_socket" "warn" "不存在: ${SOCK}（服务未起或尚未创建）"
fi

# ── 8. 媒体目录（图片/文件接收链路）─────────────────────────────
for d in feishu_imgs feishu_files; do
    P="$BRIDGE_DIR/workspaces/$BRIDGE_BOT/.tmp/$d"
    if [ -d "$P" ]; then
        N="$(ls -A "$P" 2>/dev/null | wc -l | tr -d ' ')"
        add "media_$d" "ok" "$N 个文件"
    else
        add "media_$d" "warn" "目录不存在: ${P}（从未成功下载过，或已被清理）"
    fi
done

# ── 9. agent 可执行文件 ─────────────────────────────────────────
AGENT_CFG="$("$PLATFORM_PYTHON" -c "
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    a=d.get('agent') or {}
    print(a.get('command','claude'))
except Exception: print('claude')" "$CONFIG_DIR/config.json" 2>/dev/null || echo 'claude')"
if command -v "$AGENT_CFG" >/dev/null 2>&1; then
    add "agent_bin" "ok" "$AGENT_CFG → $(command -v "$AGENT_CFG")"
else
    add "agent_bin" "fail" "$AGENT_CFG 不在 PATH（config.json 的 agent.command）"
fi

# ── 10. 磁盘 ────────────────────────────────────────────────────
DF_LINE="$(df -h "$BRIDGE_HOME" 2>/dev/null | tail -1)"
[ -z "$DF_LINE" ] && DF_LINE="$(df -h / 2>/dev/null | tail -1)"
if [ -n "$DF_LINE" ]; then
    USE="$(printf '%s' "$DF_LINE" | awk '{print $5}')"
    AVAIL="$(printf '%s' "$DF_LINE" | awk '{print $4}')"
    case "$USE" in
        [8-9][0-9]%|100%) add "disk" "warn" "已用 ${USE}，剩 $AVAIL" ;;
        *)                 add "disk" "ok" "已用 ${USE}，剩 $AVAIL" ;;
    esac
fi

# ── 输出 ────────────────────────────────────────────────────────
if [ "$JSON" = "1" ]; then
    # RESULTS 含换行，作为单个 argv 传入；脚本本身走 heredoc（- 从 stdin 读）。
    # 早先版本误从 sys.stdin 读数据，而 stdin 已被 heredoc 占用，结果恒为空数组。
    "$PLATFORM_PYTHON" - "$RESULTS" <<'PY'
import json, sys
items = []
for line in sys.argv[1].splitlines():
    if not line:
        continue
    parts = line.split("|", 2)
    if len(parts) == 3:
        items.append({"name": parts[0], "status": parts[1], "detail": parts[2]})
print(json.dumps({"checks": items}, ensure_ascii=False, indent=2))
PY
else
    echo "========================================="
    echo "  飞书桥接诊断报告"
    echo "  生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "========================================="
    echo ""
    printf '%s' "$RESULTS" | while IFS='|' read -r name status detail; do
        [ -z "$name" ] && continue
        case "$status" in
            ok)   ICON="✅" ;;
            warn) ICON="⚠️ " ;;
            fail) ICON="❌" ;;
            *)    ICON="ℹ️ " ;;
        esac
        printf '%s %-18s %s\n' "$ICON" "$name" "$detail"
    done
    echo ""
    echo "========================================="
    FAILS="$(printf '%s' "$RESULTS" | grep -c '^[^|]*|fail|' || true)"
    WARNS="$(printf '%s' "$RESULTS" | grep -c '^[^|]*|warn|' || true)"
    echo "汇总: ${FAILS} 项失败, ${WARNS} 项警告"
    [ "$FAILS" != "0" ] && echo "排障: references/troubleshooting.md"
    echo "========================================="
fi
