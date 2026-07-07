#!/usr/bin/env bash
# Mieru（mita）独立安装脚本，适用于 Debian/Ubuntu。
# 使用官方 mita 软件包，默认建立 TCP 节点，并可加入统一 Mihomo / Clash Meta 聚合订阅。
set -Eeuo pipefail

SCRIPT_VERSION="v1.1"
INSTALL_DIR="/etc/mieru-script"
INFO_FILE="$INSTALL_DIR/node-info.env"
SERVER_CONFIG="$INSTALL_DIR/server-config.json"
SUBSCRIPTION_INFO_FILE="$INSTALL_DIR/subscription.env"
DASHBOARD_AGENT_CONF="${DASHBOARD_AGENT_CONF:-/etc/ejectors-vps-agent.conf}"
DEFAULT_DASHBOARD_URL="${DEFAULT_DASHBOARD_URL:-}"
DEFAULT_PORT=2999

die() { echo "错误：$*" >&2; exit 1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行。"; command -v systemctl >/dev/null || die "当前系统需要支持 systemd。"; }
confirm_yes() { local answer; read -r -p "$1 [Y/n]: " answer; [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]; }
validate_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1025 && $1 <= 65535 )); }
port_is_listening() { ss -H -lnt "sport = :$1" 2>/dev/null | grep -q .; }
json_escape() {
  local value="${1//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

install_deps() {
  command -v apt-get >/dev/null 2>&1 || die "仅支持 Debian/Ubuntu（apt-get）。"
  local missing=() cmd
  for cmd in curl openssl ss dpkg qrencode python3; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  (( ${#missing[@]} == 0 )) && return
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl openssl ca-certificates iproute2 tzdata qrencode python3
}

public_ipv4() { curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true; }

configure_china_time() {
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-timezone Asia/Shanghai 2>/dev/null || true
    timedatectl set-ntp true 2>/dev/null || true
  fi
  systemctl enable --now systemd-timesyncd 2>/dev/null || true
  echo "已设置中国时区并启用系统自动对时（Mieru 要求客户端和服务端时间准确）。"
}

configure_bbr() {
  local available bbr_file="/etc/sysctl.d/99-mieru-bbr.conf"
  echo "当前 TCP 拥塞控制算法：$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 未知)"
  confirm_yes "是否安装 / 启用 BBR + FQ？" || return 0
  modprobe tcp_bbr 2>/dev/null || true
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if ! grep -qw bbr <<<"$available"; then
    echo "警告：当前内核不支持 BBR，已跳过，不影响 Mieru 安装。"
    return 0
  fi
  cat >"$bbr_file" <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl -w net.core.default_qdisc=fq >/dev/null
  sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null
  echo "BBR + FQ 已启用。"
}

latest_mieru_version() {
  curl -fsSL https://api.github.com/repos/enfein/mieru/releases/latest |
    sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -n1
}

install_mita() {
  local machine arch version tmp package
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "不支持的 CPU 架构：$machine" ;;
  esac
  version="$(latest_mieru_version)"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "无法获取 Mieru 最新版本。"
  tmp="$(mktemp -d)"
  package="$tmp/mita.deb"
  curl -fL "https://github.com/enfein/mieru/releases/download/v${version}/mita_${version}_${arch}.deb" -o "$package"
  dpkg -i "$package" || { apt-get -f install -y; dpkg -i "$package"; }
  rm -rf "$tmp"
  command -v mita >/dev/null 2>&1 || die "mita 安装失败。"
  systemctl enable --now mita
  echo "已安装 Mieru mita v${version}。"
}

open_firewall_port() {
  local port="$1"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${port}/tcp" >/dev/null
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null
    firewall-cmd --reload >/dev/null
  fi
}

write_server_config() {
  local port="$1" username="$2" password="$3"
  install -d -m 700 "$INSTALL_DIR"
  cat >"$SERVER_CONFIG" <<EOF
{
  "portBindings": [
    {
      "port": $port,
      "protocol": "TCP"
    }
  ],
  "users": [
    {
      "name": "$(json_escape "$username")",
      "password": "$(json_escape "$password")"
    }
  ],
  "loggingLevel": "INFO"
}
EOF
  chmod 600 "$SERVER_CONFIG"
}

apply_server_config() {
  systemctl enable --now mita
  mita apply config "$SERVER_CONFIG"
  mita stop >/dev/null 2>&1 || true
  mita start
  sleep 1
  mita status | grep -q RUNNING || die "mita 未进入 RUNNING 状态。"
}

write_info() {
  local name="$1" server="$2" port="$3" username="$4" password="$5"
  cat >"$INFO_FILE" <<EOF
NODE_NAME='$name'
SERVER_ADDRESS='$server'
PORT='$port'
USERNAME='$username'
PASSWORD='$password'
TRANSPORT='TCP'
EOF
  chmod 600 "$INFO_FILE"
}

info_value() { sed -n "s/^$1='\\(.*\\)'$/\\1/p" "$INFO_FILE"; }
subscription_info_value() { if [[ -f "$SUBSCRIPTION_INFO_FILE" ]]; then sed -n "s/^$1='\\(.*\\)'$/\\1/p" "$SUBSCRIPTION_INFO_FILE"; fi; return 0; }
agent_info_value() { if [[ -f "$DASHBOARD_AGENT_CONF" ]]; then sed -n "s/^$1='\\(.*\\)'$/\\1/p" "$DASHBOARD_AGENT_CONF"; fi; return 0; }
require_node_files() { [[ -f "$INFO_FILE" && -f "$SERVER_CONFIG" ]] || die "未找到 Mieru 节点，请先安装。"; command -v mita >/dev/null || die "未找到 mita。"; }

urlencode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

show_share_link() {
  require_node_files
  local name server port username password name_enc user_enc pass_enc primary fallback
  name="$(info_value NODE_NAME)"
  server="$(info_value SERVER_ADDRESS)"
  port="$(info_value PORT)"
  username="$(info_value USERNAME)"
  password="$(info_value PASSWORD)"
  name_enc="$(urlencode "$name")"
  user_enc="$(urlencode "$username")"
  pass_enc="$(urlencode "$password")"
  primary="mieru://${user_enc}:${pass_enc}@${server}:${port}?protocol=tcp&transport=tcp#${name_enc}"
  fallback="mieru://${pass_enc}@${server}:${port}?protocol=tcp&transport=tcp#${name_enc}"
  echo "Mieru 分享直链（主链，含 username:password）："
  echo "$primary"
  echo
  echo "备用直链（仅 password；若客户端不认用户名字段就试这个）："
  echo "$fallback"
  echo
  echo "二维码（主链）："
  qrencode -t ANSIUTF8 "$primary"
}

load_subscription_identity() {
  SUB_DASHBOARD_URL="$(agent_info_value DASHBOARD_URL)"
  SUB_INGEST_TOKEN="$(agent_info_value INGEST_TOKEN)"
  SUB_NODE_ID="$(agent_info_value NODE_ID)"
  [[ -n "$SUB_DASHBOARD_URL" ]] || SUB_DASHBOARD_URL="$(subscription_info_value DASHBOARD_URL)"
  [[ -n "$SUB_INGEST_TOKEN" ]] || SUB_INGEST_TOKEN="$(subscription_info_value INGEST_TOKEN)"
  [[ -n "$SUB_NODE_ID" ]] || SUB_NODE_ID="$(subscription_info_value NODE_ID)"
  SUB_DASHBOARD_URL="${SUB_DASHBOARD_URL:-$DEFAULT_DASHBOARD_URL}"
  [[ -n "$SUB_DASHBOARD_URL" ]] || read -rp "聚合订阅服务地址（HTTPS）: " SUB_DASHBOARD_URL
  SUB_DASHBOARD_URL="${SUB_DASHBOARD_URL%/}"
  if [[ -z "$SUB_NODE_ID" && -r /etc/machine-id ]]; then
    SUB_NODE_ID="mieru-$(tr -cd 'a-zA-Z0-9' </etc/machine-id | head -c 20)"
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
  local quiet="${1:-false}" name server port username password payload response subscription_url
  name="$(info_value NODE_NAME)"
  server="$(info_value SERVER_ADDRESS)"
  port="$(info_value PORT)"
  username="$(info_value USERNAME)"
  password="$(info_value PASSWORD)"
  load_subscription_identity
  payload="$(printf '{"node_id":"%s","name":"%s","server":"%s","port":%s,"username":"%s","password":"%s","transport":"TCP","multiplexing":"MULTIPLEXING_LOW"}' \
    "$(json_escape "$SUB_NODE_ID")" "$(json_escape "$name")" "$(json_escape "$server")" "$port" \
    "$(json_escape "$username")" "$(json_escape "$password")")"
  if ! response="$(curl -fsS --max-time 20 -X POST "${SUB_DASHBOARD_URL}/api/v1/mieru" \
    -H "Authorization: Bearer ${SUB_INGEST_TOKEN}" -H "Content-Type: application/json" --data "$payload")"; then
    echo "警告：Mieru 节点未能登记到聚合订阅服务。" >&2
    return 1
  fi
  subscription_url="$(sed -n 's/.*"subscription_url":"\([^"]*\)".*/\1/p' <<<"$response")"
  [[ "$subscription_url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/sub/anytls/[a-f0-9]{64}$ ]] ||
    die "订阅服务未返回有效链接。"
  cat >"$SUBSCRIPTION_INFO_FILE" <<EOF
DASHBOARD_URL='$SUB_DASHBOARD_URL'
INGEST_TOKEN='$SUB_INGEST_TOKEN'
NODE_ID='$SUB_NODE_ID'
SUBSCRIPTION_URL='$subscription_url'
EOF
  chmod 600 "$SUBSCRIPTION_INFO_FILE"
  if [[ "$quiet" != "true" ]]; then
    echo
    echo "统一聚合订阅（Mihomo / Clash Meta）："
    echo "$subscription_url"
    echo "同一 VPS 的其他协议也可加入这条订阅链接。"
  fi
}

remove_subscription_node() {
  local quiet="${1:-false}" dashboard_url ingest_token node_id payload
  [[ -f "$SUBSCRIPTION_INFO_FILE" ]] || { [[ "$quiet" == "true" ]] || echo "当前 Mieru 节点未加入聚合订阅。"; return 0; }
  dashboard_url="$(subscription_info_value DASHBOARD_URL)"
  ingest_token="$(subscription_info_value INGEST_TOKEN)"
  node_id="$(subscription_info_value NODE_ID)"
  payload="$(printf '{"node_id":"%s"}' "$(json_escape "$node_id")")"
  if ! curl -fsS --max-time 20 -X POST "${dashboard_url}/api/v1/mieru/delete" \
    -H "Authorization: Bearer ${ingest_token}" -H "Content-Type: application/json" --data "$payload" >/dev/null; then
    echo "警告：无法从聚合订阅移除此 Mieru 节点；本地记录暂未删除。" >&2
    return 1
  fi
  rm -f "$SUBSCRIPTION_INFO_FILE"
  [[ "$quiet" == "true" ]] || echo "当前 Mieru 节点已退出聚合订阅。"
}

show_config() {
  require_node_files
  local name server port username password
  name="$(info_value NODE_NAME)"
  server="$(info_value SERVER_ADDRESS)"
  port="$(info_value PORT)"
  username="$(info_value USERNAME)"
  password="$(info_value PASSWORD)"
  cat <<EOF
Mihomo / Clash Meta 节点配置：
- name: "$name"
  type: mieru
  server: "$server"
  port: $port
  transport: TCP
  username: "$username"
  password: "$password"
  multiplexing: MULTIPLEXING_LOW
EOF
  if [[ -f "$SUBSCRIPTION_INFO_FILE" ]]; then
    echo
    echo "统一聚合订阅："
    subscription_info_value SUBSCRIPTION_URL
  fi
  echo
  show_share_link
}

install_node() {
  install_deps
  configure_bbr
  configure_china_time
  install_mita
  mita stop >/dev/null 2>&1 || true

  local server port name username password
  server="$(public_ipv4)"
  [[ -n "$server" ]] || die "无法检测本机公网 IPv4。"
  read -r -p "节点连接地址 [$server]: " input_server
  server="${input_server:-$server}"
  [[ "$server" =~ ^[A-Za-z0-9.-]+$ ]] || die "节点连接地址格式错误。"
  read -r -p "Mieru TCP 端口 [$DEFAULT_PORT]: " port
  port="${port:-$DEFAULT_PORT}"
  validate_port "$port" || die "端口必须在 1025-65535 之间。"
  if port_is_listening "$port"; then
    die "TCP/$port 已被占用，请换一个端口。"
  fi
  read -r -p "节点名称 [Mieru]: " name
  name="${name:-Mieru}"; name="${name//\'/}"; name="${name//$'\n'/}"
  username="mieru$(openssl rand -hex 4)"
  password="$(openssl rand -hex 24)"
  write_server_config "$port" "$username" "$password"
  write_info "$name" "$server" "$port" "$username" "$password"
  apply_server_config
  open_firewall_port "$port"
  echo
  echo "Mieru 节点已创建。请确认云厂商安全组已放行 TCP/$port。"
  show_config
  echo
  if confirm_yes "是否将这个 Mieru 节点加入统一聚合订阅？"; then
    sync_subscription_node
  fi
}

restart_node() {
  require_node_files
  mita stop >/dev/null 2>&1 || true
  mita start
  mita status | grep -q RUNNING || die "Mieru 重启失败。"
  echo "Mieru 已重启。"
}

change_port() {
  require_node_files
  local port username password
  read -r -p "新 TCP 端口（1025-65535）: " port
  validate_port "$port" || die "端口格式错误。"
  port_is_listening "$port" && die "TCP/$port 已被占用。"
  username="$(info_value USERNAME)"
  password="$(info_value PASSWORD)"
  write_server_config "$port" "$username" "$password"
  sed -i "s/^PORT='.*'$/PORT='$port'/" "$INFO_FILE"
  apply_server_config
  open_firewall_port "$port"
  [[ -f "$SUBSCRIPTION_INFO_FILE" ]] && sync_subscription_node true || true
  echo "端口已更新为 TCP/$port。"
}

reset_password() {
  require_node_files
  local port username password
  port="$(info_value PORT)"
  username="$(info_value USERNAME)"
  password="$(openssl rand -hex 24)"
  write_server_config "$port" "$username" "$password"
  sed -i "s/^PASSWORD='.*'$/PASSWORD='$password'/" "$INFO_FILE"
  apply_server_config
  [[ -f "$SUBSCRIPTION_INFO_FILE" ]] && sync_subscription_node true || true
  echo "密码已重置，订阅记录已同步更新。"
  show_config
}

upgrade_mieru() {
  install_deps
  install_mita
  if [[ -f "$SERVER_CONFIG" ]]; then
    apply_server_config
  fi
}

uninstall_node() {
  confirm_yes "是否卸载本脚本创建的 Mieru 节点？" || return
  remove_subscription_node true || true
  mita stop >/dev/null 2>&1 || true
  systemctl disable --now mita 2>/dev/null || true
  dpkg -r mita 2>/dev/null || true
  rm -rf "$INSTALL_DIR"
  echo "Mieru 节点已卸载。"
}

menu() {
  cat <<EOF
========================================
 Mieru 独立节点脚本 $SCRIPT_VERSION
========================================
1. 安装 / 重建 Mieru 节点
2. 查看 Mihomo 节点配置和订阅
3. 查看状态
4. 查看日志
5. 重启 Mieru
6. 更换监听端口
7. 更换密码
8. 检查 / 更新 Mieru
9. 卸载节点
10. 加入 / 更新聚合订阅
11. 退出聚合订阅
0. 退出
EOF
  local choice
  read -r -p "请选择：" choice
  case "$choice" in
    1) install_node ;;
    2) show_config ;;
    3) mita status; systemctl status mita --no-pager ;;
    4) journalctl -u mita -n 100 --no-pager ;;
    5) restart_node ;;
    6) change_port ;;
    7) reset_password ;;
    8) upgrade_mieru ;;
    9) uninstall_node ;;
    10) sync_subscription_node ;;
    11) remove_subscription_node ;;
    12) show_share_link ;;
    0) exit 0 ;;
    *) die "无效选项。" ;;
  esac
}

require_root
case "${1:-}" in
  install) install_node ;;
  config) show_config ;;
  link|share|qr) show_share_link ;;
  status) mita status; systemctl status mita --no-pager ;;
  logs) journalctl -u mita -n 100 --no-pager ;;
  restart) restart_node ;;
  port) change_port ;;
  password) reset_password ;;
  update) upgrade_mieru ;;
  subscription|subscribe|sub) sync_subscription_node ;;
  unsubscribe|unsub) remove_subscription_node ;;
  uninstall) uninstall_node ;;
  *) menu ;;
esac
