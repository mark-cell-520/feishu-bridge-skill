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
set -a
[ -f "$HOME/.config/feishu-bridge/.env" ] && . "$HOME/.config/feishu-bridge/.env"
set +a
exec "$HOME/.venv-feishu-bridge/bin/feishu-bridge" \
  --config "$HOME/.config/feishu-bridge/config.json" \
  --bot claude-code \
  --log-level INFO
