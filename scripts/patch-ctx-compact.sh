#!/bin/bash
# patch-ctx-compact.sh — 补上"连续对话时 ctx 无限增长"这个盲区
#
# 现象（日志实测，非猜测）：
#   2026-11-03 12:51:45 Idle auto-compact firing: sid=199ccc6d ctx=459542 tokens
#   该轮之前单次交互实测 5 分 2 秒、39.3 万 token。
#
# 根因（代码级证据）：
#   worker.py 的 IdleCompactManager 每轮成功后调 touch()，起一个
#   _IDLE_COMPACT_DELAY = 50 分钟的定时器；下一轮 touch() 会 cancel
#   旧定时器再起新的（生成号递增，旧的 _fire 直接跳过）。
#   → 只要两轮间隔小于 50 分钟，定时器永远被取消，compact 永远不触发。
#   而这个 50 分钟的设计意图是省钱：Anthropic prompt cache TTL 1 小时，
#   在 cache 还热时 compact，compact 调用按 cache_read 计价，compact 后
#   历史缩短，之后冷启动重缓存的成本也小。
#   它优化的是"空闲后的那一次便宜"，完全没有覆盖"密集连续对话"这条路径。
#   密集对话恰恰是本技能的主要使用形态，于是 ctx 一路涨到几十万 token，
#   每轮 --resume 全量重放，单轮耗时按分钟计。
#
# 修法：不动原有 50 分钟路径（省钱设计保留），只在 ctx 超过硬上限时
#   把同一套 _fire 逻辑的延迟改成 15 秒——排在本轮回复之后，不打断
#   当前这一轮。超限判定读 FEISHU_BRIDGE_CTX_LIMIT，默认 150000。
#
# 为什么不用"到上限就开新会话"：那会丢上下文。用户要的是连续性，
#   compact 保留摘要，开新会话不保留。
#
# 用法：
#   bash scripts/patch-ctx-compact.sh status
#   bash scripts/patch-ctx-compact.sh apply     # 自动备份、可 revert
#   bash scripts/patch-ctx-compact.sh revert
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/platform.sh"
platform::init

MARKER="feishu-bridge-skill patch: ctx hard limit forces compact"
BACKUP_DIR="$STATE_HOME/patches"

locate_worker() {
    local py
    py="$(platform::venv_exe python3)"
    [ -x "$py" ] || py="${PLATFORM_PYTHON:-}"
    [ -n "$py" ] || { platform::err "未找到 Python 解释器"; return 1; }
    "$py" -c "
import sysconfig, os
p = os.path.join(sysconfig.get_paths()['purelib'], 'feishu_bridge', 'worker.py')
print(p if os.path.isfile(p) else '')" 2>/dev/null
}

WORKER="$(locate_worker)"
[ -n "$WORKER" ] || { platform::err "找不到 feishu_bridge/worker.py"; exit 1; }

status_patch() {
    if grep -qF "$MARKER" "$WORKER" 2>/dev/null; then echo "已打"; else echo "未打"; fi
}

case "${1:-status}" in
    status)
        echo "目标文件: $WORKER"
        echo "补丁状态: $(status_patch)"
        if [ "$(status_patch)" = "已打" ]; then
            echo
            echo "当前阈值（读环境变量，改后需重启桥接才生效）："
            echo "   FEISHU_BRIDGE_CTX_LIMIT = ${FEISHU_BRIDGE_CTX_LIMIT:-150000（默认）}"
        fi
        echo
        echo "（pip 升级会覆盖，需重打；upgrade.sh 会提醒）"
        ;;
    apply)
        [ "$(status_patch)" = "已打" ] && { echo "ℹ️ 补丁已存在"; exit 0; }
        mkdir -p "$BACKUP_DIR"
        BAK="$BACKUP_DIR/worker.py.pre-ctx-compact-$(date +%Y%m%d-%H%M%S)"
        cp -p "$WORKER" "$BAK" || { platform::err "备份失败，中止"; exit 1; }
        echo "✅ 已备份: $BAK"

        "$PLATFORM_PYTHON" - "$WORKER" "$MARKER" <<'PY'
import os, sys
path, marker = sys.argv[1], sys.argv[2]
src = open(path, encoding="utf-8").read()
if marker in src:
    print("ℹ️ 补丁已存在"); sys.exit(0)

# ── 补丁点 1：在既有常量后追加两个新常量 ──────────────────────
anchor1 = (
    "_IDLE_COMPACT_MIN_CTX = 50_000     # Don't compact small sessions\n"
)
if anchor1 not in src:
    print("❌ 未匹配到 _IDLE_COMPACT_MIN_CTX 常量，补丁点可能已变，中止",
          file=sys.stderr)
    sys.exit(1)
add1 = anchor1 + (
    "\n"
    "# " + marker + "\n"
    "# ctx 硬上限与超限后的压缩延迟。原有 50 分钟路径不变（省钱设计保留），\n"
    "# 只在 ctx 超过硬上限时把延迟改短，覆盖密集连续对话这条路径。\n"
    "# 两个值都读环境变量，但解析失败或越界时退回默认值：一个拼错的\n"
    "# 环境变量不该在导入期就把桥接弄崩，那种故障现场没有任何日志。\n"
    "try:\n"
    "    _CTX_HARD_LIMIT = int(os.environ.get(\"FEISHU_BRIDGE_CTX_LIMIT\", \"150000\"))\n"
    "    if _CTX_HARD_LIMIT < _IDLE_COMPACT_MIN_CTX:\n"
    "        _CTX_HARD_LIMIT = 150000\n"
    "except (TypeError, ValueError):\n"
    "    _CTX_HARD_LIMIT = 150000\n"
    "try:\n"
    "    _CTX_COMPACT_DELAY = int(os.environ.get(\"FEISHU_BRIDGE_CTX_DELAY\", \"15\"))\n"
    "    if not 1 <= _CTX_COMPACT_DELAY <= 600:\n"
    "        _CTX_COMPACT_DELAY = 15\n"
    "except (TypeError, ValueError):\n"
    "    _CTX_COMPACT_DELAY = 15\n"
)

# ── 补丁点 2：touch() 里按 ctx 选延迟 ─────────────────────────
anchor2 = (
    "            if total_ctx < _IDLE_COMPACT_MIN_CTX:\n"
    "                return\n"
    "\n"
    "            timer = threading.Timer(\n"
    "                _IDLE_COMPACT_DELAY,\n"
)
if anchor2 not in src:
    print("❌ 未匹配到 touch() 的定时器构造，补丁点可能已变，中止",
          file=sys.stderr)
    sys.exit(1)
add2 = (
    "            if total_ctx < _IDLE_COMPACT_MIN_CTX:\n"
    "                return\n"
    "\n"
    "            # " + marker + "\n"
    "            # 密集连续对话时 touch() 每轮都被调用，50 分钟定时器反复\n"
    "            # 取消重置，idle-compact 永不触发，ctx 一路涨到几十万 token，\n"
    "            # 每轮 --resume 全量重放，单轮耗时按分钟计。超限就把同一套\n"
    "            # _fire 逻辑的延迟改成 _CTX_COMPACT_DELAY 秒：排在本轮回复\n"
    "            # 之后，不打断当前这一轮；不到上限仍走原路径。\n"
    "            delay = _IDLE_COMPACT_DELAY\n"
    "            if total_ctx >= _CTX_HARD_LIMIT:\n"
    "                delay = _CTX_COMPACT_DELAY\n"
    "                log.info(\n"
    "                    \"Ctx over hard limit, compacting soon: \"\n"
    "                    \"sid=%s ctx=%d limit=%d\",\n"
    "                    session_id[:8], total_ctx, _CTX_HARD_LIMIT)\n"
    "\n"
    "            timer = threading.Timer(\n"
    "                delay,\n"
)

out = src.replace(anchor1, add1, 1).replace(anchor2, add2, 1)
tmp = path + ".tmp-patch"
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write(out)
os.replace(tmp, path)  # 原子替换，避免半成品文件
print("✅ 补丁已写入")
PY
        [ $? -eq 0 ] || { platform::err "写入失败，从备份恢复"; cp -p "$BAK" "$WORKER"; exit 1; }

        if "$(platform::venv_exe python3)" -m py_compile "$WORKER" 2>/dev/null; then
            echo "✅ worker.py 编译通过"
        else
            platform::err "worker.py 编译失败，已从备份恢复"
            cp -p "$BAK" "$WORKER"
            exit 1
        fi

        # 确认两处都真的写进去了，不靠"编译通过"就当成功
        if [ "$(grep -cF "$MARKER" "$WORKER")" -ge 2 ]; then
            echo "✅ 两处补丁点均已写入（marker 出现 $(grep -cF "$MARKER" "$WORKER") 次）"
        else
            platform::err "补丁点数量不对，已从备份恢复"
            cp -p "$BAK" "$WORKER"
            exit 1
        fi

        echo
        echo "阈值默认 150000 tokens，可用环境变量调整："
        echo "   FEISHU_BRIDGE_CTX_LIMIT=120000"
        echo
        echo "需要重启桥接才能生效（重启会中断当前会话，由你决定时机）："
        echo "   bash scripts/restart-bridge.sh"
        ;;
    revert)
        LATEST="$(ls -t "$BACKUP_DIR"/worker.py.pre-ctx-compact-* 2>/dev/null | head -1)"
        [ -n "$LATEST" ] || { platform::err "没有找到备份: $BACKUP_DIR"; exit 1; }
        echo "从备份恢复: $LATEST"
        cp -p "$LATEST" "$WORKER" || { platform::err "恢复失败"; exit 1; }
        if "$(platform::venv_exe python3)" -m py_compile "$WORKER" 2>/dev/null; then
            echo "✅ 已恢复（补丁状态: $(status_patch)），编译通过"
        else
            platform::err "恢复后编译失败，需人工检查"
            exit 1
        fi
        echo "需要重启桥接才能生效："
        echo "   bash scripts/restart-bridge.sh"
        ;;
    *)
        platform::err "未知子命令: $1（可用 status/apply/revert）"; exit 1
        ;;
esac
