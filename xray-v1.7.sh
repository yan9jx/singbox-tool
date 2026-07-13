#!/usr/bin/env bash
# VLESS + XHTTP + TLS 独立安装脚本，适用于 Debian/Ubuntu。
# 公网 TCP/443 由 shared-caddy 持有，可与云盘/File Browser、NaiveProxy 或其他反代站点共享。
# Xray 只监听 127.0.0.1 本地端口。
set -Eeuo pipefail

SCRIPT_VERSION="v2.5"
XRAY_ROOT="/opt/xray-xhttp"
XRAY_BIN="$XRAY_ROOT/xray"
XRAY_DIR="/etc/xray-xhttp"
XRAY_CONFIG="$XRAY_DIR/config.json"
XRAY_INFO="$XRAY_DIR/node-info.env"
XRAY_SERVICE="/etc/systemd/system/xray-xhttp.service"
CADDY_BIN="/usr/local/bin/caddy-naive"
CADDY_DIR="/etc/caddy-naive"
CADDYFILE="$CADDY_DIR/Caddyfile"
CADDY_SITE_DIR="$CADDY_DIR/sites"
CADDY_ROUTE_DIR="$CADDY_DIR/routes"
CADDY_SERVICE="shared-caddy"
CADDY_SERVICE_FILE="/etc/systemd/system/${CADDY_SERVICE}.service"
CADDY_SERVICE_USER="naiveproxy"
CADDY_STATE_DIR="/var/lib/shared-caddy"
CADDY_DATA_DIR="${CADDY_STATE_DIR}/data"
CADDY_CONFIG_DIR="${CADDY_STATE_DIR}/config"
CADDY_RELEASE_API="https://api.github.com/repos/klzgrad/forwardproxy/releases/latest"
CADDY_RELEASE_ASSET="caddy-forwardproxy-naive.tar.xz"
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

urlencode() { jq -nr --arg value "$1" '$value|@uri'; }

generate_vless_encryption_pair() {
  local output decryption encryption
  output="$("$XRAY_BIN" vlessenc)" || die "VLESS Encryption 参数生成失败。"
  decryption="$(sed -n 's/^[[:space:]]*"decryption":[[:space:]]*"\([^"]*\)"[[:space:]]*$/\1/p' <<<"$output" | head -n1)"
  encryption="$(sed -n 's/^[[:space:]]*"encryption":[[:space:]]*"\([^"]*\)"[[:space:]]*$/\1/p' <<<"$output" | head -n1)"
  [[ "$decryption" =~ ^[A-Za-z0-9._-]+$ && "$encryption" =~ ^[A-Za-z0-9._-]+$ ]] ||
    die "当前 Xray-core 返回的 VLESS Encryption 参数格式不受此脚本支持。"
  printf '%s\t%s\n' "$decryption" "$encryption"
}

valid_domain() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

install_deps() {
  command -v apt-get >/dev/null 2>&1 || die "仅支持 Debian/Ubuntu（apt-get）。"
  local missing=() cmd
  for cmd in curl unzip openssl qrencode getent ss jq tar xz sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  (( ${#missing[@]} == 0 )) && return
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl unzip openssl qrencode ca-certificates iproute2 libc-bin tzdata jq xz-utils tar coreutils
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

check_domain() {
  local domain="$1" ip="$2" resolved
  resolved="$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u | head -n1 || true)"
  [[ -n "$resolved" ]] || die "未检测到 $domain 的 A 记录。"
  [[ "$resolved" == "$ip" ]] || die "$domain 当前解析到 $resolved，不是本机公网 IPv4 $ip。"
}

shared_caddy_owns_port() {
  local port="$1" pid
  pid="$(systemctl show "$CADDY_SERVICE" -p MainPID --value 2>/dev/null || true)"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  ss -H -lntp "sport = :$port" 2>/dev/null | grep -q "pid=$pid,"
}

ensure_443_available_for_shared_caddy() {
  if ! ss -H -lntp 'sport = :443' 2>/dev/null | grep -q .; then
    return
  fi
  shared_caddy_owns_port 443 && return
  ss -H -lntp 'sport = :443' >&2 || true
  if systemctl is-active --quiet caddy 2>/dev/null ||
    ss -H -ltnp 'sport = :443' 2>/dev/null | grep -qE 'caddy|caddy-naive'; then
    die "检测到另一个 Caddy 正在占用 TCP/443。为避免覆盖它的配置，本脚本不会接管；请先迁移为 shared-caddy，或改用空闲端口。"
  fi
  die "TCP/443 is occupied by a non shared-caddy service. Stop or move that service before installing XHTTP."
}

fetch_caddy_release() {
  local release_json
  release_json="$(curl -fsSL --max-time 30 "$CADDY_RELEASE_API")" || die "Failed to query Caddy/NaiveProxy release."
  CADDY_RELEASE_TAG="$(jq -er '.tag_name' <<<"$release_json")" || die "Caddy/NaiveProxy release has no tag."
  CADDY_RELEASE_URL="$(jq -er --arg name "$CADDY_RELEASE_ASSET" '.assets[] | select(.name == $name) | .browser_download_url' <<<"$release_json")" ||
    die "Caddy/NaiveProxy release is missing $CADDY_RELEASE_ASSET."
  CADDY_RELEASE_DIGEST="$(jq -er --arg name "$CADDY_RELEASE_ASSET" '.assets[] | select(.name == $name) | .digest // ""' <<<"$release_json" |
    sed 's/^sha256://')" || true
}

ensure_caddy_binary() {
  [[ -x "$CADDY_BIN" ]] && return

  local tmp archive binary
  tmp="$(mktemp -d)"
  archive="$tmp/$CADDY_RELEASE_ASSET"
  fetch_caddy_release
  curl -fL --retry 3 "$CADDY_RELEASE_URL" -o "$archive"
  if [[ -n "${CADDY_RELEASE_DIGEST:-}" ]]; then
    printf '%s  %s\n' "$CADDY_RELEASE_DIGEST" "$archive" | sha256sum -c - >/dev/null ||
      die "Caddy/NaiveProxy archive SHA-256 verification failed."
  fi
  tar -xJf "$archive" -C "$tmp"
  binary="$tmp/caddy-forwardproxy-naive/caddy"
  [[ -x "$binary" ]] || die "Caddy/NaiveProxy archive is incomplete."
  install -m 755 "$binary" "$CADDY_BIN"
  rm -rf "$tmp"
}

ensure_shared_caddy_user() {
  getent group "$CADDY_SERVICE_USER" >/dev/null 2>&1 ||
    groupadd --system "$CADDY_SERVICE_USER"
  id "$CADDY_SERVICE_USER" >/dev/null 2>&1 ||
    useradd --system --gid "$CADDY_SERVICE_USER" --home-dir "$CADDY_STATE_DIR" \
      --no-create-home --shell /usr/sbin/nologin "$CADDY_SERVICE_USER"

  install -d -m 750 -o root -g "$CADDY_SERVICE_USER" "$CADDY_DIR" "$CADDY_SITE_DIR" "$CADDY_ROUTE_DIR"
  install -d -m 700 -o "$CADDY_SERVICE_USER" -g "$CADDY_SERVICE_USER" \
    "$CADDY_STATE_DIR" "$CADDY_DATA_DIR" "$CADDY_CONFIG_DIR"
  find "$CADDY_DIR" -type d -exec chgrp "$CADDY_SERVICE_USER" {} + -exec chmod g+rx {} +
  find "$CADDY_DIR" -type f \( -name 'Caddyfile' -o -name '*.caddy' \) \
    -exec chgrp "$CADDY_SERVICE_USER" {} + -exec chmod g+r {} +
  chown -R "$CADDY_SERVICE_USER:$CADDY_SERVICE_USER" "$CADDY_STATE_DIR"
  chmod -R u+rwX,go-rwx "$CADDY_STATE_DIR"
}

ensure_shared_caddy_base() {
  ensure_shared_caddy_user
  install -d -m 750 -o root -g "$CADDY_SERVICE_USER" "$CADDY_DIR" "$CADDY_SITE_DIR" "$CADDY_ROUTE_DIR"
  # 所有脚本使用同一主配置；forward_proxy 只能放在 Naive 的 route 内。
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
  chown root:"$CADDY_SERVICE_USER" "$CADDYFILE"
  chmod 640 "$CADDYFILE"
}

write_shared_caddy_service() {
  cat >"$CADDY_SERVICE_FILE" <<EOF
[Unit]
Description=Shared Caddy reverse proxy and NaiveProxy entry
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=${CADDY_SERVICE_USER}
Group=${CADDY_SERVICE_USER}
Environment=XDG_DATA_HOME=${CADDY_DATA_DIR}
Environment=XDG_CONFIG_HOME=${CADDY_CONFIG_DIR}
ExecStartPre=+/bin/chown -R ${CADDY_SERVICE_USER}:${CADDY_SERVICE_USER} ${CADDY_STATE_DIR}
ExecStartPre=+/bin/chmod -R u+rwX,go-rwx ${CADDY_STATE_DIR}
ExecStart=${CADDY_BIN} run --environ --config ${CADDYFILE} --adapter caddyfile
TimeoutStopSec=5s
Restart=on-failure
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
LimitNOFILE=1048576
PrivateTmp=true
ReadWritePaths=${CADDY_STATE_DIR}
NoNewPrivileges=true
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
}

verify_filebrowser_precedence() {
  local site domain tmp host_index fallback_index naive_site
  naive_site="$(find "$CADDY_SITE_DIR" -maxdepth 1 -type f -name "naive-*.caddy" -print -quit 2>/dev/null || true)"
  [[ -n "$naive_site" ]] || return 0
  grep -qE '^:443([,[:space:]]|$)' "$naive_site" || return 0

  for site in "$CADDY_SITE_DIR"/filebrowser-*.caddy; do
    [[ -f "$site" ]] || continue
    domain="${site##*/filebrowser-}"
    domain="${domain%.caddy}"
    tmp="$(mktemp)"
    "$CADDY_BIN" adapt --config "$CADDYFILE" --adapter caddyfile --pretty >"$tmp" || { rm -f "$tmp"; die "Caddy route priority check failed."; }
    host_index="$(jq -r --arg domain "$domain" '[.apps.http.servers[]?.routes | to_entries[] | select(any(.value.match[]?; ((.host? // []) | index($domain)))) | .key] | min // empty' "$tmp")"
    fallback_index="$(jq -r '[.apps.http.servers[]?.routes | to_entries[] | select((.value.match // []) | length == 0) | .key] | min // empty' "$tmp")"
    rm -f "$tmp"
    [[ "$host_index" =~ ^[0-9]+$ && "$fallback_index" =~ ^[0-9]+$ && "$host_index" -lt "$fallback_index" ]] ||
      die "Caddy route priority check failed: File Browser must precede the Naive :443 fallback route."
  done
}

restart_shared_caddy() {
  "$CADDY_BIN" validate --config "$CADDYFILE" --adapter caddyfile >/dev/null ||
    die "shared-caddy config validation failed."
  systemctl daemon-reload
  systemctl enable "$CADDY_SERVICE" >/dev/null
  if systemctl is-active --quiet "$CADDY_SERVICE"; then
    systemctl restart "$CADDY_SERVICE"
  else
    systemctl start "$CADDY_SERVICE"
  fi
  systemctl is-active --quiet "$CADDY_SERVICE" || {
    journalctl -u "$CADDY_SERVICE" --no-pager -n 50 >&2 || true
    die "shared-caddy failed to start."
  }
  verify_filebrowser_precedence
}

ensure_shared_caddy_ready() {
  ensure_443_available_for_shared_caddy
  ensure_caddy_binary
  ensure_shared_caddy_base
  write_shared_caddy_service
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

write_caddy() {
  local domain="$1" port="$2" path="$3" cover_domain="$4"
  local site_file="${CADDY_SITE_DIR}/xray-${domain}.caddy"
  local route_dir="${CADDY_ROUTE_DIR}/${domain}"
  local route_file="${route_dir}/xray-xhttp.caddy"

  install -d -m 750 -o root -g "$CADDY_SERVICE_USER" "$CADDY_SITE_DIR" "$route_dir"

  [[ ! -f "${CADDY_SITE_DIR}/naive-${domain}.caddy" ]] ||
    die "XHTTP 与 NaiveProxy 不能使用同一个域名；请为 XHTTP 使用独立子域名。"

  [[ ! -f "${CADDY_SITE_DIR}/singbox-grpc-${domain}.caddy" ]] ||
    die "XHTTP 与 sing-box gRPC 不能使用同一个域名；请为 XHTTP 使用独立子域名。"
  [[ ! -f "${CADDY_SITE_DIR}/singbox-sub-${domain}.caddy" ]] ||
    die "XHTTP 与 sing-box 订阅站点不能使用同一个域名；请为 XHTTP 使用独立子域名。"

  if [[ -f "${CADDY_SITE_DIR}/filebrowser-${domain}.caddy" ]]; then
    rm -f "$site_file"
    cat >"$route_file" <<EOF
handle_path ${path}* {
    reverse_proxy 127.0.0.1:${port}
}
EOF
  else
    rm -f "$route_file"
    cat >"$site_file" <<EOF
${domain}:443 {
    encode gzip
    handle_path ${path}* {
        reverse_proxy 127.0.0.1:${port}
    }
EOF
    if [[ -n "$cover_domain" ]]; then
      cat >>"$site_file" <<EOF
    reverse_proxy https://${cover_domain} {
        header_up Host ${cover_domain}
    }
EOF
    else
      cat >>"$site_file" <<'EOF'
    respond 404
EOF
    fi
    cat >>"$site_file" <<'EOF'
}
EOF
  fi

  chown root:"$CADDY_SERVICE_USER" "$site_file" "$route_file" 2>/dev/null || true
  chmod 640 "$site_file" "$route_file" 2>/dev/null || true

  restart_shared_caddy
}

install_node() {
  install_deps
  configure_bbr
  configure_china_time
  ensure_shared_caddy_ready
  install_xray
  systemctl stop xray-xhttp 2>/dev/null || true

  local domain ip port uuid path name tmp link cover_domain caddy_conf
  local vless_decryption="none" vless_encryption="none" encryption_pair
  read -r -p "请输入已解析到本机的 XHTTP 域名/子域名：" domain
  domain="${domain#https://}"; domain="${domain%%/*}"; domain="${domain,,}"
  valid_domain "$domain" || die "域名格式不正确。"
  ip="$(public_ipv4)"; [[ -n "$ip" ]] || die "无法检测本机公网 IPv4。"
  check_domain "$domain" "$ip"
  if [[ -f "${CADDY_SITE_DIR}/filebrowser-${domain}.caddy" ]]; then
    echo "检测到 File Browser 正在共用 ${domain}:443；保留网盘根路径，XHTTP 只添加随机路径路由。"
    cover_domain=""
  else
    read -r -p "反代伪装网站域名（例如 www.example.com；直接回车不使用，根路径返回 404）: " cover_domain
    cover_domain="${cover_domain#https://}"; cover_domain="${cover_domain#http://}"; cover_domain="${cover_domain%%/*}"; cover_domain="${cover_domain,,}"
    [[ "$cover_domain" == "0" || "$cover_domain" == "none" || "$cover_domain" == "no" ]] && cover_domain=""
    if [[ -n "$cover_domain" ]]; then
      valid_domain "$cover_domain" || die "根路径反代域名格式不正确。"
      [[ "$cover_domain" != "$domain" ]] || die "根路径反代域名不能和 XHTTP 域名相同，否则会形成循环反代。"
    fi
  fi
  if confirm_yes "是否启用 VLESS Encryption（默认开启；输入 n 关闭；需要兼容的新版 Xray 客户端）?"; then
    encryption_pair="$(generate_vless_encryption_pair)"
    IFS=$'\t' read -r vless_decryption vless_encryption <<<"$encryption_pair"
    [[ -n "$vless_decryption" && -n "$vless_encryption" ]] || die "VLESS Encryption 参数读取失败。"
  fi
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
    "settings": { "clients": [{ "id": "$uuid", "email": "xhttp" }], "decryption": "$(json_escape "$vless_decryption")" },
    "streamSettings": { "network": "xhttp", "xhttpSettings": { "path": "$path", "mode": "auto" } }
  }],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
EOF
  "$XRAY_BIN" run -test -format json -c "$tmp" >/dev/null || { rm -f "$tmp"; die "生成的 Xray 配置未通过校验。"; }
  install -m 600 "$tmp" "$XRAY_CONFIG"; rm -f "$tmp"
  write_xray_service
  start_xray_service "$port"
  write_caddy "$domain" "$port" "$path" "$cover_domain"
  if [[ -f "${CADDY_SITE_DIR}/filebrowser-${domain}.caddy" ]]; then
    caddy_conf="${CADDY_ROUTE_DIR}/${domain}/xray-xhttp.caddy"
  else
    caddy_conf="${CADDY_SITE_DIR}/xray-${domain}.caddy"
  fi

  link="vless://${uuid}@${domain}:443?encryption=$(urlencode "$vless_encryption")&security=tls&sni=${domain}&fp=chrome&type=xhttp&path=${path}&mode=auto#${name}"
  cat >"$XRAY_INFO" <<EOF
NODE_NAME='$name'
DOMAIN='$domain'
LOCAL_PORT='$port'
PATH='$path'
UUID='$uuid'
CADDY_CONF='$caddy_conf'
COVER_DOMAIN='$cover_domain'
VLESS_ENCRYPTION='$vless_encryption'
LINK='$link'
EOF
  chmod 600 "$XRAY_INFO"
  echo
  echo "XHTTP 节点已创建，公网 TCP/443 通过 shared-caddy 共享："
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
  local quiet="${1:-false}" name domain uuid path encryption payload response subscription_url
  name="$(info_value NODE_NAME)"
  domain="$(info_value DOMAIN)"
  uuid="$(info_value UUID)"
  path="$(info_value PATH)"
  encryption="$(info_value VLESS_ENCRYPTION)"
  encryption="${encryption:-none}"
  [[ "$encryption" =~ ^[A-Za-z0-9._-]+$ ]] || die "保存的 VLESS Encryption 客户端参数格式错误。"
  load_subscription_identity
  payload="$(printf '{"node_id":"%s","name":"%s","server":"%s","port":443,"uuid":"%s","sni":"%s","host":"%s","path":"%s","encryption":"%s","insecure":false}' \
    "$(json_escape "$SUB_NODE_ID")" "$(json_escape "$name")" "$(json_escape "$domain")" \
    "$(json_escape "$uuid")" "$(json_escape "$domain")" "$(json_escape "$domain")" "$(json_escape "$path")" \
    "$(json_escape "$encryption")")"
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
  if [[ -f "$XRAY_INFO" ]]; then
    conf="$(info_value CADDY_CONF || true)"
    [[ -n "$conf" ]] || conf="$(info_value NGINX_CONF || true)"
  fi
  remove_subscription_node true || true
  systemctl disable --now xray-xhttp 2>/dev/null || true
  rm -f "$XRAY_SERVICE" "$XRAY_CONFIG" "$XRAY_INFO" "$SUBSCRIPTION_INFO_FILE"
  [[ -n "$conf" ]] && rm -f "$conf"
  systemctl daemon-reload
  if [[ -f "$CADDYFILE" && -x "$CADDY_BIN" ]]; then
    restart_shared_caddy || true
  fi
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
