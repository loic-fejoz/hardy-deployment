# Hardy Deployment Automator

This repository contains deployment and configuration scripts for deploying [**Hardy**](https://github.com/ricktaylor/hardy), a Rust-based implementation of the Bundle Protocol Agent (BPA) v7, onto remote Linux hosts.

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
  -i, --ipn-eid <eid>        IPN EID (default: random EID > 256)
  -t, --telemetry <url>      OpenTelemetry OTLP endpoint (e.g. http://192.168.1.100:4317)
  -l, --layout <type>        Target layout: 'debian' or 'pi-star'
  -s, --source <mode>        Binary source: 'path' (local path) or 'compile' (clone & compile)
  -b, --binary <path>        Path to local pre-compiled binary (required if source is 'path')
```

> [!NOTE]
> **IPN EID Default Selection**: To avoid node ID conflicts on the ARDC [RADIANT project](https://radiant.amsat-uk.org/) network (which assigns values below 256), `deploy.sh` generates a random IPN node ID greater than 256 (in the range 257-65256) by default if none is explicitly provided. Hams and operators are encouraged to specify their allocated EID if they are connecting to an existing network.

## Binary Compilation Modes

The script supports two ways of obtaining the binary:

1. **Pre-compiled path (`--source path`)**:
   Point the script to a pre-compiled local `hardy-bpa-server` binary, and it will copy it directly.

2. **Automated build (`--source compile`)**:
   The script will clone a fresh copy of the official `ricktaylor/hardy` repository into a temporary folder. It then queries the target system architecture via SSH:
   - If target is **`x86_64`** and the host is `x86_64`, it compiles natively.
     * **CPU Optimization Note**: To prevent "Illegal Instruction" (`signal=ILL`) crashes on lower-end target CPUs (like Intel Celerons), native compilation enforces generic x86-64 code generation (`RUSTFLAGS="-C target-cpu=generic"`). If you want to compile and optimize code specifically for your target's microarchitecture (e.g. using AVX/AVX2 on high-end servers), we recommend compiling the binary manually with appropriate flags (e.g. `RUSTFLAGS="-C target-cpu=native"`) and deploying it via the `--source path` option.
   - If target is **`armv7l` / `armv7`** (like Raspberry Pi / Pi-Star), it automatically launches a Debian Bullseye-based Docker container to cross-compile the binary using `arm-linux-gnueabihf` to avoid Glibc mismatches.

## Opinionated Design Choices

To ensure optimal performance, resource conservation, and ease of maintenance in real-world environments, `deploy.sh` makes the following opinionated design choices:

1. **Storage Location & Disk Partition Protection (`debian` layout)**:
   - **Behavior**: If the `/srv` directory exists on the target machine, the script automatically configures all Hardy databases and bundle storage under `/srv/hardy/` (instead of `/var/lib/hardy/`).
   - **Rationale**: In standard Debian servers, `/var` is often partitioned with a small size (e.g., 7GB) while `/srv` receives the bulk of the disk. Since DTN bundle queues can grow rapidly when connectivity is lost, this redirection prevents Hardy from filling up the `/var` partition, which would otherwise crash system logs and lock out SSH access.
   - **Transparency**: This path change is explicitly written into the Hardy configuration YAML and systemd service `WorkingDirectory=` directive. If `/srv` is not present, the script seamlessly falls back to `/var/lib/hardy/`.

2. **Log Levels & Remote Telemetry Control**:
   - **Without Telemetry (Local logs)**: The log level is set to `debug` (`log-level: "debug"` and `RUST_LOG=hardy=debug`), ensuring verbose diagnostic output is routed to local logs (journald) for easier local troubleshooting.
   - **With Telemetry (`--telemetry`)**: The log level is automatically restricted to `info` (`log-level: "info"` and `RUST_LOG=hardy=info`) to conserve network bandwidth and avoid overwhelming the remote OpenTelemetry collector.

3. **Workspace Compilation Excludes**:
   - **Behavior**: When compiling from source (`--source compile`), the build command runs with `--workspace --bins` but explicitly excludes all workspace fuzzing targets (e.g., `--exclude hardy-bpa-fuzz`, etc.).
   - **Rationale**: Fuzz targets depend on `libfuzzer-sys` which requires a C++ compiler toolchain. Excluding them allows native and cross-compilation (e.g., inside minimal Docker environments) without requiring complex C++ compiler setups.

4. **Multi-Tunnel TCPCL Instance Management**:
   - **Behavior**: Outbound TCPCL connections are defined in independent configuration files named `tcpcl-<instance>.yaml` and run as separate systemd service instances (`hardy-tcpcl@<instance>`).
   - **Rationale**: This follows a pattern similar to WireGuard (`wg0`, `wg1`, etc.), allowing independent start, stop, reload, and monitoring of each tunnel without affecting the main BPA server or other tunnels.

5. **Security Hardening (Firewall, Services & Sandboxing)**:
   - **Unprivileged User**: On Debian targets, Hardy is installed under a dedicated system user `hardy` (created without login shell) rather than `root`.
   - **Systemd Sandboxing**: Services are hardened using systemd isolation parameters (`PrivateTmp=yes`, `ProtectSystem=strict`, `ProtectHome=yes`, `NoNewPrivileges=yes`, and `ReadWritePaths` limited to configuration and storage paths).
   - **Firewall Rules**: The script supports both `iptables` and modern `nftables` firewalls. If `/etc/iptables.rules` is present, it is dynamically updated to restrict SSH, HTTP, HTTPS, Samba, and administrative ports to the target's active local interface subnet (dynamically queried at runtime, falling back to `192.168.0.0/16`), while opening only the DTN port `4556` for both the local subnet and the WireGuard interface (`wg0`). On modern Debian systems using `nftables` (like Debian 13/Trixie), the script dynamically edits `/etc/nftables.conf` to insert similar whitelist rules for port `4556`. Unused services (`smbd`, `nmbd`, `cups`, `avahi-daemon`) are automatically disabled if present.
   - **Shell-Only implementation**: Subnet detection and configuration editing are performed entirely via inline POSIX `awk` and standard shell scripts, eliminating external language runtime dependencies like Python on the target.

6. **Optional Hardening Packages**:
   - **fail2ban**: Prompts to install and configure `fail2ban` on the target machine (or via `--install-fail2ban`) to protect SSH from brute-force attempts.

7. **Automatic Clock Synchronization (NTP)**:
    - **Behavior**: The script automatically tries to force-synchronize the target's clock using `chrony`, `ntpdate` (querying `debian.pool.ntp.org`), or `systemd-timesyncd` (in order of availability). It also ensures that systemd's network time synchronization is enabled via `timedatectl`. If no synchronization client succeeds, it attempts to install `systemd-timesyncd` automatically. If it still fails, a prominent red colorized error box is displayed to warn the operator.
    - **Rationale**: Because the Bundle Protocol (RFC 9171) relies on absolute timestamps relative to the DTN Epoch (2000-01-01), accurate time synchronization is essential. If target clocks mismatch by more than a bundle's configured lifetime, incoming bundles will be immediately rejected and dropped by the BPA as expired.
