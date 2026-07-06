#!/bin/bash
set -e

# Configuration default values
TARGET_HOST=""
TARGET_PORT="22"
TARGET_USER=""
DTN_EID=""
IPN_EID="ipn:1.0"
TELEMETRY_SERVER=""
LAYOUT=""
SOURCE_MODE=""
BINARY_PATH=""
TCPCL_BINARY_PATH=""
DEPLOY_TCPCL="no"

# Determine directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="${SCRIPT_DIR}/templates"
BUILD_DIR="/tmp/hardy-build-temp"

print_help() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -h, --host <host>          Target SSH host"
    echo "  -p, --port <port>          Target SSH port (default: 22)"
    echo "  -u, --user <user>          SSH user (defaults: 'root' for debian, 'pi-star' for pi-star)"
    echo "  -d, --dtn-eid <eid>        DTN EID (e.g. dtn://f4jxq/)"
    echo "  -i, --ipn-eid <eid>        IPN EID (default: ipn:1.0)"
    echo "  -t, --telemetry <url>      OpenTelemetry collector endpoint (e.g. http://192.168.1.100:4317)"
    echo "  -l, --layout <type>        Target layout: 'debian' or 'pi-star'"
    echo "  -s, --source <mode>        Binary source: 'path' or 'compile'"
    echo "  -b, --binary <path>        Path to local pre-compiled hardy-bpa-server"
    echo "  --tcpcl-binary <path>      Path to local pre-compiled hardy-tcpclv4-server"
    echo "  --help                     Show this help message"
}

# Parse command line options
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--host) TARGET_HOST="$2"; shift 2 ;;
        -p|--port) TARGET_PORT="$2"; shift 2 ;;
        -u|--user) TARGET_USER="$2"; shift 2 ;;
        -d|--dtn-eid) DTN_EID="$2"; shift 2 ;;
        -i|--ipn-eid) IPN_EID="$2"; shift 2 ;;
        -t|--telemetry) TELEMETRY_SERVER="$2"; shift 2 ;;
        -l|--layout) LAYOUT="$2"; shift 2 ;;
        -s|--source) SOURCE_MODE="$2"; shift 2 ;;
        -b|--binary) BINARY_PATH="$2"; shift 2 ;;
        --tcpcl-binary) TCPCL_BINARY_PATH="$2"; DEPLOY_TCPCL="yes"; shift 2 ;;
        --help) print_help; exit 0 ;;
        *) echo "Unknown option: $1"; print_help; exit 1 ;;
    esac
done

# Interactive prompts for missing parameters
echo "==============================================="
echo "        Hardy BPA Deployment Installer"
echo "==============================================="

# Host
if [ -z "$TARGET_HOST" ]; then
    read -p "Target IP/Hostname: " TARGET_HOST
    if [ -z "$TARGET_HOST" ]; then
        echo "Error: Host cannot be empty."
        exit 1
    fi
fi

# Port
if [ -z "$TARGET_PORT" ]; then
    read -p "Target SSH Port [22]: " TARGET_PORT
    TARGET_PORT=${TARGET_PORT:-22}
fi

# Layout
if [ -z "$LAYOUT" ]; then
    echo "Select target layout:"
    echo "  1) Debian (standard system paths: /usr/local/bin, /etc/hardy, /var/lib/hardy)"
    echo "  2) Pi-Star (home directory and base on USB key: /mnt/usb-storage/hardy-data)"
    read -p "Choice (1 or 2): " layout_choice
    case "$layout_choice" in
        1) LAYOUT="debian" ;;
        2) LAYOUT="pi-star" ;;
        *) echo "Invalid choice"; exit 1 ;;
    esac
fi

# SSH User defaults if not specified
if [ -z "$TARGET_USER" ]; then
    if [ "$LAYOUT" = "pi-star" ]; then
        TARGET_USER="pi-star"
    else
        TARGET_USER="root"
    fi
fi

# SSH connectivity check & architecture detection
echo "Connecting to $TARGET_USER@$TARGET_HOST:$TARGET_PORT to query system details..."
if ! TARGET_ARCH=$(ssh -o ConnectTimeout=5 -p "$TARGET_PORT" "$TARGET_USER@$TARGET_HOST" "uname -m" 2>/dev/null); then
    echo "Error: Failed to connect to $TARGET_USER@$TARGET_HOST:$TARGET_PORT via SSH."
    exit 1
fi
echo "Target system architecture: $TARGET_ARCH"

# EID with amateur radio callsign recommendation
if [ -z "$DTN_EID" ]; then
    echo ""
    echo "--- EID Configuration ---"
    echo "Note: For amateur radio nodes, it is recommended to use your callsign."
    echo "Example: dtn://f4jxq/ or dtn://g4dpz/"
    read -p "Enter DTN EID [dtn://local-node/]: " DTN_EID
    DTN_EID=${DTN_EID:-dtn://local-node/}
fi

if [ -z "$IPN_EID" ] || [ "$IPN_EID" = "ipn:1.0" ]; then
    read -p "Enter IPN EID [ipn:1.0]: " ipn_input
    IPN_EID=${ipn_input:-ipn:1.0}
fi

# Telemetry
if [ -z "$TELEMETRY_SERVER" ]; then
    echo ""
    echo "--- OpenTelemetry Telemetry ---"
    echo "Do you want to export logs and metrics to a remote OpenTelemetry collector?"
    echo "If yes, enter the OTLP gRPC endpoint URL (e.g., http://192.168.1.100:4317)."
    read -p "Telemetry endpoint (leave empty for local logs only): " TELEMETRY_SERVER
fi

# Ask if we want to deploy the standalone TCPCL CLA server
if [ "$DEPLOY_TCPCL" = "no" ] && [ -z "$TCPCL_BINARY_PATH" ]; then
    echo ""
    read -p "Do you want to deploy the standalone TCPCLv4 CLA server (hardy-tcpclv4-server)? [y/N]: " deploy_cl_choice
    case "$deploy_cl_choice" in
        [yY]|[yY][eE][sS]) DEPLOY_TCPCL="yes" ;;
        *) DEPLOY_TCPCL="no" ;;
    esac
fi

# Binary source
if [ -z "$SOURCE_MODE" ]; then
    echo ""
    echo "--- Binary Source Selection ---"
    echo "  1) Provide path to pre-compiled local binary"
    echo "  2) Clone from GitHub (official) and compile/cross-compile now"
    read -p "Choice (1 or 2): " source_choice
    case "$source_choice" in
        1) SOURCE_MODE="path" ;;
        2) SOURCE_MODE="compile" ;;
        *) echo "Invalid choice"; exit 1 ;;
    esac
fi

# Obtain Binaries
FINAL_BINARY_PATH=""
FINAL_TCPCL_BINARY_PATH=""

if [ "$SOURCE_MODE" = "path" ]; then
    if [ -z "$BINARY_PATH" ]; then
        read -p "Enter path to pre-compiled hardy-bpa-server binary: " BINARY_PATH
    fi
    if [ ! -f "$BINARY_PATH" ]; then
        echo "Error: File $BINARY_PATH does not exist."
        exit 1
    fi
    FINAL_BINARY_PATH="$BINARY_PATH"

    if [ "$DEPLOY_TCPCL" = "yes" ]; then
        if [ -z "$TCPCL_BINARY_PATH" ]; then
            read -p "Enter path to pre-compiled hardy-tcpclv4-server binary: " TCPCL_BINARY_PATH
        fi
        if [ ! -f "$TCPCL_BINARY_PATH" ]; then
            echo "Error: File $TCPCL_BINARY_PATH does not exist."
            exit 1
        fi
        FINAL_TCPCL_BINARY_PATH="$TCPCL_BINARY_PATH"
    fi
else
    echo "Preparing compilation directory at ${BUILD_DIR}..."
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    echo "Cloning official ricktaylor/hardy repository..."
    git clone --depth 1 https://github.com/ricktaylor/hardy.git "$BUILD_DIR/hardy"

    echo "Compiling binaries for target architecture: $TARGET_ARCH..."
    if [ "$TARGET_ARCH" = "x86_64" ] && [ "$(uname -m)" = "x86_64" ]; then
        echo "Performing native compilation (x86_64)..."
        cd "$BUILD_DIR/hardy"
        cargo build --release --workspace --bins
        FINAL_BINARY_PATH="$BUILD_DIR/hardy/target/release/hardy-bpa-server"
        FINAL_TCPCL_BINARY_PATH="$BUILD_DIR/hardy/target/release/hardy-tcpclv4-server"
    elif [ "$TARGET_ARCH" = "armv7l" ] || [ "$TARGET_ARCH" = "armv7" ]; then
        echo "Performing cross-compilation for armv7l (statically linked via MUSL) using Docker..."
        cd "$BUILD_DIR/hardy"
        docker run --rm \
          -v "$(pwd)":/usr/src/myapp \
          -w /usr/src/myapp \
          rust:slim-bullseye sh -c "
            apt-get update && \
            apt-get install -y gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf libc6-dev-armhf-cross protobuf-compiler && \
            rustup target add armv7-unknown-linux-musleabihf && \
            CARGO_TARGET_ARMV7_UNKNOWN_LINUX_MUSLEABIHF_LINKER=arm-linux-gnueabihf-gcc cargo build --target armv7-unknown-linux-musleabihf --release --workspace --bins && \
            chown -R $(id -u):$(id -g) target/
          "
        FINAL_BINARY_PATH="$BUILD_DIR/hardy/target/armv7-unknown-linux-musleabihf/release/hardy-bpa-server"
        FINAL_TCPCL_BINARY_PATH="$BUILD_DIR/hardy/target/armv7-unknown-linux-musleabihf/release/hardy-tcpclv4-server"
    else
        echo "Unsupported target architecture for automatic compilation: $TARGET_ARCH."
        echo "Please compile the binaries manually for $TARGET_ARCH and run this script using --source path."
        exit 1
    fi
fi

# Define target paths based on layout
if [ "$LAYOUT" = "debian" ]; then
    BIN_DEST="/usr/local/bin/hardy-bpa-server"
    TCPCL_BIN_DEST="/usr/local/bin/hardy-tcpclv4-server"
    CONF_DIR="/etc/hardy"
    CONF_DEST="${CONF_DIR}/my-config.yaml"
    ROUTES_DEST="${CONF_DIR}/static_routes.yaml"
    DB_DIR="/var/lib/hardy"
    STORE_DIR="/var/lib/hardy/bundle-storage"
    SERVICE_USER="root"
    WORKING_DIR="/var/lib/hardy"
    EXEC_START="/usr/local/bin/hardy-bpa-server -c ${CONF_DEST}"
    RUST_LOG="hardy=info"
    # Systemd Template Service definition for TCPCL
    TCPCL_EXEC_START="${TCPCL_BIN_DEST} --config ${CONF_DIR}/tcpcl-%i.yaml"
else
    # Pi-Star layout
    BIN_DEST="/home/pi-star/hardy-bpa-server"
    TCPCL_BIN_DEST="/home/pi-star/hardy-tcpclv4-server"
    CONF_DIR="/home/pi-star"
    CONF_DEST="${CONF_DIR}/my-config.yaml"
    ROUTES_DEST="/mnt/usb-storage/hardy-data/static_routes.yaml"
    DB_DIR="/mnt/usb-storage/hardy-data"
    STORE_DIR="/mnt/usb-storage/hardy-data/bundle-storage"
    SERVICE_USER="pi-star"
    WORKING_DIR="/home/pi-star"
    LOG_FILE="/mnt/usb-storage/hardy-data/hardy.log"
    EXEC_START="/bin/bash -c \"stdbuf -oL -eL ${BIN_DEST} -c ${CONF_DEST} >> ${LOG_FILE} 2>&1\""
    RUST_LOG="hardy=debug"
    # Systemd Template Service definition for TCPCL (writing logs on USB key)
    TCPCL_LOG_FILE="/mnt/usb-storage/hardy-data/tcpcl-%i.log"
    TCPCL_EXEC_START="/bin/bash -c \"stdbuf -oL -eL ${TCPCL_BIN_DEST} --config ${CONF_DIR}/tcpcl-%i.yaml >> ${TCPCL_LOG_FILE} 2>&1\""
fi

# Prepare environment values
if [ -n "$TELEMETRY_SERVER" ]; then
    OTEL_ENV="Environment=\"OTEL_EXPORTER_OTLP_ENDPOINT=${TELEMETRY_SERVER}\""
    LOG_LEVEL="info"
else
    OTEL_ENV=""
    LOG_LEVEL="debug"
fi

# Create local generated files
GEN_DIR="/tmp/hardy-deployment-gen"
rm -rf "$GEN_DIR"
mkdir -p "$GEN_DIR"

echo "Generating BPA configuration file..."
sed -e "s|@LOG_LEVEL@|${LOG_LEVEL}|g" \
    -e "s|@IPN_EID@|${IPN_EID}|g" \
    -e "s|@DTN_EID@|${DTN_EID}|g" \
    -e "s|@DB_DIR@|${DB_DIR}/|g" \
    -e "s|@STORE_DIR@|${STORE_DIR}|g" \
    -e "s|@ROUTES_FILE@|${ROUTES_DEST}|g" \
    "${TEMPLATES_DIR}/my-config.yaml.template" > "${GEN_DIR}/my-config.yaml"

echo "Generating systemd service file for BPA..."
sed -e "s|@SERVICE_USER@|${SERVICE_USER}|g" \
    -e "s|@WORKING_DIR@|${WORKING_DIR}|g" \
    -e "s|@OTEL_ENV@|${OTEL_ENV}|g" \
    -e "s|@RUST_LOG@|${RUST_LOG}|g" \
    -e "s|@EXEC_START@|${EXEC_START}|g" \
    "${TEMPLATES_DIR}/hardy-bpa.service.template" > "${GEN_DIR}/hardy-bpa.service"

if [ "$DEPLOY_TCPCL" = "yes" ]; then
    echo "Generating systemd template service file for TCPCL..."
    sed -e "s|@SERVICE_USER@|${SERVICE_USER}|g" \
        -e "s|@WORKING_DIR@|${WORKING_DIR}|g" \
        -e "s|@OTEL_ENV@|${OTEL_ENV}|g" \
        -e "s|@RUST_LOG@|${RUST_LOG}|g" \
        -e "s|@EXEC_START@|${TCPCL_EXEC_START}|g" \
        "${TEMPLATES_DIR}/hardy-tcpcl@.service.template" > "${GEN_DIR}/hardy-tcpcl@.service"
fi

# Interactive TCPCL connection instance configuration (like Wireguard wg0, wg1...)
INSTANCES_TO_ENABLE=()
if [ "$DEPLOY_TCPCL" = "yes" ]; then
    echo ""
    echo "--- Standalone TCPCL Connection Setup ---"
    read -p "Would you like to configure an active outbound TCPCL instance now (e.g. like wg0)? [y/N]: " add_inst_choice
    case "$add_inst_choice" in
        [yY]|[yY][eE][sS])
            read -p "Instance name (e.g. wg0, pistar, dave): " INST_NAME
            read -p "Local listening port [4557]: " LISTEN_PORT
            LISTEN_PORT=${LISTEN_PORT:-4557}
            read -p "Remote peer address & port (e.g. 192.168.3.2:4556): " PEER_ADDRESS
            if [ -n "$INST_NAME" ] && [ -n "$PEER_ADDRESS" ]; then
                echo "Generating tcpcl-${INST_NAME}.yaml configuration..."
                sed -e "s|@INSTANCE_NAME@|${INST_NAME}|g" \
                    -e "s|@LOG_LEVEL@|${LOG_LEVEL}|g" \
                    -e "s|@LISTEN_PORT@|${LISTEN_PORT}|g" \
                    -e "s|@PEER_ADDRESS@|${PEER_ADDRESS}|g" \
                    "${TEMPLATES_DIR}/tcpcl.yaml.template" > "${GEN_DIR}/tcpcl-${INST_NAME}.yaml"
                INSTANCES_TO_ENABLE+=("${INST_NAME}")
            fi
            ;;
    esac
fi

# Target deployment commands
echo "Deploying to target machine..."

# Check if filesystem is read-only
IS_RO=$(ssh -p "$TARGET_PORT" "$TARGET_USER@$TARGET_HOST" "mount | grep 'on / type' | grep -q '(ro,' && echo 'yes' || echo 'no'")

if [ "$IS_RO" = "yes" ]; then
    echo "Target filesystem is Read-Only. Remounting to Read-Write..."
    ssh -p "$TARGET_PORT" "$TARGET_USER@$TARGET_HOST" "sudo mount -o remount,rw /"
fi

# Setup directories
echo "Creating necessary directories on target..."
if [ "$LAYOUT" = "debian" ]; then
    ssh -p "$TARGET_PORT" "$TARGET_USER@$TARGET_HOST" "sudo mkdir -p ${CONF_DIR} ${DB_DIR} ${STORE_DIR}"
else
    # Pi-Star
    ssh -p "$TARGET_PORT" "$TARGET_USER@$TARGET_HOST" "mkdir -p ${CONF_DIR} && sudo mkdir -p ${DB_DIR} ${STORE_DIR} && sudo chown -R pi-star:pi-star ${DB_DIR}"
fi

# Copy BPA binary
echo "Copying BPA binary to target..."
scp -P "$TARGET_PORT" "$FINAL_BINARY_PATH" "$TARGET_USER@$TARGET_HOST:/tmp/hardy-bpa-server"
if [ "$LAYOUT" = "debian" ]; then
    ssh -p "$TARGET_PORT" "$TARGET_USER@$TARGET_HOST" "sudo mv /tmp/hardy-bpa-server ${BIN_DEST} && sudo chmod +x ${BIN_DEST}"
else
    ssh -p "$TARGET_PORT" "$TARGET_USER@$TARGET_HOST" "mv /tmp/hardy-bpa-server ${BIN_DEST} && chmod +x ${BIN_DEST}"
fi

# Copy TCPCL binary if enabled
if [ "$DEPLOY_TCPCL" = "yes" ]; then
    echo "Copying TCPCL binary to target..."
    scp -P "$TARGET_PORT" "$FINAL_TCPCL_BINARY_PATH" "$TARGET_USER@$TARGET_HOST:/tmp/hardy-tcpclv4-server"
    if [ "$LAYOUT" = "debian" ]; then
        ssh -p "$TARGET_PORT" "$TARGET_USER@$TARGET_HOST" "sudo mv /tmp/hardy-tcpclv4-server ${TCPCL_BIN_DEST} && sudo chmod +x ${TCPCL_BIN_DEST}"
    else
        ssh -p "$TARGET_PORT" "$TARGET_USER@$TARGET_HOST" "mv /tmp/hardy-tcpclv4-server ${TCPCL_BIN_DEST} && chmod +x ${TCPCL_BIN_DEST}"
    fi
fi

# Copy BPA config
echo "Copying configuration to target..."
scp -P "$TARGET_PORT" "${GEN_DIR}/my-config.yaml" "$TARGET_USER@$TARGET_HOST:/tmp/my-config.yaml"
if [ "$LAYOUT" = "debian" ]; then
    ssh -p "$TARGET_PORT" "$TARGET_USER@$TARGET_HOST" "sudo mv /tmp/my-config.yaml ${CONF_DEST}"
else
    ssh -p "$TARGET_PORT" "$TARGET_USER@$TARGET_HOST" "mv /tmp/my-config.yaml ${CONF_DEST}"
fi

# Create empty routes file if it doesn't exist
ssh -p "$TARGET_PORT" "$TARGET_USER@$TARGET_HOST" "[ ! -f ${ROUTES_DEST} ] && sudo touch ${ROUTES_DEST} && sudo chown ${SERVICE_USER} ${ROUTES_DEST} || true"

# Copy systemd units
echo "Copying systemd unit..."
scp -P "$TARGET_PORT" "${GEN_DIR}/hardy-bpa.service" "$TARGET_USER@$TARGET_HOST:/tmp/hardy-bpa.service"
ssh -p "$TARGET_PORT" "$TARGET_USER@$TARGET_HOST" "sudo mv /tmp/hardy-bpa.service /etc/systemd/system/hardy-bpa.service"

if [ "$DEPLOY_TCPCL" = "yes" ]; then
    scp -P "$TARGET_PORT" "${GEN_DIR}/hardy-tcpcl@.service" "$TARGET_USER@$TARGET_HOST:/tmp/hardy-tcpcl@.service"
    ssh -p "$TARGET_PORT" "$TARGET_USER@$TARGET_HOST" "sudo mv /tmp/hardy-tcpcl@.service /etc/systemd/system/hardy-tcpcl@.service"
fi

# Deploy newly configured TCPCL instances
for inst in "${INSTANCES_TO_ENABLE[@]}"; do
    echo "Deploying newly configured instance: ${inst}..."
    scp -P "$TARGET_PORT" "${GEN_DIR}/tcpcl-${inst}.yaml" "$TARGET_USER@$TARGET_HOST:/tmp/tcpcl-${inst}.yaml"
    if [ "$LAYOUT" = "debian" ]; then
        ssh -p "$TARGET_PORT" "$TARGET_USER@$TARGET_HOST" "sudo mv /tmp/tcpcl-${inst}.yaml ${CONF_DIR}/tcpcl-${inst}.yaml"
    else
        ssh -p "$TARGET_PORT" "$TARGET_USER@$TARGET_HOST" "mv /tmp/tcpcl-${inst}.yaml ${CONF_DIR}/tcpcl-${inst}.yaml"
    fi
done

# Look for and deploy existing local tcpcl-*.yaml configuration files (like Wireguard wg0, wg1 files)
for f in "${SCRIPT_DIR}"/tcpcl-*.yaml; do
    [ -e "$f" ] || continue
    inst_name=$(basename "$f" .yaml | sed 's/^tcpcl-//')
    echo "Deploying existing configuration for instance: ${inst_name}..."
    scp -P "$TARGET_PORT" "$f" "$TARGET_USER@$TARGET_HOST:/tmp/tcpcl-${inst_name}.yaml"
    if [ "$LAYOUT" = "debian" ]; then
        ssh -p "$TARGET_PORT" "$TARGET_USER@$TARGET_HOST" "sudo mv /tmp/tcpcl-${inst_name}.yaml ${CONF_DIR}/tcpcl-${inst_name}.yaml"
    else
        ssh -p "$TARGET_PORT" "$TARGET_USER@$TARGET_HOST" "mv /tmp/tcpcl-${inst_name}.yaml ${CONF_DIR}/tcpcl-${inst_name}.yaml"
    fi
    INSTANCES_TO_ENABLE+=("${inst_name}")
done

# Start/enable services
echo "Reloading systemd daemon and starting services..."
ssh -p "$TARGET_PORT" "$TARGET_USER@$TARGET_HOST" "sudo systemctl daemon-reload && sudo systemctl enable hardy-bpa && sudo systemctl restart hardy-bpa"

# Start and enable all configured TCPCL template instances
for inst in "${INSTANCES_TO_ENABLE[@]}"; do
    echo "Enabling and starting service: hardy-tcpcl@${inst}..."
    ssh -p "$TARGET_PORT" "$TARGET_USER@$TARGET_HOST" "sudo systemctl enable hardy-tcpcl@${inst} && sudo systemctl restart hardy-tcpcl@${inst}"
done

# Remount back to Read-Only if it was originally read-only
if [ "$IS_RO" = "yes" ]; then
    echo "Remounting target filesystem back to Read-Only..."
    ssh -p "$TARGET_PORT" "$TARGET_USER@$TARGET_HOST" "sudo mount -o remount,ro /"
fi

echo "==============================================="
echo "Deployment successful!"
echo "Service status (BPA):"
ssh -p "$TARGET_PORT" "$TARGET_USER@$TARGET_HOST" "sudo systemctl status hardy-bpa --no-pager"

for inst in "${INSTANCES_TO_ENABLE[@]}"; do
    echo ""
    echo "Service status (hardy-tcpcl@${inst}):"
    ssh -p "$TARGET_PORT" "$TARGET_USER@$TARGET_HOST" "sudo systemctl status hardy-tcpcl@${inst} --no-pager"
done
echo "==============================================="

# Cleanup build directory
if [ "$SOURCE_MODE" = "compile" ]; then
    rm -rf "$BUILD_DIR"
fi
rm -rf "$GEN_DIR"
