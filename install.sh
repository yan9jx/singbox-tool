#!/usr/bin/env bash
set -Eeuo pipefail

# GitHub-ready interactive File Browser installer for Debian/Ubuntu and RHEL-compatible VPSes.

FB_DB="/etc/filebrowser/filebrowser.db"
FB_ROOT="/srv/filebrowser"
FB_PORT="8080"
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

  read -r -p "是否自动申请并配置 HTTPS？[Y/n]: " ENABLE_HTTPS
  ENABLE_HTTPS="${ENABLE_HTTPS:-Y}"
  [[ $ENABLE_HTTPS =~ ^[YyNn]$ ]] || die "请输入 Y 或 N。"

  if [[ $ENABLE_HTTPS =~ ^[Yy]$ ]]; then
    read -r -p "请输入用于 Let's Encrypt 通知的邮箱（可留空）: " CERT_EMAIL
  fi

  ADMIN_PASS="$(random_password)"
  [[ ${#ADMIN_PASS} -eq 24 ]] || die "生成随机密码失败。"
}

install_packages() {
  info "安装 Nginx、curl 和 Certbot..."
  if [[ $PKG_FAMILY == "debian" ]]; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y nginx curl ca-certificates certbot python3-certbot-nginx
  else
    if ! dnf install -y nginx curl ca-certificates certbot python3-certbot-nginx; then
      warn "默认软件源缺少 Certbot，尝试启用 EPEL 后重试..."
      dnf install -y epel-release
      dnf install -y nginx curl ca-certificates certbot python3-certbot-nginx
    fi
  fi

  systemctl enable --now nginx
}

configure_security() {
  info "检查防火墙与 SELinux..."

  if command -v getenforce >/dev/null 2>&1 && [[ $(getenforce) == "Enforcing" ]]; then
    setsebool -P httpd_can_network_connect 1
  fi

  if systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --reload
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "^Status: active"; then
    ufw allow "Nginx Full"
  fi
}

install_filebrowser() {
  local admin_user_regex
  local existing_database="false"

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
    BACKUP="${FB_DB}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$FB_DB" "$BACKUP"
    warn "已有数据库已备份到：$BACKUP"
  else
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

  info "验证管理员账号密码..."
  http_code="$(curl -sS -o /dev/null -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    --data "{\"username\":\"${ADMIN_USER}\",\"password\":\"${ADMIN_PASS}\"}" \
    "http://127.0.0.1:${FB_PORT}/api/login" || true)"

  [[ $http_code == "200" ]] || die "管理员登录验证失败（HTTP ${http_code:-unknown}），安装已停止，请检查 File Browser 日志。"
}

write_nginx_config() {
  info "配置 Nginx 反向代理与上传限制..."
  cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

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
        proxy_set_header Connection "upgrade";
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF

  if [[ $PKG_FAMILY == "debian" ]]; then
    ln -sfn "$NGINX_CONF" /etc/nginx/sites-enabled/filebrowser
    rm -f /etc/nginx/sites-enabled/default
  fi

  nginx -t
  systemctl reload nginx
}

configure_https() {
  [[ $ENABLE_HTTPS =~ ^[Yy]$ ]] || return 0

  info "申请 Let's Encrypt HTTPS 证书..."
  CERTBOT_ARGS=(--nginx -d "$DOMAIN" --non-interactive --agree-tos --redirect)
  if [[ -n ${CERT_EMAIL:-} ]]; then
    CERTBOT_ARGS+=(--email "$CERT_EMAIL")
  else
    CERTBOT_ARGS+=(--register-unsafely-without-email)
  fi

  if certbot "${CERTBOT_ARGS[@]}"; then
    info "HTTPS 配置成功。"
  else
    warn "HTTPS 申请失败。请确认域名已解析到本机、80/443 端口已放行。HTTP 服务仍可使用。"
  fi
}

save_and_show_credentials() {
  local scheme="http"
  [[ $ENABLE_HTTPS =~ ^[Yy]$ && -d "/etc/letsencrypt/live/$DOMAIN" ]] && scheme="https"

  umask 077
  cat > "$CREDS_FILE" <<EOF
File Browser URL: ${scheme}://${DOMAIN}
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
  printf "访问地址：%s://%s\n" "$scheme" "$DOMAIN"
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
  detect_os
  collect_input
  install_packages
  configure_security
  install_filebrowser
  write_service
  verify_login
  write_nginx_config
  configure_https
  save_and_show_credentials
}

trap 'printf "${RED}[x] 安装在第 %s 行失败，请检查上方错误信息。${NC}\n" "$LINENO" >&2' ERR
main "$@"
