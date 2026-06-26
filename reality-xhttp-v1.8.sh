#!/usr/bin/env bash
# VLESS + XHTTP + REALITY 独立安装脚本，适用于 Debian/Ubuntu。
# 这是 Xray 直连监听脚本。不会停止 Nginx、云盘/File Browser 或反代服务。
# 如果 TCP/443 已被占用，会自动选择可用的 *443 备用端口。
set -Eeuo pipefail

SCRIPT_VERSION="v1.8"
XRAY_ROOT="/opt/reality-xhttp"
XRAY_BIN="$XRAY_ROOT/xray"
XRAY_DIR="/etc/reality-xhttp"
XRAY_CONFIG="$XRAY_DIR/config.json"
XRAY_INFO="$XRAY_DIR/node-info.env"
XRAY_SERVICE="/etc/systemd/system/reality-xhttp.service"
SERVICE_NAME="reality-xhttp"
DEFAULT_PORT=443

die() { echo "错误：$*" >&2; exit 1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行。"; command -v systemctl >/dev/null || die "当前系统需要支持 systemd。"; }
confirm_yes() { local answer; read -r -p "$1 [Y/n]: " answer; [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]; }
validate_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
port_is_listening() { ss -H -lnt "sport = :$1" 2>/dev/null | grep -q .; }

install_deps() {
  local missing=() cmd
  for cmd in curl unzip openssl qrencode ss; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  (( ${#missing[@]} == 0 )) && return
  command -v apt-get >/dev/null 2>&1 || die "仅支持 Debian/Ubuntu（apt-get）。"
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl unzip openssl qrencode ca-certificates iproute2 tzdata
}

public_ipv4() { curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true; }

configure_china_time() {
  echo
  echo "正在设置中国时区并开启自动对时..."
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-timezone Asia/Shanghai 2>/dev/null || true
    timedatectl set-ntp true 2>/dev/null || true
  fi
  systemctl enable --now systemd-timesyncd 2>/dev/null || true
  systemctl enable --now chronyd 2>/dev/null || true
  systemctl enable --now chrony 2>/dev/null || true

  local timezone synchronized
  timezone="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  synchronized="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  echo "当前时区：${timezone:-未知}；自动对时：${synchronized:-未知}"
}

install_xray() {
  local machine asset latest tmp zip binary
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64) asset="Xray-linux-64.zip" ;;
    aarch64|arm64) asset="Xray-linux-arm64-v8a.zip" ;;
    *) die "不支持的 CPU 架构：$machine" ;;
  esac
  latest="$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
  [[ -n "$latest" ]] || die "无法获取 Xray 最新版本。"
  tmp="$(mktemp -d)"; zip="$tmp/xray.zip"
  curl -fL "https://github.com/XTLS/Xray-core/releases/download/${latest}/${asset}" -o "$zip"
  unzip -q "$zip" -d "$tmp"
  binary="$tmp/xray"
  [[ -x "$binary" ]] || die "Xray 安装包不完整。"
  install -d -m 755 "$XRAY_ROOT"
  install -m 755 "$binary" "$XRAY_BIN"
  rm -rf "$tmp"
  echo "已安装 Xray：$latest"
}

choose_listen_port() {
  local candidate
  if ! port_is_listening "$DEFAULT_PORT"; then
    printf '%s' "$DEFAULT_PORT"
    return
  fi
  echo "TCP/443 已被占用，将保留现有云盘/反代服务并自动选择备用端口。" >&2
  for candidate in 1443 2443 3443 4443 5443 6443 7443 8443 9443 10443 11443 12443; do
    if ! port_is_listening "$candidate"; then
      printf '%s' "$candidate"
      return
    fi
  done
  die "TCP/443 和常见 *443 备用端口均已被占用。"
}

generate_reality_keys() {
  local output
  output="$("$XRAY_BIN" x25519 2>&1)" || die "无法生成 REALITY 密钥：$output"
  PRIVATE_KEY="$(printf '%s\n' "$output" | awk -F': *' 'tolower($1) ~ /^private[[:space:]]*key$/ { gsub(/\r/, "", $2); print $2; exit }')"
  PUBLIC_KEY="$(printf '%s\n' "$output" | awk -F': *' 'tolower($1) ~ /^(public[[:space:]]*key|password \(publickey\))$/ { gsub(/\r/, "", $2); print $2; exit }')"
  [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || { printf '%s\n' "$output" >&2; die "无法解析 REALITY 密钥输出。"; }
}

write_config() {
  local uuid="$1" port="$2" server_name="$3" destination="$4" private_key="$5" short_id="$6" path="$7"
  mkdir -p "$XRAY_DIR"
  cat >"$XRAY_CONFIG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
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
  }],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
EOF
  chmod 600 "$XRAY_CONFIG"
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
Description=VLESS XHTTP REALITY 节点
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
  chmod 644 "$XRAY_SERVICE"
}

start_service() {
  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
  systemctl is-active --quiet "$SERVICE_NAME" || { journalctl -u "$SERVICE_NAME" -n 50 --no-pager >&2 || true; die "Xray 未能启动。"; }
}

make_link() {
  local uuid="$1" host="$2" port="$3" server_name="$4" public_key="$5" short_id="$6" path="$7" name="$8"
  printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=xhttp&path=%s&mode=auto#%s' \
    "$uuid" "$host" "$port" "$server_name" "$public_key" "$short_id" "$path" "$name"
}

write_info() {
  local name="$1" host="$2" port="$3" uuid="$4" server_name="$5" destination="$6" private_key="$7" public_key="$8" short_id="$9" path="${10}" link="${11}"
  cat >"$XRAY_INFO" <<EOF
NODE_NAME='$name'
SERVER_ADDRESS='$host'
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

install_node() {
  install_deps
  configure_china_time
  install_xray
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true

  local port input host name uuid destination default_sni server_name short_id path link public_ip
  port="$(choose_listen_port)"
  read -r -p "监听 TCP 端口 [$port]: " input
  port="${input:-$port}"
  validate_port "$port" || die "端口必须在 1-65535 之间。"
  port_is_listening "$port" && die "TCP/$port 已被占用。"

  read -r -p "REALITY 伪装目标（域名:端口）[www.yahoo.co.jp:443]: " destination
  destination="${destination:-www.yahoo.co.jp:443}"
  [[ "$destination" =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]] || die "伪装目标必须是 域名:端口。"
  default_sni="${destination%:*}"
  read -r -p "REALITY SNI [$default_sni]: " server_name
  server_name="${server_name:-$default_sni}"
  [[ "$server_name" =~ ^[A-Za-z0-9.-]+$ ]] || die "SNI 格式不正确。"

  public_ip="$(public_ipv4)"
  read -r -p "节点连接地址（IP 或已解析域名）[${public_ip:-请手动输入}]: " host
  host="${host:-$public_ip}"
  [[ -n "$host" && "$host" != *[[:space:]]* ]] || die "节点地址不能为空或包含空格。"

  read -r -p "节点名称 [Reality-XHTTP]: " name
  name="${name:-Reality-XHTTP}"; name="${name// /-}"
  uuid="$(cat /proc/sys/kernel/random/uuid)"
  short_id="$(openssl rand -hex 8)"
  path="/$(openssl rand -hex 8)"
  generate_reality_keys
  write_config "$uuid" "$port" "$server_name" "$destination" "$PRIVATE_KEY" "$short_id" "$path"
  test_config
  write_service
  start_service
  link="$(make_link "$uuid" "$host" "$port" "$server_name" "$PUBLIC_KEY" "$short_id" "$path" "$name")"
  write_info "$name" "$host" "$port" "$uuid" "$server_name" "$destination" "$PRIVATE_KEY" "$PUBLIC_KEY" "$short_id" "$path" "$link"
  echo
  echo "REALITY + XHTTP 节点已创建："
  echo "$link"
  echo
  qrencode -t ANSIUTF8 "$link"
}

info_value() { sed -n "s/^$1='\\(.*\\)'$/\\1/p" "$XRAY_INFO"; }
require_node_files() { [[ -f "$XRAY_INFO" && -f "$XRAY_CONFIG" ]] || die "未找到节点，请先安装。"; }
show_link() { require_node_files; info_value LINK; }
print_link_qr() { echo "$1"; echo; qrencode -t ANSIUTF8 "$1"; }
show_status() { [[ -x "$XRAY_BIN" ]] && "$XRAY_BIN" version | head -n1 || true; systemctl status "$SERVICE_NAME" --no-pager; }
show_logs() { journalctl -u "$SERVICE_NAME" -n 100 --no-pager; }
restart_node() { systemctl restart "$SERVICE_NAME"; systemctl is-active --quiet "$SERVICE_NAME" || die "重启失败。"; echo "已重启。"; }

change_port() {
  require_node_files
  local old_port new_port name host uuid server_name destination private_key public_key short_id path link
  old_port="$(info_value PORT)"; name="$(info_value NODE_NAME)"; host="$(info_value SERVER_ADDRESS)"; uuid="$(info_value UUID)"
  server_name="$(info_value SNI)"; destination="$(info_value DESTINATION)"; private_key="$(info_value PRIVATE_KEY)"
  public_key="$(info_value PUBLIC_KEY)"; short_id="$(info_value SHORT_ID)"; path="$(info_value PATH)"
  read -r -p "新的监听 TCP 端口 [$old_port]: " new_port
  new_port="${new_port:-$old_port}"
  validate_port "$new_port" || die "端口必须在 1-65535 之间。"
  [[ "$new_port" == "$old_port" ]] && { echo "端口未改变。"; return; }
  port_is_listening "$new_port" && die "TCP/$new_port 已被占用。"
  write_config "$uuid" "$new_port" "$server_name" "$destination" "$private_key" "$short_id" "$path"
  test_config
  systemctl restart "$SERVICE_NAME"
  systemctl is-active --quiet "$SERVICE_NAME" || die "修改端口后服务启动失败。"
  link="$(make_link "$uuid" "$host" "$new_port" "$server_name" "$public_key" "$short_id" "$path" "$name")"
  write_info "$name" "$host" "$new_port" "$uuid" "$server_name" "$destination" "$private_key" "$public_key" "$short_id" "$path" "$link"
  print_link_qr "$link"
}

change_link_host() {
  require_node_files
  local host old_host port name uuid server_name public_key short_id path link destination private_key
  old_host="$(info_value SERVER_ADDRESS)"; port="$(info_value PORT)"; name="$(info_value NODE_NAME)"; uuid="$(info_value UUID)"
  server_name="$(info_value SNI)"; public_key="$(info_value PUBLIC_KEY)"; short_id="$(info_value SHORT_ID)"; path="$(info_value PATH)"
  destination="$(info_value DESTINATION)"; private_key="$(info_value PRIVATE_KEY)"
  read -r -p "节点连接地址（IP 或已解析域名）[$old_host]: " host
  host="${host:-$old_host}"
  [[ -n "$host" && "$host" != *[[:space:]]* ]] || die "节点地址不能为空或包含空格。"
  link="$(make_link "$uuid" "$host" "$port" "$server_name" "$public_key" "$short_id" "$path" "$name")"
  write_info "$name" "$host" "$port" "$uuid" "$server_name" "$destination" "$private_key" "$public_key" "$short_id" "$path" "$link"
  print_link_qr "$link"
}

upgrade_xray() { install_xray; restart_node; }

uninstall_node() {
  confirm_yes "是否卸载 REALITY + XHTTP 节点？" || return
  systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$XRAY_SERVICE" "$XRAY_CONFIG" "$XRAY_INFO"
  rmdir "$XRAY_DIR" 2>/dev/null || true
  systemctl daemon-reload
  echo "节点已卸载；Xray 二进制保留在 $XRAY_ROOT。"
}

menu() {
  cat <<EOF
========================================
 REALITY + XHTTP 节点脚本 $SCRIPT_VERSION
========================================
1. 安装 / 重建节点
2. 查看节点链接和二维码
3. 查看状态
4. 查看日志
5. 重启 Xray
6. 更换监听端口
7. 设置节点连接地址
8. 检查 / 更新 Xray-core
9. 卸载节点
0. 退出
EOF
  local choice
  read -r -p "请选择：" choice
  case "$choice" in
    1) install_node ;;
    2) print_link_qr "$(show_link)" ;;
    3) show_status ;;
    4) show_logs ;;
    5) restart_node ;;
    6) change_port ;;
    7) change_link_host ;;
    8) upgrade_xray ;;
    9) uninstall_node ;;
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
  port) change_port ;;
  host) change_link_host ;;
  update) upgrade_xray ;;
  uninstall) uninstall_node ;;
  *) menu ;;
esac
