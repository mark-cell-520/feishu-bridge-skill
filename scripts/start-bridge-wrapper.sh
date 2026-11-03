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
: "${FEISHU_BRIDGE_CONFIG_HOME:=$HOME/.config/feishu-bridge}"
: "${FEISHU_BRIDGE_VENV:=$HOME/.venv-feishu-bridge}"
: "${FEISHU_BRIDGE_BOT:=claude-code}"

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

set -a
[ -f "$FEISHU_BRIDGE_CONFIG_HOME/.env" ] && . "$FEISHU_BRIDGE_CONFIG_HOME/.env"
set +a

exec "$BIN" \
  --config "$FEISHU_BRIDGE_CONFIG_HOME/config.json" \
  --bot "$FEISHU_BRIDGE_BOT" \
  --log-level INFO
