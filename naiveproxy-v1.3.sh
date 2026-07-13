#!/usr/bin/env bash
# NaiveProxy 独立安装与维护脚本，适用于 Debian/Ubuntu。
# 节点信息保存在 /etc/naiveproxy/node-info.env，请妥善保护。
# 优先复用 shared-caddy 的 TCP/443；若 443 被其他服务占用，再自动选择备用端口。
# Caddy 自动申请和续期证书，支持 NaiveProxy 与 File Browser 使用不同域名共用 443。
set -Eeuo pipefail

SCRIPT_VERSION="v1.15"
INSTALL_DIR="/etc/naiveproxy"
INFO_FILE="$INSTALL_DIR/node-info.env"
CADDY_DIR="/etc/caddy-naive"
CADDYFILE="$CADDY_DIR/Caddyfile"
CADDY_SITE_DIR="$CADDY_DIR/sites"
CADDY_ROUTE_DIR="$CADDY_DIR/routes"
CADDY_SERVICE="shared-caddy"
CADDY_SERVICE_FILE="/etc/systemd/system/${CADDY_SERVICE}.service"
BIN="/usr/local/bin/caddy-naive"
MANAGER="/usr/local/sbin/naiveproxy-manager"
SERVICE_FILE="$CADDY_SERVICE_FILE"
UPDATE_SERVICE="/etc/systemd/system/naiveproxy-update.service"
UPDATE_TIMER="/etc/systemd/system/naiveproxy-update.timer"
WEB_ROOT="/var/www/naiveproxy"
SERVICE_USER="naiveproxy"
CADDY_STATE_DIR="/var/lib/shared-caddy"
CADDY_DATA_DIR="$CADDY_STATE_DIR/data"
CADDY_CONFIG_DIR="$CADDY_STATE_DIR/config"
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
  for cmd in curl jq openssl qrencode ss getent tar xz sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  (( ${#missing[@]} == 0 )) && return
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl jq openssl qrencode iproute2 libc-bin ca-certificates xz-utils tar coreutils tzdata
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

shared_caddy_owns_port() {
  local port="$1" pid
  pid="$(systemctl show "$SERVICE_NAME" -p MainPID --value 2>/dev/null || true)"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  ss -H -lntp "sport = :$port" 2>/dev/null | grep -q "pid=$pid,"
}

choose_fallback_port() {
  local candidate
  for candidate in 8443 9443 10443 11443 12443 13443 14443 15443; do
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

choose_naive_port() {
  # 443 空闲时直接使用；若 443 正由本脚本管理的 shared-caddy 监听，也可安全复用。
  if ! port_is_listening 443 || shared_caddy_owns_port 443; then
    printf '443'
  else
    choose_fallback_port
  fi
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
    useradd --system --gid "$SERVICE_USER" --home-dir "$CADDY_STATE_DIR" --no-create-home \
      --shell /usr/sbin/nologin "$SERVICE_USER"

  install -d -m 750 -o root -g "$SERVICE_USER" "$INSTALL_DIR"
  install -d -m 750 -o root -g "$SERVICE_USER" \
    "$CADDY_DIR" "$CADDY_SITE_DIR" "$CADDY_ROUTE_DIR"
  install -d -m 700 -o "$SERVICE_USER" -g "$SERVICE_USER" \
    "$CADDY_STATE_DIR" "$CADDY_DATA_DIR" "$CADDY_CONFIG_DIR"

  # shared-caddy 可能同时读取 File Browser 生成的配置，统一授予服务组只读权限。
  find "$CADDY_DIR" -type d -exec chgrp "$SERVICE_USER" {} + -exec chmod g+rx {} +
  find "$CADDY_DIR" -type f \
    \( -name 'Caddyfile' -o -name '*.caddy' \) \
    -exec chgrp "$SERVICE_USER" {} + -exec chmod g+r {} +

  # 兼容旧安装或 root 运行期间生成的证书缓存。
  chown -R "$SERVICE_USER:$SERVICE_USER" "$CADDY_STATE_DIR"
  chmod -R u+rwX,go-rwx "$CADDY_STATE_DIR"
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
  local domain="$1" port="$2" username="$3" password="$4" cover_domain="$5" site_file route_file site_address
  site_file="${CADDY_SITE_DIR}/naive-${domain}.caddy"
  route_file="${CADDY_ROUTE_DIR}/${domain}/naive.caddy"

  install -d -m 750 -o root -g "$SERVICE_USER" \
    "$CADDY_DIR" "$CADDY_SITE_DIR" "$CADDY_ROUTE_DIR/$domain"

  if [[ -f "${CADDY_SITE_DIR}/filebrowser-${domain}.caddy" && "$port" == "443" ]]; then
    die "NaiveProxy and File Browser cannot use the same hostname on shared TCP/443. Use separate subdomains."
  fi

  cat >"$CADDYFILE" <<EOF
{
    admin off
    auto_https disable_redirects
    servers {
        protocols h1 h2
    }
    log {
        output discard
    }
}

import ${CADDY_SITE_DIR}/*.caddy
EOF

  # 旧版排障时可能加入过该选项；v1.2 必须保留自动证书管理。
  sed -i '/^[[:space:]]*auto_https[[:space:]]\+disable_certs[[:space:]]*$/d' "$CADDYFILE"

  rm -f "$route_file"
  if [[ "$port" == "443" ]]; then
    site_address=":443, $domain"
  else
    site_address="$domain:$port"
  fi
  cat >"$site_file" <<EOF
$site_address {
    encode
    route {
        forward_proxy {
            basic_auth $username $password
            hide_ip
            hide_via
            probe_resistance
        }
EOF
  if [[ -n "$cover_domain" ]]; then
    cat >>"$site_file" <<EOF
        reverse_proxy https://${cover_domain} {
            header_up Host ${cover_domain}
        }
EOF
  else
    cat >>"$site_file" <<EOF
        root * $WEB_ROOT
        file_server
EOF
  fi
  cat >>"$site_file" <<'EOF'
    }
}
EOF
  chown root:"$SERVICE_USER" "$site_file"
  chmod 640 "$site_file"

  chown root:"$SERVICE_USER" "$CADDYFILE"
  chmod 640 "$CADDYFILE"
}

remove_legacy_filebrowser_naive_connect() {
  local site="$1" tmp
  grep -qE '^[[:space:]]*@naive_connect[[:space:]]+method[[:space:]]+CONNECT[[:space:]]*$' "$site" || return 0

  tmp="$(mktemp)"
  if ! awk '
    BEGIN { state = 0; depth = 0; removed = 0; failed = 0 }
    state == 0 && $0 ~ /^[[:space:]]*@naive_connect[[:space:]]+method[[:space:]]+CONNECT[[:space:]]*$/ {
      state = 1
      removed = 1
      next
    }
    state == 1 {
      if ($0 ~ /^[[:space:]]*$/) next
      if ($0 ~ /^[[:space:]]*handle[[:space:]]+@naive_connect[[:space:]]*\{[[:space:]]*$/) {
        line = $0
        depth = gsub(/\{/, "{", line) - gsub(/\}/, "}", line)
        state = depth > 0 ? 2 : 0
        next
      }
      failed = 1
      exit
    }
    state == 2 {
      line = $0
      depth += gsub(/\{/, "{", line) - gsub(/\}/, "}", line)
      if (depth <= 0) state = 0
      next
    }
    { print }
    END {
      if (failed) exit 2
      if (state != 0 || !removed) exit 3
    }
  ' "$site" >"$tmp"; then
    rm -f "$tmp"
    die "无法安全迁移 File Browser 旧版 Naive CONNECT 配置：$site"
  fi

  grep -qE '^[[:space:]]*@naive_connect[[:space:]]+method[[:space:]]+CONNECT[[:space:]]*$' "$tmp" && {
    rm -f "$tmp"
    die "File Browser 旧版 Naive CONNECT 配置未清理完整：$site"
  }
  install -m 640 -o root -g "$SERVICE_USER" "$tmp" "$site"
  rm -f "$tmp"
  echo "已将 $site 中的旧版 Naive CONNECT 规则迁移到独立路由片段。"
}

configure_filebrowser_naive_connect() {
  local username="$1" password="$2" site domain route_dir route_file

  # Refuse before touching any route if an older File Browser site lacks the shared-route hook.
  for site in "$CADDY_SITE_DIR"/filebrowser-*.caddy; do
    [[ -f "$site" ]] || continue
    domain="${site##*/filebrowser-}"
    domain="${domain%.caddy}"
    grep -Fq "import ${CADDY_ROUTE_DIR}/${domain}/*.caddy" "$site" ||
      die "File Browser site $domain does not support shared Caddy route fragments; it was left unchanged."
  done

  for site in "$CADDY_SITE_DIR"/filebrowser-*.caddy; do
    [[ -f "$site" ]] || continue
    domain="${site##*/filebrowser-}"
    domain="${domain%.caddy}"
    remove_legacy_filebrowser_naive_connect "$site"
    grep -qw "$domain" /etc/hosts || echo "127.0.0.1 $domain # shared-caddy-local" >>/etc/hosts
    route_dir="${CADDY_ROUTE_DIR}/${domain}"
    route_file="${route_dir}/naive-connect.caddy"
    install -d -m 750 -o root -g "$SERVICE_USER" "$route_dir"
    cat >"$route_file" <<EOF
@naive_connect method CONNECT
handle @naive_connect {
        forward_proxy {
            basic_auth $username $password
            hide_ip
            hide_via
            probe_resistance
            acl {
                allow $domain
                allow 127.0.0.1/32
                deny 10.0.0.0/8 127.0.0.0/8 172.16.0.0/12 192.168.0.0/16 ::1/128 fe80::/10
                allow all
            }
        }
}
EOF
    chown root:"$SERVICE_USER" "$route_file"
    chmod 640 "$route_file"
  done
}

write_service() {
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=NaiveProxy Caddy forward proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=$SERVICE_USER
Group=$SERVICE_USER
Environment=XDG_DATA_HOME=$CADDY_DATA_DIR
Environment=XDG_CONFIG_HOME=$CADDY_CONFIG_DIR
ExecStartPre=+/bin/chown -R $SERVICE_USER:$SERVICE_USER $CADDY_STATE_DIR
ExecStartPre=+/bin/chmod -R u+rwX,go-rwx $CADDY_STATE_DIR
ExecStart=$BIN run --environ --config $CADDYFILE --adapter caddyfile
ExecReload=$BIN reload --config $CADDYFILE --adapter caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
Restart=on-failure
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
PrivateTmp=true
ReadWritePaths=$CADDY_STATE_DIR
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
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

verify_filebrowser_precedence() {
  local port="$1" site domain tmp host_index fallback_index
  [[ "$port" == "443" ]] || return 0

  for site in "$CADDY_SITE_DIR"/filebrowser-*.caddy; do
    [[ -f "$site" ]] || continue
    domain="${site##*/filebrowser-}"
    domain="${domain%.caddy}"
    tmp="$(mktemp)"
    "$BIN" adapt --config "$CADDYFILE" --adapter caddyfile --pretty >"$tmp" || {
      rm -f "$tmp"
      die "Caddy route priority validation failed."
    }
    host_index="$(jq -r --arg domain "$domain" '[.apps.http.servers[]?.routes | to_entries[] | select(any(.value.match[]?; ((.host? // []) | index($domain)))) | .key] | min // empty' "$tmp")"
    fallback_index="$(jq -r '[.apps.http.servers[]?.routes | to_entries[] | select((.value.match // []) | length == 0) | .key] | min // empty' "$tmp")"
    rm -f "$tmp"
    [[ "$host_index" =~ ^[0-9]+$ && "$fallback_index" =~ ^[0-9]+$ && "$host_index" -lt "$fallback_index" ]] ||
      die "Caddy route order is unsafe: File Browser must precede the NaiveProxy :443 fallback route."
  done
}

verify_filebrowser_via_naive() {
  local port="$1" domain="$2" username="$3" password="$4" site filebrowser_domain status
  [[ "$port" == "443" ]] || return 0
  for site in "$CADDY_SITE_DIR"/filebrowser-*.caddy; do
    [[ -f "$site" ]] || continue
    filebrowser_domain="${site##*/filebrowser-}"
    filebrowser_domain="${filebrowser_domain%.caddy}"
    status="$(curl -4ksS --proxy-insecure --noproxy '' --proxy "https://${username}:${password}@${domain}:${port}" --connect-timeout 15 --max-time 30 -o /dev/null -w '%{http_code}' "https://${filebrowser_domain}/login?redirect=/files" || true)"
    [[ "$status" =~ ^(200|301|302|303|307|308)$ ]] || return 1
  done
}

make_uri() {
  local domain="$1" port="$2" username="$3" password="$4" name="$5"
  printf 'naive+https://%s:%s@%s:%s?sni=%s#%s' \
    "$(urlencode "$username")" "$(urlencode "$password")" "$domain" "$port" \
    "$(urlencode "$domain")" "$(urlencode "$name")"
}

write_info() {
  local name="$1" domain="$2" port="$3" username="$4" password="$5" version="$6" cover_domain="$7" uri
  uri="$(make_uri "$domain" "$port" "$username" "$password" "$name")"
  cat >"$INFO_FILE" <<EOF
NODE_NAME='$name'
DOMAIN='$domain'
PORT='$port'
USERNAME='$username'
PASSWORD='$password'
SERVER_VERSION='$version'
COVER_DOMAIN='$cover_domain'
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
  systemctl enable "$SERVICE_NAME" >/dev/null
  if ! systemctl restart "$SERVICE_NAME"; then
    journalctl -u "$SERVICE_NAME" -n 80 --no-pager >&2 || true
    die "NaiveProxy 启动命令失败。"
  fi
  systemctl is-active --quiet "$SERVICE_NAME" || {
    journalctl -u "$SERVICE_NAME" -n 80 --no-pager >&2 || true
    die "NaiveProxy 启动失败。"
  }
  verify_filebrowser_precedence "$port"
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

  local domain ip port name username password cover_domain tmp
  read -r -p "请输入已解析到本机的 NaiveProxy 域名：" domain
  domain="${domain#https://}"; domain="${domain%%/*}"; domain="${domain,,}"
  valid_domain "$domain" || die "域名格式不正确。"
  ip="$(public_ipv4)"
  [[ -n "$ip" ]] || die "无法检测本机公网 IPv4。"
  check_domain "$domain" "$ip"

  read -r -p "反代伪装网站域名（例如 www.example.com；直接回车不使用）: " cover_domain
  cover_domain="${cover_domain#https://}"; cover_domain="${cover_domain#http://}"
  cover_domain="${cover_domain%%/*}"; cover_domain="${cover_domain,,}"
  if [[ -n "$cover_domain" ]]; then
    valid_domain "$cover_domain" || die "伪装网站域名格式不正确。"
    [[ "$cover_domain" != "$domain" ]] || die "伪装网站不能与 NaiveProxy 域名相同，以免形成反向代理循环。"
  fi

  systemctl stop naiveproxy 2>/dev/null || true
  ensure_service_user
  port="$(choose_naive_port)"
  echo "自动选择 NaiveProxy 监听端口：TCP/$port"
  if [[ "$port" == "443" ]] && shared_caddy_owns_port 443; then
    echo "检测到 shared-caddy 已监听 443，将按域名复用同一端口。"
  fi

  read -r -p "节点名称 [NaiveProxy]: " name
  name="${name:-NaiveProxy}"; name="${name//\'/}"; name="${name//$'\n'/}"
  username="naive$(openssl rand -hex 4)"
  password="$(openssl rand -hex 24)"

  write_decoy_site
  write_caddyfile "$domain" "$port" "$username" "$password" "$cover_domain"
  configure_filebrowser_naive_connect "$username" "$password"
  write_service

  tmp="$(mktemp -d)"
  prepare_latest_binary "$tmp"
  validate_caddy "$RELEASE_BINARY"
  install -m 755 "$RELEASE_BINARY" "$BIN"
  rm -rf "$tmp"

  write_info "$name" "$domain" "$port" "$username" "$password" "$RELEASE_TAG" "$cover_domain"
  open_firewall_port "$port"
  start_service "$port"
  verify_filebrowser_via_naive "$port" "$domain" "$username" "$password" ||
    die "NaiveProxy cannot reach File Browser through the shared Caddy configuration. The new configuration was not accepted."
  enable_auto_update

  echo
  echo "NaiveProxy 已安装完成。Caddy 将自动申请并续期证书。"
  echo "请确认云厂商安全组已放行 TCP/$port；自动签发通常还需要 TCP/80 或 TCP/443 可达。"
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
  local name domain port username password version cover_domain
  name="$(info_value NODE_NAME)"
  domain="$(info_value DOMAIN)"
  port="$(info_value PORT)"
  username="$(info_value USERNAME)"
  version="$(info_value SERVER_VERSION)"
  cover_domain="$(info_value COVER_DOMAIN)"
  password="$(openssl rand -hex 24)"
  write_caddyfile "$domain" "$port" "$username" "$password" "$cover_domain"
  configure_filebrowser_naive_connect "$username" "$password"
  validate_caddy "$BIN"
  systemctl restart "$SERVICE_NAME"
  systemctl is-active --quiet "$SERVICE_NAME" || die "重置密码后服务启动失败。"
  write_info "$name" "$domain" "$port" "$username" "$password" "$version" "$cover_domain"
  verify_filebrowser_via_naive "$port" "$domain" "$username" "$password" ||
    die "NaiveProxy cannot reach File Browser through the shared Caddy configuration."
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

repair_shared_caddy() {
  require_install
  local domain port username password cover_domain
  domain="$(info_value DOMAIN)"
  port="$(info_value PORT)"
  username="$(info_value USERNAME)"
  password="$(info_value PASSWORD)"
  cover_domain="$(info_value COVER_DOMAIN)"
  valid_domain "$domain" || die "Saved NaiveProxy domain is invalid."
  validate_port "$port" || die "Saved NaiveProxy port is invalid."

  ensure_service_user
  write_decoy_site
  write_caddyfile "$domain" "$port" "$username" "$password" "$cover_domain"
  configure_filebrowser_naive_connect "$username" "$password"
  write_service
  validate_caddy "$BIN"
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null
  systemctl restart "$SERVICE_NAME"
  systemctl is-active --quiet "$SERVICE_NAME" || die "shared-caddy did not start after repair."
  verify_filebrowser_precedence "$port"
  port_is_listening "$port" || die "shared-caddy is not listening on TCP/$port after repair."
  verify_filebrowser_via_naive "$port" "$domain" "$username" "$password" ||
    die "NaiveProxy cannot reach File Browser through the shared Caddy configuration."
  echo "shared-caddy repair completed."
}

uninstall_node() {
  confirm_yes "是否卸载本脚本创建的 NaiveProxy？" || return 0
  local domain site filebrowser_domain other_sites=false
  domain="$(info_value DOMAIN 2>/dev/null || true)"

  systemctl disable --now naiveproxy-update.timer 2>/dev/null || true
  if [[ -n "$domain" ]]; then
    rm -f "${CADDY_ROUTE_DIR}/${domain}/naive.caddy" "${CADDY_SITE_DIR}/naive-${domain}.caddy"
  fi
  for site in "$CADDY_SITE_DIR"/filebrowser-*.caddy; do
    [[ -f "$site" ]] || continue
    filebrowser_domain="${site##*/filebrowser-}"
    filebrowser_domain="${filebrowser_domain%.caddy}"
    rm -f "${CADDY_ROUTE_DIR}/${filebrowser_domain}/naive-connect.caddy"
  done
  rm -f "$UPDATE_SERVICE" "$UPDATE_TIMER" "$MANAGER"
  rm -rf "$INSTALL_DIR" "$WEB_ROOT"

  if find "$CADDY_SITE_DIR" -maxdepth 1 -type f -name '*.caddy' -print -quit 2>/dev/null | grep -q .; then
    other_sites=true
  fi

  if [[ "$other_sites" == true ]]; then
    systemctl daemon-reload
    if [[ -x "$BIN" && -f "$CADDYFILE" ]]; then
      validate_caddy "$BIN"
      systemctl restart "$SERVICE_NAME" || true
    fi
    echo "NaiveProxy 已卸载；shared-caddy、自动证书和其他站点已保留。"
  else
    systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$BIN"
    rm -rf "$CADDY_DIR" "$CADDY_STATE_DIR"
    userdel "$SERVICE_USER" 2>/dev/null || true
    groupdel "$SERVICE_USER" 2>/dev/null || true
    systemctl daemon-reload
    echo "NaiveProxy 与空闲的 shared-caddy 已卸载。"
  fi
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
  repair) repair_shared_caddy ;;
  auto-update-on) enable_auto_update ;;
  auto-update-off) disable_auto_update ;;
  uninstall) uninstall_node ;;
  *) menu ;;
esac
