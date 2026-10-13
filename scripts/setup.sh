#!/bin/bash
# feishu-bridge 配置向导
set -e

CONFIG_DIR="$HOME/.config/feishu-bridge"
VENV_DIR="$HOME/.venv-feishu-bridge"

echo "========================================="
echo "  Feishu Bridge 配置向导"
echo "========================================="
echo ""

if [ -f "$CONFIG_DIR/.env" ] && [ -f "$CONFIG_DIR/config.json" ]; then
    echo "当前配置："
    AID=$(grep -m1 '^FEISHU_APP_ID=' "$CONFIG_DIR/.env" | cut -d= -f2 | tr -d '"'"'" )
    [ -n "$AID" ] && echo "  APP_ID: ${AID:0:12}..."
    echo ""
    read -r -p "是否重新配置? (y/N): " reconfigure
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
echo "⚠️ 关于 Secret 的输入方式："
echo "   · 输入时用 read -s，不回显、不进终端滚动区"
echo "   · 但 shell 历史仍可能留下痕迹；敏感环境建议改用文件派生："
echo "     sed -n 's/^FEISHU_APP_SECRET=//p' 既有文件 >> $CONFIG_DIR/.env"
echo "   · 本机安全层会把「说出来的密钥」替换成 <SECRET_xxx> 占位符，"
echo "     手打进去会得到一个字面量占位符而不是真密钥——这是实测踩过的坑。"
echo ""

read -r -p "请输入 App ID (cli_xxx): " app_id
read -r -s -p "请输入 App Secret (不回显): " app_secret
echo ""

if [ -z "$app_id" ] || [ -z "$app_secret" ]; then
    echo "❌ App ID 和 App Secret 不能为空"
    exit 1
fi

cat > "$CONFIG_DIR/.env" << EOF
FEISHU_APP_ID=$app_id
FEISHU_APP_SECRET=$app_secret
FEISHU_DOMAIN=feishu
EOF
chmod 600 "$CONFIG_DIR/.env"
echo "✅ 已保存环境变量: $CONFIG_DIR/.env (权限 600)"

echo ""
echo "测试凭证..."
set -a; . "$CONFIG_DIR/.env"; set +a
"$VENV_DIR/bin/python3" - << 'PY'
import os, sys
app_id = os.getenv("FEISHU_APP_ID")
app_secret = os.getenv("FEISHU_APP_SECRET")
try:
    import requests
except ImportError:
    print("⚠️ venv 里没有 requests，跳过凭证测试（不影响桥接运行）")
    sys.exit(0)
try:
    r = requests.post(
        "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal",
        json={"app_id": app_id, "app_secret": app_secret}, timeout=15)
    data = r.json()
except Exception as e:
    print(f"⚠️ 凭证测试请求失败: {e}")
    sys.exit(0)
if data.get("code") == 0:
    print("✅ 凭证有效，tenant_access_token 获取成功")
else:
    print(f"❌ 凭证无效: code={data.get('code')} msg={data.get('msg')}")
    sys.exit(1)
PY

echo ""
echo "配置完成！"
