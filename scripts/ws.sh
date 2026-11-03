#!/bin/bash
# ws.sh — 多工作区 / 多环境管理（跨平台）
#
# 借鉴 lark-channel-bridge 的 /ws 与 /cd 设计，但落点不同：
#   它管的是 agent 的工作目录，这里管的是桥接自身的环境身份
#   （数据目录、配置目录、venv、服务标签、bot 名）。
#
# 为什么需要：同一台机器跑多套桥接（dev/prod、多 bot、多飞书应用）时，
#   每套都要一组不同的路径和 label。手写 6 个环境变量容易漏，
#   漏一个的后果是服务看起来起来了，实际读写的是另一套数据。
#
# 存储：~/.config/feishu-bridge/workspaces.json
#   {"profiles": {"<名>": {"FEISHU_BRIDGE_HOME": "...", ...}, ...},
#    "current": "<名>"}
#
# 用法：
#   ws.sh list                  列出所有配置
#   ws.sh current               显示当前生效的是哪套
#   ws.sh add <名> [--from-current]   新增（默认从当前环境快照）
#   ws.sh use <名>              输出切换到该套所需的环境变量（供 eval）
#   ws.sh show <名>             显示某套的完整配置
#   ws.sh rm <名>               删除某套
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/platform.sh"
platform::init

WS_FILE="$CONFIG_DIR/workspaces.json"

die() { platform::err "$*"; exit 1; }

[ -f "$WS_FILE" ] || echo '{"profiles":{},"current":null}' > "$WS_FILE" 2>/dev/null || {
    mkdir -p "$CONFIG_DIR"
    echo '{"profiles":{},"current":null}' > "$WS_FILE"
}

# 所有 JSON 操作走 Python，避免 bash 拼 JSON 的转义地狱
# 注意：
#   1. 这里的 - 由调用方通过 $@ 传入，函数里不再写死，
#      否则会变成 python3 - - <file>（两个连字符，Python 报错）。
#   2. 不吞 stderr。吞掉的话"配置不存在"和"Python 语法错"都变成同一句
#      "Python 操作失败"，排障时等于没有信息。
py() { "$PLATFORM_PYTHON" "$@" || die "Python 执行失败（${PLATFORM_PYTHON}）"; }

CMD="${1:-list}"

case "$CMD" in
    list)
        py - "$WS_FILE" <<'PY'
import json, sys, os
d = json.load(open(sys.argv[1]))
profs = d.get("profiles") or {}
cur = d.get("current")
if not profs:
    print("（还没有保存任何工作区配置）")
    print("用 ws.sh add <名> 从当前环境快照一份")
    sys.exit(0)
print(f"共 {len(profs)} 套配置：")
for name in sorted(profs):
    p = profs[name]
    mark = "← 当前" if name == cur else ""
    home = p.get("FEISHU_BRIDGE_HOME", "~/.local/share/feishu-bridge")
    label = p.get("FEISHU_BRIDGE_LABEL", "com.feishu.bridge")
    bot = p.get("FEISHU_BRIDGE_BOT", "claude-code")
    exists = "✓" if os.path.isdir(os.path.expanduser(home)) else "✗(目录不存在)"
    print(f"  {name:<16} {mark}")
    print(f"      数据目录: {home}  {exists}")
    print(f"      服务标签: {label}")
    print(f"      bot 名:   {bot}")
PY
        ;;
    current)
        py - "$WS_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
cur = d.get("current")
print(cur if cur else "（未设置，用的是默认环境）")
PY
        ;;
    add)
        NAME="${2:-}"
        [ -n "$NAME" ] || die "用法: ws.sh add <名> [--from-current]"
        py - "$WS_FILE" "$NAME" <<'PY'
import json, sys, os
path, name = sys.argv[1], sys.argv[2]
d = json.load(open(path))
profs = d.setdefault("profiles", {})
if name in profs:
    print(f"配置 {name} 已存在，用 ws.sh rm {name} 先删除")
    sys.exit(1)
# 从当前环境快照：只记与默认不同的键，保持配置简洁
keys = ["FEISHU_BRIDGE_HOME", "FEISHU_BRIDGE_CONFIG_HOME", "FEISHU_BRIDGE_VENV",
        "FEISHU_BRIDGE_STATE_HOME", "FEISHU_BRIDGE_LABEL", "FEISHU_BRIDGE_BOT",
        "FEISHU_BRIDGE_PYTHON"]
snap = {k: os.environ[k] for k in keys if os.environ.get(k)}
profs[name] = snap
if not d.get("current"):
    d["current"] = name
json.dump(d, open(path, "w"), indent=2, ensure_ascii=False)
print(f"✅ 已保存 {name}（{len(snap)} 个环境变量）")
if not snap:
    print("   注意：快照为空，说明当前环境全是默认值，这份配置等于默认环境")
PY
        ;;
    use)
        NAME="${2:-}"
        [ -n "$NAME" ] || die "用法: ws.sh use <名>"
        # 输出 export 行，供 eval "$(ws.sh use <名>)" 使用
        py - "$WS_FILE" "$NAME" <<'PY'
import json, sys, shlex
path, name = sys.argv[1], sys.argv[2]
d = json.load(open(path))
p = (d.get("profiles") or {}).get(name)
if p is None:
    print(f"# 错误: 配置 {name} 不存在", file=sys.stderr)
    sys.exit(1)
for k, v in p.items():
    print(f"export {k}={shlex.quote(v)}")
# 同时更新 current，让不带环境变量的后续命令也认这套
d["current"] = name
json.dump(d, open(path, "w"), indent=2, ensure_ascii=False)
PY
        ;;
    show)
        NAME="${2:-}"
        [ -n "$NAME" ] || die "用法: ws.sh show <名>"
        py - "$WS_FILE" "$NAME" <<'PY'
import json, sys
path, name = sys.argv[1], sys.argv[2]
d = json.load(open(path))
p = (d.get("profiles") or {}).get(name)
if p is None:
    print(f"配置 {name} 不存在", file=sys.stderr); sys.exit(1)
print(f"{name} 的环境变量：")
if not p:
    print("  （空，等同默认环境）")
for k, v in sorted(p.items()):
    print(f"  {k}={v}")
PY
        ;;
    rm)
        NAME="${2:-}"
        [ -n "$NAME" ] || die "用法: ws.sh rm <名>"
        py - "$WS_FILE" "$NAME" <<'PY'
import json, sys
path, name = sys.argv[1], sys.argv[2]
d = json.load(open(path))
profs = d.get("profiles") or {}
if name not in profs:
    print(f"配置 {name} 不存在", file=sys.stderr); sys.exit(1)
del profs[name]
if d.get("current") == name:
    d["current"] = None
json.dump(d, open(path, "w"), indent=2, ensure_ascii=False)
print(f"✅ 已删除 {name}")
PY
        ;;
    *)
        die "未知子命令: ${CMD}（可用 list/current/add/use/show/rm）"
        ;;
esac
