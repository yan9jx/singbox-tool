#!/usr/bin/env bash
set -Eeuo pipefail

# GitHub-ready interactive File Browser installer for Debian/Ubuntu and RHEL-compatible VPSes.

SCRIPT_VERSION="2026.06.15-8"
FB_DB="/etc/filebrowser/filebrowser.db"
FB_ROOT="/srv/filebrowser"
FB_PORT="8080"
PUBLIC_PORT="443"
CREDS_FILE="/root/filebrowser-credentials.txt"
NGINX_CONF=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { printf "${GREEN}[+]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
die() { printf "${RED}[x]${NC} %s\n" "$*" >&2; exit 1; }

require_root() {
  [[ ${EUID} -eq 0 ]] || die "请使用 root 权限运行此脚本。"
}

require_interactive_terminal() {
  [[ -t 0 ]] || die "此脚本需要交互输入，请先下载后执行，不要使用 curl | bash。"
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

choose_available_port() {
  local port

  if port_is_available "$FB_PORT"; then
    return
  fi

  warn "端口 ${FB_PORT} 已被其他程序占用，正在寻找空闲端口..."
  for port in $(seq 8081 8999); do
    if port_is_available "$port"; then
      FB_PORT="$port"
      info "将使用空闲后端端口：${FB_PORT}"
      return
    fi
  done

  die "未能在 8081-8999 范围内找到空闲端口。"
}

choose_https_port() {
  local port
  if systemctl is-active --quiet filebrowser-nginx 2>/dev/null; then
    warn "检测到已有 File Browser 独立 Nginx，暂时停止以重新检测端口。"
    systemctl stop filebrowser-nginx
  fi

  if port_is_available "$PUBLIC_PORT"; then
    return
  fi

  warn "标准 HTTPS 端口 ${PUBLIC_PORT} 已被其他服务占用，正在寻找空闲备用端口..."
  for port in $(seq 8443 8499); do
    if [[ $port != "$FB_PORT" ]] && port_is_available "$port"; then
      PUBLIC_PORT="$port"
      info "将使用备用 HTTPS 端口：${PUBLIC_PORT}"
      return
    fi
  done

  die "443 和 8443-8499 范围内均未找到空闲 HTTPS 端口。"
}

cleanup_legacy_filebrowser_https() {
  local config
  local backup_dir="/root/filebrowser-nginx-backup-$(date +%Y%m%d-%H%M%S)"
  local cleaned="false"

  info "检查旧版 File Browser HTTPS/Nginx 残留..."
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

      warn "已备份并禁用旧 File Browser HTTPS 配置：$config"
      cleaned="true"
    fi
  done

  if [[ $cleaned == "true" ]]; then
    info "旧配置备份目录：${backup_dir}"
    warn "Let's Encrypt 证书文件已保留；File Browser 将使用标准 HTTPS 443，sing-box 的 2443 不受影响。"

    if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
      nginx -t
      systemctl reload nginx
      info "Nginx 已重载，旧 File Browser 443 监听已清理。"
    fi
  fi
}

cleanup_legacy_filebrowser_http() {
  local config
  local backup_dir="/root/filebrowser-nginx-backup-$(date +%Y%m%d-%H%M%S)"
  local cleaned="false"

  info "检查旧版 File Browser HTTP/Nginx 残留..."
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

      warn "已备份并禁用旧 File Browser HTTP 配置：$config"
      cleaned="true"
    fi
  done

  if [[ $cleaned == "true" ]]; then
    info "旧配置备份目录：${backup_dir}"
    if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
      nginx -t
      systemctl reload nginx
    fi
  fi
}

detect_os() {
  [[ -r /etc/os-release ]] || die "无法识别系统。仅支持 Debian/Ubuntu 和 RHEL 系发行版。"
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
      die "不支持当前系统：${PRETTY_NAME:-unknown}"
      ;;
  esac
}

collect_input() {
  echo
  read -r -p "请输入绑定域名（例如 cloud.example.com）: " DOMAIN
  valid_domain "$DOMAIN" || die "域名格式不正确。请输入不带 http:// 或路径的完整域名。"

  read -r -p "请输入上传文件大小限制 [默认 10G，可用示例：500M、20G]: " UPLOAD_LIMIT
  UPLOAD_LIMIT="${UPLOAD_LIMIT:-10G}"
  valid_size "$UPLOAD_LIMIT" || die "上传限制格式不正确，仅支持正整数加 M/G，例如 500M 或 20G。"

  read -r -p "请输入管理员账号 [默认 admin]: " ADMIN_USER
  ADMIN_USER="${ADMIN_USER:-admin}"
  [[ $ADMIN_USER =~ ^[A-Za-z0-9_.-]{3,32}$ ]] || die "账号仅允许 3-32 位字母、数字、下划线、点和横线。"

  read -r -p "请输入云盘存储目录 [默认 /srv/filebrowser]: " INPUT_ROOT
  FB_ROOT="${INPUT_ROOT:-$FB_ROOT}"
  [[ $FB_ROOT == /* ]] || die "存储目录必须是绝对路径。"
  [[ $FB_ROOT != "/" ]] || die "不能将系统根目录作为云盘目录。"

  read -r -p "请输入用于 Let's Encrypt 通知的邮箱（已有证书时可留空）: " CERT_EMAIL

  ADMIN_PASS="$(random_password)"
  [[ ${#ADMIN_PASS} -eq 24 ]] || die "生成随机密码失败。"
}

install_packages() {
  info "安装 Nginx、curl 和 Certbot..."
  if [[ $PKG_FAMILY == "debian" ]]; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y nginx curl ca-certificates certbot
  else
    if ! dnf install -y nginx curl ca-certificates certbot; then
      dnf install -y epel-release
      dnf install -y nginx curl ca-certificates certbot
    fi
  fi
}

configure_security() {
  info "检查防火墙与 SELinux..."

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

  if [[ -s "${cert_dir}/fullchain.pem" && -s "${cert_dir}/privkey.pem" ]]; then
    info "检测到已有 HTTPS 证书，将直接复用。"
    return
  fi

  certbot_args=(certonly -d "$DOMAIN" --non-interactive --agree-tos)
  if [[ -n ${CERT_EMAIL:-} ]]; then
    certbot_args+=(--email "$CERT_EMAIL")
  else
    certbot_args+=(--register-unsafely-without-email)
  fi

  if port_is_available 80; then
    info "使用临时端口 80 申请 Let's Encrypt 证书..."
    certbot "${certbot_args[@]}" --standalone
    return
  fi

  if ! command -v ss >/dev/null 2>&1 || ! ss -H -ltnp "sport = :80" 2>/dev/null | grep -q 'nginx'; then
    die "未找到已有证书，且端口 80 被非 Nginx 服务占用，无法安全完成 Let's Encrypt 验证。"
  fi

  info "通过现有 Nginx 的临时 ACME 路由申请 Let's Encrypt 证书..."
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
    die "Let's Encrypt 证书申请失败，请确认域名解析和端口 80 可访问。"
  fi
  [[ $PKG_FAMILY == "debian" ]] && rm -f /etc/nginx/sites-enabled/filebrowser-acme
  rm -f "$acme_conf"
  nginx -t
  systemctl reload nginx
}

configure_certificate_renewal() {
  install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/reload-filebrowser-nginx.sh <<'EOF'
#!/usr/bin/env bash
systemctl restart filebrowser-nginx
EOF
  chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/reload-filebrowser-nginx.sh
  systemctl enable --now certbot.timer 2>/dev/null || true
}

install_filebrowser() {
  local admin_user_regex
  local existing_database="false"
  local existing_port=""

  if systemctl is-active --quiet filebrowser 2>/dev/null; then
    warn "检测到正在运行的 File Browser，暂时停止服务以安全修改数据库。"
    systemctl stop filebrowser
  fi

  if command -v filebrowser >/dev/null 2>&1; then
    warn "检测到已安装 File Browser，将复用现有程序。"
  else
    info "从 File Browser 官方安装脚本安装程序..."
    curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash
  fi

  command -v filebrowser >/dev/null 2>&1 || die "File Browser 安装失败。"
  install -d -m 0755 /etc/filebrowser "$FB_ROOT"

  if [[ -f $FB_DB ]]; then
    existing_database="true"
    existing_port="$(filebrowser config cat --database "$FB_DB" 2>/dev/null | awk '/^[[:space:]]*Port:/ {print $2; exit}' || true)"
    if [[ $existing_port =~ ^[0-9]+$ ]]; then
      FB_PORT="$existing_port"
      info "检测到已有 File Browser 后端端口：${FB_PORT}"
    fi
    choose_available_port
    BACKUP="${FB_DB}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$FB_DB" "$BACKUP"
    warn "已有数据库已备份到：$BACKUP"
  else
    choose_available_port
    filebrowser config init --database "$FB_DB"
  fi

  if [[ $existing_database == "true" ]]; then
    warn "检测到已有数据库，将保留原云盘根目录配置。"
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
  info "配置 systemd 服务..."
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
    die "File Browser 服务启动失败。"
  }
}

verify_login() {
  local http_code
  local attempt

  info "等待 File Browser 启动并验证管理员账号密码..."
  for attempt in $(seq 1 30); do
    http_code="$(curl -sS -o /dev/null -w '%{http_code}' \
      -H 'Content-Type: application/json' \
      --data "{\"username\":\"${ADMIN_USER}\",\"password\":\"${ADMIN_PASS}\"}" \
      "http://127.0.0.1:${FB_PORT}/api/login" 2>/dev/null || true)"

    if [[ $http_code == "200" ]]; then
      info "管理员登录验证成功。"
      return
    fi

    if ! systemctl is-active --quiet filebrowser; then
      journalctl -u filebrowser --no-pager -n 30 >&2 || true
      die "File Browser 服务已退出，已输出服务日志。"
    fi

    sleep 1
  done

  journalctl -u filebrowser --no-pager -n 30 >&2 || true
  die "管理员登录验证失败（HTTP ${http_code:-unknown}），已输出 File Browser 服务日志。"
}

write_nginx_config() {
  info "配置隔离的 Nginx HTTPS 反向代理与上传限制..."
  NGINX_CONF="/etc/nginx/filebrowser-standalone.conf"
  cat > "$NGINX_CONF" <<EOF
pid /run/filebrowser-nginx.pid;
error_log /var/log/nginx/filebrowser-error.log;

events {}

http {
    include /etc/nginx/mime.types;
    access_log /var/log/nginx/filebrowser-access.log;
    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        '' close;
    }

    server {
        listen ${PUBLIC_PORT} ssl;
        listen [::]:${PUBLIC_PORT} ssl;
        server_name ${DOMAIN};

        ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
        # TLS 1.2 is intentionally used for compatibility with older Nginx/OpenSSL
        # combinations and mobile browsers that may fail on unstable TLS 1.3 links.
        ssl_protocols TLSv1.2;
        ssl_session_cache shared:FileBrowserSSL:10m;
        ssl_session_timeout 1d;
        ssl_session_tickets off;

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
  printf "${GREEN} File Browser 安装完成${NC}\n"
  printf "${GREEN}============================================================${NC}\n"
  printf "访问地址：%s://%s\n" "$scheme" "$public_address"
  printf "管理员账号：%s\n" "$ADMIN_USER"
  printf "管理员密码：%s\n" "$ADMIN_PASS"
  printf "存储目录：%s\n" "$FB_ROOT"
  printf "上传限制：%s\n" "$UPLOAD_LIMIT"
  printf "凭据备份：%s（仅 root 可读）\n" "$CREDS_FILE"
  printf "${GREEN}============================================================${NC}\n"
}

main() {
  require_root
  require_interactive_terminal
  info "File Browser 安装脚本版本：${SCRIPT_VERSION}"
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
  write_nginx_config
  save_and_show_credentials
}

trap 'printf "${RED}[x] 安装在第 %s 行失败，请检查上方错误信息。${NC}\n" "$LINENO" >&2' ERR
main "$@"
