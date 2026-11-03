#!/bin/bash
# perf.sh — 对话流畅度与性能度量（跨平台）
#
# 度量什么、为什么：
#   流畅度的直接指标不是 CPU，而是"每轮从受理到交付花了多久"，
#   以及"流式状态卡片更新失败了多少次"。后者本机实测是重灾区：
#   agent_status 元素的 markdown 字段被飞书 API 以 code=99992402
#   拒绝，导致流式进度更新完全失效——你在飞书上看到的是卡片不动，
#   而不是逐步输出。这个指标必须被量化，否则只能靠体感。
#
# 数据来源全部是桥接自己的日志，不引入额外探针开销：
#   "Claude: resume=..."  → 一轮开始
#   "Deliver: content_len=..." → 一轮交付
#   两者时间差即端到端耗时。
#
# 用法：
#   bash scripts/perf.sh              # 报告（默认最近 500 轮）
#   bash scripts/perf.sh --json       # 机器可读
#   bash scripts/perf.sh --since 24h  # 只看最近 24 小时
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/platform.sh"
platform::init

ERRLOG="$LOG_DIR/bridge.err.log"
JSON=0
SINCE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --json)  JSON=1 ;;
        --since) SINCE="${2:-}"; shift ;;
        *) platform::err "未知参数: $1（可用 --json/--since）"; exit 1 ;;
    esac
    shift
done

[ -f "$ERRLOG" ] || { platform::err "错误日志不存在: $ERRLOG"; exit 1; }
[ -n "$PLATFORM_PYTHON" ] || { platform::err "未找到 Python"; exit 1; }

# 全部计算放 Python：日志解析、时间配对、分位数，shell 做不了也不该做
"$PLATFORM_PYTHON" - "$ERRLOG" "$JSON" "$SINCE" <<'PY'
import json, re, sys
from datetime import datetime, timedelta
from pathlib import Path

log_path, as_json, since = sys.argv[1], sys.argv[2] == "1", sys.argv[3]

start_re = re.compile(r'^(\S+ \S+) .*Claude: resume=\S+ sid=(\S+)')
deliv_re = re.compile(r'^(\S+ \S+) .*Deliver: content_len=(\d+) is_error=(\S+)')
fail_re  = re.compile(r'Element update failed \((\w+)\): code=(\d+)')
stall_re = re.compile(r'(\d+) consecutive failures for (\w+)')

cutoff = None
if since:
    m = re.match(r'(\d+)([hmd])$', since)
    if m:
        n, unit = int(m.group(1)), m.group(2)
        delta = {"h": timedelta(hours=n), "m": timedelta(minutes=n),
                 "d": timedelta(days=n)}[unit]
        cutoff = datetime.now() - delta

def parse_ts(s):
    try:
        return datetime.strptime(s, "%Y-%m-%d %H:%M:%S")
    except ValueError:
        return None

pending, rounds, err_rounds = [], [], []
unclosed = 0
elem_fail = {}     # element_id -> count
elem_code = {}     # (element_id, code) -> count
stall_events = 0
lines_scanned = 0

for line in Path(log_path).read_text(errors="replace").splitlines():
    lines_scanned += 1
    ts_s = line[:19]
    ts = parse_ts(ts_s)
    if ts is None:
        continue
    if cutoff and ts < cutoff:
        continue

    m = start_re.match(line)
    if m:
        pending.append(ts)
        continue

    m = deliv_re.match(line)
    if m:
        t1 = parse_ts(m.group(1))
        if not pending or t1 is None:
            continue
        t0 = pending.pop(0)              # FIFO：最早的开始配最早的交付
        dt = (t1 - t0).total_seconds()
        if dt > 1800:                    # 超过 30 分钟视为错配，不计入
            continue
        if m.group(3) == "True":
            err_rounds.append(dt)
        else:
            rounds.append(dt)
        continue

    m = fail_re.search(line)
    if m:
        eid, code = m.group(1), m.group(2)
        elem_fail[eid] = elem_fail.get(eid, 0) + 1
        elem_code[(eid, code)] = elem_code.get((eid, code), 0) + 1
        continue

    if stall_re.search(line):
        stall_events += 1

unclosed = len(pending)

def pct(sorted_vals, p):
    if not sorted_vals:
        return None
    i = min(len(sorted_vals) - 1, int(len(sorted_vals) * p))
    return round(sorted_vals[i], 1)

ds = sorted(rounds)
report = {
    "logLinesScanned": lines_scanned,
    "rounds": {
        "delivered": len(ds),
        "failed": len(err_rounds),
        "unclosedStarts": unclosed,
        "fastestSec": round(ds[0], 1) if ds else None,
        "medianSec": pct(ds, 0.5),
        "p90Sec": pct(ds, 0.9),
        "slowestSec": round(ds[-1], 1) if ds else None,
        "meanSec": round(sum(ds) / len(ds), 1) if ds else None,
        "buckets": {
            "under30s": sum(1 for d in ds if d < 30),
            "30to120s": sum(1 for d in ds if 30 <= d < 120),
            "over120s": sum(1 for d in ds if d >= 120),
        },
    },
    "streamingCard": {
        "elementFailures": elem_fail,
        "byElementAndCode": {f"{k[0]}/{k[1]}": v for k, v in elem_code.items()},
        "stallWarnings": stall_events,
    },
}

if as_json:
    print(json.dumps(report, ensure_ascii=False, indent=2))
    sys.exit(0)

# ── 人读报告 ────────────────────────────────────────────────────
print("=========================================")
print("  飞书桥接 流畅度与性能报告")
print(f"  日志: {log_path}")
if cutoff:
    print(f"  范围: 最近 {since}")
print(f"  扫描行数: {lines_scanned}")
print("=========================================")
print()

r = report["rounds"]
print("一、端到端耗时（受理 → 交付）")
if r["delivered"]:
    print(f"  成功交付 {r['delivered']} 轮，失败 {r['failed']} 轮，"
          f"未闭合开始 {r['unclosedStarts']} 个")
    print(f"  最快 {r['fastestSec']}s   中位 {r['medianSec']}s   "
          f"P90 {r['p90Sec']}s   最慢 {r['slowestSec']}s   平均 {r['meanSec']}s")
    b = r["buckets"]
    print(f"  分布: <30s {b['under30s']} 轮 | 30-120s {b['30to120s']} 轮 | "
          f">120s {b['over120s']} 轮")
    if b["over120s"] > r["delivered"] * 0.5 and r["delivered"] >= 5:
        print("  ⚠️ 过半轮次超过 2 分钟。若任务本身不重，检查队列是否积压")
        print("     或 agent 是否被慢任务堵住（WORKER_COUNT 固定为 4，不可配）")
else:
    print("  （没有可配对的轮次）")
print()

s = report["streamingCard"]
print("二、流式卡片健康度（流畅度的直接指标）")
if s["elementFailures"]:
    for eid, n in sorted(s["elementFailures"].items(), key=lambda x: -x[1]):
        print(f"  {eid}: {n} 次更新失败")
    for k, v in sorted(s["byElementAndCode"].items(), key=lambda x: -x[1]):
        print(f"    {k} → {v} 次")
    print(f"  停滞告警: {s['stallWarnings']} 次")
    print()
    print("  说明：agent_status 持续失败意味着飞书上看不到逐步进度，")
    print("        只能等最终结果一次性出现。根因在桥接包的 ui.py——")
    print("        该元素是 markdown 标签，飞书 API 以 code=99992402")
    print("        （field validation failed）拒绝其字段校验。")
    print("        属上游问题，技能层只能度量与报告，改包会被升级覆盖。")
else:
    print("  ✅ 无元素更新失败，流式卡片正常")
print()

print("三、日志噪音占比（影响可读性与磁盘 IO）")
if s["elementFailures"] and lines_scanned:
    noise = sum(s["elementFailures"].values())
    p = noise * 100.0 / lines_scanned
    print(f"  {noise} / {lines_scanned} 行是元素更新失败，占 {p:.1f}%")
    if p > 30:
        print("  ⚠️ 噪音超过三成。用 logs.sh errors 看聚合，")
        print("     或 logs.sh rotate 轮换（注意运行中轮换需重启才写新文件）")
else:
    print("  无可量化噪音")
print()
print("=========================================")
PY
