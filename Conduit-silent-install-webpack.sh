#!/bin/bash
#
# ╔═══════════════════════════════════════════════════════════════════╗
# ║   🚀 PSIPHON CONDUIT MANAGER v1.8 (DEEP CLEAN + FRESH INSTALL)   ║
# ║                                                                   ║
# ║  • Kills stuck apt processes                                      ║
# ║  • Removes broken lock files                                      ║
# ║  • Fixes interrupted dpkg installs                                ║
# ║  • Wipes previous conduit containers for a fresh start            ║
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

VERSION="1.8"
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
# 1. DEEP CLEAN & REPAIR SYSTEM
#═══════════════════════════════════════════════════════════════════════

deep_clean_system() {
    log_warn "Starting Deep Clean & System Repair..."

    # 1. Kill stuck package managers
    log_info "Killing stuck apt/dpkg processes..."
    killall apt apt-get dpkg 2>/dev/null || true
    sleep 2

    # 2. Fix APT/DPKG specifics
    if [ "$PKG_MANAGER" = "apt" ]; then
        # Remove lock files if they exist (Risky but necessary for stuck systems)
        rm -f /var/lib/apt/lists/lock 
        rm -f /var/cache/apt/archives/lock
        rm -f /var/lib/dpkg/lock*

        log_info "Repairing dpkg database..."
        dpkg --configure -a || true
        
        log_info "Fixing broken dependencies..."
        apt-get install -f -y || true
        
        log_info "Cleaning apt cache..."
        apt-get clean || true
        apt-get autoremove -y || true
        
        log_info "Updating package lists..."
        apt-get update -q -y >/dev/null 2>&1 || true
    fi

    # 3. Wipe previous Conduit Installation
    log_info "Wiping previous Conduit installation..."
    if command -v docker &>/dev/null; then
        # Stop and remove all conduit containers
        docker stop conduit 2>/dev/null || true
        docker rm conduit 2>/dev/null || true
        # Also remove numbered instances just in case
        docker stop $(docker ps -a -q --filter name=conduit) 2>/dev/null || true
        docker rm $(docker ps -a -q --filter name=conduit) 2>/dev/null || true
        
        # Remove old menu link
        rm -f /usr/local/bin/conduit
    fi
    
    log_success "System cleaned and ready for fresh install."
}

#═══════════════════════════════════════════════════════════════════════
# 2. STANDARD INSTALLATION
#═══════════════════════════════════════════════════════════════════════

install_dependencies() {
    log_info "Installing dependencies..."
    local pkgs="curl gawk tcpdump geoip-bin geoip-database qrencode"
    
    # Simple install loop
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

# Keep the identity if we can, otherwise it's a fresh start
check_restore() {
    [ ! -d "$BACKUP_DIR" ] && return 0
    local backup=$(ls -t "$BACKUP_DIR"/conduit_key_*.json 2>/dev/null | head -1)
    [ -z "$backup" ] && return 0
    
    log_info "Found previous backup. Restoring Identity..."
    docker volume create conduit-data >/dev/null 2>&1 || true
    if docker run --rm -v conduit-data:/data -v "$BACKUP_DIR":/bkp alpine sh -c "cp /bkp/$(basename "$backup") /data/conduit_key.json && chown 1000:1000 /data/conduit_key.json"; then
        log_success "Identity restored."
    fi
}

run_conduit() {
    log_info "Starting Conduit (Fresh Container)..."
    
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
        log_success "Conduit Started Successfully."
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
    
    # Try download, fallback to local
    if curl -sL "https://raw.githubusercontent.com/SamNet-dev/conduit-manager/main/conduit.sh" -o "$menu_path" 2>/dev/null; then
        chmod +x "$menu_path"
    else
        log_warn "Menu download failed. Using minimal menu."
        cat > "$menu_path" << 'EOF'
#!/bin/bash
echo "--- Conduit Fallback Menu ---"
echo "1) Check Status: docker ps -f name=conduit"
echo "2) Restart:      docker restart conduit"
echo "3) Logs:         docker logs --tail 20 conduit"
EOF
        chmod +x "$menu_path"
    fi

    rm -f /usr/local/bin/conduit
    ln -s "$menu_path" /usr/local/bin/conduit
}

#═══════════════════════════════════════════════════════════════════════
# MAIN EXECUTION
#═══════════════════════════════════════════════════════════════════════

detect_os

# STEP 1: FIX EVERYTHING
deep_clean_system

# STEP 2: INSTALL REQUISITES
install_dependencies
install_docker

# STEP 3: RUN APP
check_restore
run_conduit
save_conf
create_menu

echo ""
log_success "FRESH INSTALLATION COMPLETE."
echo "------------------------------------------------"
echo "Opening menu in 3 seconds..."
echo "------------------------------------------------"
sleep 3

if [ -f "/usr/local/bin/conduit" ]; then
    exec /usr/local/bin/conduit menu
fi
