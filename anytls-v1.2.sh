#!/usr/bin/env bash
# AnyTLS 独立安装脚本，适用于 Debian/Ubuntu。
# 不会停止 Nginx、云盘/File Browser 或反代服务。
# 如果 TCP/443 已被占用，会自动选择可用的 *443 备用端口。
set -Eeuo pipefail

SCRIPT_VERSION="v1.4"
INSTALL_DIR="/opt/anytls"
BIN="$INSTALL_DIR/anytls-server"
CONFIG_DIR="/etc/anytls"
INFO_FILE="$CONFIG_DIR/node-info.env"
SERVICE_FILE="/etc/systemd/system/anytls.service"
SERVICE_NAME="anytls"
DEFAULT_PORT=443
DEFAULT_DASHBOARD_URL="${DEFAULT_DASHBOARD_URL:-}"
DASHBOARD_AGENT_CONF="${DASHBOARD_AGENT_CONF:-/etc/ejectors-vps-agent.conf}"
SUBSCRIPTION_INFO_FILE="$CONFIG_DIR/subscription.env"

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

configure_bbr() {
  local current available bbr_file="/etc/sysctl.d/99-anytls-bbr.conf"
  current="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")"

  echo
  echo "当前 TCP 拥塞控制算法：$current"
  if ! confirm_yes "是否安装 / 启用 BBR + FQ？"; then
    echo "已跳过 BBR 设置。"
    return
  fi

  modprobe tcp_bbr 2>/dev/null || true
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if ! grep -qw bbr <<<"$available"; then
    echo "警告：当前内核不支持 BBR，已跳过，不影响 AnyTLS 安装。"
    return
  fi

  cat >"$bbr_file" <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

  if sysctl -w net.core.default_qdisc=fq >/dev/null &&
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null; then
    echo "BBR + FQ 已启用：拥塞控制=$(sysctl -n net.ipv4.tcp_congestion_control)，队列=$(sysctl -n net.core.default_qdisc)"
  else
    rm -f "$bbr_file"
    echo "警告：BBR + FQ 设置失败，已跳过，不影响 AnyTLS 安装。"
  fi
}

urlencode() {
  local string="$1" encoded="" character i
  for ((i = 0; i < ${#string}; i++)); do
    character="${string:i:1}"
    case "$character" in
      [a-zA-Z0-9.~_-]) encoded+="$character" ;;
      *) printf -v character '%%%02X' "'${character}"; encoded+="$character" ;;
    esac
  done
  printf '%s' "$encoded"
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

install_anytls() {
  local machine asset latest tmp archive binary
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64) asset="anytls_*_linux_amd64.zip" ;;
    aarch64|arm64) asset="anytls_*_linux_arm64.zip" ;;
    *) die "不支持的 CPU 架构：$machine" ;;
  esac
  latest="$(curl -fsSL https://api.github.com/repos/anytls/anytls-go/releases/latest | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
  [[ -n "$latest" ]] || die "无法获取 anytls-go 最新版本。"
  asset="${asset/\*/${latest#v}}"
  tmp="$(mktemp -d)"
  archive="$tmp/anytls.zip"
  curl -fL "https://github.com/anytls/anytls-go/releases/download/${latest}/${asset}" -o "$archive"
  unzip -q "$archive" -d "$tmp"
  binary="$(find "$tmp" -type f -name anytls-server -perm -u+x -print -quit)"
  [[ -n "$binary" ]] || die "安装包中未找到 anytls-server。"
  install -d -m 755 "$INSTALL_DIR"
  install -m 755 "$binary" "$BIN"
  rm -rf "$tmp"
  echo "已安装 AnyTLS：$latest"
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

write_service() {
  local port="$1" password="$2"
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=AnyTLS 服务端
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=LOG_LEVEL=warn
ExecStart=$BIN -l 0.0.0.0:$port -p $password
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$SERVICE_FILE"
}

make_link() {
  local password="$1" host="$2" port="$3" name="$4" sni="$5"
  printf 'anytls://%s@%s:%s/?sni=%s&insecure=1#%s' "$(urlencode "$password")" "$host" "$port" "$(urlencode "$sni")" "$(urlencode "$name")"
}

write_info() {
  local name="$1" host="$2" port="$3" password="$4" sni="$5" link="$6"
  install -d -m 700 "$CONFIG_DIR"
  cat >"$INFO_FILE" <<EOF
NODE_NAME='$name'
SERVER_ADDRESS='$host'
PORT='$port'
PASSWORD='$password'
SNI='$sni'
LINK='$link'
EOF
  chmod 600 "$INFO_FILE"
}

info_value() { sed -n "s/^$1='\\(.*\\)'$/\\1/p" "$INFO_FILE"; }
subscription_info_value() { if [[ -f "$SUBSCRIPTION_INFO_FILE" ]]; then sed -n "s/^$1='\\(.*\\)'$/\\1/p" "$SUBSCRIPTION_INFO_FILE"; fi; return 0; }
agent_info_value() { if [[ -f "$DASHBOARD_AGENT_CONF" ]]; then sed -n "s/^$1='\\(.*\\)'$/\\1/p" "$DASHBOARD_AGENT_CONF"; fi; return 0; }
require_node_files() { [[ -x "$BIN" && -f "$INFO_FILE" && -f "$SERVICE_FILE" ]] || die "未找到 AnyTLS 节点，请先安装。"; }

load_subscription_identity() {
  SUB_DASHBOARD_URL="$(agent_info_value DASHBOARD_URL)"
  SUB_INGEST_TOKEN="$(agent_info_value INGEST_TOKEN)"
  SUB_NODE_ID="$(agent_info_value NODE_ID)"
  [[ -n "$SUB_DASHBOARD_URL" ]] || SUB_DASHBOARD_URL="$(subscription_info_value DASHBOARD_URL)"
  [[ -n "$SUB_INGEST_TOKEN" ]] || SUB_INGEST_TOKEN="$(subscription_info_value INGEST_TOKEN)"
  [[ -n "$SUB_NODE_ID" ]] || SUB_NODE_ID="$(subscription_info_value NODE_ID)"
  SUB_DASHBOARD_URL="${SUB_DASHBOARD_URL:-$DEFAULT_DASHBOARD_URL}"
  if [[ -z "$SUB_DASHBOARD_URL" ]]; then
    read -rp "聚合订阅服务地址（HTTPS）: " SUB_DASHBOARD_URL
  fi
  SUB_DASHBOARD_URL="${SUB_DASHBOARD_URL%/}"
  if [[ -z "$SUB_NODE_ID" && -r /etc/machine-id ]]; then
    SUB_NODE_ID="anytls-$(tr -cd 'a-zA-Z0-9' </etc/machine-id | head -c 20)"
  fi
  [[ "$SUB_DASHBOARD_URL" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || die "订阅服务地址必须是 HTTPS 地址。"
  [[ "$SUB_NODE_ID" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$ ]] || die "订阅节点 ID 格式错误。"
  if [[ -z "$SUB_INGEST_TOKEN" ]]; then
    read -rsp "VPS 状态面板上报密钥（输入不显示）: " SUB_INGEST_TOKEN
    echo
  fi
  [[ "$SUB_INGEST_TOKEN" =~ ^[A-Za-z0-9._~-]{16,512}$ ]] || die "上报密钥格式错误。"
}

sync_subscription_node() {
  require_node_files
  local quiet="${1:-false}" name host port password sni payload response subscription_url
  name="$(info_value NODE_NAME)"
  host="$(info_value SERVER_ADDRESS)"
  port="$(info_value PORT)"
  password="$(info_value PASSWORD)"
  sni="$(info_value SNI)"
  load_subscription_identity
  payload="$(printf '{"node_id":"%s","name":"%s","server":"%s","port":%s,"password":"%s","sni":"%s","insecure":true}' \
    "$(json_escape "$SUB_NODE_ID")" "$(json_escape "$name")" "$(json_escape "$host")" "$port" \
    "$(json_escape "$password")" "$(json_escape "$sni")")"
  if ! response="$(curl -fsS --max-time 20 -X POST "${SUB_DASHBOARD_URL}/api/v1/anytls" \
    -H "Authorization: Bearer ${SUB_INGEST_TOKEN}" -H "Content-Type: application/json" --data "$payload")"; then
    echo "警告：AnyTLS 节点未能登记到聚合订阅服务。" >&2
    return 1
  fi
  subscription_url="$(sed -n 's/.*"subscription_url":"\([^"]*\)".*/\1/p' <<<"$response")"
  [[ "$subscription_url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/sub/anytls/[a-f0-9]{64}$ ]] ||
    die "订阅服务未返回有效链接。"
  install -d -m 700 "$CONFIG_DIR"
  cat >"$SUBSCRIPTION_INFO_FILE" <<EOF
DASHBOARD_URL='$SUB_DASHBOARD_URL'
INGEST_TOKEN='$SUB_INGEST_TOKEN'
NODE_ID='$SUB_NODE_ID'
SUBSCRIPTION_URL='$subscription_url'
EOF
  chmod 600 "$SUBSCRIPTION_INFO_FILE"
  if [[ "$quiet" != "true" ]]; then
    echo
    echo "AnyTLS 聚合订阅（Mihomo / Clash Meta）："
    echo "$subscription_url"
    echo "当前 VPS 已加入；在其他 VPS 运行同一脚本加入后，仍使用这条链接。"
  fi
}

refresh_subscription_if_enabled() {
  [[ -f "$SUBSCRIPTION_INFO_FILE" ]] || return 0
  sync_subscription_node true || true
}

remove_subscription_node() {
  local quiet="${1:-false}" dashboard_url ingest_token node_id payload
  [[ -f "$SUBSCRIPTION_INFO_FILE" ]] || { [[ "$quiet" == "true" ]] || echo "当前 VPS 未加入聚合订阅。"; return 0; }
  dashboard_url="$(subscription_info_value DASHBOARD_URL)"
  ingest_token="$(subscription_info_value INGEST_TOKEN)"
  node_id="$(subscription_info_value NODE_ID)"
  payload="$(printf '{"node_id":"%s"}' "$(json_escape "$node_id")")"
  if ! curl -fsS --max-time 20 -X POST "${dashboard_url}/api/v1/anytls/delete" \
    -H "Authorization: Bearer ${ingest_token}" -H "Content-Type: application/json" --data "$payload" >/dev/null; then
    echo "警告：无法从聚合订阅移除此 VPS；本地记录暂未删除。" >&2
    return 1
  fi
  rm -f "$SUBSCRIPTION_INFO_FILE"
  [[ "$quiet" == "true" ]] || echo "当前 VPS 已退出 AnyTLS 聚合订阅。"
}

generate_subscription() { sync_subscription_node "${1:-false}"; }

start_service() {
  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
  systemctl is-active --quiet "$SERVICE_NAME" || { journalctl -u "$SERVICE_NAME" -n 50 --no-pager >&2 || true; die "AnyTLS 未能启动。"; }
}

install_node() {
  install_deps
  configure_bbr
  configure_china_time
  install_anytls
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true

  local port input host name password link public_ip sni default_sni
  port="$(choose_listen_port)"
  read -r -p "监听 TCP 端口 [$port]: " input
  port="${input:-$port}"
  validate_port "$port" || die "端口必须在 1-65535 之间。"
  port_is_listening "$port" && die "TCP/$port 已被占用。"

  public_ip="$(public_ipv4)"
  read -r -p "节点连接地址（IP 或已解析域名）[${public_ip:-请手动输入}]: " host
  host="${host:-$public_ip}"
  [[ -n "$host" && "$host" != *[[:space:]]* ]] || die "节点地址不能为空或包含空格。"
  if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    default_sni="www.yahoo.co.jp"
  else
    default_sni="$host"
  fi
  read -r -p "客户端 TLS SNI [$default_sni]: " sni
  sni="${sni:-$default_sni}"
  [[ "$sni" =~ ^[A-Za-z0-9.-]+$ ]] || die "SNI 格式不正确。"

  read -r -p "节点名称 [AnyTLS-Backup]: " name
  name="${name:-AnyTLS-Backup}"
  name="${name//$'\n'/}"
  password="$(openssl rand -hex 24)"
  link="$(make_link "$password" "$host" "$port" "$name" "$sni")"
  write_service "$port" "$password"
  write_info "$name" "$host" "$port" "$password" "$sni" "$link"
  start_service

  echo
  echo "AnyTLS 节点已创建。参考实现使用自签证书，所以链接中的 insecure=1 是必需的："
  print_all_formats "$name" "$host" "$port" "$password" "$sni" "$link"
  echo
  if confirm_yes "是否将这台 VPS 加入 AnyTLS 聚合订阅？"; then
    sync_subscription_node
  fi
}

show_link() {
  require_node_files
  print_all_formats "$(info_value NODE_NAME)" "$(info_value SERVER_ADDRESS)" "$(info_value PORT)" "$(info_value PASSWORD)" "$(info_value SNI)" "$(info_value LINK)"
}
print_link_qr() { echo "$1"; echo; qrencode -t ANSIUTF8 "$1"; }
print_all_formats() {
  local name="$1" host="$2" port="$3" password="$4" sni="$5" link="$6"
  echo "$link"
  echo
  qrencode -t ANSIUTF8 "$link"
  cat <<EOF

sing-box 出站配置：
{
  "type": "anytls",
  "tag": "$name",
  "server": "$host",
  "server_port": $port,
  "password": "$password",
  "tls": {
    "enabled": true,
    "server_name": "$sni",
    "insecure": true
  }
}

mihomo 节点配置：
- name: "$name"
  type: anytls
  server: $host
  port: $port
  password: "$password"
  client-fingerprint: chrome
  udp: true
  sni: "$sni"
  skip-cert-verify: true
EOF
  if [[ -f "$SUBSCRIPTION_INFO_FILE" ]]; then
    cat <<EOF

AnyTLS 聚合订阅（Mihomo / Clash Meta）：
$(subscription_info_value SUBSCRIPTION_URL)
EOF
  fi
}
show_status() { [[ -x "$BIN" ]] && "$BIN" -h 2>&1 | head -n1 || true; systemctl status "$SERVICE_NAME" --no-pager; }
show_logs() { journalctl -u "$SERVICE_NAME" -n 100 --no-pager; }
restart_node() { systemctl restart "$SERVICE_NAME"; systemctl is-active --quiet "$SERVICE_NAME" || die "重启失败。"; echo "已重启。"; }

change_port() {
  require_node_files
  local old_port new_port password host name link sni
  old_port="$(info_value PORT)"; password="$(info_value PASSWORD)"; host="$(info_value SERVER_ADDRESS)"; name="$(info_value NODE_NAME)"; sni="$(info_value SNI)"
  read -r -p "新的监听 TCP 端口 [$old_port]: " new_port
  new_port="${new_port:-$old_port}"
  validate_port "$new_port" || die "端口必须在 1-65535 之间。"
  [[ "$new_port" == "$old_port" ]] && { echo "端口未改变。"; return; }
  port_is_listening "$new_port" && die "TCP/$new_port 已被占用。"
  write_service "$new_port" "$password"
  link="$(make_link "$password" "$host" "$new_port" "$name" "$sni")"
  write_info "$name" "$host" "$new_port" "$password" "$sni" "$link"
  systemctl daemon-reload
  restart_node
  refresh_subscription_if_enabled
  print_all_formats "$name" "$host" "$new_port" "$password" "$sni" "$link"
}

change_link_host() {
  require_node_files
  local old_host host port password name link sni default_sni
  old_host="$(info_value SERVER_ADDRESS)"; port="$(info_value PORT)"; password="$(info_value PASSWORD)"; name="$(info_value NODE_NAME)"; sni="$(info_value SNI)"
  read -r -p "节点连接地址（IP 或已解析域名）[$old_host]: " host
  host="${host:-$old_host}"
  [[ -n "$host" && "$host" != *[[:space:]]* ]] || die "节点地址不能为空或包含空格。"
  default_sni="$sni"
  [[ -n "$default_sni" ]] || default_sni="$host"
  read -r -p "客户端 TLS SNI [$default_sni]: " sni
  sni="${sni:-$default_sni}"
  [[ "$sni" =~ ^[A-Za-z0-9.-]+$ ]] || die "SNI 格式不正确。"
  link="$(make_link "$password" "$host" "$port" "$name" "$sni")"
  write_info "$name" "$host" "$port" "$password" "$sni" "$link"
  refresh_subscription_if_enabled
  print_all_formats "$name" "$host" "$port" "$password" "$sni" "$link"
}

reset_password() {
  require_node_files
  local port host name password link sni
  confirm_yes "是否更换密码？旧链接会立即失效。" || return
  port="$(info_value PORT)"; host="$(info_value SERVER_ADDRESS)"; name="$(info_value NODE_NAME)"; sni="$(info_value SNI)"
  password="$(openssl rand -hex 24)"
  link="$(make_link "$password" "$host" "$port" "$name" "$sni")"
  write_service "$port" "$password"
  write_info "$name" "$host" "$port" "$password" "$sni" "$link"
  systemctl daemon-reload
  restart_node
  refresh_subscription_if_enabled
  print_all_formats "$name" "$host" "$port" "$password" "$sni" "$link"
}

upgrade_anytls() { require_node_files; install_anytls; restart_node; }

uninstall_node() {
  confirm_yes "是否卸载本脚本创建的 AnyTLS 节点？" || return
  remove_subscription_node true || true
  systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$SERVICE_FILE" "$INFO_FILE" "$SUBSCRIPTION_INFO_FILE"
  rmdir "$CONFIG_DIR" 2>/dev/null || true
  systemctl daemon-reload
  echo "AnyTLS 节点已卸载；二进制保留在 $INSTALL_DIR。"
}

menu() {
  cat <<EOF
========================================
 AnyTLS 独立节点脚本 $SCRIPT_VERSION
========================================
1. 安装 / 重建节点
2. 查看节点链接和二维码
3. 查看状态
4. 查看日志
5. 重启 AnyTLS
6. 更换监听端口
7. 设置节点连接地址
8. 更换密码
9. 检查 / 更新 anytls-go
10. 卸载节点
11. 加入 / 更新聚合订阅
12. 退出聚合订阅
0. 退出
EOF
  local choice
  read -r -p "请选择：" choice
  case "$choice" in
    1) install_node ;;
    2)
      require_node_files
      print_all_formats "$(info_value NODE_NAME)" "$(info_value SERVER_ADDRESS)" "$(info_value PORT)" "$(info_value PASSWORD)" "$(info_value SNI)" "$(info_value LINK)"
      ;;
    3) show_status ;;
    4) show_logs ;;
    5) restart_node ;;
    6) change_port ;;
    7) change_link_host ;;
    8) reset_password ;;
    9) upgrade_anytls ;;
    10) uninstall_node ;;
    11) generate_subscription ;;
    12) remove_subscription_node ;;
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
  password) reset_password ;;
  update) upgrade_anytls ;;
  subscription|subscribe|sub) generate_subscription ;;
  unsubscribe|unsub) remove_subscription_node ;;
  uninstall) uninstall_node ;;
  *) menu ;;
esac
