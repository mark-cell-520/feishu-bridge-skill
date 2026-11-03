#!/usr/bin/env python3
"""send.py — 经本机 feishu-cli 把文本/文件/图片投递到飞书（跨平台核心）

为什么用 Python 做核心而不再让 bash 直接干活：
  1. stat -f%z 是 BSD 专有，GNU 是 stat -c%s，PowerShell 又是另一套。
     os.path.getsize 一处写完三个平台都对。
  2. 路径拼接、home 展开、状态文件解析在 Windows 上 bash 不可靠。
  3. 退出码语义（用法错/超限/投递失败）需要精确控制，shell 容易和
     上游工具的退出码撞车。

bash 的 send.sh 与 PowerShell 的 send.ps1 都只是这一层的薄封装。

退出码：0 成功 / 1 用法或文件错误 / 2 超出大小上限 / 3 feishu-cli 报错
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

# 飞书硬上限
IMG_MAX = 10 * 1024 * 1024   # 图片 10MB
FILE_MAX = 30 * 1024 * 1024  # 文件 30MB

EXIT_OK = 0
EXIT_USAGE = 1
EXIT_TOO_BIG = 2
EXIT_CLI = 3


def _home() -> Path:
    """跨平台 home。Windows 上 Path.home() 走 USERPROFILE，比 $HOME 可靠。"""
    return Path.home()


# ── feishu-cli 定位 ──────────────────────────────────────────────
# 多环境：venv 可能在不同位置，也可能已进 PATH。按优先级探测，
# 第一个存在的就是；都不中就用 PATH 里的 feishu-cli。
def find_cli(explicit: str | None = None) -> str | None:
    if explicit:
        return explicit if Path(explicit).exists() else None

    candidates = []
    venv_home = os.environ.get("FEISHU_BRIDGE_VENV")
    if venv_home:
        candidates.append(Path(venv_home))

    base = _home()
    for venv in (base / ".venv-feishu-bridge",):
        candidates.append(venv)

    for venv in candidates:
        for sub in ("bin", "Scripts"):
            for name in ("feishu-cli", "feishu-cli.exe"):
                p = venv / sub / name
                if p.exists():
                    return str(p)

    # 兜底：PATH 里找
    found = shutil_which("feishu-cli")
    return found


def shutil_which(name: str) -> str | None:
    """优先用标准库 shutil.which，它会正确处理 Windows 的 PATHEXT
    （.exe/.bat/.cmd 等）与可执行位判断；标准库不可用时才退回手动遍历。"""
    try:
        import shutil
        found = shutil.which(name)
        if found:
            return found
    except Exception:
        pass
    # 手动兜底：补上常见 Windows 可执行后缀
    exts = [""]
    if os.name == "nt":
        exts += [e.lower() for e in os.environ.get("PATHEXT", ".EXE;.BAT;.CMD").split(";") if e]
    for d in os.environ.get("PATH", "").split(os.pathsep):
        if not d:
            continue
        for ext in exts:
            p = Path(d) / (name + ext)
            try:
                if p.is_file() and os.access(p, os.X_OK):
                    return str(p)
            except OSError:
                continue
    return None


# ── 当前会话 chat_id ─────────────────────────────────────────────
# 桥接的会话状态文件每帧重写，键形如 claude-code:oc_xxx:
# 多 bot 时用 FEISHU_BRIDGE_BOT 指定，默认 claude-code。
def current_chat(bot: str | None = None) -> str | None:
    bot = bot or os.environ.get("FEISHU_BRIDGE_BOT", "claude-code")
    home = os.environ.get("FEISHU_BRIDGE_HOME")
    state = (Path(home) if home else _home() / ".local/share/feishu-bridge") \
        / "workspaces" / bot / "state/feishu-bridge" / f"sessions-{bot}.json"
    if not state.is_file():
        return None
    try:
        text = state.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    pat = re.compile(rf"{re.escape(bot)}:(oc_[a-z0-9]{{8,}}):")
    m = pat.search(text)
    return m.group(1) if m else None


def die(msg: str, code: int) -> None:
    print(f"错误: {msg}", file=sys.stderr)
    sys.exit(code)


def run_cli(cli: str, args: list[str]) -> int:
    """调 feishu-cli，把它和本地用法错的退出码分开。"""
    try:
        proc = subprocess.run([cli, *args], capture_output=False)
    except OSError as e:
        print(f"错误: 无法执行 {cli}: {e}", file=sys.stderr)
        return EXIT_CLI
    return EXIT_OK if proc.returncode == 0 else EXIT_CLI


def main() -> int:
    ap = argparse.ArgumentParser(
        prog="send.py",
        description="经 feishu-cli 投递文本/文件/图片到飞书（跨平台）")
    ap.add_argument("kind", choices=["text", "file", "image", "chat"])
    ap.add_argument("payload", nargs="?", default=None)
    ap.add_argument("chat_id", nargs="?", default=None)
    ap.add_argument("--cli", default=None, help="feishu-cli 路径（默认自动探测）")
    ap.add_argument("--bot", default=None, help="bot 名（默认 claude-code）")
    ap.add_argument("--max-mb", type=float, default=None,
                    help="覆盖大小上限（MB），用于放宽飞书默认限制")
    args = ap.parse_args()

    cli = find_cli(args.cli)
    if not cli:
        die("找不到 feishu-cli。可设置 FEISHU_BRIDGE_VENV 指向 venv，"
            "或用 --cli 显式指定", EXIT_USAGE)

    chat = args.chat_id or current_chat(args.bot)
    if not chat:
        die("未提供 chat-id，且无法从会话状态文件解析出当前会话。"
            "跨会话发送请显式传 chat-id", EXIT_USAGE)

    if args.kind == "chat":
        # chat 子命令在上方已解析过 chat，这里直接打印，不重复解析。
        # 原来此处又调了一次 current_chat，属冗余，且与上方结果可能不一致。
        print(chat)
        return EXIT_OK

    if not args.payload:
        die(f"{args.kind} 缺少内容参数", EXIT_USAGE)

    if args.kind == "text":
        # payload 非空已在外层统一校验，此处不重复检查
        return run_cli(cli, ["send-message", "--chat-id", chat,
                             "--text", args.payload])

    # file / image 都需要先过文件检查
    p = Path(args.payload)
    if not p.exists():
        die(f"文件不存在: {p}", EXIT_USAGE)
    if not p.is_file():
        die(f"不是普通文件: {p}", EXIT_USAGE)

    try:
        size = p.stat().st_size  # 跨平台，替代 stat -f%z / stat -c%s
    except OSError as e:
        die(f"无法读取文件大小: {p}（{e}）", EXIT_USAGE)
    default_max = IMG_MAX if args.kind == "image" else FILE_MAX
    limit = int(args.max_mb * 1024 * 1024) if args.max_mb else default_max
    if size > limit:
        die(f"{'图片' if args.kind == 'image' else '文件'} {size} 字节，"
            f"超过 {limit // (1024 * 1024)}MB 上限", EXIT_TOO_BIG)

    if args.kind == "image":
        return run_cli(cli, ["send-image", "--chat-id", chat,
                             "--file", str(p)])
    # feishu-cli 只有 send-audio 一个文件上传入口：后缀 .opus/.ogg 走音频，
    # 其余一律 file_type=stream / msg_type=file，即通用文件消息。
    # 名字有误导性，能力是全的。
    return run_cli(cli, ["send-audio", "--chat-id", chat,
                         "--file", str(p)])


if __name__ == "__main__":
    sys.exit(main())
