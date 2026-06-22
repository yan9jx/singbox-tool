#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="v1.1"
XRAY_BIN="/usr/local/bin/xray"
XRAY_DIR="/etc/xray-xhttp"
XRAY_CONFIG="$XRAY_DIR/config.json"
XRAY_INFO="$XRAY_DIR/node-info.env"
XRAY_SERVICE="/etc/systemd/system/xray-xhttp.service"
NGINX_SYSTEM_CONF="/etc/nginx/conf.d/xray-xhttp.conf"
NGINX_STANDALONE_CONF="/etc/nginx/filebrowser-shared/xray-xhttp.conf"
LOCAL_PORT_BASE=10001

die() { echo "错误：$*" >&2; exit 1; }
require_root() { [[ $EUID -eq 0 ]] || die "请使用 root 运行。"; }

confirm_yes() {
  local answer
  read -r -p "$1 [Y/n]: " answer
  [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]
}

valid_domain() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

install_deps() {
  local missing=() cmd
  for cmd in curl unzip openssl qrencode nginx certbot ss; do command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd"); done
  (( ${#missing[@]} == 0 )) && return
  command -v apt-get >/dev/null 2>&1 || die "缺少组件：${missing[*]}，请先安装。"
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl unzip openssl qrencode nginx certbot ca-certificates iproute2 util-linux
}

old_xray_found() {
  systemctl cat xray.service >/dev/null 2>&1 || [[ -x /usr/local/bin/xray || -x /usr/bin/xray ]] ||
    [[ -d /etc/xray || -d /usr/local/etc/xray ]]
}

cleanup_old_xray() {
  old_xray_found || return
  echo "检测到旧 Xray 服务、二进制或配置残留。"
  confirm_yes "是否清理旧 Xray 残留？" || return
  local backup="/root/xray-cleanup-backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup"
  for item in /etc/xray /usr/local/etc/xray /etc/systemd/system/xray.service /etc/systemd/system/xray@.service /usr/local/bin/xray /usr/bin/xray; do
    [[ -e "$item" ]] && cp -a "$item" "$backup/" 2>/dev/null || true
  done
  systemctl disable --now xray.service 2>/dev/null || true
  rm -rf /etc/xray /usr/local/etc/xray
  rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray@.service /usr/local/bin/xray /usr/bin/xray
  systemctl daemon-reload
  echo "旧 Xray 已清理，备份位于：$backup"
}

install_xray() {
  [[ -x "$XRAY_BIN" ]] && return
  local machine asset latest tmp zip binary
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64) asset="Xray-linux-64.zip" ;;
    aarch64|arm64) asset="Xray-linux-arm64-v8a.zip" ;;
    *) die "不支持的架构：$machine" ;;
  esac
  latest="$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
  [[ -n "$latest" ]] || die "无法获取 Xray 最新版本。"
  tmp="$(mktemp -d)"; zip="$tmp/xray.zip"
  curl -fL "https://github.com/XTLS/Xray-core/releases/download/${latest}/${asset}" -o "$zip"
  unzip -q "$zip" -d "$tmp"
  binary="$tmp/xray"
  [[ -x "$binary" ]] || die "Xray 安装包异常。"
  install -m 755 "$binary" "$XRAY_BIN"
  rm -rf "$tmp"
  echo "已安装 Xray：$latest"
}

public_ipv4() { curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true; }

check_domain() {
  local domain="$1" ip="$2" resolved
  resolved="$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u | head -n1 || true)"
  [[ -n "$resolved" ]] || die "未检测到 ${domain} 的 A 记录。"
  [[ "$resolved" == "$ip" ]] || die "${domain} 当前解析为 ${resolved}，不是本机公网 IP ${ip}。"
}

select_nginx_mode() {
  if systemctl is-active --quiet nginx 2>/dev/null; then
    NGINX_MODE="system"; NGINX_CONF="$NGINX_SYSTEM_CONF"; NGINX_TEST=()
  elif [[ -f /etc/nginx/filebrowser-standalone.conf ]] && systemctl is-active --quiet filebrowser-nginx 2>/dev/null; then
    NGINX_MODE="standalone"; NGINX_CONF="$NGINX_STANDALONE_CONF"; NGINX_TEST=(-c /etc/nginx/filebrowser-standalone.conf)
    grep -qF 'include /etc/nginx/filebrowser-shared/*.conf;' /etc/nginx/filebrowser-standalone.conf || die "云盘 Nginx 未启用共享配置目录，请先更新云盘脚本。"
  else
    die "未检测到正在运行的云盘 Nginx。请先安装并启动云盘。"
  fi
}

reload_nginx() {
  nginx -t "${NGINX_TEST[@]}" || return 1
  if [[ "$NGINX_MODE" == "system" ]]; then systemctl reload nginx; else systemctl restart filebrowser-nginx; fi
}

issue_cert() {
  local domain="$1" cert_dir="/etc/letsencrypt/live/$1" acme_dir acme_conf
  [[ -s "$cert_dir/fullchain.pem" && -s "$cert_dir/privkey.pem" ]] && openssl x509 -checkend 0 -noout -in "$cert_dir/fullchain.pem" >/dev/null 2>&1 && return
  if [[ "$NGINX_MODE" == "system" ]]; then
    acme_dir="/var/lib/xray-xhttp-acme"; acme_conf="/etc/nginx/conf.d/xray-xhttp-acme.conf"
    mkdir -p "$acme_dir/.well-known/acme-challenge"
    cat >"$acme_conf" <<EOF
server { listen 80; listen [::]:80; server_name $domain;
  location ^~ /.well-known/acme-challenge/ { root $acme_dir; default_type text/plain; }
  location / { return 404; }
}
EOF
    nginx -t && systemctl reload nginx || { rm -f "$acme_conf"; die "无法启用 ACME 验证站点。"; }
    certbot certonly --webroot -w "$acme_dir" --non-interactive --agree-tos --register-unsafely-without-email -d "$domain" || { rm -f "$acme_conf"; systemctl reload nginx || true; die "证书申请失败。"; }
    rm -f "$acme_conf"; systemctl reload nginx || true
  else
    ss -H -lnt 'sport = :80' 2>/dev/null | grep -q . && die "TCP/80 被占用，无法申请证书。"
    certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d "$domain" || die "证书申请失败。"
  fi
}

local_port() {
  local p
  for p in $(seq "$LOCAL_PORT_BASE" $((LOCAL_PORT_BASE + 30))); do
    ss -H -lnt "sport = :$p" 2>/dev/null | grep -q . || { printf '%s' "$p"; return; }
  done
  die "找不到可用的本机 Xray 端口。"
}

write_nginx() {
  local domain="$1" cert="$2" key="$3" local_port="$4" path="$5" backup=""
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
        proxy_pass http://127.0.0.1:$local_port;
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
    die "Nginx 校验失败，已恢复原配置。"
  fi
}

install_node() {
  install_deps; select_nginx_mode; cleanup_old_xray; install_xray
  local domain ip cert key port uuid path name tmp
  read -r -p "请输入 XHTTP 子域名（已解析到本机）：" domain
  domain="${domain#https://}"; domain="${domain%%/*}"; domain="${domain,,}"
  valid_domain "$domain" || die "域名格式错误。"
  ip="$(public_ipv4)"; [[ -n "$ip" ]] || die "无法获取本机公网 IPv4。"
  check_domain "$domain" "$ip"; issue_cert "$domain"
  cert="/etc/letsencrypt/live/$domain/fullchain.pem"; key="/etc/letsencrypt/live/$domain/privkey.pem"
  [[ -s "$cert" && -s "$key" ]] || die "证书文件不存在。"
  port="$(local_port)"; uuid="$(cat /proc/sys/kernel/random/uuid)"; path="/$(openssl rand -hex 8)"
  read -r -p "节点名称 [XHTTP]: " name; name="${name:-XHTTP}"; name="${name// /-}"
  mkdir -p "$XRAY_DIR"; tmp="$(mktemp)"
  cat >"$tmp" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "127.0.0.1", "port": $port, "protocol": "vless",
    "settings": { "clients": [{ "id": "$uuid", "email": "xhttp" }], "decryption": "none" },
    "streamSettings": { "network": "xhttp", "xhttpSettings": { "path": "$path", "mode": "auto" } }
  }],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
EOF
  local check_output
  if ! check_output="$("$XRAY_BIN" run -test -c "$tmp" 2>&1)"; then
    echo "Xray 配置校验输出：" >&2
    printf '%s\n' "$check_output" >&2
    rm -f "$tmp"
    die "Xray 配置校验失败。"
  fi
  install -m 600 "$tmp" "$XRAY_CONFIG"; rm -f "$tmp"
  cat >"$XRAY_SERVICE" <<EOF
[Unit]
Description=Xray XHTTP Node
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
  systemctl daemon-reload; systemctl enable --now xray-xhttp
  systemctl is-active --quiet xray-xhttp || die "Xray 启动失败。"
  write_nginx "$domain" "$cert" "$key" "$port" "$path"
  local link="vless://${uuid}@${domain}:443?encryption=none&security=tls&sni=${domain}&type=xhttp&path=${path}&mode=auto#${name}"
  cat >"$XRAY_INFO" <<EOF
NODE_NAME='$name'
DOMAIN='$domain'
LOCAL_PORT='$port'
UUID='$uuid'
PATH='$path'
LINK='$link'
EOF
  chmod 600 "$XRAY_INFO"
  echo; echo "XHTTP 节点已创建（与云盘/gRPC 共用 TCP/443）："; echo "$link"; echo
  qrencode -t ANSIUTF8 "$link"
}

show_link() { [[ -f "$XRAY_INFO" ]] || die "未找到 XHTTP 节点。"; sed -n "s/^LINK='\(.*\)'$/\1/p" "$XRAY_INFO"; }
show_status() { systemctl is-active xray-xhttp 2>/dev/null || true; "$XRAY_BIN" version 2>/dev/null | head -n1 || true; }
show_logs() { journalctl -u xray-xhttp -n 80 --no-pager; }
uninstall_node() { confirm_yes "是否卸载本脚本创建的 XHTTP 节点？" || return; systemctl disable --now xray-xhttp 2>/dev/null || true; rm -f "$XRAY_SERVICE" "$XRAY_CONFIG" "$XRAY_INFO" "$NGINX_SYSTEM_CONF" "$NGINX_STANDALONE_CONF"; systemctl daemon-reload; select_nginx_mode && reload_nginx || true; echo "已卸载 XHTTP 节点。"; }

menu() {
  echo "========================================"; echo " Xray XHTTP 节点脚本 $SCRIPT_VERSION"; echo "========================================"
  echo "1. 安装 / 重建 XHTTP 节点"; echo "2. 查看节点链接和二维码"; echo "3. 查看状态"; echo "4. 查看日志"; echo "5. 重启 Xray"; echo "6. 卸载 XHTTP 节点"; echo "0. 退出"
  read -r -p "请选择：" choice
  case "$choice" in 1) install_node;; 2) show_link | tee /dev/tty | qrencode -t ANSIUTF8;; 3) show_status;; 4) show_logs;; 5) systemctl restart xray-xhttp;; 6) uninstall_node;; 0) exit 0;; *) die "无效选项。";; esac
}

require_root
case "${1:-}" in install) install_node;; link) show_link;; status) show_status;; logs) show_logs;; restart) systemctl restart xray-xhttp;; uninstall) uninstall_node;; *) menu;; esac
