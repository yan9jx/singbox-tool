#!/usr/bin/env bash
set -Eeuo pipefail

# GitHub-ready interactive File Browser installer for Debian/Ubuntu and RHEL-compatible VPSes.

SCRIPT_VERSION="2026.07.12-2"
FB_DB="/etc/filebrowser/filebrowser.db"
FB_ROOT="/srv/filebrowser"
FB_PORT="8080"
PUBLIC_PORT="443"
CREDS_FILE="/root/filebrowser-credentials.txt"
NGINX_CONF=""
CADDY_BIN="/usr/local/bin/caddy-naive"
CADDY_DIR="/etc/caddy-naive"
CADDYFILE="${CADDY_DIR}/Caddyfile"
CADDY_SITE_DIR="${CADDY_DIR}/sites"
CADDY_ROUTE_DIR="${CADDY_DIR}/routes"
CADDY_SERVICE="shared-caddy"
CADDY_SERVICE_FILE="/etc/systemd/system/${CADDY_SERVICE}.service"
CADDY_SERVICE_USER="naiveproxy"
CADDY_STATE_DIR="/var/lib/shared-caddy"
CADDY_DATA_DIR="${CADDY_STATE_DIR}/data"
CADDY_CONFIG_DIR="${CADDY_STATE_DIR}/config"
CADDY_RELEASE_API="https://api.github.com/repos/klzgrad/forwardproxy/releases/latest"
CADDY_RELEASE_ASSET="caddy-forwardproxy-naive.tar.xz"
NAIVE_INFO_FILE="/etc/naiveproxy/node-info.env"
NAIVE_WEB_ROOT="/var/www/naiveproxy"
OLD_FB_ROUTE_MANIFEST="/etc/naiveproxy/filebrowser-routes.tsv"
OLD_FB_BACKUP_DIR="/etc/naiveproxy/filebrowser-backups"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { printf "${GREEN}[+]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
die() { printf "${RED}[x]${NC} %s\n" "$*" >&2; exit 1; }

require_root() {
  [[ ${EUID} -eq 0 ]] || die "璇蜂娇鐢?root 鏉冮檺杩愯姝よ剼鏈€?
}

require_interactive_terminal() {
  [[ -t 0 ]] || die "姝よ剼鏈渶瑕佷氦浜掕緭鍏ワ紝璇峰厛涓嬭浇鍚庢墽琛岋紝涓嶈浣跨敤 curl | bash銆?
}

valid_domain() {
  [[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

valid_size() {
  [[ $1 =~ ^[1-9][0-9]*[mMgG]$ ]]
}

random_password() {
  # Avoid visually ambiguous characters so credentials can be typed reliably.
  tr -dc 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789' < /dev/urandom | head -c 24 || true
}

port_is_available() {
  local port="$1"

  if command -v ss >/dev/null 2>&1; then
    ! ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .
  else
    ! netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"
  fi
}

port_owner_is_shared_caddy() {
  local port="$1"
  command -v ss >/dev/null 2>&1 || return 1
  ss -H -ltnp "sport = :${port}" 2>/dev/null | grep -Eq 'caddy|caddy-naive'
}

choose_available_port() {
  local port

  if port_is_available "$FB_PORT"; then
    return
  fi

  warn "绔彛 ${FB_PORT} 宸茶鍏朵粬绋嬪簭鍗犵敤锛屾鍦ㄥ鎵剧┖闂茬鍙?.."
  for port in $(seq 8081 8999); do
    if port_is_available "$port"; then
      FB_PORT="$port"
      info "灏嗕娇鐢ㄧ┖闂插悗绔鍙ｏ細${FB_PORT}"
      return
    fi
  done

  die "鏈兘鍦?8081-8999 鑼冨洿鍐呮壘鍒扮┖闂茬鍙ｃ€?
}

cleanup_legacy_filebrowser_https() {
  local config
  local backup_dir="/root/filebrowser-nginx-backup-$(date +%Y%m%d-%H%M%S)"
  local cleaned="false"

  info "妫€鏌ユ棫鐗?File Browser HTTPS/Nginx 娈嬬暀..."
  for config in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf; do
    [[ -f "$config" ]] || continue

    if grep -Fq "server_name ${DOMAIN}" "$config" \
      && grep -Eq 'listen[[:space:]]+443([^0-9]|$)' "$config" \
      && grep -Eq 'proxy_pass[[:space:]]+http://127\.0\.0\.1:[0-9]+' "$config"; then
      install -d -m 0700 "$backup_dir"
      cp -aL "$config" "$backup_dir/$(basename "$config").conf"

      if [[ -L "$config" ]]; then
        rm -f "$config"
      else
        mv "$config" "${config}.disabled-filebrowser-https"
      fi

      warn "宸插浠藉苟绂佺敤鏃?File Browser HTTPS 閰嶇疆锛?config"
      cleaned="true"
    fi
  done

  if [[ $cleaned == "true" ]]; then
    info "鏃ч厤缃浠界洰褰曪細${backup_dir}"
    warn "Let's Encrypt 璇佷功鏂囦欢宸蹭繚鐣欙紱File Browser 灏嗕娇鐢ㄦ爣鍑?HTTPS 443锛宻ing-box 鐨?2443 涓嶅彈褰卞搷銆?

    if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
      nginx -t
      systemctl reload nginx
      info "Nginx 宸查噸杞斤紝鏃?File Browser 443 鐩戝惉宸叉竻鐞嗐€?
    fi
  fi
}

cleanup_legacy_filebrowser_http() {
  local config
  local backup_dir="/root/filebrowser-nginx-backup-$(date +%Y%m%d-%H%M%S)"
  local cleaned="false"

  info "妫€鏌ユ棫鐗?File Browser HTTP/Nginx 娈嬬暀..."
  for config in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf; do
    [[ -f "$config" ]] || continue

    if grep -Fq "server_name ${DOMAIN}" "$config" \
      && grep -Eq 'listen[[:space:]]+(80|80[0-7][0-9])([^0-9]|$)' "$config" \
      && grep -Eq 'proxy_pass[[:space:]]+http://127\.0\.0\.1:[0-9]+' "$config"; then
      install -d -m 0700 "$backup_dir"
      cp -aL "$config" "$backup_dir/$(basename "$config").conf"

      if [[ -L "$config" ]]; then
        rm -f "$config"
      else
        mv "$config" "${config}.disabled-filebrowser-http"
      fi

      warn "宸插浠藉苟绂佺敤鏃?File Browser HTTP 閰嶇疆锛?config"
      cleaned="true"
    fi
  done

  if [[ $cleaned == "true" ]]; then
    info "鏃ч厤缃浠界洰褰曪細${backup_dir}"
    if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
      nginx -t
      systemctl reload nginx
    fi
  fi
}

detect_os() {
  [[ -r /etc/os-release ]] || die "鏃犳硶璇嗗埆绯荤粺銆備粎鏀寔 Debian/Ubuntu 鍜?RHEL 绯诲彂琛岀増銆?
  # shellcheck disable=SC1091
  . /etc/os-release

  case "${ID_LIKE:-} ${ID:-}" in
    *debian*|*ubuntu*)
      PKG_FAMILY="debian"
      NGINX_CONF="/etc/nginx/sites-available/filebrowser"
      ;;
    *rhel*|*fedora*|*centos*|*rocky*|*almalinux*)
      PKG_FAMILY="rhel"
      NGINX_CONF="/etc/nginx/conf.d/filebrowser.conf"
      ;;
    *)
      die "涓嶆敮鎸佸綋鍓嶇郴缁燂細${PRETTY_NAME:-unknown}"
      ;;
  esac
}

collect_input() {
  echo
  read -r -p "璇疯緭鍏ョ粦瀹氬煙鍚嶏紙渚嬪 cloud.example.com锛? " DOMAIN
  valid_domain "$DOMAIN" || die "鍩熷悕鏍煎紡涓嶆纭€傝杈撳叆涓嶅甫 http:// 鎴栬矾寰勭殑瀹屾暣鍩熷悕銆?

  read -r -p "璇疯緭鍏ヤ笂浼犳枃浠跺ぇ灏忛檺鍒?[榛樿 10G锛屽彲鐢ㄧず渚嬶細500M銆?0G]: " UPLOAD_LIMIT
  UPLOAD_LIMIT="${UPLOAD_LIMIT:-10G}"
  valid_size "$UPLOAD_LIMIT" || die "涓婁紶闄愬埗鏍煎紡涓嶆纭紝浠呮敮鎸佹鏁存暟鍔?M/G锛屼緥濡?500M 鎴?20G銆?

  read -r -p "璇疯緭鍏ョ鐞嗗憳璐﹀彿 [榛樿 admin]: " ADMIN_USER
  ADMIN_USER="${ADMIN_USER:-admin}"
  [[ $ADMIN_USER =~ ^[A-Za-z0-9_.-]{3,32}$ ]] || die "璐﹀彿浠呭厑璁?3-32 浣嶅瓧姣嶃€佹暟瀛椼€佷笅鍒掔嚎銆佺偣鍜屾í绾裤€?

  read -r -p "璇疯緭鍏ヤ簯鐩樺瓨鍌ㄧ洰褰?[鍥炶溅浣跨敤榛樿鐩綍]: " INPUT_ROOT
  FB_ROOT="${INPUT_ROOT:-$FB_ROOT}"
  [[ $FB_ROOT == /* ]] || die "瀛樺偍鐩綍蹇呴』鏄粷瀵硅矾寰勩€?
  [[ $FB_ROOT != "/" ]] || die "涓嶈兘灏嗙郴缁熸牴鐩綍浣滀负浜戠洏鐩綍銆?

  read -r -p "璇疯緭鍏ョ敤浜?Let's Encrypt 閫氱煡鐨勯偖绠憋紙宸叉湁璇佷功鏃跺彲鐣欑┖锛? " CERT_EMAIL

  ADMIN_PASS="$(random_password)"
  [[ ${#ADMIN_PASS} -eq 24 ]] || die "鐢熸垚闅忔満瀵嗙爜澶辫触銆?
}

install_packages() {
  info "瀹夎 curl銆丆ertbot 鍜?Caddy 鎵€闇€渚濊禆..."
  if [[ $PKG_FAMILY == "debian" ]]; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates certbot jq xz-utils tar coreutils
  else
    if ! dnf install -y curl ca-certificates certbot jq xz tar coreutils; then
      dnf install -y epel-release
      dnf install -y curl ca-certificates certbot jq xz tar coreutils
    fi
  fi
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

naive_info_value() {
  local key="$1"
  sed -n "s/^${key}='\\(.*\\)'$/\\1/p" "$NAIVE_INFO_FILE" 2>/dev/null || true
}

write_shared_caddyfile() {
  # forward_proxy 浠呮斁鍦?Naive 鐙珛绔欑偣鐨?route 鍐呫€?  # 涓婚厤缃笉鑳借缃叏灞€ order forward_proxy锛屽惁鍒欑綉鐩?reverse_proxy 浼氳鎻愬墠鎴幏銆?  cat >"$CADDYFILE" <<EOF
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
  chown root:"$CADDY_SERVICE_USER" "$CADDYFILE"
  chmod 640 "$CADDYFILE"
}

verify_naive_filebrowser_precedence() {
  local naive_port site domain tmp host_index fallback_index naive_site
  naive_port="$(naive_info_value PORT)"
  [[ "$naive_port" == "443" ]] || return 0
  naive_site="$(find "$CADDY_SITE_DIR" -maxdepth 1 -type f -name "naive-*.caddy" -print -quit 2>/dev/null || true)"
  [[ -n "$naive_site" ]] || return 0

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

migrate_v12_filebrowser_merge() {
  local manifest="$OLD_FB_ROUTE_MANIFEST"
  local backup_dir="$OLD_FB_BACKUP_DIR"
  local archive="/root/filebrowser-naive-v1.2-merge-backup-$(date +%Y%m%d-%H%M%S)-$$"
  local fb_domain fb_upstream fb_original fb_backup backup base original restored=false

  if [[ -f "$manifest" || -d "$backup_dir" ]]; then
    install -d -m 700 "$archive"
    [[ -f "$manifest" ]] && cp -a "$manifest" "$archive/"
    [[ -d "$backup_dir" ]] && cp -a "$backup_dir" "$archive/"
  fi

  if [[ -f "$manifest" ]]; then
    while IFS=$'\t' read -r fb_domain fb_upstream fb_original fb_backup; do
      [[ -n "$fb_original" && -n "$fb_backup" ]] || continue
      if [[ ! -f "$fb_original" && -f "$fb_backup" ]]; then
        install -D -m 640 -o root -g "$CADDY_SERVICE_USER" "$fb_backup" "$fb_original"
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
        install -D -m 640 -o root -g "$CADDY_SERVICE_USER" "$backup" "$original"
        restored=true
      fi
    done
    shopt -u nullglob
  fi

  rm -f "$manifest"
  rm -rf "$backup_dir"
  find "$CADDY_ROUTE_DIR" -type f -name 'naive.caddy' -delete 2>/dev/null || true
  find "$CADDY_ROUTE_DIR" -depth -type d -empty -delete 2>/dev/null || true

  [[ "$restored" == true ]] && info "宸叉仮澶嶆棫鐗堢Щ璧扮殑 File Browser 鐙珛绔欑偣閰嶇疆銆?
  [[ -d "$archive" ]] && warn "鏃у悎骞堕厤缃凡澶囦唤鍒帮細$archive"
}

ensure_distinct_naive_domain() {
  [[ -f "$NAIVE_INFO_FILE" ]] || return 0
  local naive_domain
  naive_domain="$(naive_info_value DOMAIN)"
  if [[ -n "$naive_domain" && "$naive_domain" == "$DOMAIN" ]]; then
    die "File Browser 涓?NaiveProxy 蹇呴』浣跨敤涓嶅悓鍩熷悕锛涗袱涓煙鍚嶅彲浠ヨВ鏋愬埌鍚屼竴涓?VPS IP銆?
  fi
}

ensure_domain_not_owned_by_standalone_site() {
  local prefix
  for prefix in naive xray singbox-grpc singbox-sub; do
    [[ ! -f "${CADDY_SITE_DIR}/${prefix}-${DOMAIN}.caddy" ]] ||
      die "${DOMAIN} 已被 ${prefix} 的独立 Caddy 站点使用。请为 File Browser 使用独立子域名，避免覆盖现有服务。"
  done
}

repair_existing_naive_site() {
  [[ -f "$NAIVE_INFO_FILE" ]] || return 0

  local naive_domain naive_port naive_username naive_password site_address site_file
  naive_domain="$(naive_info_value DOMAIN)"
  naive_port="$(naive_info_value PORT)"
  naive_username="$(naive_info_value USERNAME)"
  naive_password="$(naive_info_value PASSWORD)"

  valid_domain "$naive_domain" || return 0
  [[ "$naive_port" =~ ^[0-9]+$ ]] || return 0
  [[ -n "$naive_username" && -n "$naive_password" ]] || return 0
  [[ "$naive_domain" != "$DOMAIN" ]] || die "File Browser 涓?NaiveProxy 涓嶈兘浣跨敤鍚屼竴涓煙鍚嶃€?

  if [[ "$naive_port" == "443" ]]; then
    site_address=":443, $naive_domain"
  else
    site_address="$naive_domain:$naive_port"
  fi
  site_file="${CADDY_SITE_DIR}/naive-${naive_domain}.caddy"

  cat >"$site_file" <<EOF
$site_address {
    encode

    route {
        forward_proxy {
            basic_auth $naive_username $naive_password
            hide_ip
            hide_via
            probe_resistance
        }
    }

    root * $NAIVE_WEB_ROOT
    file_server
}
EOF
  chown root:"$CADDY_SERVICE_USER" "$site_file"
  chmod 640 "$site_file"
  info "宸叉妸鐜版湁 NaiveProxy 绔欑偣淇涓虹嫭绔?route 閰嶇疆銆?
}

configure_security() {
  info "妫€鏌ラ槻鐏涓?SELinux..."

  if command -v getenforce >/dev/null 2>&1 && [[ $(getenforce) == "Enforcing" ]]; then
    setsebool -P httpd_can_network_connect 1
  fi

  if systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port="${PUBLIC_PORT}/tcp"
    firewall-cmd --reload
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "^Status: active"; then
    ufw allow "${PUBLIC_PORT}/tcp"
  fi
}

ensure_certificate() {
  local cert_dir="/etc/letsencrypt/live/${DOMAIN}"
  local certbot_args
  local acme_root="/var/lib/filebrowser-acme"
  local acme_conf

  if [[ "${NGINX_MODE:-}" == "caddy" ]]; then
    info "Shared Caddy will manage HTTPS certificates automatically; skipping certbot."
    return
  fi

  if [[ -s "${cert_dir}/fullchain.pem" && -s "${cert_dir}/privkey.pem" ]]; then
    info "妫€娴嬪埌宸叉湁 HTTPS 璇佷功锛屽皢鐩存帴澶嶇敤銆?
    return
  fi

  certbot_args=(certonly -d "$DOMAIN" --non-interactive --agree-tos)
  if [[ -n ${CERT_EMAIL:-} ]]; then
    certbot_args+=(--email "$CERT_EMAIL")
  else
    certbot_args+=(--register-unsafely-without-email)
  fi

  if port_is_available 80; then
    info "浣跨敤涓存椂绔彛 80 鐢宠 Let's Encrypt 璇佷功..."
    certbot "${certbot_args[@]}" --standalone
    return
  fi

  if ! command -v ss >/dev/null 2>&1 || ! ss -H -ltnp "sport = :80" 2>/dev/null | grep -q 'nginx'; then
    die "鏈壘鍒板凡鏈夎瘉涔︼紝涓旂鍙?80 琚潪 Nginx 鏈嶅姟鍗犵敤锛屾棤娉曞畨鍏ㄥ畬鎴?Let's Encrypt 楠岃瘉銆?
  fi

  info "閫氳繃鐜版湁 Nginx 鐨勪复鏃?ACME 璺敱鐢宠 Let's Encrypt 璇佷功..."
  install -d -m 0755 "${acme_root}/.well-known/acme-challenge"
  if [[ $PKG_FAMILY == "debian" ]]; then
    acme_conf="/etc/nginx/sites-available/filebrowser-acme"
  else
    acme_conf="/etc/nginx/conf.d/filebrowser-acme.conf"
  fi
  cat > "$acme_conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    location /.well-known/acme-challenge/ {
        root ${acme_root};
    }
}
EOF
  [[ $PKG_FAMILY == "debian" ]] && ln -sfn "$acme_conf" /etc/nginx/sites-enabled/filebrowser-acme
  nginx -t
  systemctl reload nginx
  if ! certbot "${certbot_args[@]}" --webroot -w "$acme_root"; then
    [[ $PKG_FAMILY == "debian" ]] && rm -f /etc/nginx/sites-enabled/filebrowser-acme
    rm -f "$acme_conf"
    nginx -t
    systemctl reload nginx
    die "Let's Encrypt 璇佷功鐢宠澶辫触锛岃纭鍩熷悕瑙ｆ瀽鍜岀鍙?80 鍙闂€?
  fi
  [[ $PKG_FAMILY == "debian" ]] && rm -f /etc/nginx/sites-enabled/filebrowser-acme
  rm -f "$acme_conf"
  nginx -t
  systemctl reload nginx
}

configure_certificate_renewal() {
  [[ "${NGINX_MODE:-}" == "caddy" ]] && return
  install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-shared-caddy.sh <<'EOF'
#!/usr/bin/env bash
if systemctl is-active --quiet shared-caddy 2>/dev/null; then
  systemctl reload shared-caddy || systemctl restart shared-caddy
fi
EOF
  chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/reload-shared-caddy.sh
  systemctl enable --now certbot.timer 2>/dev/null || true
}

install_filebrowser() {
  local admin_user_regex
  local existing_database="false"
  local existing_port=""

  if systemctl is-active --quiet filebrowser 2>/dev/null; then
    warn "妫€娴嬪埌姝ｅ湪杩愯鐨?File Browser锛屾殏鏃跺仠姝㈡湇鍔′互瀹夊叏淇敼鏁版嵁搴撱€?
    systemctl stop filebrowser
  fi

  if command -v filebrowser >/dev/null 2>&1; then
    warn "妫€娴嬪埌宸插畨瑁?File Browser锛屽皢澶嶇敤鐜版湁绋嬪簭銆?
  else
    info "浠?File Browser 瀹樻柟瀹夎鑴氭湰瀹夎绋嬪簭..."
    curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash
  fi

  command -v filebrowser >/dev/null 2>&1 || die "File Browser 瀹夎澶辫触銆?
  install -d -m 0755 /etc/filebrowser "$FB_ROOT"

  if [[ -f $FB_DB ]]; then
    existing_database="true"
    existing_port="$(filebrowser config cat --database "$FB_DB" 2>/dev/null | awk '/^[[:space:]]*Port:/ {print $2; exit}' || true)"
    if [[ $existing_port =~ ^[0-9]+$ ]]; then
      FB_PORT="$existing_port"
      info "妫€娴嬪埌宸叉湁 File Browser 鍚庣绔彛锛?{FB_PORT}"
    fi
    choose_available_port
    BACKUP="${FB_DB}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$FB_DB" "$BACKUP"
    warn "宸叉湁鏁版嵁搴撳凡澶囦唤鍒帮細$BACKUP"
  else
    choose_available_port
    filebrowser config init --database "$FB_DB"
  fi

  if [[ $existing_database == "true" ]]; then
    warn "妫€娴嬪埌宸叉湁鏁版嵁搴擄紝灏嗕繚鐣欏師浜戠洏鏍圭洰褰曢厤缃€?
    filebrowser config set \
      --database "$FB_DB" \
      --address 127.0.0.1 \
      --port "$FB_PORT" \
      --baseurl ""
  else
    filebrowser config set \
      --database "$FB_DB" \
      --address 127.0.0.1 \
      --port "$FB_PORT" \
      --root "$FB_ROOT" \
      --baseurl ""
  fi

  admin_user_regex="${ADMIN_USER//./\\.}"
  if filebrowser users ls --database "$FB_DB" 2>/dev/null | grep -Eq "(^|[[:space:]])${admin_user_regex}([[:space:]]|$)"; then
    filebrowser users update "$ADMIN_USER" --password "$ADMIN_PASS" --perm.admin --database "$FB_DB"
  else
    filebrowser users add "$ADMIN_USER" "$ADMIN_PASS" --perm.admin --database "$FB_DB"
  fi

  chown -R root:root /etc/filebrowser
  chmod 0755 "$FB_ROOT"
  chmod 0600 "$FB_DB"
}

write_service() {
  info "閰嶇疆 systemd 鏈嶅姟..."
  cat > /etc/systemd/system/filebrowser.service <<EOF
[Unit]
Description=File Browser
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=$(command -v filebrowser) --database ${FB_DB}
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now filebrowser
  systemctl is-active --quiet filebrowser || {
    journalctl -u filebrowser --no-pager -n 30 >&2
    die "File Browser 鏈嶅姟鍚姩澶辫触銆?
  }
}

verify_login() {
  local http_code
  local attempt

  info "绛夊緟 File Browser 鍚姩骞堕獙璇佺鐞嗗憳璐﹀彿瀵嗙爜..."
  for attempt in $(seq 1 30); do
    http_code="$(curl -sS -o /dev/null -w '%{http_code}' \
      -H 'Content-Type: application/json' \
      --data "{\"username\":\"${ADMIN_USER}\",\"password\":\"${ADMIN_PASS}\"}" \
      "http://127.0.0.1:${FB_PORT}/api/login" 2>/dev/null || true)"

    if [[ $http_code == "200" ]]; then
      info "绠＄悊鍛樼櫥褰曢獙璇佹垚鍔熴€?
      return
    fi

    if ! systemctl is-active --quiet filebrowser; then
      journalctl -u filebrowser --no-pager -n 30 >&2 || true
      die "File Browser 鏈嶅姟宸查€€鍑猴紝宸茶緭鍑烘湇鍔℃棩蹇椼€?
    fi

    sleep 1
  done

  journalctl -u filebrowser --no-pager -n 30 >&2 || true
  die "绠＄悊鍛樼櫥褰曢獙璇佸け璐ワ紙HTTP ${http_code:-unknown}锛夛紝宸茶緭鍑?File Browser 鏈嶅姟鏃ュ織銆?
}

write_nginx_config() {
  info "閰嶇疆闅旂鐨?Nginx HTTPS 鍙嶅悜浠ｇ悊涓庝笂浼犻檺鍒?.."
  if [[ "${NGINX_MODE:-standalone}" == "system" ]]; then
    NGINX_CONF="/etc/nginx/conf.d/filebrowser-${DOMAIN}.conf"
    cat > "$NGINX_CONF" <<EOF
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size ${UPLOAD_LIMIT};
    client_body_timeout 3600s;

    location / {
        proxy_pass http://127.0.0.1:${FB_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$http_connection;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF
    nginx -t
    systemctl reload nginx
    return
  fi

  NGINX_CONF="/etc/nginx/filebrowser-standalone.conf"
  install -d -m 0755 /etc/nginx/filebrowser-shared
  cat > "$NGINX_CONF" <<EOF
pid /run/filebrowser-nginx.pid;
error_log /var/log/nginx/filebrowser-error.log;

events {}

http {
    include /etc/nginx/mime.types;
    access_log /var/log/nginx/filebrowser-access.log;
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_comp_level 5;
    gzip_types application/javascript application/json text/css text/plain image/svg+xml;
    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        '' close;
    }

    # Managed extension point for services sharing public HTTPS with File Browser.
    include /etc/nginx/filebrowser-shared/*.conf;

    server {
        listen ${PUBLIC_PORT} ssl http2;
        listen [::]:${PUBLIC_PORT} ssl http2;
        server_name ${DOMAIN};

        ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
        # TLS 1.2 is intentionally used for compatibility with older Nginx/OpenSSL
        # combinations and mobile browsers that may fail on unstable TLS 1.3 links.
        ssl_protocols TLSv1.2;
        ssl_session_cache shared:FileBrowserSSL:10m;
        ssl_session_timeout 1d;
        ssl_session_tickets off;
        ssl_buffer_size 4k;

        client_max_body_size ${UPLOAD_LIMIT};
        client_body_timeout 3600s;

        location / {
            proxy_pass http://127.0.0.1:${FB_PORT};
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_buffering off;
            proxy_request_buffering off;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
        }
    }
}
EOF
  cat > /etc/systemd/system/filebrowser-nginx.service <<EOF
[Unit]
Description=Standalone Nginx reverse proxy for File Browser
After=network-online.target filebrowser.service
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=$(command -v nginx) -t -c ${NGINX_CONF}
ExecStart=$(command -v nginx) -c ${NGINX_CONF} -g "daemon off;"
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now filebrowser-nginx
}

write_caddy_config() {
  info "閰嶇疆 File Browser 涓?NaiveProxy 鍏辩敤鐨?Caddy HTTPS 鍏ュ彛..."
  ensure_caddy_binary
  ensure_shared_caddy_user
  install -d -m 750 -o root -g "$CADDY_SERVICE_USER" \
    "$CADDY_DIR" "$CADDY_SITE_DIR" "$CADDY_ROUTE_DIR"

  migrate_v12_filebrowser_merge
  ensure_distinct_naive_domain
  ensure_domain_not_owned_by_standalone_site
  write_shared_caddyfile
  repair_existing_naive_site

  # File Browser 濮嬬粓淇濈暀涓虹嫭绔嬪煙鍚嶇珯鐐癸紱涓嶈鎶婂畠鍚堝苟杩?Naive 鐨?:443 绔欑偣鍧椼€?  rm -f "${CADDY_ROUTE_DIR}/${DOMAIN}/naive.caddy"
  rm -f "${CADDY_ROUTE_DIR}/${DOMAIN}/naive.caddy"
  rmdir "${CADDY_ROUTE_DIR}/${DOMAIN}" 2>/dev/null || true
  cat >"${CADDY_SITE_DIR}/filebrowser-${DOMAIN}.caddy" <<EOF
${DOMAIN} {
    encode gzip
    request_body {
        max_size ${UPLOAD_LIMIT}
    }
    # 仅导入同一域名的路径路由（如 XHTTP、订阅）；Naive 必须使用独立域名和独立站点。
    import ${CADDY_ROUTE_DIR}/${DOMAIN}/*.caddy
    reverse_proxy 127.0.0.1:${FB_PORT}
}
EOF
  chown root:"$CADDY_SERVICE_USER" "$CADDYFILE" "${CADDY_SITE_DIR}/filebrowser-${DOMAIN}.caddy"
  chmod 640 "$CADDYFILE" "${CADDY_SITE_DIR}/filebrowser-${DOMAIN}.caddy"

  cat >"$CADDY_SERVICE_FILE" <<EOF
[Unit]
Description=Shared Caddy reverse proxy and NaiveProxy entry
After=network-online.target filebrowser.service
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

  "$CADDY_BIN" validate --config "$CADDYFILE" --adapter caddyfile >/dev/null ||
    die "Caddy 閰嶇疆鏍￠獙澶辫触銆?
  systemctl disable --now filebrowser-nginx 2>/dev/null || true
  systemctl daemon-reload
  systemctl enable "$CADDY_SERVICE" >/dev/null
  if systemctl is-active --quiet "$CADDY_SERVICE"; then
    systemctl restart "$CADDY_SERVICE"
  else
    systemctl start "$CADDY_SERVICE"
  fi
  systemctl is-active --quiet "$CADDY_SERVICE" || {
    journalctl -u "$CADDY_SERVICE" --no-pager -n 50 >&2 || true
    die "Shared Caddy 鍚姩澶辫触銆?
  }
  verify_naive_filebrowser_precedence
}

save_and_show_credentials() {
  local scheme="https"
  local public_address="${DOMAIN}"
  [[ $PUBLIC_PORT != "443" ]] && public_address="${DOMAIN}:${PUBLIC_PORT}"

  umask 077
  cat > "$CREDS_FILE" <<EOF
File Browser URL: ${scheme}://${public_address}
Username: ${ADMIN_USER}
Password: ${ADMIN_PASS}
Storage directory: ${FB_ROOT}
Upload limit: ${UPLOAD_LIMIT}
EOF
  chmod 0600 "$CREDS_FILE"

  echo
  printf "${GREEN}============================================================${NC}\n"
  printf "${GREEN} File Browser 瀹夎瀹屾垚${NC}\n"
  printf "${GREEN}============================================================${NC}\n"
  printf "璁块棶鍦板潃锛?s://%s\n" "$scheme" "$public_address"
  printf "绠＄悊鍛樿处鍙凤細%s\n" "$ADMIN_USER"
  printf "绠＄悊鍛樺瘑鐮侊細%s\n" "$ADMIN_PASS"
  printf "瀛樺偍鐩綍锛?s\n" "$FB_ROOT"
  printf "涓婁紶闄愬埗锛?s\n" "$UPLOAD_LIMIT"
  printf "鍑嵁澶囦唤锛?s锛堜粎 root 鍙锛塡n" "$CREDS_FILE"
  printf "${GREEN}============================================================${NC}\n"
}

main() {
  require_root
  require_interactive_terminal
  info "File Browser 瀹夎鑴氭湰鐗堟湰锛?{SCRIPT_VERSION}"
  detect_os
  collect_input
  cleanup_legacy_filebrowser_https
  cleanup_legacy_filebrowser_http
  choose_https_port
  install_packages
  configure_security
  ensure_certificate
  configure_certificate_renewal
  install_filebrowser
  write_service
  verify_login
  write_caddy_config
  save_and_show_credentials
}

trap 'printf "${RED}[x] 瀹夎鍦ㄧ %s 琛屽け璐ワ紝璇锋鏌ヤ笂鏂归敊璇俊鎭€?{NC}\n" "$LINENO" >&2' ERR
# File Browser 涓?NaiveProxy 鐢卞悓涓€涓?shared-caddy 鎸変笉鍚屽煙鍚嶅叡鐢ㄥ叕缃?443銆?choose_https_port() {
choose_https_port() {
  PUBLIC_PORT="443"
  if port_is_available "$PUBLIC_PORT"; then
    NGINX_MODE="caddy"
    return
  fi
  if systemctl is-active --quiet shared-caddy 2>/dev/null && port_owner_is_shared_caddy "$PUBLIC_PORT"; then
    NGINX_MODE="caddy"
    return
  fi
  if systemctl is-active --quiet caddy 2>/dev/null ||
    ss -H -ltnp 'sport = :443' 2>/dev/null | grep -qE 'caddy|caddy-naive'; then
    die "检测到另一个 Caddy 正在占用 TCP/443。为避免覆盖现有站点，本脚本不会接管；请先迁移为 shared-caddy 或释放 443。"
  fi
  die "TCP/443 is occupied by a non-Caddy service. Stop or move the old 443 service first."
}

main "$@"
