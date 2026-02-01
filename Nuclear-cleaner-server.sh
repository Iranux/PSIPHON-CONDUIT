#!/bin/bash
# 🧹 NUCLEAR CLEANER SCRIPT
# This script kills EVERYTHING related to Conduit to stop screen flickering.

if [ "$EUID" -ne 0 ]; then
    echo "Run as root!"
    exit 1
fi

echo -e "\033[1;31m[!!!] STARTING NUCLEAR CLEANUP [!!!]\033[0m"

# 1. KILL PROCESSES (The cause of flickering)
echo "1. Killing background scripts..."
# Kill any script with 'conduit', 'menu', 'watch', or 'sleep' in the name
pkill -9 -f "conduit" || true
pkill -9 -f "menu.sh" || true
pkill -9 -f "watch" || true
pkill -9 -f "sleep" || true
# Kill apt/dpkg if stuck
killall -9 apt apt-get dpkg 2>/dev/null || true

# 2. REMOVE SERVICE
echo "2. Removing Systemd Service..."
systemctl stop conduit.service 2>/dev/null || true
systemctl disable conduit.service 2>/dev/null || true
rm -f /etc/systemd/system/conduit.service
systemctl daemon-reload 2>/dev/null || true

# 3. DESTROY DOCKER CONTAINER
echo "3. Removing Docker Containers..."
if command -v docker &>/dev/null; then
    docker stop conduit 2>/dev/null || true
    docker rm -f conduit 2>/dev/null || true
    # Remove any zombie containers
    docker rm -f $(docker ps -a -q --filter name=conduit) 2>/dev/null || true
fi

# 4. REMOVE FILES
echo "4. Deleting Files..."
rm -rf /opt/conduit
rm -f /usr/local/bin/conduit
rm -f /usr/local/bin/live-users

# 5. FLUSH FIREWALL
echo "5. Flushing Firewall..."
iptables -P INPUT ACCEPT
iptables -F INPUT
if command -v ipset &>/dev/null; then
    ipset destroy iran_ips 2>/dev/null || true
fi

echo -e "\033[1;32m[✓] CLEANUP COMPLETE. SYSTEM IS CLEAN.\033[0m"
echo "You can now install the new script."
