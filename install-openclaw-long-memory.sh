#!/usr/bin/env bash
set -Eeuo pipefail

# Upgrade OpenClaw safely, then configure persistent hybrid long-term memory:
# SiliconFlow BAAI/bge-m3 embeddings + built-in SQLite keyword search.
# The script intentionally leaves WeChat, SearXNG, model providers, and
# existing conversations intact.

umask 077

config_changed=0
config_backup=""

restore_config() {
  if [[ "$config_changed" -eq 1 && -n "$config_backup" && -f "$config_backup" ]]; then
    printf '\nRestoring the pre-memory OpenClaw configuration...\n' >&2
    cp -- "$config_backup" /root/.openclaw/openclaw.json
    systemctl restart openclaw-gateway.service || true
  fi
}

on_error() {
  local exit_code=$?
  printf '\nLong-memory setup stopped at line %s (exit code %s).\n' "${BASH_LINENO[0]}" "$exit_code" >&2
  restore_config
  printf 'Your pre-upgrade backup was kept. Do not share its path or contents: it can contain API credentials.\n' >&2
  exit "$exit_code"
}
trap on_error ERR

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  printf 'Run this script as root.\n' >&2
  exit 1
fi

export HOME=/root
export PATH="/root/.local/bin:/root/.npm-global/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
hash -r

if ! command -v openclaw >/dev/null 2>&1; then
  printf 'OpenClaw is not installed.\n' >&2
  exit 1
fi
if [[ ! -f /root/.openclaw/openclaw.json ]]; then
  printf 'OpenClaw configuration is missing at /root/.openclaw/openclaw.json.\n' >&2
  exit 1
fi
if [[ "$(ps -p 1 -o comm=)" != "systemd" ]]; then
  printf 'This script requires systemd because this bot uses openclaw-gateway.service.\n' >&2
  exit 1
fi
if ! systemctl is-active --quiet openclaw-gateway.service; then
  printf 'openclaw-gateway.service is not active. Repair the bot before upgrading it.\n' >&2
  exit 1
fi

backup_dir=/root/.openclaw/backups
stamp="$(date +%Y%m%d%H%M%S)"
mkdir -p "$backup_dir"
chmod 700 "$backup_dir"

backup_items=(openclaw.json)
for item in agents/main extensions/wechat-ai-provider-admin; do
  if [[ -e "/root/.openclaw/$item" ]]; then
    backup_items+=("$item")
  fi
done
full_backup="$backup_dir/openclaw-before-long-memory-$stamp.tgz"
printf '\n[1/7] Backing up OpenClaw configuration, conversations, and custom plugin...\n'
tar -C /root/.openclaw -czf "$full_backup" "${backup_items[@]}"
chmod 600 "$full_backup"
printf 'Backup created: %s\n' "$full_backup"

printf '\n[2/7] Current OpenClaw version:\n'
openclaw --version
printf '\nThis upgrades OpenClaw to the current stable release. Your configuration, WeChat login,\n'
printf 'SearXNG, API providers, and sessions are preserved; the backup above is for rollback.\n'
read -r -p 'Type UPGRADE to continue: ' confirmation
if [[ "$confirmation" != "UPGRADE" ]]; then
  printf 'Cancelled before the OpenClaw upgrade. Nothing changed.\n'
  exit 0
fi

printf '\n[3/7] Previewing the official OpenClaw update...\n'
openclaw update --dry-run
printf '\n[4/7] Updating OpenClaw and running its built-in repair checks...\n'
openclaw update --yes
hash -r
if ! systemctl is-active --quiet openclaw-gateway.service; then
  printf 'OpenClaw update completed but the Gateway is not active. The pre-upgrade backup is at %s.\n' "$full_backup" >&2
  exit 1
fi
printf 'Updated version: '
openclaw --version

config_backup="$backup_dir/openclaw.json.before-long-memory.$stamp"
cp -- /root/.openclaw/openclaw.json "$config_backup"
chmod 600 "$config_backup"

printf '\n[5/7] Configuring SiliconFlow semantic retrieval...\n'
printf 'Create an API key at SiliconFlow first. The free BAAI/bge-m3 embedding model is used.\n'
IFS= read -r -s -p 'Paste SiliconFlow API key (input is hidden): ' siliconflow_api_key
printf '\n'
if [[ -z "$siliconflow_api_key" ]]; then
  printf 'No SiliconFlow API key was provided.\n' >&2
  exit 1
fi

# OpenClaw 2026.7.x uses the legacy, per-agent schema. Later releases moved
# this to top-level memory.search. Detect the installed schema without
# replacing any config subtree: config set only changes individual leaves.
config_changed=1
if openclaw config set agents.defaults.memorySearch.enabled true; then
  memory_schema=legacy
  printf 'Using the OpenClaw 2026.7-compatible memorySearch schema.\n'
  openclaw config set agents.defaults.memorySearch.provider openai
  openclaw config set agents.defaults.memorySearch.model BAAI/bge-m3
  openclaw config set agents.defaults.memorySearch.fallback none
  openclaw config set agents.defaults.memorySearch.remote.baseUrl https://api.siliconflow.cn/v1
  openclaw config set agents.defaults.memorySearch.remote.apiKey "$siliconflow_api_key"
  openclaw config set agents.defaults.memorySearch.remote.batch.enabled false
  openclaw config set agents.defaults.memorySearch.experimental.sessionMemory true
  openclaw config set agents.defaults.memorySearch.sources '["memory","sessions"]' --strict-json
else
  memory_schema=current
  printf 'Using the current memory.search schema.\n'
  openclaw config set memory.search.enabled true
  openclaw config set memory.search.provider openai-compatible
  openclaw config set memory.search.model BAAI/bge-m3
  openclaw config set memory.search.fallback none
  openclaw config set memory.search.remote.baseUrl https://api.siliconflow.cn/v1
  openclaw config set memory.search.remote.apiKey "$siliconflow_api_key"
  openclaw config set memory.search.rememberAcrossConversations true
  openclaw config set memory.search.sources '["memory","sessions"]' --strict-json
  openclaw config set experimental.sessionMemory true
fi
unset siliconflow_api_key

workspace_dir=/root/.openclaw/workspace
install -d -m 700 "$workspace_dir/memory"
if [[ ! -f "$workspace_dir/MEMORY.md" ]]; then
  cat > "$workspace_dir/MEMORY.md" <<'EOF'
# 长期记忆

这里保存经确认、在未来对话中仍有价值的事实、决定和偏好。
EOF
  chmod 600 "$workspace_dir/MEMORY.md"
fi
if [[ ! -f "$workspace_dir/USER.md" ]]; then
  cat > "$workspace_dir/USER.md" <<'EOF'
# 用户偏好

以中文回复；在涉及外部操作、费用或不可逆修改前先说明影响并征得确认。
EOF
  chmod 600 "$workspace_dir/USER.md"
fi

agent_instructions="$workspace_dir/AGENTS.md"
memory_marker='<!-- openclaw-long-memory-policy -->'
if ! grep -Fqx "$memory_marker" "$agent_instructions" 2>/dev/null; then
  cat >> "$agent_instructions" <<'EOF'

<!-- openclaw-long-memory-policy -->
## 长期记忆规则

- 当所有者明确说“记住”“长期记忆”“以后按这个办”时，把简洁、已确认的内容写入 `MEMORY.md` 或当天的 `memory/YYYY-MM-DD.md`。
- 只保存稳定偏好、关键决定、重要事实和带条件的提醒；不要把整段聊天原样存入长期记忆。
- 写入成功后才可回复“已记住”。用户说“忘记”或信息已过期时，要更新或删除对应记录。
EOF
  chmod 600 "$agent_instructions"
fi

printf '\n[6/7] Rebuilding the long-memory index (existing private sessions are included)...\n'
openclaw memory index --force --agent main

printf '\n[7/7] Restarting and verifying the Gateway...\n'
systemctl restart openclaw-gateway.service
sleep 5
if ! systemctl is-active --quiet openclaw-gateway.service; then
  systemctl status openclaw-gateway.service --no-pager -l >&2 || true
  printf 'Gateway did not become active. The pre-memory configuration was restored.\n' >&2
  exit 1
fi
openclaw memory status --deep --agent main || openclaw memory status --deep

config_changed=0
printf '\nLong-term memory is ready.\n'
printf 'Embedding: SiliconFlow BAAI/bge-m3 (semantic) + SQLite FTS (keywords)\n'
printf 'Test in WeChat: 记住：我的银行提醒要在每月 5 日处理。\n'
printf 'Backup before upgrade: %s\n' "$full_backup"
printf 'Config-only rollback copy: %s\n' "$config_backup"
