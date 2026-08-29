#!/usr/bin/env bash
# OpenClaw VPS 运维：异常告警、记忆增量索引、每周本机备份。
# 仅用于私有、已配置 openclaw-weixin 的 Root Gateway。
set -Eeuo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "请使用 root 运行：sudo bash install-openclaw-operations.sh"
  exit 1
fi

if ! command -v openclaw >/dev/null 2>&1; then
  echo "未找到 openclaw，未作任何修改。"
  exit 1
fi

install -d -m 700 /var/lib/openclaw-ops /root/.openclaw/backups/automatic

cat > /usr/local/sbin/openclaw-health-monitor.sh <<'MONITOR'
#!/usr/bin/env bash
set -Eeuo pipefail

state_dir=/var/lib/openclaw-ops
state_file="$state_dir/health-monitor.state"
session_file=/root/.openclaw/agents/main/sessions/sessions.json
admin_state=/root/.openclaw/wechat-ai-provider-admin/state.json
openclaw_bin="$(command -v openclaw)"
mkdir -p "$state_dir"
chmod 700 "$state_dir"

issues=()
if ! systemctl is-active --quiet openclaw-gateway.service; then
  issues+=("OpenClaw 网关未运行")
fi
if ! docker inspect -f '{{.State.Running}}' openclaw-searxng 2>/dev/null | grep -qx true; then
  issues+=("SearXNG 搜索服务未运行")
fi

available_mb=$(free -m | awk '/^Mem:/ {print $7}')
swap_used_mb=$(free -m | awk '/^Swap:/ {print $3}')
disk_used_pct=$(df -P / | awk 'END {gsub(/%/, "", $5); print $5}')
if [[ "$available_mb" =~ ^[0-9]+$ ]] && (( available_mb < 300 )); then
  issues+=("可用内存仅 ${available_mb}MB")
fi
if [[ "$swap_used_mb" =~ ^[0-9]+$ ]] && (( swap_used_mb > 1024 )); then
  issues+=("交换分区已使用 ${swap_used_mb}MB")
fi
if [[ "$disk_used_pct" =~ ^[0-9]+$ ]] && (( disk_used_pct >= 80 )); then
  issues+=("系统磁盘已使用 ${disk_used_pct}%")
fi

latest_backup=$(find /root/.openclaw/backups/automatic -maxdepth 1 -type f -name 'openclaw-auto-*.tgz' -printf '%T@\n' 2>/dev/null | sort -n | tail -n 1 || true)
if [[ -n "$latest_backup" ]]; then
  now_epoch=$(date +%s)
  backup_epoch=${latest_backup%.*}
  if (( now_epoch - backup_epoch > 691200 )); then
    issues+=("自动备份已超过 8 天未成功")
  fi
fi
if command -v rclone >/dev/null 2>&1 && rclone listremotes 2>/dev/null | grep -qx 'onedrive-crypt:'; then
  cloud_success=/var/lib/openclaw-ops/onedrive-backup.last-success
  if [[ ! -f "$cloud_success" ]] || (( $(date +%s) - $(stat -c %Y "$cloud_success") > 691200 )); then
    issues+=("OneDrive 异地备份已超过 8 天未成功")
  fi
fi

get_session_key() {
  node - "$admin_state" "$session_file" <<'NODE'
const fs = require('fs');
const [adminPath, sessionsPath] = process.argv.slice(2);
try {
  const admin = JSON.parse(fs.readFileSync(adminPath, 'utf8')).adminSenderId;
  const sessions = JSON.parse(fs.readFileSync(sessionsPath, 'utf8'));
  const candidates = Object.entries(sessions)
    .filter(([key, value]) => key.includes('openclaw-weixin:direct:') && value?.origin?.provider === 'openclaw-weixin' && value?.origin?.chatType === 'direct')
    .filter(([, value]) => !admin || value?.origin?.from === admin)
    .sort((a, b) => Number(b[1]?.updatedAt || 0) - Number(a[1]?.updatedAt || 0));
  if (candidates[0]) process.stdout.write(candidates[0][0]);
} catch {}
NODE
}

enqueue_notice() {
  local text="$1"
  local session_key
  session_key=$(get_session_key)
  if [[ -z "$session_key" ]]; then
    logger -t openclaw-health-monitor "无法定位管理员微信私聊会话，未发送：$text"
    return 1
  fi
  "$openclaw_bin" cron add \
    --name "系统监控通知" \
    --at +20s \
    --delete-after-run \
    --announce \
    --session-key "$session_key" \
    --channel openclaw-weixin \
    --message "请只用一两句自然、关切的简体中文把下面系统通知直接告诉用户；不要解释内部机制、不要输出英文或命令：$text" \
    --description "VPS 系统监控通知" >/dev/null
}

current="正常"
if (( ${#issues[@]} > 0 )); then
  current="异常：$(IFS='；'; echo "${issues[*]}")"
fi
fingerprint=$(printf '%s' "$current" | sha256sum | awk '{print $1}')
previous_fingerprint=""
previous_status=""
if [[ -r "$state_file" ]]; then
  # shellcheck disable=SC1090
  source "$state_file"
fi

if [[ "$current" == "正常" ]]; then
  if [[ "${previous_status:-}" == 异常* ]]; then
    enqueue_notice "✅ VPS 已恢复正常：网关、搜索服务与资源检查均通过。" || exit 0
  fi
  printf 'previous_status=%q\nprevious_fingerprint=%q\n' "$current" "$fingerprint" > "$state_file"
  chmod 600 "$state_file"
  exit 0
fi

if [[ "${previous_fingerprint:-}" != "$fingerprint" ]]; then
  enqueue_notice "⚠️ VPS 监控发现异常：${issues[*]}。为防止误操作，我没有自动重启；如需处理，可直接发送“确认重启 SearXNG”或说明要检查的服务。" || exit 0
fi
printf 'previous_status=%q\nprevious_fingerprint=%q\n' "$current" "$fingerprint" > "$state_file"
chmod 600 "$state_file"
MONITOR
chmod 700 /usr/local/sbin/openclaw-health-monitor.sh

cat > /usr/local/sbin/openclaw-server-backup.sh <<'BACKUP'
#!/usr/bin/env bash
set -Eeuo pipefail

backup_dir=/root/.openclaw/backups/automatic
stage=$(mktemp -d /root/.openclaw/.auto-backup-stage.XXXXXX)
stamp=$(date +%Y%m%d-%H%M%S)
archive="$backup_dir/openclaw-auto-$stamp.tgz"
cleanup() { rm -rf "$stage"; }
trap cleanup EXIT

umask 077
mkdir -p "$backup_dir" "$stage/root/.config" "$stage/opt" "$stage/etc/systemd/system" "$stage/usr/local/sbin"
tar -C /root \
  --exclude='.openclaw/backups' \
  --exclude='.openclaw/.auto-backup-stage*' \
  -cf - .openclaw | tar -C "$stage/root" -xf -
[[ -d /root/.config/rclone ]] && cp -a /root/.config/rclone "$stage/root/.config/"
for item in /opt/openclaw-wechat-ai-provider-admin /opt/openclaw-searxng; do
  [[ -e "$item" ]] && cp -a "$item" "$stage/opt/"
done
for item in /root/install-wechat-ai-root.sh /root/install-wechat-ai-provider-admin.sh /root/install-openclaw-searxng.sh /root/install-openclaw-long-memory.sh /root/install-openclaw-operations.sh; do
  [[ -f "$item" ]] && cp -a "$item" "$stage/root/"
done
[[ -f /etc/systemd/system/openclaw-gateway.service ]] && cp -a /etc/systemd/system/openclaw-gateway.service "$stage/etc/systemd/system/"
[[ -d /etc/systemd/system/openclaw-gateway.service.d ]] && cp -a /etc/systemd/system/openclaw-gateway.service.d "$stage/etc/systemd/system/"
find /usr/local/sbin -maxdepth 1 -type f -name 'openclaw-*' -exec cp -a {} "$stage/usr/local/sbin/" \;
tar -C "$stage" -czf "$archive" root opt etc usr
chmod 600 "$archive"
mapfile -t old_archives < <(find "$backup_dir" -maxdepth 1 -type f -name 'openclaw-auto-*.tgz' -printf '%T@ %p\n' | sort -n | head -n -4 | cut -d' ' -f2-)
for old in "${old_archives[@]:-}"; do
  [[ -n "$old" && "$old" == "$backup_dir"/openclaw-auto-*.tgz ]] && rm -f -- "$old"
done
sha256sum "$archive"
if command -v rclone >/dev/null 2>&1 && rclone listremotes 2>/dev/null | grep -qx 'onedrive-crypt:'; then
  rclone sync --checksum --transfers 1 --checkers 2 --retries 3 "$backup_dir" onedrive-crypt:
  touch /var/lib/openclaw-ops/onedrive-backup.last-success
fi
BACKUP
chmod 700 /usr/local/sbin/openclaw-server-backup.sh

cat > /etc/systemd/system/openclaw-health-monitor.service <<'EOF'
[Unit]
Description=OpenClaw VPS health monitor
After=network-online.target docker.service openclaw-gateway.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/openclaw-health-monitor.sh
EOF

cat > /etc/systemd/system/openclaw-health-monitor.timer <<'EOF'
[Unit]
Description=Run OpenClaw VPS health monitor every five minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
Persistent=true
Unit=openclaw-health-monitor.service

[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/openclaw-memory-index.service <<'EOF'
[Unit]
Description=Incremental OpenClaw long-memory index
After=openclaw-gateway.service

[Service]
Type=oneshot
ExecStart=/usr/bin/openclaw memory index --agent main
EOF

cat > /etc/systemd/system/openclaw-memory-index.timer <<'EOF'
[Unit]
Description=Refresh OpenClaw long-memory index every six hours

[Timer]
OnCalendar=*-*-* 00,06,12,18:20:00
RandomizedDelaySec=10min
Persistent=true
Unit=openclaw-memory-index.service

[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/openclaw-server-backup.service <<'EOF'
[Unit]
Description=Create OpenClaw server backup

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/openclaw-server-backup.sh
EOF

cat > /etc/systemd/system/openclaw-server-backup.timer <<'EOF'
[Unit]
Description=Create an OpenClaw server backup every Sunday

[Timer]
OnCalendar=Sun *-*-* 04:20:00
RandomizedDelaySec=20min
Persistent=true
Unit=openclaw-server-backup.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now openclaw-health-monitor.timer openclaw-memory-index.timer openclaw-server-backup.timer
systemctl start openclaw-health-monitor.service
openclaw memory index --agent main

echo "已完成："
echo "- VPS 监控：每 5 分钟，仅异常与恢复时微信告警；不自动重启服务。"
echo "- 长期记忆：每 6 小时增量索引。"
echo "- VPS 备份：每周日凌晨执行，本机与已配置的 OneDrive 各保留最近 4 份。"
