#!/usr/bin/env bash

CONF="/etc/sing-box/config.json"
SERVICE="sing-box"

generate() {

echo "=============================="
read -p "请输入节点名称: " NODE_NAME
read -p "请输入端口(默认21445): " PORT
PORT=${PORT:-21445}

UUID=$(cat /proc/sys/kernel/random/uuid)
KEYS=$(sing-box generate reality-keypair)
PRIVATE_KEY=$(echo "$KEYS" | awk '/PrivateKey/{print $2}')
PUBLIC_KEY=$(echo "$KEYS" | awk '/PublicKey/{print $2}')
SHORT_ID=$(openssl rand -hex 4)

IP=$(curl -4s ifconfig.me)

cat > $CONF <<EOF
{
  "log": { "level": "info" },

  "dns": {
    "servers": [
      { "tag": "google", "address": "8.8.8.8", "detour": "direct" }
    ],
    "final": "google"
  },

  "inbounds": [
    {
      "type": "vless",
      "listen": "::",
      "listen_port": $PORT,
      "users": [
        {
          "uuid": "$UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.microsoft.com",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "www.microsoft.com",
            "server_port": 443
          },
          "private_key": "$PRIVATE_KEY",
          "short_id": ["$SHORT_ID"]
        }
      }
    }
  ],

  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

systemctl restart sing-box

LINK="vless://${UUID}@${IP}:${PORT}?security=reality&encryption=none&flow=xtls-rprx-vision&sni=www.microsoft.com&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}#${NODE_NAME}"

echo ""
echo "=============================="
echo "节点已生成"
echo "=============================="
echo "$LINK"
echo "$LINK" > /root/vless.txt
}

show() {
cat /root/vless.txt
}

change_port() {
read -p "输入新端口: " NEWPORT

OLD=$(cat /etc/sing-box/config.json | sed "s/\"listen_port\": [0-9]*/\"listen_port\": $NEWPORT/")

echo "$OLD" > $CONF

systemctl restart sing-box

echo "端口已更新: $NEWPORT"
}

uninstall() {
systemctl stop sing-box
rm -rf /etc/sing-box
rm -f /root/vless.txt
echo "已卸载"
}

echo "=============================="
echo "1. 安装 / 重建节点"
echo "2. 查看链接"
echo "3. 卸载"
echo "4. 更换端口"
echo "=============================="

read -p "选择: " c

case $c in
1) generate ;;
2) show ;;
3) uninstall ;;
4) change_port ;;
esac
