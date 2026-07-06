# Hardy Deployment Automator

This repository contains deployment and configuration scripts for deploying **Hardy**, a Rust-based implementation of the Bundle Protocol Agent (BPA) v7, onto remote Linux hosts.

## Target Audience & Layouts

This script is designed for two main target profiles:

1. **Standard Debian Layout**: Installs Hardy following standard UNIX conventions.
   - Binary path: `/usr/local/bin/hardy-bpa-server`
   - Config path: `/etc/hardy/my-config.yaml`
   - Database/storage path: `/var/lib/hardy`
   - Logs: Routed directly to **Systemd Journald** (`journalctl -u hardy-bpa`).
   - Run User: `root` (or custom user).

2. **Pi-Star Layout**: Specifically designed for Raspberry Pi/SBC radio hotspots.
   - Binary path: `/home/pi-star/hardy-bpa-server`
   - Config path: `/home/pi-star/my-config.yaml`
   - Database/storage/routes: Placed on the external USB key mount (`/mnt/usb-storage/hardy-data/`).
   - Logs: Redirected to a persistent log file on the USB key (`/mnt/usb-storage/hardy-data/hardy.log`).
   - Run User: `pi-star`
   - **Automated Read-Only filesystem handling**: The script will automatically detect if the target filesystem is read-only (`ro`), remount it to read-write (`rw`) to perform the deployment, and remount it back to read-only (`ro`) when finished.

## Usage

You can run the script in two ways: **interactively** or **via command-line arguments**.

### Interactive Mode

Simply launch the script without arguments, and it will guide you step-by-step:
```bash
./deploy.sh
```

### Argument Mode (Hybrid)

You can pass parameters as options. Any missing parameters will be prompted interactively with smart defaults.
```bash
./deploy.sh --host 192.168.3.2 --port 22 --layout pi-star --dtn-eid dtn://f4jxq/ --source compile
```

### Command Line Options

```text
  -h, --host <host>          Target SSH host
  -p, --port <port>          Target SSH port (default: 22)
  -u, --user <user>          SSH user (defaults: 'root' for debian, 'pi-star' for pi-star)
  -d, --dtn-eid <eid>        DTN EID (e.g. dtn://f4jxq/ - Amateur radio callsigns recommended)
  -i, --ipn-eid <eid>        IPN EID (default: ipn:1.0)
  -t, --telemetry <url>      OpenTelemetry OTLP endpoint (e.g. http://192.168.1.100:4317)
  -l, --layout <type>        Target layout: 'debian' or 'pi-star'
  -s, --source <mode>        Binary source: 'path' (local path) or 'compile' (clone & compile)
  -b, --binary <path>        Path to local pre-compiled binary (required if source is 'path')
```

## Binary Compilation Modes

The script supports two ways of obtaining the binary:

1. **Pre-compiled path (`--source path`)**:
   Point the script to a pre-compiled local `hardy-bpa-server` binary, and it will copy it directly.

2. **Automated build (`--source compile`)**:
   The script will clone a fresh copy of the official `ricktaylor/hardy` repository into a temporary folder. It then queries the target system architecture via SSH:
   - If target is **`x86_64`** and the host is `x86_64`, it compiles natively.
   - If target is **`armv7l` / `armv7`** (like Raspberry Pi / Pi-Star), it automatically launches a Debian Bullseye-based Docker container to cross-compile the binary using `arm-linux-gnueabihf` to avoid Glibc mismatches.
