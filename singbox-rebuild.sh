#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="$CONFIG_DIR/config.json"
INFO_FILE="$CONFIG_DIR/node-info.env"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
DEFAULT_PORT="21445"
SERVER_NAME="www.microsoft.com"

die() {
  echo "错误：$*" >&2
  exit 1
}

confirm() {
  local prompt="$1"
  local answer
  read -r -p "$prompt [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

require_root() {
  [[ $EUID -eq 0 ]] || die "请使用 root 运行此脚本。"
  command -v systemctl >/dev/null || die "当前系统不支持 systemd。"
}

find_singbox() {
  SB_BIN="${SB_BIN:-$(command -v sing-box || true)}"
  [[ -n "$SB_BIN" && -x "$SB_BIN" ]]
}

install_dependencies() {
  local missing=()
  local command_name
  for command_name in curl openssl tar qrencode; do
    command -v "$command_name" >/dev/null || missing+=("$command_name")
  done

  if (( ${#missing[@]} > 0 )); then
    command -v apt-get >/dev/null || die "缺少 ${missing[*]}，且当前系统不支持自动安装。"
    echo "正在安装必要组件..."
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl openssl tar qrencode ca-certificates
  fi
}

install_singbox_core() {
  local machine arch version temp_dir archive binary
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "暂不支持当前架构：$machine" ;;
  esac

  echo "未找到 sing-box 核心，正在自动安装..."
  version="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest |
    sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
  [[ -n "$version" ]] || die "无法获取 sing-box 最新版本。"

  temp_dir="$(mktemp -d)"
  archive="$temp_dir/sing-box.tar.gz"
  curl -fL "https://github.com/SagerNet/sing-box/releases/download/${version}/sing-box-${version#v}-linux-${arch}.tar.gz" -o "$archive"
  tar -xzf "$archive" -C "$temp_dir"
  binary="$(find "$temp_dir" -type f -name sing-box | head -n1)"
  [[ -n "$binary" ]] || die "sing-box 安装包中未找到核心程序。"
  install -m 755 "$binary" /usr/local/bin/sing-box
  rm -rf "$temp_dir"
  SB_BIN="/usr/local/bin/sing-box"
  echo "sing-box 核心安装完成：$version"
}

configure_bbr() {
  local current available bbr_file="/etc/sysctl.d/99-singbox-bbr.conf"
  current="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")"

  echo
  echo "当前 TCP 拥塞控制算法：$current"
  if ! confirm "是否安装 / 启用 BBR + FQ？"; then
    echo "已跳过 BBR 设置。"
    return
  fi

  modprobe tcp_bbr 2>/dev/null || true
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if ! grep -qw bbr <<<"$available"; then
    echo "警告：当前内核不支持 BBR，已跳过，不影响 sing-box 安装。"
    return
  fi

  cat >"$bbr_file" <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

  sysctl -w net.core.default_qdisc=fq >/dev/null
  sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null
  echo "BBR + FQ 已启用，当前算法：$(sysctl -n net.ipv4.tcp_congestion_control)"
}

show_link() {
  if [[ ! -f "$INFO_FILE" ]]; then
    die "没有已保存的节点链接，请先选择 1 安装/重建节点。"
  fi

  local link
  link="$(sed -n "s/^VLESS_LINK='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"
  [[ -n "$link" ]] || die "节点信息文件损坏，请重新安装节点。"

  echo
  echo "节点链接："
  echo "$link"

  install_dependencies
  echo
  echo "节点二维码："
  qrencode -t ANSIUTF8 "$link"
}

clean_old_setup() {
  systemctl stop sing-box 2>/dev/null || true
  systemctl disable sing-box 2>/dev/null || true
  rm -f "$SERVICE_FILE"
  rm -rf "$CONFIG_DIR"
  rm -f /root/vless.txt
  systemctl daemon-reload
  echo "旧 sing-box 服务、配置和旧节点信息已清除。"
}

install_node() {
  local clean_first=false
  echo
  echo "清理范围仅限旧 sing-box 服务、配置和节点信息，不会删除其他无关脚本。"
  if confirm "安装前是否清除之前安装的 sing-box / 旧脚本残留？"; then
    clean_first=true
    clean_old_setup
  fi

  install_dependencies
  find_singbox || install_singbox_core

  local node_name
  read -r -p "请输入节点名称 [sing-box]: " node_name
  node_name="${node_name:-sing-box}"
  node_name="${node_name// /-}"
  node_name="${node_name//#/-}"
  node_name="${node_name//\'/-}"

  local port="${1:-}"
  if [[ -z "$port" ]]; then
    read -r -p "请输入端口 [${DEFAULT_PORT}]: " port
    port="${port:-$DEFAULT_PORT}"
  fi
  [[ "$port" =~ ^[0-9]+$ ]] || die "端口必须是数字。"
  (( port >= 1 && port <= 65535 )) || die "端口必须在 1 到 65535 之间。"

  configure_bbr

  local keys private_key public_key uuid short_id tmp_config backup_file=""
  echo "正在生成新的 VLESS Reality 节点..."
  keys="$("$SB_BIN" generate reality-keypair)"
  private_key="$(awk -F': *' '/PrivateKey/{print $2; exit}' <<<"$keys")"
  public_key="$(awk -F': *' '/PublicKey/{print $2; exit}' <<<"$keys")"
  uuid="$(cat /proc/sys/kernel/random/uuid)"
  short_id="$(openssl rand -hex 4)"
  [[ -n "$private_key" && -n "$public_key" ]] || die "Reality 密钥生成失败。"

  mkdir -p "$CONFIG_DIR"
  tmp_config="$(mktemp)"
  trap 'rm -f "${tmp_config:-}"' RETURN

  cat >"$tmp_config" <<EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "vless",
      "listen": "::",
      "listen_port": $port,
      "users": [
        {
          "uuid": "$uuid",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$SERVER_NAME",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$SERVER_NAME",
            "server_port": 443
          },
          "private_key": "$private_key",
          "short_id": ["$short_id"]
        }
      }
    }
  ]
}
EOF

  "$SB_BIN" check -c "$tmp_config" >/dev/null

  if [[ "$clean_first" == false && -f "$CONFIG_FILE" ]]; then
    backup_file="${CONFIG_FILE}.backup.$(date +%Y%m%d-%H%M%S)"
    cp -a "$CONFIG_FILE" "$backup_file"
  fi
  install -m 600 "$tmp_config" "$CONFIG_FILE"

  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$SB_BIN run -c $CONFIG_FILE
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable sing-box >/dev/null
  if ! systemctl restart sing-box; then
    restore_backup "$backup_file"
    die "新节点启动失败。"
  fi

  sleep 2
  if ! systemctl is-active --quiet sing-box; then
    restore_backup "$backup_file"
    die "新节点未能持续运行，请查看：journalctl -u sing-box -e"
  fi

  local public_ip vless_link
  public_ip="$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$public_ip" ]] || public_ip="YOUR_SERVER_IP"
  vless_link="vless://${uuid}@${public_ip}:${port}?encryption=none&security=reality&sni=${SERVER_NAME}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&flow=xtls-rprx-vision#${node_name}"

  cat >"$INFO_FILE" <<EOF
NODE_NAME='$node_name'
PUBLIC_IP='$public_ip'
PORT='$port'
UUID='$uuid'
PRIVATE_KEY='$private_key'
PUBLIC_KEY='$public_key'
SHORT_ID='$short_id'
SERVER_NAME='$SERVER_NAME'
VLESS_LINK='$vless_link'
EOF
  chmod 600 "$INFO_FILE"

  echo
  echo "安装完成，sing-box 正在运行。"
  show_link
}

change_port() {
  [[ -f "$CONFIG_FILE" && -f "$INFO_FILE" ]] || die "未找到现有节点，请先安装节点。"
  find_singbox || die "未找到 sing-box 核心。"

  local new_port old_port node_name public_ip uuid public_key short_id server_name
  read -r -p "请输入新端口: " new_port
  [[ "$new_port" =~ ^[0-9]+$ ]] || die "端口必须是数字。"
  (( new_port >= 1 && new_port <= 65535 )) || die "端口必须在 1 到 65535 之间。"

  old_port="$(sed -n "s/^PORT='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"
  node_name="$(sed -n "s/^NODE_NAME='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"
  public_ip="$(sed -n "s/^PUBLIC_IP='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"
  uuid="$(sed -n "s/^UUID='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"
  public_key="$(sed -n "s/^PUBLIC_KEY='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"
  short_id="$(sed -n "s/^SHORT_ID='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"
  server_name="$(sed -n "s/^SERVER_NAME='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"
  [[ -n "$old_port" && -n "$uuid" && -n "$public_key" && -n "$short_id" ]] ||
    die "节点信息不完整，请重新安装节点。"
  node_name="${node_name:-sing-box}"
  server_name="${server_name:-$SERVER_NAME}"

  local tmp_config backup_file vless_link
  tmp_config="$(mktemp)"
  backup_file="${CONFIG_FILE}.backup.$(date +%Y%m%d-%H%M%S)"
  cp -a "$CONFIG_FILE" "$backup_file"
  sed -E "s/(\"listen_port\"[[:space:]]*:[[:space:]]*)[0-9]+/\1${new_port}/" "$CONFIG_FILE" >"$tmp_config"
  "$SB_BIN" check -c "$tmp_config" >/dev/null
  install -m 600 "$tmp_config" "$CONFIG_FILE"
  rm -f "$tmp_config"

  if ! systemctl restart sing-box || ! systemctl is-active --quiet sing-box; then
    cp -a "$backup_file" "$CONFIG_FILE"
    systemctl restart sing-box 2>/dev/null || true
    die "更换端口失败，已恢复旧端口。"
  fi

  vless_link="vless://${uuid}@${public_ip}:${new_port}?encryption=none&security=reality&sni=${server_name}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&flow=xtls-rprx-vision#${node_name}"
  sed -i "s/^PORT='.*'$/PORT='${new_port}'/" "$INFO_FILE"
  sed -i "s|^VLESS_LINK='.*'$|VLESS_LINK='${vless_link}'|" "$INFO_FILE"

  echo
  echo "端口已从 $old_port 更换为 $new_port。"
  show_link
}

restore_backup() {
  local backup_file="${1:-}"
  if [[ -n "$backup_file" && -f "$backup_file" ]]; then
    cp -a "$backup_file" "$CONFIG_FILE"
    systemctl restart sing-box 2>/dev/null || true
    echo "已恢复安装前的配置。"
  fi
}

uninstall_singbox() {
  echo
  if ! confirm "确定卸载 sing-box 服务和全部配置？"; then
    echo "已取消。"
    return
  fi

  clean_old_setup

  if confirm "是否同时删除 sing-box 核心程序？"; then
    local sb_bin
    sb_bin="$(command -v sing-box || true)"
    if [[ -n "$sb_bin" ]]; then
      rm -f "$sb_bin"
      echo "sing-box 核心程序已删除。"
    fi
  fi

  echo "卸载完成；当前管理脚本已保留。"
}

show_menu() {
  clear 2>/dev/null || true
  echo "=============================="
  echo "       sing-box 管理脚本"
  echo "=============================="
  echo "1. 安装 / 重建节点"
  echo "2. 查看分享节点链接"
  echo "3. 卸载 sing-box"
  echo "4. 更换端口并更新链接"
  echo "0. 退出"
  echo "=============================="
}

main() {
  require_root

  case "${1:-}" in
    install)
      install_node "${2:-}"
      return
      ;;
    share)
      show_link
      return
      ;;
    uninstall)
      uninstall_singbox
      return
      ;;
    port)
      change_port
      return
      ;;
  esac

  show_menu
  local choice
  read -r -p "请选择: " choice
  case "$choice" in
    1) install_node ;;
    2) show_link ;;
    3) uninstall_singbox ;;
    4) change_port ;;
    0) exit 0 ;;
    *) die "无效选项。" ;;
  esac
}

main "$@"
