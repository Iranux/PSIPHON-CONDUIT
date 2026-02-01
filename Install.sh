#!/bin/bash
#
# ╔═══════════════════════════════════════════════════════════════════╗
# ║   🚀 PSIPHON CONDUIT MANAGER (Iranux Ultimate Master)             ║
# ║                                                                   ║
# ║   • Step 1: Root Access & System Update                           ║
# ║   • Step 2: Iranux Deep Clean (Conflict Removal)                  ║
# ║   • Step 3: Silent Installation (Default Settings)                ║
# ║   • Step 4: Auto-Launch Menu                                      ║
# ╚═══════════════════════════════════════════════════════════════════╝
#

# 1. AUTO ELEVATE TO ROOT (Equivalent to sudo su logic)
if [ "$EUID" -ne 0 ]; then
    if [ -f "$0" ]; then
        echo "Requesting root privileges..."
        exec sudo bash "$0" "$@"
    else
        echo "Error: This script needs root. Run with sudo."
        exit 1
    fi
fi

# Stop apt from asking questions (Non-interactive mode)
export DEBIAN_FRONTEND=noninteractive

# 2. FULL SYSTEM UPDATE (First Priority)
echo "------------------------------------------------"
echo "Running system update (apt update)..."
echo "------------------------------------------------"
if command -v apt-get &>/dev/null; then
    apt-get update -y -q
fi

# Configuration Defaults (No questions asked)
VERSION="2.0-Iranux"
CONDUIT_IMAGE="ghcr.io/ssmirr/conduit/conduit:latest"
INSTALL_DIR="/opt/conduit"
BACKUP_DIR="$INSTALL_DIR/backups"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

#═══════════════════════════════════════════════════════════════════════
# IRANUX ENGINE: DEEP CLEAN & PREPARE
#═══════════════════════════════════════════════════════════════════════

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }

detect_os() {
    if [ -f /etc/os-release ]; then . /etc/os-release; OS="$ID"; else OS=$(uname -s); fi
    case "$OS" in
        ubuntu|debian|linuxmint|kali) PKG_MANAGER="apt" ;;
        centos|rhel|fedora|almalinux) PKG_MANAGER="dnf" ;;
        alpine) PKG_MANAGER="apk" ;;
        *) PKG_MANAGER="unknown" ;;
    esac
}

deep_clean_system() {
    echo ""
    log_warn "Starting Iranux Deep Clean..."
    
    # Kill stuck package managers
    killall apt apt-get dpkg 2>/dev/null || true
    
    # Fix APT/DPKG specifics
    if [ "$PKG_MANAGER" = "apt" ]; then
        rm -f /var/lib/apt/lists/lock 
        rm -f /var/cache/apt/archives/lock
        rm -f /var/lib/dpkg/lock*
        
        log_info "Repairing dpkg database..."
        dpkg --configure -a || true
        
        log_info "Fixing broken dependencies..."
        apt-get install -f -y || true
        
        log_info "Cleaning apt cache..."
        apt-get clean || true
    fi

    # Wipe previous Conduit Installation
    if command -v docker &>/dev/null; then
        log_info "Removing conflicting containers..."
        docker stop conduit 2>/dev/null || true
        docker rm conduit 2>/dev/null || true
        # Remove numbered instances
        docker stop $(docker ps -a -q --filter name=conduit) 2>/dev/null || true
        docker rm $(docker ps -a -q --filter name=conduit) 2>/dev/null || true
    fi
    
    log_success "System completely cleaned."
}

install_dependencies() {
    log_info "Installing dependencies..."
    local pkgs="curl gawk tcpdump geoip-bin geoip-database qrencode bc jq procps"
    
    if [ "$PKG_MANAGER" = "apt" ]; then
        apt-get install -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold $pkgs || true
    elif [ "$PKG_MANAGER" = "apk" ]; then
        apk add --no-cache curl gawk tcpdump geoip qrencode bc jq procps || true
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
    log_info "Found previous backup. Restoring..."
    docker volume create conduit-data >/dev/null 2>&1 || true
    docker run --rm -v conduit-data:/data -v "$BACKUP_DIR":/bkp alpine sh -c "cp /bkp/$(basename "$backup") /data/conduit_key.json && chown 1000:1000 /data/conduit_key.json"
}

run_conduit_core() {
    log_info "Starting Conduit Containers (Default Settings)..."
    
    # Defaults (No prompts)
    MAX_CLIENTS="${MAX_CLIENTS:-50}"
    BANDWIDTH="${BANDWIDTH:-5}"
    CONTAINER_COUNT="${CONTAINER_COUNT:-1}"

    mkdir -p "$INSTALL_DIR"
    
    for i in $(seq 1 $CONTAINER_COUNT); do
        local cname="conduit"
        local vname="conduit-data"
        [ "$i" -gt 1 ] && cname="conduit-${i}" && vname="conduit-data-${i}"

        docker volume create "$vname" >/dev/null 2>&1 || true
        docker run --rm -v "${vname}:/data" alpine chown -R 1000:1000 /data >/dev/null 2>&1 || true

        docker run -d \
            --name "$cname" \
            --restart unless-stopped \
            --log-opt max-size=10m \
            -v "${vname}:/home/conduit/data" \
            --network host \
            "$CONDUIT_IMAGE" \
            start --max-clients "$MAX_CLIENTS" --bandwidth "$BANDWIDTH" --stats-file >/dev/null
    done
    
    log_success "Conduit Started."
}

#═══════════════════════════════════════════════════════════════════════
# GENERATE MANAGER SCRIPT (Full Features Embedded)
#═══════════════════════════════════════════════════════════════════════

create_management_script() {
    log_info "Installing Management Menu..."
    mkdir -p "$INSTALL_DIR"
    
    # WRITING THE FULL V1.2 MENU LOGIC
    cat > "$INSTALL_DIR/conduit" << 'EOF'
#!/bin/bash
# Iranux Conduit Manager - Ultimate Edition

INSTALL_DIR="/opt/conduit"
CONDUIT_IMAGE="ghcr.io/ssmirr/conduit/conduit:latest"
BACKUP_DIR="$INSTALL_DIR/backups"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

# Load settings
[ -f "$INSTALL_DIR/settings.conf" ] && source "$INSTALL_DIR/settings.conf"
MAX_CLIENTS=${MAX_CLIENTS:-50}
BANDWIDTH=${BANDWIDTH:-5}
CONTAINER_COUNT=${CONTAINER_COUNT:-1}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID:-}
TELEGRAM_ENABLED=${TELEGRAM_ENABLED:-false}

# --- Helpers ---
get_container_name() { local idx=${1:-1}; if [ "$idx" -eq 1 ]; then echo "conduit"; else echo "conduit-${idx}"; fi; }
get_volume_name() { local idx=${1:-1}; if [ "$idx" -eq 1 ]; then echo "conduit-data"; else echo "conduit-data-${idx}"; fi; }

print_header() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║           🚀 PSIPHON CONDUIT MANAGER (IRANUX ULTIMATE)            ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# --- Stats Logic ---
show_dashboard() {
    local stop_dash=0
    trap 'stop_dash=1' SIGINT
    tput smcup 2>/dev/null || true
    
    while [ $stop_dash -eq 0 ]; do
        tput cup 0 0
        print_header
        
        # System
        local cpu=$(grep -c ^processor /proc/cpuinfo)
        local ram=$(free -m | awk '/Mem:/ { printf("%.0f%%", $3/$2*100) }')
        echo -e "${DIM}System: ${cpu} Cores | RAM Usage: ${ram}${NC}"
        echo ""

        # Containers
        printf "  ${BOLD}%-12s %-10s %-12s %-10s${NC}\n" "Container" "Status" "Clients" "Bandwidth"
        echo -e "  ${CYAN}──────────────────────────────────────────────────${NC}"
        
        local total_clients=0
        for i in $(seq 1 $CONTAINER_COUNT); do
            local cname=$(get_container_name $i)
            local status="${RED}STOPPED${NC}"
            local clients="-"
            
            if docker ps | grep -q "$cname"; then
                status="${GREEN}RUNNING${NC}"
                local logs=$(docker logs --tail 30 "$cname" 2>&1 | grep "\[STATS\]" | tail -1)
                local conn=$(echo "$logs" | sed -n 's/.*Connected:[[:space:]]*\([0-9]*\).*/\1/p')
                local cing=$(echo "$logs" | sed -n 's/.*Connecting:[[:space:]]*\([0-9]*\).*/\1/p')
                clients="${conn:-0} (${cing:-0})"
                total_clients=$((total_clients + ${conn:-0}))
            fi
            printf "  %-12s %-19b %-12s %-10s\n" "$cname" "$status" "$clients" "Unlimited"
        done
        
        echo ""
        echo -e "  ${BOLD}Total Clients:${NC} ${GREEN}${total_clients}${NC}"
        echo ""
        
        # Tracker Data
        local snap_file="$INSTALL_DIR/traffic_stats/tracker_snapshot"
        if [ -s "$snap_file" ]; then
             echo -e "${BOLD}Top Locations (Live):${NC}"
             awk -F'|' '{if($4!="") cnt[$4]++} END{for(c in cnt) print cnt[c]"|"c}' "$snap_file" | sort -t'|' -k1 -nr | head -5 | while IFS='|' read -r cnt country; do
                printf "  %-20s %s IPs\n" "$country" "$cnt"
             done
        else
             echo -e "${DIM}Waiting for tracker data...${NC}"
        fi
        
        echo ""
        echo -e "${DIM}Press Ctrl+C to return...${NC}"
        read -t 2 -n 1 && stop_dash=1
    done
    tput rmcup 2>/dev/null || true
    trap - SIGINT
}

show_live_logs() {
    echo -e "${CYAN}Streaming logs... (Ctrl+C to exit)${NC}"
    docker logs -f --tail 50 conduit
}

# --- Actions ---
restart_conduit() {
    echo "Restarting containers..."
    for i in $(seq 1 $CONTAINER_COUNT); do
        docker restart $(get_container_name $i)
    done
    echo -e "${GREEN}Done.${NC}"
    sleep 1
}

change_settings() {
    echo ""
    echo "Current: Clients=$MAX_CLIENTS | Bandwidth=$BANDWIDTH | Containers=$CONTAINER_COUNT"
    read -p "New Max Clients (Enter to keep): " new_clients
    read -p "New Container Count (1-5): " new_count
    
    [ -n "$new_clients" ] && MAX_CLIENTS=$new_clients
    [ -n "$new_count" ] && CONTAINER_COUNT=$new_count
    
    # Save & Re-apply
    cat > "$INSTALL_DIR/settings.conf" << CONF
MAX_CLIENTS=$MAX_CLIENTS
BANDWIDTH=$BANDWIDTH
CONTAINER_COUNT=$CONTAINER_COUNT
TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID"
TELEGRAM_ENABLED=$TELEGRAM_ENABLED
CONF
    
    echo -e "${YELLOW}Applying changes (Recreating containers)...${NC}"
    for i in $(seq 1 5); do docker rm -f "conduit-${i}" "conduit" 2>/dev/null; done
    
    for i in $(seq 1 $CONTAINER_COUNT); do
        local cname=$(get_container_name $i)
        local vname="conduit-data"
        [ "$i" -gt 1 ] && vname="conduit-data-${i}"
        docker volume create "$vname" >/dev/null
        docker run -d --name "$cname" --restart unless-stopped \
            -v "${vname}:/home/conduit/data" --network host \
            "$CONDUIT_IMAGE" start --max-clients "$MAX_CLIENTS" --bandwidth "$BANDWIDTH" --stats-file >/dev/null
    done
    echo -e "${GREEN}Applied.${NC}"
    sleep 2
}

# --- Telegram ---
setup_telegram() {
    echo ""
    echo -e "${BOLD}Telegram Bot Setup${NC}"
    read -p "Bot Token: " TELEGRAM_BOT_TOKEN
    read -p "Chat ID: " TELEGRAM_CHAT_ID
    
    if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
        TELEGRAM_ENABLED=true
        # Save settings again
        cat > "$INSTALL_DIR/settings.conf" << CONF
MAX_CLIENTS=$MAX_CLIENTS
BANDWIDTH=$BANDWIDTH
CONTAINER_COUNT=$CONTAINER_COUNT
TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID"
TELEGRAM_ENABLED=$TELEGRAM_ENABLED
CONF
        
        # Create Service Script
        cat > "$INSTALL_DIR/conduit-telegram.sh" << 'TG'
#!/bin/bash
source /opt/conduit/settings.conf
[ "$TELEGRAM_ENABLED" != "true" ] && exit 0
send_msg() {
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" -d text="$1" -d parse_mode="Markdown" >/dev/null
}
send_msg "✅ *Conduit Started*
Host: $(hostname)"
# Loop for alerts could go here
TG
        chmod +x "$INSTALL_DIR/conduit-telegram.sh"
        
        # Systemd
        cat > /etc/systemd/system/conduit-telegram.service << SVC
[Unit]
Description=Conduit Bot
After=network.target
[Service]
ExecStart=/bin/bash /opt/conduit/conduit-telegram.sh
Restart=always
[Install]
WantedBy=multi-user.target
SVC
        systemctl daemon-reload
        systemctl enable conduit-telegram
        systemctl restart conduit-telegram
        echo -e "${GREEN}Bot configured.${NC}"
    fi
}

# --- Tracker (Background) ---
setup_tracker() {
    echo "Enabling traffic tracker..."
    mkdir -p "$INSTALL_DIR/traffic_stats"
    
    cat > "$INSTALL_DIR/conduit-tracker.sh" << 'TRK'
#!/bin/bash
DIR="/opt/conduit/traffic_stats"
SNAP="$DIR/tracker_snapshot"
mkdir -p "$DIR"
while true; do
    timeout 15s tcpdump -nn -i any -q "(tcp or udp) and not port 22" 2>/dev/null | \
    awk '{
        if ($3 ~ /\./) ip=$3; else ip=$5;
        gsub(/:.*/, "", ip);
        print "RX|" ip
    }' > "$SNAP.tmp"
    
    # Resolve
    if [ -s "$SNAP.tmp" ]; then
        sort "$SNAP.tmp" | uniq -c | while read count dir ip; do
            country="Unknown"
            if command -v geoiplookup &>/dev/null; then
                country=$(geoiplookup "$ip" | awk -F: '{print $2}' | xargs | cut -d, -f1)
            fi
            echo "BOTH|$count|0|$country|$ip" >> "$SNAP.new"
        done
        mv "$SNAP.new" "$SNAP"
    fi
    rm -f "$SNAP.tmp"
done
TRK
    chmod +x "$INSTALL_DIR/conduit-tracker.sh"
    
    cat > /etc/systemd/system/conduit-tracker.service << SVC
[Unit]
Description=Conduit Tracker
After=network.target
[Service]
ExecStart=/bin/bash /opt/conduit/conduit-tracker.sh
Restart=always
[Install]
WantedBy=multi-user.target
SVC
    systemctl daemon-reload
    systemctl enable conduit-tracker
    systemctl restart conduit-tracker
}

show_qr() {
    clear
    local key_json=$(docker run --rm -v conduit-data:/data alpine cat /data/conduit_key.json 2>/dev/null)
    local raw_key=$(echo "$key_json" | grep "privateKeyBase64" | awk -F'"' '{print $4}')
    echo -e "${CYAN}Key:${NC} $raw_key"
    if command -v qrencode &>/dev/null; then
         local url="network.ryve.app://(app)/conduits?claim=$(echo -n "{\"version\":1,\"data\":{\"key\":\"${raw_key}\",\"name\":\"$(hostname)\"}}" | base64 | tr -d '\n')"
         qrencode -t ANSIUTF8 "$url"
    else
         echo "Install qrencode to see QR."
    fi
    echo ""
    read -p "Enter to return..."
}

uninstall_all() {
    read -p "Remove ALL? (y/n): " c
    if [ "$c" == "y" ]; then
        docker stop $(docker ps -a -q --filter name=conduit) 2>/dev/null
        docker rm $(docker ps -a -q --filter name=conduit) 2>/dev/null
        systemctl stop conduit-tracker conduit-telegram 2>/dev/null
        rm -rf /opt/conduit /usr/local/bin/conduit
        echo "Done."
        exit 0
    fi
}

# --- Menu Loop ---
while true; do
    print_header
    echo -e "  1. 📈 Dashboard (Live)"
    echo -e "  2. 📋 Logs"
    echo -e "  3. ⚙️  Settings (Scale)"
    echo -e "  4. 📱 Telegram Setup"
    echo -e "  5. 🔄 Restart"
    echo -e "  6. 🔑 Show QR"
    echo -e "  7. 🩺 Enable Tracker"
    echo -e "  8. 🗑️  Uninstall"
    echo -e "  0. Exit"
    echo ""
    if [ "$1" == "menu" ]; then
        read -p "  Choice: " c
    else
        # Auto-launch default view if argument provided? No, loop it.
        read -p "  Choice: " c
    fi
    
    case $c in
        1) show_dashboard ;;
        2) show_live_logs ;;
        3) change_settings ;;
        4) setup_telegram ;;
        5) restart_conduit ;;
        6) show_qr ;;
        7) setup_tracker ;;
        8) uninstall_all ;;
        0) exit 0 ;;
        *) echo "Invalid" ;;
    esac
done
EOF

    chmod +x "$INSTALL_DIR/conduit"
    rm -f /usr/local/bin/conduit
    ln -s "$INSTALL_DIR/conduit" /usr/local/bin/conduit
}

#═══════════════════════════════════════════════════════════════════════
# MAIN EXECUTION FLOW
#═══════════════════════════════════════════════════════════════════════

detect_os
deep_clean_system
install_dependencies
install_docker
check_restore
run_conduit_core
create_management_script

# Initial Default Config Generation
if [ ! -f "$INSTALL_DIR/settings.conf" ]; then
    echo "MAX_CLIENTS=50" > "$INSTALL_DIR/settings.conf"
    echo "BANDWIDTH=5" >> "$INSTALL_DIR/settings.conf"
    echo "CONTAINER_COUNT=1" >> "$INSTALL_DIR/settings.conf"
fi

echo ""
log_success "INSTALLATION COMPLETE."
echo "------------------------------------------------"
echo "Launching Menu..."
sleep 2

# 4. AUTO-LAUNCH MENU (Final Step)
exec "$INSTALL_DIR/conduit"
