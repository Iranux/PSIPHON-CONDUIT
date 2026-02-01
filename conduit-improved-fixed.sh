#!/bin/bash
#
# ╔═══════════════════════════════════════════════════════════════════╗
# ║      🚀 PSIPHON CONDUIT MANAGER v1.3 - IMPROVED (FIXED)          ║
# ║                                                                   ║
# ║  One-click setup for Psiphon Conduit with Smart Guard            ║
# ║                                                                   ║
# ║  • Hardcoded optimal settings (MAX_CLIENTS=50, BANDWIDTH=10)      ║
# ║  • Nuclear clean before install                                   ║
# ║  • Smart Guard for Iranian IPs (time-based access control)        ║
# ║  • Fallback to direct binary if Docker image blocked              ║
# ║  • Fixed menu flashing issue                                      ║
# ║                                                                   ║
# ║  GitHub: https://github.com/Psiphon-Inc/conduit                   ║
# ╚═══════════════════════════════════════════════════════════════════╝

set -eo pipefail

# Require bash
if [ -z "$BASH_VERSION" ]; then
    echo "Error: This script requires bash. Please run with: bash $0"
    exit 1
fi

VERSION="1.3"
CONDUIT_IMAGE="ghcr.io/ssmirr/conduit/conduit:latest"
INSTALL_DIR="${INSTALL_DIR:-/opt/conduit}"
BACKUP_DIR="$INSTALL_DIR/backups"
FORCE_REINSTALL=false

# ═══════════════════════════════════════════════════════════════════════
# HARDCODED SETTINGS - No more prompts!
# ═══════════════════════════════════════════════════════════════════════
MAX_CLIENTS=50
BANDWIDTH=10

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

#═══════════════════════════════════════════════════════════════════════
# Utility Functions
#═══════════════════════════════════════════════════════════════════════

print_header() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║          🚀 PSIPHON CONDUIT MANAGER v${VERSION} - IMPROVED            ║"
    echo "╠═══════════════════════════════════════════════════════════════════╣"
    echo "║  Help users access the open internet during shutdowns             ║"
    echo "║  + Smart Guard • Nuclear Clean • Optimized Settings               ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

detect_os() {
    OS="unknown"
    OS_VERSION="unknown"
    OS_FAMILY="unknown"
    HAS_SYSTEMD=false
    PKG_MANAGER="unknown"
    
    # Detect OS
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS="$ID"
        OS_VERSION="${VERSION_ID:-unknown}"
    elif [ -f /etc/redhat-release ]; then
        OS="rhel"
    elif [ -f /etc/debian_version ]; then
        OS="debian"
    elif [ -f /etc/alpine-release ]; then
        OS="alpine"
    elif [ -f /etc/arch-release ]; then
        OS="arch"
    elif [ -f /etc/SuSE-release ] || [ -f /etc/SUSE-brand ]; then
        OS="opensuse"
    else
        OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    fi
    
    # Map OS family and package manager
    case "$OS" in
        ubuntu|debian|linuxmint|pop|elementary|zorin|kali|raspbian)
            OS_FAMILY="debian"
            PKG_MANAGER="apt"
            ;;
        rhel|centos|fedora|rocky|almalinux|oracle|amazon|amzn)
            OS_FAMILY="rhel"
            if command -v dnf &>/dev/null; then
                PKG_MANAGER="dnf"
            else
                PKG_MANAGER="yum"
            fi
            ;;
        arch|manjaro|endeavouros|garuda)
            OS_FAMILY="arch"
            PKG_MANAGER="pacman"
            ;;
        opensuse|opensuse-leap|opensuse-tumbleweed|sles)
            OS_FAMILY="suse"
            PKG_MANAGER="zypper"
            ;;
        alpine)
            OS_FAMILY="alpine"
            PKG_MANAGER="apk"
            ;;
        *)
            OS_FAMILY="unknown"
            PKG_MANAGER="unknown"
            ;;
    esac
    
    if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
        HAS_SYSTEMD=true
    fi

    log_info "Detected: $OS ($OS_FAMILY family), Package manager: $PKG_MANAGER"
}

install_package() {
    local package="$1"
    log_info "Installing $package..."
    
    case "$PKG_MANAGER" in
        apt)
            apt-get update -q || log_warn "apt-get update failed, attempting install anyway..."
            if apt-get install -y -q "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        dnf)
            if dnf install -y -q "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        yum)
            if yum install -y -q "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        pacman)
            if pacman -Sy --noconfirm "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        zypper)
            if zypper install -y -n "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        apk)
            if apk add --no-cache "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        *)
            log_warn "Unknown package manager. Please install $package manually."
            return 1
            ;;
    esac
}

check_dependencies() {
    if [ "$OS_FAMILY" = "alpine" ]; then
        if ! command -v bash &>/dev/null; then
            log_info "Installing bash..."
            apk add --no-cache bash 2>/dev/null
        fi
    fi
    
    if ! command -v curl &>/dev/null; then
        install_package curl || log_warn "Could not install curl automatically"
    fi
    
    if ! command -v awk &>/dev/null; then
        case "$PKG_MANAGER" in
            apt) install_package gawk || log_warn "Could not install gawk" ;;
            apk) install_package gawk || log_warn "Could not install gawk" ;;
            *) install_package awk || log_warn "Could not install awk" ;;
        esac
    fi
    
    if ! command -v jq &>/dev/null; then
        install_package jq || log_warn "Could not install jq (optional)"
    fi
}

#═══════════════════════════════════════════════════════════════════════
# NUCLEAR CLEAN FUNCTION
#═══════════════════════════════════════════════════════════════════════

nuclear_clean() {
    log_warn "Starting nuclear clean - removing all previous Conduit installations..."
    
    # Stop and remove all conduit containers
    log_info "Removing conduit containers..."
    docker stop conduit 2>/dev/null || true
    docker rm -f conduit 2>/dev/null || true
    for i in {2..10}; do
        docker stop "conduit-${i}" 2>/dev/null || true
        docker rm -f "conduit-${i}" 2>/dev/null || true
    done
    
    # Remove docker image
    docker rmi "$CONDUIT_IMAGE" 2>/dev/null || true
    docker rmi conduit-local:latest 2>/dev/null || true
    
    # Stop and disable services
    log_info "Removing system services..."
    if command -v systemctl &>/dev/null; then
        systemctl stop conduit.service 2>/dev/null || true
        systemctl stop conduit-smart-guard.service 2>/dev/null || true
        systemctl stop conduit-telegram.service 2>/dev/null || true
        systemctl disable conduit.service 2>/dev/null || true
        systemctl disable conduit-smart-guard.service 2>/dev/null || true
        systemctl disable conduit-smart-guard.timer 2>/dev/null || true
        systemctl disable conduit-telegram.service 2>/dev/null || true
        rm -f /etc/systemd/system/conduit.service
        rm -f /etc/systemd/system/conduit-smart-guard.service
        rm -f /etc/systemd/system/conduit-telegram.service
        rm -f /etc/systemd/system/conduit-smart-guard.timer
        systemctl daemon-reload 2>/dev/null || true
        systemctl reset-failed 2>/dev/null || true
    fi
    
    # OpenRC / SysVinit
    rc-service conduit stop 2>/dev/null || true
    rc-update del conduit 2>/dev/null || true
    service conduit stop 2>/dev/null || true
    update-rc.d conduit remove 2>/dev/null || true
    chkconfig conduit off 2>/dev/null || true
    rm -f /etc/init.d/conduit
    
    # Remove configuration files
    log_info "Removing configuration files..."
    rm -rf "$INSTALL_DIR" 2>/dev/null || true
    rm -f /usr/local/bin/conduit 2>/dev/null || true
    
    # Clean iptables rules for smart guard
    log_info "Cleaning firewall rules..."
    iptables -D INPUT -m set --match-set iran_ips src -j ACCEPT 2>/dev/null || true
    iptables -D INPUT -p tcp --dport 8080 -m conntrack --ctstate NEW -j REJECT 2>/dev/null || true
    iptables -D INPUT -p tcp --dport 8080 -m conntrack --ctstate NEW -m recent --name conduit_limit --set 2>/dev/null || true
    iptables -D INPUT -p tcp --dport 8080 -m conntrack --ctstate NEW -m recent --name conduit_limit --update --seconds 300 --hitcount 1 -j REJECT 2>/dev/null || true
    ipset destroy iran_ips 2>/dev/null || true
    
    log_success "Nuclear clean completed!"
    echo ""
}

#═══════════════════════════════════════════════════════════════════════
# SMART GUARD SETUP
#═══════════════════════════════════════════════════════════════════════

setup_smart_guard() {
    log_info "Setting up Smart Guard for Iranian IP protection..."
    
    # Install ipset if not available
    if ! command -v ipset &>/dev/null; then
        case "$PKG_MANAGER" in
            apt) install_package ipset ;;
            dnf|yum) install_package ipset ;;
            *) log_warn "Please install ipset manually" ; return 1 ;;
        esac
    fi
    
    # Create smart guard script
    cat > "$INSTALL_DIR/smart-guard.sh" << 'GUARDEOF'
#!/bin/bash

IRAN_IPS_URL="https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4/ir.cidr"
INSTALL_TIME_FILE="/opt/conduit/install_time"
LOG_FILE="/var/log/conduit-smart-guard.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Download Iran IP list
download_iran_ips() {
    log "Downloading Iran IP list..."
    curl -sL "$IRAN_IPS_URL" -o /tmp/iran_ips.txt 2>/dev/null
    if [ $? -eq 0 ] && [ -s /tmp/iran_ips.txt ]; then
        log "Successfully downloaded Iran IP list"
        return 0
    else
        log "ERROR: Failed to download Iran IP list"
        return 1
    fi
}

# Create ipset and add Iranian IPs
setup_ipset() {
    log "Setting up ipset for Iranian IPs..."
    
    # Create ipset if it doesn't exist
    ipset create iran_ips hash:net 2>/dev/null || ipset flush iran_ips
    
    # Add IPs from downloaded list
    while IFS= read -r ip; do
        [ -z "$ip" ] && continue
        ipset add iran_ips "$ip" 2>/dev/null
    done < /tmp/iran_ips.txt
    
    local count=$(ipset list iran_ips 2>/dev/null | grep -c '^[0-9]' || echo "0")
    log "Added $count Iranian IP ranges to ipset"
}

# Apply time-based access control
apply_access_control() {
    # Record install time if not exists
    if [ ! -f "$INSTALL_TIME_FILE" ]; then
        date +%s > "$INSTALL_TIME_FILE"
        log "Install time recorded"
    fi
    
    INSTALL_TIME=$(cat "$INSTALL_TIME_FILE")
    CURRENT_TIME=$(date +%s)
    TIME_DIFF=$((CURRENT_TIME - INSTALL_TIME))
    TWELVE_HOURS=$((12 * 3600))
    
    log "Time since install: $((TIME_DIFF / 3600)) hours"
    
    # Clear existing rules
    iptables -D INPUT -m set --match-set iran_ips src -j ACCEPT 2>/dev/null || true
    iptables -D INPUT -p tcp --dport 8080 -m conntrack --ctstate NEW -m recent --name conduit_limit --set 2>/dev/null || true
    iptables -D INPUT -p tcp --dport 8080 -m conntrack --ctstate NEW -m recent --name conduit_limit --update --seconds 300 --hitcount 1 -j REJECT 2>/dev/null || true
    
    if [ $TIME_DIFF -lt $TWELVE_HOURS ]; then
        # First 12 hours: Allow all
        log "STATUS: First 12 hours - All IPs have unlimited access"
    else
        # After 12 hours: Limit non-Iranian IPs to 5 minutes
        iptables -I INPUT -m set --match-set iran_ips src -j ACCEPT
        iptables -A INPUT -p tcp --dport 8080 -m conntrack --ctstate NEW -m recent --name conduit_limit --set
        iptables -A INPUT -p tcp --dport 8080 -m conntrack --ctstate NEW -m recent --name conduit_limit --update --seconds 300 --hitcount 1 ! -m set --match-set iran_ips src -j REJECT
        log "STATUS: After 12 hours - Non-Iranian IPs limited to 5 minutes"
    fi
}

# Main execution
main() {
    log "=== Smart Guard Check Starting ==="
    
    if download_iran_ips; then
        setup_ipset
        apply_access_control
        log "=== Smart Guard Check Completed ==="
    else
        log "=== Smart Guard Check Failed ==="
        exit 1
    fi
}

main
GUARDEOF
    
    chmod +x "$INSTALL_DIR/smart-guard.sh"
    
    # Create systemd service and timer for smart guard
    if [ "$HAS_SYSTEMD" = true ]; then
        cat > /etc/systemd/system/conduit-smart-guard.service << 'SVCEOF'
[Unit]
Description=Conduit Smart Guard
After=network.target

[Service]
Type=oneshot
ExecStart=/opt/conduit/smart-guard.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

        cat > /etc/systemd/system/conduit-smart-guard.timer << 'TIMEREOF'
[Unit]
Description=Conduit Smart Guard Timer
After=network.target

[Timer]
OnBootSec=2min
OnUnitActiveSec=1h

[Install]
WantedBy=timers.target
TIMEREOF
        
        systemctl daemon-reload
        systemctl enable conduit-smart-guard.timer
        systemctl start conduit-smart-guard.timer
        
        # Run once immediately
        systemctl start conduit-smart-guard.service 2>/dev/null || true
        
        log_success "Smart Guard enabled - will check every hour and on boot"
    else
        # For non-systemd systems, add to crontab
        (crontab -l 2>/dev/null || true; echo "@reboot $INSTALL_DIR/smart-guard.sh") | crontab -
        (crontab -l 2>/dev/null || true; echo "0 * * * * $INSTALL_DIR/smart-guard.sh") | crontab -
        
        # Run once immediately
        "$INSTALL_DIR/smart-guard.sh" 2>/dev/null || true
        
        log_success "Smart Guard enabled via cron (hourly checks)"
    fi
}

#═══════════════════════════════════════════════════════════════════════
# Docker Installation
#═══════════════════════════════════════════════════════════════════════

install_docker() {
    if command -v docker &>/dev/null; then
        log_success "Docker is already installed"
        return 0
    fi
    
    log_info "Installing Docker..."
    
    case "$OS_FAMILY" in
        debian)
            apt-get update -q
            apt-get install -y -q ca-certificates curl gnupg lsb-release
            mkdir -p /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/$OS/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null || true
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
            apt-get update -q
            apt-get install -y -q docker-ce docker-ce-cli containerd.io
            ;;
        rhel)
            if [ "$PKG_MANAGER" = "dnf" ]; then
                dnf -y install dnf-plugins-core
                dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
                dnf install -y docker-ce docker-ce-cli containerd.io
            else
                yum install -y yum-utils
                yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
                yum install -y docker-ce docker-ce-cli containerd.io
            fi
            ;;
        arch)
            pacman -Sy --noconfirm docker
            ;;
        alpine)
            apk add --no-cache docker
            rc-update add docker boot
            ;;
        *)
            log_error "Unsupported OS for automatic Docker installation"
            log_info "Please install Docker manually: https://docs.docker.com/engine/install/"
            exit 1
            ;;
    esac
    
    # Start Docker
    if command -v systemctl &>/dev/null; then
        systemctl start docker
        systemctl enable docker
    elif command -v rc-service &>/dev/null; then
        rc-service docker start
    else
        service docker start 2>/dev/null || true
    fi
    
    log_success "Docker installed and started"
}

#═══════════════════════════════════════════════════════════════════════
# Run Conduit with Fallback
#═══════════════════════════════════════════════════════════════════════

run_conduit() {
    mkdir -p "$INSTALL_DIR/data"
    
    log_info "Attempting to pull Docker image..."
    
    # Try to pull the official image
    if timeout 30 docker pull "$CONDUIT_IMAGE" 2>/dev/null; then
        log_success "Successfully pulled Docker image"
        USE_FALLBACK=false
        FINAL_IMAGE="$CONDUIT_IMAGE"
    else
        log_warn "Cannot pull official Docker image (may be blocked)"
        log_info "Switching to fallback mode: direct binary download"
        USE_FALLBACK=true
        
        # Download conduit binary directly
        CONDUIT_BINARY_URL="https://github.com/Psiphon-Labs/psiphon-tunnel-core/releases/latest/download/conduit-linux-amd64"
        
        log_info "Downloading conduit binary..."
        if curl -L "$CONDUIT_BINARY_URL" -o "$INSTALL_DIR/conduit-binary" 2>/dev/null; then
            chmod +x "$INSTALL_DIR/conduit-binary"
            log_success "Binary downloaded successfully"
            
            # Create a minimal Dockerfile
            cat > "$INSTALL_DIR/Dockerfile" << 'DOCKEREOF'
FROM alpine:latest
RUN apk add --no-cache ca-certificates
COPY conduit-binary /usr/local/bin/conduit
ENTRYPOINT ["/usr/local/bin/conduit"]
DOCKEREOF
            
            # Build local image
            log_info "Building local Docker image..."
            if docker build -t conduit-local:latest "$INSTALL_DIR/" 2>/dev/null; then
                FINAL_IMAGE="conduit-local:latest"
                log_success "Local image built successfully"
            else
                log_error "Failed to build local image"
                exit 1
            fi
        else
            log_error "Failed to download binary"
            exit 1
        fi
    fi
    
    # Run the container
    log_info "Starting Conduit container with MAX_CLIENTS=$MAX_CLIENTS, BANDWIDTH=$BANDWIDTH..."
    
    if docker run -d \
        --name conduit \
        --restart unless-stopped \
        -p 8080:8080 \
        -v "$INSTALL_DIR/data:/data" \
        "$FINAL_IMAGE" \
        --max-clients "$MAX_CLIENTS" \
        --bandwidth "$BANDWIDTH" 2>/dev/null; then
        
        sleep 3
        
        if docker ps | grep -q conduit; then
            log_success "Conduit is running!"
        else
            log_error "Conduit failed to start"
            docker logs conduit 2>/dev/null || true
            exit 1
        fi
    else
        log_error "Failed to start Conduit container"
        exit 1
    fi
}

#═══════════════════════════════════════════════════════════════════════
# Save Settings
#═══════════════════════════════════════════════════════════════════════

save_settings_install() {
    mkdir -p "$INSTALL_DIR"
    cat > "$INSTALL_DIR/settings.conf" << EOF
MAX_CLIENTS=$MAX_CLIENTS
BANDWIDTH=$BANDWIDTH
INSTALL_DIR=$INSTALL_DIR
VERSION=$VERSION
CONDUIT_IMAGE=$FINAL_IMAGE
EOF
    
    # Record install time for smart guard
    date +%s > "$INSTALL_DIR/install_time"
    
    log_success "Settings saved"
}

#═══════════════════════════════════════════════════════════════════════
# Create Management Script - MUST BE CREATED BEFORE SYSTEMD SERVICE
#═══════════════════════════════════════════════════════════════════════

create_management_script() {
    log_info "Creating management script..."
    
    cat > "$INSTALL_DIR/conduit" << 'MGMTEOF'
#!/bin/bash

INSTALL_DIR="/opt/conduit"
[ -f "$INSTALL_DIR/settings.conf" ] && source "$INSTALL_DIR/settings.conf"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

show_status() {
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                   📊 CONDUIT STATUS                               ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    if docker ps 2>/dev/null | grep -q conduit; then
        echo -e "${GREEN}Status: Running ✓${NC}"
        echo ""
        echo "Container Details:"
        docker ps --filter "name=conduit" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        echo ""
        echo "Settings:"
        echo "  Max Clients: ${MAX_CLIENTS:-50}"
        echo "  Bandwidth: ${BANDWIDTH:-10} Mbps per client"
        echo "  Image: ${CONDUIT_IMAGE:-conduit-local:latest}"
        echo ""
    else
        echo -e "${RED}Status: Stopped ✗${NC}"
    fi
}

show_logs() {
    echo -e "${CYAN}Recent logs (press Ctrl+C to exit):${NC}"
    docker logs -f --tail 50 conduit 2>/dev/null || echo "No logs available"
}

show_smart_guard_status() {
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                   🛡️ SMART GUARD STATUS                           ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    if [ -f "$INSTALL_DIR/install_time" ]; then
        INSTALL_TIME=$(cat "$INSTALL_DIR/install_time")
        CURRENT_TIME=$(date +%s)
        TIME_DIFF=$((CURRENT_TIME - INSTALL_TIME))
        HOURS=$((TIME_DIFF / 3600))
        
        echo "Time since installation: $HOURS hours"
        echo ""
        
        if [ $TIME_DIFF -lt $((12 * 3600)) ]; then
            REMAINING=$((12 - HOURS))
            echo -e "${GREEN}Mode: Grace Period (Unlimited Access)${NC}"
            echo "Remaining: $REMAINING hours until restrictions activate"
        else
            echo -e "${YELLOW}Mode: Protected (5-minute limit for non-Iranian IPs)${NC}"
            echo "Iranian IPs: Unlimited access"
            echo "Other IPs: Limited to 5 minutes per connection"
        fi
        echo ""
        
        # Show ipset stats
        if command -v ipset &>/dev/null; then
            IRAN_IP_COUNT=$(ipset list iran_ips 2>/dev/null | grep -c '^[0-9]' || echo "0")
            echo "Protected IP ranges: $IRAN_IP_COUNT Iranian networks"
        fi
        echo ""
        
        # Show recent log
        if [ -f /var/log/conduit-smart-guard.log ]; then
            echo "Recent Smart Guard Activity:"
            tail -5 /var/log/conduit-smart-guard.log
        fi
    else
        echo -e "${RED}Smart Guard not initialized${NC}"
    fi
    
    echo ""
    read -p "Press Enter to continue..." < /dev/tty
}

start_conduit() {
    if docker ps 2>/dev/null | grep -q conduit; then
        echo -e "${YELLOW}Conduit is already running${NC}"
    else
        echo "Starting Conduit..."
        if docker start conduit 2>/dev/null; then
            sleep 2
            if docker ps | grep -q conduit; then
                echo -e "${GREEN}Conduit started successfully${NC}"
            else
                echo -e "${RED}Failed to start Conduit${NC}"
            fi
        else
            echo -e "${RED}Failed to start. Container may not exist.${NC}"
        fi
    fi
}

stop_conduit() {
    echo "Stopping Conduit..."
    docker stop conduit 2>/dev/null || true
    echo -e "${GREEN}Conduit stopped${NC}"
}

restart_conduit() {
    stop_conduit
    sleep 2
    start_conduit
}

show_menu() {
    while true; do
        clear
        echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║              🚀 CONDUIT MANAGEMENT MENU v1.3                      ║${NC}"
        echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo "  1. 📊 Show Status"
        echo "  2. 📋 Show Logs"
        echo "  3. ▶️  Start Conduit"
        echo "  4. ⏸️  Stop Conduit"
        echo "  5. 🔄 Restart Conduit"
        echo "  6. 🛡️  Smart Guard Status"
        echo "  0. 🚪 Exit"
        echo ""
        read -p "  Enter choice: " choice < /dev/tty
        echo ""
        
        case "$choice" in
            1) show_status ; read -p "Press Enter to continue..." < /dev/tty ;;
            2) show_logs ;;
            3) start_conduit ; read -p "Press Enter to continue..." < /dev/tty ;;
            4) stop_conduit ; read -p "Press Enter to continue..." < /dev/tty ;;
            5) restart_conduit ; read -p "Press Enter to continue..." < /dev/tty ;;
            6) show_smart_guard_status ;;
            0) exit 0 ;;
            *) echo -e "${RED}Invalid choice${NC}" ; sleep 1 ;;
        esac
    done
}

case "${1:-menu}" in
    status) show_status ;;
    logs) show_logs ;;
    start) start_conduit ;;
    stop) stop_conduit ;;
    restart) restart_conduit ;;
    smart-guard) show_smart_guard_status ;;
    menu) show_menu ;;
    *) 
        echo "Usage: conduit {status|logs|start|stop|restart|smart-guard|menu}"
        exit 1
        ;;
esac
MGMTEOF
    
    chmod +x "$INSTALL_DIR/conduit"
    ln -sf "$INSTALL_DIR/conduit" /usr/local/bin/conduit
    
    log_success "Management script created"
}

#═══════════════════════════════════════════════════════════════════════
# Setup Auto-start - MUST BE CALLED AFTER create_management_script
#═══════════════════════════════════════════════════════════════════════

setup_autostart() {
    log_info "Setting up auto-start service..."
    
    if [ "$HAS_SYSTEMD" = true ]; then
        cat > /etc/systemd/system/conduit.service << 'SVCEOF'
[Unit]
Description=Psiphon Conduit Service
After=network.target docker.service
Wants=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/conduit start
ExecStop=/usr/local/bin/conduit stop

[Install]
WantedBy=multi-user.target
SVCEOF
        
        systemctl daemon-reload
        systemctl enable conduit.service 2>/dev/null || true
        
        # Don't start the service yet - container is already running
        log_success "Auto-start service configured (systemd)"
    else
        # For systems without systemd
        cat > /etc/init.d/conduit << 'INITEOF'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          conduit
# Required-Start:    $remote_fs $syslog docker
# Required-Stop:     $remote_fs $syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Psiphon Conduit
### END INIT INFO

case "$1" in
    start)
        /usr/local/bin/conduit start
        ;;
    stop)
        /usr/local/bin/conduit stop
        ;;
    restart)
        /usr/local/bin/conduit restart
        ;;
    *)
        echo "Usage: $0 {start|stop|restart}"
        exit 1
        ;;
esac
INITEOF
        
        chmod +x /etc/init.d/conduit
        
        if command -v rc-update &>/dev/null; then
            rc-update add conduit
        elif command -v update-rc.d &>/dev/null; then
            update-rc.d conduit defaults
        elif command -v chkconfig &>/dev/null; then
            chkconfig --add conduit
        fi
        
        log_success "Auto-start enabled (init.d)"
    fi
}

#═══════════════════════════════════════════════════════════════════════
# Print Summary
#═══════════════════════════════════════════════════════════════════════

print_summary() {
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    ✅ INSTALLATION COMPLETE!                      ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}📊 Configuration:${NC}"
    echo "  • Max Clients: $MAX_CLIENTS"
    echo "  • Bandwidth: $BANDWIDTH Mbps per client"
    echo "  • Port: 8080"
    echo "  • Smart Guard: Enabled ✓"
    echo "  • Image: $FINAL_IMAGE"
    echo ""
    
    # Get server IP
    SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || echo "YOUR_SERVER_IP")
    
    echo -e "${CYAN}🌐 Access Information:${NC}"
    echo "  Share this with users in Iran:"
    echo -e "  ${BOLD}${GREEN}$SERVER_IP:8080${NC}"
    echo ""
    
    echo -e "${CYAN}🎮 Quick Commands:${NC}"
    echo "  conduit menu       - Open management menu"
    echo "  conduit status     - Show current status"
    echo "  conduit logs       - View live logs"
    echo "  conduit smart-guard - Check Smart Guard status"
    echo ""
    echo -e "${CYAN}🛡️ Smart Guard Info:${NC}"
    echo "  • First 12 hours: Unlimited access for all"
    echo "  • After 12 hours: 5-minute limit for non-Iranian IPs"
    echo "  • Iranian IPs: Always unlimited access"
    echo ""
}

#═══════════════════════════════════════════════════════════════════════
# Uninstall
#═══════════════════════════════════════════════════════════════════════

uninstall() {
    echo -e "${RED}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                    ⚠️  UNINSTALL CONDUIT                          ║${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    read -p "Are you sure you want to uninstall? [y/N] " confirm < /dev/tty
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Uninstall cancelled."
        exit 0
    fi
    
    nuclear_clean
    
    echo ""
    echo -e "${GREEN}Uninstall complete!${NC}"
    echo ""
}

#═══════════════════════════════════════════════════════════════════════
# Main
#═══════════════════════════════════════════════════════════════════════

show_usage() {
    echo "Psiphon Conduit Manager v${VERSION} - Improved Edition"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  (no args)      Install or open management menu if already installed"
    echo "  --reinstall    Force fresh reinstall with nuclear clean"
    echo "  --uninstall    Completely remove Conduit and all components"
    echo "  --help, -h     Show this help message"
    echo ""
    echo "Features:"
    echo "  • Hardcoded optimal settings (MAX_CLIENTS=50, BANDWIDTH=10)"
    echo "  • Nuclear clean before install"
    echo "  • Smart Guard for Iranian IP protection"
    echo "  • Automatic fallback if Docker image is blocked"
    echo ""
}

main() {
    case "${1:-}" in
        --uninstall|-u)
            check_root
            uninstall
            exit 0
            ;;
        --help|-h)
            show_usage
            exit 0
            ;;
        --reinstall)
            FORCE_REINSTALL=true
            ;;
    esac
    
    print_header
    check_root
    detect_os
    check_dependencies
    
    # Check if already installed
    if [ -f "$INSTALL_DIR/conduit" ] && [ "$FORCE_REINSTALL" != "true" ]; then
        echo -e "${GREEN}Conduit is already installed!${NC}"
        echo ""
        echo "What would you like to do?"
        echo ""
        echo "  1. 📊 Open management menu"
        echo "  2. 🔄 Reinstall (with nuclear clean)"
        echo "  3. 🗑️  Uninstall"
        echo "  0. 🚪 Exit"
        echo ""
        read -p "  Enter choice: " choice < /dev/tty
        
        case "$choice" in
            1)
                exec "$INSTALL_DIR/conduit" menu
                ;;
            2)
                log_info "Starting fresh reinstall with nuclear clean..."
                # Continue to installation
                ;;
            3)
                uninstall
                exit 0
                ;;
            0)
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid choice${NC}"
                exit 1
                ;;
        esac
    fi
    
    # NUCLEAR CLEAN - Always run before installation
    nuclear_clean
    
    echo -e "${CYAN}Starting installation with optimized settings...${NC}"
    echo -e "${CYAN}MAX_CLIENTS=$MAX_CLIENTS | BANDWIDTH=$BANDWIDTH Mbps${NC}"
    echo ""
    
    # Installation Steps - FIXED ORDER!
    log_info "Step 1/5: Installing Docker..."
    install_docker
    echo ""
    
    log_info "Step 2/5: Starting Conduit container..."
    run_conduit
    echo ""
    
    log_info "Step 3/5: Saving settings..."
    save_settings_install
    echo ""
    
    log_info "Step 4/5: Creating management script..."
    create_management_script
    echo ""
    
    log_info "Step 5/5: Setting up auto-start and Smart Guard..."
    setup_autostart
    setup_smart_guard
    echo ""
    
    print_summary
    
    read -p "Open management menu now? [Y/n] " open_menu < /dev/tty
    if [[ ! "$open_menu" =~ ^[Nn]$ ]]; then
        "$INSTALL_DIR/conduit" menu
    fi
}

main "$@"
