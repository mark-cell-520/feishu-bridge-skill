#!/bin/bash
# setup-format-rule.sh — 注入「过程分步编号」输出规则（一键配置）
#
# 解决什么：用户要求"过程文字一行行排列、1.2.3.4 编号显示"。
#   这属于回复正文的排版，不是桥接的渲染逻辑——所以不该改 ui.py，
#   而该在 agent 启动时把规则注入进去。
#
# 为什么走 config.json 的 agent.args 而不是只写 CLAUDE.md：
#   CLAUDE.md 依赖"文件被读取"这个前提。工作区 CLAUDE.md 确实每次都会被读，
#   但一旦用户在别的工作区用、或者规则被后来的内容挤掉，就失效了。
#   agent.args 是 CLI 参数，桥接每次拉起 claude 都会原样带上，
#   不受工作区、不受包升级影响（升级覆盖的是 pip 包，不是这个配置文件）。
#   两条通道并存：CLAUDE.md 写详细细则与正反示例，这里放硬性要求做兜底。
#
# 用法：
#   bash scripts/setup-format-rule.sh status
#   bash scripts/setup-format-rule.sh apply      # 注入（自动备份）
#   bash scripts/setup-format-rule.sh revert     # 移除注入
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/platform.sh"
platform::init

CONFIG="${FEISHU_BRIDGE_CONFIG_HOME:-$HOME/.config/feishu-bridge}/config.json"

RULE="【输出格式硬性要求】所有过程性文字必须一步一行，用 1. 2. 3. 连续编号顶格排列。覆盖三处，缺一不可：一、执行每个工具前的说明；二、工具返回后的解读；三、最终总结。整个交互是一条连续的编号流，编号跨工具调用持续递增，不因插入工具而清零。不得把多个动作揉进一段话，不得使用不带编号的过渡句——例如「现在做 X」「最后确认 Y」这类句式必须改成编号步骤。结论、待办、风险单独成段，不占用步骤编号。步骤超过 8 条时按主题分组，组内重新从 1 编号。"

[ -n "$PLATFORM_PYTHON" ] || { platform::err "未找到 Python"; exit 1; }
[ -f "$CONFIG" ] || { platform::err "配置不存在: $CONFIG"; exit 1; }

state() {
    "$PLATFORM_PYTHON" -c "
import json,sys
d=json.load(open(sys.argv[1]))
a=(d.get('agent') or {}).get('args') or []
print('已注入' if '--append-system-prompt' in a else '未注入')" "$CONFIG" 2>/dev/null || echo "读取失败"
}

case "${1:-status}" in
    status)
        echo "配置文件: $CONFIG"
        echo "规则状态: $(state)"
        if [ "$(state)" = "已注入" ]; then
            echo
            echo "当前注入的内容："
            "$PLATFORM_PYTHON" -c "
import json,sys
a=json.load(open(sys.argv[1]))['agent']['args']
i=a.index('--append-system-prompt')
print('  ' + a[i+1])" "$CONFIG" 2>/dev/null
            echo
            echo "注意：修改后需重启桥接生效（bash scripts/restart-bridge.sh）"
        fi
        ;;
    apply)
        if [ "$(state)" = "已注入" ]; then
            echo "ℹ️ 规则已注入，无需重复。可用 revert 后重新 apply 以更新内容。"
            exit 0
        fi
        BAK="$CONFIG.bak-$(date +%Y%m%d-%H%M%S)"
        cp -p "$CONFIG" "$BAK" || { platform::err "备份失败，中止"; exit 1; }
        echo "✅ 已备份: $BAK"
        "$PLATFORM_PYTHON" - "$CONFIG" "$RULE" <<'PY'
import json, sys
path, rule = sys.argv[1], sys.argv[2]
d = json.load(open(path, encoding="utf-8"))
agent = d.setdefault("agent", {})
args = agent.get("args") or []
if "--append-system-prompt" not in args:
    args.extend(["--append-system-prompt", rule])
    agent["args"] = args
    json.dump(d, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    print("✅ 规则已注入 agent.args")
else:
    print("ℹ️ 已存在，未改动")
PY
        [ $? -eq 0 ] || { platform::err "写入失败"; exit 1; }
        echo
        echo "需要重启桥接生效："
        echo "   bash scripts/restart-bridge.sh"
        ;;
    revert)
        if [ "$(state)" != "已注入" ]; then
            echo "ℹ️ 未注入，无需回退"
            exit 0
        fi
        BAK="$CONFIG.pre-format-rule-$(date +%Y%m%d-%H%M%S)"
        cp -p "$CONFIG" "$BAK"
        echo "✅ 已备份: $BAK"
        "$PLATFORM_PYTHON" - "$CONFIG" <<'PY'
import json, sys
path = sys.argv[1]
d = json.load(open(path, encoding="utf-8"))
args = (d.get("agent") or {}).get("args") or []
if "--append-system-prompt" in args:
    i = args.index("--append-system-prompt")
    del args[i:i+2]          # 连参数带值一起删
    d["agent"]["args"] = args
    json.dump(d, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    print("✅ 已移除注入")
else:
    print("ℹ️ 未找到注入项")
PY
        echo
        echo "需要重启桥接生效："
        echo "   bash scripts/restart-bridge.sh"
        ;;
    *)
        platform::err "未知子命令: $1（可用 status/apply/revert）"; exit 1
        ;;
esac
