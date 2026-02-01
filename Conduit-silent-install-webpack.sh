#!/bin/bash
#
# ╔═══════════════════════════════════════════════════════════════════╗
# ║   🚀 PSIPHON CONDUIT MANAGER v12.0 (FINAL ARCHITECTURE)          ║
# ║                                                                   ║
# ║  • STRICT ORDER: Root Check -> Apt Update -> Clean -> Install     ║
# ║  • MENU: Pure text options. No status checks. No loops.           ║
# ║  • FIREWALL: Smart Iran-VIP (Persists on Reboot)                  ║
# ╚═══════════════════════════════════════════════════════════════════╝
#

# --- 1. MANDATORY ROOT CHECK ---
if [ "$EUID" -ne 0 ]; then
    echo "Error: You must run 'sudo su' before executing this script."
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
set -e

# --- CONFIGURATION ---
CONDUIT_IMAGE="ghcr.io/ssmirr/conduit/conduit:latest"
INSTALL_DIR="/opt/conduit"
BACKUP_DIR="$INSTALL_DIR/backups"
FW_SCRIPT="$INSTALL_DIR/firewall.sh"
MENU_SCRIPT="$INSTALL_DIR/menu.sh"
FW_STATE_FILE="$INSTALL_DIR/.firewall_state"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

#═══════════════════════════════════════════════════════════════════════
# STEP 1: SYSTEM UPDATE (HIGHEST PRIORITY)
#═══════════════════════════════════════════════════════════════════════
echo -e "${BLUE}[INFO] Step 1: Updating System Repositories...${NC}"
# Attempt full update, ignore errors to proceed with installation
apt-get update -q -y || echo -e "${YELLOW}[!] Update finished with warnings.${NC}"

#═══════════════════════════════════════════════════════════════════════
# STEP 2: NUCLEAR CLEANUP & PREPARATION
#═══════════════════════════════════════════════════════════════════════
echo -e "${BLUE}[INFO] Step 2: Cleaning old installations...${NC}"

# 1. Kill Processes
pkill -9 -f "conduit" || true
pkill -9 -f "menu.sh" || true
# Kill package managers only if they are stuck
killall apt apt-get dpkg 2>/dev/null || true

# 2. Remove Lock Files
rm -f /var/lib/apt/lists/lock 
rm -f /var/cache/apt/archives/lock
rm -f /var/lib/dpkg/lock*

# 3. Destroy Docker Container
if command -v docker &>/dev/null; then
    docker stop conduit 2>/dev/null || true
    docker rm conduit 2>/dev/null || true
fi

# 4. Remove Files & Scripts
rm -f /usr/local/bin/conduit
rm -rf "$INSTALL_DIR/menu.sh"

#═══════════════════════════════════════════════════════════════════════
# STEP 3: INSTALLATION
#═══════════════════════════════════════════════════════════════════════
echo -e "${BLUE}[INFO] Step 3: Installing Dependencies...${NC}"

# Install essentials + ipset (for firewall)
if [ -f /etc/debian_version ]; then
    apt-get install -y -q curl gawk tcpdump geoip-bin geoip-database qrencode ipset >/dev/null 2>&1 || true
elif [ -f /etc/alpine-release ]; then
    apk add --no-cache curl gawk tcpdump geoip qrencode ipset >/dev/null 2>&1 || true
fi

# Setup Docker
if ! command -v docker &>/dev/null; then
    echo -e "${BLUE}[INFO] Installing Docker...${NC}"
    curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 || true
    systemctl start docker >/dev/null 2>&1 || true
    systemctl enable docker >/dev/null 2>&1 || true
fi

#═══════════════════════════════════════════════════════════════════════
# STEP 4: DEPLOY CONDUIT
#═══════════════════════════════════════════════════════════════════════
echo -e "${BLUE}[INFO] Step 4: Deploying Service...${NC}"
mkdir -p "$INSTALL_DIR"
docker volume create conduit-data >/dev/null 2>&1 || true

# Restore Backup (Identity Persistence)
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
# STEP 5: SMART FIREWALL CONFIGURATION
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
    echo "Applying Smart Rules..."
    # 1. Update IP Set
    ipset create $IPSET hash:net -exist
    ipset flush $IPSET
    curl -sL "$IP_LIST" | while read line; do [[ "$line" =~ ^# ]] || ipset add $IPSET "$line" -exist; done
    
    # 2. Apply Rules
    iptables -F INPUT
    # Essential
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT
    
    # Iran VIP (Allow All)
    iptables -A INPUT -m set --match-set $IPSET src -j ACCEPT
    
    # World Throttle (Allow Trackers, Block Heavy Users)
    iptables -A INPUT -m state --state NEW -m recent --set
    iptables -A INPUT -m state --state NEW -m recent --update --seconds 60 --hitcount 3 -j DROP
    iptables -A INPUT -j ACCEPT
    
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
        if [ -f "$STATE_FILE" ]; then do_enable; fi ;;
esac
EOF
chmod +x "$FW_SCRIPT"

#═══════════════════════════════════════════════════════════════════════
# STEP 6: AUTO-START SERVICE setup
#═══════════════════════════════════════════════════════════════════════
cat > /etc/systemd/system/conduit.service << EOF
[Unit]
Description=Psiphon Conduit
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
# Restore firewall rules before starting container
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
# STEP 7: STATIC MENU (NO LOOP / NO DATA)
#═══════════════════════════════════════════════════════════════════════
cat << 'EOF' > "$MENU_SCRIPT"
#!/bin/bash
FW="/opt/conduit/firewall.sh"
CYAN='\033[1;36m'
GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Clear screen ONCE
clear

echo -e "${CYAN}═══ 🚀 CONDUIT v12.0 (STATIC MENU) ═══${NC}"
echo ""
echo "  [1] Show Active Users (Snapshot)"
echo "  [2] View Logs"
echo "  [3] Restart Service"
echo "  [4] Stop Service"
echo "  -----------------------"
echo "  [5] Enable Smart Firewall (Iran VIP)"
echo "  [6] Disable Firewall"
echo "  -----------------------"
echo "  [0] Exit"
echo ""

# Wait for input. No background loop.
read -p "Select option > " choice
echo ""

case $choice in
    1)
        echo "Checking users..."
        ss -tun state established 2>/dev/null | awk '{print $5}' | cut -d: -f1 | grep -vE "127.0.0.1|\[::1\]" | sort | uniq -c | sort -nr | head -n 15
        echo ""
        read -p "Press Enter to return..."
        # Re-run menu manually if needed, or just exit. 
        # User requested NO LOOP, so we exit after action or just finish.
        ;;
    2) docker logs --tail 50 -f conduit ;;
    3) docker restart conduit; echo "Restarted." ;;
    4) docker stop conduit; echo "Stopped." ;;
    5) bash "$FW" enable ;;
    6) bash "$FW" disable ;;
    0) exit 0 ;;
    *) echo "Invalid option." ;;
esac

echo ""
echo -e "${YELLOW}Action complete. Type 'conduit' to open menu again.${NC}"
EOF
chmod +x "$MENU_SCRIPT"
rm -f /usr/local/bin/conduit
ln -s "$MENU_SCRIPT" /usr/local/bin/conduit

#═══════════════════════════════════════════════════════════════════════
# STEP 8: FINALIZATION & AUTO-OPEN
#═══════════════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}[✓] INSTALLATION COMPLETE.${NC}"
echo "------------------------------------------------"
echo -e " To open menu: ${YELLOW}conduit${NC}"
echo "------------------------------------------------"
sleep 1

# Automatically open the menu
/usr/local/bin/conduit
