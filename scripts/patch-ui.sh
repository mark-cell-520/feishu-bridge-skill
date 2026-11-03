#!/bin/bash
# patch-ui.sh — 可选补丁：禁用持续失败的 agent_status 元素更新
#
# 这个补丁解决什么（数据来自 perf.sh 实测，非猜测）：
#   agent_status 元素每次更新都被飞书 API 以 code=99992402
#   （field validation failed）拒绝。本机日志里它失败了 4103 次，
#   加上 streaming_output 的 981 次，合计占全部日志行的 72%。
#   副作用有两个：日志被重复噪音淹没，tail 看不到有用记录；
#   每轮对话发起十几二十次注定失败的 API 请求，白耗往返。
#
# 为什么是"可选"而不是默认打：
#   它改的是 pip 安装的第三方包 feishu_bridge/ui.py，不是本技能自己的代码。
#   pip install --upgrade feishu-bridge 会覆盖它，补丁需要重打。
#   所以默认不动，由你明确决定。
#
# 为什么打这个补丁不损失功能：
#   agent_status 的更新一直在失败，卡片上那个位置从来就是空的。
#   禁用的是"注定失败的请求"，不是"能用的功能"。
#   streaming_output（真正承载回复内容的元素）不受影响，
#   补丁只早退 _render_agent_progress 这一个函数。
#
# 用法：
#   bash scripts/patch-ui.sh status     # 补丁是否已打
#   bash scripts/patch-ui.sh apply      # 打补丁（自动备份）
#   bash scripts/patch-ui.sh revert     # 从备份恢复
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/platform.sh"
platform::init

MARKER="feishu-bridge-skill patch: agent_status disabled"
BACKUP_DIR="$STATE_HOME/patches"

locate_ui() {
    local py
    # 必须用 venv 的解释器：feishu_bridge 装在 venv 里，
    # 而 platform 探测到的 PLATFORM_PYTHON 往往是系统 python3，
    # 它的 sysconfig purelib 指向另一个 site-packages，必然找不到。
    py="$(platform::venv_exe python3)"
    [ -x "$py" ] || py="${PLATFORM_PYTHON:-}"
    [ -n "$py" ] || { platform::err "未找到可用的 Python 解释器"; return 1; }
    "$py" -c "
import sysconfig, os
p = os.path.join(sysconfig.get_paths()['purelib'], 'feishu_bridge', 'ui.py')
print(p if os.path.isfile(p) else '')" 2>/dev/null
}

UI="$(locate_ui)"
[ -n "$UI" ] || { platform::err "找不到 feishu_bridge/ui.py"; exit 1; }

status_patch() {
    if grep -qF "$MARKER" "$UI" 2>/dev/null; then
        echo "已打"
    else
        echo "未打"
    fi
}

case "${1:-status}" in
    status)
        echo "目标文件: $UI"
        echo "补丁状态: $(status_patch)"
        if [ "$(status_patch)" = "已打" ]; then
            echo
            echo "该文件已被修改，pip 升级 feishu-bridge 会覆盖它。"
            echo "升级后需重新 apply；upgrade.sh 会提醒这一点。"
            ls -lt "$BACKUP_DIR" 2>/dev/null | grep "ui.py" | head -1 | \
                awk '{print "备份: "$NF"  ("$6" "$7" "$8")"}'
        fi
        ;;
    apply)
        if [ "$(status_patch)" = "已打" ]; then
            echo "ℹ️ 补丁已存在，无需重复打"
            exit 0
        fi
        mkdir -p "$BACKUP_DIR"
        BAK="$BACKUP_DIR/ui.py.pre-patch-$(date +%Y%m%d-%H%M%S)"
        cp -p "$UI" "$BAK" || { platform::err "备份失败，中止"; exit 1; }
        echo "✅ 已备份: $BAK"

        # 用 Python 做精确插入，避免 sed 对多行 Python 的脆弱匹配
        "$PLATFORM_PYTHON" - "$UI" "$MARKER" <<'PY'
import os, sys, re
path, marker = sys.argv[1], sys.argv[2]
src = open(path, encoding="utf-8").read()
# 定位 _render_agent_progress 的 docstring 结束处，在函数体第一行前插入早退
pat = re.compile(
    r'(    def _render_agent_progress\(self\):\n'
    r'        """Render agent \+ todo status to the CardKit agent element\."""\n)')
m = pat.search(src)
if not m:
    print("❌ 未找到 _render_agent_progress，补丁点可能已变，中止", file=sys.stderr)
    sys.exit(1)
if marker in src:
    print("ℹ️ 补丁已存在")
    sys.exit(0)
patch = (
    m.group(1)
    + "        # " + marker + "\n"
    + "        # 该元素的 markdown 字段被飞书 API 以 code=99992402 拒绝，\n"
    + "        # 更新必然失败（实测失败四千余次，占日志 72%）。禁用它，\n"
    + "        # 不影响 streaming_output——真正承载回复的元素不走这个函数。\n"
    + "        # 删除本行及上方三行注释即可恢复，或运行 patch-ui.sh revert。\n"
    + "        return\n"
)
tmp = path + ".tmp-patch"
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write(src[:m.start()] + patch + src[m.end():])
os.replace(tmp, path)  # 原子替换，避免半成品文件
print("✅ 补丁已写入")
PY
        [ $? -eq 0 ] || { platform::err "补丁写入失败，从备份恢复"; cp -p "$BAK" "$UI"; exit 1; }

        echo
        echo "补丁内容：_render_agent_progress 开头早退，跳过注定失败的请求。"
        echo
        echo "需要重启桥接才能生效："
        echo "   bash scripts/stop-bridge.sh && bash scripts/start-bridge.sh"
        echo
        echo "生效后验证（agent_status 失败数应停止增长）："
        echo "   bash scripts/perf.sh"
        ;;
    revert)
        LATEST="$(ls -t "$BACKUP_DIR"/ui.py.pre-patch-* 2>/dev/null | head -1)"
        [ -n "$LATEST" ] || { platform::err "没有找到备份: $BACKUP_DIR"; exit 1; }
        echo "从备份恢复: $LATEST"
        cp -p "$LATEST" "$UI" || { platform::err "恢复失败"; exit 1; }
        echo "✅ 已恢复（补丁状态: $(status_patch)）"
        echo
        echo "需要重启桥接才能生效："
        echo "   bash scripts/stop-bridge.sh && bash scripts/start-bridge.sh"
        ;;
    *)
        platform::err "未知子命令: $1（可用 status/apply/revert）"
        exit 1
        ;;
esac
