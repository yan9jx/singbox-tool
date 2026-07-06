#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Debian x86_64: share TCP/443 between an existing Nginx/XHTTP site and
# NaiveProxy by using HAProxy's TLS SNI passthrough.
#
# Existing: gjp.ejectors.net -> Nginx/XHTTP
# New:      gjpn.ejectors.net -> Caddy/NaiveProxy
#
# Usage:
#   bash install-naiveproxy-nginx-coexist.sh
#   bash install-naiveproxy-nginx-coexist.sh show
#   bash install-naiveproxy-nginx-coexist.sh status

NAIVE_DOMAIN="${NAIVE_DOMAIN:-gjpn.ejectors.net}"
XHTTP_DOMAIN="${XHTTP_DOMAIN:-gjp.ejectors.net}"
ACTION="${1:-install}"
NGINX_BACKEND_PORT="${NGINX_BACKEND_PORT:-8443}"

STATE_DIR="/etc/naiveproxy"
CREDENTIALS="${STATE_DIR}/credentials"
MARKER="${STATE_DIR}/nginx-coexist"
CADDYFILE="/etc/caddy/Caddyfile"
CADDY_SERVICE="/etc/systemd/system/caddy-naive.service"
HAPROXY_CONFIG="/etc/haproxy/haproxy.cfg"

CADDY_VERSION="v2.11.2-naive"
CADDY_SHA256="19eccb7321dd877a5fb4a3dba6ef1b745185188b616c96cc6201f1a1fc0380a8"
CADDY_URL="https://github.com/klzgrad/forwardproxy/releases/download/${CADDY_VERSION}/caddy-forwardproxy-naive.tar.xz"

TMP_DIR=""
NGINX_BACKUP=""
MUTATION_STARTED=0
INSTALL_OK=0

die() {
  printf '错误: %s\n' "$*" >&2
  exit 1
}

need_root() {
  [[ "$EUID" -eq 0 ]] || die "请以 root 身份运行此脚本"
}

cleanup_or_rollback() {
  local rc=$?
  if [[ "$INSTALL_OK" -ne 1 && "$MUTATION_STARTED" -eq 1 && -n "$NGINX_BACKUP" ]]; then
    printf '\n安装未完成，正在恢复原 Nginx 配置……\n' >&2
    systemctl stop haproxy.service caddy-naive.service 2>/dev/null || true
    tar -xzf "$NGINX_BACKUP" -C / || true
    nginx -t >/dev/null 2>&1 && systemctl restart nginx.service || true
  fi
  [[ -z "$TMP_DIR" ]] || rm -rf "$TMP_DIR"
  exit "$rc"
}
trap cleanup_or_rollback EXIT

load_credentials() {
  [[ -r "$CREDENTIALS" ]] || die "未找到 $CREDENTIALS"
  # Values created by this script contain only DNS-name/hex characters.
  # shellcheck disable=SC1090
  source "$CREDENTIALS"
}

show_config() {
  load_credentials
  local uri
  uri="naive+https://${NAIVE_USER}:${NAIVE_PASS}@${NAIVE_DOMAIN}:443?padding=true#gjpn-naive"
  printf '\nNaive 域名: %s\n用户名: %s\n密码: %s\n\n导入链接:\n%s\n\n' \
    "$NAIVE_DOMAIN" "$NAIVE_USER" "$NAIVE_PASS" "$uri"
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 "$uri" || true
  fi
}

check_dns() {
  local public_ipv4 resolved
  public_ipv4="$(curl -4fsS --max-time 10 https://api.ipify.org || true)"
  resolved="$(getent ahostsv4 "$NAIVE_DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u || true)"
  [[ -n "$resolved" ]] || die "$NAIVE_DOMAIN 尚未解析"

  if [[ -n "$public_ipv4" ]] && ! grep -Fxq "$public_ipv4" <<<"$resolved"; then
    printf '本机公网 IPv4: %s\n%s 解析结果:\n%s\n' \
      "$public_ipv4" "$NAIVE_DOMAIN" "$resolved" >&2
    die "域名没有指向本服务器；Cloudflare 必须设置为仅 DNS"
  fi
}

find_nginx_443_files() {
  nginx -T 2>&1 | awk '
    /^# configuration file / {
      file=$4
      sub(/:$/, "", file)
      next
    }
    /^[[:space:]]*listen[[:space:]]+(443|\[::\]:443)([[:space:];]|$)/ {
      if (file != "") print file
    }
  ' | while IFS= read -r file; do
    realpath "$file"
  done | sort -u
}

move_nginx_to_loopback() {
  local file
  mapfile -t nginx_files < <(find_nginx_443_files)
  [[ "${#nginx_files[@]}" -gt 0 ]] ||
    die "没有在有效 Nginx 配置中找到 443 监听项"

  printf '将以下 Nginx TLS 配置移至 127.0.0.1:%s：\n' "$NGINX_BACKEND_PORT"
  printf '  %s\n' "${nginx_files[@]}"

  for file in "${nginx_files[@]}"; do
    sed -Ei \
      -e "s|^([[:space:]]*)listen[[:space:]]+(0\\.0\\.0\\.0:)?443([^;]*);|\\1listen 127.0.0.1:${NGINX_BACKEND_PORT}\\3; # naive-sni-coexist|" \
      -e 's|^([[:space:]]*)listen[[:space:]]+\[::\]:443([^;]*);|\1# listen [::]:443\2; # naive-sni-coexist|' \
      "$file"
  done

  nginx -t
  # A restart briefly interrupts XHTTP but guarantees that the old wildcard
  # 443 listener is released before HAProxy takes ownership of that port.
  systemctl restart nginx.service

  if ss -H -ltnp "sport = :443" | grep -q nginx; then
    die "修改后 Nginx 仍在占用 443"
  fi
  ss -H -ltnp "sport = :${NGINX_BACKEND_PORT}" | grep -q nginx ||
    die "Nginx 没有在后端端口 ${NGINX_BACKEND_PORT} 监听"
}

write_caddy_config() {
  install -d -m 0755 /etc/caddy /var/www/naive /var/lib/caddy
  chown -R caddy:caddy /var/lib/caddy

  cat >"$CADDYFILE" <<EOF
{
	order forward_proxy before file_server
	auto_https disable_redirects
	log {
		exclude http.log.error
	}
}

:443, $NAIVE_DOMAIN {
	bind 127.0.0.1
	tls {
		issuer acme {
			disable_http_challenge
		}
	}
	encode
	forward_proxy {
		basic_auth $NAIVE_USER $NAIVE_PASS
		hide_ip
		hide_via
		probe_resistance
	}
	file_server {
		root /var/www/naive
	}
}
EOF
  chmod 0644 "$CADDYFILE"

  cat >/var/www/naive/index.html <<'EOF'
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
  chmod 0644 /var/www/naive/index.html

  cat >"$CADDY_SERVICE" <<'EOF'
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
}

write_haproxy_config() {
  local bind_ipv4 global_ipv6 ipv6_line=""
  bind_ipv4="$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  [[ -n "$bind_ipv4" && "$bind_ipv4" != 127.* ]] ||
    die "无法确定服务器的本地 IPv4 监听地址"

  global_ipv6="$(ip -6 -o addr show scope global 2>/dev/null |
    awk 'NR==1 {split($4,a,"/"); print a[1]}' || true)"
  if [[ -n "$global_ipv6" ]]; then
    ipv6_line="	bind [${global_ipv6}]:443 v6only"
  fi

  if [[ -f "$HAPROXY_CONFIG" && ! -f "$MARKER" ]]; then
    cp -a "$HAPROXY_CONFIG" "${STATE_DIR}/haproxy.cfg.before-naive"
  fi

  cat >"$HAPROXY_CONFIG" <<EOF
global
	log /dev/log local0
	log /dev/log local1 notice
	user haproxy
	group haproxy
	daemon
	stats socket /run/haproxy/admin.sock mode 660 level admin

defaults
	log global
	mode tcp
	option tcplog
	timeout connect 10s
	timeout client 1h
	timeout server 1h

frontend tls_sni_443
	bind ${bind_ipv4}:443
${ipv6_line}
	tcp-request inspect-delay 5s
	tcp-request content accept if { req.ssl_hello_type 1 }
	acl is_naive req.ssl_sni -i ${NAIVE_DOMAIN}
	use_backend naive_tls if is_naive
	default_backend nginx_xhttp_tls

backend naive_tls
	server naive 127.0.0.1:443 check

backend nginx_xhttp_tls
	server nginx 127.0.0.1:${NGINX_BACKEND_PORT} check
EOF

  /usr/sbin/haproxy -c -f "$HAPROXY_CONFIG"

  install -d -m 0755 /etc/systemd/system/haproxy.service.d
  cat >/etc/systemd/system/haproxy.service.d/naive-coexist.conf <<'EOF'
[Unit]
After=nginx.service caddy-naive.service
Wants=nginx.service caddy-naive.service
EOF
}

install_server() {
  need_root
  [[ -r /etc/os-release ]] || die "无法识别操作系统"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "debian" ]] || die "此脚本仅支持 Debian"
  [[ "$(uname -m)" == "x86_64" ]] ||
    die "当前架构 $(uname -m) 不受官方预编译 Caddy-naive 支持"
  [[ "$NAIVE_DOMAIN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] ||
    die "Naive 域名格式错误"
  [[ "$XHTTP_DOMAIN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] ||
    die "XHTTP 域名格式错误"

  if [[ -f "$MARKER" ]]; then
    printf '共存版已经安装，无需重复修改 Nginx。\n'
    show_config
    return
  fi

  command -v nginx >/dev/null || die "未安装 Nginx"
  nginx -t
  systemctl is-active --quiet nginx.service || die "Nginx 服务未运行"
  nginx -T 2>&1 | grep -Eq "server_name[[:space:]]+[^;]*${XHTTP_DOMAIN//./\\.}" ||
    die "有效 Nginx 配置中未找到 $XHTTP_DOMAIN"
  ss -H -ltnp "sport = :443" | grep -q nginx ||
    die "当前 443 不是由 Nginx 监听"

  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl xz-utils tar openssl qrencode iproute2 haproxy
  systemctl stop haproxy.service 2>/dev/null || true

  check_dns

  if [[ -e /etc/haproxy/haproxy.cfg && -s /etc/haproxy/haproxy.cfg ]] &&
     systemctl is-enabled --quiet haproxy.service 2>/dev/null &&
     grep -Eq '^[[:space:]]*(frontend|listen)[[:space:]]+' /etc/haproxy/haproxy.cfg; then
    die "检测到已有 HAProxy 业务配置，为避免覆盖已停止安装"
  fi

  TMP_DIR="$(mktemp -d)"
  curl -fL --retry 3 --connect-timeout 15 "$CADDY_URL" -o "$TMP_DIR/caddy.tar.xz"
  printf '%s  %s\n' "$CADDY_SHA256" "$TMP_DIR/caddy.tar.xz" |
    sha256sum --check --status || die "Caddy-naive SHA-256 校验失败"
  tar -xJf "$TMP_DIR/caddy.tar.xz" -C "$TMP_DIR"
  [[ -x "$TMP_DIR/caddy-forwardproxy-naive/caddy" ]] ||
    die "下载包中没有 Caddy 可执行文件"
  install -m 0755 "$TMP_DIR/caddy-forwardproxy-naive/caddy" /usr/local/bin/caddy-naive

  if ! getent group caddy >/dev/null; then
    groupadd --system caddy
  fi
  if ! id caddy >/dev/null 2>&1; then
    useradd --system --gid caddy --create-home --home-dir /var/lib/caddy \
      --shell /usr/sbin/nologin --comment "Caddy web server" caddy
  fi

  install -d -m 0700 "$STATE_DIR"
  NAIVE_USER="naive_$(openssl rand -hex 4)"
  NAIVE_PASS="$(openssl rand -hex 18)"
  cat >"$CREDENTIALS" <<EOF
NAIVE_DOMAIN=$NAIVE_DOMAIN
XHTTP_DOMAIN=$XHTTP_DOMAIN
NAIVE_USER=$NAIVE_USER
NAIVE_PASS=$NAIVE_PASS
EOF
  chmod 0600 "$CREDENTIALS"

  write_caddy_config
  /usr/local/bin/caddy-naive validate --config "$CADDYFILE" --adapter caddyfile
  write_haproxy_config

  NGINX_BACKUP="${STATE_DIR}/nginx-before-naive-$(date +%Y%m%d-%H%M%S).tar.gz"
  tar -czf "$NGINX_BACKUP" -C / etc/nginx
  MUTATION_STARTED=1

  move_nginx_to_loopback

  systemctl daemon-reload
  systemctl enable --now caddy-naive.service
  systemctl enable --now haproxy.service

  systemctl is-active --quiet nginx.service || die "Nginx/XHTTP 未运行"
  systemctl is-active --quiet caddy-naive.service || die "NaiveProxy 未运行"
  systemctl is-active --quiet haproxy.service || die "HAProxy 未运行"

  touch "$MARKER"
  chmod 0600 "$MARKER"
  INSTALL_OK=1
  MUTATION_STARTED=0
  printf '\n安装完成：XHTTP 与 NaiveProxy 已按域名共用 TCP/443。\n'
  printf '本方案为 TLS 透明分流，不支持 Naive QUIC/UDP 443。\n'
  show_config
}

status_all() {
  need_root
  systemctl --no-pager --full status nginx.service caddy-naive.service haproxy.service
}

case "$ACTION" in
  install) install_server ;;
  show) need_root; INSTALL_OK=1; show_config ;;
  status) INSTALL_OK=1; status_all ;;
  logs)
    need_root
    INSTALL_OK=1
    journalctl -u caddy-naive.service -u haproxy.service -n 100 --no-pager
    ;;
  *) die "用法: $0 [install|show|status|logs]" ;;
esac

INSTALL_OK=1
