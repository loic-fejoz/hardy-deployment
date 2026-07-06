#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BIN_DIR="/home/loic/projets/hardy/target/release"

echo "==============================================="
echo "   Hardy Deployment Local Docker Integration Test"
echo "==============================================="

# 1. Clean up old containers
echo "Cleaning up old containers..."
docker rm -f hardy-test-target hardy-test-source 2>/dev/null || true

# 2. Start target container
echo "Starting target container..."
docker run -d --name hardy-test-target debian:11-slim tail -f /dev/null

# 3. Configure SSH and Mock systemctl on target
echo "Configuring SSH and Mock systemctl on target..."
docker exec hardy-test-target sh -c "
  apt-get update && \
  apt-get install -y openssh-server sudo procps && \
  mkdir -p /var/run/sshd /root/.ssh && \
  chmod 700 /root/.ssh && \
  touch /root/.ssh/authorized_keys && \
  chmod 600 /root/.ssh/authorized_keys && \
  sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && \
  /usr/sbin/sshd && \
  echo '#!/bin/sh' > /usr/local/bin/systemctl && \
  echo 'echo [MOCK SYSTEMCTL] \$@' >> /usr/local/bin/systemctl && \
  chmod +x /usr/local/bin/systemctl
"

# 4. Start source container in the background
echo "Starting source container..."
docker run -d --name hardy-test-source \
  --link hardy-test-target:target \
  -v "${PROJECT_DIR}:/app" \
  -v "${BIN_DIR}:/binaries" \
  debian:11-slim tail -f /dev/null

# 5. Configure SSH client and keys on source, then copy pubkey to target
echo "Setting up SSH keys..."
docker exec hardy-test-source sh -c "
  apt-get update && \
  apt-get install -y openssh-client && \
  mkdir -p /root/.ssh && \
  ssh-keygen -t rsa -N '' -f /root/.ssh/id_rsa
"

# Extract public key from source and write to target
PUBKEY=$(docker exec hardy-test-source cat /root/.ssh/id_rsa.pub)
docker exec hardy-test-target sh -c "echo '${PUBKEY}' >> /root/.ssh/authorized_keys"

# 6. Run the deployment script inside the source container
echo "Running deploy.sh in source container..."
docker exec -t hardy-test-source sh -c "
  cd /app && \
  ssh-keyscan -H target >> /root/.ssh/known_hosts && \
  ./deploy.sh --host target \
              --port 22 \
              --user root \
              --layout debian \
              --dtn-eid dtn://f4jxq-test/ \
              --ipn-eid ipn:99.0 \
              --source path \
              --binary /binaries/hardy-bpa-server \
              --tcpcl-binary /binaries/hardy-tcpclv4-server \
              --non-interactive
"

echo ""
echo "==============================================="
echo "Verifying files deployed on target container:"
echo "-----------------------------------------------"
echo "--- Directories ---"
docker exec hardy-test-target ls -la /usr/local/bin/hardy-bpa-server /usr/local/bin/hardy-tcpclv4-server
echo "--- Configuration ---"
docker exec hardy-test-target cat /etc/hardy/my-config.yaml
echo "--- Systemd unit file ---"
docker exec hardy-test-target cat /etc/systemd/system/hardy-bpa-server.service 2>/dev/null || docker exec hardy-test-target cat /etc/systemd/system/hardy-bpa.service
echo "==============================================="

# Cleanup
echo "Cleaning up containers..."
docker rm -f hardy-test-target hardy-test-source >/dev/null || true
echo "Test completed successfully."
