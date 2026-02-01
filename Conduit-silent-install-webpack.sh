#!/bin/bash
#
# -----------------------------------------------------------------------
#   🚀 PSIPHON CONDUIT MANAGER v14.0 (COMPLETE MERGE)
# -----------------------------------------------------------------------
#   • CORE: 100% of your v1.8 Logic (Clean, Restore, Install).
#   • ADDED: 'sudo su' check + 'apt update' start.
#   • ADDED: Smart Firewall (Iran VIP) + Auto-Start on Reboot.
#   • UI: Localized English Menu (Static / No Flicker).
# -----------------------------------------------------------------------

# --- 1. MANDATORY ROOT CHECK ---
if [ "$EUID" -ne 0 ]; then
    echo "Elevating to root..."
    sudo su -c "bash $0"
    exit
fi

# Prevent interactive prompts during apt
export DEBIAN_FRONTEND=noninteractive
set -e

# --- CONFIGURATION (Kept from v1.8) ---
VERSION="14.0"
CONDUIT_IMAGE="ghcr.io/ssmirr/conduit/conduit:latest"
INSTALL_DIR="/opt/conduit"
BACKUP_DIR="$INSTALL_DIR/backups"
FW_SCRIPT="$INSTALL_DIR/firewall.sh"
MENU_SCRIPT="$INSTALL_DIR/menu.sh"

# COLORS
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# =======================================================================
# STEP 1: SYSTEM UPDATE (AS REQUESTED)
# =======================================================================
echo -e "${BLUE}[INFO] Step 1: Updating Repositories...${NC}"
apt-get update -q -y || echo -e "${YELLOW}[!] Update warnings ignored.${NC}"

# =======================================================================
# STEP 2: DEEP CLEAN & REPAIR (EXACT v1.8 LOGIC)
# =======================================================================
echo -e "${BLUE}[INFO] Step 2: Deep Cleaning System...${NC}"

killall apt apt-get dpkg 2>/dev/null || true
sleep 1

# Remove locks
rm -f /var/lib/apt/lists/lock 
rm -f /var/cache/apt/archives/lock
rm -f /var/lib/dpkg/lock*

# Repair dpkg
dpkg --configure -a || true
apt-get install -f -y || true

# Wipe previous Conduit
if command -v docker &>/dev/null; then
    docker stop conduit 2>/dev/null || true
    docker rm conduit 2>/dev/null || true
    docker stop $(docker ps -a -q --filter name=conduit) 2>/dev/null || true
    docker rm $(docker ps -a -q --filter name=conduit) 2>/dev/null || true
fi
rm -f /usr/local/bin/conduit
mkdir -p "$INSTALL_DIR"

# =======================================================================
# STEP 3: INSTALL DEPENDENCIES (v1.8 + ipset)
# =======================================================================
echo -e "${BLUE}[INFO] Step 3: Installing Dependencies...${NC}"
apt-get install -y -q curl gawk tcpdump geoip-bin geoip-database qrencode ipset >/dev/null 2>&1 || true

# Install Docker
if ! command -v docker &>/dev/null; then
    echo -e "${BLUE}[INFO] Installing Docker...${NC}"
    curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 || true
    systemctl start docker >/dev/null 2>&1 || true
    systemctl enable docker >/dev/null 2>&1 || true
fi

# =======================================================================
# STEP 4: RESTORE & RUN (EXACT v1.8 LOGIC)
# =======================================================================
echo -e "${BLUE}[INFO] Step 4: Deploying Service...${NC}"
docker volume create conduit-data >/dev/null 2>&1 || true

# Restore Backup
if [ -d "$BACKUP_DIR" ]; then
    BACKUP_FILE=$(ls -t "$BACKUP_DIR"/conduit_key_*.json 2>/dev/null | head -1)
    if [ -n "$BACKUP_FILE" ]; then
        echo -e "${GREEN}[✓] Identity Backup Restored.${NC}"
        docker run --rm -v conduit-data:/data -v "$BACKUP_DIR":/bkp alpine \
            sh -c "cp /bkp/$(basename "$BACKUP_FILE") /data/conduit_key.json && chown 1000:1000 /data/conduit_key.json"
    fi
fi

# Start Container (50 clients / 5 bandwidth as per v1.8)
docker run -d \
    --name conduit \
    --restart unless-stopped \
    --log-opt max-size=10m \
    -v conduit-data:/home/conduit/data \
    --network host \
    "$CONDUIT_IMAGE" \
    start --max-clients 50 --bandwidth 5 --stats-file >/dev/null

# Save Config
echo "MAX_CLIENTS=50" > "$INSTALL_DIR/settings.conf"
echo "BANDWIDTH=5" >> "$INSTALL_DIR/settings.conf"

# =======================================================================
# STEP 5: SMART FIREWALL SCRIPT
# =======================================================================
cat << 'EOF' > "$FW_SCRIPT"
#!/bin/bash
IPSET="iran_ips"
URL="https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4/ir.cidr"
STATE_FILE="/opt/conduit/.fw_active"

do_enable() {
    echo "Enabling Smart Firewall (Iran VIP)..."
    ipset create $IPSET hash:net -exist
    ipset flush $IPSET
    curl -sL "$URL" | while read line; do [[ "$line" =~ ^# ]] || ipset add $IPSET "$line" -exist; done
    
    iptables -F INPUT
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT
    
    # 1. Iran VIP (Unlimited)
    iptables -A INPUT -m set --match-set $IPSET src -j ACCEPT
    
    # 2. World Throttle (Allow Trackers, Block High-Traffic)
    iptables -A INPUT -m state --state NEW -m recent --set
    iptables -A INPUT -m state --state NEW -m recent --update --seconds 60 --hitcount 3 -j DROP
    iptables -A INPUT -j ACCEPT
    touch "$STATE_FILE"
}

do_disable() {
    echo "Opening Firewall to All..."
    iptables -P INPUT ACCEPT
    iptables -F INPUT
    rm -f "$STATE_FILE"
}

case "$1" in
    enable) do_enable ;;
    disable) do_disable ;;
    restore) [ -f "$STATE_FILE" ] && do_enable ;;
esac
EOF
chmod +x "$FW_SCRIPT"

# =======================================================================
# STEP 6: AUTO-START PERSISTENCE
# =======================================================================
cat > /etc/systemd/system/conduit.service << EOF
[Unit]
Description=Psiphon Conduit Service
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

systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable conduit.service >/dev/null 2>&1 || true

# Initialize Firewall (Default: Enabled)
bash "$FW_SCRIPT" enable

# =======================================================================
# STEP 7: STATIC MENU (Preserving Original "Reports" Logic)
# =======================================================================
cat << 'EOF' > "$MENU_SCRIPT"
#!/bin/bash
FW="/opt/conduit/firewall.sh"
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

while true; do
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║      🚀 CONDUIT MANAGER v14.0 (STABLE / ENGLISH)           ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  [1] Active Users (Report Snapshot)"
    echo "  [2] View Service Logs"
    echo "  [3] Restart Psiphon Service"
    echo "  [4] Stop Psiphon Service"
    echo "  -----------------------"
    echo "  [5] Enable Smart Filter (Iran VIP Mode)"
    echo "  [6] Disable Filter (World Open Mode)"
    echo "  -----------------------"
    echo "  [0] Exit"
    echo ""

    read -p "Select option > " choice

    case $choice in
        1)
            echo -e "\n--- Active Connections ---"
            ss -tun state established 2>/dev/null | awk '{print $5}' | cut -d: -f1 | grep -vE "127.0.0.1|\[::1\]" | sort | uniq -c | sort -nr | head -n 15
            echo ""
            read -p "Press Enter to return..." ;;
        2) docker logs --tail 50 -f conduit ;;
        3) docker restart conduit; echo "Done."; sleep 1 ;;
        4) docker stop conduit; echo "Done."; sleep 1 ;;
        5) bash "$FW" enable; read -p "Firewall updated. Press Enter..." ;;
        6) bash "$FW" disable; read -p "Firewall opened. Press Enter..." ;;
        0) exit 0 ;;
    esac
done
EOF
chmod +x "$MENU_SCRIPT"
ln -sf "$MENU_SCRIPT" /usr/local/bin/conduit

# =======================================================================
# EXECUTION
# =======================================================================
echo -e "\n${GREEN}[✓] INSTALLATION COMPLETE.${NC}"
echo "------------------------------------------------"
echo -e " Command to open menu: ${YELLOW}conduit${NC}"
echo "------------------------------------------------"
sleep 1

# Open menu automatically
/usr/local/bin/conduit
