#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HARDY_RELEASE_DIR="/home/loic/projets/hardy/target/release"

echo "==============================================="
echo "   Hardy BPA Ping Test on Docker Target"
echo "==============================================="

# 1. Clean up old target container
echo "Cleaning up old target container..."
docker rm -f hardy-test-target 2>/dev/null || true

# 2. Start target container with port mappings:
#    - 2222 -> 22 (SSH)
#    - 4559 -> 4556 (TCPCLv4 CLA)
echo "Starting target container with port 4559 and 2222..."
docker run -d --name hardy-test-target \
  -p 2222:22 \
  -p 4559:4556 \
  debian:unstable-slim tail -f /dev/null

# 3. Configure SSH and Dbus mock on target
echo "Setting up SSH on target container..."
docker exec hardy-test-target sh -c "
  apt-get update && \
  apt-get install -y openssh-server sudo procps && \
  mkdir -p /var/run/sshd /root/.ssh && \
  chmod 700 /root/.ssh && \
  touch /root/.ssh/authorized_keys && \
  chmod 600 /root/.ssh/authorized_keys && \
  sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && \
  /usr/sbin/sshd && \
  echo '#!/bin/sh' > /usr/bin/systemctl && \
  echo 'echo [MOCK SYSTEMCTL] \$@' >> /usr/bin/systemctl && \
  chmod +x /usr/bin/systemctl
"

# 4. Authorize local host SSH keys on the target container
echo "Injecting host SSH public keys into target..."
cat /home/loic/.ssh/id_*.pub 2>/dev/null | docker exec -i hardy-test-target sh -c 'cat >> /root/.ssh/authorized_keys' || true

# Add target container to ssh known_hosts to prevent interactive prompting
ssh-keyscan -p 2222 127.0.0.1 >> ~/.ssh/known_hosts 2>/dev/null || true

# 5. Deploy Hardy onto the target container
echo "Deploying Hardy..."
"${PROJECT_DIR}/deploy.sh" --host 127.0.0.1 \
                           --port 2222 \
                           --user root \
                           --layout debian \
                           --dtn-eid dtn://f4jxq-test/ \
                           --ipn-eid ipn:99.0 \
                           --source path \
                           --binary "${HARDY_RELEASE_DIR}/hardy-bpa-server" \
                           --tcpcl-binary "${HARDY_RELEASE_DIR}/hardy-tcpclv4-server" \
                           --non-interactive

# 6. Start the actual hardy-bpa-server inside target container
echo "Starting actual hardy-bpa-server on target container..."
docker exec -d hardy-test-target /usr/local/bin/hardy-bpa-server -c /etc/hardy/my-config.yaml

echo "Waiting for BPA server to initialize..."
sleep 2

# 7. Run the ping diagnostic command from the host PC
echo "-----------------------------------------------"
echo "Running: bp ping ipn:99.7 127.0.0.1:4559 --count 3"
echo "-----------------------------------------------"
"${HARDY_RELEASE_DIR}/bp" ping ipn:99.7 127.0.0.1:4559 --count 3

echo ""
echo "==============================================="
echo "Deployment and Ping Test Successful!"
echo "The target container 'hardy-test-target' is kept running."
echo "You can check its logs using: docker logs hardy-test-target"
echo "==============================================="
