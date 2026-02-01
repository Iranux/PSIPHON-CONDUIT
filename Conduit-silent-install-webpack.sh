#!/bin/bash
#
# ╔═══════════════════════════════════════════════════════════════════╗
# ║   🚀 PSIPHON CONDUIT MANAGER v6.0 (FINAL FIX)                    ║
# ║                                                                   ║
# ║  • PRE-INSTALL: Forcefully kills ALL old background scripts.      ║
# ║  • MENU: 100% Static. No timers. No refresh loops.                ║
# ║  • BANNER: Correctly updated to v6.0.                             ║
# ╚═══════════════════════════════════════════════════════════════════╝
#

# --- 1. ROOT CHECK ---
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo bash $0"
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
set -e

# --- 2. CONFIGURATION ---
CONDUIT_IMAGE="ghcr.io/ssmirr/conduit/conduit:latest"
INSTALL_DIR="/opt/conduit"
BACKUP_DIR="$INSTALL_DIR/backups"
MENU_SCRIPT="$INSTALL_DIR/menu.sh"
FW_SCRIPT="$INSTALL_DIR/firewall.sh"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

#═══════════════════════════════════════════════════════════════════════
# 3. AGGRESSIVE CLEANUP (THE FIX FOR FLICKERING)
#═══════════════════════════════════════════════════════════════════════
echo -e "${RED}[!!!] KILLING OLD PROCESSES...${NC}"

# Stop service first
systemctl stop conduit.service 2>/dev/null || true
systemctl disable conduit.service 2>/dev/null || true

# Kill any script that looks like a conduit manager
# This stops the old loops running in background
pkill -9 -f "conduit" || true
pkill -9 -f "menu.sh" || true
pkill -9 -f "watch" || true
pkill -9 -f "sleep" || true  # Safe on a dedicated server

# Kill stuck pkg managers
killall -9 apt apt-get dpkg 2>/dev/null || true
rm -f /var/lib/apt/lists/lock 
rm -f /var/cache/apt/archives/lock
rm -f /var/lib/dpkg/lock*

echo -e "${GREEN}[✓] Background cleared.${NC}"

#═══════════════════════════════════════════════════════════════════════
# 4. INSTALL DEPENDENCIES
#═══════════════════════════════════════════════════════════════════════
echo -e "${BLUE}[INFO] Installing Dependencies...${NC}"
if [ -f /etc/debian_version ]; then
    dpkg --configure -a >/dev/null 2>&1 || true
    apt-get update -q -y >/dev/null 2>&1 || true
    apt-get install -y -q curl gawk tcpdump geoip-bin geoip-database qrencode ipset >/dev/null 2>&1 || true
elif [ -f /etc/alpine-release ]; then
    apk add --no-cache curl gawk tcpdump geoip qrencode ipset >/dev/null 2>&1 || true
fi

# Clean old installation files
if command -v docker &>/dev/null; then
    docker stop conduit 2>/dev/null || true
    docker rm conduit 2>/dev/null || true
fi
rm -rf /usr/local/bin/conduit
rm -rf "$INSTALL_DIR/menu.sh"

#═══════════════════════════════════════════════════════════════════════
# 5. DOCKER & RESTORE
#═══════════════════════════════════════════════════════════════════════
echo -e "${BLUE}[INFO] Setting up Docker...${NC}"
if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 || true
    systemctl start docker >/dev/null 2>&1 || true
    systemctl enable docker >/dev/null 2>&1 || true
fi

echo -e "${BLUE}[INFO] Restoring Backup...${NC}"
mkdir -p "$INSTALL_DIR"
if [ -d "$BACKUP_DIR" ]; then
    BACKUP_FILE=$(ls -t "$BACKUP_DIR"/conduit_key_*.json 2>/dev/null | head -1)
    if [ -n "$BACKUP_FILE" ]; then
        echo -e "${GREEN}[✓] Restoring Identity...${NC}"
        docker volume create conduit-data >/dev/null 2>&1 || true
        docker run --rm -v conduit-data:/data -v "$BACKUP_DIR":/bkp alpine \
            sh -c "cp /bkp/$(basename "$BACKUP_FILE") /data/conduit_key.json && chown 1000:1000 /data/conduit_key.json"
    fi
fi

#═══════════════════════════════════════════════════════════════════════
# 6. START CONDUIT (50 Clients / 5 Mbps)
#═══════════════════════════════════════════════════════════════════════
echo -e "${BLUE}[INFO] Starting Service...${NC}"
docker volume create conduit-data >/dev/null 2>&1 || true
docker run --rm -v conduit-data:/data alpine chown -R 1000:1000 /data >/dev/null 2>&1 || true

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

#═══════════════════════════════════════════════════════════════════════
# 7. AUTO-START (Systemd)
#═══════════════════════════════════════════════════════════════════════
cat > /etc/systemd/system/conduit.service << EOF
[Unit]
Description=Psiphon Conduit
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/docker start conduit
ExecStop=/usr/bin/docker stop conduit

[Install]
WantedBy=multi-user.target
EOF

if command -v systemctl &>/dev/null; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable conduit.service >/dev/null 2>&1 || true
    systemctl start conduit.service >/dev/null 2>&1 || true
fi

#═══════════════════════════════════════════════════════════════════════
# 8. FIREWALL SCRIPT (SMART)
#═══════════════════════════════════════════════════════════════════════
cat << 'EOF' > "$FW_SCRIPT"
#!/bin/bash
IP_LIST="https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4/ir.cidr"
IPSET="iran_ips"
CYAN='\033[1;36m'
GREEN='\033[1;32m'
NC='\033[0m'

do_enable() {
    echo -e "${CYAN}Downloading Iran IP List...${NC}"
    if ! curl -sL "$IP_LIST" -o /tmp/ir.cidr; then echo "Download failed"; return; fi
    
    ipset create $IPSET hash:net -exist
    ipset flush $IPSET
    while read line; do [[ "$line" =~ ^# ]] || ipset add $IPSET "$line" -exist; done < /tmp/ir.cidr
    
    iptables -F INPUT
    # Essential
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT
    
    # Iran VIP
    iptables -A INPUT -m set --match-set $IPSET src -j ACCEPT
    
    # Others Throttled (Max 3 new connections per min)
    iptables -A INPUT -m state --state NEW -m recent --set
    iptables -A INPUT -m state --state NEW -m recent --update --seconds 60 --hitcount 3 -j DROP
    iptables -A INPUT -j ACCEPT
    
    echo -e "${GREEN}SMART FIREWALL ENABLED.${NC}"
}

do_disable() {
    iptables -P INPUT ACCEPT
    iptables -F INPUT
    echo -e "${GREEN}FIREWALL DISABLED.${NC}"
}

case "$1" in
    enable) do_enable ;;
    disable) do_disable ;;
esac
EOF
chmod +x "$FW_SCRIPT"

#═══════════════════════════════════════════════════════════════════════
# 9. STATIC MENU (CORRECTED VERSION LABEL)
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
    # --- HERE IS THE UPDATED BANNER ---
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║      🚀 CONDUIT MANAGER v6.0 (FINAL FIX)                   ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Status Checks
    if docker ps | grep -q conduit; then
        echo -e "  SERVICE:  ${GREEN}RUNNING${NC}"
    else
        echo -e "  SERVICE:  ${RED}STOPPED${NC}"
    fi

    if iptables -L INPUT 2>/dev/null | grep -q "match-set iran_ips"; then
        echo -e "  FILTER:   ${GREEN}SMART (Iran VIP)${NC}"
    else
        echo -e "  FILTER:   ${YELLOW}OPEN (No Limits)${NC}"
    fi

    echo ""
    echo "  [1] 👥 Active Users (Snapshot)"
    echo "  [2] 📄 View Logs"
    echo "  [3] 🔄 Restart Service"
    echo "  [4] 🛑 Stop Service"
    echo "  -----------------------"
    echo "  [5] 🧠 Enable Smart Filter"
    echo "  [6] 🔓 Disable Filter"
    echo "  -----------------------"
    echo "  [0] 🚪 Exit"
    echo ""
    
    # WAITS FOREVER - NO FLICKER
    read -p "  Select option: " choice
    
    case $choice in
        1)
            echo -e "\n${CYAN}--- USERS SNAPSHOT ---${NC}"
            ss -tun state established 2>/dev/null | awk '{print $5}' | cut -d: -f1 | grep -vE "127.0.0.1|\[::1\]" | sort | uniq -c | sort -nr | head -n 15
            echo ""
            read -p "Press Enter to return..."
            ;;
        2) 
            echo -e "\n${CYAN}--- LOGS (Ctrl+C to exit) ---${NC}"
            docker logs -f --tail 50 conduit
            ;;
        3)
            echo "Restarting..."
            docker restart conduit
            sleep 1
            ;;
        4)
            echo "Stopping..."
            docker stop conduit
            sleep 1
            ;;
        5)
            bash "$FW" enable
            read -p "Press Enter to return..."
            ;;
        6)
            bash "$FW" disable
            read -p "Press Enter to return..."
            ;;
        0) 
            clear
            exit 0 
            ;;
        *) ;;
    esac
done
EOF
chmod +x "$MENU_SCRIPT"
rm -f /usr/local/bin/conduit
ln -s "$MENU_SCRIPT" /usr/local/bin/conduit

#═══════════════════════════════════════════════════════════════════════
# 10. FINISH
#═══════════════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}[✓] INSTALLATION COMPLETE.${NC}"
echo "------------------------------------------------"
echo -e " To open menu: ${YELLOW}conduit${NC}"
echo "------------------------------------------------"
sleep 2
exec /usr/local/bin/conduit
