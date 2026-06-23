#!/usr/bin/env bash
# VLESS + XHTTP + REALITY installer for Debian/Ubuntu (v1.3)
# This is a direct Xray listener. Do not place Nginx or another TLS proxy in front of it.
set -Eeuo pipefail

SCRIPT_VERSION="v1.3"
XRAY_ROOT="/opt/reality-xhttp"
XRAY_BIN="$XRAY_ROOT/xray"
XRAY_DIR="/etc/reality-xhttp"
XRAY_CONFIG="$XRAY_DIR/config.json"
XRAY_INFO="$XRAY_DIR/node-info.env"
XRAY_SERVICE="/etc/systemd/system/reality-xhttp.service"
DEFAULT_PORT=443

die() { echo "错误：$*" >&2; exit 1; }
require_root() { [[ $EUID -eq 0 ]] || die "请使用 root 运行。"; }
confirm_yes() { local answer; read -r -p "$1 [Y/n]: " answer; [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]; }

install_deps() {
  local missing=() command_name
  for command_name in curl unzip openssl qrencode ss; do
    command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
  done
  (( ${#missing[@]} == 0 )) && return
  command -v apt-get >/dev/null 2>&1 || die "仅支持 Debian/Ubuntu；请先安装：${missing[*]}"
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl unzip openssl qrencode ca-certificates iproute2
}

install_xray() {
  local machine asset latest temporary_directory archive binary
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64) asset="Xray-linux-64.zip" ;;
    aarch64|arm64) asset="Xray-linux-arm64-v8a.zip" ;;
    *) die "不支持的 CPU 架构：$machine" ;;
  esac
  latest="$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
  [[ -n "$latest" ]] || die "无法获取 Xray 最新版本。"
  temporary_directory="$(mktemp -d)"
  archive="$temporary_directory/xray.zip"
  trap 'rm -rf "$temporary_directory"' RETURN
  curl -fL "https://github.com/XTLS/Xray-core/releases/download/${latest}/${asset}" -o "$archive"
  unzip -q "$archive" -d "$temporary_directory"
  binary="$temporary_directory/xray"
  [[ -x "$binary" ]] || die "Xray 安装包不完整。"
  install -d -m 755 "$XRAY_ROOT"
  install -m 755 "$binary" "$XRAY_BIN"
  rm -rf "$temporary_directory"
  trap - RETURN
  echo "已安装 Xray：$latest"
}

port_is_listening() { ss -H -lnt "sport = :$1" 2>/dev/null | grep -q .; }

validate_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

choose_listen_port() {
  local candidate
  for candidate in 443 8443 1443 2443 3443 4443 5443 6443 7443 9443; do
    if ! port_is_listening "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  die "443 及常用的 *443 端口均已被占用；请手动释放端口后重试。"
}

generate_reality_keys() {
  local output
  output="$("$XRAY_BIN" x25519 2>&1)" || die "Xray 无法执行 x25519 密钥生成：$output"
  PRIVATE_KEY="$(printf '%s\n' "$output" | awk -F': *' 'tolower($1) == "private key" { gsub(/\r/, "", $2); print $2; exit }')"
  PUBLIC_KEY="$(printf '%s\n' "$output" | awk -F': *' 'tolower($1) == "public key" { gsub(/\r/, "", $2); print $2; exit }')"
  [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || { printf '%s\n' "$output" >&2; die "无法解析 REALITY 密钥；Xray 已尝试更新，请检查下载是否完整。"; }
}

test_config() {
  local output
  if ! output="$("$XRAY_BIN" run -test -format json -c "$XRAY_CONFIG" 2>&1)"; then
    printf '%s\n' "$output" >&2
    die "Xray 配置校验失败。"
  fi
}

write_service() {
  cat >"$XRAY_SERVICE" <<EOF
[Unit]
Description=VLESS XHTTP REALITY Node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$XRAY_BIN run -c $XRAY_CONFIG
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

write_config() {
  local uuid="$1" port="$2" server_name="$3" destination="$4" private_key="$5" short_id="$6" path="$7"
  mkdir -p "$XRAY_DIR"
  cat >"$XRAY_CONFIG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$uuid", "email": "reality-xhttp" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$destination",
          "xver": 0,
          "serverNames": ["$server_name"],
          "privateKey": "$private_key",
          "shortIds": ["$short_id"]
        },
        "xhttpSettings": { "path": "$path", "mode": "auto" }
      }
    }
  ],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
EOF
  chmod 600 "$XRAY_CONFIG"
}

start_service() {
  systemctl daemon-reload
  systemctl enable --now reality-xhttp
  systemctl is-active --quiet reality-xhttp || { journalctl -u reality-xhttp -n 50 --no-pager >&2 || true; die "Xray 未能启动。"; }
}

install_node() {
  install_deps
  install_xray
  local port uuid server_name destination default_sni short_id path name link
  if systemctl is-active --quiet reality-xhttp; then
    systemctl stop reality-xhttp
  fi
  port="$(choose_listen_port)"
  if [[ "$port" == "$DEFAULT_PORT" ]]; then
    echo "TCP/443 空闲，使用 443。"
  else
    echo "TCP/443 已被占用，自动改用 TCP/$port。"
  fi
  read -r -p "REALITY 伪装目标（域名:端口）[www.microsoft.com:443]: " destination
  destination="${destination:-www.microsoft.com:443}"
  [[ "$destination" =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]] || die "伪装目标必须是 域名:端口，例如 example.com:443。"
  default_sni="${destination%:*}"
  read -r -p "REALITY SNI [$default_sni]: " server_name
  server_name="${server_name:-$default_sni}"
  [[ "$server_name" =~ ^[A-Za-z0-9.-]+$ ]] || die "SNI 格式不正确。"
  [[ "$server_name" == "$default_sni" ]] || echo "提示：SNI 应由伪装目标的 TLS 证书支持；通常应保持与伪装目标域名一致。"
  read -r -p "节点名称 [Reality-XHTTP]: " name
  name="${name:-Reality-XHTTP}"
  name="${name// /-}"
  uuid="$(cat /proc/sys/kernel/random/uuid)"
  short_id="$(openssl rand -hex 8)"
  path="/$(openssl rand -hex 8)"
  generate_reality_keys
  write_config "$uuid" "$port" "$server_name" "$destination" "$PRIVATE_KEY" "$short_id" "$path"
  test_config
  write_service
  start_service
  link="vless://${uuid}@YOUR_SERVER_IP:${port}?encryption=none&security=reality&sni=${server_name}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${short_id}&type=xhttp&path=${path}&mode=auto#${name}"
  cat >"$XRAY_INFO" <<EOF
NODE_NAME='$name'
PORT='$port'
UUID='$uuid'
SNI='$server_name'
DESTINATION='$destination'
PRIVATE_KEY='$PRIVATE_KEY'
PUBLIC_KEY='$PUBLIC_KEY'
SHORT_ID='$short_id'
PATH='$path'
LINK='$link'
EOF
  chmod 600 "$XRAY_INFO"
  echo
  echo "节点已创建。请把链接中的 YOUR_SERVER_IP 改为服务器 IP 或域名："
  echo "$link"
  echo
  qrencode -t ANSIUTF8 "$link"
}

show_link() { [[ -f "$XRAY_INFO" ]] || die "未找到节点信息。"; sed -n "s/^LINK='\(.*\)'$/\1/p" "$XRAY_INFO"; }
show_status() { systemctl status reality-xhttp --no-pager; }
show_logs() { journalctl -u reality-xhttp -n 80 --no-pager; }
restart_node() { systemctl restart reality-xhttp; systemctl is-active --quiet reality-xhttp || die "重启失败。"; echo "已重启。"; }
info_value() { sed -n "s/^$1='\\(.*\\)'$/\\1/p" "$XRAY_INFO"; }

change_sni() {
  [[ -f "$XRAY_INFO" && -f "$XRAY_CONFIG" ]] || die "未找到节点信息。"
  local uuid port server_name destination default_sni private_key public_key short_id path name link
  uuid="$(info_value UUID)"; port="$(info_value PORT)"; short_id="$(info_value SHORT_ID)"; path="$(info_value PATH)"
  name="$(info_value NODE_NAME)"; public_key="$(info_value PUBLIC_KEY)"; destination="$(info_value DESTINATION)"
  private_key="$(info_value PRIVATE_KEY)"
  [[ -n "$destination" ]] || destination="www.microsoft.com:443"
  [[ -n "$private_key" ]] || private_key="$(sed -n 's/.*"privateKey": *"\\([^"]*\\)".*/\\1/p' "$XRAY_CONFIG")"
  [[ -n "$uuid" && -n "$port" && -n "$short_id" && -n "$path" && -n "$public_key" && -n "$private_key" ]] || die "节点信息不完整，请使用“安装 / 重建节点”重新生成。"
  read -r -p "REALITY 伪装目标（域名:端口）[$destination]: " server_name
  destination="${server_name:-$destination}"
  [[ "$destination" =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]] || die "伪装目标必须是 域名:端口，例如 example.com:443。"
  default_sni="${destination%:*}"
  read -r -p "REALITY SNI [$default_sni]: " server_name
  server_name="${server_name:-$default_sni}"
  [[ "$server_name" =~ ^[A-Za-z0-9.-]+$ ]] || die "SNI 格式不正确。"
  write_config "$uuid" "$port" "$server_name" "$destination" "$private_key" "$short_id" "$path"
  test_config
  systemctl restart reality-xhttp
  systemctl is-active --quiet reality-xhttp || die "应用新 SNI 后启动失败。"
  link="vless://${uuid}@YOUR_SERVER_IP:${port}?encryption=none&security=reality&sni=${server_name}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=xhttp&path=${path}&mode=auto#${name}"
  cat >"$XRAY_INFO" <<EOF
NODE_NAME='$name'
PORT='$port'
UUID='$uuid'
SNI='$server_name'
DESTINATION='$destination'
PRIVATE_KEY='$private_key'
PUBLIC_KEY='$public_key'
SHORT_ID='$short_id'
PATH='$path'
LINK='$link'
EOF
  chmod 600 "$XRAY_INFO"
  echo "SNI 已更新：$server_name"
  echo "$link"
}

uninstall_node() {
  confirm_yes "确定卸载本脚本创建的 REALITY + XHTTP 节点？" || return
  systemctl disable --now reality-xhttp 2>/dev/null || true
  rm -f "$XRAY_SERVICE" "$XRAY_CONFIG" "$XRAY_INFO"
  systemctl daemon-reload
  echo "已卸载节点配置；Xray 二进制保留在 $XRAY_ROOT。"
}

menu() {
  echo "========================================"
  echo " REALITY + XHTTP 节点脚本 $SCRIPT_VERSION"
  echo "========================================"
  echo "1. 安装 / 重建节点"
  echo "2. 查看节点链接和二维码"
  echo "3. 查看状态"
  echo "4. 查看日志"
  echo "5. 重启 Xray"
  echo "6. 更换 REALITY SNI / 伪装目标"
  echo "7. 卸载节点"
  echo "0. 退出"
  local choice
  read -r -p "请选择：" choice
  case "$choice" in
    1) install_node ;;
    2) show_link | tee /dev/tty | qrencode -t ANSIUTF8 ;;
    3) show_status ;;
    4) show_logs ;;
    5) restart_node ;;
    6) change_sni ;;
    7) uninstall_node ;;
    0) exit 0 ;;
    *) die "无效选项。" ;;
  esac
}

require_root
case "${1:-}" in
  install) install_node ;;
  link) show_link ;;
  status) show_status ;;
  logs) show_logs ;;
  restart) restart_node ;;
  sni) change_sni ;;
  uninstall) uninstall_node ;;
  *) menu ;;
esac
