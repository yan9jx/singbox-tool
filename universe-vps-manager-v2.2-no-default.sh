#!/usr/bin/env bash
set -euo pipefail

APP_NAME="宇宙监察委员会VPS管理局"
APP_DIR="/opt/universe-vps-manager"
CONFIG_FILE="$APP_DIR/config.json"
PY_FILE="$APP_DIR/vps_manager.py"
CRON_FILE="/etc/cron.d/universe-vps-manager"
LOG_DIR="$APP_DIR/logs"

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 运行：sudo -i"
    exit 1
  fi
}

install_deps() {
  echo "[1] 安装依赖..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y curl python3 procps iproute2 coreutils util-linux >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl python3 procps-ng iproute coreutils util-linux >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl python3 procps-ng iproute coreutils util-linux >/dev/null 2>&1 || true
  fi
}

clean_old_bots() {
  echo
  echo "是否清理旧 Telegram 机器人 / 旧监控定时任务？"
  echo "会备份 crontab，只删除包含 bot/telegram/monitor/universe-monitor 等关键词的旧任务。"
  read -r -p "清理旧系统？[y/N]: " ans
  case "$ans" in
    y|Y)
      ts="$(date +%Y%m%d-%H%M%S)"
      mkdir -p "$APP_DIR/backups"
      crontab -l > "$APP_DIR/backups/crontab-$ts.bak" 2>/dev/null || true
      crontab -l 2>/dev/null | grep -viE 'bot\.py|telegram|universe-monitor|vps.*monitor|monitor\.sh|monitor\.py|status_bot|restart_bot' | crontab - 2>/dev/null || true

      # 删除旧 cron.d 残留，但不删除本项目
      find /etc/cron.d -maxdepth 1 -type f \( -iname '*bot*' -o -iname '*telegram*' -o -iname '*monitor*' \) ! -name 'universe-vps-manager' -delete 2>/dev/null || true

      # 停止常见旧机器人进程，尽量不碰系统服务
      pkill -f 'python3 .*bot' 2>/dev/null || true
      pkill -f 'python3 .*monitor' 2>/dev/null || true
      pkill -f 'telegram.*bot' 2>/dev/null || true

      echo "旧定时任务已清理，crontab 备份在：$APP_DIR/backups/crontab-$ts.bak"
      ;;
    *) echo "跳过旧系统清理。" ;;
  esac
}

write_python() {
  mkdir -p "$APP_DIR" "$LOG_DIR"
  cat > "$PY_FILE" <<'PY'
#!/usr/bin/env python3
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

APP_DIR = Path("/opt/universe-vps-manager")
STATE_DIR = APP_DIR / "state"
LOG_DIR = APP_DIR / "logs"
CONFIG_FILE = APP_DIR / "config.json"

STATE_DIR.mkdir(parents=True, exist_ok=True)
LOG_DIR.mkdir(parents=True, exist_ok=True)


def load_config():
    if not CONFIG_FILE.exists():
        print("未找到配置，请先安装。")
        sys.exit(1)
    with CONFIG_FILE.open("r", encoding="utf-8") as f:
        return json.load(f)


CFG = load_config()


def run(cmd, timeout=15):
    try:
        p = subprocess.run(cmd, shell=True, text=True, capture_output=True, timeout=timeout)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"


def tg_api(method, data):
    token = CFG["bot_token"]
    url = f"https://api.telegram.org/bot{token}/{method}"
    body = urllib.parse.urlencode(data).encode()
    try:
        with urllib.request.urlopen(url, data=body, timeout=20) as r:
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


def bytes_to_gb(v):
    return v / 1024 / 1024 / 1024


def get_iface():
    code, out, _ = run("ip route get 1.1.1.1 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++) if($i==\"dev\"){print $(i+1); exit}}'")
    return out.strip() if code == 0 and out.strip() else "eth0"


def read_counter(path):
    try:
        return int(Path(path).read_text().strip())
    except Exception:
        return 0


def get_raw_traffic():
    iface = get_iface()
    base = Path("/sys/class/net") / iface / "statistics"
    rx = read_counter(base / "rx_bytes")
    tx = read_counter(base / "tx_bytes")
    return iface, rx, tx


def traffic_state_file(name):
    return STATE_DIR / name


def read_int_file(path, default=0):
    try:
        return int(Path(path).read_text().strip())
    except Exception:
        return default


def write_int_file(path, value):
    Path(path).write_text(str(int(value)), encoding="utf-8")


def init_traffic_if_needed(use_current=True):
    iface, rx, tx = get_raw_traffic()
    if not (traffic_state_file("traffic_total_rx").exists() and traffic_state_file("traffic_total_tx").exists()):
        write_int_file(traffic_state_file("traffic_total_rx"), rx if use_current else 0)
        write_int_file(traffic_state_file("traffic_total_tx"), tx if use_current else 0)
        write_int_file(traffic_state_file("traffic_last_rx"), rx)
        write_int_file(traffic_state_file("traffic_last_tx"), tx)
        write_int_file(traffic_state_file("traffic_month_rx"), 0)
        write_int_file(traffic_state_file("traffic_month_tx"), 0)
        write_int_file(traffic_state_file("traffic_day_rx"), 0)
        write_int_file(traffic_state_file("traffic_day_tx"), 0)
        Path(traffic_state_file("traffic_day")).write_text(time.strftime("%Y-%m-%d"), encoding="utf-8")
        Path(traffic_state_file("traffic_month")).write_text(time.strftime("%Y-%m"), encoding="utf-8")


def update_traffic():
    init_traffic_if_needed(use_current=False)
    iface, rx, tx = get_raw_traffic()

    last_rx = read_int_file(traffic_state_file("traffic_last_rx"), rx)
    last_tx = read_int_file(traffic_state_file("traffic_last_tx"), tx)

    # 网卡计数重置或系统重启时，当前值小于上次值，按当前值作为新增。
    delta_rx = rx - last_rx if rx >= last_rx else rx
    delta_tx = tx - last_tx if tx >= last_tx else tx

    total_rx = read_int_file(traffic_state_file("traffic_total_rx")) + max(0, delta_rx)
    total_tx = read_int_file(traffic_state_file("traffic_total_tx")) + max(0, delta_tx)

    today = time.strftime("%Y-%m-%d")
    month = time.strftime("%Y-%m")

    day_file = traffic_state_file("traffic_day")
    month_file = traffic_state_file("traffic_month")

    if not day_file.exists() or day_file.read_text().strip() != today:
        write_int_file(traffic_state_file("traffic_day_rx"), 0)
        write_int_file(traffic_state_file("traffic_day_tx"), 0)
        day_file.write_text(today, encoding="utf-8")

    if not month_file.exists() or month_file.read_text().strip() != month:
        write_int_file(traffic_state_file("traffic_month_rx"), 0)
        write_int_file(traffic_state_file("traffic_month_tx"), 0)
        month_file.write_text(month, encoding="utf-8")

    day_rx = read_int_file(traffic_state_file("traffic_day_rx")) + max(0, delta_rx)
    day_tx = read_int_file(traffic_state_file("traffic_day_tx")) + max(0, delta_tx)
    month_rx = read_int_file(traffic_state_file("traffic_month_rx")) + max(0, delta_rx)
    month_tx = read_int_file(traffic_state_file("traffic_month_tx")) + max(0, delta_tx)

    write_int_file(traffic_state_file("traffic_total_rx"), total_rx)
    write_int_file(traffic_state_file("traffic_total_tx"), total_tx)
    write_int_file(traffic_state_file("traffic_day_rx"), day_rx)
    write_int_file(traffic_state_file("traffic_day_tx"), day_tx)
    write_int_file(traffic_state_file("traffic_month_rx"), month_rx)
    write_int_file(traffic_state_file("traffic_month_tx"), month_tx)
    write_int_file(traffic_state_file("traffic_last_rx"), rx)
    write_int_file(traffic_state_file("traffic_last_tx"), tx)

    return iface


def traffic_text():
    update_traffic()
    total_rx = read_int_file(traffic_state_file("traffic_total_rx"))
    total_tx = read_int_file(traffic_state_file("traffic_total_tx"))
    day_rx = read_int_file(traffic_state_file("traffic_day_rx"))
    day_tx = read_int_file(traffic_state_file("traffic_day_tx"))
    month_rx = read_int_file(traffic_state_file("traffic_month_rx"))
    month_tx = read_int_file(traffic_state_file("traffic_month_tx"))

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
        f"总合计: {bytes_to_gb(total_rx + total_tx):.2f} GB"
    )


def cpu_percent():
    def read_cpu():
        with open("/proc/stat", "r", encoding="utf-8") as f:
            parts = f.readline().split()[1:]
            nums = list(map(int, parts[:8]))
            idle = nums[3] + nums[4]
            total = sum(nums)
            return idle, total
    i1, t1 = read_cpu()
    time.sleep(0.2)
    i2, t2 = read_cpu()
    dt = t2 - t1
    di = i2 - i1
    if dt <= 0:
        return 0.0
    return round((1 - di / dt) * 100, 1)


def mem_info():
    data = {}
    with open("/proc/meminfo", "r", encoding="utf-8") as f:
        for line in f:
            key, val = line.split(":", 1)
            data[key] = int(val.strip().split()[0])
    total = data.get("MemTotal", 0)
    avail = data.get("MemAvailable", 0)
    used = max(0, total - avail)
    swap_total = data.get("SwapTotal", 0)
    swap_free = data.get("SwapFree", 0)
    swap_used = max(0, swap_total - swap_free)
    mem_pct = used / total * 100 if total else 0
    swap_pct = swap_used / swap_total * 100 if swap_total else 0
    return {
        "mem_total_mb": total // 1024,
        "mem_used_mb": used // 1024,
        "mem_avail_mb": avail // 1024,
        "mem_pct": round(mem_pct, 1),
        "swap_total_mb": swap_total // 1024,
        "swap_used_mb": swap_used // 1024,
        "swap_pct": round(swap_pct, 1),
    }


def disk_info():
    du = shutil.disk_usage("/")
    pct = du.used / du.total * 100 if du.total else 0
    return {
        "used_mb": du.used // 1024 // 1024,
        "total_mb": du.total // 1024 // 1024,
        "pct": round(pct, 1),
    }


def service_running():
    service = CFG.get("service_name", "sing-box")
    code, _, _ = run(f"systemctl is-active --quiet {service}")
    return code == 0


def port_listening():
    port = str(CFG.get("check_port", "")).strip()
    if not port:
        return True
    code, out, _ = run(f"ss -lnt | awk '{{print $4}}' | grep -Eq '(:|]){port}$'")
    return code == 0


def status_text():
    update_traffic()
    cpu = cpu_percent()
    mem = mem_info()
    disk = disk_info()
    node = "running" if service_running() else "DOWN"
    port = CFG.get("check_port", "未设置")
    total_rx = read_int_file(traffic_state_file("traffic_total_rx"))
    total_tx = read_int_file(traffic_state_file("traffic_total_tx"))

    return (
        f"🌌 宇宙监察委员会VPS管理局\n"
        f"━━━━━━━━━━━━━━\n"
        f"[{CFG['server_name']}]\n"
        f"时间: {time.strftime('%Y-%m-%d %H:%M:%S')}\n\n"
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

    checks = []
    checks.append("✔ sing-box运行正常" if service_running() else "✘ sing-box未运行")
    checks.append("✔ 端口监听正常" if port_listening() else f"✘ 端口 {CFG.get('check_port')} 未监听")
    checks.append("✔ RAM正常" if mem["mem_pct"] < CFG.get("ram_warn", 80) else f"⚠ RAM偏高: {mem['mem_pct']}%")
    checks.append("✔ SWAP正常" if mem["swap_pct"] < CFG.get("swap_warn", 30) else f"⚠ SWAP偏高: {mem['swap_pct']}%")
    checks.append("✔ CPU正常" if cpu < CFG.get("cpu_warn", 80) else f"⚠ CPU偏高: {cpu}%")
    checks.append("✔ 磁盘正常" if disk["pct"] < CFG.get("disk_warn", 90) else f"⚠ 磁盘偏高: {disk['pct']}%")

    return "🧪 健康检查\n[" + CFG["server_name"] + "]\n\n" + "\n".join(checks)


def latency_text():
    targets = [
        ("Cloudflare", "1.1.1.1"),
        ("GoogleDNS", "8.8.8.8"),
        ("Microsoft", "www.microsoft.com"),
    ]
    lines = ["🌐 延迟测试", f"[{CFG['server_name']}]", ""]
    for name, host in targets:
        code, out, _ = run(f"ping -c 3 -W 2 {host} 2>/dev/null | awk -F'/' '/rtt|round-trip/{{printf \"%.1f ms\", $5}}'", timeout=8)
        lines.append(f"{name}: {out if out else '失败'}")
    return "\n".join(lines)


def node_text():
    service = CFG.get("service_name", "sing-box")
    code, out, err = run(f"systemctl status {service} --no-pager | head -n 18", timeout=10)
    port = CFG.get("check_port", "")
    code2, listen, _ = run(f"ss -lntp 2>/dev/null | grep -E ':{port}\\b' || true", timeout=5) if port else (0, "", "")
    return f"📦 节点状态\n\n{out or err}\n\n端口监听:\n{listen or '未检测到指定端口'}"


def logs_text():
    service = CFG.get("service_name", "sing-box")
    code, out, err = run(f"journalctl -u {service} -n 25 --no-pager", timeout=10)
    text = out or err or "暂无日志"
    if len(text) > 3500:
        text = text[-3500:]
    return f"📄 最近日志\n\n{text}"


def clean_cache(manual=False):
    before = mem_info()
    # 安全清理：不删业务数据，只清内核缓存、旧日志、tmp 顶层临时文件
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
        f"时间: {time.strftime('%Y-%m-%d %H:%M:%S')}"
    )
    send_message(text)
    return text


def event_log(line):
    path = LOG_DIR / "events.log"
    with path.open("a", encoding="utf-8") as f:
        f.write(time.strftime("%Y-%m-%d %H:%M:%S") + " " + line + "\n")


def alert_key(name):
    return STATE_DIR / f"alert_{name}"


def can_alert(name, cooldown=600):
    p = alert_key(name)
    now = int(time.time())
    try:
        last = int(p.read_text().strip())
    except Exception:
        last = 0
    if now - last >= cooldown:
        p.write_text(str(now), encoding="utf-8")
        return True
    return False


def monitor():
    update_traffic()

    # 节点掉线/恢复
    old_state_path = STATE_DIR / "node_state"
    old = old_state_path.read_text().strip() if old_state_path.exists() else "unknown"
    ok = service_running() and port_listening()
    new = "up" if ok else "down"
    if new != old:
        if new == "down":
            msg = f"🚨 [{CFG['server_name']}] 节点掉线！"
            send_message(msg)
            event_log(msg)
        elif old == "down":
            msg = f"✅ [{CFG['server_name']}] 节点恢复运行"
            send_message(msg)
            event_log(msg)
        old_state_path.write_text(new, encoding="utf-8")

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

    if disk["pct"] >= CFG.get("disk_warn", 90):
        alerts.append(f"⚠ 磁盘偏高: {disk['pct']}%")

    # CPU 分级：5分钟 cron 下，单次检测可近似认为持续一个检测周期
    if cpu >= CFG.get("cpu_critical", 95):
        alerts.append(f"🚨 CPU严重: {cpu}%")
    elif cpu >= CFG.get("cpu_warn", 80):
        alerts.append(f"⚠ CPU偏高: {cpu}%")

    if alerts and can_alert("resource", CFG.get("alert_cooldown_sec", 600)):
        text = f"🚨 资源告警\n[{CFG['server_name']}]\n\n" + "\n".join(alerts)
        send_message(text)
        event_log(text.replace("\n", " | "))

    # 每小时状态
    now = int(time.time())
    p = STATE_DIR / "last_status"
    try:
        last = int(p.read_text().strip())
    except Exception:
        last = 0
    if now - last >= CFG.get("status_interval_sec", 3600):
        send_message(status_text())
        p.write_text(str(now), encoding="utf-8")


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
        service = CFG.get("service_name", "sing-box")
        run(f"systemctl restart {service}", timeout=20)
        time.sleep(1)
        send_message(f"🔄 已重启 {service}\n\n" + health_text(), main_keyboard())
    elif data == "restart_nginx":
        code, _, _ = run("systemctl list-unit-files nginx.service --no-legend 2>/dev/null | grep -q nginx")
        if code == 0:
            run("systemctl restart nginx", timeout=20)
            send_message("🔄 已重启 Nginx", main_keyboard())
        else:
            send_message("未检测到 nginx.service", main_keyboard())
    elif data == "reboot_ask":
        send_message("⚠️ 确认要重启 VPS 吗？节点会短暂中断。", confirm_reboot_keyboard())
    elif data == "reboot_now":
        send_message("⚠️ VPS 即将重启。")
        subprocess.Popen("sleep 2; reboot", shell=True)
    else:
        send_message("未知操作", main_keyboard())


def bot_poll():
    offset_file = STATE_DIR / "telegram_offset"
    try:
        offset = int(offset_file.read_text().strip())
    except Exception:
        offset = 0

    token = CFG["bot_token"]
    params = urllib.parse.urlencode({"timeout": 20, "offset": offset})
    url = f"https://api.telegram.org/bot{token}/getUpdates?{params}"

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
        elif text in ("/clean", "清理"):
            clean_cache(manual=True)
        else:
            send_message("发送 /start 打开控制面板。", main_keyboard())

    offset_file.write_text(str(offset), encoding="utf-8")


def show_menu_once():
    send_message(f"🌌 宇宙监察委员会VPS管理局\n[{CFG['server_name']}]\n\n控制面板已就绪。", main_keyboard())


def main():
    if len(sys.argv) < 2:
        print("usage: vps_manager.py monitor|bot|clean|status|menu|traffic-init")
        return

    cmd = sys.argv[1]
    if cmd == "monitor":
        monitor()
    elif cmd == "bot":
        bot_poll()
    elif cmd == "clean":
        clean_cache(manual=(len(sys.argv) > 2 and sys.argv[2] == "manual"))
    elif cmd == "status":
        print(status_text())
    elif cmd == "menu":
        show_menu_once()
    elif cmd == "traffic-init":
        use_current = not (len(sys.argv) > 2 and sys.argv[2] == "zero")
        init_traffic_if_needed(use_current=use_current)
        print("traffic initialized")
    else:
        print("unknown command")


if __name__ == "__main__":
    main()
PY
  chmod +x "$PY_FILE"
}

install_manager() {
  need_root
  install_deps
  mkdir -p "$APP_DIR" "$LOG_DIR"

  echo "======================================"
  echo "宇宙监察委员会VPS管理局 v2.2-no-default.2-no-default"
  echo "======================================"

  clean_old_bots

  echo
  echo "请输入 Telegram 信息。Token 不建议写进公开 GitHub 文件。"
  read -r -p "Bot Token: " BOT_TOKEN
  while true; do
    read -r -p "Chat ID: " CHAT_ID
    if [ -n "$CHAT_ID" ]; then
      break
    fi
    echo "Chat ID 不能为空。"
  done

  while true; do
    read -r -p "服务器名称: " SERVER_NAME
    if [ -n "$SERVER_NAME" ]; then
      break
    fi
    echo "服务器名称不能为空。"
  done

  read -r -p "检测的 systemd 服务名 [sing-box]: " SERVICE_NAME
  SERVICE_NAME="${SERVICE_NAME:-sing-box}"

  read -r -p "检测的代理端口，可留空只检测服务状态: " CHECK_PORT

  read -r -p "状态报告间隔分钟 [60]: " STATUS_MIN
  STATUS_MIN="${STATUS_MIN:-60}"

  read -r -p "异常检测频率分钟 [5]: " CHECK_MIN
  CHECK_MIN="${CHECK_MIN:-5}"

  echo
  echo "推荐阈值：RAM 80/90，SWAP 30/60，CPU 80/95，磁盘 90。"
  read -r -p "RAM预警阈值 [80]: " RAM_WARN
  RAM_WARN="${RAM_WARN:-80}"
  read -r -p "RAM严重阈值 [90]: " RAM_CRIT
  RAM_CRIT="${RAM_CRIT:-90}"
  read -r -p "SWAP预警阈值 [30]: " SWAP_WARN
  SWAP_WARN="${SWAP_WARN:-30}"
  read -r -p "SWAP严重阈值 [60]: " SWAP_CRIT
  SWAP_CRIT="${SWAP_CRIT:-60}"
  read -r -p "CPU预警阈值 [80]: " CPU_WARN
  CPU_WARN="${CPU_WARN:-80}"
  read -r -p "CPU严重阈值 [95]: " CPU_CRIT
  CPU_CRIT="${CPU_CRIT:-95}"
  read -r -p "磁盘预警阈值 [90]: " DISK_WARN
  DISK_WARN="${DISK_WARN:-90}"

  read -r -p "是否用当前网卡累计流量作为总流量初始值？[Y/n]: " TRAFFIC_ANS
  case "$TRAFFIC_ANS" in
    n|N) TRAFFIC_INIT="zero" ;;
    *) TRAFFIC_INIT="current" ;;
  esac

  cat > "$CONFIG_FILE" <<EOF
{
  "bot_token": "$BOT_TOKEN",
  "chat_id": "$CHAT_ID",
  "server_name": "$SERVER_NAME",
  "service_name": "$SERVICE_NAME",
  "check_port": "$CHECK_PORT",
  "status_interval_sec": $((STATUS_MIN * 60)),
  "ram_warn": $RAM_WARN,
  "ram_critical": $RAM_CRIT,
  "swap_warn": $SWAP_WARN,
  "swap_critical": $SWAP_CRIT,
  "cpu_warn": $CPU_WARN,
  "cpu_critical": $CPU_CRIT,
  "disk_warn": $DISK_WARN,
  "alert_cooldown_sec": 600
}
EOF
  chmod 600 "$CONFIG_FILE"

  write_python

  if ! [[ "$CHECK_MIN" =~ ^[0-9]+$ ]] || [ "$CHECK_MIN" -lt 1 ]; then
    CHECK_MIN=5
  fi

  cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Telegram 交互面板：每分钟轮询一次，不常驻内存
* * * * * root python3 $PY_FILE bot >/dev/null 2>&1

# 异常检测 + 每小时状态报告
*/$CHECK_MIN * * * * root python3 $PY_FILE monitor >/dev/null 2>&1

# 北京时间每天 04:00 自动清理缓存
CRON_TZ=Asia/Shanghai
0 4 * * * root python3 $PY_FILE clean >/dev/null 2>&1
EOF
  chmod 644 "$CRON_FILE"

  python3 "$PY_FILE" traffic-init "$TRAFFIC_INIT" >/dev/null 2>&1 || true
  python3 "$PY_FILE" menu || true
  python3 "$PY_FILE" monitor || true

  echo
  echo "安装完成。"
  echo "Telegram 发送 /start 打开控制面板。"
  echo "配置目录：$APP_DIR"
}

show_status() {
  echo "======================================"
  echo "宇宙监察委员会VPS管理局 v2"
  echo "======================================"
  if [ -f "$CONFIG_FILE" ]; then
    echo "已安装。配置文件：$CONFIG_FILE"
    python3 "$PY_FILE" status || true
  else
    echo "未安装。"
  fi
  echo
  echo "Cron:"
  [ -f "$CRON_FILE" ] && cat "$CRON_FILE" || echo "未安装"
}

run_now() {
  if [ ! -x "$PY_FILE" ]; then
    echo "未安装。"
    exit 1
  fi
  python3 "$PY_FILE" monitor
  echo "已执行一次检查。"
}

open_menu() {
  if [ ! -x "$PY_FILE" ]; then
    echo "未安装。"
    exit 1
  fi
  python3 "$PY_FILE" menu
  echo "已发送控制面板到 Telegram。"
}

uninstall_manager() {
  need_root
  read -r -p "确认卸载宇宙监察委员会VPS管理局？[y/N]: " ans
  case "$ans" in
    y|Y)
      rm -f "$CRON_FILE"
      rm -rf "$APP_DIR"
      echo "已卸载。"
      ;;
    *) echo "已取消。" ;;
  esac
}

main_menu() {
  need_root
  echo "======================================"
  echo "宇宙监察委员会VPS管理局 v2"
  echo "======================================"
  echo "1. 安装 / 重装"
  echo "2. 查看本机状态"
  echo "3. 立即执行一次检查"
  echo "4. 发送 Telegram 控制面板"
  echo "5. 卸载"
  echo "0. 退出"
  echo "======================================"
  read -r -p "请选择: " choice

  case "$choice" in
    1) install_manager ;;
    2) show_status ;;
    3) run_now ;;
    4) open_menu ;;
    5) uninstall_manager ;;
    0) exit 0 ;;
    *) echo "无效选项" ;;
  esac
}

main_menu "$@"
