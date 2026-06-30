#!/usr/bin/env bash
#
# Hetzner Storage Box + FileBrowser + qBittorrent 挂载管理脚本
# 适用：Debian / Ubuntu（systemd）
#
# 安全边界：
# - 不删除 FileBrowser 本地数据或 Storage Box 远程文件。
# - 不修改 Nginx、证书、节点协议、Telegram 监控或防火墙。
# - Storage Box 密码仅交给 rclone obscure 后写入 rclone 配置。

set -uo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="1.0.0"
readonly RCLONE_SERVICE="rclone-storagebox.service"
readonly QBIT_SERVICE="qbittorrent-storagebox.service"
readonly RCLONE_UNIT="/etc/systemd/system/${RCLONE_SERVICE}"
readonly QBIT_UNIT="/etc/systemd/system/${QBIT_SERVICE}"
readonly STATE_FILE="/etc/rclone-storagebox.conf"
readonly RCLONE_CONFIG="/root/.config/rclone/rclone.conf"
readonly QBIT_PROFILE="/var/lib/qbittorrent-storagebox"
readonly QBIT_CONFIG="${QBIT_PROFILE}/qBittorrent/config/qBittorrent.conf"
readonly VFS_CACHE_DIR="/var/cache/rclone/storagebox"

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_BLUE='\033[0;34m'
COLOR_RESET='\033[0m'

info() { printf '%b[信息]%b %s\n' "$COLOR_BLUE" "$COLOR_RESET" "$*"; }
ok() { printf '%b[成功]%b %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$*"; }
warn() { printf '%b[警告]%b %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$*" >&2; }
error() { printf '%b[错误]%b %s\n' "$COLOR_RED" "$COLOR_RESET" "$*" >&2; }
die() { error "$*"; exit 1; }

pause() {
    printf '\n'
    read -r -p "按 Enter 返回菜单..." _ || true
}

confirm() {
    local prompt="${1:-确认继续吗？}"
    local answer
    read -r -p "${prompt} [y/N]: " answer || return 1
    [[ "$answer" == "y" || "$answer" == "Y" ]]
}

require_root_and_systemd() {
    [[ "${EUID}" -eq 0 ]] || die "必须使用 root 运行：sudo bash Alist.sh"
    command -v systemctl >/dev/null 2>&1 || die "未找到 systemctl；本脚本仅支持使用 systemd 的 Debian/Ubuntu。"
    [[ -d /run/systemd/system ]] || die "当前系统没有运行 systemd。"
    command -v apt-get >/dev/null 2>&1 || die "未找到 apt-get；本脚本仅支持 Debian/Ubuntu。"
}

validate_absolute_path() {
    local value="$1"
    [[ "$value" == /* && "$value" != *$'\n'* && "$value" != *$'\r'* ]]
}

validate_remote_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

shell_quote() {
    printf '%q' "$1"
}

systemd_quote() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//%/%%}
    printf '"%s"' "$value"
}

sh_single_quote() {
    local value="$1"
    value=${value//\'/\'\\\'\'}
    printf "'%s'" "$value"
}

load_state() {
    REMOTE_NAME="storagebox"
    FILEBROWSER_ROOT="/srv/filebrowser"
    MOUNT_POINT="/srv/filebrowser/storagebox"
    QBIT_WEBUI_ADDRESS="127.0.0.1"
    QBIT_WEBUI_PORT="8080"
    if [[ -r "$STATE_FILE" ]]; then
        # 本文件由本脚本生成，只包含经过 shell 转义的非敏感参数。
        # shellcheck disable=SC1090
        source "$STATE_FILE"
    fi
}

save_state() {
    umask 077
    {
        printf 'REMOTE_NAME=%s\n' "$(shell_quote "$REMOTE_NAME")"
        printf 'FILEBROWSER_ROOT=%s\n' "$(shell_quote "$FILEBROWSER_ROOT")"
        printf 'MOUNT_POINT=%s\n' "$(shell_quote "$MOUNT_POINT")"
        printf 'QBIT_WEBUI_ADDRESS=%s\n' "$(shell_quote "$QBIT_WEBUI_ADDRESS")"
        printf 'QBIT_WEBUI_PORT=%s\n' "$(shell_quote "$QBIT_WEBUI_PORT")"
    } > "$STATE_FILE"
    chmod 600 "$STATE_FILE"
}

install_packages() {
    info "更新软件包索引并安装 rclone、fuse3、qbittorrent-nox..."
    if ! apt-get update; then
        error "apt-get update 失败。"
        return 1
    fi
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y rclone fuse3 qbittorrent-nox ca-certificates iproute2; then
        error "软件包安装失败。"
        return 1
    fi

    command -v rclone >/dev/null 2>&1 || { error "rclone 安装后仍不可用。"; return 1; }
    command -v fusermount3 >/dev/null 2>&1 || { error "fusermount3 安装后仍不可用。"; return 1; }
    command -v qbittorrent-nox >/dev/null 2>&1 || { error "qbittorrent-nox 安装后仍不可用。"; return 1; }
    ok "所需软件已安装。"
}

ensure_fuse_allow_other() {
    local fuse_conf="/etc/fuse.conf"
    [[ -e "$fuse_conf" ]] || touch "$fuse_conf"

    if grep -Eq '^[[:space:]]*user_allow_other([[:space:]]*(#.*)?)?$' "$fuse_conf"; then
        info "/etc/fuse.conf 已包含 user_allow_other。"
        return 0
    fi

    if grep -Eq '^[[:space:]]*#[[:space:]]*user_allow_other([[:space:]]*(#.*)?)?$' "$fuse_conf"; then
        sed -i -E '0,/^[[:space:]]*#[[:space:]]*user_allow_other([[:space:]]*(#.*)?)?$/s//user_allow_other/' "$fuse_conf"
    else
        printf '\nuser_allow_other\n' >> "$fuse_conf"
    fi
    ok "已确保 /etc/fuse.conf 包含 user_allow_other，且不会重复添加。"
}

choose_filebrowser_paths() {
    local input
    if [[ -d /srv/filebrowser ]]; then
        read -r -p "FileBrowser 根目录 [默认 /srv/filebrowser]: " input
        FILEBROWSER_ROOT="${input:-/srv/filebrowser}"
    else
        warn "默认 FileBrowser 根目录 /srv/filebrowser 不存在。"
        while true; do
            read -r -p "请输入实际 FileBrowser 根目录（必须已存在）: " input
            if validate_absolute_path "$input" && [[ -d "$input" ]]; then
                FILEBROWSER_ROOT="${input%/}"
                break
            fi
            error "请输入已经存在的绝对目录。"
        done
    fi

    validate_absolute_path "$FILEBROWSER_ROOT" || { error "FileBrowser 根目录必须是绝对路径。"; return 1; }
    [[ -d "$FILEBROWSER_ROOT" ]] || { error "目录不存在：$FILEBROWSER_ROOT"; return 1; }
    FILEBROWSER_ROOT="${FILEBROWSER_ROOT%/}"
    MOUNT_POINT="${FILEBROWSER_ROOT}/storagebox"

    if command -v mountpoint >/dev/null 2>&1 && mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        warn "$MOUNT_POINT 当前已经是挂载点。重新配置前需要停止现有挂载。"
        confirm "确认停止现有 qBittorrent 和挂载服务后重新配置吗？" || return 1
        systemctl stop "$QBIT_SERVICE" 2>/dev/null || true
        systemctl stop "$RCLONE_SERVICE" 2>/dev/null || true
        if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
            fusermount3 -u "$MOUNT_POINT" 2>/dev/null || {
                error "现有挂载无法卸载，可能仍有程序正在使用。"
                return 1
            }
        fi
    fi

    mkdir -p "$MOUNT_POINT"
    if find "$MOUNT_POINT" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
        warn "挂载点 $MOUNT_POINT 已有本地内容。"
        warn "继续挂载不会删除这些文件，但挂载期间它们会被远程目录遮住。"
        confirm "确认保留原内容并继续挂载吗？" || return 1
    fi
}

choose_storagebox_settings() {
    local input default_host password password_confirm obscured

    while true; do
        read -r -p "Storage Box 用户名（例如 u624460）: " STORAGEBOX_USER
        [[ -n "$STORAGEBOX_USER" && "$STORAGEBOX_USER" != *$'\n'* ]] && break
        error "用户名不能为空。"
    done

    default_host="${STORAGEBOX_USER}.your-storagebox.de"
    read -r -p "Host [默认 ${default_host}]: " input
    STORAGEBOX_HOST="${input:-$default_host}"
    [[ -n "$STORAGEBOX_HOST" && "$STORAGEBOX_HOST" != *[[:space:]]* ]] || {
        error "Host 格式不正确。"
        return 1
    }

    read -r -p "SFTP 端口 [默认 23]: " input
    STORAGEBOX_PORT="${input:-23}"
    validate_port "$STORAGEBOX_PORT" || { error "端口必须是 1-65535。"; return 1; }

    read -r -p "rclone remote 名 [默认 storagebox]: " input
    REMOTE_NAME="${input:-storagebox}"
    validate_remote_name "$REMOTE_NAME" || {
        error "remote 名只能包含字母、数字、下划线和连字符，且必须以字母或数字开头。"
        return 1
    }

    while true; do
        read -r -s -p "Storage Box 密码（不会回显）: " password
        printf '\n'
        [[ -n "$password" ]] || { error "密码不能为空。"; continue; }
        read -r -s -p "再次输入密码: " password_confirm
        printf '\n'
        [[ "$password" == "$password_confirm" ]] && break
        error "两次密码不一致，请重试。"
    done

    mkdir -p "$(dirname "$RCLONE_CONFIG")"
    chmod 700 "$(dirname "$RCLONE_CONFIG")"
    touch "$RCLONE_CONFIG"
    chmod 600 "$RCLONE_CONFIG"

    if rclone listremotes --config "$RCLONE_CONFIG" 2>/dev/null | grep -Fxq "${REMOTE_NAME}:"; then
        warn "rclone remote '${REMOTE_NAME}' 已存在。"
        if ! confirm "确认覆盖这个 remote 的连接参数吗？"; then
            password=''
            password_confirm=''
            unset password password_confirm
            return 1
        fi
    fi

    obscured="$(rclone obscure "$password")" || {
        password=''
        password_confirm=''
        unset password password_confirm
        error "密码混淆处理失败。"
        return 1
    }
    password=''
    password_confirm=''
    unset password password_confirm

    if ! rclone config create "$REMOTE_NAME" sftp \
        host "$STORAGEBOX_HOST" \
        user "$STORAGEBOX_USER" \
        port "$STORAGEBOX_PORT" \
        pass "$obscured" \
        --config "$RCLONE_CONFIG" \
        --non-interactive >/dev/null; then
        obscured=''
        unset obscured
        error "创建 rclone remote 失败。"
        return 1
    fi
    obscured=''
    unset obscured
    chmod 600 "$RCLONE_CONFIG"
    ok "rclone remote '${REMOTE_NAME}' 已写入受限权限配置：$RCLONE_CONFIG"
}

test_remote_named() {
    local remote="$1"
    info "测试连接：rclone lsd ${remote}:"
    if rclone lsd "${remote}:" --config "$RCLONE_CONFIG"; then
        ok "Storage Box SFTP 连接正常。"
        return 0
    fi
    error "连接失败。请检查用户名、Host、端口、密码及 Hetzner Storage Box 的 SSH/SFTP 设置。"
    return 1
}

choose_qbit_settings() {
    local input requested_port candidate found_port=""
    QBIT_WEBUI_ADDRESS="127.0.0.1"
    QBIT_WEBUI_PORT="8080"

    read -r -p "qBittorrent Web UI 监听地址 [默认 127.0.0.1]: " input
    QBIT_WEBUI_ADDRESS="${input:-127.0.0.1}"
    [[ "$QBIT_WEBUI_ADDRESS" =~ ^[0-9A-Fa-f:.]+$ ]] || {
        error "监听地址格式不正确。建议使用 127.0.0.1。"
        return 1
    }
    if [[ "$QBIT_WEBUI_ADDRESS" != "127.0.0.1" && "$QBIT_WEBUI_ADDRESS" != "::1" ]]; then
        warn "非本机监听地址可能把 qBittorrent Web UI 暴露到公网。"
        warn "本脚本不会修改防火墙、Nginx 或 TLS。"
        confirm "确认承担暴露风险并继续吗？" || return 1
    fi

    read -r -p "qBittorrent Web UI 端口 [默认 8080]: " input
    requested_port="${input:-8080}"
    validate_port "$requested_port" || { error "端口必须是 1-65535。"; return 1; }
    QBIT_WEBUI_PORT="$requested_port"

    if ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${requested_port}$"; then
        warn "TCP 端口 ${requested_port} 已被占用，正在自动寻找可用端口..."
        for ((candidate = 10#$requested_port + 1; candidate <= 65535 && candidate <= 10#$requested_port + 100; candidate++)); do
            if ! ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${candidate}$"; then
                found_port="$candidate"
                break
            fi
        done
        if [[ -z "$found_port" ]]; then
            for candidate in 18080 28080 38080 48080; do
                if ! ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${candidate}$"; then
                    found_port="$candidate"
                    break
                fi
            done
        fi
        [[ -n "$found_port" ]] || {
            error "未能自动找到可用的 qBittorrent Web UI 端口。"
            return 1
        }
        QBIT_WEBUI_PORT="$found_port"
        ok "已自动选择可用端口：${QBIT_WEBUI_PORT}"
    fi
}

write_rclone_service() {
    local remote_arg mount_arg config_arg cache_arg
    remote_arg="$(systemd_quote "${REMOTE_NAME}:")"
    mount_arg="$(systemd_quote "$MOUNT_POINT")"
    config_arg="$(systemd_quote "$RCLONE_CONFIG")"
    cache_arg="$(systemd_quote "$VFS_CACHE_DIR")"

    mkdir -p "$VFS_CACHE_DIR"
    chmod 700 "$VFS_CACHE_DIR"

    {
        printf '%s\n' '[Unit]'
        printf '%s\n' 'Description=Hetzner Storage Box rclone mount'
        printf '%s\n' 'Documentation=https://rclone.org/commands/rclone_mount/'
        printf '%s\n' 'Wants=network-online.target'
        printf '%s\n' 'After=network-online.target'
        printf '\n'
        printf '%s\n' '[Service]'
        printf 'ExecStart=/usr/bin/rclone mount %s %s \\\n' "$remote_arg" "$mount_arg"
        printf '    --config %s \\\n' "$config_arg"
        printf '    --vfs-cache-mode writes \\\n'
        printf '    --cache-dir %s \\\n' "$cache_arg"
        printf '    --vfs-cache-max-age 24h \\\n'
        printf '    --allow-other \\\n'
        printf '    --dir-cache-time 30m \\\n'
        printf '    --poll-interval 15s \\\n'
        printf '    --file-perms 0666 \\\n'
        printf '%s\n' '    --dir-perms 0777'
        printf 'ExecStop=/bin/fusermount3 -u %s\n' "$mount_arg"
        printf '%s\n' 'Restart=on-failure'
        printf '%s\n' 'RestartSec=10'
        printf '%s\n' 'TimeoutStopSec=60'
        printf '%s\n' 'KillMode=mixed'
        printf '\n'
        printf '%s\n' '[Install]'
        printf '%s\n' 'WantedBy=multi-user.target'
    } > "$RCLONE_UNIT"
    chmod 644 "$RCLONE_UNIT"
}

write_qbit_config_and_service() {
    local qbit_user="qbittorrent-storagebox"
    local save_path="${MOUNT_POINT}/downloads"
    local temp_path="${MOUNT_POINT}/downloads/.incomplete"
    local profile_arg address_arg save_escaped temp_escaped wait_command mount_shell_arg

    if ! getent passwd "$qbit_user" >/dev/null 2>&1; then
        useradd --system --home-dir "$QBIT_PROFILE" --create-home --shell /usr/sbin/nologin "$qbit_user"
    fi
    mkdir -p "$(dirname "$QBIT_CONFIG")"
    chown -R "${qbit_user}:${qbit_user}" "$QBIT_PROFILE"
    chmod 750 "$QBIT_PROFILE" "$(dirname "$QBIT_CONFIG")"

    save_escaped=${save_path//\\/\\\\}
    temp_escaped=${temp_path//\\/\\\\}
    {
        printf '%s\n' '[BitTorrent]'
        printf 'Session\\DefaultSavePath=%s\n' "$save_escaped"
        printf 'Session\\TempPath=%s\n' "$temp_escaped"
        printf '%s\n' 'Session\TempPathEnabled=true'
        printf '\n'
        printf '%s\n' '[Preferences]'
        printf 'Downloads\\SavePath=%s\n' "$save_escaped"
        printf 'Downloads\\TempPath=%s\n' "$temp_escaped"
        printf '%s\n' 'Downloads\TempPathEnabled=true'
        printf 'WebUI\\Address=%s\n' "$QBIT_WEBUI_ADDRESS"
        printf 'WebUI\\Port=%s\n' "$QBIT_WEBUI_PORT"
        printf '%s\n' 'WebUI\Username=admin'
        printf '%s\n' 'WebUI\CSRFProtection=true'
        printf '%s\n' 'WebUI\HostHeaderValidation=true'
    } > "$QBIT_CONFIG"
    chown "${qbit_user}:${qbit_user}" "$QBIT_CONFIG"
    chmod 600 "$QBIT_CONFIG"

    profile_arg="$(systemd_quote "$QBIT_PROFILE")"
    address_arg="$(systemd_quote "$QBIT_WEBUI_ADDRESS")"
    mount_shell_arg="$(sh_single_quote "$MOUNT_POINT")"
    wait_command="for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do /usr/bin/mountpoint -q ${mount_shell_arg} && exit 0; /bin/sleep 1; done; exit 1"
    {
        printf '%s\n' '[Unit]'
        printf '%s\n' 'Description=qBittorrent-nox for Hetzner Storage Box'
        printf '%s\n' "Requires=${RCLONE_SERVICE}"
        printf '%s\n' "After=network-online.target ${RCLONE_SERVICE}"
        printf '\n'
        printf '%s\n' '[Service]'
        printf '%s\n' "User=${qbit_user}"
        printf '%s\n' "Group=${qbit_user}"
        printf 'ExecStartPre=/bin/sh -c %s\n' "$(systemd_quote "$wait_command")"
        printf 'ExecStart=/usr/bin/qbittorrent-nox --profile=%s --webui-port=%s\n' "$profile_arg" "$QBIT_WEBUI_PORT"
        printf '%s\n' 'Restart=on-failure'
        printf '%s\n' 'RestartSec=10'
        printf '%s\n' 'TimeoutStopSec=30'
        printf '%s\n' 'UMask=0027'
        printf '\n'
        printf '%s\n' '[Install]'
        printf '%s\n' 'WantedBy=multi-user.target'
    } > "$QBIT_UNIT"
    chmod 644 "$QBIT_UNIT"

    # address_arg 仅用于触发严格参数检查，监听地址由 qBittorrent 配置文件控制。
    : "$address_arg"
}

show_failure_logs() {
    error "rclone 挂载服务启动失败，最近 50 行日志如下："
    journalctl -u "$RCLONE_SERVICE" -n 50 --no-pager || true
}

verify_mount() {
    local mount_point="$1"
    if command -v mountpoint >/dev/null 2>&1 && ! mountpoint -q "$mount_point"; then
        show_failure_logs
        return 1
    fi
    printf '\n'
    info "df -h 检查："
    df -h "$mount_point" || true
    printf '\n'
    info "ls -lh 检查："
    ls -lh "$mount_point" || true
    ok "Storage Box 已挂载到：$mount_point"
}

show_qbit_access() {
    local host_hint
    printf '\n'
    ok "qBittorrent 下载目录：${MOUNT_POINT}/downloads"
    if [[ "$QBIT_WEBUI_ADDRESS" == "127.0.0.1" || "$QBIT_WEBUI_ADDRESS" == "::1" ]]; then
        host_hint="<VPS_IP>"
        info "安全访问方式（在自己的电脑执行）："
        printf '  ssh -L %s:127.0.0.1:%s root@%s\n' "$QBIT_WEBUI_PORT" "$QBIT_WEBUI_PORT" "$host_hint"
        printf '  然后浏览器打开：http://127.0.0.1:%s\n' "$QBIT_WEBUI_PORT"
    else
        printf '  Web UI：http://<VPS_IP>:%s\n' "$QBIT_WEBUI_PORT"
    fi
    info "用户名：admin"
    info "首次启动密码请查看：journalctl -u ${QBIT_SERVICE} -n 50 --no-pager"
    warn "部分旧版 qBittorrent 的初始密码可能是 adminadmin；登录后请立即修改密码。"
}

install_and_configure() {
    load_state
    printf '\n'
    info "开始安装/配置 Hetzner Storage Box 与 qBittorrent。"
    warn "此操作会安装软件、更新 rclone remote，并创建两个 systemd 服务。"
    confirm "确认开始吗？" || { info "已取消。"; return; }

    install_packages || return
    ensure_fuse_allow_other || return
    choose_filebrowser_paths || return
    choose_storagebox_settings || return
    test_remote_named "$REMOTE_NAME" || {
        warn "连接未通过，未创建或启动 systemd 服务；rclone 配置已保留供排查。"
        return
    }
    choose_qbit_settings || return
    save_state
    write_rclone_service || return
    write_qbit_config_and_service || return

    systemctl daemon-reload
    systemctl enable "$RCLONE_SERVICE" "$QBIT_SERVICE"
    if ! systemctl restart "$RCLONE_SERVICE"; then
        show_failure_logs
        return
    fi
    verify_mount "$MOUNT_POINT" || return

    mkdir -p "${MOUNT_POINT}/downloads/.incomplete"
    if ! systemctl restart "$QBIT_SERVICE"; then
        error "qBittorrent 服务启动失败："
        journalctl -u "$QBIT_SERVICE" -n 50 --no-pager || true
        return
    fi
    ok "已启用开机自动挂载和 qBittorrent 自动启动。"
    show_qbit_access
    print_usage_notes
}

show_status() {
    load_state
    printf '\n'
    info "rclone 挂载服务状态："
    systemctl status "$RCLONE_SERVICE" --no-pager -l || true
    printf '\n'
    info "qBittorrent 服务状态："
    systemctl status "$QBIT_SERVICE" --no-pager -l || true
    printf '\n'
    info "挂载点：$MOUNT_POINT"
    if command -v findmnt >/dev/null 2>&1; then
        findmnt -T "$MOUNT_POINT" || true
    fi
    df -h "$MOUNT_POINT" 2>/dev/null || true
    ls -lh "$MOUNT_POINT" 2>/dev/null || true
}

restart_services() {
    load_state
    [[ -f "$RCLONE_UNIT" ]] || { error "未找到 $RCLONE_UNIT，请先执行安装/配置。"; return; }
    warn "重启挂载时，正在进行的 qBittorrent 任务会短暂停止。"
    confirm "确认重启挂载与 qBittorrent 服务吗？" || { info "已取消。"; return; }

    systemctl stop "$QBIT_SERVICE" 2>/dev/null || true
    if ! systemctl restart "$RCLONE_SERVICE"; then
        show_failure_logs
        return
    fi
    verify_mount "$MOUNT_POINT" || return
    if [[ -f "$QBIT_UNIT" ]]; then
        systemctl start "$QBIT_SERVICE" || {
            error "挂载成功，但 qBittorrent 启动失败。"
            journalctl -u "$QBIT_SERVICE" -n 50 --no-pager || true
            return
        }
    fi
    ok "服务已重启。"
}

unmount_current() {
    load_state
    warn "将停止 qBittorrent 并卸载当前 Storage Box；不会删除本地或远程文件。"
    warn "systemd 服务仍保持启用，下次开机仍会自动挂载。"
    confirm "确认卸载当前挂载吗？" || { info "已取消。"; return; }

    systemctl stop "$QBIT_SERVICE" 2>/dev/null || true
    systemctl stop "$RCLONE_SERVICE" 2>/dev/null || true
    if command -v mountpoint >/dev/null 2>&1 && mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        if ! fusermount3 -u "$MOUNT_POINT"; then
            error "卸载失败，可能有进程仍在使用挂载点。"
            return
        fi
    fi
    ok "当前挂载已卸载；没有删除任何目录或文件。"
}

delete_services_keep_config() {
    load_state
    warn "将停止并删除 ${RCLONE_SERVICE} 与 ${QBIT_SERVICE}。"
    warn "会保留 rclone 配置、qBittorrent 配置、挂载目录以及全部本地/远程文件。"
    confirm "第一次确认：继续删除 systemd 服务吗？" || { info "已取消。"; return; }
    confirm "第二次确认：确定删除服务文件吗？" || { info "已取消。"; return; }

    systemctl stop "$QBIT_SERVICE" 2>/dev/null || true
    systemctl stop "$RCLONE_SERVICE" 2>/dev/null || true
    systemctl disable "$QBIT_SERVICE" 2>/dev/null || true
    systemctl disable "$RCLONE_SERVICE" 2>/dev/null || true
    if command -v mountpoint >/dev/null 2>&1 && mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        fusermount3 -u "$MOUNT_POINT" 2>/dev/null || {
            error "挂载点仍忙，未删除服务文件。"
            return
        }
    fi
    rm -f -- "$QBIT_UNIT" "$RCLONE_UNIT"
    systemctl daemon-reload
    systemctl reset-failed "$QBIT_SERVICE" "$RCLONE_SERVICE" 2>/dev/null || true
    ok "systemd 服务已删除；rclone 和 qBittorrent 配置均已保留。"
}

test_remote_menu() {
    local input
    load_state
    command -v rclone >/dev/null 2>&1 || { error "未安装 rclone，请先执行安装/配置。"; return; }
    [[ -f "$RCLONE_CONFIG" ]] || { error "未找到 rclone 配置：$RCLONE_CONFIG"; return; }
    read -r -p "要测试的 rclone remote [默认 ${REMOTE_NAME}]: " input
    input="${input:-$REMOTE_NAME}"
    validate_remote_name "$input" || { error "remote 名格式不正确。"; return; }
    test_remote_named "$input"
}

print_usage_notes() {
    load_state
    printf '\n'
    printf '%s\n' '================ 使用说明 ================'
    printf '1. FileBrowser 里的 storagebox 文件夹就是 Hetzner Storage Box：%s\n' "$MOUNT_POINT"
    printf '%s\n' '2. 上传到 storagebox 的最终文件存放在 Storage Box，不长期占用 VPS 本地硬盘。'
    printf '%s\n' '3. rclone VFS 缓存和未完成下载会短暂占用 VPS 本地空间；上传完成并过期后释放。'
    printf '%s\n' '4. 上传到 FileBrowser 其他目录仍会占用 VPS 本地硬盘。'
    printf '%s\n' '5. 通过 FileBrowser 访问 Storage Box 会消耗 VPS 流量。'
    printf '%s\n' '6. 手机直连 Hetzner WebDAV 访问 Storage Box 不经过 VPS。'
    printf '%s\n' '7. qBittorrent 默认下载到 storagebox/downloads；请登录后立即修改 Web UI 密码。'
    printf '%s\n' '==========================================='
}

show_menu() {
    clear 2>/dev/null || true
    printf '%s\n' "Hetzner Storage Box 挂载管理 v${SCRIPT_VERSION}"
    printf '%s\n' '（含 FileBrowser 与 qBittorrent-nox 配置）'
    printf '%s\n' '-------------------------------------------'
    printf '%s\n' '1) 安装/配置 Storage Box 挂载'
    printf '%s\n' '2) 查看挂载状态'
    printf '%s\n' '3) 重启挂载服务'
    printf '%s\n' '4) 卸载当前挂载'
    printf '%s\n' '5) 删除 systemd 服务但保留 rclone 配置'
    printf '%s\n' '6) 测试 rclone 连接'
    printf '%s\n' '7) 退出'
    printf '%s\n' '-------------------------------------------'
}

main() {
    local choice
    require_root_and_systemd
    while true; do
        show_menu
        read -r -p "请选择 [1-7]: " choice || exit 0
        case "$choice" in
            1) install_and_configure; pause ;;
            2) show_status; pause ;;
            3) restart_services; pause ;;
            4) unmount_current; pause ;;
            5) delete_services_keep_config; pause ;;
            6) test_remote_menu; pause ;;
            7) print_usage_notes; exit 0 ;;
            *) error "无效选项，请输入 1-7。"; pause ;;
        esac
    done
}

main "$@"
