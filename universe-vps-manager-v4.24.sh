#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/universe-vps-manager"
CONFIG_FILE="$APP_DIR/config.json"
PY_FILE="$APP_DIR/vps_manager.py"
CRON_FILE="/etc/cron.d/universe-vps-manager"
BOT_SERVICE="/etc/systemd/system/universe-vps-manager-bot.service"

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "请先切换 root：sudo -i"
    exit 1
  fi
}

read_required() {
  local prompt="$1"
  local val=""
  while true; do
    read -r -p "$prompt" val
    if [ -n "$val" ]; then
      printf "%s" "$val"
      return
    fi
    echo "不能为空。"
  done
}

clean_input() {
  printf "%s" "$1" | tr -d '\000-\010\013\014\016-\037\177'
}

install_deps() {
  echo "[1/6] 安装依赖..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y curl python3 procps iproute2 coreutils util-linux iputils-ping cron >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl python3 procps-ng iproute coreutils util-linux iputils cronie >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl python3 procps-ng iproute coreutils util-linux iputils cronie >/dev/null 2>&1 || true
  fi
}

clean_old() {
  echo "[2/6] 旧版本处理"
  mkdir -p "$APP_DIR/backups"

  echo "检测到可能存在旧版按钮服务 / cron。"
  echo "建议首次安装或覆盖安装时清理；如果只是看脚本，可选否。"
  read -r -p "是否停止并清理旧版监控服务？[Y/n]: " ans
  ans="${ans:-Y}"

  case "$ans" in
    y|Y)
      systemctl stop universe-vps-manager-bot.service >/dev/null 2>&1 || true
      pkill -f "/opt/universe-vps-manager/vps_manager.py" 2>/dev/null || true
      rm -f "$CRON_FILE"
      echo "已停止旧按钮服务并清理旧 cron。"
      ;;
    *)
      echo "已跳过旧版本清理。"
      echo "注意：如果旧服务仍在运行，可能会和新版抢 Telegram 更新。"
      ;;
  esac
}

detect_singbox_port() {
  ss -lntp 2>/dev/null | awk '/sing-box/ {
    split($4,a,":");
    print a[length(a)];
    exit
  }'
}

detect_singbox_ports() {
  ss -H -lntp 2>/dev/null | awk '/sing-box/ {
    addr=$4; port=addr; sub(/^.*:/, "", port)
    if (port !~ /^[0-9]+$/) next
    if (addr ~ /^127\./ || addr ~ /^\[::1\]/) local_ports[port]=1
    else public_ports[port]=1
  }
  END {
    for (p in public_ports) print "0:" p
    for (p in local_ports) print "1:" p
  }' | sort -t: -k1,1n -k2,2n | cut -d: -f2 | paste -sd, -
}

write_config() {
  echo "[3/6] 写入配置..."

  BOT_TOKEN="$(read_required 'Bot Token: ')"; echo
  CHAT_ID="$(read_required 'Chat ID: ')"; echo
  SERVER_NAME="$(read_required '服务器名称: ')"; echo

  read -r -p "检测服务名 [sing-box]: " SERVICE_NAME
  SERVICE_NAME="${SERVICE_NAME:-sing-box}"

  AUTO_PORTS="$(detect_singbox_ports || true)"
  if [ -n "$AUTO_PORTS" ]; then
    read -r -p "检测端口 [自动识别 $AUTO_PORTS，回车使用]: " CHECK_PORT
    CHECK_PORT="${CHECK_PORT:-$AUTO_PORTS}"
  else
    read -r -p "检测端口 [可留空，只检测服务]: " CHECK_PORT
  fi

  echo
  echo "流量迁移：旧机器人已有总流量就手动输入 GB；不知道就回车自动。"
  read -r -p "初始入站 GB [回车=自动]: " INIT_RX_GB
  read -r -p "初始出站 GB [回车=自动]: " INIT_TX_GB

  mkdir -p "$APP_DIR" "$APP_DIR/state" "$APP_DIR/logs"

  BOT_TOKEN="$(clean_input "$BOT_TOKEN")"
  CHAT_ID="$(clean_input "$CHAT_ID")"
  SERVER_NAME="$(clean_input "$SERVER_NAME")"
  SERVICE_NAME="$(clean_input "$SERVICE_NAME")"
  CHECK_PORT="$(clean_input "$CHECK_PORT")"
  INIT_RX_GB="$(clean_input "$INIT_RX_GB")"
  INIT_TX_GB="$(clean_input "$INIT_TX_GB")"

  export BOT_TOKEN CHAT_ID SERVER_NAME SERVICE_NAME CHECK_PORT INIT_RX_GB INIT_TX_GB CONFIG_FILE

  python3 - <<'PYCONF'
from pathlib import Path
import json, os, re

def safe_env(name, default=""):
    # 修复 Xshell/Windows 粘贴可能带来的非法 surrogate、控制字符、不可编码字符。
    v = os.environ.get(name, default)
    if v is None:
        v = ""
    v = str(v)

    # 删除 Python surrogate 区间字符，避免 write_text utf-8 报 surrogates not allowed。
    v = "".join(ch for ch in v if not (0xD800 <= ord(ch) <= 0xDFFF))

    # 删除控制字符，保留普通空格；Token/ChatID/端口都不该有换行控制符。
    v = "".join(ch for ch in v if ord(ch) >= 32 and ord(ch) != 127)

    # 最后兜底：丢弃一切 UTF-8 不可编码字符。
    v = v.encode("utf-8", "ignore").decode("utf-8", "ignore")
    return v.strip()

cfg = {
    "bot_token": safe_env("BOT_TOKEN"),
    "chat_id": safe_env("CHAT_ID"),
    "server_name": safe_env("SERVER_NAME"),
    "service_name": safe_env("SERVICE_NAME", "sing-box") or "sing-box",
    "check_port": safe_env("CHECK_PORT"),
    "ram_warn": 80,
    "ram_critical": 90,
    "swap_warn": 30,
    "swap_critical": 60,
    "cpu_warn": 80,
    "cpu_critical": 95,
    "disk_warn": 90,
    "alert_cooldown_sec": 600,
    "restart_lock_sec": 600,
    "pause_until": 0,
    "init_rx_gb": safe_env("INIT_RX_GB"),
    "init_tx_gb": safe_env("INIT_TX_GB"),
}

p = Path(os.environ["CONFIG_FILE"])
# ensure_ascii=True 进一步避免终端编码影响配置文件；程序读取后仍是正常中文。
p.write_text(json.dumps(cfg, ensure_ascii=True, indent=2), encoding="utf-8")
PYCONF

  chmod 600 "$CONFIG_FILE"
}

write_manager() {
  echo "[4/6] 写入主程序..."
  cat > "$PY_FILE" <<'PYEOF'
#!/usr/bin/env python3
import json
import re
import os
import sys
import time
import fcntl
import shutil
import subprocess
import urllib.parse
import urllib.request
import html
from pathlib import Path

APP_DIR = Path("/opt/universe-vps-manager")
CONFIG_FILE = APP_DIR / "config.json"
STATE_DIR = APP_DIR / "state"
LOG_DIR = APP_DIR / "logs"
STATE_DIR.mkdir(parents=True, exist_ok=True)
LOG_DIR.mkdir(parents=True, exist_ok=True)


def load_config():
    raw = CONFIG_FILE.read_bytes()
    last_error = None
    for enc in ("utf-8", "gb18030", "gbk", "latin1"):
        try:
            data = json.loads(raw.decode(enc))
            CONFIG_FILE.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
            return data
        except Exception as e:
            last_error = e
    try:
        cleaned = bytes(b for b in raw if b in (9, 10, 13) or b >= 32)
        text = cleaned.decode("utf-8", errors="ignore")
        text = "".join(ch for ch in text if not (0xD800 <= ord(ch) <= 0xDFFF))
        data = json.loads(text)
        CONFIG_FILE.write_text(json.dumps(data, ensure_ascii=True, indent=2), encoding="utf-8")
        return data
    except Exception:
        print("配置文件读取失败：", last_error)
        sys.exit(1)


CFG = load_config()


def state_path(name):
    return STATE_DIR / name


def now_ts():
    return int(time.time())


def now_text():
    return time.strftime("%Y-%m-%d %H:%M:%S")


def run(cmd, timeout=8):
    try:
        p = subprocess.run(cmd, shell=True, text=True, capture_output=True, timeout=timeout)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"


def read_text(path, default=""):
    try:
        return Path(path).read_text(encoding="utf-8").strip()
    except Exception:
        return default


def write_text(path, value):
    Path(path).write_text(str(value), encoding="utf-8")


def read_int(path, default=0):
    try:
        return int(read_text(path, str(default)))
    except Exception:
        return default


def write_int(path, value):
    write_text(path, int(value))


def log_event(text):
    try:
        with (LOG_DIR / "events.log").open("a", encoding="utf-8") as f:
            f.write(f"{now_text()} {text}\n")
    except Exception:
        pass


def tg_api(method, data, timeout=5):
    url = f"https://api.telegram.org/bot{CFG['bot_token']}/{method}"
    body = urllib.parse.urlencode(data).encode()
    try:
        with urllib.request.urlopen(url, data=body, timeout=timeout) as r:
            return json.loads(r.read().decode())
    except Exception as e:
        log_event(f"tg_api {method} error: {e}")
        return {"ok": False, "error": str(e)}


def send_message(text, reply_markup=None):
    data = {"chat_id": CFG["chat_id"], "text": text}
    if "<pre>" in text:
        data["parse_mode"] = "HTML"
    if reply_markup:
        data["reply_markup"] = json.dumps(reply_markup, ensure_ascii=False)
    return tg_api("sendMessage", data, timeout=6)


def answer_callback(callback_id, text="已收到"):
    if not callback_id:
        return
    tg_api("answerCallbackQuery", {"callback_query_id": callback_id, "text": text}, timeout=3)


def keyboard():
    return {
        "inline_keyboard": [
            [
                {"text": "📊 状态刷新", "callback_data": "status"},
                {"text": "🔄 重启节点", "callback_data": "restart_node"},
            ],
            [
                {"text": "🌐 重启Nginx", "callback_data": "restart_nginx"},
                {"text": "♻️ 重启VPS", "callback_data": "reboot_ask"},
            ],
        ]
    }


def keyboard():
    return {
        "inline_keyboard": [
            [
                {"text": "📊 状态刷新", "callback_data": "status"},
                {"text": "🔍 状态更新", "callback_data": "refresh_local"},
            ],
            [
                {"text": "🧹 手动清理缓存（释放文件缓存）", "callback_data": "clean"},
            ],
            [
                {"text": "🔄 重启节点", "callback_data": "restart_node"},
                {"text": "🌐 重启 Nginx", "callback_data": "restart_nginx"},
            ],
            [
                {"text": "♻️ 重启 VPS", "callback_data": "reboot_ask"},
            ],
        ]
    }


def send_panel():
    # /start 面板和“状态刷新”使用同一套完整状态模板。
    send_message(status_text(), keyboard())


def get_iface():
    code, out, _ = run("ip route get 1.1.1.1 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++) if($i==\"dev\"){print $(i+1); exit}}'", timeout=3)
    return out if code == 0 and out else "eth0"


def get_raw_traffic():
    iface = get_iface()
    base = Path("/sys/class/net") / iface / "statistics"
    try:
        rx = int((base / "rx_bytes").read_text().strip())
        tx = int((base / "tx_bytes").read_text().strip())
    except Exception:
        rx, tx = 0, 0
    return iface, rx, tx


def bytes_to_gb(v):
    return v / 1024 / 1024 / 1024


def gb_to_bytes(s):
    try:
        s = str(s).strip()
        if not s:
            return None
        return int(float(s) * 1024 * 1024 * 1024)
    except Exception:
        return None


def init_traffic():
    iface, raw_rx, raw_tx = get_raw_traffic()
    init_rx = gb_to_bytes(CFG.get("init_rx_gb", ""))
    init_tx = gb_to_bytes(CFG.get("init_tx_gb", ""))

    if not state_path("traffic_total_rx").exists():
        write_int(state_path("traffic_total_rx"), init_rx if init_rx is not None else raw_rx)
        write_int(state_path("traffic_total_tx"), init_tx if init_tx is not None else raw_tx)
        write_int(state_path("traffic_last_rx"), raw_rx)
        write_int(state_path("traffic_last_tx"), raw_tx)


def update_traffic():
    lock_path = state_path("traffic.lock")
    with lock_path.open("w") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        init_traffic()
        iface, raw_rx, raw_tx = get_raw_traffic()

        last_rx = read_int(state_path("traffic_last_rx"), raw_rx)
        last_tx = read_int(state_path("traffic_last_tx"), raw_tx)

        delta_rx = raw_rx - last_rx if raw_rx >= last_rx else raw_rx
        delta_tx = raw_tx - last_tx if raw_tx >= last_tx else raw_tx
        delta_rx = max(0, delta_rx)
        delta_tx = max(0, delta_tx)

        write_int(state_path("traffic_total_rx"), read_int(state_path("traffic_total_rx")) + delta_rx)
        write_int(state_path("traffic_total_tx"), read_int(state_path("traffic_total_tx")) + delta_tx)
        write_int(state_path("traffic_last_rx"), raw_rx)
        write_int(state_path("traffic_last_tx"), raw_tx)
        fcntl.flock(lf, fcntl.LOCK_UN)


def mem_info():
    data = {}
    with open("/proc/meminfo", "r", encoding="utf-8") as f:
        for line in f:
            k, v = line.split(":", 1)
            data[k] = int(v.strip().split()[0])

    mt = data.get("MemTotal", 0)
    ma = data.get("MemAvailable", 0)
    mu = max(0, mt - ma)

    st = data.get("SwapTotal", 0)
    sf = data.get("SwapFree", 0)
    su = max(0, st - sf)

    return {
        "mem_total_mb": mt // 1024,
        "mem_used_mb": mu // 1024,
        "mem_avail_mb": ma // 1024,
        "mem_pct": round(mu / mt * 100, 1) if mt else 0,
        "swap_total_mb": st // 1024,
        "swap_used_mb": su // 1024,
        "swap_pct": round(su / st * 100, 1) if st else 0,
    }


def detect_disk_path():
    configured = str(CFG.get("disk_path", "")).strip()
    if configured and Path(configured).exists():
        return configured
    db = Path("/etc/filebrowser/filebrowser.db")
    if db.exists():
        code, out, _ = run(f"filebrowser config cat --database {db}", timeout=3)
        if code == 0:
            for line in out.splitlines():
                if line.strip().startswith("Root:"):
                    root = line.split(":", 1)[1].strip()
                    if root and Path(root).exists():
                        return root
    return "/srv/filebrowser" if Path("/srv/filebrowser").exists() else "/"


def disk_info():
    path = detect_disk_path()
    du = shutil.disk_usage(path)
    return {
        "path": path,
        "used_gb": du.used / 1024 / 1024 / 1024,
        "total_gb": du.total / 1024 / 1024 / 1024,
        "pct": round(du.used / du.total * 100, 1) if du.total else 0,
    }


def disk_io_device():
    code, source, _ = run("findmnt -n -o SOURCE /", timeout=3)
    if code != 0 or not source.startswith("/dev/"):
        return ""
    code, parent, _ = run(f"lsblk -ndo PKNAME {source}", timeout=3)
    return parent.strip() if code == 0 and parent.strip() else Path(source).name


def disk_io_rates():
    device = disk_io_device()
    stat_file = Path("/sys/class/block") / device / "stat"
    if not device or not stat_file.exists():
        return 0.0, 0.0
    try:
        values = [int(value) for value in stat_file.read_text().split()]
        read_bytes = values[2] * 512
        write_bytes = values[6] * 512
    except Exception:
        return 0.0, 0.0
    now = now_ts()
    previous_at = read_int(state_path("disk_io_at"), 0)
    previous_read = read_int(state_path("disk_io_read"), read_bytes)
    previous_write = read_int(state_path("disk_io_write"), write_bytes)
    write_int(state_path("disk_io_at"), now)
    write_int(state_path("disk_io_read"), read_bytes)
    write_int(state_path("disk_io_write"), write_bytes)
    elapsed = now - previous_at
    if elapsed <= 0:
        return 0.0, 0.0
    return max(0.0, (read_bytes - previous_read) / elapsed), max(0.0, (write_bytes - previous_write) / elapsed)


def format_rate(value):
    if value >= 1024 * 1024:
        return f"{value / 1024 / 1024:.1f}MB/s"
    if value >= 1024:
        return f"{value / 1024:.1f}KB/s"
    return f"{value:.0f}B/s"


def cpu_cores():
    return os.cpu_count() or 1


def cpu_percent_fast():
    # 快速估算：用 1分钟负载 / 核心数。
    # 这个不是瞬时 CPU，但非常快，适合按钮秒回。
    try:
        load1 = float(Path("/proc/loadavg").read_text().split()[0])
        return round(min(100.0, load1 / cpu_cores() * 100), 1)
    except Exception:
        return 0.0


def cpu_sample():
    fields = Path("/proc/stat").read_text().splitlines()[0].split()[1:]
    values = [int(x) for x in fields]
    total = sum(values)
    idle = values[3] + (values[4] if len(values) > 4 else 0)
    return total, idle


def cpu_percent_fast():
    # Actual CPU utilization, sampled across a short interval.
    try:
        total1, idle1 = cpu_sample()
        time.sleep(1.0)
        total2, idle2 = cpu_sample()
        total_delta = total2 - total1
        idle_delta = idle2 - idle1
        if total_delta <= 0:
            return 0.0
        return round(max(0.0, min(100.0, (total_delta - idle_delta) / total_delta * 100)), 1)
    except Exception:
        return 0.0


def loadavg_1m():
    try:
        return float(Path("/proc/loadavg").read_text().split()[0])
    except Exception:
        return 0.0


def cpu_load_percent():
    return round(min(100.0, loadavg_1m() / cpu_cores() * 100), 1)


def detect_service_port():
    service = str(CFG.get("service_name", "sing-box")).strip()
    code, out, _ = run("ss -H -lntp", timeout=3)
    if code != 0:
        return ""
    for line in out.splitlines():
        if service not in line:
            continue
        fields = line.split()
        if len(fields) < 4:
            continue
        local = fields[3].rsplit(":", 1)[-1].rstrip("]")
        if local.isdigit() and 1 <= int(local) <= 65535:
            return local
    return ""


def refresh_local_state():
    detected_port = detect_service_port()
    previous_port = str(CFG.get("check_port", "")).strip()
    changed = []
    if detected_port and detected_port != previous_port:
        CFG["check_port"] = detected_port
        changed.append(f"检测端口：{previous_port or '未设置'} → {detected_port}")
    disk_path = detect_disk_path()
    if disk_path != str(CFG.get("disk_path", "")).strip():
        CFG["disk_path"] = disk_path
        changed.append(f"监控磁盘：{disk_path}")
    if changed:
        save_config()
    return changed


def detect_service_ports():
    service = str(CFG.get("service_name", "sing-box")).strip()
    code, out, _ = run("ss -H -lntp", timeout=3)
    if code != 0:
        return []
    public_ports, local_ports = set(), set()
    for line in out.splitlines():
        if service not in line:
            continue
        fields = line.split()
        if len(fields) < 4:
            continue
        address = fields[3]
        port = address.rsplit(":", 1)[-1].rstrip("]")
        if not port.isdigit() or not (1 <= int(port) <= 65535):
            continue
        if address.startswith("127.") or address.startswith("[::1]"):
            local_ports.add(port)
        else:
            public_ports.add(port)
    return sorted(public_ports, key=int) + sorted(local_ports, key=int)


def configured_ports():
    raw = str(CFG.get("check_port", "")).strip()
    return [p for p in raw.replace("，", ",").split(",") if p.strip().isdigit()]


def grpc_port_mapping():
    info = Path("/etc/sing-box/grpc-node.env")
    if not info.exists():
        return "", ""
    values = {}
    for line in info.read_text(errors="ignore").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip().strip("'")
    return values.get("GRPC_PORT", ""), values.get("GRPC_LOCAL_PORT", "")


def inbound_protocols():
    config = Path("/etc/sing-box/config.json")
    if not config.exists():
        return {}
    try:
        inbounds = json.loads(config.read_text(errors="ignore")).get("inbounds", [])
    except Exception:
        return {}
    result = {}
    for inbound in inbounds:
        port = str(inbound.get("listen_port", ""))
        if not port.isdigit():
            continue
        protocol = str(inbound.get("type", "sing-box")).upper()
        tls = inbound.get("tls") or {}
        transport = inbound.get("transport") or {}
        if isinstance(tls, dict) and (tls.get("reality") or {}).get("enabled"):
            protocol = "Reality"
        elif isinstance(transport, dict) and transport.get("type") == "grpc":
            protocol = "gRPC"
        result[port] = protocol
    return result


def nginx_public_ports():
    code, out, _ = run("ss -H -lntp", timeout=3)
    if code != 0:
        return set()
    ports = set()
    for line in out.splitlines():
        if "nginx" not in line:
            continue
        fields = line.split()
        if len(fields) < 4:
            continue
        address = fields[3]
        port = address.rsplit(":", 1)[-1].rstrip("]")
        if port.isdigit() and not address.startswith("127.") and not address.startswith("[::1]"):
            ports.add(port)
    return ports


def format_port_labels(port_map):
    items = []
    for port in sorted(port_map, key=lambda value: int(value)):
        labels = " / ".join(port_map[port])
        items.append(f"{port}（{labels}）")
    if not items:
        return "未设置"
    lines, pending = [], []
    for item in items:
        if len(item) > 20:
            if pending:
                lines.append("    ".join(pending))
                pending = []
            lines.append(item)
            continue
        pending.append(item)
        if len(pending) == 2:
            lines.append("    ".join(pending))
            pending = []
    if pending:
        lines.append("    ".join(pending))
    return "\n".join(lines)


def display_ports():
    grpc_public, grpc_local = grpc_port_mapping()
    protocols = inbound_protocols()
    port_map = {}
    def add(port, label):
        if port and port.isdigit():
            port_map.setdefault(port, [])
            if label not in port_map[port]:
                port_map[port].append(label)
    for port in nginx_public_ports():
        add(port, "Nginx")
    if singbox_status() not in (None, "未使用"):
        for port in configured_ports():
            public_port = grpc_public if grpc_public and port == grpc_local else port
            add(public_port, protocols.get(port, "sing-box"))
    for node in xray_nodes():
        if node["state"] == "正常":
            add(node["public_port"], node["protocol"])
    return format_port_labels(port_map)


def refresh_local_state():
    detected_ports = detect_service_ports()
    previous = ",".join(configured_ports())
    current = ",".join(detected_ports)
    changed = []
    if current != previous:
        CFG["check_port"] = current
        changed.append(f"检测端口：{previous or '未设置'} → {display_ports()}")
    disk_path = detect_disk_path()
    if disk_path != str(CFG.get("disk_path", "")).strip():
        CFG["disk_path"] = disk_path
        changed.append(f"监控磁盘：{disk_path}")
    if changed:
        save_config()
    return changed


def service_running():
    service = CFG.get("service_name", "sing-box")
    code, _, _ = run(f"systemctl is-active --quiet {service}", timeout=2)
    return code == 0


def port_listening():
    port = str(CFG.get("check_port", "")).strip()
    if not port:
        return True
    code, _, _ = run(f"ss -H -lnt 2>/dev/null | awk '{{print $4}}' | grep -Eq '(:|]){port}$'", timeout=2)
    return code == 0


def port_listening():
    required = set(configured_ports())
    if not required:
        return True
    code, out, _ = run("ss -H -lntp", timeout=3)
    if code != 0:
        return False
    listening = set()
    service = str(CFG.get("service_name", "sing-box")).strip()
    for line in out.splitlines():
        if service not in line:
            continue
        fields = line.split()
        if len(fields) >= 4:
            port = fields[3].rsplit(":", 1)[-1].rstrip("]")
            if port.isdigit():
                listening.add(port)
    return required.issubset(listening)


def node_ok():
    return singbox_status() == "正常"


def singbox_status():
    service = str(CFG.get("service_name", "sing-box")).strip() or "sing-box"
    unit_code, _, _ = run(f"systemctl cat {service}", timeout=3)
    if unit_code != 0:
        return None
    config = Path("/etc/sing-box/config.json")
    if not config.exists():
        return "未使用"
    try:
        inbounds = json.loads(config.read_text(errors="ignore")).get("inbounds", [])
    except Exception:
        return "异常"
    if not inbounds:
        return None
    if not service_running():
        return "断开"
    return "正常" if port_listening() else "异常"


def filebrowser_status():
    unit_code, _, _ = run("systemctl cat filebrowser.service", timeout=3)
    if unit_code != 0:
        return "未安装"
    fb_code, _, _ = run("systemctl is-active --quiet filebrowser", timeout=3)
    if fb_code != 0:
        return "已关闭"
    nginx_code, _, _ = run("systemctl is-active --quiet nginx", timeout=3)
    standalone_code, _, _ = run("systemctl is-active --quiet filebrowser-nginx", timeout=3)
    if nginx_code != 0 and standalone_code != 0:
        return "反代已关闭"
    db = Path("/etc/filebrowser/filebrowser.db")
    if db.exists():
        code, out, _ = run(f"filebrowser config cat --database {db}", timeout=3)
        if code == 0:
            for line in out.splitlines():
                if line.strip().startswith("Port:"):
                    port = line.split(":", 1)[1].strip()
                    if port.isdigit():
                        check, _, _ = run(f"curl -fsS -o /dev/null --max-time 3 http://127.0.0.1:{port}/", timeout=5)
                        if check != 0:
                            return "服务异常"
                    break
    return "正常运行"


XRAY_NODE_SPECS = (
    ("旧版 XHTTP", Path("/etc/xray-xhttp/node-info.env"), Path("/etc/xray-xhttp/config.json"), "xray-xhttp"),
    ("REALITY + XHTTP", Path("/etc/reality-xhttp/node-info.env"), Path("/etc/reality-xhttp/config.json"), "reality-xhttp"),
)


def read_env_file(path):
    values = {}
    if not path.exists():
        return values
    for line in path.read_text(errors="ignore").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip().strip("'").strip('"')
    return values


def xray_nodes():
    nodes = []
    labels = {"xhttp": "XHTTP", "splithttp": "XHTTP", "grpc": "gRPC", "ws": "WebSocket", "websocket": "WebSocket", "httpupgrade": "HTTPUpgrade", "tcp": "TCP", "raw": "TCP"}
    for kind, info_path, config_path, service in XRAY_NODE_SPECS:
        if not config_path.exists():
            continue
        info = read_env_file(info_path)
        try:
            inbound = json.loads(config_path.read_text(errors="ignore")).get("inbounds", [])[0]
        except Exception:
            continue
        port = str(inbound.get("port", "")).strip()
        if not port.isdigit():
            continue
        stream = inbound.get("streamSettings") or {}
        network = str(stream.get("network", "")).strip().lower()
        protocol = labels.get(network, network.upper() if network else str(inbound.get("protocol", "Xray")).upper())
        if str(stream.get("security", "")).strip().lower() == "reality":
            protocol = f"{protocol} + REALITY"
        link = str(info.get("LINK", ""))
        matched = re.search(r"@[^:?#]+:(\d+)", link)
        public_port = matched.group(1) if matched else str(info.get("PORT") or port)
        active, _, _ = run(f"systemctl is-active --quiet {service}", timeout=3)
        code, out, _ = run("ss -H -lntp", timeout=3)
        listening = code == 0 and any(f":{port}" in line and "xray" in line for line in out.splitlines())
        state = "正常" if active == 0 and listening else ("断开" if active != 0 else "异常")
        nodes.append({"kind": kind, "port": port, "public_port": public_port, "protocol": protocol, "state": state, "service": service})
    return nodes


def xhttp_status():
    nodes = xray_nodes()
    if not nodes:
        return None, ""
    active_nodes = [node for node in nodes if node["state"] == "正常"]
    if active_nodes:
        return "正常", ",".join(node["port"] for node in active_nodes)
    return nodes[0]["state"], ",".join(node["port"] for node in nodes)


def xhttp_health_check():
    state, _ = xhttp_status()
    previous = read_text(state_path("xhttp_state"), "")
    write_text(state_path("xhttp_state"), state)
    if state in (None, "正常"):
        return
    if state != previous and can_alert("xhttp", CFG.get("alert_cooldown_sec", 600)):
        send_message(f"🚨 Xray 节点异常\n[{CFG['server_name']}]\n\n当前状态：{state}\n请检查 xray-xhttp 服务与本机监听端口。")


def alert_status_text():
    if is_paused():
        remain = int(CFG.get("pause_until", 0)) - now_ts()
        return f"暂停中（还剩 {max(0, remain // 60)} 分钟）"
    return "开启"


def status_text():
    refresh_local_state()
    update_traffic()

    cpu = cpu_percent_fast()
    mem = mem_info()
    disk = disk_info()
    io_read, io_write = disk_io_rates()
    singbox = singbox_status()
    filebrowser = filebrowser_status()
    xray, _ = xhttp_status()
    port = display_ports()
    service_lines = ""
    if singbox is not None:
        service_lines += f"singbox：{singbox}\n"
    if xray is not None:
        service_lines += f"xray：{xray}\n"

    total_rx = read_int(state_path("traffic_total_rx"))
    total_tx = read_int(state_path("traffic_total_tx"))

    safe_server_name = html.escape(str(CFG["server_name"]), quote=False)
    safe_ports = html.escape(port)
    return (
        f"🌌 宇宙监察委员会VPS管理局\n"
        f"━━━━━━━━━━━━━━\n"
        f"[{safe_server_name}]\n"
        f"时间: {now_text()}\n"
        f"告警状态: {alert_status_text()}\n\n"
        f"CPU使用率: {cpu}%（{cpu_cores()}核，1分钟负载 {loadavg_1m():.2f}）\n"
        f"RAM: {mem['mem_pct']}% ({mem['mem_used_mb']}/{mem['mem_total_mb']}MB, 可用 {mem['mem_avail_mb']}MB)\n"
        f"SWAP: {mem['swap_pct']}% ({mem['swap_used_mb']}/{mem['swap_total_mb']}MB)\n"
        f"磁盘: {disk['pct']}% ({disk['used_gb']:.1f}/{disk['total_gb']:.1f}GB)\n\n"
        f"磁盘 I/O: 读 {format_rate(io_read)} / 写 {format_rate(io_write)}\n\n"
        f"{service_lines}"
        f"网盘: {filebrowser}\n"
        f"端口:\n<pre>{safe_ports}</pre>\n"
        f"总入站: {bytes_to_gb(total_rx):.2f} GB\n"
        f"总出站: {bytes_to_gb(total_tx):.2f} GB\n"
        f"总计: {bytes_to_gb(total_rx + total_tx):.2f} GB"
    )


def can_alert(name, cooldown=None):
    cooldown = int(cooldown or CFG.get("alert_cooldown_sec", 600))
    p = state_path(f"alert_{name}")
    last = read_int(p, 0)
    now = now_ts()
    if now - last >= cooldown:
        write_int(p, now)
        return True
    return False


def is_paused():
    return now_ts() < int(CFG.get("pause_until", 0))


def save_config():
    CONFIG_FILE.write_text(json.dumps(CFG, ensure_ascii=False, indent=2), encoding="utf-8")


def set_pause(minutes):
    CFG["pause_until"] = now_ts() + minutes * 60
    save_config()


def clear_pause():
    CFG["pause_until"] = 0
    save_config()


def restart_lock_active():
    last = read_int(state_path("restart_lock"), 0)
    lock_sec = int(CFG.get("restart_lock_sec", 600))
    remain = lock_sec - (now_ts() - last)
    return remain > 0, max(0, remain)


def write_restart_lock():
    write_int(state_path("restart_lock"), now_ts())


def try_restart_node(auto=True):
    service = CFG.get("service_name", "sing-box")

    if auto:
        locked, remain = restart_lock_active()
        if locked:
            if can_alert("restart_locked", CFG.get("alert_cooldown_sec", 600)):
                send_message(
                    f"⚠️ 检测到节点仍然异常\n"
                    f"[{CFG['server_name']}]\n\n"
                    f"重启锁生效中，暂不重复重启。\n"
                    f"剩余冷却: {remain // 60}分{remain % 60}秒"
                )
            return

        send_message(
            f"🚨 检测到节点掉线\n"
            f"[{CFG['server_name']}]\n\n"
            f"🔄 正在尝试自动重启节点..."
        )

    run(f"systemctl restart {service}", timeout=20)
    time.sleep(1)
    ok = node_ok()
    write_restart_lock()

    if ok:
        send_message(f"✅ 节点恢复成功\n[{CFG['server_name']}]\n\n{service} 已正常运行")
        write_int(state_path("down_fail_count"), 0)
    else:
        send_message(f"❌ 节点重启失败\n[{CFG['server_name']}]\n\n请手动检查 VPS。")


def clean_cache(manual=False):
    before = mem_info()
    run("sync", timeout=5)
    run("sh -c 'echo 3 > /proc/sys/vm/drop_caches'", timeout=5)
    run("journalctl --vacuum-time=3d >/dev/null 2>&1", timeout=10)
    after = mem_info()

    send_message(
        f"🧹 缓存清理完成\n"
        f"[{CFG['server_name']}]\n\n"
        f"执行方式: {'手动' if manual else '自动'}\n"
        f"清理前可用: {before['mem_avail_mb']}MB\n"
        f"清理后可用: {after['mem_avail_mb']}MB\n"
        f"变化: {after['mem_avail_mb'] - before['mem_avail_mb']:+d}MB\n"
        f"时间: {now_text()}"
    )


def alive_check():
    update_traffic()
    if is_paused():
        return

    xhttp_health_check()

    singbox = singbox_status()
    if singbox is None:
        return

    if singbox == "正常":
        write_int(state_path("down_fail_count"), 0)
        write_text(state_path("node_state"), "up")
        return

    write_int(state_path("down_fail_count"), read_int(state_path("down_fail_count"), 0) + 1)
    write_text(state_path("node_state"), "down")
    try_restart_node(auto=True)


def resource_check():
    update_traffic()
    if is_paused():
        return

    # Alert only on sustained CPU pressure, not a short sampling spike.
    cpu = cpu_load_percent()
    mem = mem_info()
    disk = disk_info()

    alerts = []

    if mem["mem_pct"] >= CFG.get("ram_critical", 90):
        alerts.append(f"🚨 RAM严重: {mem['mem_pct']}%")
    elif mem["mem_pct"] >= CFG.get("ram_warn", 80):
        alerts.append(f"⚠ RAM偏高: {mem['mem_pct']}%")

    if mem["swap_pct"] >= CFG.get("swap_critical", 60):
        alerts.append(f"🚨 SWAP严重: {mem['swap_pct']}%")
    elif mem["swap_pct"] >= CFG.get("swap_warn", 30):
        alerts.append(f"⚠ SWAP偏高: {mem['swap_pct']}%")

    if cpu >= CFG.get("cpu_critical", 95):
        alerts.append(f"🚨 CPU负载严重: {cpu}%")
    elif cpu >= CFG.get("cpu_warn", 80):
        alerts.append(f"⚠ CPU负载偏高: {cpu}%")

    if disk["pct"] >= CFG.get("disk_warn", 90):
        alerts.append(f"⚠ 磁盘偏高: {disk['pct']}%")

    if alerts and can_alert("resource", CFG.get("alert_cooldown_sec", 600)):
        send_message(f"🚨 资源告警\n[{CFG['server_name']}]\n\n" + "\n".join(alerts))


def report():
    send_message(status_text(), keyboard())


def sync_updates():
    url = f"https://api.telegram.org/bot{CFG['bot_token']}/getUpdates?timeout=0&limit=100"
    try:
        with urllib.request.urlopen(url, timeout=5) as r:
            resp = json.loads(r.read().decode())
        updates = resp.get("result", []) if resp.get("ok") else []
        if updates:
            write_int(state_path("telegram_offset"), max(u.get("update_id", 0) for u in updates) + 1)
    except Exception:
        pass


def handle_callback(cb):
    data = cb.get("data", "")
    cid = cb.get("id", "")
    answer_callback(cid, "已收到")

    if data == "status":
        send_message(status_text(), keyboard())
    elif data == "refresh_local":
        changes = refresh_local_state()
        detail = "\n".join(changes) if changes else "配置已是本机最新状态。"
        send_message(f"🔍 本机状态已刷新\n[{CFG['server_name']}]\n\n{detail}\n\n" + status_text(), keyboard())
    elif data == "restart_node":
        send_message(f"🔄 正在重启节点...\n[{CFG['server_name']}]")
        try_restart_node(auto=False)
    elif data == "restart_nginx":
        send_message(f"🌐 正在重启 Nginx...\n[{CFG['server_name']}]")
        code, _, _ = run("systemctl list-unit-files nginx.service --no-legend 2>/dev/null | grep -q nginx", timeout=4)
        if code == 0:
            run("systemctl restart nginx", timeout=15)
            send_message("🌐 Nginx 已重启", keyboard())
        else:
            send_message("未检测到 nginx.service", keyboard())
    elif data == "reboot_ask":
        send_message("⚠️ 确认重启 VPS 请发送：确认重启VPS", keyboard())
    elif data == "clean":
        send_message(f"🧹 正在清理缓存...\n[{CFG['server_name']}]")
        clean_cache(manual=True)
    else:
        send_panel()


def handle_text(text):
    if text in ("/start", "/menu", "菜单"):
        send_panel()
    elif text in ("/status", "状态", "状态刷新"):
        send_message(status_text(), keyboard())
    elif text in ("/clean", "清理", "清理缓存"):
        clean_cache(manual=True)
    elif text in ("/pause10", "暂停"):
        set_pause(10)
        send_message(f"🟡 已暂停告警 10 分钟\n[{CFG['server_name']}]", keyboard())
    elif text in ("/resume", "恢复"):
        clear_pause()
        send_message(f"🟢 已恢复告警\n[{CFG['server_name']}]", keyboard())
    elif text in ("/ping", "ping"):
        send_message("pong")
    elif text == "确认重启VPS":
        send_message("⚠️ VPS 即将重启。")
        subprocess.Popen("sleep 2; reboot", shell=True)
    else:
        send_message("发送 /start 打开控制面板。", keyboard())


def bot_poll():
    offset = read_int(state_path("telegram_offset"), 0)
    params = urllib.parse.urlencode({"timeout": 0, "offset": offset, "limit": 5})
    url = f"https://api.telegram.org/bot{CFG['bot_token']}/getUpdates?{params}"

    try:
        with urllib.request.urlopen(url, timeout=4) as r:
            resp = json.loads(r.read().decode())
    except Exception:
        time.sleep(0.5)
        return

    if not resp.get("ok"):
        time.sleep(0.5)
        return

    allowed = str(CFG["chat_id"])

    for upd in resp.get("result", []):
        offset = max(offset, upd["update_id"] + 1)

        if "callback_query" in upd:
            cb = upd["callback_query"]
            msg = cb.get("message", {})
            chat_id = str(msg.get("chat", {}).get("id", ""))
            if chat_id == allowed:
                handle_callback(cb)
            continue

        msg = upd.get("message", {})
        chat_id = str(msg.get("chat", {}).get("id", ""))
        text = (msg.get("text") or "").strip()
        if chat_id == allowed:
            handle_text(text)

    write_int(state_path("telegram_offset"), offset)
    time.sleep(0.25)


def bot_loop():
    sync_updates()
    while True:
        try:
            bot_poll()
        except Exception as e:
            log_event(f"bot-loop error: {e}")
            time.sleep(1)


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "help"

    if cmd == "alive":
        alive_check()
    elif cmd == "resource":
        resource_check()
    elif cmd == "report":
        report()
    elif cmd == "clean":
        clean_cache(manual=False)
    elif cmd == "bot-loop":
        bot_loop()
    elif cmd == "bot":
        bot_poll()
    elif cmd == "sync-updates":
        sync_updates()
    elif cmd == "menu":
        send_panel()
    elif cmd == "status":
        print(status_text())
    elif cmd == "init-traffic":
        init_traffic()
    else:
        print("usage: vps_manager.py alive|resource|report|clean|bot-loop|bot|sync-updates|menu|status|init-traffic")


if __name__ == "__main__":
    main()

PYEOF
  chmod +x "$PY_FILE"
}

start_cron_service() {
  local service

  for service in cron crond; do
    if systemctl cat "${service}.service" >/dev/null 2>&1; then
      echo "启用并启动 ${service}.service..."
      if systemctl enable --now "${service}.service" \
        && systemctl is-active --quiet "${service}.service"; then
        echo "${service}.service 已运行。"
        return 0
      fi
    fi
  done

  return 1
}

install_cron_package() {
  echo "未检测到 cron 服务，正在安装..."

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y cron
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y cronie
  elif command -v yum >/dev/null 2>&1; then
    yum install -y cronie
  else
    echo "错误：未识别的软件包管理器，无法自动安装 cron。"
    return 1
  fi
}

ensure_cron_service() {
  if start_cron_service; then
    return 0
  fi

  install_cron_package

  if start_cron_service; then
    return 0
  fi

  echo "错误：cron 已安装但无法启动（cron.service / crond.service）。"
  return 1
}

install_cron() {
  echo "[5/6] 创建 cron 调度..."
  cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CRON_TZ=Asia/Shanghai

# 掉线检测：每分钟
* * * * * root python3 $PY_FILE alive >/dev/null 2>&1

# 资源检测：每5分钟
*/5 * * * * root python3 $PY_FILE resource >/dev/null 2>&1

# 无异常状态汇报：每小时
0 * * * * root python3 $PY_FILE report >/dev/null 2>&1

# 北京时间每天04:00清缓存
EOF
  chmod 644 "$CRON_FILE"
  ensure_cron_service
}

install_bot_service() {
  echo "[6/6] 创建按钮服务..."
  cat > "$BOT_SERVICE" <<EOF
[Unit]
Description=Universe VPS Manager Telegram Bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $PY_FILE bot-loop
Restart=always
RestartSec=3
WorkingDirectory=$APP_DIR

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable universe-vps-manager-bot.service >/dev/null 2>&1 || true
  python3 "$PY_FILE" init-traffic >/dev/null 2>&1 || true
  python3 "$PY_FILE" sync-updates >/dev/null 2>&1 || true
  systemctl restart universe-vps-manager-bot.service
  python3 "$PY_FILE" menu || true

  echo
  echo "✅ 安装完成"
  echo "版本：宇宙监察委员会VPS管理局 v4.24"
  echo "安装目录：$APP_DIR"
  echo "按钮服务：universe-vps-manager-bot.service"
  echo "运行模式：精简消息内按钮，监控使用 cron"
}

main() {
  need_root
  echo "======================================"
  echo "宇宙监察委员会VPS管理局 v4.14"
  echo "======================================"
  install_deps
  clean_old
  write_config
  write_manager
  install_cron
  install_bot_service
}

main "$@"
