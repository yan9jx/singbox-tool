#!/usr/bin/env bash
set -euo pipefail

APP="/usr/local/bin/ejectors-vps-agent"
CONF="/etc/ejectors-vps-agent.conf"
SERVICE="/etc/systemd/system/ejectors-vps-agent.service"
UPDATE_APP="/usr/local/sbin/ejectors-vps-agent-update"
UPDATE_SERVICE="/etc/systemd/system/ejectors-vps-agent-update.service"
UPDATE_TIMER="/etc/systemd/system/ejectors-vps-agent-update.timer"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "请使用 root 权限运行：sudo bash $0"
  exit 1
fi

action="${1:-install}"

case "$action" in
  uninstall)
    systemctl disable --now ejectors-vps-agent.service ejectors-vps-agent-update.timer 2>/dev/null || true
    rm -f "$SERVICE" "$UPDATE_SERVICE" "$UPDATE_TIMER" "$UPDATE_APP" "$APP" "$CONF" /var/lib/ejectors-vps-agent.json
    systemctl daemon-reload
    echo "VPS 状态上报已卸载；网页会在约 150 秒后显示离线。"
    exit 0
    ;;
  status)
    systemctl status ejectors-vps-agent.service --no-pager
    systemctl status ejectors-vps-agent-update.timer --no-pager || true
    exit $?
    ;;
  install|update) ;;
  *)
    echo "用法：$0 [install|update|uninstall|status]"
    exit 1
    ;;
esac

command -v python3 >/dev/null 2>&1 || {
  echo "缺少 python3，请先安装。"
  exit 1
}

if [[ -f "$CONF" ]]; then
  read_conf_value() {
    sed -n "s/^$1='\\(.*\\)'$/\\1/p" "$CONF" | head -n1
  }
  dashboard_url="$(read_conf_value DASHBOARD_URL)"
  ingest_token="$(read_conf_value INGEST_TOKEN)"
  node_id="$(read_conf_value NODE_ID)"
  node_name="$(read_conf_value NODE_NAME)"
  provider="$(read_conf_value PROVIDER)"
  location="$(read_conf_value LOCATION)"
  node_name="${node_name:-$(hostname)}"
  [[ -n "$dashboard_url" && -n "$ingest_token" && -n "$node_id" ]] || { echo "现有配置不完整，请检查 $CONF。"; exit 1; }
  echo "检测到现有配置，将保留节点 ID、上报密钥和节点信息。"
else
  [[ "$action" != "update" ]] || { echo "未找到现有配置，不能执行更新。"; exit 1; }
  default_url="${DASHBOARD_URL:-}"
  default_id="$(hostname | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9._-' | cut -c1-64)"
  if [[ -n "$default_url" ]]; then
    read -rp "状态面板地址 [$default_url]: " input_url
    dashboard_url="${input_url:-$default_url}"
  else
    read -rp "状态面板地址（例如 https://status.example.com）: " dashboard_url
  fi
  dashboard_url="${dashboard_url%/}"
  [[ "$dashboard_url" =~ ^https?://[^[:space:]]+$ ]] || { echo "状态面板地址格式错误。"; exit 1; }
  if [[ -n "${INGEST_TOKEN:-}" ]]; then ingest_token="$INGEST_TOKEN"; else read -rsp "网页上报 Token（输入时不会显示）: " ingest_token; echo; fi
  [[ -n "$ingest_token" ]] || { echo "网页上报 Token 不能为空。"; exit 1; }
  read -rp "节点 ID [$default_id]: " input_id
  node_id="${input_id:-$default_id}"
  [[ "$node_id" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$ ]] || { echo "节点 ID 格式错误，只能使用字母、数字、点、下划线和短横线。"; exit 1; }
  read -rp "节点名称 [$(hostname)]: " input_name
  node_name="${input_name:-$(hostname)}"
  read -rp "服务商（可留空）: " provider
  read -rp "机房位置（可留空）: " location

  install -d -m 700 /var/lib/ejectors-vps-agent
  cat > "$CONF" <<EOF
DASHBOARD_URL='$dashboard_url'
INGEST_TOKEN='$ingest_token'
NODE_ID='$node_id'
NODE_NAME='$node_name'
PROVIDER='$provider'
LOCATION='$location'
EOF
  chmod 600 "$CONF"
fi

install -d -m 700 /var/lib/ejectors-vps-agent

cat > "$APP" <<'PY'
#!/usr/bin/env python3
import argparse, concurrent.futures, glob, json, os, platform, re, shutil, socket, subprocess, time, urllib.request

VERSION = "1.2.1"
CONF = "/etc/ejectors-vps-agent.conf"
STATE = "/var/lib/ejectors-vps-agent/state.json"

def read_conf():
    data = {}
    with open(CONF, encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line or "=" not in line: continue
            key, value = line.split("=", 1)
            data[key] = value.strip().strip("'\"")
    return data

def read_json(path, default):
    try:
        with open(path, encoding="utf-8") as f: return json.load(f)
    except Exception:
        return default

def write_state(data):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f: json.dump(data, f)
    os.replace(tmp, STATE)

def meminfo():
    values = {}
    with open("/proc/meminfo") as f:
        for line in f:
            key, value = line.split(":", 1)
            values[key] = int(value.strip().split()[0]) / 1024
    total = values.get("MemTotal", 0)
    available = values.get("MemAvailable", 0)
    used = max(0, total - available)
    swap_total = values.get("SwapTotal", 0)
    swap_used = max(0, swap_total - values.get("SwapFree", 0))
    return (
        {"total_mb": round(total), "used_mb": round(used), "available_mb": round(available), "usage_pct": pct(used, total)},
        {"total_mb": round(swap_total), "used_mb": round(swap_used), "usage_pct": pct(swap_used, swap_total)},
    )

def cpu_times():
    with open("/proc/stat") as f: values = [int(v) for v in f.readline().split()[1:]]
    idle = values[3] + (values[4] if len(values) > 4 else 0)
    return idle, sum(values)

def cpuinfo():
    idle1, total1 = cpu_times()
    time.sleep(.18)
    idle2, total2 = cpu_times()
    delta = total2 - total1
    usage = 0 if delta <= 0 else 100 * (1 - (idle2 - idle1) / delta)
    loads = os.getloadavg()
    return {"usage_pct": round(usage, 1), "cores": os.cpu_count() or 1, "load_1": round(loads[0], 2), "load_5": round(loads[1], 2), "load_15": round(loads[2], 2)}

def pct(used, total):
    return round(used * 100 / total, 1) if total else 0

def network():
    rx = tx = 0
    with open("/proc/net/dev") as f:
        for line in f:
            if ":" not in line: continue
            iface, values = line.split(":", 1)
            if iface.strip() == "lo": continue
            fields = values.split()
            rx += int(fields[0]); tx += int(fields[8])
    old = read_json(STATE, {})
    now = time.time()
    elapsed = max(1, now - old.get("timestamp", now))
    result = {
        "rx_bytes": rx, "tx_bytes": tx,
        "rx_bps": max(0, round((rx - old.get("rx_bytes", rx)) / elapsed)),
        "tx_bps": max(0, round((tx - old.get("tx_bytes", tx)) / elapsed)),
    }
    write_state({"timestamp": now, "rx_bytes": rx, "tx_bytes": tx, "public_ip": old.get("public_ip", ""), "ip_checked": old.get("ip_checked", 0)})
    return result

def command(args):
    try: return subprocess.run(args, text=True, capture_output=True, timeout=4).stdout.strip()
    except Exception: return ""

def ping_target(target):
    if not shutil.which("ping"):
        return {"target": target, "latency_ms": None, "loss_pct": None, "status": "unavailable"}
    env = dict(os.environ, LC_ALL="C", LANG="C")
    try:
        result = subprocess.run(
            ["ping", "-n", "-q", "-c", "4", "-W", "1", target],
            text=True, capture_output=True, timeout=7, env=env,
        )
        output = result.stdout + "\n" + result.stderr
        loss_match = re.search(r"([\d.]+)%\s+packet loss", output)
        latency_match = re.search(r"=\s*[\d.]+/([\d.]+)/", output)
        loss = round(float(loss_match.group(1)), 1) if loss_match else 100.0
        latency = round(float(latency_match.group(1)), 1) if latency_match else None
        return {
            "target": target,
            "latency_ms": latency,
            "loss_pct": loss,
            "status": "ok" if loss < 100 else "loss",
        }
    except Exception:
        return {"target": target, "latency_ms": None, "loss_pct": 100.0, "status": "loss"}

def probe_carrier(probe):
    targets = [str(value) for value in probe.get("targets", [])[:2] if value]
    result = {"target": "", "latency_ms": None, "loss_pct": None, "status": "unavailable"}
    for target in targets:
        result = ping_target(target)
        if result["status"] == "ok": break
    result["carrier"] = str(probe.get("carrier", ""))
    return result

def network_quality(config):
    if not config or not config.get("enabled") or not config.get("probes"):
        return None
    probes = list(config.get("probes", []))[:3]
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(probes)) as executor:
        results = list(executor.map(probe_carrier, probes))
    return {
        "region": str(config.get("region", "")),
        "measured_at": int(time.time()),
        "probes": results,
    }

def service_snapshot():
    units = command(["systemctl", "list-unit-files", "--type=service", "--no-legend"])
    processes = {item.strip() for item in command(["ps", "-eo", "comm="]).splitlines() if item.strip()}
    return units, processes

def service_info(label, unit_names, units):
    installed = any(re.search(rf"^{re.escape(unit)}\.service\s", units, re.M) for unit in unit_names)
    running = installed and any(command(["systemctl", "is-active", unit]) == "active" for unit in unit_names)
    return {"name": label, "installed": bool(installed), "running": bool(running)}

def naive_service_info(units, processes):
    marker_paths = [
        "/etc/naiveproxy/node-info.env",
        "/etc/systemd/system/naiveproxy.service",
        "/etc/systemd/system/caddy-naive.service",
    ]
    marker_patterns = [
        "/etc/caddy-naive/sites/naive-*.caddy",
        "/etc/caddy-naive/routes/*/naive.caddy",
        "/etc/caddy-naive/routes/*/naive-connect.caddy",
    ]
    installed = any(os.path.isfile(path) for path in marker_paths)
    installed = installed or any(glob.glob(pattern) for pattern in marker_patterns)
    unit_names = ["naiveproxy", "caddy-naive", "shared-caddy", "caddy"]
    running = installed and (
        any(command(["systemctl", "is-active", unit]) == "active" for unit in unit_names)
        or any(name in processes for name in ["naive", "naiveproxy", "caddy-naive", "caddy"])
    )
    return {"name": "Naive", "installed": bool(installed), "running": bool(running)}

def listening_ports():
    output = command(["ss", "-H", "-lntup"])
    found = {}
    for line in output.splitlines():
        parts = line.split()
        if len(parts) < 5: continue
        local = parts[4]
        match = re.search(r":(\d+)$", local)
        if not match: continue
        port = int(match.group(1))
        process_match = re.search(r'\(\("([^"]+)"', line)
        process = process_match.group(1) if process_match else ""
        found[(port, process)] = {"port": port, "process": process}
    return sorted(found.values(), key=lambda item: (item["port"], item["process"]))[:200]

def public_ip():
    state = read_json(STATE, {})
    if state.get("public_ip") and time.time() - state.get("ip_checked", 0) < 21600:
        return state["public_ip"]
    try:
        req = urllib.request.Request("https://api.ipify.org", headers={"User-Agent": "ejectors-vps-agent"})
        ip = urllib.request.urlopen(req, timeout=5).read().decode().strip()
        socket.inet_pton(socket.AF_INET6 if ":" in ip else socket.AF_INET, ip)
        state.update({"public_ip": ip, "ip_checked": time.time()})
        write_state(state)
        return ip
    except Exception:
        return state.get("public_ip", "")

def os_name():
    try:
        data = {}
        with open("/etc/os-release") as f:
            for line in f:
                if "=" in line:
                    k, v = line.rstrip().split("=", 1); data[k] = v.strip('"')
        return data.get("PRETTY_NAME", platform.system())
    except Exception:
        return platform.system()

def collect(conf, probe_config=None):
    memory, swap = meminfo()
    disk = shutil.disk_usage("/")
    units, processes = service_snapshot()
    services = [
        service_info("xray", ["xray", "xray-xhttp", "reality-xhttp"], units),
        service_info("sing-box", ["sing-box", "singbox"], units),
        naive_service_info(units, processes),
        service_info("文件浏览器", ["filebrowser"], units),
    ]
    installed = [item for item in services if item["installed"]]
    alerts = [f'{item["name"]} 未运行' for item in installed if not item["running"]]
    with open("/proc/uptime") as f: uptime = int(float(f.read().split()[0]))
    boot_id = ""
    try:
        with open("/proc/sys/kernel/random/boot_id") as f: boot_id = f.read().strip()
    except Exception: pass
    payload = {
        "node_id": conf["NODE_ID"], "name": conf["NODE_NAME"],
        "provider": conf.get("PROVIDER", ""), "location": conf.get("LOCATION", ""),
        "hostname": socket.gethostname(), "os": os_name(), "kernel": platform.release(), "arch": platform.machine(),
        "public_ip": public_ip(), "boot_id": boot_id, "uptime_seconds": uptime,
        "health": "degraded" if alerts else "normal", "alerts": alerts,
        "cpu": cpuinfo(), "memory": memory, "swap": swap,
        "disk": {"total_bytes": disk.total, "used_bytes": disk.used, "free_bytes": disk.free, "usage_pct": pct(disk.used, disk.total)},
        "network": network(), "services": installed, "ports": listening_ports(),
        "reachability": {"outbound": "normal", "inbound_probe": "unknown"},
        "agent_version": VERSION,
    }
    quality = network_quality(probe_config)
    if quality: payload["network_quality"] = quality
    return payload

def post(conf, endpoint, payload):
    body = json.dumps(payload, separators=(",", ":")).encode()
    req = urllib.request.Request(conf["DASHBOARD_URL"] + endpoint, data=body, method="POST", headers={
        "Content-Type": "application/json", "Authorization": "Bearer " + conf["INGEST_TOKEN"], "User-Agent": "ejectors-vps-agent/" + VERSION,
    })
    with urllib.request.urlopen(req, timeout=15) as response:
        try: return json.loads(response.read().decode())
        except Exception: return {}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--loop", action="store_true")
    parser.add_argument("--shutdown", action="store_true")
    parser.add_argument("--version", action="store_true")
    args = parser.parse_args()
    if args.version:
        print(VERSION)
        return
    conf = read_conf()
    if args.shutdown:
        payload = {"node_id": conf["NODE_ID"], "name": conf["NODE_NAME"], "provider": conf.get("PROVIDER", ""), "location": conf.get("LOCATION", ""), "agent_version": VERSION}
        try: post(conf, "/api/v1/shutdown", payload)
        except Exception: pass
        return
    probe_config = None
    while True:
        try:
            response = post(conf, "/api/v1/heartbeat", collect(conf, probe_config))
            if isinstance(response, dict) and isinstance(response.get("probe_config"), dict):
                probe_config = response["probe_config"]
        except Exception as exc:
            print(time.strftime("%F %T"), "report failed:", exc, flush=True)
        if not args.loop: return
        time.sleep(60)

if __name__ == "__main__": main()
PY
chmod 755 "$APP"

cat > "$UPDATE_APP" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
APP="/usr/local/bin/ejectors-vps-agent"
URL="https://raw.githubusercontent.com/yan9jx/singbox-tool/main/vps-status-agent.sh"
tmp="$(mktemp /tmp/ejectors-agent-update.XXXXXX.sh)"
trap 'rm -f "$tmp"' EXIT
python3 - "$URL?ts=$(date +%s)" "$tmp" <<'PY'
import sys, urllib.request
req = urllib.request.Request(sys.argv[1], headers={"User-Agent": "ejectors-vps-agent-updater"})
with urllib.request.urlopen(req, timeout=30) as response, open(sys.argv[2], "wb") as output:
    output.write(response.read())
PY
current="$("$APP" --version 2>/dev/null || echo 0)"
remote="$(sed -n 's/^VERSION = "\([^"]*\)"/\1/p' "$tmp" | head -n1)"
[[ -n "$remote" ]] || { echo "无法读取远程版本。"; exit 1; }
[[ "$current" != "$remote" ]] || { echo "Agent 已是最新版本：$current"; exit 0; }
newest="$(printf '%s\n%s\n' "$current" "$remote" | sort -V | tail -n1)"
[[ "$newest" == "$remote" ]] || { echo "远程版本较旧，保留当前版本：$current"; exit 0; }
echo "更新 Agent：$current -> $remote"
bash "$tmp" update
EOF
chmod 755 "$UPDATE_APP"

cat > "$SERVICE" <<EOF
[Unit]
Description=Ejectors VPS Status Agent
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=$APP --loop
ExecStop=$APP --shutdown
Restart=always
RestartSec=10
TimeoutStopSec=12
NoNewPrivileges=true
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

cat > "$UPDATE_SERVICE" <<EOF
[Unit]
Description=Ejectors VPS Agent Auto Update
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$UPDATE_APP
EOF

cat > "$UPDATE_TIMER" <<'EOF'
[Unit]
Description=Check Ejectors VPS Agent updates daily

[Timer]
OnCalendar=*-*-* 04:00:00 Asia/Shanghai
Persistent=true
Unit=ejectors-vps-agent-update.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable ejectors-vps-agent.service
systemctl restart ejectors-vps-agent.service
systemctl enable --now ejectors-vps-agent-update.timer
sleep 2
systemctl --no-pager --full status ejectors-vps-agent.service || true
echo
echo "安装完成：状态数据默认每 10 秒上报一次。"
echo "自动更新：每天北京时间 04:00 检查。"
echo "卸载命令：sudo bash $0 uninstall"
