#!/usr/bin/env bash
# VLESS + XHTTP + TLS 独立安装脚本，适用于 Debian/Ubuntu。
# 公网 TCP/443 由 Nginx 持有，可与云盘/File Browser 或其他反代站点共享。
# Xray 只监听 127.0.0.1 本地端口。
set -Eeuo pipefail

SCRIPT_VERSION="v1.9"
XRAY_ROOT="/opt/xray-xhttp"
XRAY_BIN="$XRAY_ROOT/xray"
XRAY_DIR="/etc/xray-xhttp"
XRAY_CONFIG="$XRAY_DIR/config.json"
XRAY_INFO="$XRAY_DIR/node-info.env"
XRAY_SERVICE="/etc/systemd/system/xray-xhttp.service"
NGINX_SYSTEM_CONF="/etc/nginx/conf.d/xray-xhttp.conf"
NGINX_SHARED_CONF="/etc/nginx/filebrowser-shared/xray-xhttp.conf"
LOCAL_PORT_BASE=10001
DEFAULT_DASHBOARD_URL="${DEFAULT_DASHBOARD_URL:-}"
DASHBOARD_AGENT_CONF="${DASHBOARD_AGENT_CONF:-/etc/ejectors-vps-agent.conf}"
SUBSCRIPTION_INFO_FILE="$XRAY_DIR/subscription.env"

die() { echo "错误：$*" >&2; exit 1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行。"; command -v systemctl >/dev/null || die "当前系统需要支持 systemd。"; }
confirm_yes() { local answer; read -r -p "$1 [Y/n]: " answer; [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]; }
json_escape() {
  local value="${1//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

valid_domain() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

install_deps() {
  command -v apt-get >/dev/null 2>&1 || die "仅支持 Debian/Ubuntu（apt-get）。"
  local missing=() cmd
  for cmd in curl unzip openssl qrencode nginx certbot getent ss; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  (( ${#missing[@]} == 0 )) && return
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl unzip openssl qrencode nginx certbot ca-certificates iproute2 libc-bin tzdata
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
  local current available bbr_file="/etc/sysctl.d/99-xray-xhttp-bbr.conf"
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
    echo "警告：当前内核不支持 BBR，已跳过，不影响 XHTTP 节点安装。"
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
    echo "警告：BBR + FQ 设置失败，已跳过，不影响 XHTTP 节点安装。"
  fi
}

install_xray() {
  local machine asset latest tmp zip binary
  [[ -x "$XRAY_BIN" ]] && return
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

detect_nginx_mode() {
  NGINX_MODE="system"
  NGINX_CONF="$NGINX_SYSTEM_CONF"
  NGINX_TEST_ARGS=()
  if [[ -f /etc/nginx/filebrowser-standalone.conf ]] && systemctl is-active --quiet filebrowser-nginx 2>/dev/null; then
    grep -qF 'include /etc/nginx/filebrowser-shared/*.conf;' /etc/nginx/filebrowser-standalone.conf ||
      die "检测到 filebrowser-nginx 正在运行，但未启用共享配置目录。请先更新/重装云盘脚本。"
    NGINX_MODE="filebrowser-standalone"
    NGINX_CONF="$NGINX_SHARED_CONF"
    NGINX_TEST_ARGS=(-c /etc/nginx/filebrowser-standalone.conf)
  fi
}

ensure_nginx_ready() {
  detect_nginx_mode
  if [[ "$NGINX_MODE" == "filebrowser-standalone" ]]; then
    return
  fi

  if systemctl is-active --quiet nginx 2>/dev/null; then
    return
  fi

  if ss -H -lntp 'sport = :443' 2>/dev/null | grep -q .; then
    ss -H -lntp 'sport = :443' >&2 || true
    die "TCP/443 已被非 Nginx 服务占用。为避免抢云盘或反代端口，已停止安装。"
  fi

  systemctl enable --now nginx
  systemctl is-active --quiet nginx || die "Nginx 启动失败。"
}

reload_nginx() {
  nginx -t "${NGINX_TEST_ARGS[@]}" || return 1
  if [[ "$NGINX_MODE" == "filebrowser-standalone" ]]; then
    systemctl restart filebrowser-nginx
  else
    systemctl reload nginx
  fi
}

check_domain() {
  local domain="$1" ip="$2" resolved
  resolved="$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u | head -n1 || true)"
  [[ -n "$resolved" ]] || die "未检测到 $domain 的 A 记录。"
  [[ "$resolved" == "$ip" ]] || die "$domain 当前解析到 $resolved，不是本机公网 IPv4 $ip。"
}

detect_cover_domain() {
  local xhttp_domain="$1" candidate
  candidate="$(
    grep -RhoE 'server_name[[:space:]]+[^;]+' \
      /etc/nginx/conf.d /etc/nginx/sites-enabled /etc/nginx/filebrowser-standalone.conf \
      2>/dev/null |
      sed -E 's/server_name[[:space:]]+//' |
      tr ' ' '\n' |
      sed '/^$/d; /^\*/d; /^_/d' |
      grep -E '^[A-Za-z0-9.-]+$' |
      grep -Fvx "$xhttp_domain" |
      head -n1 || true
  )"
  printf '%s' "$candidate"
}

issue_cert() {
  local domain="$1" cert_dir="/etc/letsencrypt/live/$1" acme_dir acme_conf
  [[ -s "$cert_dir/fullchain.pem" && -s "$cert_dir/privkey.pem" ]] &&
    openssl x509 -checkend 0 -noout -in "$cert_dir/fullchain.pem" >/dev/null 2>&1 && return

  if [[ "$NGINX_MODE" == "filebrowser-standalone" ]]; then
    ss -H -lnt 'sport = :80' 2>/dev/null | grep -q . && die "TCP/80 已被占用；请先手动申请好证书，再重新运行脚本。"
    certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d "$domain" ||
      die "证书申请失败。"
    return
  fi

  acme_dir="/var/lib/xray-xhttp-acme"
  acme_conf="/etc/nginx/conf.d/xray-xhttp-acme.conf"
  mkdir -p "$acme_dir/.well-known/acme-challenge"
  cat >"$acme_conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $domain;
    location ^~ /.well-known/acme-challenge/ { root $acme_dir; default_type text/plain; }
    location / { return 404; }
}
EOF
  nginx -t && systemctl reload nginx || { rm -f "$acme_conf"; die "无法启用 ACME 验证站点。"; }
  certbot certonly --webroot -w "$acme_dir" --non-interactive --agree-tos --register-unsafely-without-email -d "$domain" ||
    { rm -f "$acme_conf"; systemctl reload nginx || true; die "证书申请失败。"; }
  rm -f "$acme_conf"
  systemctl reload nginx || true
}

local_port() {
  local p
  for p in $(seq "$LOCAL_PORT_BASE" $((LOCAL_PORT_BASE + 99))); do
    ss -H -lnt "sport = :$p" 2>/dev/null | grep -q . || { printf '%s' "$p"; return; }
  done
  die "找不到可用的 Xray 本地端口。"
}

wait_for_xray_listener() {
  local port="$1" n
  for n in $(seq 1 10); do
    ss -H -lnt "sport = :$port" 2>/dev/null | grep -qE "127\\.0\\.0\\.1:$port" && return 0
    sleep 1
  done
  journalctl -u xray-xhttp -n 50 --no-pager >&2 || true
  return 1
}

write_xray_service() {
  cat >"$XRAY_SERVICE" <<EOF
[Unit]
Description=Xray XHTTP 节点
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

start_xray_service() {
  local port="$1"
  systemctl daemon-reload
  systemctl enable --now xray-xhttp || die "Xray 启动命令失败。"
  systemctl is-active --quiet xray-xhttp || die "Xray 服务未运行。"
  wait_for_xray_listener "$port" || die "Xray 未监听 127.0.0.1:$port。"
}

write_nginx() {
  local domain="$1" cert="$2" key="$3" port="$4" path="$5" cover_domain="$6" backup=""
  mkdir -p "$(dirname "$NGINX_CONF")"
  [[ -f "$NGINX_CONF" ]] && { backup="${NGINX_CONF}.backup.$(date +%Y%m%d-%H%M%S)"; cp -a "$NGINX_CONF" "$backup"; }
  cat >"$NGINX_CONF" <<EOF
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $domain;

    ssl_certificate $cert;
    ssl_certificate_key $key;
    ssl_protocols TLSv1.2 TLSv1.3;

    location ^~ $path {
        proxy_pass http://127.0.0.1:$port;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
EOF

  if [[ -n "$cover_domain" ]]; then
    cat >>"$NGINX_CONF" <<EOF
    location / {
        proxy_pass https://$cover_domain;
        proxy_ssl_server_name on;
        proxy_set_header Host $cover_domain;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
EOF
  else
    cat >>"$NGINX_CONF" <<EOF
    location / { return 404; }
EOF
  fi

  cat >>"$NGINX_CONF" <<EOF
}
EOF
  if ! reload_nginx; then
    [[ -n "$backup" ]] && cp -a "$backup" "$NGINX_CONF" || rm -f "$NGINX_CONF"
    reload_nginx || true
    die "Nginx 配置校验失败，已恢复之前的配置。"
  fi
}

install_node() {
  install_deps
  configure_bbr
  configure_china_time
  ensure_nginx_ready
  install_xray
  systemctl stop xray-xhttp 2>/dev/null || true

  local domain ip cert key port uuid path name tmp link cover_domain
  read -r -p "请输入已解析到本机的 XHTTP 域名/子域名：" domain
  domain="${domain#https://}"; domain="${domain%%/*}"; domain="${domain,,}"
  valid_domain "$domain" || die "域名格式不正确。"
  ip="$(public_ipv4)"; [[ -n "$ip" ]] || die "无法检测本机公网 IPv4。"
  check_domain "$domain" "$ip"
  cover_domain=""
  cover_domain="${cover_domain#https://}"; cover_domain="${cover_domain#http://}"; cover_domain="${cover_domain%%/*}"; cover_domain="${cover_domain,,}"
  [[ "$cover_domain" == "0" || "$cover_domain" == "none" || "$cover_domain" == "no" ]] && cover_domain=""
  if [[ -n "$cover_domain" ]]; then
    valid_domain "$cover_domain" || die "根路径反代域名格式不正确。"
    [[ "$cover_domain" != "$domain" ]] || die "根路径反代域名不能和 XHTTP 域名相同，否则会形成循环反代。"
  fi
  issue_cert "$domain"

  cert="/etc/letsencrypt/live/$domain/fullchain.pem"
  key="/etc/letsencrypt/live/$domain/privkey.pem"
  [[ -s "$cert" && -s "$key" ]] || die "证书文件不存在。"

  port="$(local_port)"
  uuid="$(cat /proc/sys/kernel/random/uuid)"
  path="/$(openssl rand -hex 8)"
  read -r -p "节点名称 [XHTTP]: " name
  name="${name:-XHTTP}"; name="${name// /-}"

  mkdir -p "$XRAY_DIR"; tmp="$(mktemp)"
  cat >"$tmp" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "127.0.0.1",
    "port": $port,
    "protocol": "vless",
    "settings": { "clients": [{ "id": "$uuid", "email": "xhttp" }], "decryption": "none" },
    "streamSettings": { "network": "xhttp", "xhttpSettings": { "path": "$path", "mode": "auto" } }
  }],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
EOF
  "$XRAY_BIN" run -test -format json -c "$tmp" >/dev/null || { rm -f "$tmp"; die "生成的 Xray 配置未通过校验。"; }
  install -m 600 "$tmp" "$XRAY_CONFIG"; rm -f "$tmp"
  write_xray_service
  start_xray_service "$port"
  write_nginx "$domain" "$cert" "$key" "$port" "$path" "$cover_domain"

  link="vless://${uuid}@${domain}:443?encryption=none&security=tls&sni=${domain}&type=xhttp&path=${path}&mode=auto#${name}"
  cat >"$XRAY_INFO" <<EOF
NODE_NAME='$name'
DOMAIN='$domain'
LOCAL_PORT='$port'
PATH='$path'
UUID='$uuid'
NGINX_CONF='$NGINX_CONF'
COVER_DOMAIN='$cover_domain'
LINK='$link'
EOF
  chmod 600 "$XRAY_INFO"
  echo
  echo "XHTTP 节点已创建，公网 TCP/443 通过 Nginx 共享："
  echo "$link"
  if [[ -n "$cover_domain" ]]; then
    echo
    echo "根路径已反代到：https://$cover_domain"
  fi
  echo
  qrencode -t ANSIUTF8 "$link"
  echo
  if confirm_yes "是否将这个 XHTTP 节点加入统一聚合订阅？"; then
    sync_subscription_node
  fi
}

info_value() { sed -n "s/^$1='\\(.*\\)'$/\\1/p" "$XRAY_INFO"; }
subscription_info_value() { if [[ -f "$SUBSCRIPTION_INFO_FILE" ]]; then sed -n "s/^$1='\\(.*\\)'$/\\1/p" "$SUBSCRIPTION_INFO_FILE"; fi; return 0; }
agent_info_value() { if [[ -f "$DASHBOARD_AGENT_CONF" ]]; then sed -n "s/^$1='\\(.*\\)'$/\\1/p" "$DASHBOARD_AGENT_CONF"; fi; return 0; }
require_node_files() { [[ -f "$XRAY_INFO" && -f "$XRAY_CONFIG" ]] || die "未找到 XHTTP 节点，请先安装。"; }

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
    SUB_NODE_ID="xhttp-$(tr -cd 'a-zA-Z0-9' </etc/machine-id | head -c 20)"
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
  local quiet="${1:-false}" name domain uuid path payload response subscription_url
  name="$(info_value NODE_NAME)"
  domain="$(info_value DOMAIN)"
  uuid="$(info_value UUID)"
  path="$(info_value PATH)"
  load_subscription_identity
  payload="$(printf '{"node_id":"%s","name":"%s","server":"%s","port":443,"uuid":"%s","sni":"%s","host":"%s","path":"%s","insecure":false}' \
    "$(json_escape "$SUB_NODE_ID")" "$(json_escape "$name")" "$(json_escape "$domain")" \
    "$(json_escape "$uuid")" "$(json_escape "$domain")" "$(json_escape "$domain")" "$(json_escape "$path")")"
  if ! response="$(curl -fsS --max-time 20 -X POST "${SUB_DASHBOARD_URL}/api/v1/xhttp" \
    -H "Authorization: Bearer ${SUB_INGEST_TOKEN}" -H "Content-Type: application/json" --data "$payload")"; then
    echo "警告：XHTTP 节点未能登记到聚合订阅服务。" >&2
    return 1
  fi
  subscription_url="$(sed -n 's/.*"subscription_url":"\([^"]*\)".*/\1/p' <<<"$response")"
  [[ "$subscription_url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/sub/anytls/[a-f0-9]{64}$ ]] ||
    die "订阅服务未返回有效链接。"
  install -d -m 700 "$XRAY_DIR"
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
  [[ -f "$SUBSCRIPTION_INFO_FILE" ]] || { [[ "$quiet" == "true" ]] || echo "当前 XHTTP 节点未加入聚合订阅。"; return 0; }
  dashboard_url="$(subscription_info_value DASHBOARD_URL)"
  ingest_token="$(subscription_info_value INGEST_TOKEN)"
  node_id="$(subscription_info_value NODE_ID)"
  payload="$(printf '{"node_id":"%s"}' "$(json_escape "$node_id")")"
  if ! curl -fsS --max-time 20 -X POST "${dashboard_url}/api/v1/xhttp/delete" \
    -H "Authorization: Bearer ${ingest_token}" -H "Content-Type: application/json" --data "$payload" >/dev/null; then
    echo "警告：无法从聚合订阅移除此 XHTTP 节点；本地记录暂未删除。" >&2
    return 1
  fi
  rm -f "$SUBSCRIPTION_INFO_FILE"
  [[ "$quiet" == "true" ]] || echo "当前 XHTTP 节点已退出聚合订阅。"
}

generate_subscription() { sync_subscription_node "${1:-false}"; }

show_link() {
  require_node_files
  local link
  link="$(info_value LINK)"
  echo "$link"
  echo
  qrencode -t ANSIUTF8 "$link"
  if [[ -f "$SUBSCRIPTION_INFO_FILE" ]]; then
    echo
    echo "统一聚合订阅（Mihomo / Clash Meta）："
    subscription_info_value SUBSCRIPTION_URL
  fi
}
show_status() { systemctl status xray-xhttp --no-pager; }
show_logs() { journalctl -u xray-xhttp -n 100 --no-pager; }
restart_xray() { require_node_files; local port; port="$(info_value LOCAL_PORT)"; systemctl restart xray-xhttp; wait_for_xray_listener "$port" || die "Xray 重启后未正常监听。"; echo "Xray 已重启。"; }

uninstall_node() {
  confirm_yes "是否卸载本脚本创建的 XHTTP 节点？" || return
  local conf=""
  [[ -f "$XRAY_INFO" ]] && conf="$(info_value NGINX_CONF || true)"
  remove_subscription_node true || true
  systemctl disable --now xray-xhttp 2>/dev/null || true
  rm -f "$XRAY_SERVICE" "$XRAY_CONFIG" "$XRAY_INFO" "$SUBSCRIPTION_INFO_FILE"
  [[ -n "$conf" ]] && rm -f "$conf"
  systemctl daemon-reload
  ensure_nginx_ready && reload_nginx || true
  echo "XHTTP 节点已卸载；Xray 二进制保留在 $XRAY_ROOT。"
}

menu() {
  cat <<EOF
========================================
 Xray XHTTP TLS 节点脚本 $SCRIPT_VERSION
========================================
1. 安装 / 重建 XHTTP 节点
2. 查看节点链接和二维码
3. 查看状态
4. 查看日志
5. 重启 Xray
6. 卸载 XHTTP 节点
7. 加入 / 更新聚合订阅
8. 退出聚合订阅
0. 退出
EOF
  local choice
  read -r -p "请选择：" choice
  case "$choice" in
    1) install_node ;;
    2) show_link ;;
    3) show_status ;;
    4) show_logs ;;
    5) restart_xray ;;
    6) uninstall_node ;;
    7) generate_subscription ;;
    8) remove_subscription_node ;;
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
  restart) restart_xray ;;
  subscription|subscribe|sub) generate_subscription ;;
  unsubscribe|unsub) remove_subscription_node ;;
  uninstall) uninstall_node ;;
  *) menu ;;
esac
