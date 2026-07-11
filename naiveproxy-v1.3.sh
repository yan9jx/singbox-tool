#!/usr/bin/env bash
# NaiveProxy 鐙珛瀹夎涓庣淮鎶よ剼鏈紝閫傜敤浜?Debian/Ubuntu銆?# 鑺傜偣淇℃伅淇濆瓨鍦?/etc/naiveproxy/node-info.env锛岃濡ュ杽淇濇姢銆?# 浼樺厛澶嶇敤 shared-caddy 鐨?TCP/443锛涜嫢 443 琚叾浠栨湇鍔″崰鐢紝鍐嶈嚜鍔ㄩ€夋嫨澶囩敤绔彛銆?# Caddy 鑷姩鐢宠鍜岀画鏈熻瘉涔︼紝鏀寔 NaiveProxy 涓?File Browser 浣跨敤涓嶅悓鍩熷悕鍏辩敤 443銆?# v1.6锛氫慨澶?set -e 瀵艰嚧瀹夎/淇娴佺▼闈欓粯閫€鍑猴紝骞跺寮洪敊璇彁绀恒€?set -Eeuo pipefail

SCRIPT_VERSION="v1.8"
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
OLD_FB_ROUTE_MANIFEST="$INSTALL_DIR/filebrowser-routes.tsv"
OLD_FB_BACKUP_DIR="$INSTALL_DIR/filebrowser-backups"
die() { echo "閿欒锛?*" >&2; exit 1; }
require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "璇蜂娇鐢?root 杩愯銆?
  command -v systemctl >/dev/null || die "褰撳墠绯荤粺闇€瑕佹敮鎸?systemd銆?
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
require_install() { [[ -x "$BIN" && -f "$INFO_FILE" && -f "$CADDYFILE" ]] || die "鏈壘鍒?NaiveProxy锛岃鍏堝畨瑁呫€?; }

install_deps() {
  command -v apt-get >/dev/null 2>&1 || die "浠呮敮鎸?Debian/Ubuntu锛坅pt-get锛夈€?
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
  echo "褰撳墠 TCP 鎷ュ鎺у埗绠楁硶锛?(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 鏈煡)"
  confirm_yes "鏄惁瀹夎 / 鍚敤 BBR + FQ锛? || return 0
  modprobe tcp_bbr 2>/dev/null || true
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if ! grep -qw bbr <<<"$available"; then
    echo "璀﹀憡锛氬綋鍓嶅唴鏍镐笉鏀寔 BBR锛屽凡璺宠繃锛屼笉褰卞搷 NaiveProxy 瀹夎銆?
    return 0
  fi
  cat >"$bbr_file" <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl -w net.core.default_qdisc=fq >/dev/null
  sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null
  echo "BBR + FQ 宸插惎鐢ㄣ€?
}

check_domain() {
  local domain="$1" ip="$2" resolved
  resolved="$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u || true)"
  [[ -n "$resolved" ]] || die "鏈娴嬪埌 $domain 鐨?A 璁板綍銆?
  grep -Fxq "$ip" <<<"$resolved" ||
    die "$domain 褰撳墠瑙ｆ瀽涓猴細$(tr '\n' ' ' <<<"$resolved")锛屽叾涓病鏈夋湰鏈哄叕缃?IPv4 $ip銆傝纭 DNS 宸茬敓鏁堜笖 Cloudflare 涓轰粎 DNS锛堢伆浜戯級銆?
}

shared_caddy_owns_port() {
  local port="$1" pid
  pid="$(systemctl show "$SERVICE_NAME" -p MainPID --value 2>/dev/null || true)"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  ss -H -lntp "sport = :$port" 2>/dev/null | grep -q "pid=$pid,"
}

foreign_caddy_owns_port() {
  local port="$1"
  systemctl is-active --quiet caddy 2>/dev/null && return 0
  ss -H -ltnp "sport = :$port" 2>/dev/null | grep -qE "caddy|caddy-naive"
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
  die "鎵句笉鍒板彲鐢ㄧ殑 TCP 鐩戝惉绔彛銆?
}

choose_naive_port() {
  # 443 绌洪棽鏃剁洿鎺ヤ娇鐢紱鑻?443 姝ｇ敱鏈剼鏈鐞嗙殑 shared-caddy 鐩戝惉锛屼篃鍙畨鍏ㄥ鐢ㄣ€?  if ! port_is_listening 443 || shared_caddy_owns_port 443; then
  if ! port_is_listening 443 || shared_caddy_owns_port 443; then
    printf '443'
  else
    foreign_caddy_owns_port 443 &&
      die "检测到另一个 Caddy 正在占用 TCP/443。Naive 需要带 forward_proxy 模块的 shared-caddy，脚本不会覆盖现有 Caddy；请先迁移或释放 443。"
    choose_fallback_port
  fi
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

  # shared-caddy 鍙兘鍚屾椂璇诲彇 File Browser 鐢熸垚鐨勯厤缃紝缁熶竴鎺堜簣鏈嶅姟缁勫彧璇绘潈闄愩€?  find "$CADDY_DIR" -type d -exec chgrp "$SERVICE_USER" {} + -exec chmod g+rx {} +
  find "$CADDY_DIR" -type f \
    \( -name 'Caddyfile' -o -name '*.caddy' \) \
    -exec chgrp "$SERVICE_USER" {} + -exec chmod g+r {} +

  # 鍏煎鏃у畨瑁呮垨 root 杩愯鏈熼棿鐢熸垚鐨勮瘉涔︾紦瀛樸€?  chown -R "$SERVICE_USER:$SERVICE_USER" "$CADDY_STATE_DIR"
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

write_shared_caddyfile() {
  install -d -m 750 -o root -g "$SERVICE_USER" \
    "$CADDY_DIR" "$CADDY_SITE_DIR" "$CADDY_ROUTE_DIR"

  # 璇ヤ富閰嶇疆鐢辩綉鐩樿剼鏈拰 NaiveProxy 鑴氭湰鍏卞悓缁存姢銆?  # forward_proxy 鏀惧湪 Naive 鐙珛绔欑偣鐨?route 鍐咃紝鍥犳杩欓噷涓嶈兘鍐嶈缃叏灞€ order锛?  # 鍚﹀垯鏅€氱綉绔欑殑 reverse_proxy 浼氳 forward_proxy 鎻愬墠鎴幏銆?  cat >"$CADDYFILE" <<EOF
  cat >"$CADDYFILE" <<EOF
{
    admin off
    auto_https disable_redirects
    log {
        output discard
    }
}

import ${CADDY_SITE_DIR}/*.caddy
EOF
  chown root:"$SERVICE_USER" "$CADDYFILE"
  chmod 640 "$CADDYFILE"
}

migrate_v12_filebrowser_merge() {
  local manifest="$OLD_FB_ROUTE_MANIFEST"
  local backup_dir="$OLD_FB_BACKUP_DIR"
  local archive="/root/naiveproxy-v1.2-merge-backup-$(date +%Y%m%d-%H%M%S)-$$"
  local fb_domain fb_upstream fb_original fb_backup backup base original
  local restored=false
  local archived=false

  if [[ -f "$manifest" || -d "$backup_dir" ]]; then
    install -d -m 700 "$archive"
    archived=true

    if [[ -f "$manifest" ]]; then
      cp -a "$manifest" "$archive/"
    fi
    if [[ -d "$backup_dir" ]]; then
      cp -a "$backup_dir" "$archive/"
    fi
  fi

  if [[ -f "$manifest" ]]; then
    while IFS=$'\t' read -r fb_domain fb_upstream fb_original fb_backup; do
      [[ -n "$fb_original" && -n "$fb_backup" ]] || continue
      if [[ ! -f "$fb_original" && -f "$fb_backup" ]]; then
        install -D -m 640 -o root -g "$SERVICE_USER" "$fb_backup" "$fb_original"
        restored=true
      fi
    done <"$manifest"
  fi

  if [[ -d "$backup_dir" ]]; then
    shopt -s nullglob
    for backup in "$backup_dir"/filebrowser-*.caddy.original; do
      base="$(basename "$backup")"
      base="${base%.original}"
      original="$CADDY_SITE_DIR/$base"
      if [[ ! -f "$original" ]]; then
        install -D -m 640 -o root -g "$SERVICE_USER" "$backup" "$original"
        restored=true
      fi
    done
    shopt -u nullglob
  fi

  rm -f "$manifest"
  rm -rf "$backup_dir"

  # 娓呯悊鏃х増鈥滃悓鍩熷悕娉ㄥ叆 route鈥濇畫鐣欙紱v1.6 鍙娇鐢ㄧ嫭绔嬬珯鐐规枃浠躲€?  if [[ -d "$CADDY_ROUTE_DIR" ]]; then
  if [[ -d "$CADDY_ROUTE_DIR" ]]; then
    find "$CADDY_ROUTE_DIR" -type f -name 'naive.caddy' -delete 2>/dev/null || true
    find "$CADDY_ROUTE_DIR" -depth -type d -empty -delete 2>/dev/null || true
  fi

  if [[ "$restored" == true ]]; then
    echo "宸叉仮澶?v1.2 绉昏蛋鐨?File Browser 鐙珛绔欑偣閰嶇疆銆?
  fi
  if [[ "$archived" == true ]]; then
    echo "鏃у悎骞堕厤缃凡澶囦唤鍒帮細$archive"
  fi

  # 蹇呴』鏄惧紡鎴愬姛杩斿洖锛涘惁鍒?set -e 浼氭妸鈥滄病鏈夋棫澶囦唤鈥濊鍒や负澶辫触骞堕潤榛樼粓姝€?  return 0
  return 0
}

cleanup_managed_naive_config() {
  local new_domain="$1" old_domain="" domain
  if [[ -f "$INFO_FILE" ]]; then
    old_domain="$(info_value DOMAIN 2>/dev/null || true)"
  fi
  for domain in "$old_domain" "$new_domain"; do
    [[ -n "$domain" ]] || continue
    rm -f "${CADDY_SITE_DIR}/naive-${domain}.caddy"
    rm -f "${CADDY_ROUTE_DIR}/${domain}/naive.caddy"
    rmdir "${CADDY_ROUTE_DIR}/${domain}" 2>/dev/null || true
  done
}

ensure_distinct_filebrowser_domain() {
  local domain="$1"
  if [[ -f "${CADDY_SITE_DIR}/filebrowser-${domain}.caddy" ]]; then
    die "NaiveProxy 鍩熷悕 $domain 宸茶 File Browser 浣跨敤銆備袱涓湇鍔″繀椤讳娇鐢ㄤ笉鍚屽煙鍚嶏紝浣嗗彲浠ヨВ鏋愬埌鍚屼竴涓?VPS IP銆?
  fi
}

ensure_distinct_site_domain() {
  local domain="$1" prefix
  for prefix in filebrowser xray singbox-grpc singbox-sub; do
    [[ ! -f "${CADDY_SITE_DIR}/${prefix}-${domain}.caddy" ]] ||
      die "NaiveProxy 域名 $domain 已被 ${prefix} 使用。请为 NaiveProxy 使用独立子域名。"
  done
}

write_caddyfile() {
  local domain="$1" port="$2" username="$3" password="$4" site_file site_address
  site_file="${CADDY_SITE_DIR}/naive-${domain}.caddy"

  write_shared_caddyfile
  cleanup_managed_naive_config "$domain"
  ensure_distinct_filebrowser_domain "$domain"
  ensure_distinct_site_domain "$domain"

  if [[ "$port" == "443" ]]; then
    # :443 蹇呴』鎺掑湪 Naive 鍩熷悕鍓嶏紝鎵嶈兘澶勭悊 CONNECT 鐩爣涓轰换鎰忕綉绔欑殑浠ｇ悊璇锋眰銆?    site_address=":443, $domain"
    site_address=":443, $domain"
  else
    site_address="$domain:$port"
  fi

  cat >"$site_file" <<EOF
$site_address {
    encode

    # route 鍥哄畾 forward_proxy 鐨勫鐞嗕綅缃紝鍙綔鐢ㄤ簬 Naive 绔欑偣锛?    # 鍏朵粬鍩熷悕浠嶇敱鍚勮嚜鐙珛鐨?reverse_proxy/file_server 澶勭悊銆?    route {
    route {
        forward_proxy {
            basic_auth $username $password
            hide_ip
            hide_via
            probe_resistance
        }
    }

    root * $WEB_ROOT
    file_server
}
EOF

  chown root:"$SERVICE_USER" "$site_file"
  chmod 640 "$site_file"
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
TimeoutStopSec=5s
LimitNOFILE=1048576
Restart=on-failure
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
PrivateTmp=true
ReadWritePaths=$CADDY_STATE_DIR
NoNewPrivileges=true
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
}

fetch_latest_release() {
  local release_json
  release_json="$(curl -fsSL --max-time 30 "$RELEASE_API")" || die "鏃犳硶鑾峰彇 NaiveProxy 鏈嶅姟绔渶鏂扮増鏈€?
  RELEASE_TAG="$(jq -er '.tag_name' <<<"$release_json")" || die "鏈€鏂扮増鏈俊鎭己灏?tag銆?
  RELEASE_URL="$(jq -er --arg name "$RELEASE_ASSET" '.assets[] | select(.name == $name) | .browser_download_url' <<<"$release_json")" ||
    die "鏈€鏂扮増鏈己灏?$RELEASE_ASSET銆?
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
      die "鏈嶅姟绔畨瑁呭寘 SHA-256 鏍￠獙澶辫触銆?
  fi
  tar -xJf "$archive" -C "$workdir"
  RELEASE_BINARY="$workdir/caddy-forwardproxy-naive/caddy"
  [[ -x "$RELEASE_BINARY" ]] || die "鏈嶅姟绔畨瑁呭寘鍐呭涓嶅畬鏁淬€?
}

validate_caddy() {
  local binary="$1"
  "$binary" validate --config "$CADDYFILE" --adapter caddyfile >/dev/null ||
    die "Caddy/NaiveProxy 閰嶇疆鏍￠獙澶辫触銆?
}

verify_filebrowser_precedence() {
  local port="$1" site domain tmp host_index fallback_index naive_site
  [[ "$port" == "443" ]] || return 0
  naive_site="$(find "$CADDY_SITE_DIR" -maxdepth 1 -type f -name "naive-*.caddy" -print -quit 2>/dev/null || true)"
  [[ -n "$naive_site" ]] || return 0

  for site in "$CADDY_SITE_DIR"/filebrowser-*.caddy; do
    [[ -f "$site" ]] || continue
    domain="${site##*/filebrowser-}"
    domain="${domain%.caddy}"
    tmp="$(mktemp)"
    "$BIN" adapt --config "$CADDYFILE" --adapter caddyfile --pretty >"$tmp" || { rm -f "$tmp"; die "Caddy route priority check failed."; }
    host_index="$(jq -r --arg domain "$domain" '[.apps.http.servers[]?.routes | to_entries[] | select(any(.value.match[]?; ((.host? // []) | index($domain)))) | .key] | min // empty' "$tmp")"
    fallback_index="$(jq -r '[.apps.http.servers[]?.routes | to_entries[] | select((.value.match // []) | length == 0) | .key] | min // empty' "$tmp")"
    rm -f "$tmp"
    [[ "$host_index" =~ ^[0-9]+$ && "$fallback_index" =~ ^[0-9]+$ && "$host_index" -lt "$fallback_index" ]] ||
      die "Caddy route priority check failed: File Browser must precede the Naive :443 fallback route."
  done
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
    die "鏃犳硶淇濆瓨绠＄悊鑴氭湰锛涜鍏堝皢鑴氭湰涓嬭浇涓烘湰鍦版枃浠跺悗杩愯銆?
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
  echo "NaiveProxy 姣忓懆鑷姩鏇存柊妫€鏌ュ凡鍚敤銆?
}

disable_auto_update() {
  systemctl disable --now naiveproxy-update.timer 2>/dev/null || true
  rm -f "$UPDATE_SERVICE" "$UPDATE_TIMER"
  systemctl daemon-reload
  echo "NaiveProxy 鑷姩鏇存柊宸插叧闂€?
}

start_service() {
  local port="$1"
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null
  if ! systemctl restart "$SERVICE_NAME"; then
    journalctl -u "$SERVICE_NAME" -n 80 --no-pager >&2 || true
    die "NaiveProxy 鍚姩鍛戒护澶辫触銆?
  fi
  systemctl is-active --quiet "$SERVICE_NAME" || {
    journalctl -u "$SERVICE_NAME" -n 80 --no-pager >&2 || true
    die "NaiveProxy 鍚姩澶辫触銆?
  }
  verify_filebrowser_precedence "$port"
  local n
  for ((n = 0; n < 10; n++)); do
    port_is_listening "$port" && return 0
    sleep 1
  done
  die "NaiveProxy 鏈洃鍚?TCP/$port銆?
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
NaiveProxy 鑺傜偣锛?鍚嶇О锛?name
鍦板潃锛?domain
绔彛锛?port
鐢ㄦ埛鍚嶏細$username
瀵嗙爜锛?password

鍒嗕韩閾炬帴锛?$uri

瀹樻柟 Naive 瀹㈡埛绔厤缃細
{
  "listen": "socks://127.0.0.1:1080",
  "proxy": "https://$username:$password@$domain:$port"
}

sing-box / Husi / NekoBox 鑺傜偣鍙傛暟锛?{
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
  read -r -p "璇疯緭鍏ュ凡瑙ｆ瀽鍒版湰鏈虹殑 NaiveProxy 鍩熷悕锛? domain
  domain="${domain,,}"
  domain="${domain#https://}"
  domain="${domain#http://}"
  domain="${domain%%/*}"
  domain="${domain%%:*}"
  valid_domain "$domain" || die "鍩熷悕鏍煎紡涓嶆纭€?
  ip="$(public_ipv4)"
  [[ -n "$ip" ]] || die "鏃犳硶妫€娴嬫湰鏈哄叕缃?IPv4銆?
  check_domain "$domain" "$ip"

  systemctl stop naiveproxy 2>/dev/null || true
  ensure_service_user
  migrate_v12_filebrowser_merge
  port="$(choose_naive_port)"
  echo "鑷姩閫夋嫨 NaiveProxy 鐩戝惉绔彛锛歍CP/$port"
  if [[ "$port" == "443" ]] && shared_caddy_owns_port 443; then
    echo "妫€娴嬪埌 shared-caddy 宸茬洃鍚?443锛屽皢鎸夊煙鍚嶅鐢ㄥ悓涓€绔彛銆?
  fi

  read -r -p "鑺傜偣鍚嶇О [NaiveProxy]: " name
  name="${name:-NaiveProxy}"; name="${name//\'/}"; name="${name//$'\n'/}"
  username="naive$(openssl rand -hex 4)"
  password="$(openssl rand -hex 24)"

  write_decoy_site
  write_caddyfile "$domain" "$port" "$username" "$password"
  write_service

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
  echo "NaiveProxy 宸插畨瑁呭畬鎴愩€侰addy 灏嗚嚜鍔ㄧ敵璇峰苟缁湡璇佷功銆?
  echo "璇风‘璁や簯鍘傚晢瀹夊叏缁勫凡鏀捐 TCP/$port锛涜嚜鍔ㄧ鍙戦€氬父杩橀渶瑕?TCP/80 鎴?TCP/443 鍙揪銆?
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
    [[ "$quiet" == true ]] || echo "宸叉槸鏈€鏂扮増鏈細$current"
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
    die "鏂扮増鏈惎鍔ㄥけ璐ワ紝宸茶嚜鍔ㄥ洖婊氬埌 $current銆?
  fi
  sed -i "s/^SERVER_VERSION='.*'$/SERVER_VERSION='$RELEASE_TAG'/" "$INFO_FILE"
  rm -f "$backup"
  echo "NaiveProxy 鏈嶅姟绔凡浠?$current 鏇存柊鍒?$RELEASE_TAG銆?
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
  systemctl is-active --quiet "$SERVICE_NAME" || die "閲嶇疆瀵嗙爜鍚庢湇鍔″惎鍔ㄥけ璐ャ€?
  write_info "$name" "$domain" "$port" "$username" "$password" "$version"
  echo "瀵嗙爜宸查噸缃紝璇峰湪瀹㈡埛绔洿鏂拌妭鐐广€?
  show_config
}

repair_shared_caddy() {
  require_install
  ensure_service_user
  install_self
  migrate_v12_filebrowser_merge

  local domain port username password
  domain="$(info_value DOMAIN)"
  port="$(info_value PORT)"
  username="$(info_value USERNAME)"
  password="$(info_value PASSWORD)"
  valid_domain "$domain" || die "鐜版湁 NaiveProxy 鍩熷悕鏃犳晥銆?
  validate_port "$port" || die "鐜版湁 NaiveProxy 绔彛鏃犳晥銆?
  [[ -n "$username" && -n "$password" ]] || die "鐜版湁鑺傜偣璁よ瘉淇℃伅涓嶅畬鏁淬€?

  write_decoy_site
  write_caddyfile "$domain" "$port" "$username" "$password"
  write_service
  validate_caddy "$BIN"
  start_service "$port"
  echo "鍏变韩 443 閰嶇疆宸蹭慨澶嶏細NaiveProxy 涓?File Browser 浣跨敤涓嶅悓鍩熷悕銆佸悓涓€ Caddy銆?
}

restart_node() {
  require_install
  local port
  port="$(info_value PORT)"
  validate_caddy "$BIN"
  verify_filebrowser_precedence "$port"
  systemctl restart "$SERVICE_NAME"
  if ! systemctl is-active --quiet "$SERVICE_NAME" || ! port_is_listening "$port"; then
    die "NaiveProxy 閲嶅惎澶辫触銆?
  fi
  echo "NaiveProxy 宸查噸鍚€?
}

uninstall_node() {
  confirm_yes "鏄惁鍗歌浇鏈剼鏈垱寤虹殑 NaiveProxy锛? || return 0
  local domain other_sites=false
  domain="$(info_value DOMAIN 2>/dev/null || true)"

  systemctl disable --now naiveproxy-update.timer 2>/dev/null || true
  if [[ -n "$domain" ]]; then
    rm -f "${CADDY_ROUTE_DIR}/${domain}/naive.caddy" "${CADDY_SITE_DIR}/naive-${domain}.caddy"
  fi
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
    echo "NaiveProxy 宸插嵏杞斤紱shared-caddy銆佽嚜鍔ㄨ瘉涔﹀拰鍏朵粬绔欑偣宸蹭繚鐣欍€?
  else
    systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$BIN"
    rm -rf "$CADDY_DIR" "$CADDY_STATE_DIR"
    userdel "$SERVICE_USER" 2>/dev/null || true
    groupdel "$SERVICE_USER" 2>/dev/null || true
    systemctl daemon-reload
    echo "NaiveProxy 涓庣┖闂茬殑 shared-caddy 宸插嵏杞姐€?
  fi
}

show_status() {
  require_install
  echo "鑴氭湰鐗堟湰锛?SCRIPT_VERSION"
  echo "鏈嶅姟绔増鏈細$(info_value SERVER_VERSION)"
  systemctl status "$SERVICE_NAME" --no-pager
  systemctl status naiveproxy-update.timer --no-pager 2>/dev/null || true
}

menu() {
  cat <<EOF
========================================
 NaiveProxy 鐙珛鑺傜偣鑴氭湰 $SCRIPT_VERSION
========================================
1. 瀹夎 / 閲嶅缓 NaiveProxy
2. 鏌ョ湅鑺傜偣閰嶇疆鍜屼簩缁寸爜
3. 鏌ョ湅鐘舵€?4. 鏌ョ湅鏃ュ織
5. 閲嶅惎 NaiveProxy
6. 閲嶇疆瀵嗙爜
7. 妫€鏌?/ 鏇存柊鏈嶅姟绔?8. 寮€鍚瘡鍛ㄨ嚜鍔ㄦ洿鏂?9. 鍏抽棴鑷姩鏇存柊
10. 鍗歌浇 NaiveProxy
11. 淇涓庣綉鐩樺叡鐢?443
0. 閫€鍑?EOF
EOF
  local choice
  read -r -p "璇烽€夋嫨锛? choice
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
    11) repair_shared_caddy ;;
    0) exit 0 ;;
    *) die "鏃犳晥閫夐」銆? ;;
  esac
}


on_error() {
  local exit_code="$1" line_no="$2" command_text="$3"
  printf '閿欒锛歂aiveProxy 鑴氭湰鍦ㄧ %s 琛屾墽琛屽け璐ワ紙閫€鍑虹爜 %s锛夛細%s\n' \
    "$line_no" "$exit_code" "$command_text" >&2
  exit "$exit_code"
}

trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

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
  repair) repair_shared_caddy ;;
  *) menu ;;
esac
