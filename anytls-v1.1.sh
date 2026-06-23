#!/usr/bin/env bash
# AnyTLS (anytls-go reference implementation) installer for Debian/Ubuntu.
# It intentionally uses the reference implementation's self-signed TLS certificate.
set -Eeuo pipefail

SCRIPT_VERSION="v1.1"
INSTALL_DIR="/opt/anytls"
BIN="$INSTALL_DIR/anytls-server"
CONFIG_DIR="/etc/anytls"
INFO_FILE="$CONFIG_DIR/node-info.env"
SERVICE_FILE="/etc/systemd/system/anytls.service"
SERVICE_NAME="anytls"
DEFAULT_PORT=443

die() { echo "错误：$*" >&2; exit 1; }
require_root() { [[ $EUID -eq 0 ]] || die "请使用 root 运行。"; }
confirm_yes() { local answer; read -r -p "$1 [Y/n]: " answer; [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]; }
validate_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
port_is_listening() { ss -H -lnt "sport = :$1" 2>/dev/null | grep -q .; }

install_deps() {
  local missing=() command_name
  for command_name in curl unzip openssl qrencode ss; do
    command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
  done
  (( ${#missing[@]} == 0 )) && return
  command -v apt-get >/dev/null 2>&1 || die "仅支持 Debian/Ubuntu；请先安装：${missing[*]}"
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl unzip openssl qrencode ca-certificates iproute2
}

public_ipv4() { curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true; }

urlencode() {
  # Password is generated as hex, but this also keeps custom text safe in the URI.
  local string="$1" encoded="" character i
  for ((i = 0; i < ${#string}; i++)); do
    character="${string:i:1}"
    case "$character" in
      [a-zA-Z0-9.~_-]) encoded+="$character" ;;
      *) printf -v character '%%%02X' "'${character}"; encoded+="$character" ;;
    esac
  done
  printf '%s' "$encoded"
}

install_anytls() {
  local machine asset latest temporary_directory archive binary
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64) asset="anytls_*_linux_amd64.zip" ;;
    aarch64|arm64) asset="anytls_*_linux_arm64.zip" ;;
    *) die "不支持的 CPU 架构：$machine" ;;
  esac
  latest="$(curl -fsSL https://api.github.com/repos/anytls/anytls-go/releases/latest | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
  [[ -n "$latest" ]] || die "无法获取 anytls-go 的最新版本。"
  temporary_directory="$(mktemp -d)"
  archive="$temporary_directory/anytls.zip"
  trap 'rm -rf "$temporary_directory"' RETURN
  # Release filenames are anytls_0.0.12_linux_amd64.zip, etc.
  asset="${asset/\*/${latest#v}}"
  curl -fL "https://github.com/anytls/anytls-go/releases/download/${latest}/${asset}" -o "$archive"
  unzip -q "$archive" -d "$temporary_directory"
  binary="$(find "$temporary_directory" -type f -name anytls-server -perm -u+x -print -quit)"
  [[ -n "$binary" ]] || die "下载包中未找到 anytls-server。"
  install -d -m 755 "$INSTALL_DIR"
  install -m 755 "$binary" "$BIN"
  rm -rf "$temporary_directory"
  trap - RETURN
  echo "已安装 AnyTLS：$latest"
}

choose_listen_port() {
  local candidate
  if ! port_is_listening "$DEFAULT_PORT"; then
    printf '%s' "$DEFAULT_PORT"
    return 0
  fi
  # Public 443 is in use: default to the first available *443 port.
  # The installer still presents this value for manual override.
  for candidate in 1443 2443 3443 4443 5443 6443 7443 9443 10443 11443 12443; do
    if ! port_is_listening "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  die "443 and all common *443 ports are occupied; enter a free port manually after freeing one."
}

write_service() {
  local port="$1" password="$2"
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=AnyTLS Server (anytls-go)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=LOG_LEVEL=warn
ExecStart=$BIN -l 0.0.0.0:$port -p $password
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$SERVICE_FILE"
}

write_info() {
  local name="$1" host="$2" port="$3" password="$4" link="$5"
  install -d -m 700 "$CONFIG_DIR"
  cat >"$INFO_FILE" <<EOF
NODE_NAME='$name'
SERVER_ADDRESS='$host'
PORT='$port'
PASSWORD='$password'
LINK='$link'
EOF
  chmod 600 "$INFO_FILE"
}

info_value() { sed -n "s/^$1='\(.*\)'$/\1/p" "$INFO_FILE"; }
require_node_files() { [[ -x "$BIN" && -f "$INFO_FILE" && -f "$SERVICE_FILE" ]] || die "未找到 AnyTLS 节点，请先安装。"; }

start_service() {
  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
  systemctl is-active --quiet "$SERVICE_NAME" || {
    journalctl -u "$SERVICE_NAME" -n 50 --no-pager >&2 || true
    die "AnyTLS 未能启动。"
  }
}

make_link() {
  local password="$1" host="$2" port="$3" name="$4"
  printf 'anytls://%s@%s:%s/?insecure=1#%s' "$(urlencode "$password")" "$host" "$port" "$(urlencode "$name")"
}

install_node() {
  install_deps
  install_anytls
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true

  local port input host name password link public_ip
  port="$(choose_listen_port)"
  read -r -p "监听 TCP 端口 [$port]: " input
  port="${input:-$port}"
  validate_port "$port" || die "端口必须在 1 到 65535 之间。"
  if port_is_listening "$port"; then die "TCP/$port 已被占用。"; fi

  public_ip="$(public_ipv4)"
  read -r -p "节点连接地址（IP 或已解析域名）[${public_ip:-请手动输入}]: " host
  host="${host:-$public_ip}"
  [[ -n "$host" && "$host" != *[[:space:]]* ]] || die "节点地址不能为空或含空格。"
  read -r -p "节点名称 [AnyTLS-Backup]: " name
  name="${name:-AnyTLS-Backup}"
  name="${name//$'\n'/}"
  password="$(openssl rand -hex 24)"
  link="$(make_link "$password" "$host" "$port" "$name")"
  write_service "$port" "$password"
  write_info "$name" "$host" "$port" "$password" "$link"
  start_service
  echo
  echo "节点已创建。AnyTLS 参考实现使用自签证书，因此链接中的 insecure=1 是必要的。"
  print_link_qr "$link"
}

show_link() { require_node_files; info_value LINK; }
print_link_qr() { echo "$1"; echo; qrencode -t ANSIUTF8 "$1"; }
show_status() {
  [[ -x "$BIN" ]] && "$BIN" -h 2>&1 | head -n1 || true
  [[ -f "$INFO_FILE" ]] && echo "监听端口：$(info_value PORT)" || true
  systemctl status "$SERVICE_NAME" --no-pager
}
show_logs() { journalctl -u "$SERVICE_NAME" -n 80 --no-pager; }
restart_node() { systemctl restart "$SERVICE_NAME"; systemctl is-active --quiet "$SERVICE_NAME" || die "重启失败。"; echo "已重启。"; }

change_port() {
  require_node_files
  local old_port new_port password host name link
  old_port="$(info_value PORT)"; password="$(info_value PASSWORD)"; host="$(info_value SERVER_ADDRESS)"; name="$(info_value NODE_NAME)"
  read -r -p "新的监听 TCP 端口 [$old_port]: " new_port
  new_port="${new_port:-$old_port}"
  validate_port "$new_port" || die "端口必须在 1 到 65535 之间。"
  [[ "$new_port" == "$old_port" ]] && { echo "端口未改变。"; return; }
  port_is_listening "$new_port" && die "TCP/$new_port 已被占用。"
  write_service "$new_port" "$password"
  link="$(make_link "$password" "$host" "$new_port" "$name")"
  write_info "$name" "$host" "$new_port" "$password" "$link"
  systemctl daemon-reload
  restart_node
  print_link_qr "$link"
}

change_link_host() {
  require_node_files
  local old_host host port password name link
  old_host="$(info_value SERVER_ADDRESS)"; port="$(info_value PORT)"; password="$(info_value PASSWORD)"; name="$(info_value NODE_NAME)"
  read -r -p "节点连接地址（IP 或已解析域名）[$old_host]: " host
  host="${host:-$old_host}"
  [[ -n "$host" && "$host" != *[[:space:]]* ]] || die "节点地址不能为空或含空格。"
  link="$(make_link "$password" "$host" "$port" "$name")"
  write_info "$name" "$host" "$port" "$password" "$link"
  echo "连接地址已更新。服务端无需重启。"
  print_link_qr "$link"
}

reset_password() {
  require_node_files
  local port host name password link
  confirm_yes "确定更换密码？旧链接会立刻失效" || return
  port="$(info_value PORT)"; host="$(info_value SERVER_ADDRESS)"; name="$(info_value NODE_NAME)"
  password="$(openssl rand -hex 24)"
  link="$(make_link "$password" "$host" "$port" "$name")"
  write_service "$port" "$password"
  write_info "$name" "$host" "$port" "$password" "$link"
  systemctl daemon-reload
  restart_node
  print_link_qr "$link"
}

upgrade_anytls() {
  require_node_files
  local before
  before="$(sha256sum "$BIN" | awk '{print $1}')"
  install_anytls
  restart_node
  echo "AnyTLS 已更新（旧二进制 SHA-256：$before）。"
}

uninstall_node() {
  confirm_yes "确定卸载本脚本创建的 AnyTLS 服务和节点信息？" || return
  systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$SERVICE_FILE" "$INFO_FILE"
  rmdir "$CONFIG_DIR" 2>/dev/null || true
  systemctl daemon-reload
  echo "已卸载服务；二进制保留在 $INSTALL_DIR。"
}

menu() {
  cat <<EOF
========================================
 AnyTLS 独立节点脚本 $SCRIPT_VERSION
========================================
1. 安装 / 重建节点
2. 查看节点链接和二维码
3. 查看状态
4. 查看日志
5. 重启 AnyTLS
6. 更换监听端口
7. 设置节点连接地址（IP / 域名）
8. 更换密码
9. 检查 / 更新 anytls-go
10. 卸载节点
0. 退出
EOF
  local choice
  read -r -p "请选择：" choice
  case "$choice" in
    1) install_node ;; 2) print_link_qr "$(show_link)" ;; 3) show_status ;;
    4) show_logs ;; 5) restart_node ;; 6) change_port ;; 7) change_link_host ;;
    8) reset_password ;; 9) upgrade_anytls ;; 10) uninstall_node ;; 0) exit 0 ;;
    *) die "无效选项。" ;;
  esac
}

require_root
case "${1:-}" in
  install) install_node ;; link) show_link ;; status) show_status ;; logs) show_logs ;;
  restart) restart_node ;; port) change_port ;; host) change_link_host ;;
  password) reset_password ;; update) upgrade_anytls ;; uninstall) uninstall_node ;;
  *) menu ;;
esac
