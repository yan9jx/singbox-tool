#!/usr/bin/env bash
# Standalone AnyTLS installer for Debian/Ubuntu.
# It never stops Nginx/File Browser/reverse proxy services. If TCP/443 is
# already occupied, it chooses a free *443 fallback port.
set -Eeuo pipefail

SCRIPT_VERSION="v1.2"
INSTALL_DIR="/opt/anytls"
BIN="$INSTALL_DIR/anytls-server"
CONFIG_DIR="/etc/anytls"
INFO_FILE="$CONFIG_DIR/node-info.env"
SERVICE_FILE="/etc/systemd/system/anytls.service"
SERVICE_NAME="anytls"
DEFAULT_PORT=443

die() { echo "ERROR: $*" >&2; exit 1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Please run as root."; command -v systemctl >/dev/null || die "systemd is required."; }
confirm_yes() { local answer; read -r -p "$1 [Y/n]: " answer; [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]; }
validate_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
port_is_listening() { ss -H -lnt "sport = :$1" 2>/dev/null | grep -q .; }

install_deps() {
  local missing=() cmd
  for cmd in curl unzip openssl qrencode ss; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  (( ${#missing[@]} == 0 )) && return
  command -v apt-get >/dev/null 2>&1 || die "Only Debian/Ubuntu with apt-get is supported."
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl unzip openssl qrencode ca-certificates iproute2
}

public_ipv4() { curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true; }

urlencode() {
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
  local machine asset latest tmp archive binary
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64) asset="anytls_*_linux_amd64.zip" ;;
    aarch64|arm64) asset="anytls_*_linux_arm64.zip" ;;
    *) die "Unsupported CPU architecture: $machine" ;;
  esac
  latest="$(curl -fsSL https://api.github.com/repos/anytls/anytls-go/releases/latest | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
  [[ -n "$latest" ]] || die "Could not fetch latest anytls-go version."
  asset="${asset/\*/${latest#v}}"
  tmp="$(mktemp -d)"
  archive="$tmp/anytls.zip"
  curl -fL "https://github.com/anytls/anytls-go/releases/download/${latest}/${asset}" -o "$archive"
  unzip -q "$archive" -d "$tmp"
  binary="$(find "$tmp" -type f -name anytls-server -perm -u+x -print -quit)"
  [[ -n "$binary" ]] || die "anytls-server was not found in the release archive."
  install -d -m 755 "$INSTALL_DIR"
  install -m 755 "$binary" "$BIN"
  rm -rf "$tmp"
  echo "Installed AnyTLS: $latest"
}

choose_listen_port() {
  local candidate
  if ! port_is_listening "$DEFAULT_PORT"; then
    printf '%s' "$DEFAULT_PORT"
    return
  fi
  echo "TCP/443 is occupied. Keeping the existing cloud disk/reverse proxy service untouched." >&2
  for candidate in 1443 2443 3443 4443 5443 6443 7443 8443 9443 10443 11443 12443; do
    if ! port_is_listening "$candidate"; then
      printf '%s' "$candidate"
      return
    fi
  done
  die "TCP/443 and common *443 fallback ports are all occupied."
}

write_service() {
  local port="$1" password="$2"
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=AnyTLS Server
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

make_link() {
  local password="$1" host="$2" port="$3" name="$4" sni="$5"
  printf 'anytls://%s@%s:%s/?sni=%s&insecure=1#%s' "$(urlencode "$password")" "$host" "$port" "$(urlencode "$sni")" "$(urlencode "$name")"
}

write_info() {
  local name="$1" host="$2" port="$3" password="$4" sni="$5" link="$6"
  install -d -m 700 "$CONFIG_DIR"
  cat >"$INFO_FILE" <<EOF
NODE_NAME='$name'
SERVER_ADDRESS='$host'
PORT='$port'
PASSWORD='$password'
SNI='$sni'
LINK='$link'
EOF
  chmod 600 "$INFO_FILE"
}

info_value() { sed -n "s/^$1='\\(.*\\)'$/\\1/p" "$INFO_FILE"; }
require_node_files() { [[ -x "$BIN" && -f "$INFO_FILE" && -f "$SERVICE_FILE" ]] || die "AnyTLS node not found. Install it first."; }

start_service() {
  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
  systemctl is-active --quiet "$SERVICE_NAME" || { journalctl -u "$SERVICE_NAME" -n 50 --no-pager >&2 || true; die "AnyTLS did not start."; }
}

install_node() {
  install_deps
  install_anytls
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true

  local port input host name password link public_ip sni default_sni
  port="$(choose_listen_port)"
  read -r -p "Listen TCP port [$port]: " input
  port="${input:-$port}"
  validate_port "$port" || die "Port must be 1-65535."
  port_is_listening "$port" && die "TCP/$port is occupied."

  public_ip="$(public_ipv4)"
  read -r -p "Node address, IP or resolved domain [${public_ip:-manual required}]: " host
  host="${host:-$public_ip}"
  [[ -n "$host" && "$host" != *[[:space:]]* ]] || die "Node address cannot be empty or contain spaces."
  if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    default_sni="www.yahoo.co.jp"
  else
    default_sni="$host"
  fi
  read -r -p "TLS SNI for clients [$default_sni]: " sni
  sni="${sni:-$default_sni}"
  [[ "$sni" =~ ^[A-Za-z0-9.-]+$ ]] || die "Invalid SNI."

  read -r -p "Node name [AnyTLS-Backup]: " name
  name="${name:-AnyTLS-Backup}"
  name="${name//$'\n'/}"
  password="$(openssl rand -hex 24)"
  link="$(make_link "$password" "$host" "$port" "$name" "$sni")"
  write_service "$port" "$password"
  write_info "$name" "$host" "$port" "$password" "$sni" "$link"
  start_service

  echo
  echo "AnyTLS node created. The reference implementation uses a self-signed certificate, so insecure=1 is required in the link:"
  print_all_formats "$name" "$host" "$port" "$password" "$sni" "$link"
}

show_link() { require_node_files; info_value LINK; }
print_link_qr() { echo "$1"; echo; qrencode -t ANSIUTF8 "$1"; }
print_all_formats() {
  local name="$1" host="$2" port="$3" password="$4" sni="$5" link="$6"
  echo "$link"
  echo
  qrencode -t ANSIUTF8 "$link"
  cat <<EOF

sing-box outbound:
{
  "type": "anytls",
  "tag": "$name",
  "server": "$host",
  "server_port": $port,
  "password": "$password",
  "tls": {
    "enabled": true,
    "server_name": "$sni",
    "insecure": true
  }
}

mihomo proxy:
- name: "$name"
  type: anytls
  server: $host
  port: $port
  password: "$password"
  client-fingerprint: chrome
  udp: true
  sni: "$sni"
  skip-cert-verify: true
EOF
}
show_status() { [[ -x "$BIN" ]] && "$BIN" -h 2>&1 | head -n1 || true; systemctl status "$SERVICE_NAME" --no-pager; }
show_logs() { journalctl -u "$SERVICE_NAME" -n 100 --no-pager; }
restart_node() { systemctl restart "$SERVICE_NAME"; systemctl is-active --quiet "$SERVICE_NAME" || die "Restart failed."; echo "Restarted."; }

change_port() {
  require_node_files
  local old_port new_port password host name link sni
  old_port="$(info_value PORT)"; password="$(info_value PASSWORD)"; host="$(info_value SERVER_ADDRESS)"; name="$(info_value NODE_NAME)"; sni="$(info_value SNI)"
  read -r -p "New listen TCP port [$old_port]: " new_port
  new_port="${new_port:-$old_port}"
  validate_port "$new_port" || die "Port must be 1-65535."
  [[ "$new_port" == "$old_port" ]] && { echo "Port unchanged."; return; }
  port_is_listening "$new_port" && die "TCP/$new_port is occupied."
  write_service "$new_port" "$password"
  link="$(make_link "$password" "$host" "$new_port" "$name" "$sni")"
  write_info "$name" "$host" "$new_port" "$password" "$sni" "$link"
  systemctl daemon-reload
  restart_node
  print_all_formats "$name" "$host" "$new_port" "$password" "$sni" "$link"
}

change_link_host() {
  require_node_files
  local old_host host port password name link sni default_sni
  old_host="$(info_value SERVER_ADDRESS)"; port="$(info_value PORT)"; password="$(info_value PASSWORD)"; name="$(info_value NODE_NAME)"; sni="$(info_value SNI)"
  read -r -p "Node address, IP or resolved domain [$old_host]: " host
  host="${host:-$old_host}"
  [[ -n "$host" && "$host" != *[[:space:]]* ]] || die "Node address cannot be empty or contain spaces."
  default_sni="$sni"
  [[ -n "$default_sni" ]] || default_sni="$host"
  read -r -p "TLS SNI for clients [$default_sni]: " sni
  sni="${sni:-$default_sni}"
  [[ "$sni" =~ ^[A-Za-z0-9.-]+$ ]] || die "Invalid SNI."
  link="$(make_link "$password" "$host" "$port" "$name" "$sni")"
  write_info "$name" "$host" "$port" "$password" "$sni" "$link"
  print_all_formats "$name" "$host" "$port" "$password" "$sni" "$link"
}

reset_password() {
  require_node_files
  local port host name password link sni
  confirm_yes "Reset password? Old links will stop working." || return
  port="$(info_value PORT)"; host="$(info_value SERVER_ADDRESS)"; name="$(info_value NODE_NAME)"; sni="$(info_value SNI)"
  password="$(openssl rand -hex 24)"
  link="$(make_link "$password" "$host" "$port" "$name" "$sni")"
  write_service "$port" "$password"
  write_info "$name" "$host" "$port" "$password" "$sni" "$link"
  systemctl daemon-reload
  restart_node
  print_all_formats "$name" "$host" "$port" "$password" "$sni" "$link"
}

upgrade_anytls() { require_node_files; install_anytls; restart_node; }

uninstall_node() {
  confirm_yes "Uninstall the AnyTLS node created by this script?" || return
  systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$SERVICE_FILE" "$INFO_FILE"
  rmdir "$CONFIG_DIR" 2>/dev/null || true
  systemctl daemon-reload
  echo "AnyTLS node removed. Binary is kept at $INSTALL_DIR."
}

menu() {
  cat <<EOF
========================================
 AnyTLS Standalone Node Script $SCRIPT_VERSION
========================================
1. Install / rebuild node
2. Show node link and QR code
3. Show status
4. Show logs
5. Restart AnyTLS
6. Change listen port
7. Set node address
8. Reset password
9. Check / update anytls-go
10. Uninstall node
0. Exit
EOF
  local choice
  read -r -p "Choose: " choice
  case "$choice" in
    1) install_node ;;
    2)
      require_node_files
      print_all_formats "$(info_value NODE_NAME)" "$(info_value SERVER_ADDRESS)" "$(info_value PORT)" "$(info_value PASSWORD)" "$(info_value SNI)" "$(info_value LINK)"
      ;;
    3) show_status ;;
    4) show_logs ;;
    5) restart_node ;;
    6) change_port ;;
    7) change_link_host ;;
    8) reset_password ;;
    9) upgrade_anytls ;;
    10) uninstall_node ;;
    0) exit 0 ;;
    *) die "Invalid option." ;;
  esac
}

require_root
case "${1:-}" in
  install) install_node ;;
  link) show_link ;;
  status) show_status ;;
  logs) show_logs ;;
  restart) restart_node ;;
  port) change_port ;;
  host) change_link_host ;;
  password) reset_password ;;
  update) upgrade_anytls ;;
  uninstall) uninstall_node ;;
  *) menu ;;
esac
