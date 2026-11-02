#!/usr/bin/env bash
set -euo pipefail
ip netns add codex-probe-client
ip netns add codex-probe-server
ip link add probe-client type veth peer name probe-server
ip link set probe-client netns codex-probe-client
ip link set probe-server netns codex-probe-server
ip -n codex-probe-client addr add 198.18.0.1/24 dev probe-client
ip -n codex-probe-server addr add 198.18.0.2/24 dev probe-server
ip -n codex-probe-server addr add 198.18.0.3/24 dev probe-server
ip -n codex-probe-client link set lo up
ip -n codex-probe-server link set lo up
ip -n codex-probe-client link set probe-client up
ip -n codex-probe-server link set probe-server up
ip netns exec codex-probe-client tc qdisc add dev probe-client root netem delay 35ms
ip netns exec codex-probe-server tc qdisc add dev probe-server root netem delay 45ms
