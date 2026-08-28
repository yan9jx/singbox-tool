#!/usr/bin/env bash
set -Eeuo pipefail

# Root-only installer for Ubuntu 24.04:
# OpenClaw + official DeepSeek provider + Tencent WeChat channel plugin.
# API keys are entered interactively and are never stored in this script.

umask 077

on_error() {
  local exit_code=$?
  printf '\nInstallation stopped at line %s (exit code %s).\n' "${BASH_LINENO[0]}" "$exit_code" >&2
  printf 'Copy the error output above when asking for help. Do not include API keys or tokens.\n' >&2
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

case "$(uname -m)" in
  x86_64|aarch64) ;;
  *)
    printf 'Unsupported architecture: %s\n' "$(uname -m)" >&2
    exit 1
    ;;
esac

printf '\n[1/8] Installing system prerequisites...\n'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl git

printf '\n[2/8] Checking swap...\n'
if [[ -z "$(swapon --show=NAME --noheadings 2>/dev/null)" ]]; then
  if [[ -e /swapfile ]]; then
    printf '/swapfile already exists but is not active; leaving it unchanged.\n' >&2
    printf 'Remove or repair the existing /swapfile, then rerun this installer.\n' >&2
    exit 1
  fi

  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  if ! grep -Eq '^[[:space:]]*/swapfile[[:space:]]' /etc/fstab; then
    printf '%s\n' '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
  printf 'Created and enabled a 2 GiB swap file.\n'
else
  printf 'Active swap already exists; no changes made.\n'
fi

printf '\n[3/8] Downloading the official OpenClaw installer...\n'
installer_path="$(mktemp /tmp/openclaw-install.XXXXXX.sh)"
cleanup() {
  rm -f -- "$installer_path"
}
trap cleanup EXIT
curl -fsSL --proto '=https' --tlsv1.2 \
  https://openclaw.ai/install.sh \
  -o "$installer_path"
chmod 700 "$installer_path"
bash "$installer_path" --no-onboard --verify

export HOME=/root
export PATH="/root/.local/bin:/root/.npm-global/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
hash -r

if ! command -v openclaw >/dev/null 2>&1; then
  printf 'OpenClaw was installed but is not available in PATH.\n' >&2
  printf 'Reconnect over SSH and run: openclaw --version\n' >&2
  exit 1
fi

printf '\n[4/8] Installing the official DeepSeek provider...\n'
openclaw plugins install @openclaw/deepseek-provider

printf '\n[5/8] Starting interactive DeepSeek onboarding...\n'
printf 'Enter the DeepSeek API key only at the OpenClaw prompt. Do not paste it into chat.\n'
openclaw onboard --auth-choice deepseek-api-key --install-daemon

printf '\n[6/8] Applying conservative root-host security defaults...\n'
openclaw config set gateway.bind loopback
openclaw exec-policy preset deny-all
loginctl enable-linger root

printf '\n[7/8] Installing Tencent official WeChat plugin...\n'
openclaw plugins install @tencent-weixin/openclaw-weixin
openclaw config set plugins.entries.openclaw-weixin.enabled true

printf '\nA QR code will be displayed. Scan it with WeChat and confirm on your phone.\n'
openclaw channels login --channel openclaw-weixin

printf '\n[8/8] Restarting and verifying the Gateway...\n'
openclaw gateway restart
openclaw doctor
openclaw gateway status

printf '\nInstallation completed.\n'
printf 'OpenClaw version: '
openclaw --version
printf '\nUseful commands:\n'
printf '  openclaw gateway status\n'
printf '  openclaw logs --follow\n'
printf '  openclaw models list --provider deepseek\n'
printf '  openclaw channels login --channel openclaw-weixin\n'
printf '\nHost command execution is disabled because the Gateway runs as root.\n'
printf 'The Control UI remains bound to 127.0.0.1; use an SSH tunnel for access.\n'
