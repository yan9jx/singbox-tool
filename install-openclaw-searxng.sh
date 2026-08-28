#!/usr/bin/env bash
set -Eeuo pipefail

# Ubuntu 24.04 root-only installer for a local SearXNG instance used by
# OpenClaw. It does not expose a public port and does not modify Caddy/443.

umask 077

config_changed=0
config_backup=""

restore_openclaw_config() {
  if [[ "$config_changed" -eq 1 && -n "$config_backup" && -f "$config_backup" ]]; then
    printf '\nRestoring the OpenClaw configuration from %s ...\n' "$config_backup" >&2
    cp -- "$config_backup" /root/.openclaw/openclaw.json
    systemctl restart openclaw-gateway.service || true
  fi
}

on_error() {
  local exit_code=$?
  printf '\nInstallation stopped at line %s (exit code %s).\n' "${BASH_LINENO[0]}" "$exit_code" >&2
  restore_openclaw_config
  printf 'The existing WeChat bot configuration was left unchanged or restored.\n' >&2
  exit "$exit_code"
}
trap on_error ERR

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  printf 'Run this script as root.\n' >&2
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  printf 'Cannot read /etc/os-release. This installer supports Ubuntu 24.04.\n' >&2
  exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release
if [[ ${ID:-} != "ubuntu" || ${VERSION_ID:-} != "24.04" ]]; then
  printf 'Unsupported system: %s %s. Expected Ubuntu 24.04.\n' "${ID:-unknown}" "${VERSION_ID:-unknown}" >&2
  exit 1
fi

export HOME=/root
export PATH="/root/.local/bin:/root/.npm-global/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
hash -r

if ! command -v openclaw >/dev/null 2>&1; then
  printf 'OpenClaw is not installed. Install and verify the WeChat bot first.\n' >&2
  exit 1
fi

if ! systemctl is-active --quiet openclaw-gateway.service; then
  printf 'openclaw-gateway.service is not active. Repair the bot before changing its search provider.\n' >&2
  exit 1
fi

printf '\n[1/6] Installing Docker prerequisites...\n'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl docker.io openssl
systemctl enable --now docker.service

printf '\n[2/6] Preparing the local SearXNG configuration...\n'
base_dir=/opt/openclaw-searxng
config_dir="$base_dir/config"
cache_dir="$base_dir/cache"
settings_file="$config_dir/settings.yml"
mkdir -p "$config_dir" "$cache_dir"
chmod 700 "$base_dir" "$config_dir" "$cache_dir"

if [[ ! -e "$settings_file" ]]; then
  secret_key="$(openssl rand -hex 32)"
  cat > "$settings_file" <<EOF
use_default_settings: true
general:
  instance_name: "OpenClaw local search"
search:
  formats:
    - html
    - json
server:
  secret_key: "$secret_key"
  limiter: false
  public_instance: false
  image_proxy: false
EOF
  chmod 600 "$settings_file"
  unset secret_key
  printf 'Created %s with the JSON API enabled.\n' "$settings_file"
else
  if ! grep -Eq '^[[:space:]]*-[[:space:]]+json[[:space:]]*$' "$settings_file"; then
    printf 'Existing %s does not visibly enable the JSON API.\n' "$settings_file" >&2
    printf 'Add json under search.formats, then rerun this installer.\n' >&2
    exit 1
  fi
  printf 'Keeping the existing SearXNG settings file.\n'
fi

printf '\n[3/6] Downloading the official SearXNG image...\n'
docker pull docker.io/searxng/searxng:latest

printf '\n[4/6] Starting SearXNG on 127.0.0.1:8888 only...\n'
if docker container inspect openclaw-searxng >/dev/null 2>&1; then
  existing_port="$(docker port openclaw-searxng 8080/tcp 2>/dev/null || true)"
  if [[ "$existing_port" != "127.0.0.1:8888" ]]; then
    printf 'An existing openclaw-searxng container has an unexpected port mapping: %s\n' "$existing_port" >&2
    printf 'It was not changed. Inspect it with: docker inspect openclaw-searxng\n' >&2
    exit 1
  fi
  docker start openclaw-searxng >/dev/null || true
  docker update --memory=512m --memory-swap=512m --restart=unless-stopped openclaw-searxng >/dev/null
  printf 'Keeping the existing local SearXNG container.\n'
else
  docker run -d \
    --name openclaw-searxng \
    --restart unless-stopped \
    --memory=512m \
    --memory-swap=512m \
    --publish 127.0.0.1:8888:8080 \
    --volume "$config_dir:/etc/searxng" \
    --volume "$cache_dir:/var/cache/searxng" \
    docker.io/searxng/searxng:latest >/dev/null
fi

response_file="$(mktemp /tmp/openclaw-searxng-check.XXXXXX.json)"
cleanup() {
  rm -f -- "$response_file"
}
trap cleanup EXIT

ready=0
for _attempt in $(seq 1 20); do
  if curl --fail --silent --show-error --max-time 15 \
    'http://127.0.0.1:8888/search?q=OpenClaw&format=json' \
    -o "$response_file" && grep -q '"results"' "$response_file"; then
    ready=1
    break
  fi
  sleep 2
done

if [[ "$ready" -ne 1 ]]; then
  printf 'SearXNG did not return a valid local JSON response.\n' >&2
  printf 'Check: docker logs --tail 120 openclaw-searxng\n' >&2
  exit 1
fi

printf '\n[5/6] Installing and configuring the OpenClaw SearXNG provider...\n'
if openclaw plugins inspect searxng >/dev/null 2>&1; then
  printf 'OpenClaw SearXNG plugin is already installed; keeping it.\n'
else
  openclaw plugins install @openclaw/searxng-plugin
fi

config_path=/root/.openclaw/openclaw.json
if [[ ! -f "$config_path" ]]; then
  printf 'OpenClaw configuration not found at %s.\n' "$config_path" >&2
  exit 1
fi
backup_dir=/root/.openclaw/backups
mkdir -p "$backup_dir"
config_backup="$backup_dir/openclaw.json.before-searxng.$(date +%Y%m%d%H%M%S)"
cp -- "$config_path" "$config_backup"
chmod 600 "$config_backup"

openclaw config set plugins.entries.searxng.enabled true
openclaw config set plugins.entries.searxng.config.webSearch.baseUrl http://127.0.0.1:8888
openclaw config set plugins.entries.searxng.config.webSearch.categories general,news
openclaw config set tools.web.search.provider searxng
config_changed=1

printf '\n[6/6] Restarting and verifying the WeChat bot...\n'
systemctl restart openclaw-gateway.service
sleep 4
if ! systemctl is-active --quiet openclaw-gateway.service; then
  printf 'Gateway service did not become active after the provider change.\n' >&2
  printf 'Check: journalctl -u openclaw-gateway.service -n 120 --no-pager\n' >&2
  exit 1
fi

config_changed=0
printf '\nSearXNG is ready and OpenClaw now uses it for web search.\n'
printf 'Local search URL: http://127.0.0.1:8888 (not exposed publicly)\n'
printf 'Container RAM cap: 512 MiB, with swap disabled for this container.\n'
printf '\nUseful commands:\n'
printf '  docker stats --no-stream openclaw-searxng\n'
printf '  docker logs --tail 120 openclaw-searxng\n'
printf '  systemctl status openclaw-gateway.service --no-pager\n'
