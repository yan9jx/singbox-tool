#!/usr/bin/env bash
set -Eeuo pipefail

# Pure-IPv6 VPS: route IPv4 through Cloudflare WARP on demand while leaving
# every IPv6 route, address, DNS setting, and firewall rule untouched.

SCRIPT_VERSION="1.0.2"
NAME="warp-ipv4"
WG_IF="warp-ipv4"
WG_CONF="/etc/wireguard/${WG_IF}.conf"
CONFIG_DIR="/etc/${NAME}"
ACCOUNT_JSON="${CONFIG_DIR}/account.json"
ENDPOINT_FILE="${CONFIG_DIR}/endpoint-v6"
MANAGER="/usr/local/sbin/${NAME}"
RUN_DIR="/run/${NAME}"
IPV6_ROUTE_GUARD="${RUN_DIR}/ipv6-default.before"
IPV6_ADDR_GUARD="${RUN_DIR}/ipv6-public.before"
ROLLBACK_UNIT="${NAME}-rollback"
ROLLBACK_SECONDS=180
WARP_ROUTE_METRIC=5
TRACE_URL="https://www.cloudflare.com/cdn-cgi/trace"
IPV6_CHECK_URL="https://api64.ipify.org"
WARP_API="https://api.cloudflareclient.com/v0a1922/reg"
WARP_ENDPOINT_HOST="engage.cloudflareclient.com"
WARP_ENDPOINT_PORT="2408"

say() {
  printf '%s\n' "$*"
}

info() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行：sudo bash $0"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

is_interface_up() {
  ip link show dev "$WG_IF" >/dev/null 2>&1
}

install_dependencies() {
  local missing=0
  local command_name

  for command_name in curl jq ip wg wg-quick systemctl systemd-run getent sha256sum; do
    if ! have "$command_name"; then
      missing=1
      break
    fi
  done

  if [[ $missing -eq 0 ]]; then
    return
  fi

  info "安装 curl、jq、WireGuard 和网络工具；此步骤不会启用 WARP。"
  if have apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y curl ca-certificates jq iproute2 wireguard-tools
  elif have dnf; then
    dnf install -y curl ca-certificates jq iproute wireguard-tools
  elif have yum; then
    yum install -y curl ca-certificates jq iproute wireguard-tools
  else
    die "不支持当前包管理器，请先安装 curl、jq、iproute2 和 wireguard-tools。"
  fi

  for command_name in curl jq ip wg wg-quick systemctl systemd-run getent sha256sum; do
    have "$command_name" || die "依赖安装后仍缺少命令：$command_name"
  done
}

check_systemd() {
  [[ "$(ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]')" == "systemd" ]] \
    || die "安全回滚依赖 systemd；当前 PID 1 不是 systemd，拒绝继续。"
}

check_wireguard_kernel() {
  local probe="wgp${RANDOM}"

  if is_interface_up; then
    return
  fi

  modprobe wireguard >/dev/null 2>&1 || true
  ip link show dev "$probe" >/dev/null 2>&1 \
    && die "临时 WireGuard 探测接口名冲突，请重新运行。"
  if ! ip link add dev "$probe" type wireguard >/dev/null 2>&1; then
    die "内核或 VPS 虚拟化环境不支持 WireGuard；未改动任何路由。"
  fi
  ip link del dev "$probe"
}

native_ipv6() {
  curl -6 --proto '=https' --tlsv1.2 -fsS --max-time 15 "$IPV6_CHECK_URL"
}

check_native_ipv6() {
  local default_route public_v6

  default_route="$(ip -6 route show default)"
  [[ -n "$default_route" ]] || die "没有 IPv6 默认路由，拒绝安装或启用。"

  ip -6 route get 2606:4700:4700::1111 >/dev/null 2>&1 \
    || die "IPv6 路由不可达，拒绝继续。"

  public_v6="$(native_ipv6)" || die "无法通过原生 IPv6 访问 $IPV6_CHECK_URL。"
  [[ "$public_v6" == *:* ]] || die "IPv6 公网地址检查结果异常：$public_v6"
}

is_private_ipv4() {
  local address="$1"
  local second_octet

  case "$address" in
    10.*|192.168.*|169.254.*) return 0 ;;
    172.*)
      second_octet="${address#172.}"
      second_octet="${second_octet%%.*}"
      (( second_octet >= 16 && second_octet <= 31 ))
      return
      ;;
    100.*)
      second_octet="${address#100.}"
      second_octet="${second_octet%%.*}"
      (( second_octet >= 64 && second_octet <= 127 ))
      return
      ;;
  esac
  return 1
}

check_pure_ipv6_host() {
  local default_v4 route_probe source_v4

  default_v4="$(ip -4 route show default)"
  [[ -n "$default_v4" ]] || return

  route_probe="$(ip -4 route get 1.1.1.1 2>/dev/null || true)"
  source_v4="$(awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}' <<< "$route_probe")"

  if [[ -n "$source_v4" ]] && is_private_ipv4 "$source_v4"; then
    info "检测到云厂商内网 IPv4（$source_v4），没有把它当作公网 IPv4；允许继续。"
    return
  fi

  die "检测到可能承载 SSH 的公网 IPv4 默认路由，拒绝接管：$default_v4"
}

resolve_warp_endpoint_v6() {
  local endpoint

  endpoint="$(
    getent ahostsv6 "$WARP_ENDPOINT_HOST" 2>/dev/null \
      | awk '$1 ~ /:/ && tolower($1) !~ /^::ffff:/ { print $1; exit }'
  )"

  [[ -n "$endpoint" ]] || die "无法解析 $WARP_ENDPOINT_HOST 的 AAAA 记录。"
  ip -6 route get "$endpoint" >/dev/null 2>&1 \
    || die "WARP IPv6 端点不可达：$endpoint"
  printf '%s\n' "$endpoint"
}

accept_cloudflare_terms() {
  local answer

  say
  say "本脚本通过 Cloudflare consumer WARP 注册接口生成 WireGuard 配置。"
  say "Cloudflare 服务条款：https://www.cloudflare.com/application/terms/"
  read -r -p "确认你已阅读并接受条款，请输入 I AGREE： " answer
  [[ "$answer" == "I AGREE" ]] || die "未接受服务条款，已取消。"
}

register_warp() {
  local temp_dir private_key public_key tos payload response http_code
  local warp_address peer_public_key endpoint_v6 temp_conf

  temp_dir="$(mktemp -d)"
  private_key="$(wg genkey)"
  public_key="$(printf '%s' "$private_key" | wg pubkey)"
  tos="$(date -u +'%Y-%m-%dT%H:%M:%S.000Z')"

  payload="$(
    jq -cn \
      --arg key "$public_key" \
      --arg tos "$tos" \
      '{key:$key,install_id:"",fcm_token:"",tos:$tos,model:"Linux IPv6 VPS",locale:"en_US",type:"Android"}'
  )"
  response="${temp_dir}/account.json"

  info "通过原生 IPv6 注册 Cloudflare WARP 设备。"
  http_code="$(
    curl -6 --proto '=https' --tlsv1.2 --tls-max 1.2 --http1.1 \
      -sS --max-time 30 \
      -o "$response" \
      -w '%{http_code}' \
      -H 'Content-Type: application/json; charset=UTF-8' \
      -H 'User-Agent: okhttp/3.12.1' \
      -H 'CF-Client-Version: a-6.3-1922' \
      --data "$payload" \
      "$WARP_API"
  )" || {
    rm -f "$response"
    rmdir "$temp_dir" 2>/dev/null || true
    die "WARP 注册请求失败；未启用隧道，也未改动路由。"
  }

  if [[ "$http_code" != "200" ]]; then
    warn "WARP 注册返回 HTTP $http_code："
    jq -c '{errors, message}' "$response" 2>/dev/null || true
    rm -f "$response"
    rmdir "$temp_dir" 2>/dev/null || true
    die "WARP 注册失败；未启用隧道，也未改动路由。"
  fi

  if ! warp_address="$(jq -er '.config.interface.addresses.v4' "$response")"; then
    rm -f "$response"
    rmdir "$temp_dir" 2>/dev/null || true
    die "注册响应缺少 WARP IPv4 地址。"
  fi
  if ! peer_public_key="$(jq -er '.config.peers[0].public_key' "$response")"; then
    rm -f "$response"
    rmdir "$temp_dir" 2>/dev/null || true
    die "注册响应缺少 WireGuard 对端公钥。"
  fi
  [[ "$warp_address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "WARP IPv4 地址格式异常：$warp_address"

  endpoint_v6="$(resolve_warp_endpoint_v6)"

  install -d -m 700 "$CONFIG_DIR"
  install -d -m 700 /etc/wireguard
  install -m 600 "$response" "$ACCOUNT_JSON"
  printf '%s\n' "$endpoint_v6" > "${temp_dir}/endpoint-v6"
  install -m 600 "${temp_dir}/endpoint-v6" "$ENDPOINT_FILE"

  temp_conf="${temp_dir}/${WG_IF}.conf"
  cat > "$temp_conf" <<EOF
[Interface]
PrivateKey = $private_key
Address = ${warp_address}/32
MTU = 1280
Table = off

[Peer]
PublicKey = $peer_public_key
AllowedIPs = 0.0.0.0/0
Endpoint = [${endpoint_v6}]:${WARP_ENDPOINT_PORT}
PersistentKeepalive = 25
EOF
  install -m 600 "$temp_conf" "$WG_CONF"

  rm -f "$response" "${temp_dir}/endpoint-v6" "$temp_conf"
  rmdir "$temp_dir" 2>/dev/null || true
}

install_manager() {
  local source_path target_path

  source_path="$(readlink -f "$0")"
  target_path="$(readlink -m "$MANAGER")"
  if [[ "$source_path" != "$target_path" ]]; then
    install -m 755 "$source_path" "$MANAGER"
  fi
}

install_warp() {
  require_root
  check_systemd

  if [[ -e "$WG_CONF" || -e "$ACCOUNT_JSON" ]]; then
    die "检测到已有配置。为避免覆盖密钥，请先查看状态或明确执行卸载。"
  fi

  install_dependencies
  check_native_ipv6
  check_pure_ipv6_host
  check_wireguard_kernel
  accept_cloudflare_terms
  register_warp
  install_manager

  systemctl disable "wg-quick@${WG_IF}.service" >/dev/null 2>&1 || true

  say
  say "安装完成，但 WARP 尚未启用。"
  say "安全设计："
  say "  - WireGuard 配置使用 Table = off"
  say "  - 仅配置 0.0.0.0/0，不配置 ::/0"
  say "  - 不修改 DNS、IPv6 地址、防火墙或 sysctl"
  say "  - 不设置开机自动启用"
  say
  say "启用命令：sudo $MANAGER on"
}

current_ipv6_path() {
  local route

  route="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null)" || return 1
  awk -v warp_if="$WG_IF" '
    {
      for (i = 1; i <= NF; i++) {
        if ($i == "via") via = $(i + 1)
        if ($i == "dev") dev = $(i + 1)
      }
    }
    END {
      if (dev == "" || dev == warp_if) exit 1
      print "via=" via " dev=" dev
    }
  ' <<< "$route"
}

save_ipv6_guards() {
  local public_v6 route_path

  install -d -m 700 "$RUN_DIR"
  route_path="$(current_ipv6_path)" || die "无法保存 IPv6 出口路径基线。"
  printf '%s\n' "$route_path" > "$IPV6_ROUTE_GUARD"

  public_v6="$(native_ipv6)" || die "无法保存原生 IPv6 地址基线。"
  [[ "$public_v6" == *:* ]] || die "原生 IPv6 地址基线异常。"
  printf '%s\n' "$public_v6" > "$IPV6_ADDR_GUARD"
  chmod 600 "$IPV6_ROUTE_GUARD" "$IPV6_ADDR_GUARD"
}

verify_ipv6_unchanged() {
  local current_route current_v6 expected_route expected_v6

  [[ -s "$IPV6_ROUTE_GUARD" && -s "$IPV6_ADDR_GUARD" ]] \
    || return 1

  expected_route="$(cat "$IPV6_ROUTE_GUARD")"
  expected_v6="$(cat "$IPV6_ADDR_GUARD")"
  current_route="$(current_ipv6_path)" || return 1
  current_v6="$(native_ipv6)" || return 1

  [[ "$current_route" == "$expected_route" && "$current_v6" == "$expected_v6" ]]
}

warp_trace() {
  curl -4 --interface "$WG_IF" \
    --proto '=https' --tlsv1.2 -fsS --max-time 20 "$TRACE_URL"
}

verify_warp_ipv4() {
  local trace

  trace="$(warp_trace)" || return 1
  grep -Eq '^warp=(on|plus)$' <<< "$trace"
}

cancel_rollback() {
  systemctl stop "${ROLLBACK_UNIT}.timer" >/dev/null 2>&1 || true
  systemctl stop "${ROLLBACK_UNIT}.service" >/dev/null 2>&1 || true
  systemctl reset-failed "${ROLLBACK_UNIT}.timer" "${ROLLBACK_UNIT}.service" \
    >/dev/null 2>&1 || true
}

schedule_rollback() {
  cancel_rollback
  systemd-run \
    --quiet \
    --unit="$ROLLBACK_UNIT" \
    --on-active="${ROLLBACK_SECONDS}s" \
    --timer-property=AccuracySec=1s \
    "$MANAGER" rollback

  if ! systemctl is-active --quiet "${ROLLBACK_UNIT}.timer"; then
    cancel_rollback
    die "无法建立自动回滚计时器，拒绝启用 WARP。"
  fi
}

remove_warp_route() {
  while ip -4 route del default dev "$WG_IF" metric "$WARP_ROUTE_METRIC" \
    >/dev/null 2>&1; do
    :
  done
}

down_tunnel() {
  remove_warp_route
  if is_interface_up; then
    if ! wg-quick down "$WG_IF" >/dev/null 2>&1; then
      warn "wg-quick down 失败，尝试仅删除 $WG_IF 接口。"
      ip link del dev "$WG_IF" >/dev/null 2>&1 || true
    fi
  fi
}

enable_warp() {
  local endpoint_v6 trace

  require_root
  check_systemd
  [[ -s "$WG_CONF" && -x "$MANAGER" ]] || die "尚未安装，请先执行 install。"

  if is_interface_up; then
    warn "WARP IPv4 已经启用。"
    status_warp
    return
  fi

  install_dependencies
  check_native_ipv6
  check_pure_ipv6_host
  check_wireguard_kernel

  endpoint_v6="$(resolve_warp_endpoint_v6)"
  printf '%s\n' "$endpoint_v6" > "$ENDPOINT_FILE"
  chmod 600 "$ENDPOINT_FILE"
  sed -i -E \
    "s#^Endpoint[[:space:]]*=.*#Endpoint = [${endpoint_v6}]:${WARP_ENDPOINT_PORT}#" \
    "$WG_CONF"

  save_ipv6_guards
  schedule_rollback

  info "自动回滚已预先设置为 ${ROLLBACK_SECONDS} 秒后执行。"
  if ! wg-quick up "$WG_IF"; then
    cancel_rollback
    down_tunnel
    die "WireGuard 启动失败，已回滚。"
  fi

  remove_warp_route
  if ! ip -4 route add default dev "$WG_IF" metric "$WARP_ROUTE_METRIC"; then
    down_tunnel
    cancel_rollback
    die "无法添加 WARP IPv4 路由，已回滚。"
  fi

  if ! verify_ipv6_unchanged; then
    down_tunnel
    cancel_rollback
    die "检测到 IPv6 默认路由或公网 IPv6 发生变化，已自动回滚。"
  fi

  if ! verify_warp_ipv4; then
    down_tunnel
    cancel_rollback
    die "WARP IPv4 连通性验证失败，已自动回滚。"
  fi

  trace="$(warp_trace 2>/dev/null || true)"
  say
  say "WARP IPv4 已临时启用，IPv6 路由和公网 IPv6 保持不变。"
  if [[ -n "$trace" ]]; then
    grep -E '^(ip|colo|warp)=' <<< "$trace" || true
  fi
  say
  warn "尚未永久确认！请立即新开一个 IPv6 SSH 会话测试。"
  warn "${ROLLBACK_SECONDS} 秒内未执行 confirm，脚本会自动关闭 WARP。"
  say "确认命令：sudo $MANAGER confirm"
  say "立即关闭：sudo $MANAGER off"
}

confirm_warp() {
  require_root
  is_interface_up || die "WARP IPv4 当前未启用。"

  if ! verify_ipv6_unchanged; then
    down_tunnel
    cancel_rollback
    die "IPv6 安全校验失败，已自动关闭 WARP。"
  fi
  if ! verify_warp_ipv4; then
    down_tunnel
    cancel_rollback
    die "WARP IPv4 校验失败，已自动关闭 WARP。"
  fi

  cancel_rollback
  say "已确认本次启用；自动回滚计时器已取消。"
  say "WARP 仍不会开机自启，重启 VPS 后默认关闭。"
}

disable_warp() {
  require_root
  cancel_rollback
  down_tunnel
  rm -f "$IPV6_ROUTE_GUARD" "$IPV6_ADDR_GUARD"
  rmdir "$RUN_DIR" 2>/dev/null || true
  say "WARP IPv4 已关闭；IPv6 配置未改动。"
}

rollback_warp() {
  require_root
  warn "未收到人工确认，正在执行 WARP IPv4 自动回滚。"
  down_tunnel
  rm -f "$IPV6_ROUTE_GUARD" "$IPV6_ADDR_GUARD"
  rmdir "$RUN_DIR" 2>/dev/null || true
}

status_warp() {
  local trace=""

  require_root
  say "脚本版本：$SCRIPT_VERSION"
  say "配置文件：$WG_CONF"
  say

  if is_interface_up; then
    say "状态：WARP IPv4 已启用"
    wg show "$WG_IF" || true
    say
    say "IPv4 默认路由："
    ip -4 route show default || true
    say
    say "IPv6 默认路由（应为 VPS 原生路由）："
    ip -6 route show default || true
    say
    trace="$(warp_trace 2>/dev/null || true)"
    if [[ -n "$trace" ]]; then
      say "WARP IPv4 出口："
      grep -E '^(ip|colo|warp)=' <<< "$trace" || true
    else
      warn "无法验证 WARP IPv4 出口。"
    fi
  else
    say "状态：WARP IPv4 已关闭"
    say "IPv6 默认路由："
    ip -6 route show default || true
  fi

  say
  if systemctl is-active --quiet "${ROLLBACK_UNIT}.timer"; then
    warn "自动回滚计时器正在等待确认："
    systemctl status "${ROLLBACK_UNIT}.timer" --no-pager --lines=0 || true
  else
    say "自动回滚计时器：未运行"
  fi
}

uninstall_warp() {
  local answer

  require_root
  say "卸载会关闭 WARP 并删除本机私钥和配置。"
  say "不会卸载系统的 WireGuard/curl/jq 软件包，也不会改动 IPv6。"
  say "Cloudflare 侧已注册的 consumer WARP 设备记录不会被远程删除。"
  read -r -p "确认卸载请输入 REMOVE： " answer
  [[ "$answer" == "REMOVE" ]] || die "已取消卸载。"

  cancel_rollback
  down_tunnel
  systemctl disable "wg-quick@${WG_IF}.service" >/dev/null 2>&1 || true

  rm -f \
    "$WG_CONF" \
    "$ACCOUNT_JSON" \
    "$ENDPOINT_FILE" \
    "$IPV6_ROUTE_GUARD" \
    "$IPV6_ADDR_GUARD"
  rmdir "$RUN_DIR" "$CONFIG_DIR" 2>/dev/null || true

  rm -f "$MANAGER"

  say "本机 WARP IPv4 配置已卸载。"
}

show_help() {
  cat <<EOF
用法：sudo $0 <命令>

命令：
  install    安装并注册，但不启用 WARP
  on         临时启用 IPv4 -> WARP，并启动 ${ROLLBACK_SECONDS} 秒自动回滚
  confirm    确认 IPv6 SSH 正常并取消自动回滚
  off        立即关闭 WARP IPv4
  status     查看 WireGuard、IPv4/IPv6 路由和回滚计时器
  uninstall  关闭并删除本机 WARP 配置
  help       显示帮助

无参数运行时显示交互菜单。
EOF
}

menu() {
  local choice

  while true; do
    say
    say "===== 纯 IPv6 VPS：按需 WARP IPv4 ====="
    say "1. 安装/注册（不会启用）"
    say "2. 启用 WARP IPv4（带自动回滚）"
    say "3. 确认连接安全，取消自动回滚"
    say "4. 关闭 WARP IPv4"
    say "5. 查看状态"
    say "6. 卸载本机配置"
    say "0. 退出"
    read -r -p "请选择： " choice
    case "$choice" in
      1) install_warp ;;
      2) enable_warp ;;
      3) confirm_warp ;;
      4) disable_warp ;;
      5) status_warp ;;
      6) uninstall_warp; return ;;
      0) return ;;
      *) warn "无效选择。" ;;
    esac
  done
}

main() {
  case "${1:-menu}" in
    install) install_warp ;;
    on|enable|start) enable_warp ;;
    confirm) confirm_warp ;;
    off|disable|stop) disable_warp ;;
    rollback) rollback_warp ;;
    status) status_warp ;;
    uninstall|remove) uninstall_warp ;;
    help|-h|--help) show_help ;;
    menu) menu ;;
    *) show_help; exit 1 ;;
  esac
}

main "$@"
