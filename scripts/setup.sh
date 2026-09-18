#!/bin/bash
# feishu-bridge 配置脚本
set -e

CONFIG_DIR="$HOME/.config/feishu-bridge"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "========================================="
echo "  Feishu Bridge 配置向导"
echo "========================================="
echo ""

# 检查是否已有配置
if [ -f "$CONFIG_DIR/.env" ] && [ -f "$CONFIG_DIR/config.json" ]; then
    echo "当前配置："
    echo "  APP_ID: $(grep FEISHU_APP_ID "$CONFIG_DIR/.env" | cut -d= -f2 | head -c 10)..."
    echo ""
    read -p "是否重新配置? (y/N): " reconfigure
    if [ "$reconfigure" != "y" ]; then
        echo "保持现有配置"
        exit 0
    fi
fi

mkdir -p "$CONFIG_DIR"

echo "请访问 https://open.feishu.cn/app 创建飞书应用："
echo "  1. 创建企业自建应用"
echo "  2. 启用机器人能力"
echo "  3. 订阅事件 im.message.receive_v1（长连接模式）"
echo "  4. 发布应用"
echo "  5. 复制 App ID 和 App Secret"
echo ""

read -p "请输入 App ID (cli_xxx): " app_id
read -p "请输入 App Secret: " app_secret

if [ -z "$app_id" ] || [ -z "$app_secret" ]; then
    echo "❌ App ID 和 App Secret 不能为空"
    exit 1
fi

# 保存 .env
cat > "$CONFIG_DIR/.env" << EOF
FEISHU_APP_ID=$app_id
FEISHU_APP_SECRET=$app_secret
FEISHU_DOMAIN=feishu
EOF

chmod 600 "$CONFIG_DIR/.env"
echo "✅ 已保存环境变量: $CONFIG_DIR/.env"

# 测试凭证
echo ""
echo "测试凭证..."
source "$CONFIG_DIR/.env"
"$HOME/.venv-feishu-bridge/bin/python3" -c "
import os, requests
app_id = os.getenv('FEISHU_APP_ID')
app_secret = os.getenv('FEISHU_APP_SECRET')
r = requests.post('https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal', json={'app_id': app_id, 'app_secret': app_secret})
data = r.json()
if data.get('code') == 0:
    print('✅ 凭证有效，tenant_access_token 获取成功')
else:
    print(f'❌ 凭证无效: {data}')
    exit(1)
"
echo ""

echo "配置完成！"
