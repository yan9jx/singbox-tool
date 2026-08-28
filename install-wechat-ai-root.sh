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

printf '\n[1/9] Installing system prerequisites...\n'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl git

printf '\n[2/9] Checking swap...\n'
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

printf '\n[3/9] Downloading the official OpenClaw installer...\n'
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

printf '\n[4/9] Installing the official DeepSeek provider...\n'
openclaw plugins install @openclaw/deepseek-provider

printf '\n[5/9] Starting interactive DeepSeek onboarding...\n'
printf 'Enter the DeepSeek API key only at the OpenClaw prompt. Do not paste it into chat.\n'
openclaw onboard --auth-choice deepseek-api-key --skip-daemon --skip-health --skip-ui

printf '\n[6/9] Applying conservative root-host security defaults...\n'
openclaw config set gateway.bind loopback
openclaw exec-policy preset deny-all

if [[ "$(ps -p 1 -o comm=)" != "systemd" ]]; then
  printf 'This root installer requires systemd as PID 1 for persistent Gateway startup.\n' >&2
  exit 1
fi

openclaw_bin="$(command -v openclaw)"
if [[ "$openclaw_bin" != /* ]]; then
  printf 'Cannot determine an absolute path for the OpenClaw command.\n' >&2
  exit 1
fi

tee /etc/systemd/system/openclaw-gateway.service >/dev/null <<EOF
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target
StartLimitBurst=5
StartLimitIntervalSec=60

[Service]
Type=simple
User=root
Group=root
Environment=HOME=/root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WorkingDirectory=/root
ExecStart=$openclaw_bin gateway --port 18789
Restart=always
RestartSec=5
RestartPreventExitStatus=78
TimeoutStopSec=30
TimeoutStartSec=30
SuccessExitStatus=0 143
OOMPolicy=continue
KillMode=control-group

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable openclaw-gateway.service

printf '\n[7/9] Installing Tencent official WeChat plugin...\n'
if openclaw plugins inspect openclaw-weixin >/dev/null 2>&1; then
  printf 'Tencent official WeChat plugin is already installed; keeping the existing copy.\n'
else
  openclaw plugins install @tencent-weixin/openclaw-weixin
fi
openclaw config set plugins.entries.openclaw-weixin.enabled true

printf '\n[8/9] Starting the root system Gateway service...\n'
systemctl restart openclaw-gateway.service
sleep 3
if ! systemctl is-active --quiet openclaw-gateway.service; then
  systemctl status openclaw-gateway.service --no-pager -l >&2 || true
  printf 'Gateway service did not become active. Check: journalctl -u openclaw-gateway.service -n 120 --no-pager\n' >&2
  exit 1
fi

printf '\n[9/9] Connecting the official WeChat channel...\n'
printf '\nA QR code will be displayed. Scan it with WeChat and confirm on your phone.\n'
openclaw channels login --channel openclaw-weixin

printf '\nRestarting and verifying the root system Gateway service...\n'
systemctl restart openclaw-gateway.service
sleep 3
if ! systemctl is-active --quiet openclaw-gateway.service; then
  systemctl status openclaw-gateway.service --no-pager -l >&2 || true
  printf 'Gateway service stopped after WeChat login. Check: journalctl -u openclaw-gateway.service -n 120 --no-pager\n' >&2
  exit 1
fi

printf '\nInstallation completed.\n'
printf 'OpenClaw version: '
openclaw --version
printf '\nUseful commands:\n'
printf '  systemctl status openclaw-gateway.service --no-pager\n'
printf '  journalctl -u openclaw-gateway.service -f\n'
printf '  openclaw models list --provider deepseek\n'
printf '  openclaw channels login --channel openclaw-weixin\n'
printf '\nHost command execution is disabled because the Gateway runs as root.\n'
printf 'The Control UI remains bound to 127.0.0.1; use an SSH tunnel for access.\n'
