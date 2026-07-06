#!/bin/bash
set -e

# Configuration default values
TARGET_HOST=""
TARGET_PORT="22"
TARGET_USER=""
DTN_EID=""
# Generate a random IPN Node ID > 256 to avoid collisions (e.g. with ARDC RADIANT project)
RANDOM_NODE=$((257 + RANDOM % 65000))
IPN_EID="ipn:${RANDOM_NODE}.0"
IPN_EID_PASSED="no"
TELEMETRY_SERVER=""
TELEMETRY_PASSED=""
LAYOUT=""
SOURCE_MODE=""
BINARY_PATH=""
TCPCL_BINARY_PATH=""
DEPLOY_TCPCL="no"
NON_INTERACTIVE="no"
INSTALL_FAIL2BAN="no"
INSTALL_UNATTENDED_UPGRADES="no"

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
    echo "  -i, --ipn-eid <eid>        IPN EID (default: random EID > 256)"
    echo "  -t, --telemetry <url>      OpenTelemetry collector endpoint (e.g. http://192.168.1.100:4317)"
    echo "  -l, --layout <type>        Target layout: 'debian' or 'pi-star'"
    echo "  -s, --source <mode>        Binary source: 'path' or 'compile'"
    echo "  -b, --binary <path>        Path to local pre-compiled hardy-bpa-server"
    echo "  --tcpcl-binary <path>      Path to local pre-compiled hardy-tcpclv4-server"
    echo "  --deploy-tcpcl             Force compilation/deployment of standalone TCPCL CLA"
    echo "  --install-fail2ban         Automatically install fail2ban on target"
    echo "  --install-unattended-upgrades Automatically install unattended-upgrades on target"
    echo "  -y, --yes, --non-interactive  Run non-interactively without prompting"
    echo "  --help                     Show this help message"
}

# Parse command line options
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--host) TARGET_HOST="$2"; shift 2 ;;
        -p|--port) TARGET_PORT="$2"; shift 2 ;;
        -u|--user) TARGET_USER="$2"; shift 2 ;;
        -d|--dtn-eid) DTN_EID="$2"; shift 2 ;;
        --install-fail2ban) INSTALL_FAIL2BAN="yes"; shift 1 ;;
        --install-unattended-upgrades) INSTALL_UNATTENDED_UPGRADES="yes"; shift 1 ;;
        -i|--ipn-eid) IPN_EID="$2"; IPN_EID_PASSED="yes"; shift 2 ;;
        -t|--telemetry) TELEMETRY_SERVER="$2"; TELEMETRY_PASSED="yes"; shift 2 ;;
        -l|--layout) LAYOUT="$2"; shift 2 ;;
        -s|--source) SOURCE_MODE="$2"; shift 2 ;;
        -b|--binary) BINARY_PATH="$2"; shift 2 ;;
        --tcpcl-binary) TCPCL_BINARY_PATH="$2"; DEPLOY_TCPCL="yes"; shift 2 ;;
        --deploy-tcpcl) DEPLOY_TCPCL="yes"; shift 1 ;;
        -y|--yes|--non-interactive) NON_INTERACTIVE="yes"; shift 1 ;;
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
    if [ "$NON_INTERACTIVE" = "yes" ]; then
        echo "Error: Target host is required in non-interactive mode."
        exit 1
    fi
    read -p "Target IP/Hostname: " TARGET_HOST
    if [ -z "$TARGET_HOST" ]; then
        echo "Error: Host cannot be empty."
        exit 1
    fi
fi

# Port
if [ -z "$TARGET_PORT" ]; then
    if [ "$NON_INTERACTIVE" = "yes" ]; then
        TARGET_PORT="22"
    else
        read -p "Target SSH Port [22]: " TARGET_PORT
        TARGET_PORT=${TARGET_PORT:-22}
    fi
fi

# Layout
if [ -z "$LAYOUT" ]; then
    if [ "$NON_INTERACTIVE" = "yes" ]; then
        LAYOUT="debian"
    else
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
fi

# SSH User prompts and defaults
if [ -z "$TARGET_USER" ]; then
    if [ "$NON_INTERACTIVE" = "yes" ]; then
        if [ "$LAYOUT" = "pi-star" ]; then
            TARGET_USER="pi-star"
        else
            TARGET_USER="root"
        fi
    else
        default_user="root"
        if [ "$LAYOUT" = "pi-star" ]; then
            default_user="pi-star"
        fi
        read -p "Target SSH User [${default_user}]: " TARGET_USER
        TARGET_USER=${TARGET_USER:-${default_user}}
    fi
fi

# Define SSH commands for queries (no TTY) and actions (forces TTY in interactive mode to support sudo password prompting)
SSH_QUERY_CMD="ssh -p ${TARGET_PORT}"
SSH_ACTION_CMD="ssh -p ${TARGET_PORT}"
if [ "$NON_INTERACTIVE" = "no" ]; then
    SSH_ACTION_CMD="ssh -t -p ${TARGET_PORT}"
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
    if [ "$NON_INTERACTIVE" = "yes" ]; then
        DTN_EID="dtn://local-node/"
    else
        echo ""
        echo "--- EID Configuration ---"
        echo "Note: For amateur radio nodes, it is recommended to use your callsign."
        echo "Example: dtn://f4jxq/ or dtn://g4dpz/"
        read -p "Enter DTN EID [dtn://local-node/]: " DTN_EID
        DTN_EID=${DTN_EID:-dtn://local-node/}
    fi
fi

if [ "$IPN_EID_PASSED" = "no" ]; then
    if [ "$NON_INTERACTIVE" = "no" ]; then
        read -p "Enter IPN EID [${IPN_EID}]: " ipn_input
        IPN_EID=${ipn_input:-$IPN_EID}
    fi
fi

# Telemetry
if [ -z "$TELEMETRY_SERVER" ] && [ -z "$TELEMETRY_PASSED" ]; then
    if [ "$NON_INTERACTIVE" = "yes" ]; then
        TELEMETRY_SERVER=""
    else
        echo ""
        echo "--- OpenTelemetry Telemetry ---"
        echo "Do you want to export logs and metrics to a remote OpenTelemetry collector?"
        echo "If yes, enter the OTLP gRPC endpoint URL (e.g., http://192.168.1.100:4317)."
        read -p "Telemetry endpoint (leave empty for local logs only): " TELEMETRY_SERVER
    fi
fi

# Ask if we want to deploy the standalone TCPCL CLA server
if [ "$DEPLOY_TCPCL" = "no" ] && [ -z "$TCPCL_BINARY_PATH" ]; then
    if [ "$NON_INTERACTIVE" = "yes" ]; then
        DEPLOY_TCPCL="no"
    else
        echo ""
        read -p "Do you want to deploy the standalone TCPCLv4 CLA server (hardy-tcpclv4-server)? [y/N]: " deploy_cl_choice
        case "$deploy_cl_choice" in
            [yY]|[yY][eE][sS]) DEPLOY_TCPCL="yes" ;;
            *) DEPLOY_TCPCL="no" ;;
        esac
    fi
fi

# Host Security Extensions Prompts
if [ "$NON_INTERACTIVE" = "no" ]; then
    echo ""
    echo "--- Host Security Extensions ---"
    read -p "Would you like to install fail2ban for SSH security hardening? [y/N]: " f2b_choice
    case "$f2b_choice" in
        [yY]|[yY][eE][sS]) INSTALL_FAIL2BAN="yes" ;;
        *) INSTALL_FAIL2BAN="no" ;;
    esac

    read -p "Would you like to install unattended-upgrades for automatic security updates? [y/N]: " ua_choice
    case "$ua_choice" in
        [yY]|[yY][eE][sS]) INSTALL_UNATTENDED_UPGRADES="yes" ;;
        *) INSTALL_UNATTENDED_UPGRADES="no" ;;
    esac
fi

# Binary source
if [ -z "$SOURCE_MODE" ]; then
    if [ "$NON_INTERACTIVE" = "yes" ]; then
        SOURCE_MODE="path"
    else
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
fi

# Obtain Binaries
FINAL_BINARY_PATH=""
FINAL_TCPCL_BINARY_PATH=""

if [ "$SOURCE_MODE" = "path" ]; then
    if [ -z "$BINARY_PATH" ]; then
        if [ "$NON_INTERACTIVE" = "yes" ]; then
            echo "Error: Binary path is required in non-interactive mode."
            exit 1
        fi
        read -p "Enter path to pre-compiled hardy-bpa-server binary: " BINARY_PATH
    fi
    if [ ! -f "$BINARY_PATH" ]; then
        echo "Error: File $BINARY_PATH does not exist."
        exit 1
    fi
    FINAL_BINARY_PATH="$BINARY_PATH"

    if [ "$DEPLOY_TCPCL" = "yes" ]; then
        if [ -z "$TCPCL_BINARY_PATH" ]; then
            if [ "$NON_INTERACTIVE" = "yes" ]; then
                echo "Error: TCPCL binary path is required in non-interactive mode."
                exit 1
            fi
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
    CARGO_EXCLUDES="--exclude hardy-bpa-fuzz --exclude hardy-bpv7-fuzz --exclude hardy-cbor-fuzz --exclude hardy-eid-patterns-fuzz --exclude hardy-tcpclv4-fuzz"
    if [ "$DEPLOY_TCPCL" = "no" ]; then
        CARGO_EXCLUDES="${CARGO_EXCLUDES} --exclude hardy-tcpclv4-server"
    fi

    if [ "$TARGET_ARCH" = "x86_64" ] && [ "$(uname -m)" = "x86_64" ]; then
        echo "Performing native compilation (x86_64)..."
        cd "$BUILD_DIR/hardy"
        RUSTFLAGS="-C target-cpu=generic" cargo build --all-features --release --workspace --bins ${CARGO_EXCLUDES}
        FINAL_BINARY_PATH="$BUILD_DIR/hardy/target/release/hardy-bpa-server"
        if [ "$DEPLOY_TCPCL" = "yes" ]; then
            FINAL_TCPCL_BINARY_PATH="$BUILD_DIR/hardy/target/release/hardy-tcpclv4-server"
        fi
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
            CARGO_TARGET_ARMV7_UNKNOWN_LINUX_MUSLEABIHF_LINKER=arm-linux-gnueabihf-gcc cargo build --all-features --target armv7-unknown-linux-musleabihf --release --workspace --bins ${CARGO_EXCLUDES} && \
            chown -R \$(id -u):\$(id -g) target/
          "
        FINAL_BINARY_PATH="$BUILD_DIR/hardy/target/armv7-unknown-linux-musleabihf/release/hardy-bpa-server"
        if [ "$DEPLOY_TCPCL" = "yes" ]; then
            FINAL_TCPCL_BINARY_PATH="$BUILD_DIR/hardy/target/armv7-unknown-linux-musleabihf/release/hardy-tcpclv4-server"
        fi
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
    
    HAS_SRV=$(${SSH_QUERY_CMD} "$TARGET_USER@$TARGET_HOST" "[ -d /srv ] && echo 'yes' || echo 'no'")
    if [ "$HAS_SRV" = "yes" ]; then
        echo "/srv directory detected on target. Configuring storage under /srv/hardy..."
        DB_DIR="/srv/hardy"
        STORE_DIR="/srv/hardy/bundle-storage"
        WORKING_DIR="/srv/hardy"
    else
        DB_DIR="/var/lib/hardy"
        STORE_DIR="/var/lib/hardy/bundle-storage"
        WORKING_DIR="/var/lib/hardy"
    fi
    SERVICE_USER="hardy"
    PRIVATE_TMP="yes"
    PROTECT_SYSTEM="strict"
    PROTECT_HOME="yes"
    NO_NEW_PRIVILEGES="yes"
    READ_WRITE_PATHS="${DB_DIR} ${CONF_DIR}"
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
    PRIVATE_TMP="no"
    PROTECT_SYSTEM="no"
    PROTECT_HOME="no"
    NO_NEW_PRIVILEGES="no"
    READ_WRITE_PATHS=""
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
RUST_LOG="hardy=${LOG_LEVEL}"

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
    -e "s|@PRIVATE_TMP@|${PRIVATE_TMP}|g" \
    -e "s|@PROTECT_SYSTEM@|${PROTECT_SYSTEM}|g" \
    -e "s|@PROTECT_HOME@|${PROTECT_HOME}|g" \
    -e "s|@NO_NEW_PRIVILEGES@|${NO_NEW_PRIVILEGES}|g" \
    -e "s|@READ_WRITE_PATHS@|${READ_WRITE_PATHS}|g" \
    "${TEMPLATES_DIR}/hardy-bpa.service.template" > "${GEN_DIR}/hardy-bpa.service"

if [ "$DEPLOY_TCPCL" = "yes" ]; then
    echo "Generating systemd template service file for TCPCL..."
    sed -e "s|@SERVICE_USER@|${SERVICE_USER}|g" \
        -e "s|@WORKING_DIR@|${WORKING_DIR}|g" \
        -e "s|@OTEL_ENV@|${OTEL_ENV}|g" \
        -e "s|@RUST_LOG@|${RUST_LOG}|g" \
        -e "s|@EXEC_START@|${TCPCL_EXEC_START}|g" \
        -e "s|@PRIVATE_TMP@|${PRIVATE_TMP}|g" \
        -e "s|@PROTECT_SYSTEM@|${PROTECT_SYSTEM}|g" \
        -e "s|@PROTECT_HOME@|${PROTECT_HOME}|g" \
        -e "s|@NO_NEW_PRIVILEGES@|${NO_NEW_PRIVILEGES}|g" \
        -e "s|@READ_WRITE_PATHS@|${READ_WRITE_PATHS}|g" \
        "${TEMPLATES_DIR}/hardy-tcpcl@.service.template" > "${GEN_DIR}/hardy-tcpcl@.service"
fi

# Interactive TCPCL connection instance configuration (like Wireguard wg0, wg1...)
INSTANCES_TO_ENABLE=()
if [ "$DEPLOY_TCPCL" = "yes" ] && [ "$NON_INTERACTIVE" = "no" ]; then
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

# Look for existing local tcpcl-*.yaml configuration files (add to instances list before script generation)
for f in "${SCRIPT_DIR}"/tcpcl-*.yaml; do
    [ -e "$f" ] || continue
    inst_name=$(basename "$f" .yaml | sed 's/^tcpcl-//')
    INSTANCES_TO_ENABLE+=("${inst_name}")
done

# Target deployment commands
echo "Deploying to target machine..."

# Query target settings for deployment script generation (unprivileged queries)
echo "Querying target system details..."
IS_RO=$(${SSH_QUERY_CMD} "$TARGET_USER@$TARGET_HOST" "mount | grep 'on / type' | grep -q '(ro,' && echo 'yes' || echo 'no'")
LOCAL_SUBNET=$(${SSH_QUERY_CMD} "$TARGET_USER@$TARGET_HOST" "ip route show | awk '/proto kernel/ && /scope link/ {print \$1; exit}'" 2>/dev/null || echo "")
if [ -z "$LOCAL_SUBNET" ]; then
    LOCAL_SUBNET="192.168.0.0/16"
fi

# Generate target deployment script from template
echo "Generating target deployment script..."
sed -e "s|@LAYOUT@|${LAYOUT}|g" \
    -e "s|@CONF_DIR@|${CONF_DIR}|g" \
    -e "s|@DB_DIR@|${DB_DIR}|g" \
    -e "s|@STORE_DIR@|${STORE_DIR}|g" \
    -e "s|@BIN_DEST@|${BIN_DEST}|g" \
    -e "s|@TCPCL_BIN_DEST@|${TCPCL_BIN_DEST}|g" \
    -e "s|@CONF_DEST@|${CONF_DEST}|g" \
    -e "s|@ROUTES_DEST@|${ROUTES_DEST}|g" \
    -e "s|@SERVICE_USER@|${SERVICE_USER}|g" \
    -e "s|@DEPLOY_TCPCL@|${DEPLOY_TCPCL}|g" \
    -e "s|@LOCAL_SUBNET@|${LOCAL_SUBNET}|g" \
    -e "s|@INSTALL_FAIL2BAN@|${INSTALL_FAIL2BAN}|g" \
    -e "s|@INSTALL_UNATTENDED_UPGRADES@|${INSTALL_UNATTENDED_UPGRADES}|g" \
    -e "s|@IS_RO@|${IS_RO}|g" \
    -e "s|@INSTANCES_TO_ENABLE@|${INSTANCES_TO_ENABLE[*]}|g" \
    "${TEMPLATES_DIR}/deploy-target.sh.template" > "${GEN_DIR}/deploy-target.sh"

# Copy files to /tmp
echo "Copying BPA binary..."
scp -P "$TARGET_PORT" "$FINAL_BINARY_PATH" "$TARGET_USER@$TARGET_HOST:/tmp/hardy-bpa-server"

if [ "$DEPLOY_TCPCL" = "yes" ]; then
    echo "Copying TCPCL binary..."
    scp -P "$TARGET_PORT" "$FINAL_TCPCL_BINARY_PATH" "$TARGET_USER@$TARGET_HOST:/tmp/hardy-tcpclv4-server"
fi

if [ -f "${SCRIPT_DIR}/static_routes.yaml" ]; then
    echo "Copying local static_routes.yaml..."
    scp -P "$TARGET_PORT" "${SCRIPT_DIR}/static_routes.yaml" "$TARGET_USER@$TARGET_HOST:/tmp/static_routes.yaml"
fi

echo "Copying configuration..."
scp -P "$TARGET_PORT" "${GEN_DIR}/my-config.yaml" "$TARGET_USER@$TARGET_HOST:/tmp/my-config.yaml"

echo "Copying systemd unit..."
scp -P "$TARGET_PORT" "${GEN_DIR}/hardy-bpa.service" "$TARGET_USER@$TARGET_HOST:/tmp/hardy-bpa.service"
if [ "$DEPLOY_TCPCL" = "yes" ]; then
    scp -P "$TARGET_PORT" "${GEN_DIR}/hardy-tcpcl@.service" "$TARGET_USER@$TARGET_HOST:/tmp/hardy-tcpcl@.service"
fi

# Copy newly configured and existing TCPCL instances
for inst in "${INSTANCES_TO_ENABLE[@]}"; do
    if [ -f "${GEN_DIR}/tcpcl-${inst}.yaml" ]; then
        echo "Copying newly configured instance: ${inst}..."
        scp -P "$TARGET_PORT" "${GEN_DIR}/tcpcl-${inst}.yaml" "$TARGET_USER@$TARGET_HOST:/tmp/tcpcl-${inst}.yaml"
    elif [ -f "${SCRIPT_DIR}/tcpcl-${inst}.yaml" ]; then
        echo "Copying existing configuration for instance: ${inst}..."
        scp -P "$TARGET_PORT" "${SCRIPT_DIR}/tcpcl-${inst}.yaml" "$TARGET_USER@$TARGET_HOST:/tmp/tcpcl-${inst}.yaml"
    fi
done

echo "Copying deployment script to target..."
scp -P "$TARGET_PORT" "${GEN_DIR}/deploy-target.sh" "$TARGET_USER@$TARGET_HOST:/tmp/deploy-target.sh"

# Execute target script once as root (prompts for sudo password exactly once)
echo "Executing deployment on target..."
${SSH_ACTION_CMD} "$TARGET_USER@$TARGET_HOST" "sudo bash /tmp/deploy-target.sh && rm -f /tmp/deploy-target.sh"

# Cleanup build directory
if [ "$SOURCE_MODE" = "compile" ]; then
    rm -rf "$BUILD_DIR"
fi
rm -rf "$GEN_DIR"
