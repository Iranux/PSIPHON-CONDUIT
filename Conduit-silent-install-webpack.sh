#!/bin/bash
#
# ╔═══════════════════════════════════════════════════════════════════╗
# ║   🚀 PSIPHON CONDUIT MANAGER v1.6 (FINAL STABLE)                 ║
# ║                                                                   ║
# ║  Settings: 50 Clients / 5 Mbps / 1 Container                      ║
# ║  Fixes: Auto-Root, Silent Apt, Menu Fallback                      ║
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
# ----------------------------

# Stop apt from asking questions
export DEBIAN_FRONTEND=noninteractive

# Exit on critical errors only
set -e

VERSION="1.6"
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

perform_system_update() {
    log_info "Updating package lists..."
    case "$PKG_MANAGER" in
        apt) apt-get update -q -y >/dev/null 2>&1 || true ;;
        dnf|yum) dnf check-update >/dev/null 2>&1 || true ;;
        apk) apk update >/dev/null 2>&1 || true ;;
    esac
}

install_package() {
    local pkg="$1"
    local flags="-y -q"
    [ "$PKG_MANAGER" = "apt" ] && flags="$flags -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
    
    case "$PKG_MANAGER" in
        apt) apt-get install $flags "$pkg" >/dev/null 2>&1 || true ;;
        dnf|yum) dnf install -y -q "$pkg" >/dev/null 2>&1 || true ;;
        apk) apk add --no-cache "$pkg" >/dev/null 2>&1 || true ;;
    esac
}

check_dependencies() {
    log_info "Installing dependencies..."
    if ! command -v curl &>/dev/null; then install_package curl; fi
    if ! command -v awk &>/dev/null; then install_package gawk; fi
    # Try to install extras but don't fail if they miss
    install_package tcpdump
    install_package qrencode
}

#═══════════════════════════════════════════════════════════════════════
# Core Logic
#═══════════════════════════════════════════════════════════════════════

install_docker() {
    if command -v docker &>/dev/null; then
        log_success "Docker already installed"
        return 0
    fi
    log_info "Installing Docker..."
    if [ "$PKG_MANAGER" = "alpine" ]; then
        apk add --no-cache docker docker-cli-compose || true
        service docker start || true
    else
        if ! curl -fsSL https://get.docker.com | sh >/dev/null 2>&1; then
             log_warn "Docker script failed, trying package manager..."
             install_package docker.io
             install_package docker-ce
        fi
        systemctl enable docker >/dev/null 2>&1 || true
        systemctl start docker >/dev/null 2>&1 || true
    fi
}

check_restore() {
    [ ! -d "$BACKUP_DIR" ] && return 0
    local backup=$(ls -t "$BACKUP_DIR"/conduit_key_*.json 2>/dev/null | head -1)
    [ -z "$backup" ] && return 0
    
    log_info "Restoring backup: $(basename "$backup")"
    docker volume create conduit-data >/dev/null 2>&1 || true
    # Use a temp container to copy file
    if docker run --rm -v conduit-data:/data -v "$BACKUP_DIR":/bkp alpine sh -c "cp /bkp/$(basename "$backup") /data/conduit_key.json && chown 1000:1000 /data/conduit_key.json"; then
        log_success "Identity restored."
    fi
}

run_conduit() {
    log_info "Starting Conduit (50 clients, 5Mbps)..."
    docker stop conduit >/dev/null 2>&1 || true
    docker rm conduit >/dev/null 2>&1 || true
    
    # Ensure volume
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
        log_success "Container started."
    else
        log_error "Failed to start container."
        exit 1
    fi
}

save_conf() {
    mkdir -p "$INSTALL_DIR"
    # Create simple config
    echo "MAX_CLIENTS=50" > "$INSTALL_DIR/settings.conf"
    echo "BANDWIDTH=5" >> "$INSTALL_DIR/settings.conf"
    echo "CONTAINER_COUNT=1" >> "$INSTALL_DIR/settings.conf"
}

create_menu() {
    log_info "Installing management menu..."
    local menu_path="$INSTALL_DIR/conduit"
    
    # 1. Try to download official manager
    # Added '|| true' so script DOES NOT EXIT if curl fails
    if curl -sL "https://raw.githubusercontent.com/SamNet-dev/conduit-manager/main/conduit.sh" -o "$menu_path" 2>/dev/null; then
        chmod +x "$menu_path"
        log_success "Downloaded official manager."
    else
        log_warn "Download failed. Creating local fallback menu."
        # 2. Create Fallback Menu if download fails
        cat > "$menu_path" << 'EOF'
#!/bin/bash
echo "--- Conduit Fallback Menu ---"
echo "1) Status"
echo "2) Stop"
echo "3) Start"
echo "4) Logs"
read -p "Select: " opt
case $opt in
    1) docker ps -f name=conduit ;;
    2) docker stop conduit ;;
    3) docker start conduit ;;
    4) docker logs --tail 50 -f conduit ;;
    *) echo "Invalid option" ;;
esac
EOF
        chmod +x "$menu_path"
    fi

    # Symlink
    rm -f /usr/local/bin/conduit
    ln -s "$menu_path" /usr/local/bin/conduit
}

#═══════════════════════════════════════════════════════════════════════
# MAIN
#═══════════════════════════════════════════════════════════════════════

detect_os
perform_system_update
check_dependencies

install_docker
check_restore
run_conduit
save_conf
create_menu

echo ""
log_success "INSTALLATION FINISHED."
echo "------------------------------------------------"
echo "Access menu anytime by typing: conduit"
echo "------------------------------------------------"
echo "Launching menu now..."
sleep 2

# Force open menu
if [ -f "/usr/local/bin/conduit" ]; then
    exec /usr/local/bin/conduit menu
else
    echo "Menu script missing. Try running: docker ps"
fi
