#!/usr/bin/env bash
# VLESS + XHTTP + REALITY installer for Debian/Ubuntu (v1.7)
# This is a direct Xray listener. Do not place Nginx or another TLS proxy in front of it.
set -Eeuo pipefail

SCRIPT_VERSION="v1.7"
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

public_ipv4() { curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true; }

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
  PRIVATE_KEY="$(printf '%s\n' "$output" | awk -F': *' 'tolower($1) ~ /^private[[:space:]]*key$/ { gsub(/\r/, "", $2); print $2; exit }')"
  PUBLIC_KEY="$(printf '%s\n' "$output" | awk -F': *' 'tolower($1) ~ /^(public[[:space:]]*key|password \(publickey\))$/ { gsub(/\r/, "", $2); print $2; exit }')"
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
  local port uuid server_name destination default_sni short_id path name link server_address
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
  server_address="$(public_ipv4)"
  if [[ -z "$server_address" ]]; then
    read -r -p "无法自动获取公网 IP，请输入节点服务器 IP 或域名：" server_address
    [[ -n "$server_address" ]] || die "节点地址不能为空。"
  fi
  uuid="$(cat /proc/sys/kernel/random/uuid)"
  short_id="$(openssl rand -hex 8)"
  path="/$(openssl rand -hex 8)"
  generate_reality_keys
  write_config "$uuid" "$port" "$server_name" "$destination" "$PRIVATE_KEY" "$short_id" "$path"
  test_config
  write_service
  start_service
  link="vless://${uuid}@${server_address}:${port}?encryption=none&security=reality&sni=${server_name}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${short_id}&type=xhttp&path=${path}&mode=auto#${name}"
  cat >"$XRAY_INFO" <<EOF
NODE_NAME='$name'
SERVER_ADDRESS='$server_address'
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
  echo "节点已创建："
  echo "$link"
  echo
  qrencode -t ANSIUTF8 "$link"
}

show_link() { [[ -f "$XRAY_INFO" ]] || die "未找到节点信息。"; sed -n "s/^LINK='\(.*\)'$/\1/p" "$XRAY_INFO"; }
print_link_qr() { echo "$1"; echo; qrencode -t ANSIUTF8 "$1"; }
show_status() {
  [[ -x "$XRAY_BIN" ]] && "$XRAY_BIN" version | head -n1 || true
  [[ -f "$XRAY_CONFIG" ]] && test_config && echo "配置校验：通过" || true
  [[ -f "$XRAY_INFO" ]] && echo "监听端口：$(info_value PORT)"
  systemctl status reality-xhttp --no-pager
}
show_logs() { journalctl -u reality-xhttp -n 80 --no-pager; }
restart_node() { systemctl restart reality-xhttp; systemctl is-active --quiet reality-xhttp || die "重启失败。"; echo "已重启。"; }
info_value() { sed -n "s/^$1='\\(.*\\)'$/\\1/p" "$XRAY_INFO"; }

write_node_info() {
  local name="$1" server_address="$2" port="$3" uuid="$4" server_name="$5" destination="$6" private_key="$7" public_key="$8" short_id="$9" path="${10}" link="${11}"
  cat >"$XRAY_INFO" <<EOF
NODE_NAME='$name'
SERVER_ADDRESS='$server_address'
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
}

require_node_files() { [[ -f "$XRAY_INFO" && -f "$XRAY_CONFIG" ]] || die "未找到节点信息，请先安装或重建节点。"; }

change_port() {
  require_node_files
  local uuid old_port new_port server_name destination private_key public_key short_id path name server_address link
  uuid="$(info_value UUID)"; old_port="$(info_value PORT)"; server_name="$(info_value SNI)"; destination="$(info_value DESTINATION)"
  private_key="$(info_value PRIVATE_KEY)"; public_key="$(info_value PUBLIC_KEY)"; short_id="$(info_value SHORT_ID)"; path="$(info_value PATH)"
  name="$(info_value NODE_NAME)"; server_address="$(info_value SERVER_ADDRESS)"
  [[ -n "$uuid" && -n "$old_port" && -n "$private_key" && -n "$public_key" && -n "$short_id" && -n "$path" ]] || die "节点信息不完整，请重建节点。"
  read -r -p "新监听端口 [$old_port]: " new_port
  new_port="${new_port:-$old_port}"; validate_port "$new_port" || die "端口必须在 1–65535 之间。"
  [[ "$new_port" == "$old_port" ]] && { echo "端口未改变。"; return; }
  if port_is_listening "$new_port"; then die "TCP/$new_port 已被占用。"; fi
  write_config "$uuid" "$new_port" "$server_name" "$destination" "$private_key" "$short_id" "$path"
  test_config
  systemctl restart reality-xhttp
  systemctl is-active --quiet reality-xhttp || die "新端口启动失败，请查看日志。"
  link="vless://${uuid}@${server_address}:${new_port}?encryption=none&security=reality&sni=${server_name}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=xhttp&path=${path}&mode=auto#${name}"
  write_node_info "$name" "$server_address" "$new_port" "$uuid" "$server_name" "$destination" "$private_key" "$public_key" "$short_id" "$path" "$link"
  echo "端口已更新：$old_port → $new_port"; print_link_qr "$link"
}

change_link_host() {
  require_node_files
  local host uuid port server_name destination private_key public_key short_id path name link
  host="$(info_value SERVER_ADDRESS)"; uuid="$(info_value UUID)"; port="$(info_value PORT)"; server_name="$(info_value SNI)"; destination="$(info_value DESTINATION)"
  private_key="$(info_value PRIVATE_KEY)"; public_key="$(info_value PUBLIC_KEY)"; short_id="$(info_value SHORT_ID)"; path="$(info_value PATH)"; name="$(info_value NODE_NAME)"
  read -r -p "节点连接地址（IP 或域名）[$host]: " host
  host="${host:-$(info_value SERVER_ADDRESS)}"; [[ -n "$host" && "$host" != *[[:space:]]* ]] || die "节点地址格式不正确。"
  link="vless://${uuid}@${host}:${port}?encryption=none&security=reality&sni=${server_name}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=xhttp&path=${path}&mode=auto#${name}"
  write_node_info "$name" "$host" "$port" "$uuid" "$server_name" "$destination" "$private_key" "$public_key" "$short_id" "$path" "$link"
  echo "连接地址已更新：$host"; print_link_qr "$link"
}

upgrade_xray() {
  require_node_files
  local before after
  before="$("$XRAY_BIN" version 2>/dev/null | head -n1 || true)"
  install_xray
  test_config
  systemctl restart reality-xhttp
  systemctl is-active --quiet reality-xhttp || die "升级后服务启动失败，请查看日志。"
  after="$("$XRAY_BIN" version 2>/dev/null | head -n1 || true)"
  echo "Xray-core：${before:-未知} → ${after:-未知}"
}

change_sni() {
  [[ -f "$XRAY_INFO" && -f "$XRAY_CONFIG" ]] || die "未找到节点信息。"
  local uuid port server_name destination default_sni private_key public_key short_id path name link server_address
  uuid="$(info_value UUID)"; port="$(info_value PORT)"; short_id="$(info_value SHORT_ID)"; path="$(info_value PATH)"
  name="$(info_value NODE_NAME)"; public_key="$(info_value PUBLIC_KEY)"; destination="$(info_value DESTINATION)"
  server_address="$(info_value SERVER_ADDRESS)"
  private_key="$(info_value PRIVATE_KEY)"
  [[ -n "$destination" ]] || destination="www.microsoft.com:443"
  [[ -n "$private_key" ]] || private_key="$(sed -n 's/.*"privateKey": *"\\([^"]*\\)".*/\\1/p' "$XRAY_CONFIG")"
  [[ -n "$server_address" ]] || server_address="$(public_ipv4)"
  if [[ -z "$server_address" ]]; then
    read -r -p "无法自动获取公网 IP，请输入节点服务器 IP 或域名：" server_address
    [[ -n "$server_address" ]] || die "节点地址不能为空。"
  fi
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
  link="vless://${uuid}@${server_address}:${port}?encryption=none&security=reality&sni=${server_name}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=xhttp&path=${path}&mode=auto#${name}"
  cat >"$XRAY_INFO" <<EOF
NODE_NAME='$name'
SERVER_ADDRESS='$server_address'
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
  print_link_qr "$link"
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
  echo "7. 更换监听端口并更新链接"
  echo "8. 设置节点连接地址（IP / 域名）"
  echo "9. 检查 / 更新 Xray-core"
  echo "10. 卸载节点"
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
    7) change_port ;;
    8) change_link_host ;;
    9) upgrade_xray ;;
    10) uninstall_node ;;
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
  port) change_port ;;
  host) change_link_host ;;
  update) upgrade_xray ;;
  uninstall) uninstall_node ;;
  *) menu ;;
esac
