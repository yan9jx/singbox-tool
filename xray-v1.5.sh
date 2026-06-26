#!/usr/bin/env bash
# Standalone VLESS + XHTTP + TLS installer for Debian/Ubuntu.
# Public TCP/443 is owned by Nginx and can be shared with File Browser or other
# Nginx virtual hosts. Xray only listens on 127.0.0.1.
set -Eeuo pipefail

SCRIPT_VERSION="v1.6"
XRAY_ROOT="/opt/xray-xhttp"
XRAY_BIN="$XRAY_ROOT/xray"
XRAY_DIR="/etc/xray-xhttp"
XRAY_CONFIG="$XRAY_DIR/config.json"
XRAY_INFO="$XRAY_DIR/node-info.env"
XRAY_SERVICE="/etc/systemd/system/xray-xhttp.service"
NGINX_SYSTEM_CONF="/etc/nginx/conf.d/xray-xhttp.conf"
NGINX_SHARED_CONF="/etc/nginx/filebrowser-shared/xray-xhttp.conf"
LOCAL_PORT_BASE=10001

die() { echo "ERROR: $*" >&2; exit 1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Please run as root."; command -v systemctl >/dev/null || die "systemd is required."; }
confirm_yes() { local answer; read -r -p "$1 [Y/n]: " answer; [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]; }

valid_domain() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

install_deps() {
  command -v apt-get >/dev/null 2>&1 || die "Only Debian/Ubuntu with apt-get is supported."
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
    *) die "Unsupported CPU architecture: $machine" ;;
  esac
  latest="$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
  [[ -n "$latest" ]] || die "Could not fetch latest Xray version."
  tmp="$(mktemp -d)"; zip="$tmp/xray.zip"
  curl -fL "https://github.com/XTLS/Xray-core/releases/download/${latest}/${asset}" -o "$zip"
  unzip -q "$zip" -d "$tmp"
  binary="$tmp/xray"
  [[ -x "$binary" ]] || die "Xray archive is incomplete."
  install -d -m 755 "$XRAY_ROOT"
  install -m 755 "$binary" "$XRAY_BIN"
  rm -rf "$tmp"
  echo "Installed Xray: $latest"
}

detect_nginx_mode() {
  NGINX_MODE="system"
  NGINX_CONF="$NGINX_SYSTEM_CONF"
  NGINX_TEST_ARGS=()
  if [[ -f /etc/nginx/filebrowser-standalone.conf ]] && systemctl is-active --quiet filebrowser-nginx 2>/dev/null; then
    grep -qF 'include /etc/nginx/filebrowser-shared/*.conf;' /etc/nginx/filebrowser-standalone.conf ||
      die "filebrowser-nginx is running but shared config include is missing. Reinstall/update the File Browser script first."
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
    die "TCP/443 is already occupied by a non-Nginx service. I will not steal the cloud disk or reverse-proxy port."
  fi

  systemctl enable --now nginx
  systemctl is-active --quiet nginx || die "Nginx failed to start."
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
  [[ -n "$resolved" ]] || die "No A record found for $domain."
  [[ "$resolved" == "$ip" ]] || die "$domain resolves to $resolved, not this VPS public IPv4 $ip."
}

issue_cert() {
  local domain="$1" cert_dir="/etc/letsencrypt/live/$1" acme_dir acme_conf
  [[ -s "$cert_dir/fullchain.pem" && -s "$cert_dir/privkey.pem" ]] &&
    openssl x509 -checkend 0 -noout -in "$cert_dir/fullchain.pem" >/dev/null 2>&1 && return

  if [[ "$NGINX_MODE" == "filebrowser-standalone" ]]; then
    ss -H -lnt 'sport = :80' 2>/dev/null | grep -q . && die "TCP/80 is occupied; obtain the certificate first, then rerun this script."
    certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d "$domain" ||
      die "Certificate request failed."
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
  nginx -t && systemctl reload nginx || { rm -f "$acme_conf"; die "Could not enable ACME challenge site."; }
  certbot certonly --webroot -w "$acme_dir" --non-interactive --agree-tos --register-unsafely-without-email -d "$domain" ||
    { rm -f "$acme_conf"; systemctl reload nginx || true; die "Certificate request failed."; }
  rm -f "$acme_conf"
  systemctl reload nginx || true
}

local_port() {
  local p
  for p in $(seq "$LOCAL_PORT_BASE" $((LOCAL_PORT_BASE + 99))); do
    ss -H -lnt "sport = :$p" 2>/dev/null | grep -q . || { printf '%s' "$p"; return; }
  done
  die "No free loopback port found for Xray."
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
}

start_xray_service() {
  local port="$1"
  systemctl daemon-reload
  systemctl enable --now xray-xhttp || die "Failed to start Xray."
  systemctl is-active --quiet xray-xhttp || die "Xray service is not running."
  wait_for_xray_listener "$port" || die "Xray did not listen on 127.0.0.1:$port."
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
    die "Nginx validation failed; previous config was restored."
  fi
}

install_node() {
  install_deps
  ensure_nginx_ready
  install_xray
  systemctl stop xray-xhttp 2>/dev/null || true

  local domain ip cert key port uuid path name tmp link
  read -r -p "XHTTP domain/subdomain resolved to this VPS: " domain
  domain="${domain#https://}"; domain="${domain%%/*}"; domain="${domain,,}"
  valid_domain "$domain" || die "Invalid domain."
  ip="$(public_ipv4)"; [[ -n "$ip" ]] || die "Could not detect public IPv4."
  check_domain "$domain" "$ip"
  issue_cert "$domain"

  cert="/etc/letsencrypt/live/$domain/fullchain.pem"
  key="/etc/letsencrypt/live/$domain/privkey.pem"
  [[ -s "$cert" && -s "$key" ]] || die "Certificate files are missing."

  port="$(local_port)"
  uuid="$(cat /proc/sys/kernel/random/uuid)"
  path="/$(openssl rand -hex 8)"
  read -r -p "Node name [XHTTP]: " name
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
  "$XRAY_BIN" run -test -format json -c "$tmp" >/dev/null || { rm -f "$tmp"; die "Generated Xray config did not pass validation."; }
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
  echo "XHTTP node created. Public TCP/443 is shared through Nginx:"
  echo "$link"
  echo
  qrencode -t ANSIUTF8 "$link"
}

info_value() { sed -n "s/^$1='\\(.*\\)'$/\\1/p" "$XRAY_INFO"; }
require_node_files() { [[ -f "$XRAY_INFO" && -f "$XRAY_CONFIG" ]] || die "XHTTP node not found. Install it first."; }
show_link() { require_node_files; info_value LINK; }
show_status() { systemctl status xray-xhttp --no-pager; }
show_logs() { journalctl -u xray-xhttp -n 100 --no-pager; }
restart_xray() { require_node_files; local port; port="$(info_value LOCAL_PORT)"; systemctl restart xray-xhttp; wait_for_xray_listener "$port" || die "Xray did not restart cleanly."; echo "Xray restarted."; }

uninstall_node() {
  confirm_yes "Uninstall the XHTTP node created by this script?" || return
  local conf=""
  [[ -f "$XRAY_INFO" ]] && conf="$(info_value NGINX_CONF || true)"
  systemctl disable --now xray-xhttp 2>/dev/null || true
  rm -f "$XRAY_SERVICE" "$XRAY_CONFIG" "$XRAY_INFO"
  [[ -n "$conf" ]] && rm -f "$conf"
  systemctl daemon-reload
  ensure_nginx_ready && reload_nginx || true
  echo "XHTTP node removed. Xray binary is kept at $XRAY_ROOT."
}

menu() {
  cat <<EOF
========================================
 Xray XHTTP TLS Node Script $SCRIPT_VERSION
========================================
1. Install / rebuild XHTTP node
2. Show node link and QR code
3. Show status
4. Show logs
5. Restart Xray
6. Uninstall XHTTP node
0. Exit
EOF
  local choice
  read -r -p "Choose: " choice
  case "$choice" in
    1) install_node ;;
    2) show_link | tee /dev/tty | qrencode -t ANSIUTF8 ;;
    3) show_status ;;
    4) show_logs ;;
    5) restart_xray ;;
    6) uninstall_node ;;
    0) exit 0 ;;
    *) die "Invalid option." ;;
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
