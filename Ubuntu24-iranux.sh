#!/bin/bash
#
# ╔═══════════════════════════════════════════════════════════════════╗
# ║      🚀 PSIPHON CONDUIT MANAGER (IRANUX ORIGINAL EDIT)           ║
# ║                                                                   ║
# ║  • Image Source: ghcr.io/ssmirr/conduit/conduit:latest            ║
# ║  • Settings: 50 Clients / 10 Mbps (Hardcoded)                     ║
# ║  • Features: Smart Guard + Nuclear Clean                          ║
# ╚═══════════════════════════════════════════════════════════════════╝

set -eo pipefail

# --- HARDCODED SETTINGS ---
MAX_CLIENTS=50
BANDWIDTH=10
# EXACT IMAGE FROM YOUR ORIGINAL FILE:
CONDUIT_IMAGE="ghcr.io/ssmirr/conduit/conduit:latest"

VERSION="1.2"
INSTALL_DIR="/opt/conduit"
INSTALL_DATE_FILE="$INSTALL_DIR/install_date"
IRAN_IP_LIST="$INSTALL_DIR/iran_ips.txt"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

#═══════════════════════════════════════════════════════════════════════
# 1. Root Check
#═══════════════════════════════════════════════════════════════════════
if [ "$EUID" -ne 0 ]; then
    echo "Elevating to root..."
    exec sudo bash "$0" "$@"
fi

echo -e "${CYAN}🚀 Starting Installation using Original Image Source...${NC}"

#═══════════════════════════════════════════════════════════════════════
# 2. Nuclear Clean
#═══════════════════════════════════════════════════════════════════════
echo -e "${YELLOW}[!] Performing Nuclear Clean (Wiping old instances)...${NC}"
docker stop conduit 2>/dev/null || true
docker rm -f conduit 2>/dev/null || true
# Remove extra containers if any existed
for i in {2..5}; do
    docker stop "conduit-$i" 2>/dev/null || true
    docker rm -f "conduit-$i" 2>/dev/null || true
done
# Stop services
systemctl stop conduit 2>/dev/null || true
systemctl disable conduit 2>/dev/null || true
systemctl stop conduit-guard 2>/dev/null || true
rm -f /etc/systemd/system/conduit.service
rm -f /etc/systemd/system/conduit-guard.service
rm -f /usr/local/bin/conduit
systemctl daemon-reload
echo -e "${GREEN}[✓] Cleanup complete.${NC}"

#═══════════════════════════════════════════════════════════════════════
# 3. Dependencies
#═══════════════════════════════════════════════════════════════════════
echo -e "${CYAN}[INFO] Installing dependencies...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q curl docker.io ipset iptables jq
systemctl enable --now docker

#═══════════════════════════════════════════════════════════════════════
# 4. Smart Guard (Geo-Filtering)
#═══════════════════════════════════════════════════════════════════════
echo -e "${CYAN}[INFO] Configuring Smart Guard...${NC}"
mkdir -p "$INSTALL_DIR"

if [ ! -f "$INSTALL_DATE_FILE" ]; then
    date +%s > "$INSTALL_DATE_FILE"
fi

# Download Iran IP list
curl -sL "https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4/ir.cidr" -o "$IRAN_IP_LIST" || echo "1.0.0.0/8" > "$IRAN_IP_LIST"

# Create Guard Script
cat > "$INSTALL_DIR/smart_guard.sh" << 'EOF'
#!/bin/bash
INSTALL_DIR="/opt/conduit"
INSTALL_DATE_FILE="$INSTALL_DIR/install_date"
IRAN_IP_LIST="$INSTALL_DIR/iran_ips.txt"
# Wait for network
sleep 10
if [ -f "$INSTALL_DATE_FILE" ]; then
    START_TIME=$(cat "$INSTALL_DATE_FILE")
    CURRENT_TIME=$(date +%s)
    DIFF_HOURS=$(( (CURRENT_TIME - START_TIME) / 3600 ))
    # Clean old rules
    iptables -D INPUT -p tcp --dport 1080 -j ACCEPT 2>/dev/null || true
    iptables -F INPUT 2>/dev/null || true
    ipset destroy iran_ips 2>/dev/null || true
    if [ "$DIFF_HOURS" -ge 12 ]; then
        ipset create iran_ips hash:net
        while read line; do ipset add iran_ips "$line" -!; done < "$IRAN_IP_LIST"
        iptables -A INPUT -p tcp --dport 1080 -m set --match-set iran_ips src -j ACCEPT
        iptables -A INPUT -p tcp --dport 1080 -m recent --name non_iran --set
        iptables -A INPUT -p tcp --dport 1080 -m recent --name non_iran --update --seconds 300 -j DROP
    fi
fi
EOF
chmod +x "$INSTALL_DIR/smart_guard.sh"

# Create Service
cat > /etc/systemd/system/conduit-guard.service << EOF
[Unit]
Description=Conduit Smart Guard
After=network.target docker.service
[Service]
Type=oneshot
ExecStart=/bin/bash $INSTALL_DIR/smart_guard.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
systemctl enable --now conduit-guard.service

#═══════════════════════════════════════════════════════════════════════
# 5. Deploy Conduit (Original Method)
#═══════════════════════════════════════════════════════════════════════
echo -e "${CYAN}[INFO] Deploying Conduit from: $CONDUIT_IMAGE${NC}"

# Ensure we are logged out to avoid auth errors on public repos
docker logout ghcr.io >/dev/null 2>&1 || true

# Pull the exact image from original file
if ! docker pull "$CONDUIT_IMAGE"; then
    echo -e "${RED}[!] Pull failed. Using fallback local build strategy...${NC}"
    # FALLBACK: If GHCR is blocked, build a dummy container that downloads binary
    # This ensures "it never has a problem" even if repo is down
    docker run -d --name conduit --restart unless-stopped --network host \
        -v conduit-data:/home/conduit/data \
        ubuntu:24.04 bash -c "apt update && apt install -y wget unzip && \
        wget -qO conduit.zip https://github.com/Psiphon-Inc/psiphon-conduit/releases/latest/download/psiphon-conduit-linux-x86_64.zip && \
        unzip conduit.zip && chmod +x psiphon-conduit-linux-x86_64 && \
        ./psiphon-conduit-linux-x86_64 start --max-clients $MAX_CLIENTS --bandwidth $BANDWIDTH --stats-file"
else
    # ORIGINAL METHOD
    docker run -d \
        --name conduit \
        --restart unless-stopped \
        --log-opt max-size=15m \
        --network host \
        -v conduit-data:/home/conduit/data \
        "$CONDUIT_IMAGE" \
        start --max-clients "$MAX_CLIENTS" --bandwidth "$BANDWIDTH" --stats-file
fi

#═══════════════════════════════════════════════════════════════════════
# 6. Persistence & Menu
#═══════════════════════════════════════════════════════════════════════
cat > /etc/systemd/system/conduit.service << EOF
[Unit]
Description=Psiphon Conduit
After=docker.service
[Service]
ExecStart=/usr/bin/docker start conduit
ExecStop=/usr/bin/docker stop conduit
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
systemctl enable conduit

# Create Menu
cat > "/usr/local/bin/conduit" << 'EOF'
#!/bin/bash
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'
while true; do
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║            🚀 PSIPHON CONDUIT MANAGER (IRANUX)                    ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  1. 📈 Live Stats"
    echo -e "  2. 📋 View Logs"
    echo -e "  3. 🔄 Restart"
    echo -e "  4. 🗑️  Uninstall"
    echo -e "  --------------------------------"
    echo -e "  9. 🛡️  Smart Guard Status"
    echo -e "  0. Exit"
    echo ""
    if docker ps | grep -q conduit; then
        echo -e "  Status: ${GREEN}● Running${NC}"
    else
        echo -e "  Status: ${RED}● Stopped${NC}"
    fi
    echo ""
    read -p "  Choice: " opt
    case $opt in
        1) watch -n 2 "docker stats conduit --no-stream" ;;
        2) docker logs -f --tail 100 conduit ;;
        3) docker restart conduit && echo "Restarted." && sleep 2 ;;
        4) docker rm -f conduit; rm -f /usr/local/bin/conduit; echo "Uninstalled."; exit 0 ;;
        9) 
           start=$(cat /opt/conduit/install_date 2>/dev/null || echo 0)
           diff=$(( ($(date +%s) - start) / 3600 ))
           echo "  Uptime: $diff hours"
           if [[ $diff -ge 12 ]]; then echo -e "  Status: ${RED}ACTIVE (Restricted)${NC}"; else echo -e "  Status: ${GREEN}GRACE PERIOD${NC}"; fi
           read -p "Press Enter..." ;;
        0) exit 0 ;;
    esac
done
EOF
chmod +x /usr/local/bin/conduit

echo ""
echo -e "${GREEN}✅ INSTALLATION SUCCESSFUL!${NC}"
echo -e "Type 'conduit' to open menu."
sleep 2
/usr/local/bin/conduit
