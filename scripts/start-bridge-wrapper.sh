#!/bin/bash
# feishu-bridge launchd 启动包装器
#
# 这是 plist 的真正入口。它只做一件事：先加载 .env，再 exec 真正的二进制。
#
# 为什么必须有它（本机实测，2026-10-13）：
#   feishu_bridge/main.py 的 load_config 只从 os.environ 里取变量，
#   取不到就 log.error("Unresolved env vars in config: ...") 然后退出。
#   它自己不读 ~/.config/feishu-bridge/.env。
#   读 .env 的逻辑只存在于 feishu_bridge/cli.py（feishu-cli 入口）里。
#   → 所以 launchd 直拉二进制必然起不来；直拉 feishu-cli 反而能起来。
#   这个不对称没有任何文档说明，是排障时踩出来的。
#
# 安装位置：~/.local/share/feishu-bridge/start-bridge.sh（由 install.sh 复制）
# 路径支持环境变量覆盖（多环境：dev/prod、多 bot 隔离），
# 与 lib/platform.sh 用同一套变量名，避免两处口径不一致。
#
# ── 解释器为什么要单独解析（本机实测，2026-10-21）──────────────────
#   直接 exec venv 里的 feishu-bridge，是靠它的 shebang 找解释器，
#   而 shebang 指向 ~/.local/share/uv/... 一类的路径，那条链断过一次：
#   目录名会变、claude-code 升级会换二进制，一换桥接就起不来。
#   本机的解法是把解释器固化进一个 app bundle
#   （~/Applications/FeishuBridge.app/Contents/MacOS/python3.11），
#   macOS 的完全磁盘访问授权挂在这条永久不变的路径上，不随上面那些变动失效。
#   所以这里显式解析解释器，不再依赖 shebang。
#   没有 bundle 的机器走后面的候选，行为与旧版一致。
: "${FEISHU_BRIDGE_CONFIG_HOME:=$HOME/.config/feishu-bridge}"
: "${FEISHU_BRIDGE_VENV:=$HOME/.venv-feishu-bridge}"
: "${FEISHU_BRIDGE_BOT:=claude-code}"
: "${FEISHU_BRIDGE_PYTHON=}"

# venv 可执行目录：POSIX 是 bin，Windows 是 Scripts。
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*|Windows_NT) VENV_BIN="Scripts" ;;
    *)                               VENV_BIN="bin" ;;
esac

BIN="$FEISHU_BRIDGE_VENV/$VENV_BIN/feishu-bridge"
[ -x "$BIN" ] || {
    echo "错误: 找不到 feishu-bridge 可执行文件: $BIN" >&2
    echo "      先运行 bash scripts/install.sh" >&2
    exit 1
}

# 解释器候选，按优先级排列：
#   1. FEISHU_BRIDGE_PYTHON —— 显式指定，最高优先，与 lib/platform.sh 同口径
#   2. app bundle 内的固化解释器 —— macOS 上 FDA 授权挂在这条路径上
#   3. venv 自带的 python —— 没有 bundle 的机器的常规形态
#   4. 空 —— 直接 exec BIN，交回 shebang（旧行为，兜底）
PY="$FEISHU_BRIDGE_PYTHON"
if [ -z "$PY" ]; then
    for cand in \
        "$HOME/Applications/FeishuBridge.app/Contents/MacOS/python3.11" \
        "$FEISHU_BRIDGE_VENV/$VENV_BIN/python3" \
        "$FEISHU_BRIDGE_VENV/$VENV_BIN/python"
    do
        if [ -x "$cand" ]; then PY="$cand"; break; fi
    done
fi

# 选中的解释器必须真的能跑，否则明确报错退出。
# 不静默降级：FDA 授权失效时"看起来起来了其实读不了目录"，
# 比启动失败更难排查。
if [ -n "$PY" ] && [ ! -x "$PY" ]; then
    echo "错误: FEISHU_BRIDGE_PYTHON 指向的不可执行: $PY" >&2
    exit 1
fi

set -a
[ -f "$FEISHU_BRIDGE_CONFIG_HOME/.env" ] && . "$FEISHU_BRIDGE_CONFIG_HOME/.env"
set +a

if [ -n "$PY" ]; then
    exec "$PY" "$BIN" \
      --config "$FEISHU_BRIDGE_CONFIG_HOME/config.json" \
      --bot "$FEISHU_BRIDGE_BOT" \
      --log-level INFO
else
    exec "$BIN" \
      --config "$FEISHU_BRIDGE_CONFIG_HOME/config.json" \
      --bot "$FEISHU_BRIDGE_BOT" \
      --log-level INFO
fi
