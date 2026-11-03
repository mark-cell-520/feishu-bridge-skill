#!/bin/bash
# upgrade.sh — 平滑升级（技能自身 + 桥接包 + 权限补丁重打）
#
# 为什么要单独一个脚本：升级有顺序，且有一个必须记得的坑——
#   pip install --upgrade feishu-bridge 会用包内的
#   data/bridge-settings.json 无条件覆盖 ~/.feishu-bridge/ 那份，
#   而包内默认 deny 了 Bash(curl *)/Bash(wget *)，升级完桥接的 claude
#   就连不上网。手动升级的人九成会漏掉这一步，然后花半小时排查"为什么突然不能联网"。
#
# 所以顺序固定为：拉技能 → 升包 → 重打补丁 → 重启 → 验证。
#
# 用法：
#   bash scripts/upgrade.sh              # 全流程
#   bash scripts/upgrade.sh --skip-git   # 不拉技能（本地有未提交改动时用）
#   bash scripts/upgrade.sh --no-restart # 不重启服务（手动挑时机重启）
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/platform.sh"
platform::init

SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKIP_GIT=0
NO_RESTART=0
for a in "$@"; do
    case "$a" in
        --skip-git)   SKIP_GIT=1 ;;
        --no-restart) NO_RESTART=1 ;;
        *) platform::err "未知参数: $a"; exit 1 ;;
    esac
done

step() { echo; echo "── $* ─────────────────────────────"; }

# ── 0. 前置检查 ─────────────────────────────────────────────────
step "0/5 前置检查"
if [ -z "$PLATFORM_PYTHON" ]; then
    platform::err "未找到 Python，升级中止"
    exit 1
fi
PIP="$(platform::venv_exe pip)"
if [ ! -x "$PIP" ]; then
    platform::err "venv 不存在或缺少 pip: $PIP"
    platform::err "先跑 bash scripts/install.sh"
    exit 1
fi
echo "✅ Python ${PLATFORM_PYTHON}，venv: $VENV_DIR"

# ── 1. 拉取技能自身 ─────────────────────────────────────────────
step "1/5 更新技能自身"
if [ "$SKIP_GIT" = "1" ]; then
    echo "ℹ️ 按参数跳过 git pull"
elif [ -d "$SKILL_DIR/.git" ]; then
    if [ -n "$(cd "$SKILL_DIR" && git status --porcelain 2>/dev/null)" ]; then
        platform::warn "技能仓库有未提交改动，跳过 pull（避免冲突）"
        echo "   先提交或 stash，或用 --skip-git 明确跳过"
    else
        (cd "$SKILL_DIR" && git pull --ff-only 2>&1 | tail -3)
        echo "✅ 技能已更新到: $(cd "$SKILL_DIR" && git log --oneline -1)"
    fi
else
    echo "ℹ️ 不是 git 仓库，跳过"
fi

# ── 2. 升级桥接包 ───────────────────────────────────────────────
step "2/5 升级 feishu-bridge 包"
BEFORE="$("$PLATFORM_PYTHON" -c "
import importlib.metadata as m
try: print(m.version('feishu-bridge'))
except Exception: print('未安装')" 2>/dev/null)"
echo "当前版本: $BEFORE"
"$PIP" install --upgrade feishu-bridge 2>&1 | tail -3
AFTER="$("$PLATFORM_PYTHON" -c "
import importlib.metadata as m
try: print(m.version('feishu-bridge'))
except Exception: print('未安装')" 2>/dev/null)"
echo "升级后版本: $AFTER"
[ "$BEFORE" = "$AFTER" ] && echo "（版本未变，可能已是最新）"

# ── 3. 重打权限补丁（pip 升级已把它还原）───────────────────────
step "3/5 重打权限补丁"
PKG_SETTINGS="$("$PLATFORM_PYTHON" -c "
import sysconfig, os
p = os.path.join(sysconfig.get_paths()['purelib'], 'feishu_bridge', 'data', 'bridge-settings.json')
print(p if os.path.isfile(p) else '')" 2>/dev/null)"
if [ -z "$PKG_SETTINGS" ]; then
    platform::warn "找不到包内 bridge-settings.json，跳过补丁"
else
    echo "目标: $PKG_SETTINGS"
    "$PLATFORM_PYTHON" - "$PKG_SETTINGS" <<'PY'
import json, sys, shutil, os
path = sys.argv[1]
try:
    d = json.load(open(path))
except Exception as e:
    print(f"  ⚠️ 读取失败: {e}"); sys.exit(0)
perms = d.setdefault("permissions", {})
before_mode = perms.get("defaultMode")
before_deny = perms.get("deny") or []
# 与 mac-stack-doctor 技能记录的口径一致：
#   defaultMode 设 bypassPermissions；删掉 curl/wget 的 deny；
#   保留关机/删盘类高危命令的 deny。
perms["defaultMode"] = "bypassPermissions"
blocked = ("curl", "wget")
new_deny = [x for x in before_deny
            if not any(b in str(x) for b in blocked)]
removed = len(before_deny) - len(new_deny)
perms["deny"] = new_deny
if before_mode != "bypassPermissions" or removed:
    bak = path + ".pre-upgrade-bak"
    if not os.path.exists(bak):
        shutil.copy2(path, bak)
    json.dump(d, open(path, "w"), indent=2, ensure_ascii=False)
    print(f"  ✅ defaultMode: {before_mode} → bypassPermissions")
    print(f"  ✅ deny 移除 {removed} 条（curl/wget）")
    print(f"  备份: {bak}")
else:
    print("  ✅ 补丁已就位，无需改动")
PY
fi

# ── 4. ui.py 补丁检测（pip 升级会覆盖它）──────────────────────
step "3.5/5 检测 ui.py 补丁"
# 逐个检测已知补丁：有备份但 marker 不在 = 被本次升级覆盖了
check_patch() {
    local script="$1" name="$2" bakpat="$3"
    [ -f "$SCRIPT_DIR/$script" ] || { echo "ℹ️ $name: 无补丁脚本，跳过"; return; }
    local state
    state="$(bash "$SCRIPT_DIR/$script" status 2>/dev/null | grep '补丁状态:' | awk '{print $2}')"
    if [ "$state" = "已打" ]; then
        echo "✅ $name 补丁仍在"
    elif ls "$STATE_HOME/patches/$bakpat"* >/dev/null 2>&1; then
        echo "⚠️ $name 补丁被本次升级覆盖了，需重打: bash scripts/$script apply"
    else
        echo "ℹ️ $name 未打过补丁（可选，详见 bash scripts/$script status）"
    fi
}
check_patch "patch-ui.sh"        "ui.py（禁用失效的 agent_status 元素）" "ui.py.pre-patch-"
check_patch "patch-post-image.sh" "main.py（图文混排时提取图片）"        "main.py.pre-post-image-"
check_patch "patch-tool-list.sh"  "ui.py（工具列表编号逐行）"            "ui.py.pre-tool-list-"

# ── 4. 重启服务 ─────────────────────────────────────────────────
step "4/5 重启服务"
if [ "$NO_RESTART" = "1" ]; then
    echo "ℹ️ 按参数跳过重启，稍后手动执行:"
    echo "   bash scripts/stop-bridge.sh && bash scripts/start-bridge.sh"
elif [ -z "$(platform::service_status)" ]; then
    echo "ℹ️ 服务当前未运行，不重启"
    echo "   启动: bash scripts/start-bridge.sh"
else
    bash "$SCRIPT_DIR/stop-bridge.sh" || true
    bash "$SCRIPT_DIR/start-bridge.sh" || {
        platform::err "重启失败，查看日志:"
        platform::err "   tail -30 $LOG_DIR/bridge.err.log"
        exit 1
    }
fi

# ── 5. 验证 ─────────────────────────────────────────────────────
step "5/5 升级后验证"
bash "$SCRIPT_DIR/health-check.sh" 2>&1 | head -20
echo
echo "========================================="
echo "  升级完成"
echo "  包版本: $BEFORE → $AFTER"
echo "  平台: $PLATFORM_OS / $PLATFORM_INIT"
echo "========================================="
