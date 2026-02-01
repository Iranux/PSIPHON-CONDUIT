#!/bin/bash
#
# ╔═══════════════════════════════════════════════════════════════════╗
# ║   🚀 PSIPHON CONDUIT MANAGER v2.0 (FLICKER-FREE EDITION)         ║
# ║                                                                   ║
# ║  • Fixes: Removing screen flashing using ANSI cursor reset        ║
# ║  • Feature: Buffered output for smooth rendering                  ║
# ║  • Settings: 50 Clients / 5 Mbps / 1 Container                    ║
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

VERSION="2.0"
CONDUIT_IMAGE="ghcr.io/ssmirr/conduit/conduit:latest"
INSTALL_DIR="${INSTALL_DIR:-/opt/conduit}"
BACKUP_DIR="$INSTALL_DIR/backups"

# Colors
GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
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
    log_warn "Performing System Check..."
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
# SMOOTH DASHBOARD SCRIPT
#═══════════════════════════════════════════════════════════════════════

create_custom_menu() {
    log_info "Installing Smooth Dashboard..."
    local menu_path="$INSTALL_DIR/conduit"
    
    cat << 'EOF' > "$menu_path"
#!/bin/bash

# ANSI Colors
CYAN='\033[1;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'
DIM='\033[2m'

# Move cursor to top-left
move_home() { printf "\033[H"; }
# Clear from cursor to end of screen
clear_end() { printf "\033[J"; }
# Hide/Show Cursor
hide_cursor() { printf "\033[?25l"; }
show_cursor() { printf "\033[?25h"; }

trap show_cursor EXIT

main_menu() {
    clear
    hide_cursor
    
    while true; do
        move_home
        
        # --- BUILD OUTPUT BUFFER ---
        # We construct the whole screen in a variable first to avoid tearing
        
        OUTPUT="${CYAN}╔════════════════════════════════════════════════════════════╗${NC}\n"
        OUTPUT+="${CYAN}║              🌍 LIVE USER MONITORING                       ║${NC}\n"
        OUTPUT+="${CYAN}╚════════════════════════════════════════════════════════════╝${NC}\n"
        
        # Get Data
        connections=$(ss -tun state established 2>/dev/null | awk '{print $5}' | cut -d: -f1 | grep -vE "127.0.0.1|\[::1\]" | sort | uniq -c | sort -nr)
        total_users=$(echo "$connections" | grep -c . || true)
        
        if [ -z "$connections" ]; then
            OUTPUT+="\n${DIM}  Waiting for connections...${NC}\n"
            OUTPUT+="${DIM}  (It takes time for Psiphon network to find your node)${NC}\n"
            OUTPUT+="\n"
        else
            OUTPUT+="\n"
            OUTPUT+=$(printf "  %-20s %-10s %-20s" "IP ADDRESS" "COUNT" "COUNTRY")
            OUTPUT+="\n  --------------------------------------------------------\n"
            
            # Process lines
            count_lines=0
            while read count ip; do
                [ -z "$ip" ] && continue
                if [ "$count_lines" -ge 8 ]; then break; fi # Limit to 8 rows
                
                country=$(geoiplookup "$ip" 2>/dev/null | awk -F: '{print $2}' | sed 's/^ //')
                if [[ "$country" == *"can't resolve"* ]] || [[ -z "$country" ]]; then country="Unknown"; fi
                
                # Trim country name if too long
                country=${country:0:20}
                
                OUTPUT+=$(printf "  %-20s ${GREEN}%-10s${NC} %-20s\n" "$ip" "$count" "$country")
                ((count_lines++))
            done <<< "$connections"
            
            OUTPUT+="  --------------------------------------------------------\n"
            OUTPUT+="  TOTAL UNIQUE USERS: ${GREEN}$total_users${NC}\n"
        fi
        
        OUTPUT+="\n${CYAN}--- MAIN MENU -----------------------------------${NC}\n"
        OUTPUT+="  [1] Refresh View   [3] Restart Service\n"
        OUTPUT+="  [2] View Logs      [4] Stop Service\n"
        OUTPUT+="  [0] Exit\n"
        OUTPUT+="\n"
        OUTPUT+="  ${YELLOW}Auto-refreshing... Press number to select.${NC}\n"
        
        # Print the whole buffer at once
        echo -e "$OUTPUT"
        clear_end
        
        # Wait for input with timeout (Non-blocking check)
        # We use 'read -t' to create the refresh interval
        if read -t 5 -n 1 choice; then
            case $choice in
                1) continue ;;
                2) 
                    show_cursor
                    echo -e "\n${CYAN}--- LOGS (Press CTRL+C to exit) ---${NC}"
                    docker logs -f --tail 50 conduit
                    hide_cursor
                    clear
                    ;;
                3)
                    echo -e "\n${YELLOW}Restarting...${NC}"
                    docker restart conduit >/dev/null
                    sleep 2
                    ;;
                4)
                    echo -e "\n${RED}Stopping...${NC}"
                    docker stop conduit >/dev/null
                    sleep 1
                    ;;
                0) 
                    show_cursor
                    clear
                    exit 0 
                    ;;
                *) ;;
            esac
        fi
    done
}

main_menu
EOF

    chmod +x "$menu_path"
    rm -f /usr/local/bin/conduit
    ln -s "$menu_path" /usr/local/bin/conduit
    log_success "Smooth Dashboard Installed."
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
echo "Starting Smooth Dashboard in 2 seconds..."
echo "------------------------------------------------"
sleep 2

if [ -f "/usr/local/bin/conduit" ]; then
    exec /usr/local/bin/conduit
fi
