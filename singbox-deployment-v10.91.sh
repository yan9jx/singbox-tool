#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="$CONFIG_DIR/config.json"
INFO_FILE="$CONFIG_DIR/node-info.env"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
DEFAULT_PORT="443"
SERVER_NAME="www.microsoft.com"
SCRIPT_TITLE="宇宙监察委员会sing-box部署局"
SCRIPT_VERSION="v10.91"

die() {
  echo "错误：$*" >&2
  exit 1
}

confirm() {
  local prompt="$1"
  local answer
  read -r -p "$prompt [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

confirm_yes() {
  local prompt="$1"
  local answer
  read -r -p "$prompt [Y/n]: " answer
  [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]
}

check_port_available() {
  local port="$1"
  local owner
  owner="$(ss -H -lntp "sport = :$port" 2>/dev/null || true)"
  if [[ -n "$owner" && "$owner" != *"sing-box"* ]]; then
    echo >&2
    echo "警告：端口 $port 已被其他程序占用：" >&2
    echo "$owner" >&2
    return 1
  fi
  return 0
}

prompt_port() {
  local prompt="$1"
  local default_port="${2:-}"
  local port
  while true; do
    if [[ -n "$default_port" ]]; then
      read -r -p "$prompt [${default_port}]: " port
      port="${port:-$default_port}"
    else
      read -r -p "$prompt: " port
    fi

    if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
      echo "端口必须是 1 到 65535 之间的数字，请重新输入。" >&2
      continue
    fi
    if ! check_port_available "$port"; then
      echo "请重新输入其他端口。" >&2
      continue
    fi
    printf '%s' "$port"
    return
  done
}

require_root() {
  [[ $EUID -eq 0 ]] || die "请使用 root 运行此脚本。"
  command -v systemctl >/dev/null || die "当前系统不支持 systemd。"
}

find_singbox() {
  SB_BIN="${SB_BIN:-$(command -v sing-box || true)}"
  [[ -n "$SB_BIN" && -x "$SB_BIN" ]]
}

install_dependencies() {
  local missing=()
  local command_name
  for command_name in curl openssl tar qrencode ss; do
    command -v "$command_name" >/dev/null || missing+=("$command_name")
  done

  if (( ${#missing[@]} > 0 )); then
    command -v apt-get >/dev/null || die "缺少 ${missing[*]}，且当前系统不支持自动安装。"
    echo "正在安装必要组件..."
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl openssl tar qrencode ca-certificates iproute2
  fi
}

install_singbox_core() {
  local machine arch version temp_dir archive binary
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "暂不支持当前架构：$machine" ;;
  esac

  echo "未找到 sing-box 核心，正在自动安装..."
  version="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest |
    sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
  [[ -n "$version" ]] || die "无法获取 sing-box 最新版本。"

  temp_dir="$(mktemp -d)"
  archive="$temp_dir/sing-box.tar.gz"
  curl -fL "https://github.com/SagerNet/sing-box/releases/download/${version}/sing-box-${version#v}-linux-${arch}.tar.gz" -o "$archive"
  tar -xzf "$archive" -C "$temp_dir"
  binary="$(find "$temp_dir" -type f -name sing-box | head -n1)"
  [[ -n "$binary" ]] || die "sing-box 安装包中未找到核心程序。"
  install -m 755 "$binary" /usr/local/bin/sing-box
  rm -rf "$temp_dir"
  SB_BIN="/usr/local/bin/sing-box"
  echo "sing-box 核心安装完成：$version"
}

show_status() {
  local service port server bbr swap ntp core
  if systemctl is-active --quiet sing-box >/dev/null 2>&1; then
    service="运行中"
  elif [[ -f "$SERVICE_FILE" ]]; then
    service="未运行"
  else
    service="未安装"
  fi
  port=""
  server=""
  if [[ -f "$INFO_FILE" ]]; then
    port="$(sed -n "s/^PORT='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"
    server="$(sed -n "s/^SERVER_NAME='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"
  fi
  bbr="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")"
  swap="$(free -m 2>/dev/null | awk '/Swap:/{print $2 "MB"}')"
  ntp="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo "未知")"
  core="$(sing-box version 2>/dev/null | head -n1 || echo "未安装")"

  echo "状态：sing-box=$service | 端口=${port:-未配置} | 伪装=${server:-未配置}"
  echo "系统：BBR=$bbr | SWAP=${swap:-未知} | 时间同步=$ntp"
  echo "核心：$core"
}

configure_bbr() {
  local current available bbr_file="/etc/sysctl.d/99-singbox-bbr.conf"
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
    echo "警告：当前内核不支持 BBR，已跳过，不影响 sing-box 安装。"
    return
  fi

  cat >"$bbr_file" <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

  if sysctl -w net.core.default_qdisc=fq >/dev/null &&
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null; then
    echo "BBR + FQ 已启用，当前算法：$(sysctl -n net.ipv4.tcp_congestion_control)"
  else
    rm -f "$bbr_file"
    echo "警告：BBR 设置失败，已跳过，不影响 sing-box 安装。"
  fi
}

enable_time_sync() {
  echo
  echo "正在开启系统自动对时..."
  if command -v timedatectl >/dev/null; then
    timedatectl set-ntp true 2>/dev/null || true
  fi
  systemctl enable --now systemd-timesyncd 2>/dev/null || true
  systemctl enable --now chronyd 2>/dev/null || true
  systemctl enable --now chrony 2>/dev/null || true

  local synchronized
  synchronized="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  if [[ "$synchronized" == "yes" ]]; then
    echo "自动对时已开启，系统时间已同步。"
  else
    echo "自动对时已开启；首次同步可能需要稍等片刻。"
  fi
}

configure_swap() {
  local active_swap swap_mb available_bytes required_bytes swap_conf="/etc/sysctl.d/99-singbox-swap.conf"
  if ! command -v swapon >/dev/null || ! command -v mkswap >/dev/null || ! command -v free >/dev/null; then
    command -v apt-get >/dev/null || die "系统缺少 SWAP 管理组件，且不支持自动安装。"
    echo "正在安装 SWAP 管理组件..."
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y util-linux procps
  fi

  echo
  echo "当前内存与 SWAP 状态："
  free -h
  echo

  active_swap="$(swapon --noheadings --show=NAME 2>/dev/null || true)"
  if [[ -n "$active_swap" ]]; then
    echo "检测到系统已经启用 SWAP："
    swapon --show
    if grep -qx "/swapfile" <<<"$active_swap" && confirm "是否删除 /swapfile？"; then
      swapoff /swapfile
      sed -i '\|^[[:space:]]*/swapfile[[:space:]]|d' /etc/fstab
      rm -f /swapfile /etc/sysctl.d/99-singbox-swap.conf
      echo "本脚本创建的 /swapfile 已删除。"
    else
      echo "为避免覆盖现有 SWAP，本脚本不会重复创建。"
    fi
    return
  fi

  read -r -p "请输入要创建的 SWAP 大小（MB）[1024]: " swap_mb
  swap_mb="${swap_mb:-1024}"
  [[ "$swap_mb" =~ ^[0-9]+$ ]] || die "SWAP 大小必须是数字。"
  (( swap_mb >= 256 && swap_mb <= 8192 )) || die "SWAP 大小必须在 256MB 到 8192MB 之间。"

  available_bytes="$(df --output=avail -B1 / | tail -n1 | tr -d ' ')"
  required_bytes=$(( swap_mb * 1024 * 1024 + 512 * 1024 * 1024 ))
  (( available_bytes >= required_bytes )) || die "磁盘空间不足；创建后至少需要保留 512MB 可用空间。"

  if [[ -e /swapfile ]] && ! confirm "发现未启用的 /swapfile，是否覆盖？"; then
    echo "已取消创建 SWAP。"
    return
  fi

  echo "正在创建 ${swap_mb}MB SWAP..."
  rm -f /swapfile
  if ! command -v fallocate >/dev/null || ! fallocate -l "${swap_mb}M" /swapfile 2>/dev/null; then
    dd if=/dev/zero of=/swapfile bs=1M count="$swap_mb" status=progress
  fi
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  if ! swapon /swapfile 2>/dev/null; then
    echo "快速创建的 SWAP 不兼容当前文件系统，正在使用兼容方式重建..."
    rm -f /swapfile
    dd if=/dev/zero of=/swapfile bs=1M count="$swap_mb" status=progress
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
  fi

  sed -i '\|^[[:space:]]*/swapfile[[:space:]]|d' /etc/fstab
  echo "/swapfile none swap sw 0 0" >>/etc/fstab
  cat >"$swap_conf" <<EOF
vm.swappiness=10
EOF
  sysctl -w vm.swappiness=10 >/dev/null

  echo "SWAP 创建完成，并已设置为开机自动启用。"
  swapon --show
}

v10_get_current_public_ipv6() {
  local ip
  ip="$(curl -6fsS --max-time 10 https://api64.ipify.org 2>/dev/null || true)"
  [[ "$ip" == *:* ]] || return 1
  printf '%s' "$ip"
}

build_vless_link_from_info() {
  local requested_host="${1:-}" node_name link_host port uuid public_key short_id server_name
  node_name="$(sed -n "s/^NODE_NAME='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"
  link_host="${requested_host:-$(sed -n "s/^LINK_HOST='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)}"
  port="$(sed -n "s/^PORT='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"
  uuid="$(sed -n "s/^UUID='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"
  public_key="$(sed -n "s/^PUBLIC_KEY='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"
  short_id="$(sed -n "s/^SHORT_ID='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"
  server_name="$(sed -n "s/^SERVER_NAME='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"

  [[ -n "$node_name" && -n "$link_host" && -n "$port" && -n "$uuid" && -n "$public_key" && -n "$short_id" && -n "$server_name" ]] || return 1
  # IPv6 literals in a URI must be enclosed in square brackets.
  [[ "$link_host" == *:* ]] && link_host="[$link_host]"
  printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&flow=xtls-rprx-vision#%s' \
    "$uuid" "$link_host" "$port" "$server_name" "$public_key" "$short_id" "$node_name"
}

show_link() {
  if [[ ! -f "$INFO_FILE" ]]; then
    die "没有已保存的节点链接，请先选择 1 安装/重建节点。"
  fi

  local public_ipv4 public_ipv6 link_host primary_link ipv6_link primary_label
  public_ipv4="$(sed -n "s/^PUBLIC_IP='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"
  public_ipv6="$(sed -n "s/^PUBLIC_IPV6='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"
  link_host="$(sed -n "s/^LINK_HOST='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"
  [[ -n "$public_ipv4" ]] || die "节点信息文件损坏，请重新安装节点。"
  link_host="${link_host:-$public_ipv4}"
  [[ -n "$public_ipv6" ]] || public_ipv6="$(v10_get_current_public_ipv6 || true)"

  # Always derive links from structured fields, never from a saved VLESS_LINK.
  # Keep the hostname selected by menu item 10 as the primary/QR link.
  primary_link="$(build_vless_link_from_info "$link_host")"
  [[ -n "$primary_link" ]] || die "节点信息文件损坏，请重新安装节点。"
  ipv6_link=""
  [[ -n "$public_ipv6" ]] && ipv6_link="$(build_vless_link_from_info "$public_ipv6")"
  if [[ "$link_host" == "$public_ipv4" ]]; then
    primary_label="IPv4 节点链接（二维码）："
  else
    primary_label="当前连接域名节点链接（二维码）："
  fi

  echo
  echo "$primary_label"
  echo "$primary_link"
  if [[ -n "$ipv6_link" ]]; then
    echo
    echo "IPv6 节点链接："
    echo "$ipv6_link"
  else
    echo
    echo "IPv6 节点链接：当前 VPS 未检测到公网 IPv6，未生成。"
  fi

  install_dependencies
  echo
  echo "节点二维码（当前连接地址）："
  qrencode -t ANSIUTF8 "$primary_link"
}

post_install_check() {
  local port="$1"
  echo
  echo "端口检查："
  if ss -H -lnt "sport = :${port}" 2>/dev/null | grep -q .; then
    echo "本机 TCP 端口 ${port} 已正常监听。"
  else
    echo "警告：本机 TCP 端口 ${port} 未监听，请检查 sing-box 日志。"
  fi

  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "^Status: active"; then
    echo "检测到 UFW 已开启，请确认已放行 TCP/${port}。"
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state 2>/dev/null | grep -q running; then
    if firewall-cmd --quiet --query-port="${port}/tcp" 2>/dev/null; then
      echo "firewalld 已放行 TCP/${port}。"
    else
      echo "警告：firewalld 尚未放行 TCP/${port}。"
    fi
  else
    echo "未检测到正在运行的 UFW/firewalld。"
  fi
  echo "云厂商安全组无法从 VPS 内可靠检测，请在控制台确认已放行 TCP/${port}。"
}

clean_old_setup() {
  systemctl stop sing-box 2>/dev/null || true
  systemctl disable sing-box 2>/dev/null || true
  rm -f "$SERVICE_FILE"
  rm -rf "$CONFIG_DIR"
  rm -f /root/vless.txt
  systemctl daemon-reload
  echo "旧 sing-box 服务、配置和旧节点信息已清除。"
}

install_node() {
  local clean_first=false
  echo
  echo "清理范围仅限旧 sing-box 服务、配置和节点信息，不会删除其他无关脚本。"
  if confirm "安装前是否清除之前安装的 sing-box / 旧脚本残留？"; then
    clean_first=true
    clean_old_setup
  fi

  install_dependencies
  find_singbox || install_singbox_core
  enable_time_sync

  local node_name
  read -r -p "请输入节点名称 [sing-box]: " node_name
  node_name="${node_name:-sing-box}"
  node_name="${node_name// /-}"
  node_name="${node_name//#/-}"
  node_name="${node_name//\'/-}"

  local port="${1:-}"
  if [[ -n "$port" ]]; then
    [[ "$port" =~ ^[0-9]+$ ]] || die "端口必须是数字。"
    (( port >= 1 && port <= 65535 )) || die "端口必须在 1 到 65535 之间。"
    check_port_available "$port" || die "指定端口 $port 已被占用。"
  else
    port="$(prompt_port "请输入端口" "$DEFAULT_PORT")"
  fi

  configure_bbr

  local keys private_key public_key uuid short_id tmp_config backup_file=""
  echo "正在生成新的 VLESS Reality 节点..."
  keys="$("$SB_BIN" generate reality-keypair)"
  private_key="$(awk -F': *' '/PrivateKey/{print $2; exit}' <<<"$keys")"
  public_key="$(awk -F': *' '/PublicKey/{print $2; exit}' <<<"$keys")"
  uuid="$(cat /proc/sys/kernel/random/uuid)"
  # Use a 16-character Reality short ID for maximum client compatibility.
  short_id="$(openssl rand -hex 8)"
  [[ -n "$private_key" && -n "$public_key" ]] || die "Reality 密钥生成失败。"

  mkdir -p "$CONFIG_DIR"
  tmp_config="$(mktemp)"
  trap 'rm -f "${tmp_config:-}"' RETURN

  cat >"$tmp_config" <<EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "vless",
      "listen": "::",
      "listen_port": $port,
      "users": [
        {
          "uuid": "$uuid",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$SERVER_NAME",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$SERVER_NAME",
            "server_port": 443
          },
          "private_key": "$private_key",
          "short_id": ["$short_id"]
        }
      }
    }
  ]
}
EOF

  "$SB_BIN" check -c "$tmp_config" >/dev/null

  if [[ "$clean_first" == false && -f "$CONFIG_FILE" ]]; then
    backup_file="${CONFIG_FILE}.backup.$(date +%Y%m%d-%H%M%S)"
    cp -a "$CONFIG_FILE" "$backup_file"
  fi
  install -m 600 "$tmp_config" "$CONFIG_FILE"

  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$SB_BIN run -c $CONFIG_FILE
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable sing-box >/dev/null
  if ! systemctl restart sing-box; then
    restore_backup "$backup_file"
    die "新节点启动失败。"
  fi

  sleep 2
  if ! systemctl is-active --quiet sing-box; then
    restore_backup "$backup_file"
    die "新节点未能持续运行，请查看：journalctl -u sing-box -e"
  fi

  local public_ip public_ipv6 vless_link
  public_ip="$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  public_ipv6="$(v10_get_current_public_ipv6 || true)"
  [[ -n "$public_ip" ]] || public_ip="YOUR_SERVER_IP"
  vless_link="vless://${uuid}@${public_ip}:${port}?encryption=none&security=reality&sni=${SERVER_NAME}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&flow=xtls-rprx-vision#${node_name}"

  cat >"$INFO_FILE" <<EOF
NODE_NAME='$node_name'
PUBLIC_IP='$public_ip'
PUBLIC_IPV6='$public_ipv6'
LINK_HOST='$public_ip'
PORT='$port'
UUID='$uuid'
PRIVATE_KEY='$private_key'
PUBLIC_KEY='$public_key'
SHORT_ID='$short_id'
SERVER_NAME='$SERVER_NAME'
VLESS_LINK='$vless_link'
EOF
  chmod 600 "$INFO_FILE"

  echo
  echo "安装完成，sing-box 正在运行。"
  post_install_check "$port"
  show_link
}

change_camouflage() {
  [[ -f "$CONFIG_FILE" && -f "$INFO_FILE" ]] || die "未找到现有节点，请先安装节点。"
  find_singbox || die "未找到 sing-box 核心。"

  local old_server new_server tmp_config backup_file tls_output
  local node_name public_ip link_host port uuid private_key public_key short_id vless_link
  old_server="$(sed -n "s/^SERVER_NAME='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"
  old_server="${old_server:-$SERVER_NAME}"

  echo
  echo "当前伪装网站：$old_server"
  read -r -p "请输入新的伪装网站域名（不要带 https://）: " new_server
  new_server="${new_server#https://}"
  new_server="${new_server#http://}"
  new_server="${new_server%%/*}"
  [[ "$new_server" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$new_server" == *.* ]] ||
    die "请输入正确的域名，例如 www.microsoft.com。"

  if [[ "$new_server" == "$old_server" ]]; then
    echo "新旧伪装网站相同，无需更换。"
    return
  fi

  echo "正在测试 $new_server 的 TLS 1.3 连接..."
  tls_output="$(timeout 10 openssl s_client -connect "${new_server}:443" -servername "$new_server" -tls1_3 </dev/null 2>/dev/null || true)"
  if ! grep -q "BEGIN CERTIFICATE" <<<"$tls_output"; then
    if ! confirm "未能确认该网站支持 TLS 1.3，仍然继续更换？"; then
      echo "已取消更换。"
      return
    fi
  fi

  tmp_config="$(mktemp)"
  backup_file="${CONFIG_FILE}.backup.$(date +%Y%m%d-%H%M%S)"
  cp -a "$CONFIG_FILE" "$backup_file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "${line//$old_server/$new_server}"
  done <"$CONFIG_FILE" >"$tmp_config"

  "$SB_BIN" check -c "$tmp_config" >/dev/null
  install -m 600 "$tmp_config" "$CONFIG_FILE"
  rm -f "$tmp_config"

  if ! systemctl restart sing-box || ! systemctl is-active --quiet sing-box; then
    cp -a "$backup_file" "$CONFIG_FILE"
    systemctl restart sing-box 2>/dev/null || true
    die "更换伪装网站失败，已恢复为 ${old_server}。"
  fi

  node_name="$(sed -n "s/^NODE_NAME='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"
  public_ip="$(sed -n "s/^PUBLIC_IP='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"
  link_host="$(sed -n "s/^LINK_HOST='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"
  port="$(sed -n "s/^PORT='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"
  uuid="$(sed -n "s/^UUID='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"
  private_key="$(sed -n "s/^PRIVATE_KEY='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"
  public_key="$(sed -n "s/^PUBLIC_KEY='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"
  short_id="$(sed -n "s/^SHORT_ID='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"
  [[ -n "$public_ip" && -n "$port" && -n "$uuid" && -n "$public_key" && -n "$short_id" ]] ||
    die "伪装已更换，但节点信息不完整，请重新安装节点以生成分享链接。"
  node_name="${node_name:-sing-box}"
  link_host="${link_host:-$public_ip}"
  vless_link="vless://${uuid}@${link_host}:${port}?encryption=none&security=reality&sni=${new_server}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&flow=xtls-rprx-vision#${node_name}"

  cat >"$INFO_FILE" <<EOF
NODE_NAME='$node_name'
PUBLIC_IP='$public_ip'
LINK_HOST='$link_host'
PORT='$port'
UUID='$uuid'
PRIVATE_KEY='$private_key'
PUBLIC_KEY='$public_key'
SHORT_ID='$short_id'
SERVER_NAME='$new_server'
VLESS_LINK='$vless_link'
EOF
  chmod 600 "$INFO_FILE"

  echo
  echo "伪装网站已从 ${old_server} 更换为 ${new_server}。"
  show_link
}

change_port() {
  [[ -f "$CONFIG_FILE" && -f "$INFO_FILE" ]] || die "未找到现有节点，请先安装节点。"
  find_singbox || die "未找到 sing-box 核心。"

  local new_port old_port node_name public_ip link_host uuid public_key short_id server_name
  new_port="$(prompt_port "请输入新端口")"

  old_port="$(sed -n "s/^PORT='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"
  node_name="$(sed -n "s/^NODE_NAME='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"
  public_ip="$(sed -n "s/^PUBLIC_IP='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"
  link_host="$(sed -n "s/^LINK_HOST='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"
  uuid="$(sed -n "s/^UUID='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"
  public_key="$(sed -n "s/^PUBLIC_KEY='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"
  short_id="$(sed -n "s/^SHORT_ID='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"
  server_name="$(sed -n "s/^SERVER_NAME='\(.*\)'$/\1/p" "$INFO_FILE" | head -n1)"
  [[ -n "$old_port" && -n "$uuid" && -n "$public_key" && -n "$short_id" ]] ||
    die "节点信息不完整，请重新安装节点。"
  node_name="${node_name:-sing-box}"
  server_name="${server_name:-$SERVER_NAME}"
  link_host="${link_host:-$public_ip}"

  local tmp_config backup_file vless_link
  tmp_config="$(mktemp)"
  backup_file="${CONFIG_FILE}.backup.$(date +%Y%m%d-%H%M%S)"
  cp -a "$CONFIG_FILE" "$backup_file"
  sed -E "s/(\"listen_port\"[[:space:]]*:[[:space:]]*)[0-9]+/\1${new_port}/" "$CONFIG_FILE" >"$tmp_config"
  "$SB_BIN" check -c "$tmp_config" >/dev/null
  install -m 600 "$tmp_config" "$CONFIG_FILE"
  rm -f "$tmp_config"

  if ! systemctl restart sing-box || ! systemctl is-active --quiet sing-box; then
    cp -a "$backup_file" "$CONFIG_FILE"
    systemctl restart sing-box 2>/dev/null || true
    die "更换端口失败，已恢复旧端口。"
  fi

  vless_link="vless://${uuid}@${link_host}:${new_port}?encryption=none&security=reality&sni=${server_name}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&flow=xtls-rprx-vision#${node_name}"
  sed -i "s/^PORT='.*'$/PORT='${new_port}'/" "$INFO_FILE"
  sed -i "s|^VLESS_LINK='.*'$|VLESS_LINK='${vless_link}'|" "$INFO_FILE"

  echo
  echo "端口已从 ${old_port} 更换为 ${new_port}。"
  post_install_check "$new_port"
  show_link
}

restore_backup() {
  local backup_file="${1:-}"
  if [[ -n "$backup_file" && -f "$backup_file" ]]; then
    cp -a "$backup_file" "$CONFIG_FILE"
    systemctl restart sing-box 2>/dev/null || true
    echo "已恢复安装前的配置。"
  fi
}

restart_singbox() {
  find_singbox || die "未找到 sing-box 核心。"
  [[ -f "$CONFIG_FILE" ]] || die "未找到 sing-box 配置。"
  systemctl restart sing-box
  sleep 1
  systemctl is-active --quiet sing-box || die "重启失败，请查看最近日志。"
  echo "sing-box 已重启并正常运行。"
}

check_singbox() {
  find_singbox || die "未找到 sing-box 核心。"
  [[ -f "$CONFIG_FILE" ]] || die "未找到 sing-box 配置。"
  "$SB_BIN" check -c "$CONFIG_FILE"
  if systemctl is-active --quiet sing-box; then
    echo "配置校验通过，sing-box 正在运行。"
  else
    echo "配置校验通过，但 sing-box 当前未运行。"
  fi
}

show_logs() {
  journalctl -u sing-box -n 40 --no-pager
}

upgrade_singbox() {
  find_singbox || die "未找到 sing-box 核心。"
  install_dependencies

  local machine arch latest current temp_dir archive binary backup
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "暂不支持当前架构：$machine" ;;
  esac

  current="$("$SB_BIN" version 2>/dev/null | head -n1)"
  latest="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest |
    sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
  [[ -n "$latest" ]] || die "无法获取官方最新版本。"
  echo "当前核心：$current"
  echo "官方最新：$latest"
  if [[ "$current" == *"${latest#v}"* ]]; then
    echo "当前已经是官方最新版本。"
    return
  fi
  confirm "是否下载并升级？" || return

  temp_dir="$(mktemp -d)"
  archive="$temp_dir/sing-box.tar.gz"
  curl -fL "https://github.com/SagerNet/sing-box/releases/download/${latest}/sing-box-${latest#v}-linux-${arch}.tar.gz" -o "$archive"
  tar -xzf "$archive" -C "$temp_dir"
  binary="$(find "$temp_dir" -type f -name sing-box | head -n1)"
  [[ -n "$binary" ]] || die "安装包中未找到 sing-box 核心。"
  [[ -f "$CONFIG_FILE" ]] || die "未找到 sing-box 配置，无法安全验证升级。"
  "$binary" check -c "$CONFIG_FILE" >/dev/null

  backup="${SB_BIN}.backup"
  cp -a "$SB_BIN" "$backup"
  install -m 755 "$binary" "$SB_BIN"
  rm -rf "$temp_dir"
  if ! systemctl restart sing-box || ! systemctl is-active --quiet sing-box; then
    cp -a "$backup" "$SB_BIN"
    systemctl restart sing-box 2>/dev/null || true
    die "升级后启动失败，已恢复旧核心。"
  fi
  rm -f "$backup"
  echo "sing-box 核心升级完成。"
}

uninstall_singbox() {
  echo
  if ! confirm "确定卸载 sing-box 服务和全部配置？"; then
    echo "已取消。"
    return
  fi

  clean_old_setup

  if confirm "是否同时删除 sing-box 核心程序？"; then
    local sb_bin
    sb_bin="$(command -v sing-box || true)"
    if [[ -n "$sb_bin" ]]; then
      rm -f "$sb_bin"
      echo "sing-box 核心程序已删除。"
    fi
  fi

  echo "卸载完成；当前管理脚本已保留。"
}

show_menu() {
  clear 2>/dev/null || true
  echo "================================================"
  echo "   $SCRIPT_TITLE $SCRIPT_VERSION"
  echo "================================================"
  show_status
  echo "13. 生成 VLESS gRPC 节点（仅填写子域名）"
  echo "13. Generate VLESS gRPC node (domain only)"
  echo "================================================"
  echo "1. 安装 / 重建节点"
  echo "2. 查看分享节点链接"
  echo "3. 重启 sing-box"
  echo "4. 检查配置与运行状态"
  echo "5. 查看最近日志"
  echo "6. 更换端口并更新链接"
  echo "7. 更换伪装网站并更新链接"
  echo "8. 管理 SWAP"
  echo "9. 检查 / 升级官方核心"
  echo "10. 卸载 sing-box"
  echo "0. 退出"
  echo "13. 生成 VLESS gRPC 节点（仅填已解析子域名）"
  echo "13. 生成 VLESS gRPC 节点（仅填已解析子域名）"
  echo "================================================"
}

main() {
  require_root
  echo "正在运行：$SCRIPT_TITLE $SCRIPT_VERSION"

  case "${1:-}" in
    install)
      install_node "${2:-}"
      return
      ;;
    share)
      show_link
      return
      ;;
    uninstall)
      uninstall_singbox
      return
      ;;
    port)
      change_port
      return
      ;;
    camouflage)
      change_camouflage
      return
      ;;
    swap)
      configure_swap
      return
      ;;
    restart)
      restart_singbox
      return
      ;;
    check)
      check_singbox
      return
      ;;
    logs)
      show_logs
      return
      ;;
    upgrade)
      upgrade_singbox
      return
      ;;
  esac

  show_menu
  local choice
  read -r -p "请选择: " choice
  case "$choice" in
    1) install_node ;;
    2) show_link ;;
    3) restart_singbox ;;
    4) check_singbox ;;
    5) show_logs ;;
    6) change_port ;;
    7) change_camouflage ;;
    8) configure_swap ;;
    9) upgrade_singbox ;;
    10) uninstall_singbox ;;
    0) exit 0 ;;
    *) die "无效选项。" ;;
  esac
}

# ---- v10 HTTP subscription add-on: File Browser safe ----
SUBSCRIPTION_INFO_FILE="${SUBSCRIPTION_INFO_FILE:-$CONFIG_DIR/subscription.env}"
SUBSCRIPTION_WEB_DIR="${SUBSCRIPTION_WEB_DIR:-/var/www/sub}"
SUBSCRIPTION_NGINX_SNIPPET="${SUBSCRIPTION_NGINX_SNIPPET:-/etc/nginx/snippets/singbox-sub-location.conf}"
LEGACY_SUBSCRIPTION_NGINX_CONF="${LEGACY_SUBSCRIPTION_NGINX_CONF:-/etc/nginx/conf.d/singbox-sub.conf}"
GRPC_INFO_FILE="${GRPC_INFO_FILE:-$CONFIG_DIR/grpc-node.env}"
GRPC_PORT="${GRPC_PORT:-443}"
GRPC_SERVICE_NAME="${GRPC_SERVICE_NAME:-grpc}"

v10_read_info_value() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  sed -n "s/^${key}='\(.*\)'$/\1/p" "$file" | head -n1
}

v10_clean_host_input() {
  local host="$1"
  host="${host#https://}"
  host="${host#http://}"
  host="${host%%/*}"
  host="${host%%:*}"
  host="${host,,}"
  printf '%s' "$host"
}

v10_validate_link_host() {
  local host="$1" part
  if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    IFS='.' read -r -a parts <<<"$host"
    for part in "${parts[@]}"; do
      (( part >= 0 && part <= 255 )) || return 1
    done
    return 0
  fi
  [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

v10_is_ipv4() {
  local host="$1" part
  [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a parts <<<"$host"
  for part in "${parts[@]}"; do
    [[ "$part" =~ ^[0-9]+$ ]] || return 1
    (( part >= 0 && part <= 255 )) || return 1
  done
  return 0
}

v10_get_current_public_ipv4() {
  curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true
}

v10_resolve_ipv4_records() {
  local host="$1"
  if command -v getent >/dev/null; then
    getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u
  elif command -v dig >/dev/null; then
    dig +short A "$host" 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u
  elif command -v nslookup >/dev/null; then
    nslookup -type=A "$host" 2>/dev/null | awk '/^Address: /{print $2}' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u
  fi
}

v10_check_domain_resolution() {
  local domain="$1" expected_ip="$2" resolved_ips matched="false" ip resolved_one_line

  [[ -n "$expected_ip" ]] || expected_ip="$(v10_get_current_public_ipv4)"
  if [[ -z "$expected_ip" ]]; then
    echo "警告：未能自动获取当前 VPS 公网 IPv4，无法严格校验 DNS 解析。"
    return 2
  fi

  echo "正在检测域名 A 记录解析..."
  resolved_ips="$(v10_resolve_ipv4_records "$domain" | sed '/^$/d')"
  if [[ -z "$resolved_ips" ]]; then
    echo "未检测到 ${domain} 的 IPv4 A 记录。"
    echo "请先在 DNS 面板添加 A 记录：${domain} -> ${expected_ip}"
    return 1
  fi

  resolved_one_line="$(printf '%s\n' "$resolved_ips" | paste -sd ' ' -)"
  echo "当前 VPS 公网 IPv4：$expected_ip"
  echo "域名解析到：$resolved_one_line"

  while IFS= read -r ip; do
    [[ "$ip" == "$expected_ip" ]] && matched="true"
  done <<<"$resolved_ips"

  if [[ "$matched" == "true" ]]; then
    echo "DNS 解析校验通过：${domain} 已指向当前 VPS。"
    return 0
  fi

  echo "DNS 解析不一致：${domain} 还没有指向当前 VPS。"
  echo "请确认 Cloudflare / DNS 面板里 A 记录指向 ${expected_ip}，并关闭小黄云，保持 DNS only。"
  return 2
}

v10_build_vless_link() {
  local node_name="$1" link_host="$2" port="$3" uuid="$4" public_key="$5" short_id="$6" server_name="$7"
  printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&flow=xtls-rprx-vision#%s'     "$uuid" "$link_host" "$port" "$server_name" "$public_key" "$short_id" "$node_name"
}

v10_detect_subscription_host() {
  local fallback="$1" host=""
  if [[ -d /etc/nginx ]]; then
    host="$(grep -RhsE '^[[:space:]]*server_name[[:space:]]+' /etc/nginx/sites-enabled /etc/nginx/conf.d 2>/dev/null |
      sed -E 's/^[[:space:]]*server_name[[:space:]]+//; s/;.*$//' |
      tr ' ' '\n' |
      grep -Ev '^$|^_$|^localhost$|^\*$|^~' |
      head -n1 || true)"
  fi
  printf '%s' "${host:-$fallback}"
}

v10_make_subscription_url() {
  local host="$1" file_name="$2"
  printf 'http://%s/sub/%s' "$host" "$file_name"
}

v10_write_nginx_snippet() {
  mkdir -p "$(dirname "$SUBSCRIPTION_NGINX_SNIPPET")" "$SUBSCRIPTION_WEB_DIR"
  cat >"$SUBSCRIPTION_NGINX_SNIPPET" <<EOF
# Managed by singbox-deployment-v10.3. Static subscription files only.
location ^~ /sub/ {
    alias ${SUBSCRIPTION_WEB_DIR}/;
    default_type text/yaml;
    add_header Cache-Control no-store always;
    try_files \$uri =404;
}
EOF
}

v10_remove_legacy_subscription_server() {
  [[ -f "$LEGACY_SUBSCRIPTION_NGINX_CONF" ]] || return 0
  if grep -qF "alias ${SUBSCRIPTION_WEB_DIR}/;" "$LEGACY_SUBSCRIPTION_NGINX_CONF" &&
    grep -qF "return 404;" "$LEGACY_SUBSCRIPTION_NGINX_CONF"; then
    cp -a "$LEGACY_SUBSCRIPTION_NGINX_CONF" "${LEGACY_SUBSCRIPTION_NGINX_CONF}.backup.$(date +%Y%m%d-%H%M%S)"
    rm -f "$LEGACY_SUBSCRIPTION_NGINX_CONF"
    echo "已移除旧版独立订阅 Nginx 配置：$LEGACY_SUBSCRIPTION_NGINX_CONF"
  fi
}

v10_find_existing_nginx_site() {
  local url_host="$1" site="" candidates count
  [[ -d /etc/nginx ]] || return 1
  if [[ -n "$url_host" && "$url_host" != "YOUR_SERVER_IP" ]]; then
    site="$(grep -RslE "^[[:space:]]*server_name[[:space:]].*(^|[[:space:]])${url_host//./\\.}([[:space:];]|$)" \
      /etc/nginx/sites-enabled /etc/nginx/conf.d 2>/dev/null | head -n1 || true)"
  fi
  if [[ -z "$site" ]]; then
    site="$(grep -RsilE 'file[[:space:]_-]*browser|filebrowser|proxy_pass[[:space:]]+http://127\.0\.0\.1:8080|proxy_pass[[:space:]]+http://localhost:8080' \
      /etc/nginx/sites-enabled /etc/nginx/conf.d 2>/dev/null | head -n1 || true)"
  fi
  if [[ -z "$site" ]]; then
    candidates="$(grep -RslE '^[[:space:]]*server[[:space:]]*\{' /etc/nginx/sites-enabled /etc/nginx/conf.d 2>/dev/null || true)"
    count="$(printf '%s\n' "$candidates" | sed '/^$/d' | wc -l)"
    if [[ "$count" == "1" ]]; then
      site="$(printf '%s\n' "$candidates" | sed '/^$/d' | head -n1)"
    fi
  fi
  [[ -n "$site" ]] || return 1
  printf '%s' "$site"
}

v10_append_sub_to_existing_site() {
  local site_file="$1" tmp include_line
  include_line="    include ${SUBSCRIPTION_NGINX_SNIPPET};"
  grep -qF "include ${SUBSCRIPTION_NGINX_SNIPPET};" "$site_file" && return 0
  tmp="$(mktemp)"
  awk -v inc="$include_line" '
    BEGIN { in_server=0; depth=0; inserted=0 }
    {
      line=$0
      opens=gsub(/\{/, "{", line)
      closes=gsub(/\}/, "}", line)
      if (!inserted && $0 ~ /^[[:space:]]*server[[:space:]]*\{/) in_server=1
      if (!inserted && in_server && depth == 1 && closes > 0) {
        print "";
        print "    # singbox-deployment-v10.3: static subscription path.";
        print inc;
        inserted=1;
      }
      print $0
      if (!inserted || in_server) depth += opens - closes
    }
  ' "$site_file" >"$tmp"
  install -m 644 "$tmp" "$site_file"
  rm -f "$tmp"
}

v10_ensure_subscription_nginx_mapping() {
  local url_host="$1" site_file backup_file
  if ! command -v nginx >/dev/null; then
    echo "未检测到 Nginx；已生成订阅 YAML，不会改动 File Browser。"
    return 0
  fi
  v10_write_nginx_snippet
  v10_remove_legacy_subscription_server
  site_file="$(v10_find_existing_nginx_site "$url_host" || true)"
  if [[ -z "$site_file" ]]; then
    echo "未检测到可安全追加的 File Browser/Nginx 站点，已保持 Nginx 不变。"
    echo "订阅文件仍已生成到：${SUBSCRIPTION_WEB_DIR}"
    return 0
  fi
  backup_file="${site_file}.backup.$(date +%Y%m%d-%H%M%S)"
  cp -a "$site_file" "$backup_file"
  v10_append_sub_to_existing_site "$site_file"
  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null || true
    echo "已向现有 Nginx 站点追加 /sub/ 静态订阅路径：$site_file"
  else
    cp -a "$backup_file" "$site_file"
    echo "Nginx 校验失败，已恢复原 File Browser/Nginx 配置。"
  fi
}

generate_subscription_link() {
  [[ -f "$INFO_FILE" ]] || die "没有找到节点信息，请先安装/重建节点。"
  local node_name public_ip link_host server_host port uuid public_key short_id server_name sub_name sub_path url_host sub_url
  node_name="$(v10_read_info_value "$INFO_FILE" NODE_NAME)"
  public_ip="$(v10_read_info_value "$INFO_FILE" PUBLIC_IP)"
  link_host="$(v10_read_info_value "$INFO_FILE" LINK_HOST)"
  port="$(v10_read_info_value "$INFO_FILE" PORT)"
  uuid="$(v10_read_info_value "$INFO_FILE" UUID)"
  public_key="$(v10_read_info_value "$INFO_FILE" PUBLIC_KEY)"
  short_id="$(v10_read_info_value "$INFO_FILE" SHORT_ID)"
  server_name="$(v10_read_info_value "$INFO_FILE" SERVER_NAME)"
  node_name="${node_name:-sing-box}"
  public_ip="${public_ip:-YOUR_SERVER_IP}"
  server_host="${link_host:-$public_ip}"
  server_name="${server_name:-$SERVER_NAME}"
  [[ -n "$port" && -n "$uuid" && -n "$public_key" && -n "$short_id" ]] || die "节点信息不完整，请重新安装节点。"

  command -v openssl >/dev/null || install_dependencies
  sub_name="$(v10_read_info_value "$SUBSCRIPTION_INFO_FILE" SUBSCRIPTION_FILE_NAME)"
  [[ -n "$sub_name" ]] || sub_name="$(openssl rand -hex 4).yaml"
  [[ "$sub_name" =~ ^[A-Za-z0-9._-]+\.ya?ml$ ]] || die "订阅文件名异常。"
  mkdir -p "$SUBSCRIPTION_WEB_DIR" "$CONFIG_DIR"
  sub_path="${SUBSCRIPTION_WEB_DIR}/${sub_name}"
  if [[ -n "$link_host" && "$link_host" != "$public_ip" ]]; then
    url_host="$server_host"
  else
    url_host="$(v10_detect_subscription_host "$server_host")"
  fi
  sub_url="$(v10_make_subscription_url "$url_host" "$sub_name")"

  cat >"$sub_path" <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info

dns:
  enable: true
  enhanced-mode: fake-ip
  nameserver:
    - https://223.5.5.5/dns-query
    - https://1.1.1.1/dns-query

proxies:
  - name: "$node_name"
    type: vless
    server: "$server_host"
    port: $port
    uuid: "$uuid"
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: "$server_name"
    client-fingerprint: chrome
    reality-opts:
      public-key: "$public_key"
      short-id: "$short_id"

proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - "$node_name"
      - DIRECT

rules:
  - MATCH,PROXY
EOF
  chmod 644 "$sub_path"
  v10_ensure_subscription_nginx_mapping "$url_host"
  cat >"$SUBSCRIPTION_INFO_FILE" <<EOF
SUBSCRIPTION_FILE_NAME='$sub_name'
SUBSCRIPTION_PATH='$sub_path'
SUBSCRIPTION_HTTP_URL='$sub_url'
EOF
  chmod 600 "$SUBSCRIPTION_INFO_FILE"
  echo
  echo "Clash/Mihomo 订阅文件：$sub_path"
  echo "HTTP 订阅链接："
  echo "$sub_url"
}

generate_grpc_node() {
  [[ -f "$INFO_FILE" && -f "$CONFIG_FILE" ]] || die "Please install the Reality node first."
  find_singbox || die "sing-box core was not found."

  local domain current_ip node_name port uuid private_key public_key short_id server_name grpc_port candidate grpc_port_available=false
  local cert_dir cert_file key_file tmp_config backup_file grpc_name grpc_link grpc_sub_path nginx_was_running=false

  echo
  echo "gRPC prefers TCP/${GRPC_PORT}; only enter a subdomain whose A record already points directly to this VPS."
  echo "Cloudflare proxy must be disabled (DNS only)."
  read -r -p "gRPC subdomain: " domain
  domain="$(v10_clean_host_input "$domain")"
  v10_validate_link_host "$domain" && ! v10_is_ipv4 "$domain" || die "Enter a valid subdomain, not an IP address."

  current_ip="$(v10_get_current_public_ipv4)"
  [[ -n "$current_ip" ]] || die "Could not determine the public IPv4 address."
  v10_check_domain_resolution "$domain" "$current_ip" || die "The subdomain has not resolved to this VPS; no changes were made."

  node_name="$(v10_read_info_value "$INFO_FILE" NODE_NAME)"
  port="$(v10_read_info_value "$INFO_FILE" PORT)"
  uuid="$(v10_read_info_value "$INFO_FILE" UUID)"
  private_key="$(v10_read_info_value "$INFO_FILE" PRIVATE_KEY)"
  public_key="$(v10_read_info_value "$INFO_FILE" PUBLIC_KEY)"
  short_id="$(v10_read_info_value "$INFO_FILE" SHORT_ID)"
  server_name="$(v10_read_info_value "$INFO_FILE" SERVER_NAME)"
  node_name="${node_name:-sing-box}"
  server_name="${server_name:-$SERVER_NAME}"
  [[ -n "$port" && -n "$uuid" && -n "$private_key" && -n "$public_key" && -n "$short_id" ]] || die "Saved node information is incomplete."

  grpc_port="$GRPC_PORT"
  # Reality commonly already owns 443. Keep this one-field workflow by selecting
  # the first available HTTPS-like fallback port instead of asking for a port.
  if [[ "$grpc_port" == "$port" ]] || ! check_port_available "$grpc_port"; then
    for candidate in 8443 9443 10443 12443; do
      if [[ "$candidate" != "$port" ]] && check_port_available "$candidate"; then
        grpc_port="$candidate"
        grpc_port_available=true
        break
      fi
    done
    [[ "$grpc_port_available" == true ]] || die "TCP/443 is occupied and no fallback gRPC port is available."
    echo "TCP/443 is occupied; gRPC will use TCP/${grpc_port}."
  fi

  command -v certbot >/dev/null || {
    command -v apt-get >/dev/null || die "certbot is required to issue the TLS certificate."
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y certbot
  }

  # HTTP-01 needs port 80 briefly. Nginx is restored immediately after issuance.
  if systemctl is-active --quiet nginx 2>/dev/null; then
    systemctl stop nginx
    nginx_was_running=true
  fi
  if ss -H -lnt "sport = :80" 2>/dev/null | grep -q .; then
    [[ "$nginx_was_running" == true ]] && systemctl start nginx
    die "TCP/80 is occupied; free it temporarily so Let's Encrypt can validate ${domain}."
  fi
  if ! certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d "$domain"; then
    [[ "$nginx_was_running" == true ]] && systemctl start nginx
    die "TLS certificate issuance failed; no sing-box configuration was changed."
  fi
  [[ "$nginx_was_running" == true ]] && systemctl start nginx

  cert_dir="/etc/letsencrypt/live/${domain}"
  cert_file="${cert_dir}/fullchain.pem"
  key_file="${cert_dir}/privkey.pem"
  [[ -s "$cert_file" && -s "$key_file" ]] || die "The issued certificate files were not found."

  tmp_config="$(mktemp)"
  backup_file="${CONFIG_FILE}.backup.$(date +%Y%m%d-%H%M%S)"
  cp -a "$CONFIG_FILE" "$backup_file"
  cat >"$tmp_config" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless",
      "listen": "::",
      "listen_port": $port,
      "users": [{ "uuid": "$uuid", "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true,
        "server_name": "$server_name",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$server_name", "server_port": 443 },
          "private_key": "$private_key",
          "short_id": ["$short_id"]
        }
      }
    },
    {
      "type": "vless",
      "tag": "vless-grpc",
      "listen": "::",
      "listen_port": $grpc_port,
      "users": [{ "uuid": "$uuid" }],
      "tls": {
        "enabled": true,
        "server_name": "$domain",
        "certificate_path": "$cert_file",
        "key_path": "$key_file"
      },
      "transport": { "type": "grpc", "service_name": "$GRPC_SERVICE_NAME" }
    }
  ]
}
EOF
  if ! "$SB_BIN" check -c "$tmp_config" >/dev/null; then
    rm -f "$tmp_config"
    die "The generated gRPC configuration did not pass sing-box validation; the old config remains active."
  fi
  install -m 600 "$tmp_config" "$CONFIG_FILE"
  rm -f "$tmp_config"
  if ! systemctl restart sing-box; then
    cp -a "$backup_file" "$CONFIG_FILE"
    systemctl restart sing-box || true
    die "sing-box could not restart; the previous configuration was restored."
  fi

  grpc_name="${node_name}-gRPC"
  grpc_link="vless://${uuid}@${domain}:${grpc_port}?encryption=none&security=tls&sni=${domain}&type=grpc&serviceName=${GRPC_SERVICE_NAME}#${grpc_name}"
  grpc_sub_path="${SUBSCRIPTION_WEB_DIR}/grpc-${uuid:0:8}.yaml"
  mkdir -p "$SUBSCRIPTION_WEB_DIR"
  cat >"$grpc_sub_path" <<EOF
proxies:
  - name: "$grpc_name"
    type: vless
    server: "$domain"
    port: $grpc_port
    uuid: "$uuid"
    network: grpc
    tls: true
    udp: true
    servername: "$domain"
    grpc-opts:
      grpc-service-name: "$GRPC_SERVICE_NAME"
EOF
  chmod 644 "$grpc_sub_path"
  v10_ensure_subscription_nginx_mapping "$domain"
  cat >"$GRPC_INFO_FILE" <<EOF
GRPC_DOMAIN='$domain'
GRPC_PORT='$grpc_port'
GRPC_SERVICE_NAME='$GRPC_SERVICE_NAME'
GRPC_LINK='$grpc_link'
GRPC_SUBSCRIPTION_PATH='$grpc_sub_path'
EOF
  chmod 600 "$GRPC_INFO_FILE"

  echo
  echo "gRPC node created:"
  echo "$grpc_link"
  echo "Clash/Mihomo file: $grpc_sub_path"
  echo "Ensure TCP/${grpc_port} is open in the firewall and cloud security group."
}

set_link_host() {
  [[ -f "$INFO_FILE" ]] || die "没有找到节点信息，请先安装/重建节点。"

  local node_name public_ip link_host old_host new_host current_ip resolved_ips port uuid private_key public_key short_id server_name vless_link
  node_name="$(v10_read_info_value "$INFO_FILE" NODE_NAME)"
  public_ip="$(v10_read_info_value "$INFO_FILE" PUBLIC_IP)"
  old_host="$(v10_read_info_value "$INFO_FILE" LINK_HOST)"
  port="$(v10_read_info_value "$INFO_FILE" PORT)"
  uuid="$(v10_read_info_value "$INFO_FILE" UUID)"
  private_key="$(v10_read_info_value "$INFO_FILE" PRIVATE_KEY)"
  public_key="$(v10_read_info_value "$INFO_FILE" PUBLIC_KEY)"
  short_id="$(v10_read_info_value "$INFO_FILE" SHORT_ID)"
  server_name="$(v10_read_info_value "$INFO_FILE" SERVER_NAME)"

  node_name="${node_name:-sing-box}"
  public_ip="${public_ip:-}"
  old_host="${old_host:-$public_ip}"
  server_name="${server_name:-$SERVER_NAME}"
  [[ -n "$port" && -n "$uuid" && -n "$public_key" && -n "$short_id" ]] || die "节点信息不完整，请重新安装节点。"

  echo
  echo "当前客户端连接地址：${old_host:-未设置}"
  echo "注意：域名需要在 DNS 里 A 记录直连到这台 VPS 的公网 IP，不要开 Cloudflare 小黄云代理。"
  read -r -p "请输入新的连接域名（不要带 https://；留空=恢复当前公网 IP）: " new_host

  if [[ -z "$new_host" ]]; then
    current_ip="$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
    new_host="${current_ip:-$public_ip}"
    [[ -n "$new_host" ]] || die "未能自动获取公网 IP，请手动输入 IP 或域名。"
  else
    new_host="$(v10_clean_host_input "$new_host")"
  fi

  v10_validate_link_host "$new_host" || die "请输入正确的域名或 IPv4，例如 node.example.com。"

  current_ip="$(v10_get_current_public_ipv4)"
  [[ -n "$current_ip" ]] && public_ip="$current_ip"

  if ! v10_is_ipv4 "$new_host"; then
    if ! v10_check_domain_resolution "$new_host" "$current_ip"; then
      if ! confirm "DNS 解析未通过，仍然继续生成链接？"; then
        echo "已取消。"
        return
      fi
    fi
  fi

  link_host="$new_host"
  vless_link="$(v10_build_vless_link "$node_name" "$link_host" "$port" "$uuid" "$public_key" "$short_id" "$server_name")"

  cat >"$INFO_FILE" <<EOF
NODE_NAME='$node_name'
PUBLIC_IP='$public_ip'
LINK_HOST='$link_host'
PORT='$port'
UUID='$uuid'
PRIVATE_KEY='$private_key'
PUBLIC_KEY='$public_key'
SHORT_ID='$short_id'
SERVER_NAME='$server_name'
VLESS_LINK='$vless_link'
EOF
  chmod 600 "$INFO_FILE"

  echo
  echo "连接地址已更新：${old_host:-未设置} -> ${link_host}"
  show_link
  echo
  echo "正在同步生成 / 更新 HTTP 订阅链接..."
  generate_subscription_link
}

show_menu() {
  clear 2>/dev/null || true
  echo "================================================"
  echo "   $SCRIPT_TITLE $SCRIPT_VERSION"
  echo "================================================"
  show_status
  echo "================================================"
  echo "1. 安装 / 重建节点"
  echo "2. 查看分享节点链接"
  echo "3. 重启 sing-box"
  echo "4. 检查配置与运行状态"
  echo "5. 查看最近日志"
  echo "6. 更换端口并更新链接"
  echo "7. 更换伪装网站并更新链接"
  echo "8. 生成 / 更新 HTTP 订阅链接"
  echo "9. 管理 SWAP"
  echo "10. 设置连接域名并更新链接"
  echo "11. 检查 / 升级官方核心"
  echo "12. 卸载 sing-box"
  echo "0. 退出"
  echo "================================================"
}

main() {
  require_root
  echo "正在运行：$SCRIPT_TITLE $SCRIPT_VERSION"

  case "${1:-}" in
    install) install_node "${2:-}"; return ;;
    share) show_link; return ;;
    uninstall) uninstall_singbox; return ;;
    port) change_port; return ;;
    camouflage) change_camouflage; return ;;
    subscribe|subscription) generate_subscription_link; return ;;
    grpc) generate_grpc_node; return ;;
    domain|host) set_link_host; return ;;
    swap) configure_swap; return ;;
    restart) restart_singbox; return ;;
    check) check_singbox; return ;;
    logs) show_logs; return ;;
    upgrade) upgrade_singbox; return ;;
  esac

  show_menu
  local choice
  read -r -p "请选择: " choice
  case "$choice" in
    1) install_node ;;
    2) show_link ;;
    3) restart_singbox ;;
    4) check_singbox ;;
    5) show_logs ;;
    6) change_port ;;
    7) change_camouflage ;;
    8) generate_subscription_link ;;
    9) configure_swap ;;
    10) set_link_host ;;
    11) upgrade_singbox ;;
    12) uninstall_singbox ;;
    13) generate_grpc_node ;;
    0) exit 0 ;;
    *) die "无效选项。" ;;
  esac
}

main "$@"
