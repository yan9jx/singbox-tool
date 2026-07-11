#!/usr/bin/env bash
# NaiveProxy 独立安装与维护脚本，适用于 Debian/Ubuntu。
# 域名在安装时输入；不会在脚本中保存域名、账号、密码或其他个人信息。
# 默认尝试 TCP/443；端口被占用时自动选择其他可用端口，不停止现有服务。
set -Eeuo pipefail

SCRIPT_VERSION="v1.1"
INSTALL_DIR="/etc/naiveproxy"
INFO_FILE="$INSTALL_DIR/node-info.env"
CADDY_DIR="/etc/caddy-naive"
CADDYFILE="$CADDY_DIR/Caddyfile"
CADDY_SITE_DIR="$CADDY_DIR/sites"
CADDY_ROUTE_DIR="$CADDY_DIR/routes"
CADDY_SERVICE="shared-caddy"
CADDY_SERVICE_FILE="/etc/systemd/system/${CADDY_SERVICE}.service"
TLS_DIR="$INSTALL_DIR/tls"
TLS_CERT="$TLS_DIR/fullchain.pem"
TLS_KEY="$TLS_DIR/privkey.pem"
BIN="/usr/local/bin/caddy-naive"
MANAGER="/usr/local/sbin/naiveproxy-manager"
SERVICE_FILE="$CADDY_SERVICE_FILE"
UPDATE_SERVICE="/etc/systemd/system/naiveproxy-update.service"
UPDATE_TIMER="/etc/systemd/system/naiveproxy-update.timer"
RENEW_HOOK="/etc/letsencrypt/renewal-hooks/deploy/naiveproxy.sh"
WEB_ROOT="/var/www/naiveproxy"
SERVICE_USER="naiveproxy"
SERVICE_NAME="$CADDY_SERVICE"
RELEASE_API="https://api.github.com/repos/klzgrad/forwardproxy/releases/latest"
RELEASE_ASSET="caddy-forwardproxy-naive.tar.xz"

die() { echo "错误：$*" >&2; exit 1; }
require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行。"
  command -v systemctl >/dev/null || die "当前系统需要支持 systemd。"
}
confirm_yes() { local answer; read -r -p "$1 [Y/n]: " answer; [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]; }
validate_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 )); }
valid_domain() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}
port_is_listening() { ss -H -lnt "sport = :$1" 2>/dev/null | grep -q .; }
public_ipv4() { curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true; }
urlencode() { jq -nr --arg value "$1" '$value|@uri'; }
info_value() { sed -n "s/^$1='\\(.*\\)'$/\\1/p" "$INFO_FILE"; }
require_install() { [[ -x "$BIN" && -f "$INFO_FILE" && -f "$CADDYFILE" ]] || die "未找到 NaiveProxy，请先安装。"; }

install_deps() {
  command -v apt-get >/dev/null 2>&1 || die "仅支持 Debian/Ubuntu（apt-get）。"
  local missing=() cmd
  for cmd in curl jq openssl qrencode ss getent certbot tar xz sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  (( ${#missing[@]} == 0 )) && return
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl jq openssl qrencode iproute2 libc-bin ca-certificates certbot xz-utils tar coreutils tzdata
}

configure_china_time() {
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-timezone Asia/Shanghai 2>/dev/null || true
    timedatectl set-ntp true 2>/dev/null || true
  fi
  systemctl enable --now systemd-timesyncd 2>/dev/null || true
}

configure_bbr() {
  local available bbr_file="/etc/sysctl.d/99-naiveproxy-bbr.conf"
  echo "当前 TCP 拥塞控制算法：$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 未知)"
  confirm_yes "是否安装 / 启用 BBR + FQ？" || return 0
  modprobe tcp_bbr 2>/dev/null || true
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if ! grep -qw bbr <<<"$available"; then
    echo "警告：当前内核不支持 BBR，已跳过，不影响 NaiveProxy 安装。"
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

check_domain() {
  local domain="$1" ip="$2" resolved
  resolved="$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u | head -n1 || true)"
  [[ -n "$resolved" ]] || die "未检测到 $domain 的 A 记录。"
  [[ "$resolved" == "$ip" ]] ||
    die "$domain 当前解析到 $resolved，不是本机公网 IPv4 $ip。请确认 DNS 已生效且 Cloudflare 为仅 DNS（灰云）。"
}

detect_nginx_mode() {
  NGINX_MODE=""
  NGINX_TEST_ARGS=()
  NGINX_SERVICE=""
  ACME_NGINX_CONF=""
  if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
    NGINX_MODE="system"
    NGINX_SERVICE="nginx"
    ACME_NGINX_CONF="/etc/nginx/conf.d/naiveproxy-acme.conf"
  elif command -v nginx >/dev/null 2>&1 &&
    [[ -f /etc/nginx/filebrowser-standalone.conf ]] &&
    systemctl is-active --quiet filebrowser-nginx 2>/dev/null; then
    grep -qF 'include /etc/nginx/filebrowser-shared/*.conf;' /etc/nginx/filebrowser-standalone.conf ||
      die "检测到 filebrowser-nginx，但未启用共享配置目录。"
    NGINX_MODE="filebrowser"
    NGINX_SERVICE="filebrowser-nginx"
    NGINX_TEST_ARGS=(-c /etc/nginx/filebrowser-standalone.conf)
    ACME_NGINX_CONF="/etc/nginx/filebrowser-shared/naiveproxy-acme.conf"
  fi
}

reload_managed_nginx() {
  nginx -t "${NGINX_TEST_ARGS[@]}" && systemctl reload "$NGINX_SERVICE"
}

issue_certificate() {
  local domain="$1" live_dir="/etc/letsencrypt/live/$1" acme_root="/var/lib/naiveproxy-acme"
  if [[ -s "$live_dir/fullchain.pem" && -s "$live_dir/privkey.pem" ]] &&
    openssl x509 -checkend 604800 -noout -in "$live_dir/fullchain.pem" >/dev/null 2>&1; then
    return
  fi

  detect_nginx_mode
  if [[ -n "$NGINX_MODE" ]]; then
    install -d -m 755 "$acme_root/.well-known/acme-challenge" "$(dirname "$ACME_NGINX_CONF")"
    cat >"$ACME_NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $domain;
    location ^~ /.well-known/acme-challenge/ {
        root $acme_root;
        default_type text/plain;
    }
    location / { return 404; }
}
EOF
    if ! reload_managed_nginx; then
      rm -f "$ACME_NGINX_CONF"
      die "无法临时启用证书验证站点。"
    fi
    if ! certbot certonly --webroot -w "$acme_root" --non-interactive --agree-tos \
      --register-unsafely-without-email -d "$domain"; then
      rm -f "$ACME_NGINX_CONF"
      reload_managed_nginx || true
      die "证书申请失败。"
    fi
    # 保留仅处理 ACME challenge 的小型 server block，供 certbot 后续自动续期。
  else
    if port_is_listening 80; then
      ss -H -lntp "sport = :80" >&2 || true
      die "TCP/80 已被未知服务占用，无法使用 standalone 模式申请证书。"
    fi
    certbot certonly --standalone --non-interactive --agree-tos \
      --register-unsafely-without-email -d "$domain" || die "证书申请失败。"
  fi
  [[ -s "$live_dir/fullchain.pem" && -s "$live_dir/privkey.pem" ]] || die "证书文件不存在。"
}

choose_port() {
  local candidate
  for candidate in 443 8443 9443 10443 11443 12443 13443 14443 15443; do
    if ! port_is_listening "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  for candidate in $(seq 20000 20100); do
    if ! port_is_listening "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  die "找不到可用的 TCP 监听端口。"
}

shared_filebrowser_site_exists() {
  local domain="$1"
  [[ -f "${CADDY_SITE_DIR}/filebrowser-${domain}.caddy" ]]
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

ensure_service_user() {
  getent group "$SERVICE_USER" >/dev/null 2>&1 || groupadd --system "$SERVICE_USER"
  id "$SERVICE_USER" >/dev/null 2>&1 ||
    useradd --system --gid "$SERVICE_USER" --home-dir /var/lib/naiveproxy --create-home \
      --shell /usr/sbin/nologin "$SERVICE_USER"
  install -d -m 750 -o "$SERVICE_USER" -g "$SERVICE_USER" /var/lib/naiveproxy
  install -d -m 750 -o root -g "$SERVICE_USER" "$INSTALL_DIR" "$TLS_DIR"
}

sync_tls_files() {
  local domain="$1" live_dir="/etc/letsencrypt/live/$1"
  install -m 640 -o root -g "$SERVICE_USER" "$live_dir/fullchain.pem" "$TLS_CERT"
  install -m 640 -o root -g "$SERVICE_USER" "$live_dir/privkey.pem" "$TLS_KEY"
}

write_decoy_site() {
  install -d -m 755 "$WEB_ROOT"
  cat >"$WEB_ROOT/index.html" <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Welcome</title>
  <style>body{max-width:720px;margin:12vh auto;padding:24px;font:16px/1.7 system-ui;color:#263238}h1{font-size:28px}</style>
</head>
<body><h1>Welcome</h1><p>This site is online.</p></body>
</html>
EOF
  chmod 644 "$WEB_ROOT/index.html"
}

write_caddyfile() {
  local domain="$1" port="$2" username="$3" password="$4"
  install -d -m 755 "$CADDY_DIR" "$CADDY_SITE_DIR" "$CADDY_ROUTE_DIR/$domain"
  if [[ ! -f "$CADDYFILE" ]]; then
    cat >"$CADDYFILE" <<EOF
{
    order forward_proxy before reverse_proxy
    admin off
    auto_https disable_redirects
    log {
        output discard
    }
}

import ${CADDY_SITE_DIR}/*.caddy
EOF
  fi

  if [[ -f "${CADDY_SITE_DIR}/filebrowser-${domain}.caddy" && "$port" == "443" ]]; then
    cat >"${CADDY_ROUTE_DIR}/${domain}/naive.caddy" <<EOF
forward_proxy {
    basic_auth $username $password
    hide_ip
    hide_via
    probe_resistance
}
EOF
  else
    cat >"${CADDY_SITE_DIR}/naive-${domain}.caddy" <<EOF
$domain:$port {
    tls /etc/letsencrypt/live/$domain/fullchain.pem /etc/letsencrypt/live/$domain/privkey.pem
    encode
    forward_proxy {
        basic_auth $username $password
        hide_ip
        hide_via
        probe_resistance
    }
    root * $WEB_ROOT
    file_server
}
EOF
  fi
  chown root:"$SERVICE_USER" "$CADDYFILE"
  chmod 640 "$CADDYFILE"
}

write_service() {
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=NaiveProxy Caddy forward proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
Environment=XDG_DATA_HOME=/var/lib/naiveproxy
Environment=XDG_CONFIG_HOME=/var/lib/naiveproxy
ExecStart=$BIN run --environ --config $CADDYFILE --adapter caddyfile
ExecReload=$BIN reload --config $CADDYFILE --adapter caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
Restart=on-failure
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
PrivateTmp=true
ReadWritePaths=/var/lib/naiveproxy
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
}

write_renew_hook() {
  local domain="$1"
  install -d -m 755 "$(dirname "$RENEW_HOOK")"
  cat >"$RENEW_HOOK" <<EOF
#!/usr/bin/env bash
set -e
if systemctl is-enabled --quiet $SERVICE_NAME 2>/dev/null; then
  install -m 640 -o root -g $SERVICE_USER /etc/letsencrypt/live/$domain/fullchain.pem $TLS_CERT
  install -m 640 -o root -g $SERVICE_USER /etc/letsencrypt/live/$domain/privkey.pem $TLS_KEY
  systemctl restart $SERVICE_NAME
fi
EOF
  chmod 755 "$RENEW_HOOK"
}

fetch_latest_release() {
  local release_json
  release_json="$(curl -fsSL --max-time 30 "$RELEASE_API")" || die "无法获取 NaiveProxy 服务端最新版本。"
  RELEASE_TAG="$(jq -er '.tag_name' <<<"$release_json")" || die "最新版本信息缺少 tag。"
  RELEASE_URL="$(jq -er --arg name "$RELEASE_ASSET" '.assets[] | select(.name == $name) | .browser_download_url' <<<"$release_json")" ||
    die "最新版本缺少 $RELEASE_ASSET。"
  RELEASE_DIGEST="$(jq -er --arg name "$RELEASE_ASSET" '.assets[] | select(.name == $name) | .digest // ""' <<<"$release_json" |
    sed 's/^sha256://')" || true
}

prepare_latest_binary() {
  local workdir="$1"
  local archive="$workdir/$RELEASE_ASSET"
  fetch_latest_release
  curl -fL --retry 3 "$RELEASE_URL" -o "$archive"
  if [[ -n "$RELEASE_DIGEST" ]]; then
    printf '%s  %s\n' "$RELEASE_DIGEST" "$archive" | sha256sum -c - >/dev/null ||
      die "服务端安装包 SHA-256 校验失败。"
  fi
  tar -xJf "$archive" -C "$workdir"
  RELEASE_BINARY="$workdir/caddy-forwardproxy-naive/caddy"
  [[ -x "$RELEASE_BINARY" ]] || die "服务端安装包内容不完整。"
}

validate_caddy() {
  local binary="$1"
  "$binary" validate --config "$CADDYFILE" --adapter caddyfile >/dev/null ||
    die "Caddy/NaiveProxy 配置校验失败。"
}

make_uri() {
  local domain="$1" port="$2" username="$3" password="$4" name="$5"
  printf 'naive+https://%s:%s@%s:%s?sni=%s#%s' \
    "$(urlencode "$username")" "$(urlencode "$password")" "$domain" "$port" \
    "$(urlencode "$domain")" "$(urlencode "$name")"
}

write_info() {
  local name="$1" domain="$2" port="$3" username="$4" password="$5" version="$6" uri
  uri="$(make_uri "$domain" "$port" "$username" "$password" "$name")"
  cat >"$INFO_FILE" <<EOF
NODE_NAME='$name'
DOMAIN='$domain'
PORT='$port'
USERNAME='$username'
PASSWORD='$password'
SERVER_VERSION='$version'
URI='$uri'
EOF
  chmod 600 "$INFO_FILE"
}

install_self() {
  if [[ -r "$0" && -f "$0" ]]; then
    install -m 700 "$0" "$MANAGER"
  elif [[ ! -x "$MANAGER" ]]; then
    die "无法保存管理脚本；请先将脚本下载为本地文件后运行。"
  fi
}

enable_auto_update() {
  cat >"$UPDATE_SERVICE" <<EOF
[Unit]
Description=Check and update NaiveProxy server
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$MANAGER update --quiet
EOF
  cat >"$UPDATE_TIMER" <<'EOF'
[Unit]
Description=Weekly NaiveProxy server update check

[Timer]
OnCalendar=Sun *-*-* 04:20:00
RandomizedDelaySec=12h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now naiveproxy-update.timer
  echo "NaiveProxy 每周自动更新检查已启用。"
}

disable_auto_update() {
  systemctl disable --now naiveproxy-update.timer 2>/dev/null || true
  rm -f "$UPDATE_SERVICE" "$UPDATE_TIMER"
  systemctl daemon-reload
  echo "NaiveProxy 自动更新已关闭。"
}

start_service() {
  local port="$1"
  systemctl daemon-reload
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    systemctl reload "$SERVICE_NAME" || systemctl restart "$SERVICE_NAME"
  elif ! systemctl enable --now "$SERVICE_NAME"; then
    journalctl -u "$SERVICE_NAME" -n 80 --no-pager >&2 || true
    die "NaiveProxy 启动命令失败。"
  fi
  systemctl is-active --quiet "$SERVICE_NAME" || {
    journalctl -u "$SERVICE_NAME" -n 80 --no-pager >&2 || true
    die "NaiveProxy 启动失败。"
  }
  local n
  for ((n = 0; n < 10; n++)); do
    port_is_listening "$port" && return 0
    sleep 1
  done
  die "NaiveProxy 未监听 TCP/$port。"
}

show_config() {
  require_install
  local name domain port username password uri
  name="$(info_value NODE_NAME)"
  domain="$(info_value DOMAIN)"
  port="$(info_value PORT)"
  username="$(info_value USERNAME)"
  password="$(info_value PASSWORD)"
  uri="$(info_value URI)"
  cat <<EOF
NaiveProxy 节点：
名称：$name
地址：$domain
端口：$port
用户名：$username
密码：$password

分享链接：
$uri

官方 Naive 客户端配置：
{
  "listen": "socks://127.0.0.1:1080",
  "proxy": "https://$username:$password@$domain:$port"
}

sing-box / Husi / NekoBox 节点参数：
{
  "type": "naive",
  "tag": "$name",
  "server": "$domain",
  "server_port": $port,
  "username": "$username",
  "password": "$password",
  "tls": {
    "enabled": true,
    "server_name": "$domain"
  }
}
EOF
  echo
  qrencode -t ANSIUTF8 "$uri"
}

install_node() {
  install_deps
  configure_china_time
  configure_bbr
  install_self

  local domain ip port name username password tmp
  read -r -p "请输入已解析到本机的 NaiveProxy 域名：" domain
  domain="${domain#https://}"; domain="${domain%%/*}"; domain="${domain,,}"
  valid_domain "$domain" || die "域名格式不正确。"
  ip="$(public_ipv4)"
  [[ -n "$ip" ]] || die "无法检测本机公网 IPv4。"
  check_domain "$domain" "$ip"
  issue_certificate "$domain"

  systemctl stop naiveproxy 2>/dev/null || true
  if shared_filebrowser_site_exists "$domain"; then
    port="443"
  else
    port="$(choose_port)"
  fi
  echo "自动选择 NaiveProxy 监听端口：TCP/$port"
  read -r -p "节点名称 [NaiveProxy]: " name
  name="${name:-NaiveProxy}"; name="${name//\'/}"; name="${name//$'\n'/}"
  username="naive$(openssl rand -hex 4)"
  password="$(openssl rand -hex 24)"

  ensure_service_user
  sync_tls_files "$domain"
  write_decoy_site
  write_caddyfile "$domain" "$port" "$username" "$password"
  write_service
  write_renew_hook "$domain"
  systemctl enable --now certbot.timer 2>/dev/null || true

  tmp="$(mktemp -d)"
  prepare_latest_binary "$tmp"
  validate_caddy "$RELEASE_BINARY"
  install -m 755 "$RELEASE_BINARY" "$BIN"
  rm -rf "$tmp"
  write_info "$name" "$domain" "$port" "$username" "$password" "$RELEASE_TAG"
  open_firewall_port "$port"
  start_service "$port"
  enable_auto_update

  echo
  echo "NaiveProxy 已安装完成。请确认云厂商安全组已放行 TCP/$port。"
  show_config
}

update_server() {
  require_install
  local quiet=false tmp current backup port
  [[ "${1:-}" == "--quiet" ]] && quiet=true
  current="$(info_value SERVER_VERSION)"
  port="$(info_value PORT)"
  tmp="$(mktemp -d)"
  prepare_latest_binary "$tmp"
  if [[ "$current" == "$RELEASE_TAG" ]]; then
    rm -rf "$tmp"
    [[ "$quiet" == true ]] || echo "已是最新版本：$current"
    return 0
  fi
  validate_caddy "$RELEASE_BINARY"
  backup="${BIN}.previous"
  cp -a "$BIN" "$backup"
  install -m 755 "$RELEASE_BINARY" "$BIN"
  rm -rf "$tmp"
  if ! systemctl restart "$SERVICE_NAME" || ! systemctl is-active --quiet "$SERVICE_NAME" || ! port_is_listening "$port"; then
    cp -a "$backup" "$BIN"
    systemctl restart "$SERVICE_NAME" || true
    die "新版本启动失败，已自动回滚到 $current。"
  fi
  sed -i "s/^SERVER_VERSION='.*'$/SERVER_VERSION='$RELEASE_TAG'/" "$INFO_FILE"
  rm -f "$backup"
  echo "NaiveProxy 服务端已从 $current 更新到 $RELEASE_TAG。"
}

reset_password() {
  require_install
  local name domain port username password version
  name="$(info_value NODE_NAME)"
  domain="$(info_value DOMAIN)"
  port="$(info_value PORT)"
  username="$(info_value USERNAME)"
  version="$(info_value SERVER_VERSION)"
  password="$(openssl rand -hex 24)"
  write_caddyfile "$domain" "$port" "$username" "$password"
  validate_caddy "$BIN"
  systemctl restart "$SERVICE_NAME"
  systemctl is-active --quiet "$SERVICE_NAME" || die "重置密码后服务启动失败。"
  write_info "$name" "$domain" "$port" "$username" "$password" "$version"
  echo "密码已重置，请在客户端更新节点。"
  show_config
}

restart_node() {
  require_install
  local port
  port="$(info_value PORT)"
  validate_caddy "$BIN"
  systemctl restart "$SERVICE_NAME"
  if ! systemctl is-active --quiet "$SERVICE_NAME" || ! port_is_listening "$port"; then
    die "NaiveProxy 重启失败。"
  fi
  echo "NaiveProxy 已重启。"
}

uninstall_node() {
  confirm_yes "是否卸载本脚本创建的 NaiveProxy？" || return 0
  local domain
  domain="$(info_value DOMAIN 2>/dev/null || true)"
  systemctl disable --now naiveproxy-update.timer 2>/dev/null || true
  if [[ -n "$domain" ]]; then
    rm -f "${CADDY_ROUTE_DIR}/${domain}/naive.caddy" "${CADDY_SITE_DIR}/naive-${domain}.caddy"
  fi
  rm -f "$UPDATE_SERVICE" "$UPDATE_TIMER" "$RENEW_HOOK" "$MANAGER"
  rm -rf "$INSTALL_DIR" "$WEB_ROOT" /var/lib/naiveproxy
  systemctl reload "$SERVICE_NAME" 2>/dev/null || systemctl restart "$SERVICE_NAME" 2>/dev/null || true
  detect_nginx_mode
  if [[ -n "$NGINX_MODE" && -n "$ACME_NGINX_CONF" ]]; then
    rm -f "$ACME_NGINX_CONF"
    reload_managed_nginx || true
  fi
  userdel "$SERVICE_USER" 2>/dev/null || true
  groupdel "$SERVICE_USER" 2>/dev/null || true
  systemctl daemon-reload
  echo "NaiveProxy 已卸载；Let's Encrypt 证书保留，未修改其他服务。"
}

show_status() {
  require_install
  echo "脚本版本：$SCRIPT_VERSION"
  echo "服务端版本：$(info_value SERVER_VERSION)"
  systemctl status "$SERVICE_NAME" --no-pager
  systemctl status naiveproxy-update.timer --no-pager 2>/dev/null || true
}

menu() {
  cat <<EOF
========================================
 NaiveProxy 独立节点脚本 $SCRIPT_VERSION
========================================
1. 安装 / 重建 NaiveProxy
2. 查看节点配置和二维码
3. 查看状态
4. 查看日志
5. 重启 NaiveProxy
6. 重置密码
7. 检查 / 更新服务端
8. 开启每周自动更新
9. 关闭自动更新
10. 卸载 NaiveProxy
0. 退出
EOF
  local choice
  read -r -p "请选择：" choice
  case "$choice" in
    1) install_node ;;
    2) show_config ;;
    3) show_status ;;
    4) journalctl -u "$SERVICE_NAME" -n 100 --no-pager ;;
    5) restart_node ;;
    6) reset_password ;;
    7) update_server ;;
    8) enable_auto_update ;;
    9) disable_auto_update ;;
    10) uninstall_node ;;
    0) exit 0 ;;
    *) die "无效选项。" ;;
  esac
}

require_root
case "${1:-}" in
  install) install_node ;;
  link|config) show_config ;;
  status) show_status ;;
  logs) journalctl -u "$SERVICE_NAME" -n 100 --no-pager ;;
  restart) restart_node ;;
  password) reset_password ;;
  update) update_server "${2:-}" ;;
  auto-update-on) enable_auto_update ;;
  auto-update-off) disable_auto_update ;;
  uninstall) uninstall_node ;;
  *) menu ;;
esac
