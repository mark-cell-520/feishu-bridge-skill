#!/bin/bash
# feishu-bridge 健康检查脚本

echo "检查飞书桥接健康状态..."

# 检查服务
if ! launchctl list | grep -q "com.feishu.bridge"; then
    echo '{"ok": false, "error": "服务未运行"}'
    exit 1
fi

# 检查配置
CONFIG_DIR="$HOME/.config/feishu-bridge"
if [ ! -f "$CONFIG_DIR/.env" ]; then
    echo '{"ok": false, "error": "配置缺失"}'
    exit 1
fi

source "$CONFIG_DIR/.env"

# 返回健康信息
cat << EOF
{
  "ok": true,
  "feishuApp": "${FEISHU_APP_ID}",
  "service": "running",
  "config": "$CONFIG_DIR"
}
EOF
