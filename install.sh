#!/usr/bin/env bash

TITLE="sing-box 一键安装系统"

echo "=============================="
echo "$TITLE"
echo "=============================="

# 基础依赖
apt update -y
apt install -y curl jq qrencode uuid-runtime openssl

# 检查 sing-box
if ! command -v sing-box &> /dev/null; then
  echo "[1] 安装 sing-box..."

  VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)

  curl -L -o sb.tar.gz \
  "https://github.com/SagerNet/sing-box/releases/download/${VER}/sing-box-${VER#v}-linux-amd64.tar.gz"

  tar -xzf sb.tar.gz
  mv sing-box-*/sing-box /usr/local/bin/
  chmod +x /usr/local/bin/sing-box
fi

# 拉取核心脚本（你原来的逻辑）
TMP="/tmp/singbox-core.sh"

curl -Ls https://raw.githubusercontent.com/yan9jx/singbox-tool/main/singbox-rebuild.sh -o $TMP

if [ ! -s "$TMP" ]; then
  echo "❌ 核心脚本下载失败（GitHub路径不对）"
  exit 1
fi

chmod +x $TMP

echo "[2] 启动核心安装..."
bash $TMP
