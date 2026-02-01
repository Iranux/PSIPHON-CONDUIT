#!/bin/bash
#
# ╔═══════════════════════════════════════════════════════════════════╗
# ║   🚀 PSIPHON CONDUIT MANAGER v1.4 (SILENT + AUTO ROOT + UPDATE)  ║
# ║                                                                   ║
# ║  Customized for: 50 Clients / 5 Mbps / 1 Container                ║
# ╚═══════════════════════════════════════════════════════════════════╝
#

# --- AUTO ELEVATE TO ROOT ---
# If script is run as normal user, restart it with sudo automatically
if [ "$EUID" -ne 0 ]; then
    echo "Requesting root privileges..."
    exec sudo bash "$0" "$@"
fi
# ----------------------------

set -eo pipefail

VERSION="1.4"
CONDUIT_IMAGE="ghcr.io/ssmirr/conduit/conduit:latest"
INSTALL_DIR="${INSTALL_DIR:-/opt/conduit}"
BACKUP_DIR="$INSTALL_DIR/backups"
FORCE_REINSTALL=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

#═══════════════════════════════════════════════════════════════════════
# Utility Functions
#═══════════════════════════════════════════════════════════════════════

print_header() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║          🚀 PSIPHON CONDUIT MANAGER (AUTO INSTALL)             ║"
    echo "╠═══════════════════════════════════════════════════════════════════╣"
    echo "║  Settings: 50 Clients | 5 Mbps | 1 Container                      ║"
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

detect_os() {
    OS="unknown"
    OS_FAMILY="unknown"
    HAS_SYSTEMD=false
    PKG_MANAGER="unknown"
    
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS="$ID"
    else
        OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    fi
    
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

# --- AUTO UPDATE SYSTEM ---
perform_system_update() {
    log_info "Running system update ($PKG_MANAGER update)..."
    case "$PKG_MANAGER" in
        apt)
            apt-get update -q -y >/dev/null 2>&1 || true
            ;;
        dnf)
            dnf check-update >/dev/null 2>&1 || true
            ;;
        yum)
            yum check-update >/dev/null 2>&1 || true
            ;;
        apk)
            apk update >/dev/null 2>&1 || true
            ;;
        pacman)
            pacman -Sy --noconfirm >/dev/null 2>&1 || true
            ;;
        zypper)
            zypper refresh >/dev/null 2>&1 || true
            ;;
    esac
    log_success "System package list updated."
}

install_package() {
    local package="$1"
    case "$PKG_MANAGER" in
        apt)
            apt-get install -y -q "$package" >/dev/null 2>&1
            ;;
        dnf)
            dnf install -y -q "$package" >/dev/null 2>&1
            ;;
        yum)
            yum install -y -q "$package" >/dev/null 2>&1
            ;;
        pacman)
            pacman -Sy --noconfirm "$package" >/dev/null 2>&1
            ;;
        zypper)
            zypper install -y -n "$package" >/dev/null 2>&1
            ;;
        apk)
            apk add --no-cache "$package" >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

check_dependencies() {
    if [ "$OS_FAMILY" = "alpine" ]; then
        if ! command -v bash &>/dev/null; then
            apk add --no-cache bash 2>/dev/null
        fi
    fi
    
    if ! command -v curl &>/dev/null; then
        install_package curl
    fi
    
    if ! command -v awk &>/dev/null; then
        case "$PKG_MANAGER" in
            apt) install_package gawk ;;
            apk) install_package gawk ;;
            *) install_package awk ;;
        esac
    fi
    
    if ! command -v tcpdump &>/dev/null; then
        install_package tcpdump
    fi

    if ! command -v geoiplookup &>/dev/null && ! command -v mmdblookup &>/dev/null; then
        case "$PKG_MANAGER" in
            apt)
                install_package geoip-bin
                install_package geoip-database
                ;;
            dnf|yum)
                if ! rpm -q epel-release &>/dev/null; then
                    $PKG_MANAGER install -y epel-release &>/dev/null || true
                fi
                install_package GeoIP 2>/dev/null || install_package libmaxminddb
                ;;
            apk) install_package geoip ;;
        esac
    fi
    
    if ! command -v qrencode &>/dev/null; then
        install_package qrencode
    fi
}

#═══════════════════════════════════════════════════════════════════════
# HARDCODED SETTINGS (NO PROMPT)
#═══════════════════════════════════════════════════════════════════════

prompt_settings() {
    echo -e "${CYAN}--- Configuring Settings (Silent Mode) ---${NC}"
    
    # --- USER DEFINED VALUES ---
    MAX_CLIENTS=50
    BANDWIDTH=5
    CONTAINER_COUNT=1
    # ---------------------------

    echo -e "  Max Clients: ${GREEN}${MAX_CLIENTS}${NC}"
    echo -e "  Bandwidth:   ${GREEN}${BANDWIDTH}${NC} Mbps"
    echo -e "  Containers:  ${GREEN}${CONTAINER_COUNT}${NC}"
    echo ""
}

#═══════════════════════════════════════════════════════════════════════
# Installation Functions
#═══════════════════════════════════════════════════════════════════════

install_docker() {
    if command -v docker &>/dev/null; then
        log_success "Docker is already installed"
        return 0
    fi
    
    log_info "Installing Docker..."
    
    if [ "$OS_FAMILY" = "rhel" ]; then
        $PKG_MANAGER install -y -q dnf-plugins-core 2>/dev/null || true
        dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null || true
    fi

    if [ "$OS_FAMILY" = "alpine" ]; then
        apk add --no-cache docker docker-cli-compose 2>/dev/null
        rc-update add docker boot 2>/dev/null || true
        service docker start 2>/dev/null || rc-service docker start 2>/dev/null || true
    else
        if ! curl -fsSL https://get.docker.com | sh >/dev/null 2>&1; then
            log_error "Official Docker installation script failed."
            return 1
        fi
        
        if [ "$HAS_SYSTEMD" = "true" ]; then
            systemctl enable docker 2>/dev/null || true
            systemctl start docker 2>/dev/null || true
        else
            service docker start 2>/dev/null || /etc/init.d/docker start 2>/dev/null || true
        fi
    fi
    
    sleep 3
    if docker info &>/dev/null; then
        log_success "Docker installed successfully"
    else
        log_error "Docker installation may have failed."
        return 1
    fi
}

check_and_offer_backup_restore() {
    if [ ! -d "$BACKUP_DIR" ]; then
        return 0
    fi

    local latest_backup=$(ls -t "$BACKUP_DIR"/conduit_key_*.json 2>/dev/null | head -1)

    if [ -z "$latest_backup" ]; then
        return 0
    fi

    local backup_filename=$(basename "$latest_backup")
    log_info "Backup found: $backup_filename"
    log_info "Auto-restoring node identity..."

    docker volume create conduit-data 2>/dev/null || true

    local restore_ok=false
    local tmp_ctr="conduit-restore-tmp"
    docker create --name "$tmp_ctr" -v conduit-data:/home/conduit/data alpine true 2>/dev/null || true
    if docker cp "$latest_backup" "$tmp_ctr:/home/conduit/data/conduit_key.json" 2>/dev/null; then
        docker run --rm -v conduit-data:/home/conduit/data alpine \
            chown -R 1000:1000 /home/conduit/data 2>/dev/null || true
        restore_ok=true
    fi
    docker rm -f "$tmp_ctr" 2>/dev/null || true

    if [ "$restore_ok" = "true" ]; then
        log_success "Node identity restored successfully!"
        return 0
    else
        log_error "Failed to restore backup. Creating new identity."
        return 1
    fi
}

run_conduit() {
    local count=${CONTAINER_COUNT:-1}
    log_info "Starting Conduit ($count container(s))..."

    if ! docker pull "$CONDUIT_IMAGE" >/dev/null 2>&1; then
        log_error "Failed to pull Conduit image."
        exit 1
    fi

    for i in $(seq 1 $count); do
        local cname="conduit"
        local vname="conduit-data"
        [ "$i" -gt 1 ] && cname="conduit-${i}" && vname="conduit-data-${i}"

        docker rm -f "$cname" 2>/dev/null || true
        docker volume create "$vname" 2>/dev/null || true
        docker run --rm -v "${vname}:/home/conduit/data" alpine \
            sh -c "chown -R 1000:1000 /home/conduit/data" 2>/dev/null || true

        # shellcheck disable=SC2086
        docker run -d \
            --name "$cname" \
            --restart unless-stopped \
            --log-opt max-size=15m \
            --log-opt max-file=3 \
            -v "${vname}:/home/conduit/data" \
            --network host \
            "$CONDUIT_IMAGE" \
            start --max-clients "$MAX_CLIENTS" --bandwidth "$BANDWIDTH" --stats-file >/dev/null

        if [ $? -eq 0 ]; then
            log_success "$cname started"
        else
            log_error "Failed to start $cname"
        fi
    done
}

save_settings_install() {
    mkdir -p "$INSTALL_DIR"
    local _tg_token="" _tg_chat="" _tg_interval="6" _tg_enabled="false"
    if [ -f "$INSTALL_DIR/settings.conf" ]; then
        source "$INSTALL_DIR/settings.conf" 2>/dev/null
        _tg_token="${TELEGRAM_BOT_TOKEN:-}"
        _tg_chat="${TELEGRAM_CHAT_ID:-}"
        _tg_interval="${TELEGRAM_INTERVAL:-6}"
        _tg_enabled="${TELEGRAM_ENABLED:-false}"
    fi
    local _tmp="$INSTALL_DIR/settings.conf.tmp.$$"
    cat > "$_tmp" << EOF
MAX_CLIENTS=$MAX_CLIENTS
BANDWIDTH=$BANDWIDTH
CONTAINER_COUNT=${CONTAINER_COUNT:-1}
DATA_CAP_GB=0
DATA_CAP_IFACE=
DATA_CAP_BASELINE_RX=0
DATA_CAP_BASELINE_TX=0
DATA_CAP_PRIOR_USAGE=0
TELEGRAM_BOT_TOKEN="$_tg_token"
TELEGRAM_CHAT_ID="$_tg_chat"
TELEGRAM_INTERVAL=$_tg_interval
TELEGRAM_ENABLED=$_tg_enabled
EOF
    chmod 600 "$_tmp" 2>/dev/null || true
    mv "$_tmp" "$INSTALL_DIR/settings.conf"
    log_success "Settings saved"
}

setup_autostart() {
    if [ "$HAS_SYSTEMD" = "true" ]; then
        cat > /etc/systemd/system/conduit.service << EOF
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
EOF
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable conduit.service 2>/dev/null || true
        systemctl start conduit.service 2>/dev/null || true
    elif command -v rc-update &>/dev/null; then
        cat > /etc/init.d/conduit << 'EOF'
#!/sbin/openrc-run
name="conduit"
depend() {
    need docker
    after network
}
start() {
    ebegin "Starting Conduit"
    /usr/local/bin/conduit start
    eend $?
}
stop() {
    ebegin "Stopping Conduit"
    /usr/local/bin/conduit stop
    eend $?
}
EOF
        chmod +x /etc/init.d/conduit
        rc-update add conduit default 2>/dev/null || true
    fi
}

create_management_script() {
    local tmp_script="$INSTALL_DIR/conduit.tmp.$$"
    cat > "$tmp_script" << 'MANAGEMENT'
#!/bin/bash
if [ -f "/opt/conduit/conduit-manager-full.sh" ]; then
   bash "/opt/conduit/conduit-manager-full.sh" "$@"
else
   curl -sL https://raw.githubusercontent.com/SamNet-dev/conduit-manager/main/conduit.sh | bash -s -- --update-components
   if [ -f /usr/local/bin/conduit ]; then
       /usr/local/bin/conduit "$@"
   fi
fi
MANAGEMENT
    chmod +x "$tmp_script"
    mv "$tmp_script" "$INSTALL_DIR/conduit"
    rm -f /usr/local/bin/conduit 2>/dev/null || true
    ln -s "$INSTALL_DIR/conduit" /usr/local/bin/conduit
}

setup_tracker_service() {
    return 0
}

#═══════════════════════════════════════════════════════════════════════
# Main Execution
#═══════════════════════════════════════════════════════════════════════

main() {
    detect_os
    
    # --- AUTO UPDATE STEP ---
    perform_system_update
    # ------------------------
    
    print_header
    check_dependencies
    
    prompt_settings
    install_docker
    check_and_offer_backup_restore || true
    
    # Cleanup previous instances
    docker stop conduit 2>/dev/null || true
    docker rm conduit 2>/dev/null || true
    
    run_conduit
    save_settings_install
    setup_autostart
    
    create_management_script
    
    # Initial tracker update
    if [ -f "$INSTALL_DIR/conduit" ]; then
        "$INSTALL_DIR/conduit" --update-components >/dev/null 2>&1 || true
    fi

    echo ""
    log_success "Installation Complete."
    echo -e "  Launching Management Menu..."
    sleep 2
    
    # Auto-open menu
    if [ -f "$INSTALL_DIR/conduit" ]; then
        "$INSTALL_DIR/conduit" menu
    fi
}

main "$@"
