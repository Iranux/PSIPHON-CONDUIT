#!/bin/bash
#
# ╔═══════════════════════════════════════════════════════════════════╗
# ║   🚀 PSIPHON CONDUIT MANAGER v4.2 (FINAL STABLE)                 ║
# ║                                                                   ║
# ║  • CLEAN INSTALL on a clean system.                               ║
# ║  • MENU: Static (No auto-refresh loop).                           ║
# ║  • FIREWALL: Smart Iran-VIP logic.                                ║
# ╚═══════════════════════════════════════════════════════════════════╝
#

if [ "$EUID" -ne 0 ]; then
    echo "Run with sudo!"
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
set -e

# --- VARIABLES ---
CONDUIT_IMAGE="ghcr.io/ssmirr/conduit/conduit:latest"
INSTALL_DIR="/opt/conduit"
BACKUP_DIR="$INSTALL_DIR/backups"
MENU_SCRIPT="$INSTALL_DIR/menu.sh"
FW_SCRIPT="$INSTALL_DIR/firewall.sh"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}[INFO] Installing Dependencies...${NC}"
if [ -f /etc/debian_version ]; then
    apt-get update -q -y >/dev/null 2>&1 || true
    apt-get install -y -q curl gawk tcpdump geoip-bin geoip-database qrencode ipset >/dev/null 2>&1 || true
elif [ -f /etc/alpine-release ]; then
    apk add --no-cache curl gawk tcpdump geoip qrencode ipset >/dev/null 2>&1 || true
fi

echo -e "${CYAN}[INFO] Setting up Docker...${NC}"
if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 || true
    systemctl start docker >/dev/null 2>&1 || true
    systemctl enable docker >/dev/null 2>&1 || true
fi

echo -e "${CYAN}[INFO] Starting Conduit (50 Users / 5 Mbps)...${NC}"
mkdir -p "$INSTALL_DIR"
docker stop conduit 2>/dev/null || true
docker rm conduit 2>/dev/null || true
docker volume create conduit-data >/dev/null 2>&1 || true

# START CONTAINER
docker run -d \
    --name conduit \
    --restart unless-stopped \
    --log-opt max-size=10m \
    -v conduit-data:/home/conduit/data \
    --network host \
    "$CONDUIT_IMAGE" \
    start --max-clients 50 --bandwidth 5 --stats-file >/dev/null

# SAVE CONFIG
echo "MAX_CLIENTS=50" > "$INSTALL_DIR/settings.conf"
echo "BANDWIDTH=5" >> "$INSTALL_DIR/settings.conf"

# ENABLE AUTO-START
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
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable conduit.service >/dev/null 2>&1 || true

# CREATE FIREWALL SCRIPT
cat << 'EOF' > "$FW_SCRIPT"
#!/bin/bash
IPSET="iran_ips"
URL="https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4/ir.cidr"

if [ "$1" == "enable" ]; then
    echo "Downloading Iran IPs..."
    ipset create $IPSET hash:net -exist
    ipset flush $IPSET
    curl -sL "$URL" | while read line; do [[ "$line" =~ ^# ]] || ipset add $IPSET "$line" -exist; done
    
    iptables -F INPUT
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT
    # Iran Unlimited
    iptables -A INPUT -m set --match-set $IPSET src -j ACCEPT
    # Others Throttled (Allow Trackers)
    iptables -A INPUT -m state --state NEW -m recent --set
    iptables -A INPUT -m state --state NEW -m recent --update --seconds 60 --hitcount 3 -j DROP
    iptables -A INPUT -j ACCEPT
    echo "Smart Firewall ENABLED."
else
    iptables -P INPUT ACCEPT
    iptables -F INPUT
    echo "Firewall DISABLED."
fi
EOF
chmod +x "$FW_SCRIPT"

# CREATE STATIC MENU
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
    echo -e "${CYAN}║      🚀 CONDUIT MANAGER v4.2 (FINAL STATIC)                ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    if docker ps | grep -q conduit; then
        echo -e "  STATUS:   ${GREEN}RUNNING${NC}"
    else
        echo -e "  STATUS:   ${RED}STOPPED${NC}"
    fi

    if iptables -L INPUT 2>/dev/null | grep -q "match-set iran_ips"; then
        echo -e "  FIREWALL: ${GREEN}SMART (Iran VIP)${NC}"
    else
        echo -e "  FIREWALL: ${YELLOW}OPEN (No Limits)${NC}"
    fi

    echo ""
    echo "  [1] 👥 Active Users (Snapshot)"
    echo "  [2] 📄 Logs"
    echo "  [3] 🔄 Restart"
    echo "  [4] 🛑 Stop"
    echo "  -----------------------"
    echo "  [5] 🧠 Enable Smart Filter"
    echo "  [6] 🔓 Disable Filter"
    echo "  -----------------------"
    echo "  [0] 🚪 Exit"
    echo ""
    
    # WAITS HERE FOREVER. NO FLICKER.
    read -p "  Select option: " choice
    
    case $choice in
        1)
            echo -e "\n${CYAN}--- USERS ---${NC}"
            ss -tun state established 2>/dev/null | awk '{print $5}' | cut -d: -f1 | grep -vE "127.0.0.1|\[::1\]" | sort | uniq -c | sort -nr | head -n 15
            read -p "Press Enter..." ;;
        2) docker logs --tail 50 -f conduit ;;
        3) docker restart conduit; sleep 1 ;;
        4) docker stop conduit; sleep 1 ;;
        5) bash "$FW" enable; read -p "Press Enter..." ;;
        6) bash "$FW" disable; read -p "Press Enter..." ;;
        0) clear; exit 0 ;;
    esac
done
EOF
chmod +x "$MENU_SCRIPT"
rm -f /usr/local/bin/conduit
ln -s "$MENU_SCRIPT" /usr/local/bin/conduit

echo ""
echo -e "${GREEN}[✓] INSTALLED.${NC}"
echo "Type 'conduit' to open menu."
