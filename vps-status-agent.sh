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
    rm -f "$SERVICE" "$UPDATE_SERVICE" "$UPDATE_TIMER" "$UPDATE_APP" "$APP" "$CONF" /var/lib/ejectors-vps-agent.json /var/lib/ejectors-vps-agent/update.json
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
import argparse, collections, concurrent.futures, glob, ipaddress, json, math, os, platform, re, shutil, socket, statistics, subprocess, threading, time, urllib.request

VERSION = "1.3.1"
CONF = "/etc/ejectors-vps-agent.conf"
STATE = "/var/lib/ejectors-vps-agent/state.json"
UPDATE_STATE = "/var/lib/ejectors-vps-agent/update.json"
UPDATE_SERVICE = "ejectors-vps-agent-update.service"
PING_COUNT = 5
PING_INTERVAL_SECONDS = 1
PING_TIMEOUT_SECONDS = 18
PROBE_TARGET_STATE = {}
PROBE_WINDOW_SECONDS = 300
REPORT_INTERVAL_SECONDS = 15
PROBE_MONITOR = None

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

def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f: json.dump(data, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)

def write_state(data):
    write_json(STATE, data)

def version_parts(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d+(?:\.\d+){1,3}", value): return None
    return tuple(int(part) for part in value.split("."))

def compare_versions(left, right):
    a, b = version_parts(left), version_parts(right)
    if a is None or b is None: return None
    width = max(len(a), len(b))
    a += (0,) * (width - len(a)); b += (0,) * (width - len(b))
    return (a > b) - (a < b)

def agent_update_status():
    data = read_json(UPDATE_STATE, {})
    if not isinstance(data, dict): return None
    request_id = data.get("request_id", "")
    target_version = data.get("target_version", "")
    status = data.get("status", "")
    if not re.fullmatch(r"[a-f0-9]{32}", request_id) or version_parts(target_version) is None or status not in {"accepted", "succeeded", "failed"}:
        return None
    if status == "accepted" and compare_versions(VERSION, target_version) >= 0:
        data.update({"status": "succeeded", "version": VERSION, "updated_at": int(time.time()), "error": ""})
        write_json(UPDATE_STATE, data)
    return {
        "request_id": request_id,
        "target_version": target_version,
        "version": VERSION,
        "status": data["status"],
        "updated_at": int(data.get("updated_at", 0)),
        "error": str(data.get("error", ""))[:120] if data["status"] == "failed" else "",
    }

def handle_agent_action(action):
    if not isinstance(action, dict) or action.get("type") != "agent_update": return
    request_id = action.get("request_id", "")
    target_version = action.get("target_version", "")
    requested_at = action.get("requested_at")
    if not re.fullmatch(r"[a-f0-9]{32}", request_id) or version_parts(target_version) is None or not isinstance(requested_at, int) or requested_at <= 0:
        return
    current = agent_update_status()
    if current and current["request_id"] == request_id and current["status"] in {"accepted", "succeeded", "failed"}:
        return
    now = int(time.time())
    update = {
        "request_id": request_id,
        "target_version": target_version,
        "version": VERSION,
        "status": "succeeded" if compare_versions(VERSION, target_version) >= 0 else "accepted",
        "updated_at": now,
        "error": "",
    }
    write_json(UPDATE_STATE, update)
    if update["status"] == "succeeded": return
    try:
        result = subprocess.run(
            ["systemctl", "start", "--no-block", UPDATE_SERVICE],
            text=True, capture_output=True, timeout=5,
        )
        if result.returncode != 0:
            message = (result.stderr or result.stdout or "systemctl 启动更新服务失败").strip()[:120]
            update.update({"status": "failed", "updated_at": int(time.time()), "error": message})
            write_json(UPDATE_STATE, update)
    except Exception as exc:
        update.update({"status": "failed", "updated_at": int(time.time()), "error": str(exc)[:120]})
        write_json(UPDATE_STATE, update)

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
    tcp = tcp_snapshot()
    result["tcp_quality"] = tcp_window(old.get("tcp_snapshot"), tcp)
    result["tcp_quality"].update(tcp_connection_rtt(command(["ss", "-tineHO", "state", "established"])))
    write_state({"timestamp": now, "rx_bytes": rx, "tx_bytes": tx, "public_ip": old.get("public_ip", ""), "ip_checked": old.get("ip_checked", 0), "tcp_snapshot": tcp})
    return result

def parse_proc_counters(text, group):
    lines = text.splitlines()
    for index in range(len(lines) - 1):
        keys, values = lines[index].split(), lines[index + 1].split()
        if keys and values and keys[0] == values[0] == group + ":" and len(keys) == len(values):
            return {key: int(value) for key, value in zip(keys[1:], values[1:])}
    return {}

def tcp_snapshot():
    try:
        with open("/proc/net/snmp") as f: counters = parse_proc_counters(f.read(), "Tcp")
        if not {"OutSegs", "RetransSegs"}.issubset(counters): return None
        try:
            with open("/proc/net/netstat") as f: extra = parse_proc_counters(f.read(), "TcpExt")
        except (OSError, ValueError): extra = {}
        with open("/proc/sys/kernel/random/boot_id") as f: boot = f.read().strip()
        return {"at": time.time(), "clock": time.monotonic(), "boot_id": boot,
                "out": counters["OutSegs"], "retrans": counters["RetransSegs"],
                "original_data": extra.get("TCPOrigDataSent"), "syn_retrans": extra.get("TCPSynRetrans")}
    except (OSError, ValueError): return None

def tcp_window(previous, current):
    result = {"status": "unavailable", "retrans_pct": None, "window_seconds": 0,
              "original_segments": 0, "retrans_segments": 0, "syn_retrans_segments": None, "basis": "original_data"}
    if not current: return result
    basis = "original_data" if current.get("original_data") is not None else "out"
    result.update(status="warming", basis=basis)
    if not isinstance(previous, dict) or previous.get("boot_id") != current.get("boot_id"): return result
    elapsed = current["clock"] - previous.get("clock", current["clock"])
    if not 1 <= elapsed <= 600: return result
    for key in ("out", "retrans", basis):
        if previous.get(key) is None or current[key] < previous[key]: return result
    sent = current[basis] - previous[basis]
    retrans = current["retrans"] - previous["retrans"]
    result.update(window_seconds=round(elapsed, 1), original_segments=sent, retrans_segments=retrans)
    if current.get("syn_retrans") is not None and previous.get("syn_retrans") is not None and current["syn_retrans"] >= previous["syn_retrans"]:
        result["syn_retrans_segments"] = current["syn_retrans"] - previous["syn_retrans"]
    if sent == 0:
        result["status"] = "retransmitting" if retrans else "idle"
        return result
    # This is a retransmission/original-segment ratio, not an end-to-end packet-loss probability.
    # Repeated retransmissions can legitimately make the ratio exceed 100%.
    result.update(status="measured" if sent >= 100 else "low_sample", retrans_pct=round(retrans * 100.0 / sent, 2))
    return result

def tcp_connection_rtt(output):
    samples = []
    for line in output.splitlines():
        fields = line.split()
        if fields and fields[0] in {"ESTAB", "ESTABLISHED"}: fields = fields[1:]
        if len(fields) < 4: continue
        try:
            peer = ipaddress.ip_address(fields[3].rsplit(":", 1)[0].strip("[]"))
            if isinstance(peer, ipaddress.IPv6Address) and peer.ipv4_mapped: peer = peer.ipv4_mapped
            if not peer.is_global: continue
        except ValueError: continue
        rtt = re.search(r"\brtt:([\d.]+)/", line)
        # Ignore stale socket RTTs; do not manufacture a zero when there are no active sockets.
        activity = [int(value) for value in re.findall(r"\b(?:lastsnd|lastrcv|lastack):(\d+)", line)]
        if not rtt or not activity or min(activity) > 120000: continue
        value = float(rtt.group(1))
        if not math.isfinite(value) or not 0 < value <= 60000: continue
        samples.append(value)
    return {"rtt_ms": round(statistics.median(samples), 2) if samples else None,
            "rtt_p95_ms": round(sorted(samples)[math.ceil(len(samples) * .95) - 1], 2) if samples else None,
            "rtt_connections": len(samples)}

def command(args):
    try: return subprocess.run(args, text=True, capture_output=True, timeout=4).stdout.strip()
    except Exception: return ""

def ping_target(target):
    if not shutil.which("ping"):
        return {"target": target, "latency_ms": None, "loss_pct": None, "status": "unavailable", "packets_sent": 0, "packets_received": 0}
    env = dict(os.environ, LC_ALL="C", LANG="C")
    try:
        started_at = time.time()
        started_clock = time.monotonic()
        deadline = math.ceil((PING_COUNT - 1) * PING_INTERVAL_SECONDS + 3)
        result = subprocess.run(
            ["ping", "-4", "-n", "-D", "-c", str(PING_COUNT), "-i", str(PING_INTERVAL_SECONDS), "-W", "2", "-w", str(deadline), target],
            text=True, capture_output=True, timeout=PING_TIMEOUT_SECONDS, env=env,
        )
        output = result.stdout + "\n" + result.stderr
        packet_match = re.search(r"(\d+)\s+packets transmitted,\s+(\d+)\s+(?:packets )?received", output)
        replies = {}
        for sequence, value in re.findall(r"icmp_seq[= ](\d+)[^\n]*?time[=<]([\d.]+)\s*ms", output):
            replies.setdefault(sequence, float(value))
        samples = list(replies.values())
        if not packet_match:
            return {"target": target, "latency_ms": None, "loss_pct": None, "status": "unavailable", "packets_sent": 0, "packets_received": 0}
        sent, received = int(packet_match.group(1)), int(packet_match.group(2))
        if sent <= 0:
            return {"target": target, "latency_ms": None, "loss_pct": None, "status": "unavailable", "packets_sent": 0, "packets_received": 0}
        received = min(sent, received)
        # Recover each reply's send time from its receive timestamp and RTT.
        # Unanswered packets use the same fixed one-second sequence schedule.
        bases = [float(stamp) - float(rtt) / 1000 - (int(sequence) - 1) * PING_INTERVAL_SECONDS
                 for stamp, sequence, rtt in re.findall(r"^\[([\d.]+)\][^\n]*?icmp_seq[= ](\d+)[^\n]*?time[=<]([\d.]+)\s*ms", output, re.MULTILINE)]
        first_sent_at = statistics.median(bases) if bases else started_at
        can_identify_losses = sent - len(replies) == sent - received
        packet_points = []
        for sequence in range(1, sent + 1):
            rtt = replies.get(str(sequence))
            packet_points.append([int(first_sent_at + (sequence - 1) * PING_INTERVAL_SECONDS), round(rtt, 1) if rtt is not None else None,
                                  0 if rtt is not None else 100 if can_identify_losses else None])
        loss = round((sent - received) * 100.0 / sent, 1)
        address_match = re.search(r"^PING\s+\S+\s+\((\d+\.\d+\.\d+\.\d+)\)", output, re.MULTILINE)
        latency = round(float(statistics.median(samples)), 1) if samples else None
        p95 = round(float(sorted(samples)[max(0, math.ceil(len(samples) * 0.95) - 1)]), 1) if samples else None
        deltas = [abs(samples[index] - samples[index - 1]) for index in range(1, len(samples))]
        jitter = round(float(statistics.fmean(deltas)), 1) if deltas else 0.0 if samples else None
        return {
            "target": target,
            "target_ip": address_match.group(1) if address_match else target if re.fullmatch(r"\d+\.\d+\.\d+\.\d+", target) else "",
            "latency_ms": latency,
            "loss_pct": loss,
            "jitter_ms": jitter,
            "p95_ms": p95,
            "packets_sent": sent,
            "packets_received": received,
            "rtt_samples": samples,
            "packet_points": packet_points,
            "_started_clock": started_clock,
            "_ended_clock": time.monotonic(),
            "status": "ok" if loss == 0 else "loss",
        }
    except Exception:
        return {"target": target, "latency_ms": None, "loss_pct": None, "status": "unavailable", "packets_sent": 0, "packets_received": 0}

def probe_carrier(probe):
    targets = list(dict.fromkeys(str(value) for value in probe.get("targets", [])[:5] if value))
    base = {
        "carrier": str(probe.get("carrier", "")),
        "target": "",
        "latency_ms": None,
        "loss_pct": None,
        "jitter_ms": None,
        "p95_ms": None,
        "packets_sent": 0,
        "packets_received": 0,
        "status": "unavailable",
        "targets_tested": len(targets),
        "responsive_targets": 0,
    }
    if not targets: return base
    key = (base["carrier"], tuple(targets))
    state = PROBE_TARGET_STATE.setdefault(key, {"target": targets[0], "failures": 0})
    # Only continuously ping the active endpoint. Test backups on the third
    # failed round instead of generating constant traffic to every fallback.
    measured_targets = [state["target"]] if probe.get("continuous") and state["failures"] < 2 else targets
    base["targets_tested"] = len(measured_targets)
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(measured_targets)) as executor:
        results = list(executor.map(ping_target, measured_targets))
    responsive = [item for item in results if item.get("packets_received", 0) > 0]
    measurable = [item for item in results if item.get("packets_sent", 0) > 0]
    if not measurable: return base
    representative = next((item for item in results if item["target"] == state["target"]), results[0])
    if representative.get("packets_received", 0) > 0:
        state["failures"] = 0
    else:
        state["failures"] += 1
        # Keep partial loss visible; only fail over after three completely failed rounds.
        if state["failures"] >= 3 or not representative.get("packets_sent", 0):
            replacement = next(iter(responsive), None)
            if replacement is not None:
                representative = replacement
                state.update(target=representative["target"], failures=0)
    if not representative.get("packets_sent", 0):
        representative = measurable[0]
    return {
        **base,
        "target": representative["target"],
        "target_ip": representative.get("target_ip", ""),
        "latency_ms": representative["latency_ms"],
        "loss_pct": representative["loss_pct"],
        "jitter_ms": representative.get("jitter_ms"),
        "p95_ms": representative.get("p95_ms"),
        "packets_sent": representative.get("packets_sent", 0),
        "packets_received": representative.get("packets_received", 0),
        "status": representative["status"],
        "responsive_targets": len(responsive),
        "rtt_samples": representative.get("rtt_samples", []),
        "packet_points": representative.get("packet_points", []),
    }

def measure_network_quality(config):
    if not config or not config.get("enabled") or not config.get("probes"):
        return None
    probes = list(config.get("probes", []))[:3]
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(probes)) as executor:
        results = list(executor.map(lambda probe: probe_carrier({**probe, "continuous": True}), probes))
    return {
        "region": str(config.get("region", "")),
        "measured_at": int(time.time()),
        "probes": results,
    }

def packet_seconds(batches):
    points = {}
    for batch in batches:
        for point in batch["probe"].get("packet_points", []):
            points[point[0]] = point
    if not points: return []
    end = max(points)
    return [points[at] for at in sorted(points) if at >= end - 29]

def rolling_probe(batches, now):
    latest = batches[-1] if batches else None
    if not latest: return None
    result = {key: value for key, value in latest["probe"].items() if key not in {"rtt_samples", "packet_points"}}
    result.update(window_seconds=0, seconds=packet_seconds(batches))
    if now - latest["end"] > 30:
        result.update(status="unavailable", latency_ms=None, loss_pct=None, p95_ms=None, jitter_ms=None, packets_sent=0, packets_received=0)
        return result
    if result.get("status") == "unavailable": return result
    identity = (result.get("target"), result.get("target_ip"))
    selected = []
    for batch in reversed(batches):
        probe = batch["probe"]
        if batch["start"] < now - PROBE_WINDOW_SECONDS: break
        if probe.get("status") == "unavailable" or (probe.get("target"), probe.get("target_ip")) != identity: break
        selected.append(batch)
    selected.reverse()
    if not selected:
        result.update(status="unavailable", latency_ms=None, loss_pct=None, packets_sent=0, packets_received=0)
        return result
    sent = sum(batch["probe"].get("packets_sent", 0) for batch in selected)
    received = sum(batch["probe"].get("packets_received", 0) for batch in selected)
    samples = [value for batch in selected for value in batch["probe"].get("rtt_samples", [])]
    loss = round((sent - received) * 100.0 / sent, 2) if sent else None
    deltas = [abs(right - left) for left, right in zip(samples, samples[1:])]
    result.update(
        packets_sent=sent, packets_received=received, loss_pct=loss,
        # Show the recent batch's mean RTT so short-term changes remain visible.
        # Packet loss uses the larger rolling window for finer resolution.
        latency_ms=round(statistics.fmean(latest["probe"].get("rtt_samples", [])), 1) if latest["probe"].get("rtt_samples") else None,
        p95_ms=round(sorted(samples)[math.ceil(len(samples) * .95) - 1], 1) if samples else None,
        jitter_ms=round(statistics.fmean(deltas), 1) if deltas else 0.0 if samples else None,
        status="ok" if loss == 0 else "loss" if loss is not None else "unavailable",
        window_seconds=round(selected[-1]["end"] - selected[0]["start"], 1),
    )
    return result

class CarrierProbeSampler:
    def __init__(self, probe):
        self.carrier = str(probe.get("carrier", ""))
        self.targets = list(dict.fromkeys(str(target) for target in probe.get("targets", [])[:5] if target))
        self.target = self.targets[0] if self.targets else ""
        self.failures = 0
        self.pending = collections.deque()
        self.backup = None
        self.backup_index = 0
        self.last_backup = -float("inf")

    def schedule(self, executor, now):
        # Launch on a fixed cadence even while the previous batch waits for
        # missing replies. Bound outstanding work if ping/DNS itself stalls.
        if self.target and len(self.pending) < 3:
            self.pending.append((executor.submit(ping_target, self.target), self.target, now))
        alternatives = [target for target in self.targets if target != self.target]
        if self.failures >= 2 and alternatives and self.backup is None and now - self.last_backup >= PING_COUNT:
            target = alternatives[self.backup_index % len(alternatives)]
            self.backup_index += 1
            self.last_backup = now
            self.backup = (executor.submit(ping_target, target), self.target)

    def poll(self, now):
        batches = []
        while self.pending and self.pending[0][0].done():
            future, target, started = self.pending.popleft()
            try:
                probe = dict(future.result())
            except Exception:
                probe = {"target": target, "status": "unavailable", "packets_sent": 0, "packets_received": 0, "latency_ms": None, "loss_pct": None}
            received = probe.get("packets_received", 0)
            if target == self.target:
                self.failures = 0 if received else self.failures + 1
            start = probe.pop("_started_clock", started)
            end = probe.pop("_ended_clock", now)
            probe.update(carrier=self.carrier, targets_tested=1, responsive_targets=1 if received else 0)
            batches.append({"start": start, "end": end, "probe": probe})
        if self.backup and self.backup[0].done():
            future, expected_target = self.backup
            self.backup = None
            try:
                replacement = future.result()
            except Exception:
                replacement = {}
            # Partial loss never causes a switch. A backup must actually reply,
            # and the active endpoint must have failed three complete batches.
            if self.target == expected_target and self.failures >= 3 and replacement.get("packets_received", 0) > 0:
                self.target = replacement["target"]
                self.failures = 0
        return batches

    def cancel(self):
        for future, _, _ in self.pending: future.cancel()
        if self.backup: self.backup[0].cancel()


class NetworkProbeMonitor:
    def __init__(self):
        self.lock = threading.Lock()
        self.wake = threading.Event()
        self.config = None
        self.config_key = ""
        self.generation = 0
        self.batches = {}
        self.measured_at = 0
        self.thread = None

    def configure(self, config):
        config_key = json.dumps(config, sort_keys=True)
        with self.lock:
            if config_key != self.config_key:
                self.config = config
                self.config_key = config_key
                self.generation += 1
                self.batches = {}
                self.measured_at = 0
                self.wake.set()
            if self.thread is None and config and config.get("enabled"):
                self.thread = threading.Thread(target=self.run, daemon=True, name="network-probe")
                self.thread.start()

    def run(self):
        samplers, active_generation, next_tick = [], -1, 0
        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as executor:
            while True:
                self.wake.clear()
                with self.lock:
                    config, generation = self.config, self.generation
                enabled = config and config.get("enabled")
                if generation != active_generation:
                    for sampler in samplers: sampler.cancel()
                    samplers = [CarrierProbeSampler(probe) for probe in list(config.get("probes", []))[:3]] if enabled else []
                    active_generation = generation
                    # Stay away from a wall-second boundary so process startup
                    # jitter does not split otherwise regular sends across cells.
                    next_tick = time.monotonic() + ((0.25 - time.time() % 1) % 1)
                now = time.monotonic()
                for sampler in samplers:
                    batches = sampler.poll(now)
                    if batches:
                        with self.lock:
                            if generation == self.generation:
                                window = self.batches.setdefault(sampler.carrier, collections.deque(maxlen=90))
                                window.extend(batches)
                                self.measured_at = int(time.time())
                if enabled and now >= next_tick:
                    for sampler in samplers: sampler.schedule(executor, now)
                    next_tick += PING_COUNT * PING_INTERVAL_SECONDS
                    if next_tick <= now: next_tick = now + PING_COUNT * PING_INTERVAL_SECONDS
                self.wake.wait(0.1 if enabled else 5)

    def snapshot(self):
        with self.lock:
            if not self.config or not self.config.get("enabled") or not self.batches: return None
            now = time.monotonic()
            probes = [rolling_probe(list(batches), now) for batches in self.batches.values()]
            return {"region": self.config.get("region", ""), "measured_at": self.measured_at,
                    "probes": [probe for probe in probes if probe is not None]}

def configure_network_quality(config):
    global PROBE_MONITOR
    if PROBE_MONITOR is None: PROBE_MONITOR = NetworkProbeMonitor()
    PROBE_MONITOR.configure(config)

def network_quality(config):
    if not config or not config.get("enabled"):
        if PROBE_MONITOR is not None: PROBE_MONITOR.configure(config)
        return None
    configure_network_quality(config)
    return PROBE_MONITOR.snapshot()

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
    update = agent_update_status()
    if update: payload["agent_update_status"] = update
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
    report_interval = REPORT_INTERVAL_SECONDS
    while True:
        report_started = time.monotonic()
        try:
            response = post(conf, "/api/v1/heartbeat", collect(conf, probe_config))
            if isinstance(response, dict) and isinstance(response.get("probe_config"), dict):
                probe_config = response["probe_config"]
                configure_network_quality(probe_config)
            if isinstance(response, dict):
                interval = response.get("report_interval_seconds")
                if isinstance(interval, (int, float)) and not isinstance(interval, bool) and math.isfinite(interval):
                    report_interval = max(5, min(120, int(interval)))
                handle_agent_action(response.get("agent_action"))
        except Exception as exc:
            print(time.strftime("%F %T"), "report failed:", exc, flush=True)
        if not args.loop: return
        time.sleep(max(1, report_interval - (time.monotonic() - report_started)))

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
echo "安装完成：上报间隔由面板按节点数量自动调整。"
echo "自动更新：每天北京时间 04:00 检查。"
echo "卸载命令：sudo bash $0 uninstall"
