#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# NaiveProxy server installer for Debian x86_64.
# Usage:
#   sudo bash install-naiveproxy-debian.sh
#   sudo DOMAIN=other.example.com bash install-naiveproxy-debian.sh
#   sudo bash install-naiveproxy-debian.sh show
#   sudo bash install-naiveproxy-debian.sh status

DOMAIN="${DOMAIN:-jpn.ejectors.net}"
REQUESTED_DOMAIN="$DOMAIN"
ACTION="${1:-install}"
STATE_DIR="/etc/naiveproxy"
CREDENTIALS="${STATE_DIR}/credentials"
CADDYFILE="/etc/caddy/Caddyfile"
SERVICE="/etc/systemd/system/caddy-naive.service"
CADDY_VERSION="v2.11.2-naive"
CADDY_SHA256="19eccb7321dd877a5fb4a3dba6ef1b745185188b616c96cc6201f1a1fc0380a8"
CADDY_URL="https://github.com/klzgrad/forwardproxy/releases/download/${CADDY_VERSION}/caddy-forwardproxy-naive.tar.xz"

die() {
  printf '错误: %s\n' "$*" >&2
  exit 1
}

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "请用 root 运行：sudo bash $0"
}

load_credentials() {
  [[ -r "$CREDENTIALS" ]] || die "未找到 $CREDENTIALS，请先安装"
  # Values are restricted to DNS names and hexadecimal strings by this script.
  # shellcheck disable=SC1090
  source "$CREDENTIALS"
}

show_config() {
  load_credentials
  local uri="naive+https://${NAIVE_USER}:${NAIVE_PASS}@${DOMAIN}:443?padding=true#jpn-naive"
  printf '\n域名: %s\n用户名: %s\n密码: %s\n\n导入链接:\n%s\n\n' \
    "$DOMAIN" "$NAIVE_USER" "$NAIVE_PASS" "$uri"
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 "$uri" || true
  fi
}

check_dns() {
  local public_ipv4 resolved
  public_ipv4="$(curl -4fsS --max-time 10 https://api.ipify.org || true)"
  resolved="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u || true)"

  [[ -n "$resolved" ]] || die \
    "$DOMAIN 尚未解析。请先添加 A 记录指向本机公网 IPv4，等待生效后重跑脚本。"

  if [[ -n "$public_ipv4" ]] && ! grep -Fxq "$public_ipv4" <<<"$resolved"; then
    printf '当前服务器公网 IPv4: %s\n%s 当前解析到:\n%s\n' \
      "$public_ipv4" "$DOMAIN" "$resolved" >&2
    die "DNS 未指向本服务器。若使用 Cloudflare，请设为“仅 DNS”，不要开启代理云朵。"
  fi
}

check_ports() {
  local occupied
  occupied="$(ss -H -ltnp '( sport = :80 or sport = :443 )' 2>/dev/null || true)"
  if [[ -n "$occupied" ]]; then
    printf '%s\n' "$occupied" >&2
    die "TCP 80/443 已被占用；请先处理现有 Web 服务"
  fi
}

install_server() {
  need_root
  [[ -r /etc/os-release ]] || die "无法识别操作系统"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "debian" ]] || die "此脚本只支持 Debian"
  [[ "$(uname -m)" == "x86_64" ]] || die \
    "官方预编译服务端仅适配 x86_64；当前架构为 $(uname -m)"
  [[ "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] ||
    die "域名格式不正确：$DOMAIN"

  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl xz-utils tar openssl qrencode iproute2

  check_dns

  local reinstall=0
  if [[ -f "$CREDENTIALS" ]]; then
    reinstall=1
    load_credentials
    [[ "$REQUESTED_DOMAIN" == "$DOMAIN" ]] || die \
      "现有安装使用域名 $DOMAIN；如需迁移域名，请先人工调整配置"
  else
    check_ports
    NAIVE_USER="naive_$(openssl rand -hex 4)"
    NAIVE_PASS="$(openssl rand -hex 18)"
  fi

  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  printf '下载 Caddy-naive...\n'
  curl -fL --retry 3 --connect-timeout 15 "$CADDY_URL" -o "$tmp/caddy.tar.xz"
  printf '%s  %s\n' "$CADDY_SHA256" "$tmp/caddy.tar.xz" | sha256sum --check --status ||
    die "Caddy-naive 下载文件的 SHA-256 校验失败"
  tar -xJf "$tmp/caddy.tar.xz" -C "$tmp"
  [[ -x "$tmp/caddy-forwardproxy-naive/caddy" ]] ||
    die "下载包内未找到 Caddy 可执行文件"

  install -d -m 0755 /etc/caddy /var/www/html /var/lib/caddy
  install -d -m 0700 "$STATE_DIR"
  install -m 0755 "$tmp/caddy-forwardproxy-naive/caddy" /usr/local/bin/caddy-naive

  if ! getent group caddy >/dev/null; then
    groupadd --system caddy
  fi
  if ! id caddy >/dev/null 2>&1; then
    useradd --system --gid caddy --create-home --home-dir /var/lib/caddy \
      --shell /usr/sbin/nologin --comment "Caddy web server" caddy
  fi
  chown -R caddy:caddy /var/lib/caddy

  cat >"$CREDENTIALS" <<EOF
DOMAIN=$DOMAIN
NAIVE_USER=$NAIVE_USER
NAIVE_PASS=$NAIVE_PASS
EOF
  chmod 0600 "$CREDENTIALS"

  cat >"$CADDYFILE" <<EOF
{
	order forward_proxy before file_server
	log {
		exclude http.log.error
	}
}

:443, $DOMAIN {
	encode
	forward_proxy {
		basic_auth $NAIVE_USER $NAIVE_PASS
		hide_ip
		hide_via
		probe_resistance
	}
	file_server {
		root /var/www/html
	}
}
EOF
  chmod 0644 "$CADDYFILE"

  cat >/var/www/html/index.html <<'EOF'
<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Welcome</title>
<style>
body{max-width:42rem;margin:12vh auto;padding:0 1.5rem;font:16px/1.6 system-ui;color:#27303f}
h1{font-weight:600}
</style>
<h1>It works.</h1>
<p>This site is online.</p>
EOF
  chmod 0644 /var/www/html/index.html

  cat >"$SERVICE" <<'EOF'
[Unit]
Description=Caddy with NaiveProxy forward proxy
Documentation=https://github.com/klzgrad/naiveproxy
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
Environment=HOME=/var/lib/caddy
Environment=XDG_DATA_HOME=/var/lib/caddy/.local/share
Environment=XDG_CONFIG_HOME=/var/lib/caddy/.config
ExecStart=/usr/local/bin/caddy-naive run --environ --config /etc/caddy/Caddyfile --adapter caddyfile
ExecReload=/usr/local/bin/caddy-naive reload --config /etc/caddy/Caddyfile --adapter caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

  /usr/local/bin/caddy-naive validate --config "$CADDYFILE" --adapter caddyfile
  systemctl daemon-reload
  systemctl enable --now caddy-naive.service

  sleep 2
  if ! systemctl is-active --quiet caddy-naive.service; then
    journalctl -u caddy-naive.service -n 50 --no-pager >&2 || true
    die "服务启动失败，日志见上方"
  fi

  if [[ "$reinstall" -eq 1 ]]; then
    printf '\n更新完成。\n'
  else
    printf '\n安装完成。请确认云厂商防火墙已放行 TCP 80、TCP 443、UDP 443。\n'
  fi
  show_config
}

case "$ACTION" in
  install) install_server ;;
  show) need_root; show_config ;;
  status) need_root; systemctl status caddy-naive.service --no-pager ;;
  logs) need_root; journalctl -u caddy-naive.service -n 100 --no-pager ;;
  *) die "用法: $0 [install|show|status|logs]" ;;
esac
