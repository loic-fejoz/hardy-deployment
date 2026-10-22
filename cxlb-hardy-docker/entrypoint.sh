#!/usr/bin/env bash
set -eo pipefail

echo "=========================================="
echo " Starting CorteXlab Hardy Container Node  "
echo "=========================================="

export PATH="/cortexlab/toolchains/current/bin:${PATH}"
export LD_LIBRARY_PATH="/cortexlab/toolchains/current/lib:${LD_LIBRARY_PATH}"
export PYTHONPATH="/cortexlab/toolchains/current/lib/python3.11/site-packages:${PYTHONPATH}"

# Environment variables & smart defaults
export NODE_EID="${NODE_EID:-ipn:100.0}"
export LTP_ENGINE_ID="${LTP_ENGINE_ID:-100}"
export LTP_TX_HOST="${LTP_TX_HOST:-127.0.0.1}"
export LTP_TX_PORT="${LTP_TX_PORT:-52001}"
export LTP_RX_PORT="${LTP_RX_PORT:-52002}"
export LTP_MAX_SEGMENT_LEN="${LTP_MAX_SEGMENT_LEN:-1000}"
export LTP_RTT="${LTP_RTT:-1s}"
export LTP_ACK_MARGIN="${LTP_ACK_MARGIN:-250ms}"
export LTP_PEERS="${LTP_PEERS:-}"
export ENABLE_TCPCL="${ENABLE_TCPCL:-true}"
export TCPCL_PORT="${TCPCL_PORT:-4556}"
export RF_FREQ="${RF_FREQ:-434000000}"
export LOG_LEVEL="${LOG_LEVEL:-info}"
export START_FLOWGRAPH="${START_FLOWGRAPH:-true}"
export FLOWGRAPH_SCRIPT="${FLOWGRAPH_SCRIPT:-/opt/cxlb-hardy/flowgraphs/udp_gfsk.py}"
export SCENARIO_SCRIPT="${SCENARIO_SCRIPT:-}"
export AUTO_EXIT="${AUTO_EXIT:-false}"
export IGNORE_FLOWGRAPH_FAILURE="${IGNORE_FLOWGRAPH_FAILURE:-true}"

# Ensure runtime directories exist
mkdir -p /var/lib/hardy/bundles /etc/hardy /var/log/hardy

# Generate Hardy configuration file
echo "[ENTRYPOINT] Generating Hardy configuration for EID: ${NODE_EID}, Engine ID: ${LTP_ENGINE_ID}..."
python3 - << 'EOF'
import os
import sys

node_eid = os.environ.get("NODE_EID", "ipn:100.0").strip()
dtn_eid = os.environ.get("DTN_EID", "").strip()

node_ids = []
if node_eid:
    if node_eid.startswith("dtn://") and not node_eid.endswith("/") and "/" not in node_eid[6:]:
        node_eid += "/"
    node_ids.append(node_eid)

if dtn_eid:
    if dtn_eid.startswith("dtn://") and not dtn_eid.endswith("/") and "/" not in dtn_eid[6:]:
        dtn_eid += "/"
    if dtn_eid not in node_ids:
        node_ids.append(dtn_eid)
elif not any(n.startswith("dtn://") for n in node_ids):
    # Hardy requires a DTN node ID for string-named services (like built-in echo)
    if node_eid.startswith("ipn:"):
        try:
            num = node_eid.split(":")[1].split(".")[0]
            node_ids.append(f"dtn://node{num}/")
        except Exception:
            node_ids.append("dtn://cxlb-node/")
    else:
        node_ids.append("dtn://cxlb-node/")

node_ids_yaml = "\n".join([f'  - "{nid}"' for nid in node_ids])
engine_id = os.environ.get("LTP_ENGINE_ID", "100").strip()
tx_host = os.environ.get("LTP_TX_HOST", "127.0.0.1").strip()
tx_port = os.environ.get("LTP_TX_PORT", "52001").strip()
rx_port = os.environ.get("LTP_RX_PORT", "52002").strip()
max_segment_len = os.environ.get("LTP_MAX_SEGMENT_LEN", "1000").strip()
rtt = os.environ.get("LTP_RTT", "1s").strip()
ack_margin = os.environ.get("LTP_ACK_MARGIN", "250ms").strip()
log_level = os.environ.get("LOG_LEVEL", "info").strip()
raw_peers = os.environ.get("LTP_PEERS", "").strip()

peers_yaml = ""
if raw_peers:
    # Example format: "200=ipn:200.0, 300=dtn://f4jxq" or "200=ipn:200.0; 300=dtn://f4jxq"
    delimiters = [',', ';']
    entries = [raw_peers]
    for d in delimiters:
        new_entries = []
        for e in entries:
            new_entries.extend(e.split(d))
        entries = new_entries

    peers_list = []
    for entry in entries:
        entry = entry.strip()
        if not entry:
            continue
        if '=' in entry:
            p_engine, p_node = entry.split('=', 1)
        elif ':' in entry and not entry.startswith("ipn:") and not entry.startswith("dtn:"):
            p_engine, p_node = entry.split(':', 1)
        else:
            continue
        p_node_clean = p_node.strip()
        if p_node_clean.startswith("dtn://") and not p_node_clean.endswith("/") and "/" not in p_node_clean[6:]:
            p_node_clean += "/"
        peers_list.append((p_engine.strip(), p_node_clean))

    if peers_list:
        peers_yaml = "    peers:\n"
        for p_engine, p_node in peers_list:
            peers_yaml += f"      - engine-id: {p_engine}\n"
            peers_yaml += f"        address: \"{tx_host}:{tx_port}\"\n"
            peers_yaml += f"        node-id: \"{p_node}\"\n"
    else:
        peers_yaml = "    peers: []\n"
else:
    peers_yaml = "    peers: []\n"

enable_tcpcl = os.environ.get("ENABLE_TCPCL", "true").lower() in ("true", "1", "yes")
tcpcl_port = os.environ.get("TCPCL_PORT", "4556").strip()

tcpcl_yaml = ""
if enable_tcpcl:
    tcpcl_yaml = f"""  - name: tcp-cla-1
    type: tcpclv4
    listeners:
      - "0.0.0.0:{tcpcl_port}"
"""

config_template = f"""log-level: {log_level}
node-ids:
{node_ids_yaml}
status-reports: true
poll-channel-depth: 16
processing-pool-size: 16

grpc:
  address: "[::]:50051"
  services:
    - application
    - cla
    - service

storage:
  lru-capacity: 1024
  max-cached-bundle-size: 16384
  metadata:
    type: sqlite
    db-dir: /var/lib/hardy/
  bundle:
    type: localdisk
    fsync: true
    store-dir: /var/lib/hardy/bundles

rfc9171-validity:
  primary-block-integrity: false
  bundle-age-required: true

built-in-services:
  echo:
    - 7
    - echo

clas:
{tcpcl_yaml}  - name: ltp-cla-1
    type: ltp
    engine-id: {engine_id}
    max-segment-payload-len: {max_segment_len}
    rtt: "{rtt}"
    ack-margin: "{ack_margin}"
    checkpoint-rtx-limit: 10
    report-rtx-limit: 10
    transport:
      type: udp
      bind-addr: "0.0.0.0:{rx_port}"
{peers_yaml}
"""

with open("/etc/hardy/hardy.yaml", "w") as f:
    f.write(config_template)
print("[ENTRYPOINT] Configuration written to /etc/hardy/hardy.yaml successfully.")
EOF

# PIDs to manage
GR_PID=""
HARDY_PID=""

# Cleanup trap on termination
cleanup() {
    echo "[ENTRYPOINT] Caught termination signal. Stopping processes..."
    if [ -n "$HARDY_PID" ] && kill -0 "$HARDY_PID" 2>/dev/null; then
        echo "[ENTRYPOINT] Stopping hardy-bpa-server (PID: $HARDY_PID)..."
        kill -TERM "$HARDY_PID" 2>/dev/null || true
    fi
    if [ -n "$GR_PID" ] && kill -0 "$GR_PID" 2>/dev/null; then
        echo "[ENTRYPOINT] Stopping GNU Radio flowgraph (PID: $GR_PID)..."
        kill -TERM "$GR_PID" 2>/dev/null || true
    fi
    wait "$HARDY_PID" 2>/dev/null || true
    wait "$GR_PID" 2>/dev/null || true
    echo "[ENTRYPOINT] All processes stopped."
}
trap cleanup SIGTERM SIGINT SIGQUIT

# Start GNU Radio flowgraph if enabled
if [ "$START_FLOWGRAPH" = "true" ]; then
    if [ -f "$FLOWGRAPH_SCRIPT" ]; then
        echo "[ENTRYPOINT] Starting GNU Radio flowgraph: $FLOWGRAPH_SCRIPT (RF Frequency: ${RF_FREQ} Hz)..."
        python3 -u "$FLOWGRAPH_SCRIPT" &
        GR_PID=$!
        echo "[ENTRYPOINT] GNU Radio running with PID: $GR_PID"
        sleep 1
        if ! kill -0 "$GR_PID" 2>/dev/null; then
            if [ "$IGNORE_FLOWGRAPH_FAILURE" = "true" ]; then
                echo "[ENTRYPOINT] Warning: GNU Radio flowgraph terminated early (likely no USRP hardware available). Continuing as IGNORE_FLOWGRAPH_FAILURE=true."
                GR_PID=""
            else
                echo "[ENTRYPOINT] Error: GNU Radio flowgraph failed to start."
                exit 1
            fi
        fi
    else
        echo "[ENTRYPOINT] Flowgraph script '$FLOWGRAPH_SCRIPT' not found, skipping."
    fi
fi

# Start Hardy BPA server
echo "[ENTRYPOINT] Starting hardy-bpa-server..."
hardy-bpa-server -c /etc/hardy/hardy.yaml &
HARDY_PID=$!
echo "[ENTRYPOINT] hardy-bpa-server running with PID: $HARDY_PID"

# Give Hardy a moment to initialize
sleep 1
if ! kill -0 "$HARDY_PID" 2>/dev/null; then
    echo "[ENTRYPOINT] Error: hardy-bpa-server failed to start!"
    exit 1
fi
echo "[ENTRYPOINT] Hardy BPA is up and running."

# Run custom scenario script if specified
SCENARIO_EXIT=0
if [ -n "$SCENARIO_SCRIPT" ]; then
    if [ -f "$SCENARIO_SCRIPT" ]; then
        echo "[ENTRYPOINT] Executing scenario script: $SCENARIO_SCRIPT..."
        set +e
        if [ -x "$SCENARIO_SCRIPT" ]; then
            "$SCENARIO_SCRIPT"
        else
            bash "$SCENARIO_SCRIPT"
        fi
        SCENARIO_EXIT=$?
        set -e
        echo "[ENTRYPOINT] Scenario script finished with exit status: $SCENARIO_EXIT"
        if [ "$AUTO_EXIT" = "true" ] || [ "$AUTO_EXIT" = "1" ]; then
            echo "[ENTRYPOINT] AUTO_EXIT is enabled. Exiting with status $SCENARIO_EXIT..."
            cleanup
            exit $SCENARIO_EXIT
        fi
    else
        echo "[ENTRYPOINT] Error: SCENARIO_SCRIPT='$SCENARIO_SCRIPT' was specified but file does not exist."
    fi
fi

# If container command (CMD) arguments were passed beyond default, execute them or wait
if [ "$#" -gt 0 ] && [ "$1" != "/entrypoint.sh" ]; then
    echo "[ENTRYPOINT] Executing container command: $*"
    set +e
    "$@"
    CMD_EXIT=$?
    set -e
    if [ "$AUTO_EXIT" = "true" ] || [ "$AUTO_EXIT" = "1" ]; then
        cleanup
        exit $CMD_EXIT
    fi
fi

echo "[ENTRYPOINT] Background processes active. Waiting for signals..."
# Wait for Hardy BPA to stop or signals to arrive
wait "$HARDY_PID" 2>/dev/null || true
echo "[ENTRYPOINT] Container execution finished."
