#!/bin/bash
# logs.sh — 日志查看与管理（跨平台）
#
# 为什么单独一个脚本：bridge.err.log 是 INFO 级，CardKit 的
#   agent_status 字段校验失败会持续刷屏（本机实测单日数千条），
#   文件很容易长到几百 KB。直接 tail 看不到重点，直接删又丢掉现场。
#
# 能力：
#   logs.sh tail [N]        末尾 N 行（默认 30）
#   logs.sh follow          实时跟随（Ctrl-C 退出）
#   logs.sh errors [N]      只看 ERROR/CRITICAL/WARNING，按内容聚合计数
#   logs.sh rotate          轮换：.log → .log.1（覆盖式，只留一代）
#   logs.sh size            各日志文件大小与年龄
#   logs.sh clean           清空（轮换后确认无用再这么做）
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/platform.sh"
platform::init

STDLOG="$LOG_DIR/bridge.log"
ERRLOG="$LOG_DIR/bridge.err.log"
N="${2:-30}"

die() { platform::err "$*"; exit 1; }

# 日志不在时不直接失败——服务可能从没起过，这也是有效信息
warn_if_missing() {
    for f in "$STDLOG" "$ERRLOG"; do
        [ -f "$f" ] || platform::warn "日志不存在: $f"
    done
    [ -f "$STDLOG" ] || [ -f "$ERRLOG" ] || exit 1
}

CMD="${1:-tail}"
warn_if_missing

case "$CMD" in
    tail)
        echo "=== $ERRLOG 末尾 $N 行 ==="
        [ -f "$ERRLOG" ] && tail -"$N" "$ERRLOG"
        echo
        echo "=== $STDLOG 末尾 $N 行 ==="
        [ -f "$STDLOG" ] && tail -"$N" "$STDLOG"
        ;;
    follow)
        # 两个日志一起跟，用标签区分来源
        echo "跟随中（Ctrl-C 退出）..."
        tail -f "$ERRLOG" "$STDLOG" 2>/dev/null
        ;;
    errors)
        # 聚合计数：刷屏的同一条错只显示一次并给出次数，
        # 比 tail 更能看出"是同一个错在刷"还是"多种错并存"。
        echo "=== 错误聚合（${ERRLOG}，前 $N 类）==="
        [ -f "$ERRLOG" ] && "$PLATFORM_PYTHON" - "$ERRLOG" "$N" <<'PY'
import re, sys, collections
path, topn = sys.argv[1], int(sys.argv[2])
pat = re.compile(r"(ERROR|CRITICAL|WARNING)\s+(.{0,100})")
c = collections.Counter()
first, last = {}, {}
with open(path, errors="replace") as f:
    for line in f:
        m = pat.search(line)
        if not m:
            continue
        key = f"{m.group(1)} {m.group(2).strip()[:70]}"
        c[key] += 1
        ts = line[:19]
        if key not in first:
            first[key] = ts
        last[key] = ts
if not c:
    print("  （无 ERROR/WARNING/CRITICAL 记录）")
for msg, n in c.most_common(topn):
    print(f"  {n:>6}x  {first[msg]} → {last[msg]}")
    print(f"          {msg}")
PY
        ;;
    rotate)
        # 只留一代：当前 → .1，旧的 .1 被覆盖。
        # 不留多代是因为日志本身信息密度低，多代只会占地方。
        for f in "$ERRLOG" "$STDLOG"; do
            [ -f "$f" ] || continue
            SZ="$(wc -c < "$f" | tr -d ' ')"
            mv -f "$f" "$f.1" 2>/dev/null && : > "$f" && \
                echo "✅ 已轮换 $(basename "$f")（原 ${SZ} 字节 → $(basename "$f").1）"
        done
        echo
        echo "提示：服务运行中轮换后，桥接持有的文件句柄仍指向已改名的 inode，"
        echo "      新内容会继续写进 .log.1。要让桥接改写新文件需重启服务："
        echo "      bash scripts/stop-bridge.sh && bash scripts/start-bridge.sh"
        ;;
    size)
        echo "日志目录: $LOG_DIR"
        for f in "$ERRLOG" "$STDLOG"; do
            [ -f "$f" ] || continue
            SZ="$(wc -c < "$f" | tr -d ' ')"
            MT="$(platform::stat_mtime "$f" || echo '')"
            AGE="?"
            [ -n "$MT" ] && AGE="$(( $(date +%s) - MT ))s"
            printf '  %-18s %10s 字节  年龄 %s\n' "$(basename "$f")" "$SZ" "$AGE"
        done
        [ -f "$ERRLOG.1" ] && printf '  %-18s %10s 字节（上一代）\n' \
            "bridge.err.log.1" "$(wc -c < "$ERRLOG.1" | tr -d ' ')"
        ;;
    clean)
        # 破坏性操作，要求显式确认第二个参数
        if [ "${2:-}" != "--yes" ]; then
            die "这会清空日志，排障现场会丢失。确认请执行: logs.sh clean --yes"
        fi
        for f in "$ERRLOG" "$STDLOG"; do
            [ -f "$f" ] && : > "$f" && echo "✅ 已清空 $(basename "$f")"
        done
        ;;
    *)
        die "未知子命令: ${CMD}（可用 tail/follow/errors/rotate/size/clean）"
        ;;
esac
