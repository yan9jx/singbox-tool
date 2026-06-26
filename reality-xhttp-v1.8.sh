#!/usr/bin/env bash
# Standalone VLESS + XHTTP + REALITY installer for Debian/Ubuntu.
# This is a direct Xray listener. It never stops Nginx/File Browser/reverse proxy
# services. If TCP/443 is already occupied, it chooses a free *443 fallback port.
set -Eeuo pipefail

SCRIPT_VERSION="v1.9"
XRAY_ROOT="/opt/reality-xhttp"
XRAY_BIN="$XRAY_ROOT/xray"
XRAY_DIR="/etc/reality-xhttp"
XRAY_CONFIG="$XRAY_DIR/config.json"
XRAY_INFO="$XRAY_DIR/node-info.env"
XRAY_SERVICE="/etc/systemd/system/reality-xhttp.service"
SERVICE_NAME="reality-xhttp"
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

install_xray() {
  local machine asset latest tmp zip binary
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64) asset="Xray-linux-64.zip" ;;
    aarch64|arm64) asset="Xray-linux-arm64-v8a.zip" ;;
    *) die "Unsupported CPU architecture: $machine" ;;
  esac
  latest="$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
  [[ -n "$latest" ]] || die "Could not fetch latest Xray version."
  tmp="$(mktemp -d)"; zip="$tmp/xray.zip"
  curl -fL "https://github.com/XTLS/Xray-core/releases/download/${latest}/${asset}" -o "$zip"
  unzip -q "$zip" -d "$tmp"
  binary="$tmp/xray"
  [[ -x "$binary" ]] || die "Xray archive is incomplete."
  install -d -m 755 "$XRAY_ROOT"
  install -m 755 "$binary" "$XRAY_BIN"
  rm -rf "$tmp"
  echo "Installed Xray: $latest"
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

generate_reality_keys() {
  local output
  output="$("$XRAY_BIN" x25519 2>&1)" || die "Could not generate REALITY keys: $output"
  PRIVATE_KEY="$(printf '%s\n' "$output" | awk -F': *' 'tolower($1) ~ /^private[[:space:]]*key$/ { gsub(/\r/, "", $2); print $2; exit }')"
  PUBLIC_KEY="$(printf '%s\n' "$output" | awk -F': *' 'tolower($1) ~ /^(public[[:space:]]*key|password \(publickey\))$/ { gsub(/\r/, "", $2); print $2; exit }')"
  [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || { printf '%s\n' "$output" >&2; die "Could not parse REALITY key output."; }
}

write_config() {
  local uuid="$1" port="$2" server_name="$3" destination="$4" private_key="$5" short_id="$6" path="$7"
  mkdir -p "$XRAY_DIR"
  cat >"$XRAY_CONFIG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": $port,
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "$uuid", "email": "reality-xhttp" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "xhttp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "$destination",
        "xver": 0,
        "serverNames": ["$server_name"],
        "privateKey": "$private_key",
        "shortIds": ["$short_id"]
      },
      "xhttpSettings": { "path": "$path", "mode": "auto" }
    }
  }],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
EOF
  chmod 600 "$XRAY_CONFIG"
}

test_config() {
  local output
  if ! output="$("$XRAY_BIN" run -test -format json -c "$XRAY_CONFIG" 2>&1)"; then
    printf '%s\n' "$output" >&2
    die "Xray config validation failed."
  fi
}

write_service() {
  cat >"$XRAY_SERVICE" <<EOF
[Unit]
Description=VLESS XHTTP REALITY Node
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
  chmod 644 "$XRAY_SERVICE"
}

start_service() {
  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
  systemctl is-active --quiet "$SERVICE_NAME" || { journalctl -u "$SERVICE_NAME" -n 50 --no-pager >&2 || true; die "Xray did not start."; }
}

make_link() {
  local uuid="$1" host="$2" port="$3" server_name="$4" public_key="$5" short_id="$6" path="$7" name="$8"
  printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=xhttp&path=%s&mode=auto#%s' \
    "$uuid" "$host" "$port" "$server_name" "$public_key" "$short_id" "$path" "$name"
}

write_info() {
  local name="$1" host="$2" port="$3" uuid="$4" server_name="$5" destination="$6" private_key="$7" public_key="$8" short_id="$9" path="${10}" link="${11}"
  cat >"$XRAY_INFO" <<EOF
NODE_NAME='$name'
SERVER_ADDRESS='$host'
PORT='$port'
UUID='$uuid'
SNI='$server_name'
DESTINATION='$destination'
PRIVATE_KEY='$private_key'
PUBLIC_KEY='$public_key'
SHORT_ID='$short_id'
PATH='$path'
LINK='$link'
EOF
  chmod 600 "$XRAY_INFO"
}

install_node() {
  install_deps
  install_xray
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true

  local port input host name uuid destination default_sni server_name short_id path link public_ip
  port="$(choose_listen_port)"
  read -r -p "Listen TCP port [$port]: " input
  port="${input:-$port}"
  validate_port "$port" || die "Port must be 1-65535."
  port_is_listening "$port" && die "TCP/$port is occupied."

  read -r -p "REALITY target domain:port [www.yahoo.co.jp:443]: " destination
  destination="${destination:-www.yahoo.co.jp:443}"
  [[ "$destination" =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]] || die "Target must be domain:port."
  default_sni="${destination%:*}"
  read -r -p "REALITY SNI [$default_sni]: " server_name
  server_name="${server_name:-$default_sni}"
  [[ "$server_name" =~ ^[A-Za-z0-9.-]+$ ]] || die "Invalid SNI."

  public_ip="$(public_ipv4)"
  read -r -p "Node address, IP or resolved domain [${public_ip:-manual required}]: " host
  host="${host:-$public_ip}"
  [[ -n "$host" && "$host" != *[[:space:]]* ]] || die "Node address cannot be empty or contain spaces."

  read -r -p "Node name [Reality-XHTTP]: " name
  name="${name:-Reality-XHTTP}"; name="${name// /-}"
  uuid="$(cat /proc/sys/kernel/random/uuid)"
  short_id="$(openssl rand -hex 8)"
  path="/$(openssl rand -hex 8)"
  generate_reality_keys
  write_config "$uuid" "$port" "$server_name" "$destination" "$PRIVATE_KEY" "$short_id" "$path"
  test_config
  write_service
  start_service
  link="$(make_link "$uuid" "$host" "$port" "$server_name" "$PUBLIC_KEY" "$short_id" "$path" "$name")"
  write_info "$name" "$host" "$port" "$uuid" "$server_name" "$destination" "$PRIVATE_KEY" "$PUBLIC_KEY" "$short_id" "$path" "$link"
  echo
  echo "REALITY + XHTTP node created:"
  echo "$link"
  echo
  qrencode -t ANSIUTF8 "$link"
}

info_value() { sed -n "s/^$1='\\(.*\\)'$/\\1/p" "$XRAY_INFO"; }
require_node_files() { [[ -f "$XRAY_INFO" && -f "$XRAY_CONFIG" ]] || die "Node not found. Install it first."; }
show_link() { require_node_files; info_value LINK; }
print_link_qr() { echo "$1"; echo; qrencode -t ANSIUTF8 "$1"; }
show_status() { [[ -x "$XRAY_BIN" ]] && "$XRAY_BIN" version | head -n1 || true; systemctl status "$SERVICE_NAME" --no-pager; }
show_logs() { journalctl -u "$SERVICE_NAME" -n 100 --no-pager; }
restart_node() { systemctl restart "$SERVICE_NAME"; systemctl is-active --quiet "$SERVICE_NAME" || die "Restart failed."; echo "Restarted."; }

change_port() {
  require_node_files
  local old_port new_port name host uuid server_name destination private_key public_key short_id path link
  old_port="$(info_value PORT)"; name="$(info_value NODE_NAME)"; host="$(info_value SERVER_ADDRESS)"; uuid="$(info_value UUID)"
  server_name="$(info_value SNI)"; destination="$(info_value DESTINATION)"; private_key="$(info_value PRIVATE_KEY)"
  public_key="$(info_value PUBLIC_KEY)"; short_id="$(info_value SHORT_ID)"; path="$(info_value PATH)"
  read -r -p "New listen TCP port [$old_port]: " new_port
  new_port="${new_port:-$old_port}"
  validate_port "$new_port" || die "Port must be 1-65535."
  [[ "$new_port" == "$old_port" ]] && { echo "Port unchanged."; return; }
  port_is_listening "$new_port" && die "TCP/$new_port is occupied."
  write_config "$uuid" "$new_port" "$server_name" "$destination" "$private_key" "$short_id" "$path"
  test_config
  systemctl restart "$SERVICE_NAME"
  systemctl is-active --quiet "$SERVICE_NAME" || die "Service failed after port change."
  link="$(make_link "$uuid" "$host" "$new_port" "$server_name" "$public_key" "$short_id" "$path" "$name")"
  write_info "$name" "$host" "$new_port" "$uuid" "$server_name" "$destination" "$private_key" "$public_key" "$short_id" "$path" "$link"
  print_link_qr "$link"
}

change_link_host() {
  require_node_files
  local host old_host port name uuid server_name public_key short_id path link destination private_key
  old_host="$(info_value SERVER_ADDRESS)"; port="$(info_value PORT)"; name="$(info_value NODE_NAME)"; uuid="$(info_value UUID)"
  server_name="$(info_value SNI)"; public_key="$(info_value PUBLIC_KEY)"; short_id="$(info_value SHORT_ID)"; path="$(info_value PATH)"
  destination="$(info_value DESTINATION)"; private_key="$(info_value PRIVATE_KEY)"
  read -r -p "Node address, IP or resolved domain [$old_host]: " host
  host="${host:-$old_host}"
  [[ -n "$host" && "$host" != *[[:space:]]* ]] || die "Node address cannot be empty or contain spaces."
  link="$(make_link "$uuid" "$host" "$port" "$server_name" "$public_key" "$short_id" "$path" "$name")"
  write_info "$name" "$host" "$port" "$uuid" "$server_name" "$destination" "$private_key" "$public_key" "$short_id" "$path" "$link"
  print_link_qr "$link"
}

upgrade_xray() { install_xray; restart_node; }

uninstall_node() {
  confirm_yes "Uninstall the REALITY + XHTTP node?" || return
  systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$XRAY_SERVICE" "$XRAY_CONFIG" "$XRAY_INFO"
  rmdir "$XRAY_DIR" 2>/dev/null || true
  systemctl daemon-reload
  echo "Node removed. Xray binary is kept at $XRAY_ROOT."
}

menu() {
  cat <<EOF
========================================
 REALITY + XHTTP Node Script $SCRIPT_VERSION
========================================
1. Install / rebuild node
2. Show node link and QR code
3. Show status
4. Show logs
5. Restart Xray
6. Change listen port
7. Set node address
8. Check / update Xray-core
9. Uninstall node
0. Exit
EOF
  local choice
  read -r -p "Choose: " choice
  case "$choice" in
    1) install_node ;;
    2) print_link_qr "$(show_link)" ;;
    3) show_status ;;
    4) show_logs ;;
    5) restart_node ;;
    6) change_port ;;
    7) change_link_host ;;
    8) upgrade_xray ;;
    9) uninstall_node ;;
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
  update) upgrade_xray ;;
  uninstall) uninstall_node ;;
  *) menu ;;
esac
