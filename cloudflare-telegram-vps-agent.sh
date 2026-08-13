#!/usr/bin/env bash
set -euo pipefail

VERSION="1.2.1"
APP="/usr/local/lib/ejectors-telegram-vps-agent.py"
LOCAL_TEST_APP="/usr/local/lib/ejectors-local-speedtest.py"
CONF="/etc/ejectors-telegram-vps-agent.json"
STATE="/var/lib/ejectors-telegram-vps-agent-state.json"
SERVICE="/etc/systemd/system/ejectors-telegram-vps-agent.service"
LOCAL_TEST_SERVICE="/etc/systemd/system/ejectors-local-speedtest.service"
MODE_FILE="/var/lib/ejectors-telegram-webhook-active"
BRIEF_MODE="/opt/universe-vps-manager/state/daily_brief_mode"
BRIEF_BACKUP="/var/lib/ejectors-telegram-local-brief-mode.backup"
OLD_BOT_SERVICE="universe-vps-manager-bot.service"
MANAGER_CRON="/etc/cron.d/universe-vps-manager"
MANAGER_CRON_BACKUP="/var/lib/ejectors-telegram-local-cron.backup"
MANAGER_APP="/opt/universe-vps-manager/vps_manager.py"
MANAGER_APP_BACKUP="/var/lib/ejectors-telegram-local-manager.backup"

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
import ipaddress
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

VERSION = "1.2.1"
CONF_PATH = Path("/etc/ejectors-telegram-vps-agent.json")
STATE_PATH = Path("/var/lib/ejectors-telegram-vps-agent-state.json")
MANAGER_CONFIG = Path("/opt/universe-vps-manager/config.json")
MANAGER_APP = Path("/opt/universe-vps-manager/vps_manager.py")
MAX_OUTPUT = 12000
LOCAL_TEST_STATE = Path("/var/lib/ejectors-local-test.json")
ALLOWED_ACTIONS = {"refresh", "clean", "pause10", "resume", "restart_node", "restart_proxy", "reboot", "setup_local_test", "disable_local_test"}


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


def cpu_percent():
    def sample():
        parts = Path("/proc/stat").read_text().splitlines()[0].split()[1:]
        values = [int(value) for value in parts]
        idle = values[3] + (values[4] if len(values) > 4 else 0)
        return sum(values), idle
    try:
        total1, idle1 = sample()
        time.sleep(0.15)
        total2, idle2 = sample()
        delta = total2 - total1
        return round((delta - (idle2 - idle1)) * 100 / delta, 1) if delta > 0 else 0
    except Exception:
        return 0


def network_info(state):
    _, route, _ = run(["ip", "route", "show", "default"], 3)
    match = re.search(r"\bdev\s+([A-Za-z0-9_.:-]+)", route)
    iface = match.group(1) if match else ""
    try:
        base = Path("/sys/class/net") / iface / "statistics"
        rx = int((base / "rx_bytes").read_text().strip())
        tx = int((base / "tx_bytes").read_text().strip())
    except Exception:
        return {"interface": iface, "rx_mbps": 0, "tx_mbps": 0}
    now = time.time()
    prior = state.get("network_sample", {}) if isinstance(state.get("network_sample"), dict) else {}
    elapsed = now - float(prior.get("time", 0) or 0)
    prior_rx = int(prior.get("rx", rx) or rx)
    prior_tx = int(prior.get("tx", tx) or tx)
    rx_delta = rx - prior_rx if rx >= prior_rx else 0
    tx_delta = tx - prior_tx if tx >= prior_tx else 0
    state["network_sample"] = {"time": now, "rx": rx, "tx": tx, "interface": iface}
    return {
        "interface": iface,
        "rx_mbps": round(rx_delta * 8 / elapsed / 1_000_000, 2) if elapsed > 0 else 0,
        "tx_mbps": round(tx_delta * 8 / elapsed / 1_000_000, 2) if elapsed > 0 else 0,
    }


def service_states(manager_cfg):
    primary = str(manager_cfg.get("service_name", "")).strip()
    names = [primary, "xray", "sing-box", "shared-caddy", "caddy", "nginx", "filebrowser", "filebrowser-nginx"]
    result = {}
    for name in dict.fromkeys(str(item).strip() for item in names if item):
        if not re.fullmatch(r"[A-Za-z0-9_.@-]+", name):
            continue
        exists, _, _ = run(["systemctl", "cat", f"{name}.service"], 3)
        if exists != 0:
            continue
        _, state, _ = run(["systemctl", "is-active", name], 3)
        enabled, _, _ = run(["systemctl", "is-enabled", name], 3)
        # The configured node service is always expected. Other known services
        # are monitored only when enabled or currently active, avoiding alerts
        # for intentionally disabled leftovers from an old installation.
        if name != primary and enabled != 0 and state != "active":
            continue
        result[name] = state or "unknown"
    return result


def manager_status():
    if MANAGER_APP.exists():
        code, out, err = run([sys.executable, str(MANAGER_APP), "status"], 20)
        if code == 0 and out:
            return redact(out)
        return redact(err or "Universe VPS Manager 状态读取失败")
    return "未安装 Universe VPS Manager；显示基础系统状态。"


def collect_snapshot(state):
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
    listening_tcp_ports = []
    for line in ports.splitlines():
        columns = line.split()
        if len(columns) < 4:
            continue
        port = columns[3].rsplit(":", 1)[-1].strip("[]")
        if port.isdigit():
            listening_tcp_ports.append(int(port))
    expected_ports = [int(value) for value in re.findall(r"\d+", str(manager_cfg.get("check_port", "")))]
    local_test_cfg = load_json(LOCAL_TEST_STATE, {})
    local_test_url = str(local_test_cfg.get("url", "")) if isinstance(local_test_cfg, dict) else ""
    diagnostics = {
        "cpu": {"used_pct": cpu_percent(), "cores": os.cpu_count() or 1},
        "load": {"1m": round(load1, 2), "5m": round(load5, 2), "15m": round(load15, 2)},
        "memory": mem_info(),
        "disk": {
            "used_gb": round(disk.used / 1073741824, 2),
            "total_gb": round(disk.total / 1073741824, 2),
            "used_pct": round(disk.used * 100 / disk.total, 1) if disk.total else 0,
        },
        "uptime_seconds": uptime,
        "network": network_info(state),
        "services": service_states(manager_cfg),
        "expected_ports": sorted(set(expected_ports)),
        "listening_tcp_ports": sorted(set(listening_tcp_ports)),
        "alert_policy": {
            "ram_warn": manager_cfg.get("ram_warn", 80),
            "swap_warn": manager_cfg.get("swap_warn", 30),
            "cpu_warn": manager_cfg.get("cpu_warn", 80),
            "disk_warn": manager_cfg.get("disk_warn", 90),
            "bandwidth_mbps": manager_cfg.get("bandwidth_mbps", 1000),
            "traffic_saturation_ratio": manager_cfg.get("traffic_saturation_ratio", 90),
        },
        "failed_units": redact(failed),
        "listening_ports": redact("\n".join(ports.splitlines()[:60])),
        "top_cpu": redact("\n".join(top_cpu.splitlines()[:12])),
        "recent_warnings": redact(warnings),
        "ssh_failures_24h": redact("\n".join(ssh_lines[-30:])),
        "local_test_url": local_test_url if re.fullmatch(r"https://[A-Za-z0-9.-]+/__ejectors-test", local_test_url) else "",
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


def caddy_binary():
    for candidate in ("/usr/local/bin/caddy-naive", shutil.which("caddy"), "/usr/local/bin/caddy", "/usr/bin/caddy"):
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return candidate
    return ""


def direct_test_site():
    roots = (Path("/etc/caddy-naive"), Path("/etc/shared-caddy"))
    sites = [(root, site) for root in roots for site in sorted((root / "sites").glob("filebrowser-*.caddy"))]
    if not sites:
        raise RuntimeError("未在 /etc/caddy-naive 或 /etc/shared-caddy 找到 FileBrowser 站点，未做任何修改。")
    request = urllib.request.Request("https://api64.ipify.org", headers={"User-Agent": "ejectors-local-test-setup/1.2"})
    with urllib.request.urlopen(request, timeout=10) as response:
        public_ip = str(ipaddress.ip_address(response.read(128).decode().strip()))
    rejected = []
    for root, site in sites:
        text = site.read_text(encoding="utf-8")
        match = re.search(r"(?m)^\s*([A-Za-z0-9.-]+):443\s*\{", text)
        if not match:
            continue
        domain = match.group(1).lower()
        route_dir = root / "routes" / domain
        if f"import {route_dir}/*.caddy" not in text:
            rejected.append(f"{domain} 缺少独立路由导入点")
            continue
        addresses = set()
        for record_type in ("A", "AAAA"):
            try:
                dns_url = "https://cloudflare-dns.com/dns-query?" + urllib.parse.urlencode({"name": domain, "type": record_type})
                dns_request = urllib.request.Request(dns_url, headers={
                    "Accept": "application/dns-json",
                    "User-Agent": "ejectors-local-test-setup/1.2",
                })
                with urllib.request.urlopen(dns_request, timeout=10) as response:
                    dns_value = json.loads(response.read().decode("utf-8"))
                for answer in dns_value.get("Answer", []):
                    try:
                        addresses.add(str(ipaddress.ip_address(str(answer.get("data", "")))))
                    except ValueError:
                        pass
            except Exception:
                pass
        if public_ip not in addresses:
            rejected.append(f"{domain} 未直接解析到本 VPS")
            continue
        caddyfile = root / "Caddyfile"
        if not caddyfile.is_file():
            rejected.append(f"{domain} 缺少 {caddyfile}")
            continue
        return domain, route_dir, caddyfile
    raise RuntimeError("；".join(rejected) or "没有找到可安全使用的直连 HTTPS 域名，未做任何修改。")


def validate_and_reload_caddy(caddyfile):
    caddyfile = Path(caddyfile)
    allowed = {Path("/etc/caddy-naive/Caddyfile"), Path("/etc/shared-caddy/Caddyfile")}
    if caddyfile not in allowed or not caddyfile.is_file():
        return False, "Caddy 主配置路径不在安全白名单"
    binary = caddy_binary()
    if not binary:
        return False, "未找到 Caddy 可执行文件"
    code, out, err = run([binary, "validate", "--config", str(caddyfile), "--adapter", "caddyfile"], 20)
    if code != 0:
        return False, redact(err or out or "Caddy 配置校验失败")
    code, out, err = run(["systemctl", "reload", "shared-caddy"], 30)
    return code == 0, redact(err or out or ("共享 Caddy 已重载" if code == 0 else "共享 Caddy 重载失败"))


def setup_local_test():
    try:
        domain, route_dir, caddyfile = direct_test_site()
    except Exception as exc:
        return False, redact(exc)
    route_dir.mkdir(parents=True, exist_ok=True)
    route = route_dir / "ejectors-local-test.caddy"
    previous = route.read_bytes() if route.exists() else None
    content = (
        "# Managed by ejectors Telegram VPS Agent.\n"
        "handle_path /__ejectors-test/* {\n"
        "    header Cache-Control \"no-store, no-cache, must-revalidate\"\n"
        "    reverse_proxy 127.0.0.1:18789\n"
        "}\n"
    )
    tmp = route.with_suffix(".tmp")
    tmp.write_text(content, encoding="utf-8")
    os.chmod(tmp, 0o640)
    os.chown(tmp, 0, route_dir.stat().st_gid)
    os.replace(tmp, route)
    url = f"https://{domain}/__ejectors-test"
    save_json(LOCAL_TEST_STATE, {"url": url, "route": str(route), "domain": domain, "caddyfile": str(caddyfile)})
    code, out, err = run(["systemctl", "start", "ejectors-local-speedtest.service"], 20)
    if code == 0:
        try:
            with urllib.request.urlopen("http://127.0.0.1:18789/health", timeout=5) as response:
                code = 0 if response.status == 200 else 1
        except Exception as exc:
            code, err = 1, str(exc)
    if code == 0:
        valid, message = validate_and_reload_caddy(caddyfile)
    else:
        valid, message = False, redact(err or out or "本地测速服务启动失败")
    if not valid:
        if previous is None:
            route.unlink(missing_ok=True)
        else:
            route.write_bytes(previous)
            os.chmod(route, 0o640)
            os.chown(route, 0, route.parent.stat().st_gid)
        LOCAL_TEST_STATE.unlink(missing_ok=True)
        run(["systemctl", "stop", "ejectors-local-speedtest.service"], 15)
        return False, f"启用失败并已回滚：{message}"
    return True, f"本地设备直连测试入口已启用：{url}\n原网页内容、原有路由和代理节点未修改；只新增了隔离测试路径。"


def disable_local_test():
    cfg = load_json(LOCAL_TEST_STATE, {})
    route_text = str(cfg.get("route", "")) if isinstance(cfg, dict) else ""
    caddyfile = Path(str(cfg.get("caddyfile", ""))) if isinstance(cfg, dict) else Path("")
    expected_roots = (Path("/etc/caddy-naive/routes").resolve(), Path("/etc/shared-caddy/routes").resolve())
    if not route_text:
        return True, "本地设备直连测试入口本来就是停用状态。"
    route = Path(route_text)
    try:
        resolved = route.resolve()
    except Exception:
        return False, "测速路由路径无效，拒绝修改。"
    if resolved.name != "ejectors-local-test.caddy" or not any(root in resolved.parents for root in expected_roots):
        return False, "测速路由路径不在安全白名单，拒绝修改。"
    previous = resolved.read_bytes() if resolved.exists() else None
    resolved.unlink(missing_ok=True)
    valid, message = validate_and_reload_caddy(caddyfile)
    if not valid:
        if previous is not None:
            resolved.parent.mkdir(parents=True, exist_ok=True)
            resolved.write_bytes(previous)
            os.chmod(resolved, 0o640)
            os.chown(resolved, 0, resolved.parent.stat().st_gid)
        return False, f"停用失败并已回滚：{message}"
    run(["systemctl", "stop", "ejectors-local-speedtest.service"], 15)
    LOCAL_TEST_STATE.unlink(missing_ok=True)
    return True, "本地设备直连测试入口已停用；其他功能未修改。"


def execute(command):
    action = str(command.get("action", ""))
    if action not in ALLOWED_ACTIONS:
        return False, "拒绝了不在白名单中的操作。"
    if int(command.get("expires_at", 0)) < int(time.time() * 1000):
        return False, "操作已过期，未执行。"
    if action == "refresh":
        return True, "本机状态已刷新。"
    if action == "clean":
        before = mem_info()
        run(["sync"], 5)
        try:
            Path("/proc/sys/vm/drop_caches").write_text("3\n")
        except Exception as exc:
            return False, f"缓存清理失败：{redact(exc)}"
        run(["journalctl", "--vacuum-time=3d"], 15)
        after = mem_info()
        return True, (
            f"缓存清理完成。清理前可用 {before['available_mb']}MB，"
            f"清理后可用 {after['available_mb']}MB，"
            f"变化 {after['available_mb'] - before['available_mb']:+d}MB。"
        )
    if action == "pause10":
        return update_pause(10)
    if action == "resume":
        return update_pause(0)
    if action == "setup_local_test":
        return setup_local_test()
    if action == "disable_local_test":
        return disable_local_test()
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
                state["snapshot"] = collect_snapshot(state)
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
                state["snapshot"] = collect_snapshot(state)
                last_collect = time.time()
            save_json(STATE_PATH, state)
            failures = 0
            # 30 秒心跳兼顾控制响应速度，并为 Cloudflare Free 额度保留余量。
            time.sleep(1 if executed else 30)
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

write_local_test_server() {
  cat > "$LOCAL_TEST_APP" <<'PYTEST'
#!/usr/bin/env python3
import base64
import hashlib
import hmac
import html
import json
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

CONF = Path("/etc/ejectors-telegram-vps-agent.json")
DOWNLOAD_BYTES = 100_000_000
CHUNK = bytes((index * 73 + 41) % 256 for index in range(256 * 1024))


def config():
    return json.loads(CONF.read_text(encoding="utf-8"))


def verify_token(token):
    try:
        body, signature = token.split(".", 1)
        if not body or len(signature) != 64:
            return None
        cfg = config()
        expected = hmac.new(str(cfg["agent_secret"]).encode(), body.encode(), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(signature.lower(), expected):
            return None
        padded = body.replace("-", "+").replace("_", "/") + "=" * ((4 - len(body) % 4) % 4)
        payload = json.loads(base64.b64decode(padded, validate=True).decode("utf-8"))
        if payload.get("n") != cfg.get("node_id") or payload.get("k") not in ("latency", "speed"):
            return None
        if int(payload.get("e", 0)) < int(time.time() * 1000):
            return None
        return payload
    except Exception:
        return None


def page(token, kind, worker_url):
    title = "本机到 VPS 延迟测试" if kind == "latency" else "本机到 VPS 下载测速"
    detail = "将连续请求 VPS 6 次并计算真实浏览器往返时间。" if kind == "latency" else "点击开始后，本设备会从 VPS 下载 100 MB 测试数据。"
    button = "" if kind == "latency" else '<button id="start">开始下载 100 MB</button>'
    auto = "runLatency();" if kind == "latency" else ""
    return f'''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer"><title>{html.escape(title)}</title>
<style>body{{font-family:system-ui,-apple-system,sans-serif;margin:0;background:#f4f7fb;color:#162033}}main{{max-width:560px;margin:8vh auto;padding:24px}}.card{{background:#fff;border-radius:18px;padding:24px;box-shadow:0 8px 30px #15325b18}}h1{{font-size:24px;margin:0 0 12px}}p{{line-height:1.6}}#result{{font-size:20px;font-weight:700;white-space:pre-line;margin-top:18px}}button{{width:100%;padding:14px;border:0;border-radius:12px;background:#1677ff;color:#fff;font-size:18px}}button:disabled{{opacity:.55}}small{{color:#667085}}</style></head>
<body><main><div class="card"><h1>{html.escape(title)}</h1><p>{html.escape(detail)}</p>{button}<div id="result">准备中…</div><p><small>测试链接 10 分钟有效，结果仅回传到你的 Telegram 管家。</small></p></div></main>
<script>
const token={json.dumps(token)}; const worker={json.dumps(worker_url.rstrip('/'))}; const result=document.getElementById('result');
async function report(data){{
  const response=await fetch(worker+'/api/local-test/result',{{method:'POST',headers:{{'Content-Type':'text/plain;charset=UTF-8'}},body:JSON.stringify({{...data,token,user_agent:navigator.userAgent.slice(0,120)}})}});
  if(!response.ok) throw new Error('结果回传失败');
}}
async function runLatency(){{
  try{{result.textContent='正在测试…';const values=[];
    for(let i=0;i<6;i++){{const started=performance.now();const response=await fetch('ping?token='+encodeURIComponent(token)+'&i='+i,{{cache:'no-store'}});if(!response.ok)throw new Error('VPS 无响应');const value=performance.now()-started;if(i>0)values.push(value);}}
    const avg=values.reduce((a,b)=>a+b,0)/values.length,min=Math.min(...values),max=Math.max(...values);
    result.textContent=`平均 ${{avg.toFixed(1)}} ms\n最低 ${{min.toFixed(1)}} ms · 最高 ${{max.toFixed(1)}} ms\n正在回传 Telegram…`;
    await report({{latency_avg_ms:avg,latency_min_ms:min,latency_max_ms:max,samples:values.length}});result.textContent=result.textContent.replace('正在回传 Telegram…','结果已回传 Telegram');
  }}catch(error){{result.textContent='测试失败：'+error.message;}}
}}
async function runSpeed(){{
  const button=document.getElementById('start');button.disabled=true;
  try{{result.textContent='正在下载，请保持页面打开…';const started=performance.now();const response=await fetch('download?token='+encodeURIComponent(token),{{cache:'no-store'}});if(!response.ok||!response.body)throw new Error('浏览器不支持流式测速或 VPS 无响应');
    const reader=response.body.getReader();let bytes=0;while(true){{const part=await reader.read();if(part.done)break;bytes+=part.value.byteLength;result.textContent=`已下载 ${{(bytes/1e6).toFixed(1)}} / 100.0 MB`;}}
    const elapsed=performance.now()-started,mbps=bytes*8/elapsed/1000;
    result.textContent=`${{mbps.toFixed(1)}} Mbps\n${{(bytes/1e6).toFixed(1)}} MB · ${{(elapsed/1000).toFixed(1)}} 秒\n正在回传 Telegram…`;
    await report({{download_mbps:mbps,bytes,elapsed_ms:elapsed}});result.textContent=result.textContent.replace('正在回传 Telegram…','结果已回传 Telegram');
  }}catch(error){{result.textContent='测速失败：'+error.message;button.disabled=false;}}
}}
if(document.getElementById('start'))document.getElementById('start').addEventListener('click',runSpeed);{auto}
</script></body></html>'''.encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def send_common_headers(self, status, content_type, length=0):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(length))
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.end_headers()

    def do_GET(self):
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path == "/health":
            body = b"ok"
            self.send_common_headers(200, "text/plain; charset=utf-8", len(body)); self.wfile.write(body); return
        token = urllib.parse.parse_qs(parsed.query).get("token", [""])[0]
        payload = verify_token(token)
        if not payload:
            body = "链接无效或已过期，请回 Telegram 重新生成。".encode("utf-8")
            self.send_common_headers(403, "text/plain; charset=utf-8", len(body)); self.wfile.write(body); return
        if parsed.path in ("/", ""):
            cfg = config(); body = page(token, payload["k"], str(cfg["worker_url"]))
            self.send_common_headers(200, "text/html; charset=utf-8", len(body)); self.wfile.write(body); return
        if parsed.path == "/ping" and payload["k"] == "latency":
            self.send_common_headers(204, "text/plain", 0); return
        if parsed.path == "/download" and payload["k"] == "speed":
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(DOWNLOAD_BYTES))
            self.send_header("Content-Disposition", "attachment; filename=100mb.test")
            self.send_header("Cache-Control", "no-store, no-transform")
            self.send_header("Content-Encoding", "identity")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            remaining = DOWNLOAD_BYTES
            try:
                while remaining:
                    block = CHUNK[:min(len(CHUNK), remaining)]
                    self.wfile.write(block); remaining -= len(block)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        body = b"not found"
        self.send_common_headers(404, "text/plain", len(body)); self.wfile.write(body)


server = ThreadingHTTPServer(("127.0.0.1", 18789), Handler)
server.daemon_threads = True
server.serve_forever()
PYTEST
  chmod 755 "$LOCAL_TEST_APP"
  cat > "$LOCAL_TEST_SERVICE" <<EOF
[Unit]
Description=Ejectors local-device VPS speed test
After=network-online.target
ConditionPathExists=/var/lib/ejectors-local-test.json

[Service]
Type=simple
ExecStart=/usr/bin/python3 $LOCAL_TEST_APP
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadOnlyPaths=$CONF
RestrictAddressFamilies=AF_INET AF_UNIX
MemoryMax=96M
CPUQuota=50%

[Install]
WantedBy=multi-user.target
EOF
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
ReadWritePaths=/var/lib /opt/universe-vps-manager -/etc/caddy-naive/routes -/etc/shared-caddy/routes /run /tmp

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable ejectors-local-speedtest.service >/dev/null
  if [ -f /var/lib/ejectors-local-test.json ]; then
    systemctl start ejectors-local-speedtest.service
  fi
  systemctl enable ejectors-telegram-vps-agent.service >/dev/null
  systemctl restart ejectors-telegram-vps-agent.service
}

apply_cloudflare_only_mode() {
  if [ -f "$MANAGER_CRON" ]; then
    [ -f "$MANAGER_CRON_BACKUP" ] || cp -a "$MANAGER_CRON" "$MANAGER_CRON_BACKUP"
    python3 - "$MANAGER_CRON" <<'PY'
import os, pathlib, re, sys
path = pathlib.Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()
lines = [line for line in lines if not re.search(r"\bpython3\s+\S*vps_manager\.py\s+report\b", line)]
tmp = path.with_suffix(".tmp")
tmp.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
os.chmod(tmp, 0o644)
os.replace(tmp, path)
PY
  fi
  if [ -f "$MANAGER_APP" ]; then
    [ -f "$MANAGER_APP_BACKUP" ] || cp -a "$MANAGER_APP" "$MANAGER_APP_BACKUP"
    python3 - "$MANAGER_APP" <<'PY'
import os, pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
needle = "def send_message(text, reply_markup=None):\n"
guard = '    if Path("/var/lib/ejectors-telegram-webhook-active").exists():\n        return True\n'
if guard not in text:
    if needle not in text:
        raise SystemExit("未找到本地 Telegram 发送函数，拒绝修改")
    text = text.replace(needle, needle + guard, 1)
    tmp = path.with_suffix(".cloudflare-tmp")
    tmp.write_text(text, encoding="utf-8")
    os.chmod(tmp, path.stat().st_mode & 0o777)
    os.replace(tmp, path)
PY
  fi
}

restore_local_monitoring_mode() {
  if [ -f "$MANAGER_CRON_BACKUP" ]; then
    cp -a "$MANAGER_CRON_BACKUP" "$MANAGER_CRON"
    rm -f "$MANAGER_CRON_BACKUP"
  fi
  if [ -f "$MANAGER_APP_BACKUP" ]; then
    cp -a "$MANAGER_APP_BACKUP" "$MANAGER_APP"
    rm -f "$MANAGER_APP_BACKUP"
  fi
}

install_agent() {
  need_root
  install_deps
  write_config
  write_agent
  write_local_test_server
  write_service
  if [ -f "$MODE_FILE" ]; then
    apply_cloudflare_only_mode
  fi
  sleep 2
  systemctl --no-pager --full status ejectors-telegram-vps-agent.service || true
  echo
  echo "✅ Cloudflare VPS Agent 已安装。"
  echo "现有 Telegram 轮询服务尚未停止，原功能尚未切换。"
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
health_request = urllib.request.Request(
    health_url,
    headers={"User-Agent": "ejectors-telegram-vps-agent/1.2.1"},
)
with urllib.request.urlopen(health_request, timeout=15) as response:
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
  apply_cloudflare_only_mode
  echo "✅ 已切换为 Cloudflare Webhook 模式。"
  echo "本地 Telegram 整点播报、异常告警和 AI 简报已停用；状态采集、流量累计、自动重启与节点功能保留。"
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
  restore_local_monitoring_mode
  rm -f "$MODE_FILE"
  if [ -f "$BRIEF_BACKUP" ]; then
    cp -a "$BRIEF_BACKUP" "$BRIEF_MODE"
    rm -f "$BRIEF_BACKUP"
  fi
  systemctl enable --now "$OLD_BOT_SERVICE"
  echo "✅ 已恢复 VPS 本地 Telegram 轮询模式。"
}

upgrade_agent() {
  need_root
  [ -f "$CONF" ] || { echo "尚未安装 Agent，请先运行：bash $0 install"; exit 1; }
  install_deps
  write_agent
  write_local_test_server
  write_service
  if [ -f "$MODE_FILE" ]; then
    apply_cloudflare_only_mode
  fi
  echo "✅ Cloudflare VPS Agent 已升级到 $VERSION。"
  show_status
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
  if [ -f /var/lib/ejectors-local-test.json ]; then
    echo "本地测速入口仍在使用。请先在 Telegram 发送 /testdisable 并确认，避免遗留无效 Caddy 路由。"
    exit 1
  fi
  systemctl disable --now ejectors-telegram-vps-agent.service 2>/dev/null || true
  systemctl disable --now ejectors-local-speedtest.service 2>/dev/null || true
  rm -f "$SERVICE" "$APP" "$LOCAL_TEST_SERVICE" "$LOCAL_TEST_APP" "$CONF" "$STATE" "$MODE_FILE" "$BRIEF_BACKUP"
  systemctl daemon-reload
  echo "已移除 Cloudflare Telegram VPS Agent；原 Universe VPS Manager 文件未删除。"
}

case "${1:-install}" in
  install|update) install_agent ;;
  upgrade) upgrade_agent ;;
  activate) activate_webhook_mode ;;
  deactivate) deactivate_webhook_mode ;;
  status) show_status ;;
  uninstall) uninstall_agent ;;
  *) echo "用法：$0 [install|update|upgrade|activate|deactivate|status|uninstall]"; exit 1 ;;
esac
