#!/usr/bin/env bash
set -euo pipefail

APP_NAME="宇宙监察委员会VPS管理局"
APP_DIR="/opt/universe-vps-manager"
CONFIG_FILE="$APP_DIR/config.json"
PY_FILE="$APP_DIR/vps_manager.py"
CRON_FILE="/etc/cron.d/universe-vps-manager"

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

install_deps() {
  echo "[1/6] 安装依赖..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y curl python3 procps iproute2 coreutils util-linux iputils-ping >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl python3 procps-ng iproute coreutils util-linux iputils >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl python3 procps-ng iproute coreutils util-linux iputils >/dev/null 2>&1 || true
  fi
}

clean_old_bots() {
  echo
  echo "[2/6] 旧机器人 / 旧定时任务清理"
  echo "会备份当前 crontab，只删除包含 bot/telegram/monitor/universe-monitor 等关键词的旧任务。"
  read -r -p "是否清理旧系统？[y/N]: " ans
  case "$ans" in
    y|Y)
      mkdir -p "$APP_DIR/backups"
      ts="$(date +%Y%m%d-%H%M%S)"
      crontab -l > "$APP_DIR/backups/crontab-$ts.bak" 2>/dev/null || true
      crontab -l 2>/dev/null | grep -viE 'bot\.py|telegram|universe-monitor|vps.*monitor|monitor\.sh|monitor\.py|status_bot|restart_bot' | crontab - 2>/dev/null || true

      find /etc/cron.d -maxdepth 1 -type f \( -iname '*bot*' -o -iname '*telegram*' -o -iname '*monitor*' \) ! -name 'universe-vps-manager' -delete 2>/dev/null || true

      pkill -f 'python3 .*bot' 2>/dev/null || true
      pkill -f 'python3 .*monitor' 2>/dev/null || true
      pkill -f 'telegram.*bot' 2>/dev/null || true

      echo "旧任务已清理，crontab 备份：$APP_DIR/backups/crontab-$ts.bak"
      ;;
    *) echo "跳过旧系统清理。" ;;
  esac
}

detect_singbox_port() {
  ss -lntp 2>/dev/null | awk '/sing-box/ {
    split($4,a,":");
    print a[length(a)];
    exit
  }'
}

write_config() {
  echo "[3/6] 写入配置..."

  BOT_TOKEN="$(read_required 'Bot Token: ')"
  echo
  CHAT_ID="$(read_required 'Chat ID: ')"
  echo
  SERVER_NAME="$(read_required '服务器名称: ')"
  echo

  read -r -p "检测服务名 [sing-box]: " SERVICE_NAME
  SERVICE_NAME="${SERVICE_NAME:-sing-box}"

  AUTO_PORT="$(detect_singbox_port || true)"
  if [ -n "$AUTO_PORT" ]; then
    read -r -p "检测端口 [自动识别 $AUTO_PORT，回车使用]: " CHECK_PORT
    CHECK_PORT="${CHECK_PORT:-$AUTO_PORT}"
  else
    read -r -p "检测端口 [可留空，只检测服务]: " CHECK_PORT
  fi

  echo
  echo "流量迁移："
  echo "  - 旧机器人已有总流量，就手动输入 GB。"
  echo "  - 不知道就直接回车，脚本会用当前网卡累计值作为初始总流量。"
  read -r -p "初始入站 GB [回车=自动]: " INIT_RX_GB
  read -r -p "初始出站 GB [回车=自动]: " INIT_TX_GB

  mkdir -p "$APP_DIR" "$APP_DIR/state" "$APP_DIR/logs"

  cat > "$CONFIG_FILE" <<EOF
{
  "bot_token": "$BOT_TOKEN",
  "chat_id": "$CHAT_ID",
  "server_name": "$SERVER_NAME",
  "service_name": "$SERVICE_NAME",
  "check_port": "$CHECK_PORT",
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
  "init_rx_gb": "$INIT_RX_GB",
  "init_tx_gb": "$INIT_TX_GB"
}
EOF
  chmod 600 "$CONFIG_FILE"

  # 修复 Windows/Xshell 终端可能把中文输入写成非 UTF-8 的问题。
  python3 - <<'PYFIX' >/dev/null 2>&1 || true
from pathlib import Path
import json

p = Path("/opt/universe-vps-manager/config.json")
raw = p.read_bytes()
for enc in ("utf-8", "gb18030", "gbk", "latin1"):
    try:
        data = json.loads(raw.decode(enc))
        p.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        break
    except Exception:
        pass
PYFIX
}

write_manager() {
  echo "[4/6] 写入主程序..."
  mkdir -p "$APP_DIR"
  cat > "$PY_FILE" <<'PYEOF'
#!/usr/bin/env python3
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

APP_DIR = Path("/opt/universe-vps-manager")
CONFIG_FILE = APP_DIR / "config.json"
STATE_DIR = APP_DIR / "state"
LOG_DIR = APP_DIR / "logs"

STATE_DIR.mkdir(parents=True, exist_ok=True)
LOG_DIR.mkdir(parents=True, exist_ok=True)


def load_config():
    if not CONFIG_FILE.exists():
        print("配置文件不存在，请先运行 install.sh")
        sys.exit(1)

    raw = CONFIG_FILE.read_bytes()
    last_error = None

    # 兼容 Xshell / Windows 终端把中文服务器名写成 GBK/GB18030 的情况。
    for enc in ("utf-8", "gb18030", "gbk", "latin1"):
        try:
            data = json.loads(raw.decode(enc))
            # 成功后立刻转回标准 UTF-8，之后不再炸。
            try:
                CONFIG_FILE.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
            except Exception:
                pass
            return data
        except Exception as e:
            last_error = e

    print("配置文件读取失败：", last_error)
    sys.exit(1)


CFG = load_config()


def run(cmd, timeout=20):
    try:
        p = subprocess.run(cmd, shell=True, text=True, capture_output=True, timeout=timeout)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"


def now_ts():
    return int(time.time())


def now_text():
    return time.strftime("%Y-%m-%d %H:%M:%S")


def tg_api(method, data):
    url = f"https://api.telegram.org/bot{CFG['bot_token']}/{method}"
    body = urllib.parse.urlencode(data).encode()
    try:
        with urllib.request.urlopen(url, data=body, timeout=25) as r:
            return json.loads(r.read().decode())
    except Exception as e:
        return {"ok": False, "error": str(e)}


def send_message(text, reply_markup=None):
    data = {
        "chat_id": CFG["chat_id"],
        "text": text,
    }
    if reply_markup:
        data["reply_markup"] = json.dumps(reply_markup, ensure_ascii=False)
    return tg_api("sendMessage", data)


def answer_callback(callback_id, text="已执行"):
    return tg_api("answerCallbackQuery", {"callback_query_id": callback_id, "text": text})


def state_path(name):
    return STATE_DIR / name


def log_event(text):
    with (LOG_DIR / "events.log").open("a", encoding="utf-8") as f:
        f.write(f"{now_text()} {text}\n")


def read_text_file(path, default=""):
    try:
        return Path(path).read_text(encoding="utf-8").strip()
    except Exception:
        return default


def write_text_file(path, value):
    Path(path).write_text(str(value), encoding="utf-8")


def read_int(path, default=0):
    try:
        return int(read_text_file(path, str(default)))
    except Exception:
        return default


def write_int(path, value):
    write_text_file(path, int(value))


def is_paused():
    return now_ts() < int(CFG.get("pause_until", 0))


def set_pause(minutes):
    CFG["pause_until"] = now_ts() + minutes * 60
    with CONFIG_FILE.open("w", encoding="utf-8") as f:
        json.dump(CFG, f, ensure_ascii=False, indent=2)


def clear_pause():
    CFG["pause_until"] = 0
    with CONFIG_FILE.open("w", encoding="utf-8") as f:
        json.dump(CFG, f, ensure_ascii=False, indent=2)


def can_alert(name, cooldown=None):
    cooldown = int(cooldown or CFG.get("alert_cooldown_sec", 600))
    p = state_path(f"alert_{name}")
    last = read_int(p, 0)
    now = now_ts()
    if now - last >= cooldown:
        write_int(p, now)
        return True
    return False


def main_keyboard():
    return {
        "inline_keyboard": [
            [
                {"text": "📊 状态刷新", "callback_data": "status"},
                {"text": "🧪 健康检查", "callback_data": "health"},
            ],
            [
                {"text": "📊 流量统计", "callback_data": "traffic"},
                {"text": "🌐 延迟测试", "callback_data": "latency"},
            ],
            [
                {"text": "📦 节点状态", "callback_data": "node"},
                {"text": "🔄 重启节点", "callback_data": "restart_singbox"},
            ],
            [
                {"text": "🔄 重启 Nginx", "callback_data": "restart_nginx"},
                {"text": "🧹 清理缓存", "callback_data": "clean"},
            ],
            [
                {"text": "🟡 暂停告警10分钟", "callback_data": "pause10"},
                {"text": "🟢 恢复告警", "callback_data": "resume"},
            ],
            [
                {"text": "📄 最近日志", "callback_data": "logs"},
                {"text": "⚠️ 重启 VPS", "callback_data": "reboot_ask"},
            ],
        ]
    }


def confirm_reboot_keyboard():
    return {
        "inline_keyboard": [
            [
                {"text": "确认重启 VPS", "callback_data": "reboot_now"},
                {"text": "取消", "callback_data": "status"},
            ]
        ]
    }


def get_iface():
    code, out, _ = run("ip route get 1.1.1.1 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++) if($i==\"dev\"){print $(i+1); exit}}'")
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
        return int(float(str(s).strip()) * 1024 * 1024 * 1024)
    except Exception:
        return None


def init_traffic():
    iface, raw_rx, raw_tx = get_raw_traffic()

    init_rx = gb_to_bytes(CFG.get("init_rx_gb", ""))
    init_tx = gb_to_bytes(CFG.get("init_tx_gb", ""))

    total_rx = init_rx if init_rx is not None else raw_rx
    total_tx = init_tx if init_tx is not None else raw_tx

    if not state_path("traffic_total_rx").exists():
        write_int(state_path("traffic_total_rx"), total_rx)
        write_int(state_path("traffic_total_tx"), total_tx)
        write_int(state_path("traffic_last_rx"), raw_rx)
        write_int(state_path("traffic_last_tx"), raw_tx)
        write_int(state_path("traffic_day_rx"), 0)
        write_int(state_path("traffic_day_tx"), 0)
        write_int(state_path("traffic_month_rx"), 0)
        write_int(state_path("traffic_month_tx"), 0)
        write_text_file(state_path("traffic_day"), time.strftime("%Y-%m-%d"))
        write_text_file(state_path("traffic_month"), time.strftime("%Y-%m"))


def update_traffic():
    init_traffic()
    iface, raw_rx, raw_tx = get_raw_traffic()

    last_rx = read_int(state_path("traffic_last_rx"), raw_rx)
    last_tx = read_int(state_path("traffic_last_tx"), raw_tx)

    delta_rx = raw_rx - last_rx if raw_rx >= last_rx else raw_rx
    delta_tx = raw_tx - last_tx if raw_tx >= last_tx else raw_tx
    delta_rx = max(0, delta_rx)
    delta_tx = max(0, delta_tx)

    today = time.strftime("%Y-%m-%d")
    month = time.strftime("%Y-%m")

    if read_text_file(state_path("traffic_day")) != today:
        write_int(state_path("traffic_day_rx"), 0)
        write_int(state_path("traffic_day_tx"), 0)
        write_text_file(state_path("traffic_day"), today)

    if read_text_file(state_path("traffic_month")) != month:
        write_int(state_path("traffic_month_rx"), 0)
        write_int(state_path("traffic_month_tx"), 0)
        write_text_file(state_path("traffic_month"), month)

    write_int(state_path("traffic_total_rx"), read_int(state_path("traffic_total_rx")) + delta_rx)
    write_int(state_path("traffic_total_tx"), read_int(state_path("traffic_total_tx")) + delta_tx)
    write_int(state_path("traffic_day_rx"), read_int(state_path("traffic_day_rx")) + delta_rx)
    write_int(state_path("traffic_day_tx"), read_int(state_path("traffic_day_tx")) + delta_tx)
    write_int(state_path("traffic_month_rx"), read_int(state_path("traffic_month_rx")) + delta_rx)
    write_int(state_path("traffic_month_tx"), read_int(state_path("traffic_month_tx")) + delta_tx)
    write_int(state_path("traffic_last_rx"), raw_rx)
    write_int(state_path("traffic_last_tx"), raw_tx)
    return iface


def traffic_text():
    update_traffic()
    total_rx = read_int(state_path("traffic_total_rx"))
    total_tx = read_int(state_path("traffic_total_tx"))
    day_rx = read_int(state_path("traffic_day_rx"))
    day_tx = read_int(state_path("traffic_day_tx"))
    month_rx = read_int(state_path("traffic_month_rx"))
    month_tx = read_int(state_path("traffic_month_tx"))

    return (
        f"📊 流量统计\n"
        f"[{CFG['server_name']}]\n\n"
        f"今日入站: {bytes_to_gb(day_rx):.2f} GB\n"
        f"今日出站: {bytes_to_gb(day_tx):.2f} GB\n"
        f"今日合计: {bytes_to_gb(day_rx + day_tx):.2f} GB\n\n"
        f"本月入站: {bytes_to_gb(month_rx):.2f} GB\n"
        f"本月出站: {bytes_to_gb(month_tx):.2f} GB\n"
        f"本月合计: {bytes_to_gb(month_rx + month_tx):.2f} GB\n\n"
        f"总入站: {bytes_to_gb(total_rx):.2f} GB\n"
        f"总出站: {bytes_to_gb(total_tx):.2f} GB\n"
        f"总计: {bytes_to_gb(total_rx + total_tx):.2f} GB"
    )


def cpu_percent():
    def read_cpu():
        with open("/proc/stat", "r", encoding="utf-8") as f:
            nums = list(map(int, f.readline().split()[1:8]))
            idle = nums[3] + nums[4]
            total = sum(nums)
            return idle, total

    i1, t1 = read_cpu()
    time.sleep(0.2)
    i2, t2 = read_cpu()

    if t2 <= t1:
        return 0.0
    return round((1 - (i2 - i1) / (t2 - t1)) * 100, 1)


def mem_info():
    data = {}
    with open("/proc/meminfo", "r", encoding="utf-8") as f:
        for line in f:
            k, v = line.split(":", 1)
            data[k] = int(v.strip().split()[0])

    mem_total = data.get("MemTotal", 0)
    mem_avail = data.get("MemAvailable", 0)
    mem_used = max(0, mem_total - mem_avail)

    swap_total = data.get("SwapTotal", 0)
    swap_free = data.get("SwapFree", 0)
    swap_used = max(0, swap_total - swap_free)

    return {
        "mem_total_mb": mem_total // 1024,
        "mem_used_mb": mem_used // 1024,
        "mem_avail_mb": mem_avail // 1024,
        "mem_pct": round(mem_used / mem_total * 100, 1) if mem_total else 0,
        "swap_total_mb": swap_total // 1024,
        "swap_used_mb": swap_used // 1024,
        "swap_pct": round(swap_used / swap_total * 100, 1) if swap_total else 0,
    }


def disk_info():
    du = shutil.disk_usage("/")
    return {
        "used_mb": du.used // 1024 // 1024,
        "total_mb": du.total // 1024 // 1024,
        "pct": round(du.used / du.total * 100, 1) if du.total else 0,
    }


def service_running():
    code, _, _ = run(f"systemctl is-active --quiet {CFG.get('service_name', 'sing-box')}", timeout=10)
    return code == 0


def port_listening():
    port = str(CFG.get("check_port", "")).strip()
    if not port:
        return True
    code, _, _ = run(f"ss -lnt | awk '{{print $4}}' | grep -Eq '(:|]){port}$'", timeout=8)
    return code == 0


def node_ok():
    return service_running() and port_listening()


def status_text():
    update_traffic()
    cpu = cpu_percent()
    mem = mem_info()
    disk = disk_info()
    node = "正常运行" if node_ok() else "异常"
    port = CFG.get("check_port") or "未设置"

    total_rx = read_int(state_path("traffic_total_rx"))
    total_tx = read_int(state_path("traffic_total_tx"))
    pause = ""
    if is_paused():
        remain = int(CFG.get("pause_until", 0)) - now_ts()
        pause = f"\n告警状态: 暂停中，还剩 {max(0, remain // 60)} 分钟\n"

    return (
        f"🌌 宇宙监察委员会VPS管理局\n"
        f"━━━━━━━━━━━━━━\n"
        f"[{CFG['server_name']}]\n"
        f"时间: {now_text()}\n"
        f"{pause}\n"
        f"CPU: {cpu}%\n"
        f"RAM: {mem['mem_pct']}% ({mem['mem_used_mb']}/{mem['mem_total_mb']}MB, 可用 {mem['mem_avail_mb']}MB)\n"
        f"SWAP: {mem['swap_pct']}% ({mem['swap_used_mb']}/{mem['swap_total_mb']}MB)\n"
        f"磁盘: {disk['pct']}% ({disk['used_mb']}/{disk['total_mb']}MB)\n\n"
        f"节点: {node}\n"
        f"端口: {port}\n\n"
        f"总入站: {bytes_to_gb(total_rx):.2f} GB\n"
        f"总出站: {bytes_to_gb(total_tx):.2f} GB\n"
        f"总计: {bytes_to_gb(total_rx + total_tx):.2f} GB"
    )


def health_text():
    cpu = cpu_percent()
    mem = mem_info()
    disk = disk_info()

    lines = [
        "🧪 系统健康检查",
        f"[{CFG['server_name']}]",
        "",
        "✔ sing-box运行正常" if service_running() else "✘ sing-box未运行",
        "✔ 端口监听正常" if port_listening() else f"✘ 端口 {CFG.get('check_port')} 未监听",
        "✔ CPU正常" if cpu < CFG.get("cpu_warn", 80) else f"⚠ CPU偏高: {cpu}%",
        "✔ RAM正常" if mem["mem_pct"] < CFG.get("ram_warn", 80) else f"⚠ RAM偏高: {mem['mem_pct']}%",
        "✔ SWAP正常" if mem["swap_pct"] < CFG.get("swap_warn", 30) else f"⚠ SWAP偏高: {mem['swap_pct']}%",
        "✔ 磁盘正常" if disk["pct"] < CFG.get("disk_warn", 90) else f"⚠ 磁盘偏高: {disk['pct']}%",
    ]
    return "\n".join(lines)


def latency_text():
    targets = [
        ("Cloudflare", "1.1.1.1"),
        ("GoogleDNS", "8.8.8.8"),
        ("Microsoft", "www.microsoft.com"),
    ]
    lines = ["🌐 网络延迟", f"[{CFG['server_name']}]", ""]
    for name, host in targets:
        code, out, _ = run(f"ping -c 3 -W 2 {host} 2>/dev/null | awk -F'/' '/rtt|round-trip/{{printf \"%.1f ms\", $5}}'", timeout=10)
        lines.append(f"{name}: {out if out else '失败'}")
    return "\n".join(lines)


def node_text():
    service = CFG.get("service_name", "sing-box")
    code, out, err = run(f"systemctl status {service} --no-pager | head -n 20", timeout=10)
    port = str(CFG.get("check_port", "")).strip()
    listen = ""
    if port:
        _, listen, _ = run(f"ss -lntp 2>/dev/null | grep -E ':{port}\\b' || true", timeout=5)
    return f"📦 节点状态\n\n{out or err}\n\n端口监听:\n{listen or '未检测到指定端口，或未设置端口检测'}"


def logs_text():
    service = CFG.get("service_name", "sing-box")
    code, out, err = run(f"journalctl -u {service} -n 30 --no-pager", timeout=10)
    text = out or err or "暂无日志"
    if len(text) > 3500:
        text = text[-3500:]
    return f"📄 最近日志\n\n{text}"


def clean_cache(manual=False):
    before = mem_info()
    run("sync", timeout=10)
    run("sh -c 'echo 3 > /proc/sys/vm/drop_caches'", timeout=10)
    run("journalctl --vacuum-time=3d", timeout=30)
    run("find /tmp -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true", timeout=30)
    after = mem_info()

    freed = after["mem_avail_mb"] - before["mem_avail_mb"]
    text = (
        f"🧹 缓存清理完成\n"
        f"[{CFG['server_name']}]\n\n"
        f"执行方式: {'手动' if manual else '自动'}\n"
        f"清理前可用: {before['mem_avail_mb']}MB\n"
        f"清理后可用: {after['mem_avail_mb']}MB\n"
        f"变化: {freed:+d}MB\n"
        f"时间: {now_text()}"
    )
    send_message(text)
    log_event(text.replace("\n", " | "))
    return text


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
                msg = (
                    f"⚠️ 检测到节点仍然异常\n"
                    f"[{CFG['server_name']}]\n\n"
                    f"10分钟重启锁生效中，暂不重复重启。\n"
                    f"剩余冷却: {remain // 60}分{remain % 60}秒"
                )
                send_message(msg)
                log_event(msg.replace("\n", " | "))
            return

        send_message(
            f"🚨 检测到节点掉线\n"
            f"[{CFG['server_name']}]\n\n"
            f"🔄 正在尝试自动重启节点..."
        )

    code, _, err = run(f"systemctl restart {service}", timeout=30)
    time.sleep(2)
    ok = node_ok()

    write_restart_lock()

    if ok:
        mem = mem_info()
        cpu = cpu_percent()
        msg = (
            f"✅ 节点恢复成功\n"
            f"[{CFG['server_name']}]\n\n"
            f"{service} 已正常运行\n"
            f"恢复时间: {now_text()}\n"
            f"CPU: {cpu}%\n"
            f"RAM: {mem['mem_pct']}%"
        )
        write_text_file(state_path("node_state"), "up")
        write_int(state_path("down_fail_count"), 0)
        send_message(msg)
        log_event(msg.replace("\n", " | "))
    else:
        _, status_out, status_err = run(f"systemctl is-active {service}; systemctl status {service} --no-pager | head -n 12", timeout=10)
        detail = status_out or status_err or err or "无详细输出"
        msg = (
            f"❌ 节点重启失败\n"
            f"[{CFG['server_name']}]\n\n"
            f"systemctl restart {service} 执行后仍未恢复。\n"
            f"请立即手动检查 VPS。\n\n"
            f"{detail}"
        )
        if len(msg) > 3500:
            msg = msg[:3500]
        write_text_file(state_path("node_state"), "down")
        send_message(msg)
        log_event(msg.replace("\n", " | "))


def alive_check():
    update_traffic()

    if is_paused():
        return

    ok = node_ok()
    old_state = read_text_file(state_path("node_state"), "unknown")

    if ok:
        write_int(state_path("down_fail_count"), 0)
        if old_state == "down":
            msg = f"✅ 节点恢复运行\n[{CFG['server_name']}]\n\n检测到节点已恢复。"
            send_message(msg)
            log_event(msg.replace("\n", " | "))
        write_text_file(state_path("node_state"), "up")
        return

    fail_count = read_int(state_path("down_fail_count"), 0) + 1
    write_int(state_path("down_fail_count"), fail_count)
    write_text_file(state_path("node_state"), "down")

    # v2.3：每分钟检测，检测到异常就进入自愈流程；重启锁防止风暴。
    try_restart_node(auto=True)


def resource_check():
    update_traffic()

    if is_paused():
        return

    cpu = cpu_percent()
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
        alerts.append(f"🚨 CPU严重: {cpu}%")
    elif cpu >= CFG.get("cpu_warn", 80):
        alerts.append(f"⚠ CPU偏高: {cpu}%")

    if disk["pct"] >= CFG.get("disk_warn", 90):
        alerts.append(f"⚠ 磁盘偏高: {disk['pct']}%")

    if alerts and can_alert("resource", CFG.get("alert_cooldown_sec", 600)):
        msg = f"🚨 资源告警\n[{CFG['server_name']}]\n\n" + "\n".join(alerts)
        send_message(msg)
        log_event(msg.replace("\n", " | "))


def report():
    send_message(status_text(), main_keyboard())


def handle_callback(callback):
    data = callback.get("data", "")
    cid = callback.get("id", "")
    answer_callback(cid)

    if data == "status":
        send_message(status_text(), main_keyboard())
    elif data == "health":
        send_message(health_text(), main_keyboard())
    elif data == "traffic":
        send_message(traffic_text(), main_keyboard())
    elif data == "latency":
        send_message(latency_text(), main_keyboard())
    elif data == "node":
        send_message(node_text(), main_keyboard())
    elif data == "logs":
        send_message(logs_text(), main_keyboard())
    elif data == "clean":
        clean_cache(manual=True)
    elif data == "restart_singbox":
        send_message(f"🔄 正在手动重启节点...\n[{CFG['server_name']}]")
        try_restart_node(auto=False)
    elif data == "restart_nginx":
        code, _, _ = run("systemctl list-unit-files nginx.service --no-legend 2>/dev/null | grep -q nginx")
        if code == 0:
            run("systemctl restart nginx", timeout=20)
            send_message("🔄 已重启 Nginx", main_keyboard())
        else:
            send_message("未检测到 nginx.service", main_keyboard())
    elif data == "pause10":
        set_pause(10)
        send_message(f"🟡 已暂停告警 10 分钟\n[{CFG['server_name']}]", main_keyboard())
    elif data == "resume":
        clear_pause()
        send_message(f"🟢 已恢复告警\n[{CFG['server_name']}]", main_keyboard())
    elif data == "reboot_ask":
        send_message("⚠️ 确认要重启 VPS 吗？节点会短暂中断。", confirm_reboot_keyboard())
    elif data == "reboot_now":
        send_message("⚠️ VPS 即将重启。")
        subprocess.Popen("sleep 2; reboot", shell=True)
    else:
        send_message("未知操作", main_keyboard())


def bot_poll():
    offset_file = state_path("telegram_offset")
    offset = read_int(offset_file, 0)

    params = urllib.parse.urlencode({"timeout": 20, "offset": offset})
    url = f"https://api.telegram.org/bot{CFG['bot_token']}/getUpdates?{params}"

    try:
        with urllib.request.urlopen(url, timeout=30) as r:
            resp = json.loads(r.read().decode())
    except Exception:
        return

    if not resp.get("ok"):
        return

    allowed_chat = str(CFG["chat_id"])

    for upd in resp.get("result", []):
        offset = max(offset, upd["update_id"] + 1)

        if "callback_query" in upd:
            cb = upd["callback_query"]
            msg = cb.get("message", {})
            chat_id = str(msg.get("chat", {}).get("id", ""))
            if chat_id == allowed_chat:
                handle_callback(cb)
            continue

        msg = upd.get("message", {})
        chat_id = str(msg.get("chat", {}).get("id", ""))
        text = (msg.get("text") or "").strip()

        if chat_id != allowed_chat:
            continue

        if text in ("/start", "/menu", "菜单"):
            send_message(f"🌌 宇宙监察委员会VPS管理局\n[{CFG['server_name']}]\n\n请选择操作：", main_keyboard())
        elif text in ("/status", "状态"):
            send_message(status_text(), main_keyboard())
        elif text in ("/health", "健康"):
            send_message(health_text(), main_keyboard())
        elif text in ("/traffic", "流量"):
            send_message(traffic_text(), main_keyboard())
        elif text in ("/latency", "延迟"):
            send_message(latency_text(), main_keyboard())
        elif text in ("/node", "节点"):
            send_message(node_text(), main_keyboard())
        elif text in ("/logs", "日志"):
            send_message(logs_text(), main_keyboard())
        elif text in ("/clean", "清理"):
            clean_cache(manual=True)
        elif text in ("/pause10", "暂停"):
            set_pause(10)
            send_message("🟡 已暂停告警 10 分钟", main_keyboard())
        elif text in ("/resume", "恢复"):
            clear_pause()
            send_message("🟢 已恢复告警", main_keyboard())
        else:
            send_message("发送 /start 打开控制面板。", main_keyboard())

    write_int(offset_file, offset)


def show_menu():
    send_message(f"🌌 宇宙监察委员会VPS管理局\n[{CFG['server_name']}]\n\n控制面板已就绪。", main_keyboard())


def main():
    if len(sys.argv) < 2:
        print("usage: vps_manager.py alive|resource|report|bot|menu|clean|status|init-traffic")
        return

    cmd = sys.argv[1]

    if cmd == "alive":
        alive_check()
    elif cmd == "resource":
        resource_check()
    elif cmd == "report":
        report()
    elif cmd == "bot":
        bot_poll()
    elif cmd == "menu":
        show_menu()
    elif cmd == "clean":
        clean_cache(manual=False)
    elif cmd == "status":
        print(status_text())
    elif cmd == "init-traffic":
        init_traffic()
        print("traffic initialized")
    else:
        print("unknown command")


if __name__ == "__main__":
    main()

PYEOF
  chmod +x "$PY_FILE"
}

install_cron() {
  echo "[5/6] 创建 cron 调度..."

  cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CRON_TZ=Asia/Shanghai

# Telegram 按钮 / 指令轮询：每分钟一次，不常驻内存
* * * * * root python3 $PY_FILE bot >/dev/null 2>&1

# 掉线检测：每分钟，异常则自动尝试重启 sing-box
* * * * * root python3 $PY_FILE alive >/dev/null 2>&1

# 资源检测：每 5 分钟，CPU/RAM/SWAP/Disk 异常立即通知
*/5 * * * * root python3 $PY_FILE resource >/dev/null 2>&1

# 无异常状态汇报：每小时一次
0 * * * * root python3 $PY_FILE report >/dev/null 2>&1

# 北京时间每天 04:00 自动清缓存
0 4 * * * root python3 $PY_FILE clean >/dev/null 2>&1
EOF

  chmod 644 "$CRON_FILE"
}

finish_install() {
  echo "[6/6] 初始化并发送面板..."
  python3 "$PY_FILE" init-traffic >/dev/null 2>&1 || true
  python3 "$PY_FILE" menu || true
  python3 "$PY_FILE" report || true

  echo
  echo "✅ 安装完成"
  echo "Telegram 发送 /start 打开控制面板。"
  echo "安装目录：$APP_DIR"
  echo "配置文件：$CONFIG_FILE"
  echo "cron 文件：$CRON_FILE"
}

main() {
  need_root
  echo "======================================"
  echo "🌌 宇宙监察委员会VPS管理局 v2.3-fixed standalone"
  echo "======================================"
  install_deps
  mkdir -p "$APP_DIR"
  clean_old_bots
  write_config
  write_manager
  install_cron
  finish_install
}

main "$@"
