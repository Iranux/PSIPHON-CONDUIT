#!/bin/bash
#
# ╔═══════════════════════════════════════════════════════════════════╗
# ║   🚀 PSIPHON CONDUIT MANAGER (STABLE - NO FLASHING)              ║
# ║                                                                   ║
# ║  • Reverted to stable v1.8 logic (No live monitoring table)       ║
# ║  • Deep Clean & System Repair enabled                             ║
# ║  • Standard Menu (No auto-refresh loops)                          ║
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

CONDUIT_IMAGE="ghcr.io/ssmirr/conduit/conduit:latest"
INSTALL_DIR="${INSTALL_DIR:-/opt/conduit}"
BACKUP_DIR="$INSTALL_DIR/backups"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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
# 1. DEEP CLEAN & REPAIR SYSTEM
#═══════════════════════════════════════════════════════════════════════

deep_clean_system() {
    log_warn "Performing System Check & Cleanup..."

    # 1. Kill stuck package managers
    killall apt apt-get dpkg 2>/dev/null || true
    
    # 2. Fix APT/DPKG specifics
    if [ "$PKG_MANAGER" = "apt" ]; then
        rm -f /var/lib/apt/lists/lock 
        rm -f /var/cache/apt/archives/lock
        rm -f /var/lib/dpkg/lock*

        # Repair dpkg
        dpkg --configure -a >/dev/null 2>&1 || true
        apt-get install -f -y >/dev/null 2>&1 || true
    fi

    # 3. Wipe previous Conduit Installation to ensure clean state
    if command -v docker &>/dev/null; then
        docker stop conduit 2>/dev/null || true
        docker rm conduit 2>/dev/null || true
        # Remove old menu link
        rm -f /usr/local/bin/conduit
    fi
}

#═══════════════════════════════════════════════════════════════════════
# 2. INSTALLATION
#═══════════════════════════════════════════════════════════════════════

install_dependencies() {
    log_info "Installing dependencies..."
    # We install these just in case, but they are not critical for the basic menu
    local pkgs="curl gawk tcpdump geoip-bin geoip-database qrencode"
    
    if [ "$PKG_MANAGER" = "apt" ]; then
        apt-get install -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold $pkgs >/dev/null 2>&1 || true
    elif [ "$PKG_MANAGER" = "apk" ]; then
        apk add --no-cache curl gawk tcpdump geoip qrencode >/dev/null 2>&1 || true
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
             log_warn "Docker script failed, trying package manager..."
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
    
    log_info "Restoring Identity from backup..."
    docker volume create conduit-data >/dev/null 2>&1 || true
    if docker run --rm -v conduit-data:/data -v "$BACKUP_DIR":/bkp alpine sh -c "cp /bkp/$(basename "$backup") /data/conduit_key.json && chown 1000:1000 /data/conduit_key.json"; then
        log_success "Identity restored."
    fi
}

run_conduit() {
    log_info "Starting Conduit (50 Clients / 5 Mbps)..."
    
    # Ensure volume exists and permissions are correct
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

create_menu() {
    log_info "Setting up Management Menu..."
    local menu_path="$INSTALL_DIR/conduit"
    
    # 1. Try to download the OFFICIAL/STANDARD manager from GitHub
    # This is the original behavior before I customized it
    if curl -sL "https://raw.githubusercontent.com/SamNet-dev/conduit-manager/main/conduit.sh" -o "$menu_path" 2>/dev/null; then
        chmod +x "$menu_path"
        log_success "Downloaded official manager."
    else
        # 2. FALLBACK: Simple Static Script (NO LOOPS, NO FLICKERING)
        log_warn "Download failed. Creating basic local menu."
        cat > "$menu_path" << 'EOF'
#!/bin/bash
echo "--- Conduit Basic Menu ---"
echo "1) Check Status (docker ps)"
echo "2) Show Logs (docker logs)"
echo "3) Restart (docker restart)"
echo "4) Stop (docker stop)"
echo "Enter your choice:"
read choice
case $choice in
    1) docker ps -f name=conduit ;;
    2) docker logs --tail 50 conduit ;;
    3) docker restart conduit ;;
    4) docker stop conduit ;;
    *) echo "Invalid option" ;;
esac
EOF
        chmod +x "$menu_path"
    fi

    # Symlink for easy access
    rm -f /usr/local/bin/conduit
    ln -s "$menu_path" /usr/local/bin/conduit
}

#═══════════════════════════════════════════════════════════════════════
# MAIN EXECUTION
#═══════════════════════════════════════════════════════════════════════

detect_os

# 1. Clean & Repair
deep_clean_system

# 2. Install
install_dependencies
install_docker

# 3. Run
check_restore
run_conduit
save_conf
create_menu

echo ""
log_success "INSTALLATION COMPLETE."
echo "------------------------------------------------"
echo "To access the menu, type: conduit"
echo "------------------------------------------------"
echo "Launching menu now..."
sleep 2

if [ -f "/usr/local/bin/conduit" ]; then
    exec /usr/local/bin/conduit menu
fi
