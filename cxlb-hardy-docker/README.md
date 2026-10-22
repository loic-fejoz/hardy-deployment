# CorteXlab Hardy Deployment

This directory contains the Docker packaging to deploy [Hardy](https://github.com/loic-fejoz/hardy) (with Licklider Transport Protocol LTP CLA) and [dtn-hdy-utils](https://github.com/loic-fejoz/dtn-hdy-utils) alongside GNU Radio onto [CorteXlab](https://www.cortexlab.fr/) nodes.

---

## Architecture Overview

```
                      +---------------------------------------+
                      |          CorteXlab Container          |
                      |                                       |
                      |   +-------------------------------+   |
                      |   |    Custom Scenario Script     |   |
                      |   |   (dtnping, dtnsend, etc.)    |   |
                      |   +---------------+---------------+   |
                      |                   | gRPC (50051)      |
                      |   +---------------v---------------+   |
                      |   |       hardy-bpa-server        |   |
                      |   |       with LTP CLA            |   |
                      |   +-------+---------------+-------+   |
                      |    TX UDP | 52001  52002  ^ RX UDP    |
                      |           v               |           |
                      |   +-----------------------+-------+   |
                      |   | GNU Radio Flowgraph (GFSK)    |   |
                      |   |      (udp_gfsk.py)            |   |
                      |   +---------------+---------------+   |
                      +-------------------|-------------------+
                                          | UHD / USRP (RF 434 MHz)
                                          v
                                   Air Interface
```

Each container instance:
1. Generates Hardy's configuration from environment variables (local EID, Engine ID, and LTP peer addresses).
2. Starts the pre-compiled GNU Radio flowgraph (`udp_gfsk.py`) in the background.
3. Starts `hardy-bpa-server` with LTP CLA binding to `0.0.0.0:52002` (RX from GNU Radio) and targeting `127.0.0.1:52001` (TX to GNU Radio).
4. Optionally executes a custom bash scenario script (provided via environment variable or mounted volume) to send/receive bundles.
5. Emits all logs to standard output for straightforward inspection via `docker logs`.

---

## Build Instructions

Build the image using Docker and the provided `Makefile`:

```bash
make build
# or with a custom image name
make build IMAGE_NAME=my-registry.example.org/cxlb-hardy:latest
```

The build uses a multi-stage Docker build:
- **Stage 1 (Builder)**: Clones and compiles `hardy-bpa-server` (branch `feat/ltp-cla`) and `dtn-hdy-utils` tools from source using the official Rust image.
- **Stage 2 (Runtime)**: Based on `cxlb-docker-gnuradio-3.10:latest`, installs runtime dependencies, compiles `udp_gfsk.grc` via `grcc`, and installs the entrypoint script and binaries.

---

## Smoke Test

You can test the container locally on your host even without USRP hardware:

```bash
make run-test
```

This target launches a test container, checks the presence and version of `hardy-bpa-server`, tests the availability of `dtn-hdy-utils` (`dtnping`, `dtnsend`, `dtnprint`, `dtnfiles`, `dtnbasket`, `hdy-stats`), inspects the generated configuration, and cleans up.

---

## Environment Variables Configuration

| Variable | Default | Description |
|---|---|---|
| `NODE_EID` | `ipn:100.0` | Local BPA node EID (supports `ipn:...` and `dtn://...`) |
| `LTP_ENGINE_ID` | `100` | Local LTP Engine ID |
| `LTP_PEERS` | *empty* | Comma-separated list of remote peers: `"<engine_id>=<node_eid>, ..."` |
| `LTP_TX_HOST` | `127.0.0.1` | GNU Radio UDP TX input host |
| `LTP_TX_PORT` | `52001` | GNU Radio UDP TX input port |
| `LTP_RX_PORT` | `52002` | Local UDP bind port for receiving LTP segments from GNU Radio |
| `LTP_MAX_SEGMENT_LEN` | `1000` | Maximum LTP segment payload length (bytes) |
| `LTP_RTT` | `1s` | LTP round-trip time estimation |
| `LTP_ACK_MARGIN` | `250ms` | LTP ACK margin delay |
| `SCENARIO_SCRIPT` | *empty* | Absolute path to custom bash script to run on startup |
| `AUTO_EXIT` | `false` | If `true`, the container terminates with the exit code of `SCENARIO_SCRIPT` |
| `START_FLOWGRAPH` | `true` | Set to `false` to disable starting GNU Radio flowgraph |
| `FLOWGRAPH_SCRIPT` | `/opt/cxlb-hardy/flowgraphs/udp_gfsk.py` | Path to compiled GNU Radio Python script |
| `IGNORE_FLOWGRAPH_FAILURE` | `true` | If `true`, container will not crash if USRP hardware is absent |
| `LOG_LEVEL` | `info` | Hardy log level (`trace`, `debug`, `info`, `warn`, `error`) |

---

## CorteXlab Experiment Usage Example

Deploying two nodes (e.g. Node 1 and Node 2):

### Node 1 (Sender / Initiator)
```bash
docker run -d \
  --name node1 \
  --privileged \
  -v /dev/bus/usb:/dev/bus/usb \
  -v /shared/scenarios:/scenarios:ro \
  -e NODE_EID="ipn:100.0" \
  -e LTP_ENGINE_ID=100 \
  -e LTP_PEERS="200=ipn:200.0" \
  -e SCENARIO_SCRIPT="/scenarios/sender.sh" \
  -e AUTO_EXIT=true \
  cxlb-hardy:latest
```

### Node 2 (Receiver)
```bash
docker run -d \
  --name node2 \
  --privileged \
  -v /dev/bus/usb:/dev/bus/usb \
  -e NODE_EID="ipn:200.0" \
  -e LTP_ENGINE_ID=200 \
  -e LTP_PEERS="100=ipn:100.0" \
  -e AUTO_EXIT=false \
  cxlb-hardy:latest
```

### Example Scenario Script (`sender.sh`)

```bash
#!/usr/bin/env bash
set -e

echo "Waiting for links to stabilize..."
sleep 5

echo "Testing connectivity with dtnping..."
dtnping -c 3 ipn:200.0

echo "Sending test bundle..."
echo "Hello from CorteXlab node 100!" | dtnsend -r ipn:200.0/test

echo "Scenario complete!"
```
