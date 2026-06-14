#!/usr/bin/env bash
set -Eeuo pipefail

# GitHub-ready interactive File Browser installer for Debian/Ubuntu and RHEL-compatible VPSes.

SCRIPT_VERSION="2026.06.14-5"
FB_DB="/etc/filebrowser/filebrowser.db"
FB_ROOT="/srv/filebrowser"
FB_PORT="8080"
PUBLIC_PORT="80"
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

check_web_port_conflicts() {
  local port=80

  if systemctl is-active --quiet filebrowser-nginx 2>/dev/null; then
    warn "检测到已有 File Browser 独立 Nginx，暂时停止以重新检测端口。"
    systemctl stop filebrowser-nginx
  fi

  if port_is_available "$port"; then
    return
  fi

  if command -v ss >/dev/null 2>&1 && ss -H -ltnp "sport = :${port}" 2>/dev/null | grep -q 'nginx'; then
    return
  fi

  warn "公网端口 80 已被其他服务占用，正在寻找空闲访问端口..."
  for port in $(seq 8000 8079); do
    if [[ $port != "$FB_PORT" ]] && port_is_available "$port"; then
      PUBLIC_PORT="$port"
      info "将使用公网访问端口：${PUBLIC_PORT}（443 保留给 sing-box）"
      return
    fi
  done

  die "未能在 8000-8079 范围内找到空闲公网访问端口。"
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
    warn "Let's Encrypt 证书文件已保留，443 端口将继续留给 sing-box。"

    if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
      nginx -t
      systemctl reload nginx
      info "Nginx 已重载，旧 File Browser 443 监听已清理。"
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

  ADMIN_PASS="$(random_password)"
  [[ ${#ADMIN_PASS} -eq 24 ]] || die "生成随机密码失败。"
}

install_packages() {
  info "安装 Nginx 和 curl..."
  if [[ $PKG_FAMILY == "debian" ]]; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y nginx curl ca-certificates
  else
    dnf install -y nginx curl ca-certificates
  fi

  [[ $PUBLIC_PORT == "80" ]] && systemctl enable nginx
}

configure_security() {
  info "检查防火墙与 SELinux..."

  if command -v getenforce >/dev/null 2>&1 && [[ $(getenforce) == "Enforcing" ]]; then
    setsebool -P httpd_can_network_connect 1
  fi

  if systemctl is-active --quiet firewalld 2>/dev/null; then
    if [[ $PUBLIC_PORT == "80" ]]; then
      firewall-cmd --permanent --add-service=http
    else
      firewall-cmd --permanent --add-port="${PUBLIC_PORT}/tcp"
    fi
    firewall-cmd --reload
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "^Status: active"; then
    if [[ $PUBLIC_PORT == "80" ]]; then
      ufw allow "Nginx HTTP"
    else
      ufw allow "${PUBLIC_PORT}/tcp"
    fi
  fi
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
  info "配置 Nginx 反向代理与上传限制..."
  if [[ $PUBLIC_PORT == "80" ]]; then
    systemctl disable filebrowser-nginx 2>/dev/null || true
    cat > "$NGINX_CONF" <<EOF
server {
    listen ${PUBLIC_PORT};
    listen [::]:${PUBLIC_PORT};
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
    fi

    nginx -t
    systemctl enable --now nginx
    systemctl reload nginx
  else
    NGINX_CONF="/etc/nginx/filebrowser-standalone.conf"
    cat > "$NGINX_CONF" <<EOF
pid /run/filebrowser-nginx.pid;
error_log /var/log/nginx/filebrowser-error.log;

events {}

http {
    include /etc/nginx/mime.types;
    access_log /var/log/nginx/filebrowser-access.log;

    server {
        listen ${PUBLIC_PORT};
        listen [::]:${PUBLIC_PORT};
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
  fi
}

save_and_show_credentials() {
  local scheme="http"
  local public_address="${DOMAIN}"
  [[ $PUBLIC_PORT != "80" ]] && public_address="${DOMAIN}:${PUBLIC_PORT}"

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
  check_web_port_conflicts
  install_packages
  configure_security
  install_filebrowser
  write_service
  verify_login
  write_nginx_config
  save_and_show_credentials
}

trap 'printf "${RED}[x] 安装在第 %s 行失败，请检查上方错误信息。${NC}\n" "$LINENO" >&2' ERR
main "$@"
