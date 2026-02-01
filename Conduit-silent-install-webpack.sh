#!/bin/bash
#
# ╔═══════════════════════════════════════════════════════════════════╗
# ║   🚀 PSIPHON CONDUIT MANAGER v1.9 (ULTIMATE DASHBOARD)           ║
# ║                                                                   ║
# ║  • Features: Auto-Repair, Deep Clean, Custom English Dashboard    ║
# ║  • Settings: 50 Clients / 5 Mbps / 1 Container                    ║
# ║  • Monitor:  Live GeoIP Table integrated into the menu            ║
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

# Stop apt from asking questions
export DEBIAN_FRONTEND=noninteractive

# Exit on critical errors
set -e

VERSION="1.9"
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
    log_info "Detected OS: $OS ($PKG_MANAGER)"
}

#═══════════════════════════════════════════════════════════════════════
# 1. DEEP CLEAN & REPAIR SYSTEM (From v1.8)
#═══════════════════════════════════════════════════════════════════════

deep_clean_system() {
    log_warn "Starting Deep Clean & System Repair..."

    # 1. Kill stuck package managers
    killall apt apt-get dpkg 2>/dev/null || true
    
    # 2. Fix APT/DPKG specifics
    if [ "$PKG_MANAGER" = "apt" ]; then
        rm -f /var/lib/apt/lists/lock 
        rm -f /var/cache/apt/archives/lock
        rm -f /var/lib/dpkg/lock*

        log_info "Repairing dpkg database..."
        dpkg --configure -a || true
        apt-get install -f -y || true
        apt-get clean || true
        apt-get update -q -y >/dev/null 2>&1 || true
    fi

    # 3. Wipe previous Conduit Installation
    log_info "Wiping previous Conduit installation..."
    if command -v docker &>/dev/null; then
        docker stop conduit 2>/dev/null || true
        docker rm conduit 2>/dev/null || true
        # Remove old menu link
        rm -f /usr/local/bin/conduit
    fi
    
    log_success "System cleaned."
}

#═══════════════════════════════════════════════════════════════════════
# 2. INSTALLATION
#═══════════════════════════════════════════════════════════════════════

install_dependencies() {
    log_info "Installing dependencies..."
    local pkgs="curl gawk tcpdump geoip-bin geoip-database qrencode"
    
    if [ "$PKG_MANAGER" = "apt" ]; then
        apt-get install -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold $pkgs || true
    elif [ "$PKG_MANAGER" = "apk" ]; then
        apk add --no-cache curl gawk tcpdump geoip qrencode || true
    fi
}

install_docker() {
    if command -v docker &>/dev/null; then
        log_success "Docker is present."
        return 0
    fi
    log_info "Installing Docker..."
    if [ "$PKG_MANAGER" = "alpine" ]; then
        apk add --no-cache docker docker-cli-compose || true
        service docker start || true
    else
        if ! curl -fsSL https://get.docker.com | sh >/dev/null 2>&1; then
             log_warn "Docker script failed, trying fallback..."
             if [ "$PKG_MANAGER" = "apt" ]; then apt-get install -y docker.io || true; fi
        fi
        systemctl start docker >/dev/null 2>&1 || true
        systemctl enable docker >/dev/null 2>&1 || true
    fi
}

check_restore() {
    [ ! -d "$BACKUP_DIR" ] && return 0
    local backup=$(ls -t "$BACKUP_DIR"/conduit_key_*.json 2>/dev/null | head -1)
    [ -z "$backup" ] && return 0
    
    log_info "Found backup. Restoring Identity..."
    docker volume create conduit-data >/dev/null 2>&1 || true
    if docker run --rm -v conduit-data:/data -v "$BACKUP_DIR":/bkp alpine sh -c "cp /bkp/$(basename "$backup") /data/conduit_key.json && chown 1000:1000 /data/conduit_key.json"; then
        log_success "Identity restored."
    fi
}

run_conduit() {
    log_info "Starting Conduit (50 Clients / 5 Mbps)..."
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
        log_success "Conduit Started."
    else
        log_error "Failed to start container."
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
# 3. CREATE CUSTOM DASHBOARD (English)
#═══════════════════════════════════════════════════════════════════════

create_custom_menu() {
    log_info "Generating Custom Dashboard with Live Monitor..."
    local menu_path="$INSTALL_DIR/conduit"
    
    # We write the entire menu script here
    cat << 'EOF' > "$menu_path"
#!/bin/bash

# --- Custom Conduit Manager ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

show_monitor() {
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              🌍 LIVE USER MONITORING                       ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    
    # Get connections (exclude localhost)
    # Using 'ss' to find established connections not on 127.0.0.1
    connections=$(ss -tun state established | awk '{print $5}' | cut -d: -f1 | grep -vE "127.0.0.1|\[::1\]" | sort | uniq -c | sort -nr)
    total_users=$(echo "$connections" | grep -c . || true)
    
    if [ -z "$connections" ]; then
        echo -e "\n${YELLOW}  [!] No active users connected yet.${NC}"
        echo -e "  --------------------------------------------------"
        echo -e "  ${YELLOW}NOTE:${NC} It may take 15-60 minutes for Psiphon Network"
        echo -e "        to discover this server and route traffic here."
        echo -e "        Please be patient."
        echo -e "  --------------------------------------------------"
    else
        printf "\n  %-20s %-10s %-20s\n" "IP ADDRESS" "COUNT" "COUNTRY"
        echo "  --------------------------------------------------------"
        
        # Process top 10 IPs to fit on screen
        echo "$connections" | head -n 10 | while read count ip; do
            [ -z "$ip" ] && continue
            
            # GeoIP Lookup
            country=$(geoiplookup "$ip" 2>/dev/null | awk -F: '{print $2}' | sed 's/^ //')
            if [[ "$country" == *"can't resolve"* ]] || [[ -z "$country" ]]; then
                country="Unknown"
            fi
            
            printf "  %-20s ${GREEN}%-10s${NC} %-20s\n" "$ip" "$count" "$country"
        done
        
        if [ "$total_users" -gt 10 ]; then
             echo "  ... (and $((total_users - 10)) more)"
        fi
        
        echo "  --------------------------------------------------------"
        echo -e "  TOTAL UNIQUE USERS: ${GREEN}$total_users${NC}"
    fi
    echo -e "\n  Last Update: $(date '+%H:%M:%S')"
}

main_menu() {
    while true; do
        clear
        show_monitor
        
        echo ""
        echo -e "${CYAN}--- MAIN MENU -----------------------------------${NC}"
        echo "  1) Refresh Monitor (Enter)"
        echo "  2) Show Container Logs"
        echo "  3) Restart Conduit"
        echo "  4) Stop Conduit"
        echo "  0) Exit"
        echo ""
        
        # Read with timeout for auto-refresh
        read -t 10 -p "  Select option: " choice || true
        
        case $choice in
            1|"") continue ;;
            2) 
                echo -e "\n${YELLOW}Press CTRL+C to stop logs...${NC}"
                sleep 1
                docker logs -f --tail 100 conduit
                ;;
            3)
                echo "Restarting..."
                docker restart conduit
                sleep 2
                ;;
            4)
                echo "Stopping..."
                docker stop conduit
                ;;
            0) exit 0 ;;
            *) ;;
        esac
    done
}

# Run
main_menu
EOF

    chmod +x "$menu_path"
    rm -f /usr/local/bin/conduit
    ln -s "$menu_path" /usr/local/bin/conduit
    log_success "Custom Dashboard Installed."
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
echo "Launching Dashboard in 3 seconds..."
echo "------------------------------------------------"
sleep 3

if [ -f "/usr/local/bin/conduit" ]; then
    exec /usr/local/bin/conduit
fi
