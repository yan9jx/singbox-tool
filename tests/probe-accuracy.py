"""Real Linux iputils checks inside disposable, isolated network namespaces."""
import concurrent.futures
import json
import math
import re
import statistics
import subprocess
import time
from pathlib import Path

shell = Path("vps-status-agent.sh").read_text(encoding="utf-8")
source = shell.split('cat > "$APP" <<\'PY\'\n', 1)[1].split('\nPY\nchmod 755 "$APP"', 1)[0]
agent = {"__name__": "probe_accuracy_test"}
exec(compile(source, "agent.py", "exec"), agent)
actual_run = subprocess.run
captures = []

def capture(args, **kwargs):
    result = actual_run(args, **kwargs)
    if args[0] == "ping": captures.append(result.stdout)
    return result

agent["subprocess"].run = capture

def server(*args):
    actual_run(["ip", "netns", "exec", "codex-probe-server", *args], check=True)

def reset():
    server("iptables", "-F", "INPUT")

def check(name, target="198.18.0.2"):
    measured = agent["ping_target"](target)
    output = captures[-1]
    match = re.search(r"(\d+) packets transmitted, (\d+) received", output)
    assert match, output
    sent, received = map(int, match.groups())
    assert sent == 5, (name, "Unexpected extra transmissions", output)
    assert (measured["packets_sent"], measured["packets_received"]) == (sent, received), measured
    assert measured["loss_pct"] == round((sent-received)*100/sent, 1), measured
    assert len(measured["packet_points"]) == sent, measured
    assert sum(point[2] == 0 for point in measured["packet_points"]) == received, measured
    assert sum(point[2] == 100 for point in measured["packet_points"]) == sent-received, measured
    average = re.search(r"(?:rtt|round-trip)[^=]*= [\d.]+/([\d.]+)/", output)
    if received:
        assert average, output
        batches = [{"start": measured["_started_clock"], "end": measured["_ended_clock"], "probe": measured}]
        rolled = agent["rolling_probe"](batches, time.monotonic())
        assert math.isclose(rolled["latency_ms"], float(average.group(1)), abs_tol=.2), (rolled, output)
    else:
        assert measured["latency_ms"] is None and measured["loss_pct"] == 100, measured
    print(json.dumps({"case":name,"sent":sent,"received":received,"loss_pct":measured["loss_pct"],"rtt_mean":statistics.fmean(measured["rtt_samples"]) if measured["rtt_samples"] else None,"raw":output},ensure_ascii=False),flush=True)
    return measured

reset()
baseline = check("controlled-80ms-rtt")
assert baseline["packets_received"] == 5 and 60 <= baseline["latency_ms"] <= 200, baseline

server("iptables", "-A", "INPUT", "-p", "icmp", "--icmp-type", "echo-request", "-d", "198.18.0.2", "-m", "statistic", "--mode", "nth", "--every", "3", "--packet", "0", "-j", "DROP")
partial = check("deterministic-partial-loss")
assert 0 < partial["packets_received"] < 5, partial
legacy = actual_run(["ping","-4","-n","-D","-c","5","-i","1","-W","2","-w","7","198.18.0.2"],text=True,capture_output=True,timeout=15)
legacy_sent = int(re.search(r"(\d+) packets transmitted",legacy.stdout).group(1))
assert legacy_sent > 5, legacy.stdout
print(json.dumps({"case":"negative-control-legacy-deadline-oversends","sent":legacy_sent,"raw":legacy.stdout}),flush=True)

reset()
server("tc","qdisc","replace","dev","probe-server","root","netem","delay","1100ms")
slow = check("slow-replies-preserved")
assert slow["packets_received"] == 5 and slow["latency_ms"] >= 1100, slow
server("tc","qdisc","replace","dev","probe-server","root","netem","delay","45ms")

server("iptables", "-A", "INPUT", "-p", "icmp", "--icmp-type", "echo-request", "-d", "198.18.0.2", "-j", "DROP")
check("complete-loss")
blocked = agent["CarrierProbeSampler"]({"carrier":"telecom","targets":["198.18.0.2"]})
healthy = agent["CarrierProbeSampler"]({"carrier":"mobile","targets":["198.18.0.3"]})
time.sleep((.25 - time.time()%1)%1)
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
    started = time.monotonic()
    blocked.schedule(executor,started)
    healthy.schedule(executor,started)
    good = []
    while not good and time.monotonic()-started < 5.5:
        good = healthy.poll(time.monotonic())
        if not good: time.sleep(.02)
    assert good and not blocked.pending[0][0].done(), "A blocked carrier must not delay a healthy carrier"
    while time.monotonic()-started < 5: time.sleep(.01)
    blocked.schedule(executor,time.monotonic())
    assert len(blocked.pending) == 2, "Start the next batch while the prior batch waits"
    lost = []
    while blocked.pending and time.monotonic()-started < 15:
        lost.extend(blocked.poll(time.monotonic()))
        time.sleep(.02)
    assert len(lost) == 2, lost
    seconds = agent["packet_seconds"](lost)
    assert len(seconds) == 10 and seconds[-1][0]-seconds[0][0] == 9, seconds
    assert all(point[2] == 100 for point in seconds), seconds
    assert sum(batch["probe"]["packets_sent"] for batch in lost) == 10
    print(json.dumps({"case":"independent-cadence-during-total-loss","seconds":seconds,"healthy_received":good[0]["probe"]["packets_received"]}),flush=True)
reset()
print(json.dumps({"ok":True,"checks":"real iputils counts, RTT versus raw summary, partial loss, 100% loss, slow replies, legacy negative control and independent cadence"}),flush=True)
