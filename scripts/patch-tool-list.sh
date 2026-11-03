#!/bin/bash
# patch-tool-list.sh — 工具调用列表改为编号逐行显示
#
# 用户要求（2026-11-03，附图确认）：
#   "修改信息显示方式，让过程显示，做一行行排列，1.2.3.4，这样子排列显示。"
#
# 原实现的问题：
#   _build_tool_panels_for_streaming 把每次工具调用渲染成一个
#   collapsible_panel（可折叠面板），每个面板带图标、边框、8px 内边距，
#   一条就要占三四行。步骤一多就看不到全貌——附图里 8 个步骤
#   把整屏撑满，而每条真正有用的信息只有"干了什么"那一小段。
#
# 改法：返回单个 markdown 元素，一步一行，连续编号。
#   1. ⏳ 执行命令 · 查看 _update_element 实现确定补丁点
#   2. ✅ 执行命令 · 查看 agent_status 更新调用链与文件指纹
#   3. ✅ 写入文件 · patch-ui.sh
#   保留状态图标与 hint，折叠提示也保留。
#
# 兼容性：函数名、签名、返回类型（list[dict]）都不变，调用方
#   _send_tool_card 与 _render_tool_progress 无需改动。
#
# 用法：
#   bash scripts/patch-tool-list.sh status
#   bash scripts/patch-tool-list.sh apply
#   bash scripts/patch-tool-list.sh revert
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/platform.sh"
platform::init

MARKER="feishu-bridge-skill patch: numbered tool list"
BACKUP_DIR="$STATE_HOME/patches"

locate_ui() {
    local py
    py="$(platform::venv_exe python3)"
    [ -x "$py" ] || py="${PLATFORM_PYTHON:-}"
    [ -n "$py" ] || { platform::err "未找到 Python 解释器"; return 1; }
    "$py" -c "
import sysconfig, os
p = os.path.join(sysconfig.get_paths()['purelib'], 'feishu_bridge', 'ui.py')
print(p if os.path.isfile(p) else '')" 2>/dev/null
}

UI="$(locate_ui)"
[ -n "$UI" ] || { platform::err "找不到 feishu_bridge/ui.py"; exit 1; }

status_patch() {
    if grep -qF "$MARKER" "$UI" 2>/dev/null; then echo "已打"; else echo "未打"; fi
}

case "${1:-status}" in
    status)
        echo "目标文件: $UI"
        echo "补丁状态: $(status_patch)"
        [ "$(status_patch)" = "已打" ] && echo "（pip 升级会覆盖，需重打；upgrade.sh 会提醒）"
        ;;
    apply)
        [ "$(status_patch)" = "已打" ] && { echo "ℹ️ 补丁已存在"; exit 0; }
        mkdir -p "$BACKUP_DIR"
        BAK="$BACKUP_DIR/ui.py.pre-tool-list-$(date +%Y%m%d-%H%M%S)"
        cp -p "$UI" "$BAK" || { platform::err "备份失败，中止"; exit 1; }
        echo "✅ 已备份: $BAK"

        "$PLATFORM_PYTHON" - "$UI" "$MARKER" <<'PY'
import sys, re
path, marker = sys.argv[1], sys.argv[2]
src = open(path, encoding="utf-8").read()
if marker in src:
    print("ℹ️ 补丁已存在"); sys.exit(0)

# 替换整个 _build_tool_panels_for_streaming 函数体（到下一个 def 为止）
pat = re.compile(
    r'    def _build_tool_panels_for_streaming\(self\) -> list\[dict\]:\n'
    r'.*?'
    r'(?=\n    def )',
    re.S)
m = pat.search(src)
if not m:
    print("❌ 未找到 _build_tool_panels_for_streaming，补丁点可能已变，中止",
          file=sys.stderr)
    sys.exit(1)

new_body = '''    def _build_tool_panels_for_streaming(self) -> list[dict]:
        """Build a numbered markdown list of tool_history for streaming.

        %s

        原实现把每次工具调用渲染成一个 collapsible_panel，带图标、边框、
        8px 内边距，一条占三四行；步骤一多就看不到全貌。改为单个
        markdown 元素、一步一行、连续编号。函数名与返回类型不变，
        调用方 _send_tool_card 与 _render_tool_progress 无需改动。
        """
        if not self._tool_history:
            return []

        entries = list(self._tool_history)
        total = len(entries)
        max_display = self._MAX_TOOL_PANELS
        visible = entries[-max_display:] if total > max_display else entries

        lines = []
        if total > max_display:
            lines.append(f"... 前 {total - max_display} 次操作已折叠")
            lines.append("")

        for i, entry in enumerate(visible, 1):
            label = entry["label"]
            hint = entry.get("hint", "")
            count = entry.get("count", 1)
            status = entry.get("status", "running")

            icon = "⏳" if status == "running" else "✅"
            detail = f" · {hint}" if hint else ""
            line = f"{i}. {icon} {label}{detail}"
            if count > 1:
                line += f" ×{count}"
            lines.append(line)

        return [{"tag": "markdown", "content": "\\n".join(lines)}]

''' % marker

open(path, "w", encoding="utf-8").write(src[:m.start()] + new_body + src[m.end():])
print("✅ 补丁已写入")
PY
        [ $? -eq 0 ] || { platform::err "写入失败，从备份恢复"; cp -p "$BAK" "$UI"; exit 1; }

        if "$(platform::venv_exe python3)" -m py_compile "$UI" 2>/dev/null; then
            echo "✅ ui.py 编译通过"
        else
            platform::err "ui.py 编译失败，已从备份恢复"
            cp -p "$BAK" "$UI"
            exit 1
        fi

        echo
        echo "需要重启桥接才能生效："
        echo "   bash scripts/restart-bridge.sh"
        ;;
    revert)
        LATEST="$(ls -t "$BACKUP_DIR"/ui.py.pre-tool-list-* 2>/dev/null | head -1)"
        [ -n "$LATEST" ] || { platform::err "没有找到备份"; exit 1; }
        echo "从备份恢复: $LATEST"
        cp -p "$LATEST" "$UI" || { platform::err "恢复失败"; exit 1; }
        echo "✅ 已恢复（补丁状态: $(status_patch)）"
        echo "需要重启桥接才能生效："
        echo "   bash scripts/restart-bridge.sh"
        ;;
    *)
        platform::err "未知子命令: $1（可用 status/apply/revert）"; exit 1
        ;;
esac
