#!/bin/bash
# send.sh — 经本机 feishu-cli 把文本/文件/图片投递到飞书（macOS / Linux 入口）
#
# 这是跨平台核心 send.py 的 bash 薄封装。真正干活的是 Python，
# 因为 stat -f%z / stat -c%s / PowerShell 三套语法不可能在一个 shell 里写对。
#
# 用法:
#   send.sh text  <文本>            [chat-id]
#   send.sh file  <本地路径>        [chat-id]
#   send.sh image <本地图片路径>    [chat-id]
#   send.sh chat                    # 显示当前会话的 chat_id 后退出，不发送
#
# chat-id 省略时，取当前飞书会话（从桥接的会话状态文件解析）。
# 跨会话发送必须显式传 chat-id，不要依赖默认值。
#
# 退出码: 0 成功 / 1 用法或文件错误 / 2 超出大小上限 / 3 feishu-cli 报错
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CORE="$SCRIPT_DIR/send.py"

usage() {
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

[ $# -ge 1 ] || usage
CMD="$1"; shift

case "$CMD" in
    text|file|image)
        [ $# -ge 1 ] || usage
        ;;
    chat) ;;
    *) usage ;;
esac

# Python 解释器：优先平台层探测，其次 PATH，最后报明确错误
PY=""
for c in "${FEISHU_BRIDGE_PYTHON:-}" python3 python py; do
    [ -n "$c" ] || continue
    if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
done
if [ -z "$PY" ]; then
    echo "错误: 未找到 Python（试过 python3/python/py）" >&2
    echo "      可设置 FEISHU_BRIDGE_PYTHON 指定解释器" >&2
    exit 1
fi

# chat 子命令不带 payload
if [ "$CMD" = "chat" ]; then
    exec "$PY" "$CORE" chat
fi

exec "$PY" "$CORE" "$CMD" "$@"
