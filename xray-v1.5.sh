#!/usr/bin/env bash
# VLESS + XHTTP + TLS 独立安装脚本，适用于 Debian/Ubuntu。
# 公网 TCP/443 由 Nginx 持有，可与云盘/File Browser 或其他反代站点共享。
# Xray 只监听 127.0.0.1 本地端口。
set -Eeuo pipefail

SCRIPT_VERSION="v1.5"
XRAY_ROOT="/opt/xray-xhttp"
XRAY_BIN="$XRAY_ROOT/xray"
XRAY_DIR="/etc/xray-xhttp"
XRAY_CONFIG="$XRAY_DIR/config.json"
XRAY_INFO="$XRAY_DIR/node-info.env"
XRAY_SERVICE="/etc/systemd/system/xray-xhttp.service"
NGINX_SYSTEM_CONF="/etc/nginx/conf.d/xray-xhttp.conf"
NGINX_SHARED_CONF="/etc/nginx/filebrowser-shared/xray-xhttp.conf"
LOCAL_PORT_BASE=10001

die() { echo "错误：$*" >&2; exit 1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行。"; command -v systemctl >/dev/null || die "当前系统需要支持 systemd。"; }
confirm_yes() { local answer; read -r -p "$1 [Y/n]: " answer; [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]; }

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
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl unzip openssl qrencode nginx certbot ca-certificates iproute2 libc-bin
}

public_ipv4() { curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true; }

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
  local domain="$1" cert="$2" key="$3" port="$4" path="$5" backup=""
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

    location / { return 404; }
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
  ensure_nginx_ready
  install_xray
  systemctl stop xray-xhttp 2>/dev/null || true

  local domain ip cert key port uuid path name tmp link
  read -r -p "请输入已解析到本机的 XHTTP 域名/子域名：" domain
  domain="${domain#https://}"; domain="${domain%%/*}"; domain="${domain,,}"
  valid_domain "$domain" || die "域名格式不正确。"
  ip="$(public_ipv4)"; [[ -n "$ip" ]] || die "无法检测本机公网 IPv4。"
  check_domain "$domain" "$ip"
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
  write_nginx "$domain" "$cert" "$key" "$port" "$path"

  link="vless://${uuid}@${domain}:443?encryption=none&security=tls&sni=${domain}&type=xhttp&path=${path}&mode=auto#${name}"
  cat >"$XRAY_INFO" <<EOF
NODE_NAME='$name'
DOMAIN='$domain'
LOCAL_PORT='$port'
PATH='$path'
UUID='$uuid'
NGINX_CONF='$NGINX_CONF'
LINK='$link'
EOF
  chmod 600 "$XRAY_INFO"
  echo
  echo "XHTTP 节点已创建，公网 TCP/443 通过 Nginx 共享："
  echo "$link"
  echo
  qrencode -t ANSIUTF8 "$link"
}

info_value() { sed -n "s/^$1='\\(.*\\)'$/\\1/p" "$XRAY_INFO"; }
require_node_files() { [[ -f "$XRAY_INFO" && -f "$XRAY_CONFIG" ]] || die "未找到 XHTTP 节点，请先安装。"; }
show_link() { require_node_files; info_value LINK; }
show_status() { systemctl status xray-xhttp --no-pager; }
show_logs() { journalctl -u xray-xhttp -n 100 --no-pager; }
restart_xray() { require_node_files; local port; port="$(info_value LOCAL_PORT)"; systemctl restart xray-xhttp; wait_for_xray_listener "$port" || die "Xray 重启后未正常监听。"; echo "Xray 已重启。"; }

uninstall_node() {
  confirm_yes "是否卸载本脚本创建的 XHTTP 节点？" || return
  local conf=""
  [[ -f "$XRAY_INFO" ]] && conf="$(info_value NGINX_CONF || true)"
  systemctl disable --now xray-xhttp 2>/dev/null || true
  rm -f "$XRAY_SERVICE" "$XRAY_CONFIG" "$XRAY_INFO"
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
0. 退出
EOF
  local choice
  read -r -p "请选择：" choice
  case "$choice" in
    1) install_node ;;
    2) show_link | tee /dev/tty | qrencode -t ANSIUTF8 ;;
    3) show_status ;;
    4) show_logs ;;
    5) restart_xray ;;
    6) uninstall_node ;;
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
  uninstall) uninstall_node ;;
  *) menu ;;
esac
