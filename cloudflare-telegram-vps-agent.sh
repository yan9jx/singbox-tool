#!/usr/bin/env bash
set -euo pipefail

VERSION="1.0.0"
APP="/usr/local/lib/ejectors-telegram-vps-agent.py"
CONF="/etc/ejectors-telegram-vps-agent.json"
STATE="/var/lib/ejectors-telegram-vps-agent-state.json"
SERVICE="/etc/systemd/system/ejectors-telegram-vps-agent.service"
MODE_FILE="/var/lib/ejectors-telegram-webhook-active"
BRIEF_MODE="/opt/universe-vps-manager/state/daily_brief_mode"
BRIEF_BACKUP="/var/lib/ejectors-telegram-local-brief-mode.backup"
OLD_BOT_SERVICE="universe-vps-manager-bot.service"

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "请先切换 root：sudo -i"
    exit 1
  fi
}

install_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y python3 iproute2 procps util-linux >/dev/null 2>&1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y python3 iproute procps-ng util-linux >/dev/null 2>&1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y python3 iproute procps-ng util-linux >/dev/null 2>&1
  fi
  command -v python3 >/dev/null 2>&1 || { echo "缺少 python3。"; exit 1; }
}

read_existing() {
  local key="$1"
  [ -f "$CONF" ] || return 0
  python3 - "$CONF" "$key" <<'PY'
import json, sys
try:
    print(str(json.load(open(sys.argv[1], encoding="utf-8")).get(sys.argv[2], "")))
except Exception:
    pass
PY
}

manager_default() {
  local key="$1"
  [ -f /opt/universe-vps-manager/config.json ] || return 0
  python3 - "$key" <<'PY'
import json, sys
try:
    print(str(json.load(open("/opt/universe-vps-manager/config.json", encoding="utf-8")).get(sys.argv[1], "")))
except Exception:
    pass
PY
}

write_config() {
  local old_url old_node old_name input default_name
  old_url="$(read_existing worker_url)"
  old_node="$(read_existing node_id)"
  old_name="$(read_existing name)"
  default_name="${old_name:-$(manager_default server_name)}"
  default_name="${default_name:-$(hostname)}"

  echo "Cloudflare Telegram VPS Agent $VERSION"
  echo "此安装只新增独立上报代理，不会修改现有网页、监控 cron 或代理节点。"
  read -r -p "新 Telegram Worker 地址${old_url:+ [$old_url]}: " input
  WORKER_URL="${input:-$old_url}"
  WORKER_URL="${WORKER_URL%/}"
  [[ "$WORKER_URL" =~ ^https://[^[:space:]]+$ ]] || { echo "Worker 地址必须是 HTTPS。"; exit 1; }

  read -r -p "节点 ID${old_node:+ [$old_node]}: " input
  NODE_ID="${input:-$old_node}"
  [[ "$NODE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || { echo "节点 ID 格式错误。"; exit 1; }

  read -r -p "节点名称 [$default_name]: " input
  NODE_NAME="${input:-$default_name}"
  [ -n "$NODE_NAME" ] || { echo "节点名称不能为空。"; exit 1; }

  local old_secret manager_token
  old_secret="$(read_existing agent_secret)"
  if [ -n "$old_secret" ]; then
    read -r -s -p "VPS Agent Secret [回车保留现有值]: " AGENT_SECRET; echo
    AGENT_SECRET="${AGENT_SECRET:-$old_secret}"
  else
    manager_token="$(manager_default bot_token)"
    if [ -n "$manager_token" ]; then
      AGENT_SECRET="$(python3 - "$manager_token" <<'PY'
import hashlib, hmac, sys
print(hmac.new(sys.argv[1].encode(), b"ejectors-vps-agent-v1", hashlib.sha256).hexdigest())
PY
)"
      echo "已从现有 Bot Token 安全派生 VPS Agent Secret，无需再次输入。"
    else
      read -r -s -p "VPS Agent Secret（至少 32 位，输入不显示）: " AGENT_SECRET; echo
    fi
  fi
  [ "${#AGENT_SECRET}" -ge 32 ] || { echo "VPS Agent Secret 至少需要 32 个字符。"; exit 1; }

  export WORKER_URL NODE_ID NODE_NAME AGENT_SECRET CONF
  python3 - <<'PY'
import json, os, pathlib
path = pathlib.Path(os.environ["CONF"])
tmp = path.with_suffix(".tmp")
data = {
    "worker_url": os.environ["WORKER_URL"],
    "node_id": os.environ["NODE_ID"],
    "name": os.environ["NODE_NAME"],
    "agent_secret": os.environ["AGENT_SECRET"],
}
tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
tmp.chmod(0o600)
tmp.replace(path)
PY
  unset AGENT_SECRET
  chmod 600 "$CONF"
}

write_agent() {
  cat > "$APP" <<'PYAGENT'
#!/usr/bin/env python3
import hashlib
import hmac
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

VERSION = "1.0.0"
CONF_PATH = Path("/etc/ejectors-telegram-vps-agent.json")
STATE_PATH = Path("/var/lib/ejectors-telegram-vps-agent-state.json")
MANAGER_CONFIG = Path("/opt/universe-vps-manager/config.json")
MANAGER_APP = Path("/opt/universe-vps-manager/vps_manager.py")
MAX_OUTPUT = 12000
ALLOWED_ACTIONS = {"refresh", "clean", "pause10", "resume", "restart_node", "restart_proxy", "reboot"}


def load_json(path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default


def save_json(path, value, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def run(args, timeout=10):
    try:
        proc = subprocess.run(args, text=True, capture_output=True, timeout=timeout, check=False)
        return proc.returncode, (proc.stdout or "").strip(), (proc.stderr or "").strip()
    except subprocess.TimeoutExpired:
        return 124, "", "执行超时"
    except Exception as exc:
        return 1, "", str(exc)


def redact(text):
    value = str(text or "")
    value = re.sub(r"\bsk-[A-Za-z0-9_-]{10,}\b", "[已隐藏 API Key]", value)
    value = re.sub(r"\b\d{6,12}:[A-Za-z0-9_-]{20,}\b", "[已隐藏 Bot Token]", value)
    value = re.sub(r"(?i)(api[_ -]?key|token|password|passwd|secret)\s*[:=]\s*\S+", r"\1=[已隐藏]", value)
    value = re.sub(r"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----", "[已隐藏私钥]", value)
    return value[:MAX_OUTPUT]


def mem_info():
    values = {}
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            key, raw = line.split(":", 1)
            values[key] = int(raw.strip().split()[0]) * 1024
    except Exception:
        pass
    total = values.get("MemTotal", 0)
    available = values.get("MemAvailable", 0)
    swap_total = values.get("SwapTotal", 0)
    swap_free = values.get("SwapFree", 0)
    return {
        "total_mb": round(total / 1048576),
        "used_mb": round((total - available) / 1048576),
        "available_mb": round(available / 1048576),
        "used_pct": round((total - available) * 100 / total, 1) if total else 0,
        "swap_used_pct": round((swap_total - swap_free) * 100 / swap_total, 1) if swap_total else 0,
    }


def service_states(manager_cfg):
    names = [manager_cfg.get("service_name", ""), "xray", "sing-box", "shared-caddy", "caddy", "nginx", "filebrowser"]
    result = {}
    for name in dict.fromkeys(str(item).strip() for item in names if item):
        if not re.fullmatch(r"[A-Za-z0-9_.@-]+", name):
            continue
        exists, _, _ = run(["systemctl", "cat", f"{name}.service"], 3)
        if exists != 0:
            continue
        _, state, _ = run(["systemctl", "is-active", name], 3)
        result[name] = state or "unknown"
    return result


def manager_status():
    if MANAGER_APP.exists():
        code, out, err = run([sys.executable, str(MANAGER_APP), "status"], 20)
        if code == 0 and out:
            return redact(out)
        return redact(err or "Universe VPS Manager 状态读取失败")
    return "未安装 Universe VPS Manager；显示基础系统状态。"


def collect_snapshot():
    manager_cfg = load_json(MANAGER_CONFIG, {})
    disk = shutil.disk_usage("/")
    try:
        uptime = int(float(Path("/proc/uptime").read_text().split()[0]))
    except Exception:
        uptime = 0
    _, ports, _ = run(["ss", "-H", "-lntp"], 5)
    _, failed, _ = run(["systemctl", "--failed", "--no-legend", "--plain"], 5)
    _, top_cpu, _ = run(["ps", "-eo", "pid,comm,%cpu,%mem,rss", "--sort=-%cpu"], 5)
    _, warnings, _ = run(["journalctl", "-p", "warning", "-n", "30", "--no-pager"], 8)
    _, ssh_failures, _ = run([
        "journalctl", "-u", "ssh", "-u", "sshd", "--since", "24 hours ago", "--no-pager", "-n", "100"
    ], 8)
    ssh_lines = [line for line in ssh_failures.splitlines() if re.search(r"failed|invalid user|authentication failure", line, re.I)]
    try:
        load1, load5, load15 = os.getloadavg()
    except OSError:
        load1 = load5 = load15 = 0.0
    diagnostics = {
        "load": {"1m": round(load1, 2), "5m": round(load5, 2), "15m": round(load15, 2)},
        "memory": mem_info(),
        "disk": {
            "used_gb": round(disk.used / 1073741824, 2),
            "total_gb": round(disk.total / 1073741824, 2),
            "used_pct": round(disk.used * 100 / disk.total, 1) if disk.total else 0,
        },
        "uptime_seconds": uptime,
        "services": service_states(manager_cfg),
        "failed_units": redact(failed),
        "listening_ports": redact("\n".join(ports.splitlines()[:60])),
        "top_cpu": redact("\n".join(top_cpu.splitlines()[:12])),
        "recent_warnings": redact(warnings),
        "ssh_failures_24h": redact("\n".join(ssh_lines[-30:])),
    }
    return {"status_text": manager_status(), "diagnostics": diagnostics}


def update_pause(minutes):
    cfg = load_json(MANAGER_CONFIG, {})
    if not isinstance(cfg, dict) or not cfg:
        return False, "未找到 Universe VPS Manager 配置。"
    cfg["pause_until"] = int(time.time()) + minutes * 60 if minutes else 0
    save_json(MANAGER_CONFIG, cfg)
    return True, "已暂停告警 10 分钟。" if minutes else "已恢复告警。"


def valid_service(name):
    return name if re.fullmatch(r"[A-Za-z0-9_.@-]+", str(name or "")) else ""


def execute(command):
    action = str(command.get("action", ""))
    if action not in ALLOWED_ACTIONS:
        return False, "拒绝了不在白名单中的操作。"
    if int(command.get("expires_at", 0)) < int(time.time() * 1000):
        return False, "操作已过期，未执行。"
    if action == "refresh":
        return True, "本机状态已刷新。"
    if action == "clean":
        if not MANAGER_APP.exists():
            return False, "未安装 Universe VPS Manager。"
        code, out, err = run([sys.executable, str(MANAGER_APP), "clean"], 30)
        return code == 0, redact(out or err or ("缓存清理完成。" if code == 0 else "缓存清理失败。"))
    if action == "pause10":
        return update_pause(10)
    if action == "resume":
        return update_pause(0)
    if action == "restart_node":
        cfg = load_json(MANAGER_CONFIG, {})
        service = valid_service(cfg.get("service_name", "sing-box"))
        if not service:
            return False, "节点服务名无效，拒绝执行。"
        code, out, err = run(["systemctl", "restart", service], 30)
        return code == 0, redact(out or err or (f"{service} 重启成功。" if code == 0 else f"{service} 重启失败。"))
    if action == "restart_proxy":
        for service in ("shared-caddy", "caddy", "nginx", "filebrowser-nginx"):
            exists, _, _ = run(["systemctl", "cat", f"{service}.service"], 3)
            if exists == 0:
                code, out, err = run(["systemctl", "restart", service], 30)
                return code == 0, redact(out or err or (f"{service} 重启成功。" if code == 0 else f"{service} 重启失败。"))
        return False, "未检测到受支持的反向代理服务。"
    if action == "reboot":
        code, out, err = run([
            "systemd-run", "--unit=ejectors-telegram-delayed-reboot", "--on-active=3s", "/usr/bin/systemctl", "reboot"
        ], 10)
        return code == 0, redact(out or err or ("VPS 将在 3 秒后重启。" if code == 0 else "VPS 重启任务创建失败。"))
    return False, "无效操作。"


def signed_sync(conf, payload):
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    timestamp = str(int(time.time() * 1000))
    signature = hmac.new(conf["agent_secret"].encode(), timestamp.encode() + b"." + body, hashlib.sha256).hexdigest()
    request = urllib.request.Request(
        conf["worker_url"] + "/api/agent/sync",
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "X-Agent-Id": conf["node_id"],
            "X-Agent-Timestamp": timestamp,
            "X-Agent-Signature": signature,
            "User-Agent": "ejectors-telegram-vps-agent/" + VERSION,
        },
    )
    with urllib.request.urlopen(request, timeout=25) as response:
        return json.loads(response.read().decode("utf-8"))


def main():
    conf = load_json(CONF_PATH, {})
    required = ("worker_url", "node_id", "name", "agent_secret")
    if not isinstance(conf, dict) or any(not str(conf.get(key, "")) for key in required):
        raise SystemExit("Agent 配置不完整。")
    state = load_json(STATE_PATH, {"results": [], "completed": [], "snapshot": {}})
    state.setdefault("results", [])
    state.setdefault("completed", [])
    state.setdefault("snapshot", {})
    last_collect = 0.0
    failures = 0
    while True:
        try:
            if time.time() - last_collect >= 30 or not state["snapshot"]:
                state["snapshot"] = collect_snapshot()
                last_collect = time.time()
            payload = {
                "version": VERSION,
                "node_id": conf["node_id"],
                "name": conf["name"],
                "reported_at": int(time.time() * 1000),
                "snapshot": state["snapshot"],
                "command_results": state["results"][-20:],
            }
            response = signed_sync(conf, payload)
            completed = set(state["completed"][-100:])
            executed = False
            for command in response.get("commands", [])[:5]:
                command_id = str(command.get("command_id", ""))
                if not re.fullmatch(r"[0-9a-f-]{36}", command_id, re.I) or command_id in completed:
                    continue
                ok, output = execute(command)
                state["results"].append({
                    "command_id": command_id,
                    "ok": bool(ok),
                    "output": redact(output),
                    "finished_at": int(time.time() * 1000),
                })
                state["completed"].append(command_id)
                completed.add(command_id)
                executed = True
            state["results"] = state["results"][-20:]
            state["completed"] = state["completed"][-100:]
            if executed:
                state["snapshot"] = collect_snapshot()
                last_collect = time.time()
            save_json(STATE_PATH, state)
            failures = 0
            time.sleep(1 if executed else 10)
        except urllib.error.HTTPError as exc:
            print(time.strftime("%F %T"), "sync HTTP error:", exc.code, flush=True)
            failures += 1
            time.sleep(min(30, 2 ** min(failures, 5)))
        except Exception as exc:
            print(time.strftime("%F %T"), "sync error:", redact(exc), flush=True)
            failures += 1
            time.sleep(min(30, 2 ** min(failures, 5)))


if __name__ == "__main__":
    main()
PYAGENT
  chmod 755 "$APP"
}

write_service() {
  cat > "$SERVICE" <<EOF
[Unit]
Description=Ejectors Cloudflare Telegram VPS Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $APP
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=/var/lib /opt/universe-vps-manager /run /tmp

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now ejectors-telegram-vps-agent.service
}

install_agent() {
  need_root
  install_deps
  write_config
  write_agent
  write_service
  sleep 2
  systemctl --no-pager --full status ejectors-telegram-vps-agent.service || true
  echo
  echo "✅ Cloudflare VPS Agent 已安装。"
  echo "现有 Telegram 轮询服务尚未停止，监控 cron 和原功能均未改动。"
  echo "待新 Worker 与 Webhook 验收完成后，再运行：bash $0 activate"
}

activate_webhook_mode() {
  need_root
  systemctl is-active --quiet ejectors-telegram-vps-agent.service || { echo "新 Agent 未运行，拒绝切换。"; exit 1; }
  if ! python3 - <<'PY'
import hashlib, hmac, json, urllib.parse, urllib.request
agent = json.load(open("/etc/ejectors-telegram-vps-agent.json", encoding="utf-8"))
manager = json.load(open("/opt/universe-vps-manager/config.json", encoding="utf-8"))
token = str(manager.get("bot_token", "")).strip()
if not token:
    raise SystemExit("Bot Token 未配置")
secret = hmac.new(token.encode(), b"ejectors-telegram-webhook-v1", hashlib.sha256).hexdigest()
health_url = str(agent["worker_url"]).rstrip("/") + "/health"
with urllib.request.urlopen(health_url, timeout=15) as response:
    health = json.loads(response.read().decode())
if not health.get("ok") or health.get("nodes", {}).get("online_nodes", 0) < 1:
    raise SystemExit("Cloudflare Worker 尚未看到在线 VPS Agent")
body = urllib.parse.urlencode({
    "url": str(agent["worker_url"]).rstrip("/") + "/telegram/webhook",
    "secret_token": secret,
    "drop_pending_updates": "false",
    "allowed_updates": json.dumps(["message", "callback_query"]),
}).encode()
with urllib.request.urlopen(f"https://api.telegram.org/bot{token}/setWebhook", data=body, timeout=15) as response:
    value = json.loads(response.read().decode())
if not value.get("ok"):
    raise SystemExit("Telegram setWebhook 失败")
PY
  then
    echo "新 Worker/Agent/Webhook 预检失败，没有停止旧 Telegram 轮询。"
    exit 1
  fi
  systemctl stop "$OLD_BOT_SERVICE" 2>/dev/null || true
  systemctl disable "$OLD_BOT_SERVICE" >/dev/null 2>&1 || true
  if [ -f "$BRIEF_MODE" ]; then
    cp -a "$BRIEF_MODE" "$BRIEF_BACKUP"
    printf '%s\n' off > "$BRIEF_MODE"
  fi
  mkdir -p "$(dirname "$MODE_FILE")"
  printf '%s\n' "$(date -Is)" > "$MODE_FILE"
  chmod 600 "$MODE_FILE"
  echo "✅ 已切换为 Cloudflare Webhook 模式。"
  echo "只停止了旧 Telegram getUpdates 服务；/etc/cron.d/universe-vps-manager 监控、告警和原节点服务保持不变。"
}

deactivate_webhook_mode() {
  need_root
  if ! python3 - <<'PY'
import json, urllib.parse, urllib.request
cfg = json.load(open("/opt/universe-vps-manager/config.json", encoding="utf-8"))
token = str(cfg.get("bot_token", "")).strip()
if not token:
    raise SystemExit("Bot Token 未配置")
body = urllib.parse.urlencode({"drop_pending_updates": "false"}).encode()
with urllib.request.urlopen(f"https://api.telegram.org/bot{token}/deleteWebhook", data=body, timeout=15) as response:
    value = json.loads(response.read().decode())
if not value.get("ok"):
    raise SystemExit("Telegram deleteWebhook 失败")
PY
  then
    echo "Telegram Webhook 删除失败，为避免与 getUpdates 冲突，没有恢复本地轮询。"
    exit 1
  fi
  rm -f "$MODE_FILE"
  if [ -f "$BRIEF_BACKUP" ]; then
    cp -a "$BRIEF_BACKUP" "$BRIEF_MODE"
    rm -f "$BRIEF_BACKUP"
  fi
  systemctl enable --now "$OLD_BOT_SERVICE"
  echo "✅ 已恢复 VPS 本地 Telegram 轮询模式。"
}

show_status() {
  need_root
  systemctl --no-pager --full status ejectors-telegram-vps-agent.service || true
  echo
  if [ -f "$MODE_FILE" ]; then echo "Telegram 模式：Cloudflare Webhook"; else echo "Telegram 模式：本地轮询（尚未切换）"; fi
}

uninstall_agent() {
  need_root
  if [ -f "$MODE_FILE" ]; then
    echo "当前仍是 Cloudflare Webhook 模式。请先运行 deactivate 安全恢复本地轮询，再卸载。"
    exit 1
  fi
  systemctl disable --now ejectors-telegram-vps-agent.service 2>/dev/null || true
  rm -f "$SERVICE" "$APP" "$CONF" "$STATE" "$MODE_FILE" "$BRIEF_BACKUP"
  systemctl daemon-reload
  echo "已移除 Cloudflare Telegram VPS Agent；原 Universe VPS Manager 文件未删除。"
}

case "${1:-install}" in
  install|update) install_agent ;;
  activate) activate_webhook_mode ;;
  deactivate) deactivate_webhook_mode ;;
  status) show_status ;;
  uninstall) uninstall_agent ;;
  *) echo "用法：$0 [install|update|activate|deactivate|status|uninstall]"; exit 1 ;;
esac
