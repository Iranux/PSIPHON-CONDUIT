#!/bin/bash
#
# ╔═══════════════════════════════════════════════════════════════════╗
# ║   🚀 PSIPHON CONDUIT MANAGER v2.1 (CLEAN STATIC EDITION)         ║
# ║                                                                   ║
# ║  • FIXED: Removed flickering table from main menu                 ║
# ║  • STABLE: Main menu is now static (no auto-refresh)              ║
# ║  • FEATURE: Added dedicated "Live Monitor" submenu using 'watch'  ║
# ╚═══════════════════════════════════════════════════════════════════╝
#

# --- AUTO ELEVATE TO ROOT ---
if [ "$EUID" -ne 0 ]; then
    if [ -f "$0" ]; then
        echo "Requesting root privileges..."
        exec sudo bash "$0" "$@"
    else
        echo "Error: This script needs root."
        echo "Please run with sudo:  curl ... | sudo bash"
        exit 1
    fi
fi

export DEBIAN_FRONTEND=noninteractive
set -e

VERSION="2.1"
CONDUIT_IMAGE="ghcr.io/ssmirr/conduit/conduit:latest"
INSTALL_DIR="${INSTALL_DIR:-/opt/conduit}"
BACKUP_DIR="$INSTALL_DIR/backups"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

#═══════════════════════════════════════════════════════════════════════
# Helpers
#═══════════════════════════════════════════════════════════════════════

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }

detect_os() {
    OS="unknown"
    PKG_MANAGER="unknown"
    if [ -f /etc/os-release ]; then . /etc/os-release; OS="$ID"; else OS=$(uname -s); fi
    
    case "$OS" in
        ubuntu|debian|linuxmint|kali) PKG_MANAGER="apt" ;;
        centos|rhel|fedora|almalinux) PKG_MANAGER="dnf" ;;
        alpine) PKG_MANAGER="apk" ;;
        *) PKG_MANAGER="unknown" ;;
    esac
}

#═══════════════════════════════════════════════════════════════════════
# SYSTEM REPAIR & INSTALL
#═══════════════════════════════════════════════════════════════════════

deep_clean_system() {
    log_warn "Performing System Check & Cleanup..."
    killall apt apt-get dpkg 2>/dev/null || true
    if [ "$PKG_MANAGER" = "apt" ]; then
        rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock*
        dpkg --configure -a >/dev/null 2>&1 || true
    fi
    # Wipe old menu
    rm -f /usr/local/bin/conduit
}

install_dependencies() {
    log_info "Verifying dependencies..."
    local pkgs="curl gawk tcpdump geoip-bin geoip-database qrencode"
    if [ "$PKG_MANAGER" = "apt" ]; then
        apt-get install -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold $pkgs >/dev/null 2>&1 || true
    elif [ "$PKG_MANAGER" = "apk" ]; then
        apk add --no-cache curl gawk tcpdump geoip qrencode >/dev/null 2>&1 || true
    fi
}

install_docker() {
    if ! command -v docker &>/dev/null; then
        log_info "Installing Docker..."
        if [ "$PKG_MANAGER" = "alpine" ]; then
            apk add --no-cache docker docker-cli-compose >/dev/null 2>&1 || true
            service docker start >/dev/null 2>&1 || true
        else
            curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 || apt-get install -y docker.io >/dev/null 2>&1 || true
            systemctl start docker >/dev/null 2>&1 || true
        fi
    fi
}

check_restore() {
    [ ! -d "$BACKUP_DIR" ] && return 0
    local backup=$(ls -t "$BACKUP_DIR"/conduit_key_*.json 2>/dev/null | head -1)
    [ -z "$backup" ] && return 0
    docker volume create conduit-data >/dev/null 2>&1 || true
    docker run --rm -v conduit-data:/data -v "$BACKUP_DIR":/bkp alpine sh -c "cp /bkp/$(basename "$backup") /data/conduit_key.json && chown 1000:1000 /data/conduit_key.json" >/dev/null 2>&1 || true
}

run_conduit() {
    log_info "Configuring Conduit (50 Clients / 5 Mbps)..."
    docker rm -f conduit 2>/dev/null || true
    docker volume create conduit-data >/dev/null 2>&1 || true
    docker run --rm -v conduit-data:/data alpine chown -R 1000:1000 /data >/dev/null 2>&1 || true

    if docker run -d \
        --name conduit \
        --restart unless-stopped \
        --log-opt max-size=10m \
        -v conduit-data:/home/conduit/data \
        --network host \
        "$CONDUIT_IMAGE" \
        start --max-clients 50 --bandwidth 5 --stats-file >/dev/null; then
        log_success "Service Started."
    else
        log_error "Failed to start service."
        exit 1
    fi
}

save_conf() {
    mkdir -p "$INSTALL_DIR"
    echo "MAX_CLIENTS=50" > "$INSTALL_DIR/settings.conf"
    echo "BANDWIDTH=5" >> "$INSTALL_DIR/settings.conf"
    echo "CONTAINER_COUNT=1" >> "$INSTALL_DIR/settings.conf"
}

#═══════════════════════════════════════════════════════════════════════
# CLEAN DASHBOARD SCRIPT
#═══════════════════════════════════════════════════════════════════════

create_custom_menu() {
    log_info "Installing Clean Dashboard..."
    local menu_path="$INSTALL_DIR/conduit"
    local stats_helper="$INSTALL_DIR/stats_helper.sh"
    
    # 1. Create a helper script for 'watch' to use (Stats logic)
    cat << 'EOF' > "$stats_helper"
#!/bin/bash
CYAN='\033[1;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${CYAN}--- LIVE USER MONITOR (Updates every 2s) ---${NC}"
printf "%-20s %-10s %-20s\n" "IP ADDRESS" "COUNT" "COUNTRY"
echo "----------------------------------------------------"

connections=$(ss -tun state established 2>/dev/null | awk '{print $5}' | cut -d: -f1 | grep -vE "127.0.0.1|\[::1\]" | sort | uniq -c | sort -nr)
total=$(echo "$connections" | grep -c . || true)

if [ -z "$connections" ]; then
    echo -e "${YELLOW}No active users yet.${NC}"
else
    echo "$connections" | head -n 15 | while read count ip; do
        [ -z "$ip" ] && continue
        country=$(geoiplookup "$ip" 2>/dev/null | awk -F: '{print $2}' | sed 's/^ //')
        [ -z "$country" ] && country="Unknown"
        printf "%-20s ${GREEN}%-10s${NC} %-20s\n" "$ip" "$count" "${country:0:20}"
    done
fi
echo "----------------------------------------------------"
echo -e "TOTAL USERS: ${GREEN}$total${NC}"
EOF
    chmod +x "$stats_helper"

    # 2. Create the Main Menu (Static)
    cat << 'EOF' > "$menu_path"
#!/bin/bash

# Define paths
STATS_SCRIPT="/opt/conduit/stats_helper.sh"

# ANSI Colors
CYAN='\033[1;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

while true; do
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║             🚀 CONDUIT MANAGER (Static Menu)               ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Simple Status Check
    if docker ps | grep -q conduit; then
        echo -e "  STATUS: ${GREEN}RUNNING${NC}"
    else
        echo -e "  STATUS: ${RED}STOPPED${NC}"
    fi
    
    echo ""
    echo "  [1] 🌍 Live Monitor (Show Users)"
    echo "  [2] 📄 View Logs"
    echo "  [3] 🔄 Restart Service"
    echo "  [4] 🛑 Stop Service"
    echo "  [0] 🚪 Exit"
    echo ""
    read -p "  Select option: " choice
    
    case $choice in
        1)
            # Use 'watch' for flicker-free updates
            if command -v watch >/dev/null; then
                watch -c -n 2 "$STATS_SCRIPT"
            else
                # Fallback if watch is missing
                bash "$STATS_SCRIPT"
                echo ""
                read -p "Press Enter to return..."
            fi
            ;;
        2) 
            echo -e "\n${CYAN}--- LOGS (Press CTRL+C to exit) ---${NC}"
            docker logs -f --tail 50 conduit
            ;;
        3)
            echo -e "\n${YELLOW}Restarting...${NC}"
            docker restart conduit
            sleep 2
            ;;
        4)
            echo -e "\n${RED}Stopping...${NC}"
            docker stop conduit
            sleep 1
            ;;
        0) 
            clear
            exit 0 
            ;;
        *) ;;
    esac
done
EOF

    chmod +x "$menu_path"
    rm -f /usr/local/bin/conduit
    ln -s "$menu_path" /usr/local/bin/conduit
    log_success "Clean Dashboard Installed."
}

#═══════════════════════════════════════════════════════════════════════
# MAIN EXECUTION
#═══════════════════════════════════════════════════════════════════════

detect_os
deep_clean_system
install_dependencies
install_docker
check_restore
run_conduit
save_conf
create_custom_menu

echo ""
log_success "INSTALLATION COMPLETE."
echo "------------------------------------------------"
echo "Starting Dashboard..."
echo "------------------------------------------------"
sleep 2

if [ -f "/usr/local/bin/conduit" ]; then
    exec /usr/local/bin/conduit
fi
