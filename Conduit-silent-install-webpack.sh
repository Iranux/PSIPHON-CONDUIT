#!/bin/bash
#
# ╔═══════════════════════════════════════════════════════════════════╗
# ║   🚀 PSIPHON CONDUIT MANAGER v8.0 (GOLD EDITION)                 ║
# ║                                                                   ║
# ║  • PLATFORM: Optimized for GitHub (curl | bash friendly)          ║
# ║  • SECURITY: Smart Firewall + Auto-Restore on Reboot              ║
# ║  • STABILITY: No-Flicker Static Menu                              ║
# ╚═══════════════════════════════════════════════════════════════════╝
#

# --- 1. ROOT CHECK ---
if [ "$EUID" -ne 0 ]; then
    echo "Error: Please run as root (sudo)."
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
set -e

# --- 2. CONFIGURATION ---
CONDUIT_IMAGE="ghcr.io/ssmirr/conduit/conduit:latest"
INSTALL_DIR="/opt/conduit"
BACKUP_DIR="$INSTALL_DIR/backups"
FW_SCRIPT="$INSTALL_DIR/firewall.sh"
MENU_SCRIPT="$INSTALL_DIR/menu.sh"
# This file tracks if firewall was enabled (for reboot persistence)
FW_STATE_FILE="$INSTALL_DIR/.firewall_state"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

#═══════════════════════════════════════════════════════════════════════
# 3. SYSTEM PREP
#═══════════════════════════════════════════════════════════════════════
echo -e "${BLUE}[INFO] System Check...${NC}"

# Kill conflicting processes (Prevent Apt Lock)
killall apt apt-get dpkg 2>/dev/null || true

# Install Dependencies
if [ -f /etc/debian_version ]; then
    apt-get update -q -y >/dev/null 2>&1 || true
    # ipset is crucial for the firewall
    apt-get install -y -q curl gawk tcpdump geoip-bin geoip-database qrencode ipset >/dev/null 2>&1 || true
elif [ -f /etc/alpine-release ]; then
    apk add --no-cache curl gawk tcpdump geoip qrencode ipset >/dev/null 2>&1 || true
fi

# Clean Old Install (Force Fresh Start)
if command -v docker &>/dev/null; then
    docker stop conduit 2>/dev/null || true
    docker rm conduit 2>/dev/null || true
fi
rm -f /usr/local/bin/conduit

#═══════════════════════════════════════════════════════════════════════
# 4. DOCKER SETUP
#═══════════════════════════════════════════════════════════════════════
echo -e "${BLUE}[INFO] Setting up Docker...${NC}"
if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 || true
    systemctl start docker >/dev/null 2>&1 || true
    systemctl enable docker >/dev/null 2>&1 || true
fi

#═══════════════════════════════════════════════════════════════════════
# 5. DEPLOY CONDUIT
#═══════════════════════════════════════════════════════════════════════
echo -e "${BLUE}[INFO] Deploying Container...${NC}"
mkdir -p "$INSTALL_DIR"
docker volume create conduit-data >/dev/null 2>&1 || true

# Restore Backup if found
if [ -d "$BACKUP_DIR" ]; then
    BACKUP_FILE=$(ls -t "$BACKUP_DIR"/conduit_key_*.json 2>/dev/null | head -1)
    if [ -n "$BACKUP_FILE" ]; then
        echo -e "${GREEN}[✓] Restoring Identity...${NC}"
        docker run --rm -v conduit-data:/data -v "$BACKUP_DIR":/bkp alpine \
            sh -c "cp /bkp/$(basename "$BACKUP_FILE") /data/conduit_key.json && chown 1000:1000 /data/conduit_key.json"
    fi
fi

# Start Container
docker run -d \
    --name conduit \
    --restart unless-stopped \
    --log-opt max-size=10m \
    -v conduit-data:/home/conduit/data \
    --network host \
    "$CONDUIT_IMAGE" \
    start --max-clients 50 --bandwidth 5 --stats-file >/dev/null

#═══════════════════════════════════════════════════════════════════════
# 6. SMART FIREWALL SCRIPT
#═══════════════════════════════════════════════════════════════════════
cat << 'EOF' > "$FW_SCRIPT"
#!/bin/bash
INSTALL_DIR="/opt/conduit"
STATE_FILE="$INSTALL_DIR/.firewall_state"
IP_LIST="https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4/ir.cidr"
IPSET="iran_ips"
GREEN='\033[1;32m'
NC='\033[0m'

do_enable() {
    echo "Updating Smart Firewall..."
    
    # 1. Download IPs
    ipset create $IPSET hash:net -exist
    ipset flush $IPSET
    curl -sL "$IP_LIST" | while read line; do [[ "$line" =~ ^# ]] || ipset add $IPSET "$line" -exist; done
    
    # 2. Apply Rules
    iptables -F INPUT
    # Allow Local & SSH
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT
    
    # Allow Iran (Unlimited)
    iptables -A INPUT -m set --match-set $IPSET src -j ACCEPT
    
    # Throttle World (Trackers OK, Users Blocked)
    iptables -A INPUT -m state --state NEW -m recent --set
    iptables -A INPUT -m state --state NEW -m recent --update --seconds 60 --hitcount 3 -j DROP
    iptables -A INPUT -j ACCEPT
    
    # 3. Save State
    touch "$STATE_FILE"
    echo -e "${GREEN}SMART FIREWALL ENABLED.${NC}"
}

do_disable() {
    iptables -P INPUT ACCEPT
    iptables -F INPUT
    rm -f "$STATE_FILE"
    echo -e "${GREEN}FIREWALL DISABLED.${NC}"
}

case "$1" in
    enable) do_enable ;;
    disable) do_disable ;;
    restore)
        if [ -f "$STATE_FILE" ]; then
            do_enable
        fi
        ;;
esac
EOF
chmod +x "$FW_SCRIPT"

#═══════════════════════════════════════════════════════════════════════
# 7. AUTO-START SERVICE (With Firewall Persistence)
#═══════════════════════════════════════════════════════════════════════
echo -e "${BLUE}[INFO] Configuring Auto-Start...${NC}"

# We add 'ExecStartPre' to restore firewall rules BEFORE starting docker
cat > /etc/systemd/system/conduit.service << EOF
[Unit]
Description=Psiphon Conduit
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/bash /opt/conduit/firewall.sh restore
ExecStart=/usr/bin/docker start conduit
ExecStop=/usr/bin/docker stop conduit

[Install]
WantedBy=multi-user.target
EOF

if command -v systemctl &>/dev/null; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable conduit.service >/dev/null 2>&1 || true
fi

#═══════════════════════════════════════════════════════════════════════
# 8. STATIC MENU GENERATOR
#═══════════════════════════════════════════════════════════════════════
cat << 'EOF' > "$MENU_SCRIPT"
#!/bin/bash
FW="/opt/conduit/firewall.sh"
CYAN='\033[1;36m'
GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

while true; do
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║      🚀 CONDUIT MANAGER v8.0 (GOLD EDITION)                ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Status
    if docker ps | grep -q conduit; then
        echo -e "  STATUS:   ${GREEN}RUNNING${NC}"
    else
        echo -e "  STATUS:   ${RED}STOPPED${NC}"
    fi

    # Firewall Status
    if iptables -L INPUT 2>/dev/null | grep -q "match-set iran_ips"; then
        echo -e "  FILTER:   ${GREEN}SMART (Iran VIP)${NC}"
    else
        echo -e "  FILTER:   ${YELLOW}OPEN (No Limits)${NC}"
    fi

    echo ""
    echo "  [1] 👥 Active Users (Snapshot)"
    echo "  [2] 📄 View Logs"
    echo "  [3] 🔄 Restart"
    echo "  [4] 🛑 Stop"
    echo "  -----------------------"
    echo "  [5] 🧠 Enable Smart Filter"
    echo "  [6] 🔓 Disable Filter"
    echo "  -----------------------"
    echo "  [0] 🚪 Exit"
    echo ""
    
    # STATIC WAIT - NO FLICKER
    read -p "  Select option: " choice
    
    case $choice in
        1)
            echo -e "\n${CYAN}--- USERS ---${NC}"
            ss -tun state established 2>/dev/null | awk '{print $5}' | cut -d: -f1 | grep -vE "127.0.0.1|\[::1\]" | sort | uniq -c | sort -nr | head -n 15
            echo ""
            read -p "Press Enter..." ;;
        2) docker logs --tail 50 -f conduit ;;
        3) docker restart conduit; sleep 1 ;;
        4) docker stop conduit; sleep 1 ;;
        5) bash "$FW" enable; read -p "Press Enter..." ;;
        6) bash "$FW" disable; read -p "Press Enter..." ;;
        0) clear; exit 0 ;;
        *) echo "Invalid option." ;;
    esac
done
EOF
chmod +x "$MENU_SCRIPT"
rm -f /usr/local/bin/conduit
ln -s "$MENU_SCRIPT" /usr/local/bin/conduit

#═══════════════════════════════════════════════════════════════════════
# 9. FINALIZATION
#═══════════════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}[✓] INSTALLED SUCCESSFULLY.${NC}"
echo "------------------------------------------------"
echo -e " To open menu: ${YELLOW}conduit${NC}"
echo "------------------------------------------------"
