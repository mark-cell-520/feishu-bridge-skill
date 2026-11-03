#!/bin/bash
# patch-post-image.sh — 修复：图文混排时图片收不到
#
# 根因（代码级证据，非猜测）：
#   飞书里单独发一张图，msg_type 是 "image"，走 main.py 的 image 分支，
#   image_key 被取出并下载——这条路径是通的。
#   但图文一起发，msg_type 变成 "post"（富文本）。post 分支只调用
#   parse_post_content(content) 取文字，而该函数对 tag == "img" 的段
#   做的是 line_parts.append("[图片]")——把 image_key 换成字面量后丢弃。
#   于是图片永远不会被下载，claude 只看到 "[图片]" 两个字符。
#   这就是"单独发图可以，图文一起就不行"的确切原因。
#
# 修法：post 分支在取到文字后，从 content 里把 img 段的 image_key 提出来，
#   交给已有的 download_image 走同一套下载逻辑。不改 parsers.py，
#   避免影响其他调用方；最小侵入。
#
# 多语言：飞书 post 的 content 可能是 {"zh_cn": {...}} / {"en_us": {...}}
#   或直接平铺，三种都要覆盖。
#
# 用法：
#   bash scripts/patch-post-image.sh status
#   bash scripts/patch-post-image.sh apply     # 自动备份
#   bash scripts/patch-post-image.sh revert
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/platform.sh"
platform::init

MARKER="feishu-bridge-skill patch: extract image_key from post"
BACKUP_DIR="$STATE_HOME/patches"

locate_main() {
    local py
    py="$(platform::venv_exe python3)"
    [ -x "$py" ] || py="${PLATFORM_PYTHON:-}"
    [ -n "$py" ] || { platform::err "未找到 Python 解释器"; return 1; }
    "$py" -c "
import sysconfig, os
p = os.path.join(sysconfig.get_paths()['purelib'], 'feishu_bridge', 'main.py')
print(p if os.path.isfile(p) else '')" 2>/dev/null
}

MAIN="$(locate_main)"
[ -n "$MAIN" ] || { platform::err "找不到 feishu_bridge/main.py"; exit 1; }

status_patch() {
    if grep -qF "$MARKER" "$MAIN" 2>/dev/null; then echo "已打"; else echo "未打"; fi
}

case "${1:-status}" in
    status)
        echo "目标文件: $MAIN"
        echo "补丁状态: $(status_patch)"
        [ "$(status_patch)" = "已打" ] && echo "（pip 升级会覆盖，需重打；upgrade.sh 会提醒）"
        ;;
    apply)
        [ "$(status_patch)" = "已打" ] && { echo "ℹ️ 补丁已存在"; exit 0; }
        mkdir -p "$BACKUP_DIR"
        BAK="$BACKUP_DIR/main.py.pre-post-image-$(date +%Y%m%d-%H%M%S)"
        cp -p "$MAIN" "$BAK" || { platform::err "备份失败，中止"; exit 1; }
        echo "✅ 已备份: $BAK"

        "$PLATFORM_PYTHON" - "$MAIN" "$MARKER" <<'PY'
import sys, re
path, marker = sys.argv[1], sys.argv[2]
src = open(path, encoding="utf-8").read()
if marker in src:
    print("ℹ️ 补丁已存在"); sys.exit(0)

# 精确匹配 post 分支。原代码：
#             elif msg_type == "post":
#                 # Rich-text message — use shared parser + strip mentions
#                 text = _strip_mentions(
#                     parse_post_content(content), _msg_mentions)
#                 if not text:
#                     return
old = (
    '            elif msg_type == "post":\n'
    '                # Rich-text message — use shared parser + strip mentions\n'
    '                text = _strip_mentions(\n'
    '                    parse_post_content(content), _msg_mentions)\n'
    '                if not text:\n'
    '                    return\n'
)
if old not in src:
    print("❌ 未匹配到 post 分支原代码，补丁点可能已变，中止", file=sys.stderr)
    sys.exit(1)

new = (
    '            elif msg_type == "post":\n'
    '                # Rich-text message — use shared parser + strip mentions\n'
    '                text = _strip_mentions(\n'
    '                    parse_post_content(content), _msg_mentions)\n'
    '                # ' + marker + '\n'
    '                # 图文混排时 msg_type 是 post，parse_post_content 会把 img 段\n'
    '                # 替换成字面量 "[图片]" 并丢弃 image_key，导致图片从不下载。\n'
    '                # 这里把 image_key 取回来，交给下方已有的 download_image。\n'
    '                # 只取第一张：一轮对话里塞多图时，先保证至少一张能到，\n'
    '                # 多图全取会让 prompt 里出现多个路径、超出卡片长度上限。\n'
    '                if not image_key:\n'
    '                    _pc = content\n'
    '                    if "content" not in _pc and "title" not in _pc:\n'
    '                        _pc = (_pc.get("zh_cn") or _pc.get("en_us")\n'
    '                               or _pc.get("ja_jp") or {})\n'
    '                    for _para in (_pc.get("content") or []):\n'
    '                        for _seg in _para:\n'
    '                            if _seg.get("tag") == "img" and _seg.get("image_key"):\n'
    '                                image_key = _seg["image_key"]\n'
    '                                break\n'
    '                        if image_key:\n'
    '                            break\n'
    '                if not text and not image_key:\n'
    '                    return\n'
)
open(path, "w", encoding="utf-8").write(src.replace(old, new, 1))
print("✅ 补丁已写入")
PY
        [ $? -eq 0 ] || { platform::err "写入失败，从备份恢复"; cp -p "$BAK" "$MAIN"; exit 1; }

        # 语法验证：改坏了就不能留
        if "$(platform::venv_exe python3)" -m py_compile "$MAIN" 2>/dev/null; then
            echo "✅ main.py 编译通过"
        else
            platform::err "main.py 编译失败，已从备份恢复"
            cp -p "$BAK" "$MAIN"
            exit 1
        fi

        echo
        echo "需要重启桥接才能生效："
        echo "   bash scripts/stop-bridge.sh && bash scripts/start-bridge.sh"
        ;;
    revert)
        LATEST="$(ls -t "$BACKUP_DIR"/main.py.pre-post-image-* 2>/dev/null | head -1)"
        [ -n "$LATEST" ] || { platform::err "没有找到备份"; exit 1; }
        echo "从备份恢复: $LATEST"
        cp -p "$LATEST" "$MAIN" || { platform::err "恢复失败"; exit 1; }
        echo "✅ 已恢复（补丁状态: $(status_patch)）"
        echo "需要重启桥接才能生效："
        echo "   bash scripts/stop-bridge.sh && bash scripts/start-bridge.sh"
        ;;
    *)
        platform::err "未知子命令: $1（可用 status/apply/revert）"; exit 1
        ;;
esac
