#!/bin/bash
#
# ╔═══════════════════════════════════════════════════════════════════╗
# ║      🚀 PSIPHON CONDUIT MANAGER v2.0 Iranux Version                             ║
# ║                                                                   ║
# ║  One-click setup for Psiphon Conduit                              ║
# ║                                                                   ║
# ║  • Installs Docker (if needed)                                    ║
# ║  • Runs Conduit in Docker with live stats                         
# ║  • Auto-start on boot via systemd/OpenRC/SysVinit                 ║
# ║  • Easy management via CLI or interactive menu                    ║
# ║                                                                   ║
# ║  GitHub: https://github.com/Psiphon-Inc/conduit                   ║
# ╚═══════════════════════════════════════════════════════════════════╝
# core engine: https://github.com/Psiphon-Labs/psiphon-tunnel-core
# Usage:
# curl -sL https://raw.githubusercontent.com/iranux/PSIPHON-CONDUIT/main/conduit_auto.sh | sudo bash
#
# Reference: https://github.com/ssmirr/conduit/releases/latest
# Conduit CLI options:
#   -m, --max-clients int   maximum number of proxy clients (1-1000) (default 200)
#   -b, --bandwidth float   bandwidth limit per peer in Mbps (1-40, or -1 for unlimited) (default 5)
#   -v, --verbose           increase verbosity (-v for verbose, -vv for debug)
#

set -eo pipefail

# Require bash
if [ -z "$BASH_VERSION" ]; then
    echo "Error: This script requires bash. Please run with: bash $0"
    exit 1
fi

VERSION="2.0"
CONDUIT_IMAGE="ghcr.io/ssmirr/conduit/conduit:latest"
INSTALL_DIR="${INSTALL_DIR:-/opt/conduit}"
BACKUP_DIR="$INSTALL_DIR/backups"
FORCE_REINSTALL=false
AUTO_INSTALL=false
HEADLESS_DEFAULTS_APPLIED=false

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
    echo "║                🚀 PSIPHON CONDUIT MANAGER v${VERSION}                  ║"
    echo "╠═══════════════════════════════════════════════════════════════════╣"
    echo "║  Help users access the open internet during shutdowns             ║"
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
# Auto-escalate privileges when possible (best-effort).
ensure_root() {
    if [ "$EUID" -eq 0 ]; then
        return 0
    fi
    # If script is being executed from a file path, re-exec via sudo.
    if command -v sudo &>/dev/null && [ -n "${0:-}" ] && [ -f "${0}" ]; then
        exec sudo -E bash "${0}" "$@"
    fi
    # If we can't re-exec (e.g., piped stdin), we must rely on the caller to use sudo.
    log_error "Root privileges are required. Please run with sudo (e.g., curl ... | sudo bash)."
    exit 1
}

update_system_packages() {
    log_info "Updating OS packages (this may take a few minutes)..."
    case "$PKG_MANAGER" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y -q || true
            apt-get upgrade -y -q || true
            apt-get dist-upgrade -y -q || true
            apt-get autoremove -y -q || true
            ;;
        dnf)
            dnf -y -q upgrade || true
            ;;
        yum)
            yum -y -q update || true
            ;;
        pacman)
            pacman -Syu --noconfirm || true
            ;;
        zypper)
            zypper refresh -f -n || true
            zypper update -y -n || true
            ;;
        apk)
            apk update || true
            apk upgrade || true
            ;;
        *)
            log_warn "Unknown package manager. Skipping OS update."
            ;;
    esac
    log_success "System update step complete"
}

apply_headless_defaults() {
    # Apply once.
    if [ "${HEADLESS_DEFAULTS_APPLIED}" = "true" ]; then
        return 0
    fi
    # Required by user request:
    # - Support 50 concurrent users
    # - 10 Mbps per user bandwidth limit
    MAX_CLIENTS=50
    BANDWIDTH=10
    # Keep existing behavior for container count, but default to 1 (safe) if not set.
    CONTAINER_COUNT=${CONTAINER_COUNT:-1}
    HEADLESS_DEFAULTS_APPLIED=true
}

uninstall_silent() {
    # Silent/unattended removal of all Conduit components managed by this script.
    telegram_disable_service 2>/dev/null || true
    rm -f /etc/systemd/system/conduit-telegram.service 2>/dev/null || true
    rm -f /etc/systemd/system/conduit-tracker.service 2>/dev/null || true
    rm -f /etc/systemd/system/conduit-ipmgmt.service 2>/dev/null || true
    rm -f /etc/systemd/system/conduit-ipmgmt.timer 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true

    for i in 1 2 3 4 5; do
        local cname="conduit"
        local vname="conduit-data"
        [ "$i" -gt 1 ] && cname="conduit-${i}" && vname="conduit-data-${i}"
        docker stop "$cname" 2>/dev/null || true
        docker rm -f "$cname" 2>/dev/null || true
        docker volume rm "$vname" 2>/dev/null || true
    done

    docker rmi "$CONDUIT_IMAGE" 2>/dev/null || true

    # Stop/disable boot services
    systemctl stop conduit.service 2>/dev/null || true
    systemctl disable conduit.service 2>/dev/null || true
    rm -f /etc/systemd/system/conduit.service 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true

    rc-service conduit stop 2>/dev/null || true
    rc-update del conduit 2>/dev/null || true
    service conduit stop 2>/dev/null || true
    update-rc.d conduit remove 2>/dev/null || true
    chkconfig conduit off 2>/dev/null || true
    rm -f /etc/init.d/conduit 2>/dev/null || true

    # Remove CLI symlink/binary and install dir (keep backups if present)
    rm -f /usr/local/bin/conduit 2>/dev/null || true
    if [ -d "$INSTALL_DIR" ]; then
        # Preserve backups directory if exists
        if [ -d "$BACKUP_DIR" ]; then
            local tmp_keep="/tmp/conduit_backups_keep_$$"
            rm -rf "$tmp_keep" 2>/dev/null || true
            mkdir -p "$tmp_keep" 2>/dev/null || true
            cp -a "$BACKUP_DIR" "$tmp_keep/" 2>/dev/null || true
            rm -rf "$INSTALL_DIR" 2>/dev/null || true
            mkdir -p "$INSTALL_DIR" 2>/dev/null || true
            mkdir -p "$BACKUP_DIR" 2>/dev/null || true
            cp -a "$tmp_keep/$(basename "$BACKUP_DIR")/." "$BACKUP_DIR/" 2>/dev/null || true
            rm -rf "$tmp_keep" 2>/dev/null || true
        else
            rm -rf "$INSTALL_DIR" 2>/dev/null || true
        fi
    fi
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

    if command -v podman &>/dev/null && ! command -v docker &>/dev/null; then
        log_warn "Podman detected. This script is optimized for Docker."
        log_warn "If installation fails, consider installing 'docker-ce' manually."
    fi
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
    
    if ! command -v free &>/dev/null; then
        case "$PKG_MANAGER" in
            apt|dnf|yum) install_package procps || log_warn "Could not install procps" ;;
            pacman) install_package procps-ng || log_warn "Could not install procps" ;;
            zypper) install_package procps || log_warn "Could not install procps" ;;
            apk) install_package procps || log_warn "Could not install procps" ;;
        esac
    fi

    if ! command -v tput &>/dev/null; then
        case "$PKG_MANAGER" in
            apt) install_package ncurses-bin || log_warn "Could not install ncurses-bin" ;;
            apk) install_package ncurses || log_warn "Could not install ncurses" ;;
            *) install_package ncurses || log_warn "Could not install ncurses" ;;
        esac
    fi

    if ! command -v tcpdump &>/dev/null; then
        install_package tcpdump || log_warn "Could not install tcpdump automatically"
    fi

    # GeoIP (geoiplookup or mmdblookup fallback)
    if ! command -v geoiplookup &>/dev/null && ! command -v mmdblookup &>/dev/null; then
        case "$PKG_MANAGER" in
            apt)
                install_package geoip-bin || log_warn "Could not install geoip-bin"
                install_package geoip-database || log_warn "Could not install geoip-database"
                ;;
            dnf|yum)
                if ! rpm -q epel-release &>/dev/null; then
                    $PKG_MANAGER install -y epel-release &>/dev/null || true
                fi
                if ! install_package GeoIP 2>/dev/null; then
                    # AL2023/Fedora: fallback to libmaxminddb
                    log_info "Legacy GeoIP not available, trying libmaxminddb..."
                    install_package libmaxminddb || log_warn "Could not install libmaxminddb"
                    if [ ! -f /usr/share/GeoIP/GeoLite2-Country.mmdb ] && [ ! -f /var/lib/GeoIP/GeoLite2-Country.mmdb ]; then
                        mkdir -p /usr/share/GeoIP
                        local mmdb_url="https://raw.githubusercontent.com/P3TERX/GeoLite.mmdb/download/GeoLite2-Country.mmdb"
                        curl -sL "$mmdb_url" -o /usr/share/GeoIP/GeoLite2-Country.mmdb 2>/dev/null || \
                            log_warn "Could not download GeoLite2-Country.mmdb"
                    fi
                fi
                ;;
            pacman) install_package geoip || log_warn "Could not install geoip." ;;
            zypper) install_package GeoIP || log_warn "Could not install GeoIP." ;;
            apk) install_package geoip || log_warn "Could not install geoip." ;;
            *) log_warn "Could not install geoiplookup automatically" ;;
        esac
    fi

    if ! command -v qrencode &>/dev/null; then
        install_package qrencode || log_warn "Could not install qrencode automatically"
    fi
}

get_ram_mb() {
    local ram=""
    if command -v free &>/dev/null; then
        ram=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    fi
    
    if [ -z "$ram" ] || [ "$ram" = "0" ]; then
        if [ -f /proc/meminfo ]; then
            local kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
            if [ -n "$kb" ]; then
                ram=$((kb / 1024))
            fi
        fi
    fi
    
    if [ -z "$ram" ] || [ "$ram" -lt 1 ] 2>/dev/null; then
        echo 1
    else
        echo "$ram"
    fi
}

get_cpu_cores() {
    local cores=1
    if command -v nproc &>/dev/null; then
        cores=$(nproc)
    elif [ -f /proc/cpuinfo ]; then
        cores=$(grep -c ^processor /proc/cpuinfo)
    fi
    
    if [ -z "$cores" ] || [ "$cores" -lt 1 ] 2>/dev/null; then
        echo 1
    else
        echo "$cores"
    fi
}

calculate_recommended_clients() {
    local cores=$(get_cpu_cores)
    local recommended=$((cores * 100))
    if [ "$recommended" -gt 1000 ]; then
        echo 1000
    else
        echo "$recommended"
    fi
}

#═══════════════════════════════════════════════════════════════════════
# Interactive Setup
#═══════════════════════════════════════════════════════════════════════

prompt_settings() {
  while true; do
    local ram_mb=$(get_ram_mb)
    local cpu_cores=$(get_cpu_cores)
    local recommended=$(calculate_recommended_clients)
    
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    CONDUIT CONFIGURATION                      ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}Server Info:${NC}"
    echo -e "    CPU Cores: ${GREEN}${cpu_cores}${NC}"
    if [ "$ram_mb" -ge 1000 ]; then
        local ram_gb=$(awk "BEGIN {printf \"%.1f\", $ram_mb/1024}")
        echo -e "    RAM: ${GREEN}${ram_gb} GB${NC}"
    else
        echo -e "    RAM: ${GREEN}${ram_mb} MB${NC}"
    fi
    echo -e "    Recommended max-clients: ${GREEN}${recommended}${NC}"
    echo ""
    echo -e "  ${BOLD}Conduit Options:${NC}"
    echo -e "    ${YELLOW}--max-clients${NC}  Maximum proxy clients (1-1000)"
    echo -e "    ${YELLOW}--bandwidth${NC}    Bandwidth per peer in Mbps (1-40, or -1 for unlimited)"
    echo ""
    
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "  Enter max-clients (1-1000)"
    echo -e "  Press Enter for recommended: ${GREEN}${recommended}${NC}"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    read -p "  max-clients: " input_clients < /dev/tty || true
    
    if [ -z "$input_clients" ]; then
        MAX_CLIENTS=$recommended
    elif [[ "$input_clients" =~ ^[0-9]+$ ]] && [ "$input_clients" -ge 1 ] && [ "$input_clients" -le 1000 ]; then
        MAX_CLIENTS=$input_clients
    else
        log_warn "Invalid input. Using recommended: $recommended"
        MAX_CLIENTS=$recommended
    fi
    
    echo ""
    
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "  Do you want to set ${BOLD}UNLIMITED${NC} bandwidth? (Recommended for servers)"
    echo -e "  ${YELLOW}Note: High bandwidth usage may attract attention.${NC}"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    read -p "  Set unlimited bandwidth? [y/N] " unlimited_bw < /dev/tty || true

    if [[ "$unlimited_bw" =~ ^[Yy]$ ]]; then
        BANDWIDTH="-1"
        echo -e "  Selected: ${GREEN}Unlimited (-1)${NC}"
    else
        echo ""
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -e "  Enter bandwidth per peer in Mbps (1-40)"
        echo -e "  Press Enter for default: ${GREEN}5${NC} Mbps"
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        read -p "  bandwidth: " input_bandwidth < /dev/tty || true
        
        if [ -z "$input_bandwidth" ]; then
            BANDWIDTH=5
        elif [[ "$input_bandwidth" =~ ^[0-9]+$ ]] && [ "$input_bandwidth" -ge 1 ] && [ "$input_bandwidth" -le 40 ]; then
            BANDWIDTH=$input_bandwidth
        elif [[ "$input_bandwidth" =~ ^[0-9]*\.[0-9]+$ ]]; then
            local float_ok=$(awk -v val="$input_bandwidth" 'BEGIN { print (val >= 1 && val <= 40) ? "yes" : "no" }')
            if [ "$float_ok" = "yes" ]; then
                BANDWIDTH=$input_bandwidth
            else
                log_warn "Invalid input. Using default: 5 Mbps"
                BANDWIDTH=5
            fi
        else
            log_warn "Invalid input. Using default: 5 Mbps"
            BANDWIDTH=5
        fi
    fi
    
    echo ""

    # Detect CPU cores and RAM for recommendation
    local cpu_cores=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
    local ram_mb=$(awk '/MemTotal/{printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo 512)
    local rec_containers=2
    if [ "$cpu_cores" -le 1 ] || [ "$ram_mb" -lt 1024 ]; then
        rec_containers=1
    elif [ "$cpu_cores" -ge 4 ] && [ "$ram_mb" -ge 4096 ]; then
        rec_containers=3
    fi

    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "  How many Conduit containers to run? (1-5)"
    echo -e "  More containers = more connections served"
    echo ""
    echo -e "  ${DIM}System: ${cpu_cores} CPU core(s), ${ram_mb}MB RAM${NC}"
    if [ "$cpu_cores" -le 1 ] || [ "$ram_mb" -lt 1024 ]; then
        echo -e "  ${YELLOW}⚠ Low-end system detected. Recommended: 1 container.${NC}"
        echo -e "  ${YELLOW}  Multiple containers may cause high CPU and instability.${NC}"
    elif [ "$cpu_cores" -le 2 ]; then
        echo -e "  ${DIM}Recommended: 1-2 containers for this system.${NC}"
    else
        echo -e "  ${DIM}Recommended: up to ${rec_containers} containers for this system.${NC}"
    fi
    echo ""
    echo -e "  Press Enter for default: ${GREEN}${rec_containers}${NC}"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    read -p "  containers: " input_containers < /dev/tty || true

    if [ -z "$input_containers" ]; then
        CONTAINER_COUNT=$rec_containers
    elif [[ "$input_containers" =~ ^[1-5]$ ]]; then
        CONTAINER_COUNT=$input_containers
    else
        log_warn "Invalid input. Using default: ${rec_containers}"
        CONTAINER_COUNT=$rec_containers
    fi

    echo ""
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}Your Settings:${NC}"
    echo -e "    Max Clients: ${GREEN}${MAX_CLIENTS}${NC}"
    if [ "$BANDWIDTH" == "-1" ]; then
        echo -e "    Bandwidth:   ${GREEN}Unlimited${NC}"
    else
        echo -e "    Bandwidth:   ${GREEN}${BANDWIDTH}${NC} Mbps"
    fi
    echo -e "    Containers:  ${GREEN}${CONTAINER_COUNT}${NC}"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo ""

    read -p "  Proceed with these settings? [Y/n] " confirm < /dev/tty || true
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        continue
    fi
    break
  done
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
        log_info "Adding Docker repo for RHEL..."
        $PKG_MANAGER install -y -q dnf-plugins-core 2>/dev/null || true
        dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null || true
    fi

    if [ "$OS_FAMILY" = "alpine" ]; then
        if ! apk add --no-cache docker docker-cli-compose 2>/dev/null; then
            log_error "Failed to install Docker on Alpine"
            return 1
        fi
        rc-update add docker boot 2>/dev/null || true
        service docker start 2>/dev/null || rc-service docker start 2>/dev/null || true
    else
        if ! curl -fsSL https://get.docker.com | sh; then
            log_error "Official Docker installation script failed."
            log_info "Try installing docker manually: https://docs.docker.com/engine/install/"
            return 1
        fi
        
        if [ "$HAS_SYSTEMD" = "true" ]; then
            systemctl enable docker 2>/dev/null || true
            systemctl start docker 2>/dev/null || true
        else
            if command -v update-rc.d &>/dev/null; then
                update-rc.d docker defaults 2>/dev/null || true
            elif command -v chkconfig &>/dev/null; then
                chkconfig docker on 2>/dev/null || true
            elif command -v rc-update &>/dev/null; then
                rc-update add docker default 2>/dev/null || true
            fi
            service docker start 2>/dev/null || /etc/init.d/docker start 2>/dev/null || true
        fi
    fi
    
    sleep 3
    local retries=27
    while ! docker info &>/dev/null && [ $retries -gt 0 ]; do
        sleep 1
        retries=$((retries - 1))
    done
    
    if docker info &>/dev/null; then
        log_success "Docker installed successfully"
    else
        log_error "Docker installation may have failed. Please check manually."
        return 1
    fi
}


# Check for backup keys and offer restore during install
check_and_offer_backup_restore() {
    if [ "${AUTO_INSTALL}" = "true" ]; then
        # Headless mode: never prompt; always skip restore.
        return 1
    fi
    if [ ! -d "$BACKUP_DIR" ]; then
        return 0
    fi

    local latest_backup=$(ls -t "$BACKUP_DIR"/conduit_key_*.json 2>/dev/null | head -1)

    if [ -z "$latest_backup" ]; then
        return 0
    fi

    local backup_filename=$(basename "$latest_backup")
    local backup_date=$(echo "$backup_filename" | sed -E 's/conduit_key_([0-9]{8})_([0-9]{6})\.json/\1/')
    local backup_time=$(echo "$backup_filename" | sed -E 's/conduit_key_([0-9]{8})_([0-9]{6})\.json/\2/')
    local formatted_date="${backup_date:0:4}-${backup_date:4:2}-${backup_date:6:2}"
    local formatted_time="${backup_time:0:2}:${backup_time:2:2}:${backup_time:4:2}"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  📁 PREVIOUS NODE IDENTITY BACKUP FOUND${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  A backup of your node identity key was found:"
    echo -e "    ${YELLOW}File:${NC} $backup_filename"
    echo -e "    ${YELLOW}Date:${NC} $formatted_date $formatted_time"
    echo ""
    echo -e "  Restoring this key will:"
    echo -e "    • Preserve your node's identity on the Psiphon network"
    echo -e "    • Maintain any accumulated reputation"
    echo -e "    • Allow peers to reconnect to your known node ID"
    echo ""
    echo -e "  ${YELLOW}Note:${NC} If you don't restore, a new identity will be generated."
    echo ""

    while true; do
        read -p "  Do you want to restore your previous node identity? (y/n): " restore_choice < /dev/tty || true

        if [[ "$restore_choice" =~ ^[Yy]$ ]]; then
            echo ""
            log_info "Restoring node identity from backup..."

            docker volume create conduit-data 2>/dev/null || true

            # Try bind-mount, fall back to docker cp (Snap Docker compatibility)
            local restore_ok=false
            if docker run --rm -v conduit-data:/home/conduit/data -v "$BACKUP_DIR":/backup alpine \
                sh -c "cp /backup/$backup_filename /home/conduit/data/conduit_key.json && chown -R 1000:1000 /home/conduit/data" 2>/dev/null; then
                restore_ok=true
            else
                log_info "Bind-mount failed (Snap Docker?), trying docker cp..."
                local tmp_ctr="conduit-restore-tmp"
                docker create --name "$tmp_ctr" -v conduit-data:/home/conduit/data alpine true 2>/dev/null || true
                if docker cp "$latest_backup" "$tmp_ctr:/home/conduit/data/conduit_key.json" 2>/dev/null; then
                    docker run --rm -v conduit-data:/home/conduit/data alpine \
                        chown -R 1000:1000 /home/conduit/data 2>/dev/null || true
                    restore_ok=true
                fi
                docker rm -f "$tmp_ctr" 2>/dev/null || true
            fi

            if [ "$restore_ok" = "true" ]; then
                log_success "Node identity restored successfully!"
                echo ""
                return 0
            else
                log_error "Failed to restore backup. Proceeding with fresh install."
                echo ""
                return 1
            fi
        elif [[ "$restore_choice" =~ ^[Nn]$ ]]; then
            echo ""
            log_info "Skipping restore. A new node identity will be generated."
            echo ""
            return 1
        else
            echo "  Please enter y or n."
        fi
    done
}

run_conduit() {
    local count=${CONTAINER_COUNT:-1}
    log_info "Starting Conduit ($count container(s))..."

    log_info "Pulling Conduit image ($CONDUIT_IMAGE)..."
    if ! docker pull "$CONDUIT_IMAGE"; then
        log_error "Failed to pull Conduit image. Check your internet connection."
        exit 1
    fi

    for i in $(seq 1 $count); do
        local cname="conduit"
        local vname="conduit-data"
        [ "$i" -gt 1 ] && cname="conduit-${i}" && vname="conduit-data-${i}"

        docker rm -f "$cname" 2>/dev/null || true

        # Ensure volume exists with correct permissions (uid 1000)
        docker volume create "$vname" 2>/dev/null || true
        docker run --rm -v "${vname}:/home/conduit/data" alpine \
            sh -c "chown -R 1000:1000 /home/conduit/data" 2>/dev/null || true

        local resource_args=""
        local cpus=$(get_container_cpus $i)
        local mem=$(get_container_memory $i)
        [ -n "$cpus" ] && resource_args+="--cpus $cpus "
        [ -n "$mem" ] && resource_args+="--memory $mem "
        # shellcheck disable=SC2086
        docker run -d \
            --name "$cname" \
            --restart unless-stopped \
            --log-opt max-size=15m \
            --log-opt max-file=3 \
            -v "${vname}:/home/conduit/data" \
            --network host \
            $resource_args \
            "$CONDUIT_IMAGE" \
            start --max-clients "$MAX_CLIENTS" --bandwidth "$BANDWIDTH" --stats-file

        if [ $? -eq 0 ]; then
            log_success "$cname started"
        else
            log_error "Failed to start $cname"
        fi
    done

    sleep 3
    if docker ps | grep -q conduit; then
        if [ "$BANDWIDTH" == "-1" ]; then
            log_success "Settings: max-clients=$MAX_CLIENTS, bandwidth=Unlimited, containers=$count"
        else
            log_success "Settings: max-clients=$MAX_CLIENTS, bandwidth=${BANDWIDTH}Mbps, containers=$count"
        fi
    else
        log_error "Conduit failed to start"
        docker logs conduit 2>&1 | tail -10
        exit 1
    fi
}

save_settings_install() {
    mkdir -p "$INSTALL_DIR"
    # Preserve existing Telegram settings on reinstall
    local _tg_token="" _tg_chat="" _tg_interval="6" _tg_enabled="false"
    local _tg_alerts="true" _tg_daily="true" _tg_weekly="true" _tg_label="" _tg_start_hour="0"
    if [ -f "$INSTALL_DIR/settings.conf" ]; then
        source "$INSTALL_DIR/settings.conf" 2>/dev/null
        _tg_token="${TELEGRAM_BOT_TOKEN:-}"
        _tg_chat="${TELEGRAM_CHAT_ID:-}"
        _tg_interval="${TELEGRAM_INTERVAL:-6}"
        _tg_enabled="${TELEGRAM_ENABLED:-false}"
        _tg_alerts="${TELEGRAM_ALERTS_ENABLED:-true}"
        _tg_daily="${TELEGRAM_DAILY_SUMMARY:-true}"
        _tg_weekly="${TELEGRAM_WEEKLY_SUMMARY:-true}"
        _tg_label="${TELEGRAM_SERVER_LABEL:-}"
        _tg_start_hour="${TELEGRAM_START_HOUR:-0}"
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
TELEGRAM_ALERTS_ENABLED=$_tg_alerts
TELEGRAM_DAILY_SUMMARY=$_tg_daily
TELEGRAM_WEEKLY_SUMMARY=$_tg_weekly
TELEGRAM_SERVER_LABEL="$_tg_label"
TELEGRAM_START_HOUR=$_tg_start_hour
IPMGMT_ENABLED=${IPMGMT_ENABLED:-true}
EOF
    chmod 600 "$_tmp" 2>/dev/null || true
    mv "$_tmp" "$INSTALL_DIR/settings.conf"

    if [ ! -f "$INSTALL_DIR/settings.conf" ]; then
        log_error "Failed to save settings. Check disk space and permissions."
        return 1
    fi

    log_success "Settings saved"
}

setup_autostart() {
    log_info "Setting up auto-start on boot..."
    
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
        log_success "Systemd service created, enabled, and started"
        
    elif command -v rc-update &>/dev/null; then
        # OpenRC (Alpine, Gentoo, etc.)
        cat > /etc/init.d/conduit << 'EOF'
#!/sbin/openrc-run

name="conduit"
description="Psiphon Conduit Service"
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
        log_success "OpenRC service created and enabled"
        
    elif [ -d /etc/init.d ]; then
        # SysVinit fallback
        cat > /etc/init.d/conduit << 'EOF'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          conduit
# Required-Start:    $docker
# Required-Stop:     $docker
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Psiphon Conduit Service
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
    status)
        docker ps | grep -q conduit && echo "Running" || echo "Stopped"
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac
EOF
        chmod +x /etc/init.d/conduit
        if command -v update-rc.d &>/dev/null; then
            update-rc.d conduit defaults 2>/dev/null || true
        elif command -v chkconfig &>/dev/null; then
            chkconfig conduit on 2>/dev/null || true
        fi
        log_success "SysVinit service created and enabled"
        
    else
        log_warn "Could not set up auto-start. Docker's restart policy will handle restarts."
        log_info "Container is set to restart unless-stopped, which works on reboot if Docker starts."
    fi
}

setup_ipmgmt_files() {
        mkdir -p "$INSTALL_DIR"
        local script_path="$INSTALL_DIR/conduit-ipmgmt.sh"
        cat > "$script_path" << 'IPMGMT'
#!/bin/bash
set -euo pipefail

INSTALL_DIR="/opt/conduit"
SETTINGS_FILE="$INSTALL_DIR/settings.conf"
SNAPSHOT_FILE="$INSTALL_DIR/traffic_stats/tracker_snapshot"
STATE_DIR="$INSTALL_DIR/ipmgmt"
STATE_FILE="$STATE_DIR/state.db"
INSTALL_EPOCH_FILE="$STATE_DIR/install_epoch"

mkdir -p "$STATE_DIR"

# Load toggle
IPMGMT_ENABLED=true
if [ -f "$SETTINGS_FILE" ]; then
  # shellcheck disable=SC1090
  source "$SETTINGS_FILE" 2>/dev/null || true
fi
IPMGMT_ENABLED=${IPMGMT_ENABLED:-true}

now_epoch() { date +%s; }

ensure_ipset_iptables() {
  if ! command -v ipset >/dev/null 2>&1; then
    exit 0
  fi
  ipset create conduit_block hash:ip timeout 0 -exist >/dev/null 2>&1 || true

  # Insert DROP rule if missing
  if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -m set --match-set conduit_block src -j DROP >/dev/null 2>&1 || \
      iptables -I INPUT 1 -m set --match-set conduit_block src -j DROP >/dev/null 2>&1 || true
  fi
}

ensure_install_epoch() {
  if [ -f "$INSTALL_EPOCH_FILE" ]; then
    return 0
  fi
  now=$(now_epoch)
  echo "$now" > "$INSTALL_EPOCH_FILE"
}

normalize_country() {
  # stdin: country string -> stdout normalized
  local c="${1:-Unknown}"
  echo "$c"
}

is_iran() {
  local c="${1:-}"
  [[ "$c" == *Iran* ]] && return 0
  return 1
}

load_state() {
  # STATE_FILE lines: ip|first_seen|last_seen|country
  : > "$STATE_FILE.tmp" 2>/dev/null || true
  if [ -f "$STATE_FILE" ]; then
    cat "$STATE_FILE" > "$STATE_FILE.tmp" 2>/dev/null || true
  fi
  mv -f "$STATE_FILE.tmp" "$STATE_FILE" 2>/dev/null || true
}

upsert_state() {
  local ip="$1" first="$2" last="$3" country="$4"
  # replace or add
  awk -F'|' -v ip="$ip" -v first="$first" -v last="$last" -v c="$country" '
    BEGIN{OFS="|"; found=0}
    $1==ip {print ip, first, last, c; found=1; next}
    {print}
    END{ if(!found) print ip, first, last, c }
  ' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

get_state_field() {
  local ip="$1" field="$2"
  awk -F'|' -v ip="$ip" -v f="$field" '$1==ip {print $f; exit}' "$STATE_FILE" 2>/dev/null || true
}

prune_state() {
  local now="$1"
  # Drop entries not seen for 10 minutes
  awk -F'|' -v now="$now" 'BEGIN{OFS="|"} { if(($3+0) >= (now-600)) print }' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

main_loop() {
  ensure_ipset_iptables
  ensure_install_epoch
  load_state

  while true; do
    # Reload toggle each cycle
    IPMGMT_ENABLED=true
    if [ -f "$SETTINGS_FILE" ]; then
      # shellcheck disable=SC1090
      source "$SETTINGS_FILE" 2>/dev/null || true
    fi
    IPMGMT_ENABLED=${IPMGMT_ENABLED:-true}

    if [ "$IPMGMT_ENABLED" != "true" ]; then
      sleep 10
      continue
    fi

    local now
    now=$(now_epoch)

    local install_epoch
    install_epoch=$(cat "$INSTALL_EPOCH_FILE" 2>/dev/null || echo "$now")
    # 12 hours grace
    if [ "$now" -lt $((install_epoch + 43200)) ]; then
      prune_state "$now"
      sleep 10
      continue
    fi

    # Build current IP->country map from snapshot (dir|country|bytes|ip)
    if [ -s "$SNAPSHOT_FILE" ]; then
      awk -F'|' '{ip=$4; c=$2; if(ip!="" && c!="") seen[ip]=c} END{for(ip in seen) print ip "|" seen[ip]}' "$SNAPSHOT_FILE" > "$STATE_DIR/current_ips" 2>/dev/null || true
    else
      : > "$STATE_DIR/current_ips"
    fi

    if [ -s "$STATE_DIR/current_ips" ]; then
      while IFS='|' read -r ip country; do
        [ -z "$ip" ] && continue
        country=$(normalize_country "$country")

        local first_seen last_seen
        first_seen=$(get_state_field "$ip" 2)
        last_seen=$(get_state_field "$ip" 3)

        if [ -z "$first_seen" ]; then
          first_seen="$now"
        fi
        last_seen="$now"

        # Enforce after 5 minutes for non-Iran
        if ! is_iran "$country"; then
          local age=$((now - first_seen))
          if [ "$age" -ge 300 ]; then
            if command -v ipset >/dev/null 2>&1; then
              ipset add conduit_block "$ip" timeout 60 -exist >/dev/null 2>&1 || true
            fi
            # Reset first_seen so that after the 1-min block and reconnection, they get another 5-min window.
            first_seen="$now"
          fi
        fi

        upsert_state "$ip" "$first_seen" "$last_seen" "$country"
      done < "$STATE_DIR/current_ips"
    fi

    prune_state "$now"
    sleep 10
  done
}

main_loop
IPMGMT
        chmod +x "$script_path" 2>/dev/null || true
    }

    setup_ipmgmt_service() {
        setup_ipmgmt_files
        # Install ipset if available via package manager (best effort)
        if ! command -v ipset &>/dev/null; then
            case "$PKG_MANAGER" in
                apt) install_package ipset 2>/dev/null || true ;;
                dnf|yum) install_package ipset 2>/dev/null || true ;;
                pacman) install_package ipset 2>/dev/null || true ;;
                zypper) install_package ipset 2>/dev/null || true ;;
                apk) install_package ipset 2>/dev/null || true ;;
                *) true ;;
            esac
        fi

        if [ "$HAS_SYSTEMD" = "true" ]; then
            cat > /etc/systemd/system/conduit-ipmgmt.service << EOF
[Unit]
Description=Conduit IP Management (Geo-fencing)
After=network.target docker.service

[Service]
Type=simple
ExecStart=$INSTALL_DIR/conduit-ipmgmt.sh
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload 2>/dev/null || true
            systemctl enable conduit-ipmgmt.service 2>/dev/null || true
            systemctl restart conduit-ipmgmt.service 2>/dev/null || true
            log_success "IP management service enabled"
        else
            log_warn "IP management service: systemd not detected. Feature will be available only after manual start."
        fi
    }

#═══════════════════════════════════════════════════════════════════════
# Management Script
#═══════════════════════════════════════════════════════════════════════

create_management_script() {
    # Generate the management script (write to temp file first to avoid "Text file busy")
    local tmp_script="$INSTALL_DIR/conduit.tmp.$$"
    cat > "$tmp_script" << 'MANAGEMENT'
#!/bin/bash
#
# Psiphon Conduit Manager
# Reference: https://github.com/ssmirr/conduit/releases/latest
#

VERSION="1.2"
INSTALL_DIR="REPLACE_ME_INSTALL_DIR"
BACKUP_DIR="$INSTALL_DIR/backups"
CONDUIT_IMAGE="ghcr.io/ssmirr/conduit/conduit:latest"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Load settings
[ -f "$INSTALL_DIR/settings.conf" ] && source "$INSTALL_DIR/settings.conf"
MAX_CLIENTS=${MAX_CLIENTS:-200}
BANDWIDTH=${BANDWIDTH:-5}
CONTAINER_COUNT=${CONTAINER_COUNT:-1}
DATA_CAP_GB=${DATA_CAP_GB:-0}
DATA_CAP_IFACE=${DATA_CAP_IFACE:-}
DATA_CAP_BASELINE_RX=${DATA_CAP_BASELINE_RX:-0}
DATA_CAP_BASELINE_TX=${DATA_CAP_BASELINE_TX:-0}
DATA_CAP_PRIOR_USAGE=${DATA_CAP_PRIOR_USAGE:-0}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID:-}
TELEGRAM_INTERVAL=${TELEGRAM_INTERVAL:-6}
TELEGRAM_ENABLED=${TELEGRAM_ENABLED:-false}
IPMGMT_ENABLED=${IPMGMT_ENABLED:-true}

# Ensure we're running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This command must be run as root (use sudo conduit)${NC}"
    exit 1
fi

# Check if Docker is available
check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${RED}Error: Docker is not installed!${NC}"
        echo ""
        echo "Docker is required to run Conduit. Please reinstall:"
        echo "  curl -fsSL https://get.docker.com | sudo sh"
        echo ""
        echo "Or re-run the Conduit installer:"
        echo "  sudo bash conduit.sh"
        exit 1
    fi
    
    if ! docker info &>/dev/null; then
        echo -e "${RED}Error: Docker daemon is not running!${NC}"
        echo ""
        echo "Start Docker with:"
        echo "  sudo systemctl start docker       # For systemd"
        echo "  sudo /etc/init.d/docker start     # For SysVinit"
        echo "  sudo rc-service docker start      # For OpenRC"
        exit 1
    fi
}

# Run Docker check
check_docker


toggle_ipmgmt() {
    echo ""
    echo -e "${CYAN}═══ IP MANAGEMENT (GEO-FENCING) ═══${NC}"
    echo ""
    if [ "${IPMGMT_ENABLED}" = "true" ]; then
        echo -e "  Current: ${GREEN}Enabled${NC}"
        echo ""
        read -p "  Disable IP management? [y/N]: " ans < /dev/tty || true
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            IPMGMT_ENABLED=false
        fi
    else
        echo -e "  Current: ${RED}Disabled${NC}"
        echo ""
        read -p "  Enable IP management? [y/N]: " ans < /dev/tty || true
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            IPMGMT_ENABLED=true
        fi
    fi

    # Persist toggle
    if [ -f "$INSTALL_DIR/settings.conf" ]; then
        if grep -q "^IPMGMT_ENABLED=" "$INSTALL_DIR/settings.conf" 2>/dev/null; then
            sed -i "s/^IPMGMT_ENABLED=.*/IPMGMT_ENABLED=${IPMGMT_ENABLED}/" "$INSTALL_DIR/settings.conf" 2>/dev/null || true
        else
            echo "IPMGMT_ENABLED=${IPMGMT_ENABLED}" >> "$INSTALL_DIR/settings.conf"
        fi
    fi

    # Start/stop service if systemd exists
    if command -v systemctl &>/dev/null; then
        systemctl daemon-reload 2>/dev/null || true
        if [ "${IPMGMT_ENABLED}" = "true" ]; then
            systemctl enable conduit-ipmgmt.service 2>/dev/null || true
            systemctl restart conduit-ipmgmt.service 2>/dev/null || true
            echo -e "  ${GREEN}✓ IP management enabled${NC}"
        else
            systemctl stop conduit-ipmgmt.service 2>/dev/null || true
            systemctl disable conduit-ipmgmt.service 2>/dev/null || true
            echo -e "  ${YELLOW}✓ IP management disabled${NC}"
        fi
    else
        echo -e "  ${YELLOW}Note:${NC} systemd not detected; service control not available."
    fi

    echo ""
    read -n 1 -s -r -p "  Press any key to return..." < /dev/tty || true
}


# Check for awk (needed for stats parsing)
if ! command -v awk &>/dev/null; then
    echo -e "${YELLOW}Warning: awk not found. Some stats may not display correctly.${NC}"
fi

# Helper: Get container name by index (1-based)
get_container_name() {
    local idx=${1:-1}
    if [ "$idx" -eq 1 ]; then
        echo "conduit"
    else
        echo "conduit-${idx}"
    fi
}

# Helper: Get volume name by index (1-based)
get_volume_name() {
    local idx=${1:-1}
    if [ "$idx" -eq 1 ]; then
        echo "conduit-data"
    else
        echo "conduit-data-${idx}"
    fi
}

# Helper: Fix volume permissions for conduit user (uid 1000)
fix_volume_permissions() {
    local idx=${1:-0}
    if [ "$idx" -eq 0 ]; then
        # Fix all volumes
        for i in $(seq 1 $CONTAINER_COUNT); do
            local vol=$(get_volume_name $i)
            docker run --rm -v "${vol}:/home/conduit/data" alpine \
                sh -c "chown -R 1000:1000 /home/conduit/data" 2>/dev/null || true
        done
    else
        local vol=$(get_volume_name $idx)
        docker run --rm -v "${vol}:/home/conduit/data" alpine \
            sh -c "chown -R 1000:1000 /home/conduit/data" 2>/dev/null || true
    fi
}

# Helper: Start/recreate conduit container with current settings
get_container_max_clients() {
    local idx=${1:-1}
    local var="MAX_CLIENTS_${idx}"
    local val="${!var}"
    echo "${val:-$MAX_CLIENTS}"
}

get_container_bandwidth() {
    local idx=${1:-1}
    local var="BANDWIDTH_${idx}"
    local val="${!var}"
    echo "${val:-$BANDWIDTH}"
}

get_container_cpus() {
    local idx=${1:-1}
    local var="CPUS_${idx}"
    local val="${!var}"
    echo "${val:-${DOCKER_CPUS:-}}"
}

get_container_memory() {
    local idx=${1:-1}
    local var="MEMORY_${idx}"
    local val="${!var}"
    echo "${val:-${DOCKER_MEMORY:-}}"
}

run_conduit_container() {
    local idx=${1:-1}
    local name=$(get_container_name $idx)
    local vol=$(get_volume_name $idx)
    local mc=$(get_container_max_clients $idx)
    local bw=$(get_container_bandwidth $idx)
    local cpus=$(get_container_cpus $idx)
    local mem=$(get_container_memory $idx)
    # Remove any existing container with the same name to avoid conflicts
    if docker ps -a 2>/dev/null | grep -q "[[:space:]]${name}$"; then
        docker rm -f "$name" 2>/dev/null || true
    fi
    local resource_args=""
    [ -n "$cpus" ] && resource_args+="--cpus $cpus "
    [ -n "$mem" ] && resource_args+="--memory $mem "
    # shellcheck disable=SC2086
    docker run -d \
        --name "$name" \
        --restart unless-stopped \
        --log-opt max-size=15m \
        --log-opt max-file=3 \
        -v "${vol}:/home/conduit/data" \
        --network host \
        $resource_args \
        "$CONDUIT_IMAGE" \
        start --max-clients "$mc" --bandwidth "$bw" --stats-file
}

print_header() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    printf "║                🚀 PSIPHON CONDUIT MANAGER v%-5s                  ║\n" "${VERSION}"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_live_stats_header() {
    local EL="\033[K"
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${EL}"
    printf "║  ${NC}🚀 PSIPHON CONDUIT MANAGER v%-5s   ${CYAN}CONDUIT LIVE STATISTICS      ║${EL}\n" "${VERSION}"
    echo -e "╠═══════════════════════════════════════════════════════════════════╣${EL}"
    # Check for per-container overrides
    local has_overrides=false
    for i in $(seq 1 $CONTAINER_COUNT); do
        local mc_var="MAX_CLIENTS_${i}"
        local bw_var="BANDWIDTH_${i}"
        if [ -n "${!mc_var}" ] || [ -n "${!bw_var}" ]; then
            has_overrides=true
            break
        fi
    done
    if [ "$has_overrides" = true ] && [ "$CONTAINER_COUNT" -gt 1 ]; then
        for i in $(seq 1 $CONTAINER_COUNT); do
            local mc=$(get_container_max_clients $i)
            local bw=$(get_container_bandwidth $i)
            local bw_d="Unlimited"
            [ "$bw" != "-1" ] && bw_d="${bw}Mbps"
            local line="$(get_container_name $i): ${mc} clients, ${bw_d}"
            printf "║  ${GREEN}%-64s${CYAN}║${EL}\n" "$line"
        done
    else
        printf "║  Max Clients: ${GREEN}%-52s${CYAN}║${EL}\n" "${MAX_CLIENTS}"
        if [ "$BANDWIDTH" == "-1" ]; then
            printf "║  Bandwidth:   ${GREEN}%-52s${CYAN}║${EL}\n" "Unlimited"
        else
            printf "║  Bandwidth:   ${GREEN}%-52s${CYAN}║${EL}\n" "${BANDWIDTH} Mbps"
        fi
    fi
    echo -e "╚═══════════════════════════════════════════════════════════════════╝${EL}"
    echo -e "${NC}\033[K"
}



get_node_id() {
    local vol="${1:-conduit-data}"
    if docker volume inspect "$vol" >/dev/null 2>&1; then
        local mountpoint=$(docker volume inspect "$vol" --format '{{ .Mountpoint }}' 2>/dev/null)
        local key_json=""
        if [ -n "$mountpoint" ] && [ -f "$mountpoint/conduit_key.json" ]; then
            key_json=$(cat "$mountpoint/conduit_key.json" 2>/dev/null)
        else
            local tmp_ctr="conduit-nodeid-tmp"
            docker rm -f "$tmp_ctr" 2>/dev/null || true
            docker create --name "$tmp_ctr" -v "$vol":/data alpine true 2>/dev/null || true
            key_json=$(docker cp "$tmp_ctr:/data/conduit_key.json" - 2>/dev/null | tar -xO 2>/dev/null)
            docker rm -f "$tmp_ctr" 2>/dev/null || true
        fi
        if [ -n "$key_json" ]; then
            echo "$key_json" | grep "privateKeyBase64" | awk -F'"' '{print $4}' | base64 -d 2>/dev/null | tail -c 32 | base64 | tr -d '=\n'
        fi
    fi
}

get_raw_key() {
    local vol="${1:-conduit-data}"
    if docker volume inspect "$vol" >/dev/null 2>&1; then
        local mountpoint=$(docker volume inspect "$vol" --format '{{ .Mountpoint }}' 2>/dev/null)
        local key_json=""
        if [ -n "$mountpoint" ] && [ -f "$mountpoint/conduit_key.json" ]; then
            key_json=$(cat "$mountpoint/conduit_key.json" 2>/dev/null)
        else
            local tmp_ctr="conduit-rawkey-tmp"
            docker rm -f "$tmp_ctr" 2>/dev/null || true
            docker create --name "$tmp_ctr" -v "$vol":/data alpine true 2>/dev/null || true
            key_json=$(docker cp "$tmp_ctr:/data/conduit_key.json" - 2>/dev/null | tar -xO 2>/dev/null)
            docker rm -f "$tmp_ctr" 2>/dev/null || true
        fi
        if [ -n "$key_json" ]; then
            echo "$key_json" | grep "privateKeyBase64" | awk -F'"' '{print $4}'
        fi
    fi
}

show_qr_code() {
    local idx="${1:-}"
    # If multiple containers and no index specified, prompt
    if [ -z "$idx" ] && [ "$CONTAINER_COUNT" -gt 1 ]; then
        echo ""
        echo -e "${CYAN}═══ SELECT CONTAINER ═══${NC}"
        for ci in $(seq 1 $CONTAINER_COUNT); do
            local cname=$(get_container_name $ci)
            echo -e "  ${ci}. ${cname}"
        done
        echo ""
        read -p "  Which container? (1-${CONTAINER_COUNT}): " idx < /dev/tty || true
        if ! [[ "$idx" =~ ^[1-5]$ ]] || [ "$idx" -gt "$CONTAINER_COUNT" ]; then
            echo -e "${RED}  Invalid selection.${NC}"
            return
        fi
    fi
    [ -z "$idx" ] && idx=1
    local vol=$(get_volume_name $idx)
    local cname=$(get_container_name $idx)

    clear
    local node_id=$(get_node_id "$vol")
    local raw_key=$(get_raw_key "$vol")
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                    CONDUIT ID & QR CODE                           ║${NC}"
    echo -e "${CYAN}╠═══════════════════════════════════════════════════════════════════╣${NC}"
    if [ "$CONTAINER_COUNT" -gt 1 ]; then
        printf "${CYAN}║${NC}  Container:  ${BOLD}%-52s${CYAN}║${NC}\n" "$cname"
    fi
    if [ -n "$node_id" ]; then
        printf "${CYAN}║${NC}  Conduit ID: ${GREEN}%-52s${CYAN}║${NC}\n" "$node_id"
    else
        printf "${CYAN}║${NC}  Conduit ID: ${YELLOW}%-52s${CYAN}║${NC}\n" "Not available (start container first)"
    fi
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    if [ -n "$raw_key" ] && command -v qrencode &>/dev/null; then
        local hostname_str=$(hostname 2>/dev/null || echo "conduit")
        local claim_json="{\"version\":1,\"data\":{\"key\":\"${raw_key}\",\"name\":\"${hostname_str}\"}}"
        local claim_b64=$(echo -n "$claim_json" | base64 | tr -d '\n')
        local claim_url="network.ryve.app://(app)/conduits?claim=${claim_b64}"
        echo -e "${BOLD}  Scan to claim rewards:${NC}"
        echo ""
        qrencode -t ANSIUTF8 "$claim_url" 2>/dev/null
    elif ! command -v qrencode &>/dev/null; then
        echo -e "${YELLOW}  qrencode not installed. Install with: sudo apt install qrencode${NC}"
        echo -e "  ${CYAN}Claim rewards at: https://network.ryve.app${NC}"
    else
        echo -e "${YELLOW}  Key not available. Start container first.${NC}"
    fi
    echo ""
    read -n 1 -s -r -p "  Press any key to return..." < /dev/tty || true
}

show_dashboard() {
    local stop_dashboard=0
    # Setup trap to catch signals gracefully
    trap 'stop_dashboard=1' SIGINT SIGTERM
    
    # Use alternate screen buffer if available for smoother experience
    tput smcup 2>/dev/null || true
    echo -ne "\033[?25l" # Hide cursor
    # Initial clear
    clear

    while [ $stop_dashboard -eq 0 ]; do
        # Move cursor to top-left (0,0)
        # We NO LONGER clear the screen here to avoid the "full black" flash
        if ! tput cup 0 0 2>/dev/null; then
            printf "\033[H"
        fi
        
        print_live_stats_header
        
        show_status "live"
        
        # Check data cap
        if [ "$DATA_CAP_GB" -gt 0 ] 2>/dev/null; then
            local usage=$(get_data_usage)
            local used_rx=$(echo "$usage" | awk '{print $1}')
            local used_tx=$(echo "$usage" | awk '{print $2}')
            local total_used=$((used_rx + used_tx + ${DATA_CAP_PRIOR_USAGE:-0}))
            local cap_gb_fmt=$(format_gb $total_used)
            echo -e "${CYAN}═══ DATA USAGE ═══${NC}\033[K"
            echo -e "  Usage: ${YELLOW}${cap_gb_fmt} GB${NC} / ${GREEN}${DATA_CAP_GB} GB${NC}\033[K"
            if ! check_data_cap; then
                echo -e "  ${RED}⚠ DATA CAP EXCEEDED - Containers stopped!${NC}\033[K"
            fi
            echo -e "\033[K"
        fi

        # Side-by-side: Active Clients | Top Upload
        local snap_file="$INSTALL_DIR/traffic_stats/tracker_snapshot"
        local data_file="$INSTALL_DIR/traffic_stats/cumulative_data"
        if [ -s "$snap_file" ] || [ -s "$data_file" ]; then
            # Reuse connected count from show_status (already cached)
            local dash_clients=${_total_connected:-0}

            # Left column: Active Clients per country (estimated from snapshot distribution)
            local left_lines=()
            if [ -s "$snap_file" ] && [ "$dash_clients" -gt 0 ]; then
                local snap_data
                snap_data=$(awk -F'|' '{if($2!=""&&$4!="") seen[$2"|"$4]=1} END{for(k in seen){split(k,a,"|");c[a[1]]++} for(co in c) print c[co]"|"co}' "$snap_file" 2>/dev/null | sort -t'|' -k1 -nr | head -5)
                local snap_total=0
                if [ -n "$snap_data" ]; then
                    while IFS='|' read -r cnt co; do
                        snap_total=$((snap_total + cnt))
                    done <<< "$snap_data"
                fi
                [ "$snap_total" -eq 0 ] && snap_total=1
                if [ -n "$snap_data" ]; then
                    while IFS='|' read -r cnt country; do
                        [ -z "$country" ] && continue
                        country="${country%% - #*}"
                        local est=$(( (cnt * dash_clients) / snap_total ))
                        [ "$est" -eq 0 ] && [ "$cnt" -gt 0 ] && est=1
                        local pct=$((est * 100 / dash_clients))
                        [ "$pct" -gt 100 ] && pct=100
                        local bl=$((pct / 20)); [ "$bl" -lt 1 ] && bl=1; [ "$bl" -gt 5 ] && bl=5
                        local bf=""; local bp=""; for ((bi=0; bi<bl; bi++)); do bf+="█"; done; for ((bi=bl; bi<5; bi++)); do bp+=" "; done
                        left_lines+=("$(printf "%-11.11s %3d%% \033[32m%s%s\033[0m %5s" "$country" "$pct" "$bf" "$bp" "$(format_number $est)")")
                    done <<< "$snap_data"
                fi
            fi

            # Right column: Top 5 Upload (cumulative outbound bytes per country)
            local right_lines=()
            if [ -s "$data_file" ]; then
                local all_upload
                all_upload=$(awk -F'|' '{if($1!="" && $3+0>0) print $3"|"$1}' "$data_file" 2>/dev/null | sort -t'|' -k1 -nr)
                local top5_upload=$(echo "$all_upload" | head -5)
                local total_upload=0
                if [ -n "$all_upload" ]; then
                    while IFS='|' read -r bytes co; do
                        bytes=$(printf '%.0f' "${bytes:-0}" 2>/dev/null) || bytes=0
                        total_upload=$((total_upload + bytes))
                    done <<< "$all_upload"
                fi
                [ "$total_upload" -eq 0 ] && total_upload=1
                if [ -n "$top5_upload" ]; then
                    while IFS='|' read -r bytes country; do
                        [ -z "$country" ] && continue
                        country="${country%% - #*}"
                        bytes=$(printf '%.0f' "${bytes:-0}" 2>/dev/null) || bytes=0
                        local pct=$((bytes * 100 / total_upload))
                        local bl=$((pct / 20)); [ "$bl" -lt 1 ] && bl=1; [ "$bl" -gt 5 ] && bl=5
                        local bf=""; local bp=""; for ((bi=0; bi<bl; bi++)); do bf+="█"; done; for ((bi=bl; bi<5; bi++)); do bp+=" "; done
                        local fmt_bytes=$(format_bytes $bytes)
                        right_lines+=("$(printf "%-11.11s %3d%% \033[35m%s%s\033[0m %9s" "$country" "$pct" "$bf" "$bp" "$fmt_bytes")")
                    done <<< "$top5_upload"
                fi
            fi

            # Print side by side
            printf "  ${GREEN}${BOLD}%-30s${NC} ${YELLOW}${BOLD}%s${NC}\033[K\n" "ACTIVE CLIENTS" "TOP 5 UPLOAD (cumulative)"
            local max_rows=${#left_lines[@]}
            [ ${#right_lines[@]} -gt $max_rows ] && max_rows=${#right_lines[@]}
            for ((ri=0; ri<max_rows; ri++)); do
                local lc="${left_lines[$ri]:-}"
                local rc="${right_lines[$ri]:-}"
                if [ -n "$lc" ] && [ -n "$rc" ]; then
                    printf "  "
                    echo -ne "$lc"
                    printf "   "
                    echo -e "$rc\033[K"
                elif [ -n "$lc" ]; then
                    printf "  "
                    echo -e "$lc\033[K"
                elif [ -n "$rc" ]; then
                    printf "  %-30s " ""
                    echo -e "$rc\033[K"
                fi
            done
            echo -e "\033[K"
        fi

        echo -e "${BOLD}Refreshes every 5 seconds. Press any key to return to menu...${NC}\033[K"
        
        # Clear any leftover lines below the dashboard content (Erase to End of Display)
        # This only cleans up if the dashboard gets shorter
        if ! tput ed 2>/dev/null; then
            printf "\033[J"
        fi
        
        # Wait 4 seconds for keypress (compensating for processing time)
        # Redirect from /dev/tty ensures it works when the script is piped
        if read -t 4 -n 1 -s < /dev/tty 2>/dev/null; then
            stop_dashboard=1
        fi
    done
    
    echo -ne "\033[?25h" # Show cursor
    # Restore main screen buffer
    tput rmcup 2>/dev/null || true
    trap - SIGINT SIGTERM # Reset traps
}

get_container_stats() {
    # Get CPU and RAM usage across all conduit containers
    # Returns: "CPU_PERCENT RAM_USAGE"
    # Single docker stats call for all containers at once
    local names=""
    for i in $(seq 1 $CONTAINER_COUNT); do
        names+=" $(get_container_name $i)"
    done
    local all_stats=$(timeout 10 docker stats --no-stream --format "{{.CPUPerc}} {{.MemUsage}}" $names 2>/dev/null)
    if [ -z "$all_stats" ]; then
        echo "0% 0MiB"
    elif [ "$CONTAINER_COUNT" -le 1 ]; then
        echo "$all_stats"
    else
        # Single awk to aggregate all container stats at once
        echo "$all_stats" | awk '{
            # CPU: strip % and sum
            cpu = $1; gsub(/%/, "", cpu); total_cpu += cpu + 0
            # Memory used: convert to MiB and sum
            mem = $2; gsub(/[^0-9.]/, "", mem); mem += 0
            if ($2 ~ /GiB/) mem *= 1024
            else if ($2 ~ /KiB/) mem /= 1024
            total_mem += mem
            # Memory limit: take first one
            if (mem_limit == "") mem_limit = $4
            found = 1
        } END {
            if (!found) { print "0% 0MiB"; exit }
            if (total_mem >= 1024) mem_display = sprintf("%.2fGiB", total_mem/1024)
            else mem_display = sprintf("%.1fMiB", total_mem)
            printf "%.2f%% %s / %s\n", total_cpu, mem_display, mem_limit
        }'
    fi
}

get_cpu_cores() {
    local cores=1
    if command -v nproc &>/dev/null; then
        cores=$(nproc)
    elif [ -f /proc/cpuinfo ]; then
        cores=$(grep -c ^processor /proc/cpuinfo)
    fi
    if [ -z "$cores" ] || [ "$cores" -lt 1 ] 2>/dev/null; then echo 1; else echo "$cores"; fi
}

get_system_stats() {
    # Get System CPU (Live Delta) and RAM
    # Returns: "CPU_PERCENT RAM_USED RAM_TOTAL RAM_PCT"
    
    # 1. System CPU (Stateful Average)
    local sys_cpu="0%"
    local cpu_tmp="/tmp/conduit_cpu_state"
    
    if [ -f /proc/stat ]; then
        read -r cpu user nice system idle iowait irq softirq steal guest < /proc/stat
        local total_curr=$((user + nice + system + idle + iowait + irq + softirq + steal))
        local work_curr=$((user + nice + system + irq + softirq + steal))
        
        if [ -f "$cpu_tmp" ]; then
            read -r total_prev work_prev < "$cpu_tmp"
            local total_delta=$((total_curr - total_prev))
            local work_delta=$((work_curr - work_prev))
            
            if [ "$total_delta" -gt 0 ]; then
                local cpu_usage=$(awk -v w="$work_delta" -v t="$total_delta" 'BEGIN { printf "%.1f", w * 100 / t }' 2>/dev/null || echo 0)
                sys_cpu="${cpu_usage}%"
            fi
        else
            sys_cpu="Calc..." # First run calibration
        fi
        
        # Save current state for next run
        echo "$total_curr $work_curr" > "$cpu_tmp"
    else
        sys_cpu="N/A"
    fi
    
    # 2. System RAM (Used, Total, Percentage)
    local sys_ram_used="N/A"
    local sys_ram_total="N/A"
    local sys_ram_pct="N/A"
    
    if command -v free &>/dev/null; then
        # Single free -m call: MiB values for percentage + display
        local free_out=$(free -m 2>/dev/null)
        if [ -n "$free_out" ]; then
            read -r sys_ram_used sys_ram_total sys_ram_pct <<< $(echo "$free_out" | awk '/^Mem:/{
                used_mb=$3; total_mb=$2
                pct = (total_mb > 0) ? (used_mb/total_mb)*100 : 0
                if (total_mb >= 1024) { total_str=sprintf("%.1fGiB", total_mb/1024) } else { total_str=sprintf("%.1fMiB", total_mb) }
                if (used_mb >= 1024) { used_str=sprintf("%.1fGiB", used_mb/1024) } else { used_str=sprintf("%.1fMiB", used_mb) }
                printf "%s %s %.2f%%", used_str, total_str, pct
            }')
        fi
    fi
    
    echo "$sys_cpu $sys_ram_used $sys_ram_total $sys_ram_pct"
}

show_live_stats() {
    # Check if any container is running (single docker ps call)
    local ps_cache=$(docker ps --format '{{.Names}}' 2>/dev/null)
    local any_running=false
    for i in $(seq 1 $CONTAINER_COUNT); do
        local cname=$(get_container_name $i)
        if echo "$ps_cache" | grep -q "^${cname}$"; then
            any_running=true
            break
        fi
    done
    if [ "$any_running" = false ]; then
        print_header
        echo -e "${RED}Conduit is not running!${NC}"
        echo "Start it first with option 6 or 'conduit start'"
        read -n 1 -s -r -p "Press any key to continue..." < /dev/tty 2>/dev/null || true
        return 1
    fi

    if [ "$CONTAINER_COUNT" -le 1 ]; then
        # Single container - stream directly
        echo -e "${CYAN}Streaming live statistics... Press Ctrl+C to return to menu${NC}"
        echo -e "${YELLOW}(showing live logs filtered for [STATS])${NC}"
        echo ""
        trap 'echo -e "\n${CYAN}Returning to menu...${NC}"; return' SIGINT
        if grep --help 2>&1 | grep -q -- --line-buffered; then
            docker logs -f --tail 20 conduit 2>&1 | grep --line-buffered "\[STATS\]"
        else
            docker logs -f --tail 20 conduit 2>&1 | grep "\[STATS\]"
        fi
        trap - SIGINT
    else
        # Multi container - show container picker
        echo ""
        echo -e "${CYAN}Select container to view live stats:${NC}"
        echo ""
        for i in $(seq 1 $CONTAINER_COUNT); do
            local cname=$(get_container_name $i)
            local status="${RED}Stopped${NC}"
            echo "$ps_cache" | grep -q "^${cname}$" && status="${GREEN}Running${NC}"
            echo -e "  ${i}. ${cname}  [${status}]"
        done
        echo ""
        read -p "  Select (1-${CONTAINER_COUNT}): " idx < /dev/tty || true
        if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt "$CONTAINER_COUNT" ]; then
            echo -e "${RED}Invalid selection.${NC}"
            return 1
        fi
        local target=$(get_container_name $idx)
        echo ""
        echo -e "${CYAN}Streaming live statistics from ${target}... Press Ctrl+C to return${NC}"
        echo ""
        trap 'echo -e "\n${CYAN}Returning to menu...${NC}"; return' SIGINT
        if grep --help 2>&1 | grep -q -- --line-buffered; then
            docker logs -f --tail 20 "$target" 2>&1 | grep --line-buffered "\[STATS\]"
        else
            docker logs -f --tail 20 "$target" 2>&1 | grep "\[STATS\]"
        fi
        trap - SIGINT
    fi
}

# format_bytes() - Convert bytes to human-readable format (B, KB, MB, GB)
format_bytes() {
    local bytes=$1

    # Handle empty or zero input
    if [ -z "$bytes" ] || [ "$bytes" -eq 0 ] 2>/dev/null; then
        echo "0 B"
        return
    fi

    # Convert based on size thresholds (using binary units)
    # 1 GB = 1073741824 bytes (1024^3)
    # 1 MB = 1048576 bytes (1024^2)
    # 1 KB = 1024 bytes
    if [ "$bytes" -ge 1073741824 ]; then
        awk "BEGIN {printf \"%.2f GB\", $bytes/1073741824}"
    elif [ "$bytes" -ge 1048576 ]; then
        awk "BEGIN {printf \"%.2f MB\", $bytes/1048576}"
    elif [ "$bytes" -ge 1024 ]; then
        awk "BEGIN {printf \"%.2f KB\", $bytes/1024}"
    else
        echo "$bytes B"
    fi
}

format_number() {
    local n=$1
    if [ -z "$n" ] || [ "$n" -eq 0 ] 2>/dev/null; then
        echo "0"
    elif [ "$n" -ge 1000000 ]; then
        awk "BEGIN {printf \"%.1fM\", $n/1000000}"
    elif [ "$n" -ge 1000 ]; then
        awk "BEGIN {printf \"%.1fK\", $n/1000}"
    else
        echo "$n"
    fi
}

# Background tracker helper
is_tracker_active() {
    if command -v systemctl &>/dev/null; then
        systemctl is-active conduit-tracker.service &>/dev/null
        return $?
    fi
    # Fallback: check if tracker process is running
    pgrep -f "conduit-tracker.sh" &>/dev/null
    return $?
}

# Generate the background tracker script
regenerate_tracker_script() {
    local tracker_script="$INSTALL_DIR/conduit-tracker.sh"
    local persist_dir="$INSTALL_DIR/traffic_stats"
    mkdir -p "$INSTALL_DIR" "$persist_dir"

    cat > "$tracker_script" << 'TRACKER_SCRIPT'
#!/bin/bash
# Psiphon Conduit Background Tracker
set -u

INSTALL_DIR="/opt/conduit"
PERSIST_DIR="/opt/conduit/traffic_stats"
mkdir -p "$PERSIST_DIR"
STATS_FILE="$PERSIST_DIR/cumulative_data"
IPS_FILE="$PERSIST_DIR/cumulative_ips"
SNAPSHOT_FILE="$PERSIST_DIR/tracker_snapshot"
C_START_FILE="$PERSIST_DIR/container_start"
GEOIP_CACHE="$PERSIST_DIR/geoip_cache"

# Detect local IPs
get_local_ips() {
    ip -4 addr show 2>/dev/null | awk '/inet /{split($2,a,"/"); print a[1]}' | tr '\n' '|'
    echo ""
}

# GeoIP lookup with file-based cache
geo_lookup() {
    local ip="$1"
    # Check cache
    if [ -f "$GEOIP_CACHE" ]; then
        local cached=$(grep "^${ip}|" "$GEOIP_CACHE" 2>/dev/null | head -1 | cut -d'|' -f2)
        if [ -n "$cached" ]; then
            echo "$cached"
            return
        fi
    fi
    local country=""
    if command -v geoiplookup &>/dev/null; then
        country=$(geoiplookup "$ip" 2>/dev/null | awk -F: '/Country Edition/{print $2}' | sed 's/^ *//' | cut -d, -f2- | sed 's/^ *//')
    elif command -v mmdblookup &>/dev/null; then
        local mmdb=""
        for f in /usr/share/GeoIP/GeoLite2-Country.mmdb /var/lib/GeoIP/GeoLite2-Country.mmdb; do
            [ -f "$f" ] && mmdb="$f" && break
        done
        if [ -n "$mmdb" ]; then
            country=$(mmdblookup --file "$mmdb" --ip "$ip" country names en 2>/dev/null | grep -o '"[^"]*"' | tr -d '"')
        fi
    fi
    [ -z "$country" ] && country="Unknown"
    # Cache it (limit cache size)
    if [ -f "$GEOIP_CACHE" ]; then
        local cache_lines=$(wc -l < "$GEOIP_CACHE" 2>/dev/null || echo 0)
        if [ "$cache_lines" -gt 10000 ]; then
            tail -5000 "$GEOIP_CACHE" > "$GEOIP_CACHE.tmp" && mv "$GEOIP_CACHE.tmp" "$GEOIP_CACHE"
        fi
    fi
    echo "${ip}|${country}" >> "$GEOIP_CACHE"
    echo "$country"
}

# Check for container restart — reset data if restarted
container_start=$(docker inspect --format='{{.State.StartedAt}}' conduit 2>/dev/null | cut -d'.' -f1)
stored_start=""
[ -f "$C_START_FILE" ] && stored_start=$(cat "$C_START_FILE" 2>/dev/null)
if [ "$container_start" != "$stored_start" ]; then
    echo "$container_start" > "$C_START_FILE"
    # Backup cumulative data before reset
    if [ -s "$STATS_FILE" ] || [ -s "$IPS_FILE" ]; then
        echo "[TRACKER] Container restart detected — backing up tracker data"
        [ -s "$STATS_FILE" ] && cp "$STATS_FILE" "$PERSIST_DIR/cumulative_data.bak"
        [ -s "$IPS_FILE" ] && cp "$IPS_FILE" "$PERSIST_DIR/cumulative_ips.bak"
        [ -s "$GEOIP_CACHE" ] && cp "$GEOIP_CACHE" "$PERSIST_DIR/geoip_cache.bak"
    fi
    rm -f "$STATS_FILE" "$IPS_FILE"
    # Note: Don't clear SNAPSHOT_FILE here — keep stale speed data visible
    # until the first 15-second capture cycle replaces it atomically
    # Restore cumulative data (keep historical totals across restarts)
    if [ -f "$PERSIST_DIR/cumulative_data.bak" ]; then
        cp "$PERSIST_DIR/cumulative_data.bak" "$STATS_FILE"
        cp "$PERSIST_DIR/cumulative_ips.bak" "$IPS_FILE" 2>/dev/null
        echo "[TRACKER] Tracker data restored from backup"
    fi
fi
touch "$STATS_FILE" "$IPS_FILE"

# Detect tcpdump and awk paths
TCPDUMP_BIN=$(command -v tcpdump 2>/dev/null || echo "tcpdump")
AWK_BIN=$(command -v gawk 2>/dev/null || command -v awk 2>/dev/null || echo "awk")

# Detect local IP
LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
[ -z "$LOCAL_IP" ] && LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

# Batch process: resolve GeoIP + merge into cumulative files in bulk
process_batch() {
    local batch="$1"
    local resolved="$PERSIST_DIR/resolved_batch"
    local geo_map="$PERSIST_DIR/geo_map"

    # Step 1: Extract unique IPs and bulk-resolve GeoIP
    # Read cache once, resolve uncached, produce ip|country mapping
    $AWK_BIN -F'|' '{print $2}' "$batch" | sort -u > "$PERSIST_DIR/batch_ips"

    # Build geo mapping: read cache + resolve missing
    > "$geo_map"
    while IFS= read -r ip; do
        [ -z "$ip" ] && continue
        country=""
        if [ -f "$GEOIP_CACHE" ]; then
            country=$(grep "^${ip}|" "$GEOIP_CACHE" 2>/dev/null | head -1 | cut -d'|' -f2)
        fi
        if [ -z "$country" ]; then
            country=$(geo_lookup "$ip")
        fi
        # Strip country code prefix (e.g. "US, United States" -> "United States")
        country=$(echo "$country" | sed 's/^[A-Z][A-Z], //')
        # Normalize
        case "$country" in
            *Iran*) country="Iran - #FreeIran" ;;
            *Moldova*) country="Moldova" ;;
            *Korea*Republic*|*"South Korea"*) country="South Korea" ;;
            *"Russian Federation"*|*Russia*) country="Russia" ;;
            *"Taiwan"*) country="Taiwan" ;;
            *"Venezuela"*) country="Venezuela" ;;
            *"Bolivia"*) country="Bolivia" ;;
            *"Tanzania"*) country="Tanzania" ;;
            *"Viet Nam"*|*Vietnam*) country="Vietnam" ;;
            *"Syrian Arab Republic"*) country="Syria" ;;
        esac
        echo "${ip}|${country}" >> "$geo_map"
    done < "$PERSIST_DIR/batch_ips"

    # Step 2: Single awk pass — merge batch into cumulative_data + write snapshot
    $AWK_BIN -F'|' -v snap="${SNAPSHOT_TMP:-$SNAPSHOT_FILE}" '
        BEGIN { OFMT = "%.0f"; CONVFMT = "%.0f" }
        FILENAME == ARGV[1] { geo[$1] = $2; next }
        FILENAME == ARGV[2] { existing[$1] = $2 "|" $3; next }
        FILENAME == ARGV[3] {
            dir = $1; ip = $2; bytes = $3 + 0
            c = geo[ip]
            if (c == "") c = "Unknown"
            if (dir == "FROM") from_bytes[c] += bytes
            else to_bytes[c] += bytes
            # Also collect snapshot lines
            print dir "|" c "|" bytes "|" ip > snap
            next
        }
        END {
            # Merge existing + new
            for (c in existing) {
                split(existing[c], v, "|")
                f = v[1] + 0; t = v[2] + 0
                f += from_bytes[c] + 0
                t += to_bytes[c] + 0
                print c "|" f "|" t
                delete from_bytes[c]
                delete to_bytes[c]
            }
            # New countries not in existing
            for (c in from_bytes) {
                f = from_bytes[c] + 0
                t = to_bytes[c] + 0
                print c "|" f "|" t
                delete to_bytes[c]
            }
            for (c in to_bytes) {
                print c "|0|" to_bytes[c] + 0
            }
        }
    ' "$geo_map" "$STATS_FILE" "$batch" > "$STATS_FILE.tmp" && mv "$STATS_FILE.tmp" "$STATS_FILE"

    # Step 3: Single awk pass — merge batch IPs into cumulative_ips
    $AWK_BIN -F'|' '
        FILENAME == ARGV[1] { geo[$1] = $2; next }
        FILENAME == ARGV[2] { seen[$0] = 1; print; next }
        FILENAME == ARGV[3] {
            ip = $2; c = geo[ip]
            if (c == "") c = "Unknown"
            key = c "|" ip
            if (!(key in seen)) { seen[key] = 1; print key }
        }
    ' "$geo_map" "$IPS_FILE" "$batch" > "$IPS_FILE.tmp" && mv "$IPS_FILE.tmp" "$IPS_FILE"

    rm -f "$PERSIST_DIR/batch_ips" "$geo_map" "$resolved"
}

# Auto-restart stuck containers (no peers for 2+ hours)
LAST_STUCK_CHECK=0
declare -A CONTAINER_LAST_ACTIVE
declare -A CONTAINER_LAST_RESTART
STUCK_THRESHOLD=7200      # 2 hours in seconds
STUCK_CHECK_INTERVAL=900  # Check every 15 minutes

check_stuck_containers() {
    local now=$(date +%s)
    # Skip if data cap exceeded (containers intentionally stopped)
    if [ -f "$PERSIST_DIR/data_cap_exceeded" ]; then
        return
    fi
    # Find all running conduit containers
    local containers=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^conduit(-[0-9]+)?$')
    [ -z "$containers" ] && return

    for cname in $containers; do
        # Get last 50 lines of logs
        local logs=$(docker logs --tail 50 "$cname" 2>&1)
        local has_stats
        has_stats=$(echo "$logs" | grep -c "\[STATS\]" 2>/dev/null) || true
        has_stats=${has_stats:-0}
        local connected=0
        if [ "$has_stats" -gt 0 ]; then
            local last_stat=$(echo "$logs" | grep "\[STATS\]" | tail -1)
            local parsed=$(echo "$last_stat" | sed -n 's/.*Connected:[[:space:]]*\([0-9]*\).*/\1/p')
            if [ -z "$parsed" ]; then
                # Stats exist but format unrecognized — treat as active
                CONTAINER_LAST_ACTIVE[$cname]=$now
                continue
            fi
            connected=$parsed
        fi

        # If container has peers or stats activity, mark as active
        if [ "$connected" -gt 0 ]; then
            CONTAINER_LAST_ACTIVE[$cname]=$now
            continue
        fi

        # Initialize first-seen time if not tracked yet
        if [ -z "${CONTAINER_LAST_ACTIVE[$cname]:-}" ]; then
            CONTAINER_LAST_ACTIVE[$cname]=$now
            continue
        fi

        # Check if stuck for 2+ hours
        local last_active=${CONTAINER_LAST_ACTIVE[$cname]:-$now}
        local idle_time=$((now - last_active))
        if [ "$idle_time" -ge "$STUCK_THRESHOLD" ]; then
            # Check cooldown — don't restart if restarted within last 2 hours
            local last_restart=${CONTAINER_LAST_RESTART[$cname]:-0}
            if [ $((now - last_restart)) -lt "$STUCK_THRESHOLD" ]; then
                continue
            fi

            # Check container still exists and has been running long enough
            local started=$(docker inspect --format='{{.State.StartedAt}}' "$cname" 2>/dev/null | cut -d'.' -f1)
            if [ -z "$started" ]; then
                # Container no longer exists, clean up tracking
                unset CONTAINER_LAST_ACTIVE[$cname] 2>/dev/null
                unset CONTAINER_LAST_RESTART[$cname] 2>/dev/null
                continue
            fi
            local start_epoch=$(date -d "$started" +%s 2>/dev/null || echo "$now")
            local uptime=$((now - start_epoch))
            if [ "$uptime" -lt "$STUCK_THRESHOLD" ]; then
                continue
            fi

            echo "[TRACKER] Auto-restarting stuck container: $cname (no peers for ${idle_time}s)"
            if docker restart "$cname" >/dev/null 2>&1; then
                CONTAINER_LAST_RESTART[$cname]=$now
                CONTAINER_LAST_ACTIVE[$cname]=$now
                # Send Telegram alert if enabled
                if [ "$TELEGRAM_ENABLED" = "true" ] && [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
                    local safe_cname=$(escape_telegram_markdown "$cname")
                    telegram_send_message "⚠️ *Conduit Alert*
Container ${safe_cname} was stuck (no peers for $((idle_time/3600))h) and has been auto-restarted."
                fi
            fi
        fi
    done
}

# Main capture loop: tcpdump -> awk -> batch process
LAST_BACKUP=0
while true; do
    BATCH_FILE="$PERSIST_DIR/batch_tmp"
    > "$BATCH_FILE"

    while true; do
        if IFS= read -t 60 -r line; then
            if [ "$line" = "SYNC_MARKER" ]; then
                # Process entire batch at once
                if [ -s "$BATCH_FILE" ]; then
                    > "${SNAPSHOT_FILE}.new"
                    SNAPSHOT_TMP="${SNAPSHOT_FILE}.new"
                    if process_batch "$BATCH_FILE" && [ -s "${SNAPSHOT_FILE}.new" ]; then
                        mv -f "${SNAPSHOT_FILE}.new" "$SNAPSHOT_FILE"
                    fi
                fi
                > "$BATCH_FILE"
                # Periodic backup every 3 hours
                NOW=$(date +%s)
                if [ $((NOW - LAST_BACKUP)) -ge 10800 ]; then
                    [ -s "$STATS_FILE" ] && cp "$STATS_FILE" "$PERSIST_DIR/cumulative_data.bak"
                    [ -s "$IPS_FILE" ] && cp "$IPS_FILE" "$PERSIST_DIR/cumulative_ips.bak"
                    LAST_BACKUP=$NOW
                fi
                # Check for stuck containers every 15 minutes
                if [ $((NOW - LAST_STUCK_CHECK)) -ge "$STUCK_CHECK_INTERVAL" ]; then
                    check_stuck_containers
                    LAST_STUCK_CHECK=$NOW
                fi
                continue
            fi
            echo "$line" >> "$BATCH_FILE"
        else
            # read timed out or EOF — check stuck containers even with no traffic
            rc=$?
            if [ $rc -gt 128 ]; then
                # Timeout — no traffic, still check for stuck containers
                NOW=$(date +%s)
                if [ $((NOW - LAST_STUCK_CHECK)) -ge "$STUCK_CHECK_INTERVAL" ]; then
                    check_stuck_containers
                    LAST_STUCK_CHECK=$NOW
                fi
            else
                # EOF — tcpdump exited, break to outer loop to restart
                break
            fi
        fi
    done < <($TCPDUMP_BIN -tt -l -ni any -n -q "(tcp or udp) and not port 22" 2>/dev/null | $AWK_BIN -v local_ip="$LOCAL_IP" '
    BEGIN { last_sync = 0; OFMT = "%.0f"; CONVFMT = "%.0f" }
    {
        # Parse timestamp
        ts = $1 + 0
        if (ts == 0) next

        # Find IP keyword and extract src/dst
        src = ""; dst = ""
        for (i = 1; i <= NF; i++) {
            if ($i == "IP") {
                sf = $(i+1)
                for (j = i+2; j <= NF; j++) {
                    if ($(j-1) == ">") {
                        df = $j
                        gsub(/:$/, "", df)
                        break
                    }
                }
                break
            }
        }
        # Extract IP from IP.port
        if (sf != "") { n=split(sf,p,"."); if(n>=4) src=p[1]"."p[2]"."p[3]"."p[4] }
        if (df != "") { n=split(df,p,"."); if(n>=4) dst=p[1]"."p[2]"."p[3]"."p[4] }

        # Get length
        len = 0
        for (i=1; i<=NF; i++) { if ($i=="length") { len=$(i+1)+0; break } }
        if (len==0) { for (i=NF; i>0; i--) { if ($i ~ /^[0-9]+$/) { len=$i+0; break } } }

        # Skip private IPs
        if (src ~ /^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.|0\.|169\.254\.)/) src=""
        if (dst ~ /^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.|0\.|169\.254\.)/) dst=""

        # Determine direction
        if (src == local_ip && dst != "" && dst != local_ip) {
            to[dst] += len
        } else if (dst == local_ip && src != "" && src != local_ip) {
            from[src] += len
        } else if (src != "" && src != local_ip) {
            from[src] += len
        } else if (dst != "" && dst != local_ip) {
            to[dst] += len
        }

        # Sync every 15 seconds
        if (last_sync == 0) last_sync = ts
        if (ts - last_sync >= 15) {
            for (ip in from) { if (from[ip] > 0) print "FROM|" ip "|" from[ip] }
            for (ip in to) { if (to[ip] > 0) print "TO|" ip "|" to[ip] }
            print "SYNC_MARKER"
            delete from; delete to; last_sync = ts; fflush()
        }
    }')

    # If tcpdump exits, wait and retry
    sleep 5
done
TRACKER_SCRIPT

    chmod +x "$tracker_script"
}

# Setup tracker systemd service
setup_tracker_service() {
    regenerate_tracker_script

    if command -v systemctl &>/dev/null; then
        cat > /etc/systemd/system/conduit-tracker.service << EOF
[Unit]
Description=Conduit Traffic Tracker
After=network.target docker.service
Wants=docker.service

[Service]
Type=simple
ExecStart=/bin/bash $INSTALL_DIR/conduit-tracker.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable conduit-tracker.service 2>/dev/null || true
        systemctl restart conduit-tracker.service 2>/dev/null || true
    fi
}

# Stop tracker service
stop_tracker_service() {
    if command -v systemctl &>/dev/null; then
        systemctl stop conduit-tracker.service 2>/dev/null || true
    else
        pkill -f "conduit-tracker.sh" 2>/dev/null || true
    fi
}

# Advanced Statistics page with 15-second soft refresh
show_advanced_stats() {
    local persist_dir="$INSTALL_DIR/traffic_stats"
    local exit_stats=0
    trap 'exit_stats=1' SIGINT SIGTERM

    local L="══════════════════════════════════════════════════════════════"
    local D="──────────────────────────────────────────────────────────────"

    # Enter alternate screen buffer
    tput smcup 2>/dev/null || true
    echo -ne "\033[?25l"
    printf "\033[2J\033[H"

    local cycle_start=$(date +%s)
    local last_refresh=0

    while [ "$exit_stats" -eq 0 ]; do
        local now=$(date +%s)
        local term_height=$(stty size </dev/tty 2>/dev/null | awk '{print $1}')
        [ -z "$term_height" ] || [ "$term_height" -lt 10 ] 2>/dev/null && term_height=$(tput lines 2>/dev/null || echo "${LINES:-24}")

        local cycle_elapsed=$(( (now - cycle_start) % 15 ))
        local time_until_next=$((15 - cycle_elapsed))

        # Build progress bar
        local bar=""
        for ((i=0; i<cycle_elapsed; i++)); do bar+="●"; done
        for ((i=cycle_elapsed; i<15; i++)); do bar+="○"; done

        # Refresh data every 15 seconds or first run
        if [ $((now - last_refresh)) -ge 15 ] || [ "$last_refresh" -eq 0 ]; then
            last_refresh=$now
            cycle_start=$now

            printf "\033[H"

            echo -e "${CYAN}╔${L}${NC}\033[K"
            echo -e "${CYAN}║${NC}  ${BOLD}ADVANCED STATISTICS${NC}        ${DIM}[q] Back  Auto-refresh${NC}\033[K"
            echo -e "${CYAN}╠${L}${NC}\033[K"

            # Container stats - aggregate from all containers
            local docker_ps_cache=$(docker ps --format '{{.Names}}' 2>/dev/null)
            local container_count=0
            local total_cpu=0 total_conn=0
            local total_up_bytes=0 total_down_bytes=0
            local total_mem_mib=0 first_mem_limit=""

            echo -e "${CYAN}║${NC} ${GREEN}CONTAINER${NC}  ${DIM}|${NC}  ${YELLOW}NETWORK${NC}  ${DIM}|${NC}  ${MAGENTA}TRACKER${NC}\033[K"

            # Fetch docker stats and all container logs in parallel
            local adv_running_names=""
            local _adv_tmpdir=$(mktemp -d /tmp/.conduit_adv.XXXXXX)
            # mktemp already created the directory
            for ci in $(seq 1 $CONTAINER_COUNT); do
                local cname=$(get_container_name $ci)
                if echo "$docker_ps_cache" | grep -q "^${cname}$"; then
                    adv_running_names+=" $cname"
                    ( docker logs --tail 30 "$cname" 2>&1 | grep "\[STATS\]" | tail -1 > "$_adv_tmpdir/logs_${ci}" ) &
                fi
            done
            local adv_all_stats=""
            if [ -n "$adv_running_names" ]; then
                ( timeout 10 docker stats --no-stream --format "{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}" $adv_running_names > "$_adv_tmpdir/stats" 2>/dev/null ) &
            fi
            wait
            [ -f "$_adv_tmpdir/stats" ] && adv_all_stats=$(cat "$_adv_tmpdir/stats")

            for ci in $(seq 1 $CONTAINER_COUNT); do
                local cname=$(get_container_name $ci)
                if echo "$docker_ps_cache" | grep -q "^${cname}$"; then
                    container_count=$((container_count + 1))

                    local stats=$(echo "$adv_all_stats" | grep "^${cname}|" 2>/dev/null)
                    local cpu=$(echo "$stats" | cut -d'|' -f2 | tr -d '%')
                    [[ "$cpu" =~ ^[0-9.]+$ ]] && total_cpu=$(awk -v a="$total_cpu" -v b="$cpu" 'BEGIN{printf "%.2f", a+b}')

                    local cmem_str=$(echo "$stats" | cut -d'|' -f3 | awk '{print $1}')
                    local cmem_val=$(echo "$cmem_str" | sed 's/[^0-9.]//g')
                    local cmem_unit=$(echo "$cmem_str" | sed 's/[0-9.]//g')
                    if [[ "$cmem_val" =~ ^[0-9.]+$ ]]; then
                        case "$cmem_unit" in
                            GiB) cmem_val=$(awk -v v="$cmem_val" 'BEGIN{printf "%.2f", v*1024}') ;;
                            KiB) cmem_val=$(awk -v v="$cmem_val" 'BEGIN{printf "%.2f", v/1024}') ;;
                        esac
                        total_mem_mib=$(awk -v a="$total_mem_mib" -v b="$cmem_val" 'BEGIN{printf "%.2f", a+b}')
                    fi
                    [ -z "$first_mem_limit" ] && first_mem_limit=$(echo "$stats" | cut -d'|' -f3 | awk -F'/' '{print $2}' | xargs)

                    local logs=""
                    [ -f "$_adv_tmpdir/logs_${ci}" ] && logs=$(cat "$_adv_tmpdir/logs_${ci}")
                    local conn=$(echo "$logs" | sed -n 's/.*Connected:[[:space:]]*\([0-9]*\).*/\1/p')
                    [[ "$conn" =~ ^[0-9]+$ ]] && total_conn=$((total_conn + conn))

                    # Parse upload/download to bytes
                    local up_raw=$(echo "$logs" | sed -n 's/.*Up:[[:space:]]*\([^|]*\).*/\1/p' | xargs)
                    local down_raw=$(echo "$logs" | sed -n 's/.*Down:[[:space:]]*\([^|]*\).*/\1/p' | xargs)
                    if [ -n "$up_raw" ]; then
                        local up_val=$(echo "$up_raw" | sed 's/[^0-9.]//g')
                        local up_unit=$(echo "$up_raw" | sed 's/[0-9. ]//g')
                        if [[ "$up_val" =~ ^[0-9.]+$ ]]; then
                            case "$up_unit" in
                                GB) total_up_bytes=$(awk -v a="$total_up_bytes" -v v="$up_val" 'BEGIN{printf "%.0f", a+v*1073741824}') ;;
                                MB) total_up_bytes=$(awk -v a="$total_up_bytes" -v v="$up_val" 'BEGIN{printf "%.0f", a+v*1048576}') ;;
                                KB) total_up_bytes=$(awk -v a="$total_up_bytes" -v v="$up_val" 'BEGIN{printf "%.0f", a+v*1024}') ;;
                                B)  total_up_bytes=$(awk -v a="$total_up_bytes" -v v="$up_val" 'BEGIN{printf "%.0f", a+v}') ;;
                            esac
                        fi
                    fi
                    if [ -n "$down_raw" ]; then
                        local down_val=$(echo "$down_raw" | sed 's/[^0-9.]//g')
                        local down_unit=$(echo "$down_raw" | sed 's/[0-9. ]//g')
                        if [[ "$down_val" =~ ^[0-9.]+$ ]]; then
                            case "$down_unit" in
                                GB) total_down_bytes=$(awk -v a="$total_down_bytes" -v v="$down_val" 'BEGIN{printf "%.0f", a+v*1073741824}') ;;
                                MB) total_down_bytes=$(awk -v a="$total_down_bytes" -v v="$down_val" 'BEGIN{printf "%.0f", a+v*1048576}') ;;
                                KB) total_down_bytes=$(awk -v a="$total_down_bytes" -v v="$down_val" 'BEGIN{printf "%.0f", a+v*1024}') ;;
                                B)  total_down_bytes=$(awk -v a="$total_down_bytes" -v v="$down_val" 'BEGIN{printf "%.0f", a+v}') ;;
                            esac
                        fi
                    fi
                fi
            done
            rm -rf "$_adv_tmpdir"

            if [ "$container_count" -gt 0 ]; then
                local cpu_display="${total_cpu}%"
                [ "$container_count" -gt 1 ] && cpu_display="${total_cpu}% (${container_count} containers)"
                local mem_display="${total_mem_mib}MiB"
                if [ -n "$first_mem_limit" ] && [ "$container_count" -gt 1 ]; then
                    mem_display="${total_mem_mib}MiB (${container_count}x ${first_mem_limit})"
                elif [ -n "$first_mem_limit" ]; then
                    mem_display="${total_mem_mib}MiB / ${first_mem_limit}"
                fi
                printf "${CYAN}║${NC} CPU: ${YELLOW}%s${NC}  Mem: ${YELLOW}%s${NC}  Clients: ${GREEN}%d${NC}\033[K\n" "$cpu_display" "$mem_display" "$total_conn"
                local up_display=$(format_bytes "$total_up_bytes")
                local down_display=$(format_bytes "$total_down_bytes")
                printf "${CYAN}║${NC} Upload: ${GREEN}%s${NC}    Download: ${GREEN}%s${NC}\033[K\n" "$up_display" "$down_display"
            else
                echo -e "${CYAN}║${NC} ${RED}No Containers Running${NC}\033[K"
            fi

            # Network info
            local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
            local iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
            printf "${CYAN}║${NC} Net: ${GREEN}%s${NC} (%s)\033[K\n" "${ip:-N/A}" "${iface:-?}"

            echo -e "${CYAN}╠${D}${NC}\033[K"

            # Load tracker data
            local total_active=0 total_in=0 total_out=0
            unset cips cbw_in cbw_out
            declare -A cips cbw_in cbw_out

            if [ -s "$persist_dir/cumulative_data" ]; then
                while IFS='|' read -r country from_bytes to_bytes; do
                    [ -z "$country" ] && continue
                    from_bytes=$(printf '%.0f' "${from_bytes:-0}" 2>/dev/null) || from_bytes=0
                    to_bytes=$(printf '%.0f' "${to_bytes:-0}" 2>/dev/null) || to_bytes=0
                    cbw_in["$country"]=$from_bytes
                    cbw_out["$country"]=$to_bytes
                    total_in=$((total_in + from_bytes))
                    total_out=$((total_out + to_bytes))
                done < "$persist_dir/cumulative_data"
            fi

            if [ -s "$persist_dir/cumulative_ips" ]; then
                while IFS='|' read -r country ip_addr; do
                    [ -z "$country" ] && continue
                    cips["$country"]=$((${cips["$country"]:-0} + 1))
                    total_active=$((total_active + 1))
                done < "$persist_dir/cumulative_ips"
            fi

            local tstat="${RED}Off${NC}"; is_tracker_active && tstat="${GREEN}On${NC}"
            printf "${CYAN}║${NC} Tracker: %b  Clients: ${GREEN}%s${NC}  Unique IPs: ${YELLOW}%s${NC}  In: ${GREEN}%s${NC}  Out: ${YELLOW}%s${NC}\033[K\n" "$tstat" "$(format_number $total_conn)" "$(format_number $total_active)" "$(format_bytes $total_in)" "$(format_bytes $total_out)"

            # TOP 5 by Unique IPs (from tracker)
            echo -e "${CYAN}╠─── ${CYAN}TOP 5 BY UNIQUE IPs${NC} ${DIM}(tracked)${NC}\033[K"
            local total_traffic=$((total_in + total_out))
            if [ "$total_conn" -gt 0 ] && [ "$total_active" -gt 0 ]; then
                for c in "${!cips[@]}"; do echo "${cips[$c]}|$c"; done | sort -t'|' -k1 -nr | head -7 | while IFS='|' read -r active_cnt country; do
                    local peers=$(( (active_cnt * total_conn) / total_active ))
                    [ "$peers" -eq 0 ] && [ "$active_cnt" -gt 0 ] && peers=1
                    local pct=$((peers * 100 / total_conn))
                    local blen=$((pct / 8)); [ "$blen" -lt 1 ] && blen=1; [ "$blen" -gt 14 ] && blen=14
                    local bfill=""; for ((i=0; i<blen; i++)); do bfill+="█"; done
                    printf "${CYAN}║${NC} %-16.16s %3d%% ${CYAN}%-14s${NC} (%s IPs)\033[K\n" "$country" "$pct" "$bfill" "$(format_number $peers)"
                done
            elif [ "$total_traffic" -gt 0 ]; then
                for c in "${!cbw_in[@]}"; do
                    local bytes=$(( ${cbw_in[$c]:-0} + ${cbw_out[$c]:-0} ))
                    echo "${bytes}|$c"
                done | sort -t'|' -k1 -nr | head -7 | while IFS='|' read -r bytes country; do
                    local pct=$((bytes * 100 / total_traffic))
                    local blen=$((pct / 8)); [ "$blen" -lt 1 ] && blen=1; [ "$blen" -gt 14 ] && blen=14
                    local bfill=""; for ((i=0; i<blen; i++)); do bfill+="█"; done
                    printf "${CYAN}║${NC} %-16.16s %3d%% ${CYAN}%-14s${NC} (%9s)\033[K\n" "$country" "$pct" "$bfill" "by traffic"
                done
            else
                echo -e "${CYAN}║${NC} No data yet\033[K"
            fi

            # TOP 5 by Download
            echo -e "${CYAN}╠─── ${GREEN}TOP 5 BY DOWNLOAD${NC} ${DIM}(inbound traffic)${NC}\033[K"
            if [ "$total_in" -gt 0 ]; then
                for c in "${!cbw_in[@]}"; do echo "${cbw_in[$c]}|$c"; done | sort -t'|' -k1 -nr | head -7 | while IFS='|' read -r bytes country; do
                    local pct=$((bytes * 100 / total_in))
                    local blen=$((pct / 8)); [ "$blen" -lt 1 ] && blen=1; [ "$blen" -gt 14 ] && blen=14
                    local bfill=""; for ((i=0; i<blen; i++)); do bfill+="█"; done
                    printf "${CYAN}║${NC} %-16.16s %3d%% ${GREEN}%-14s${NC} (%9s)\033[K\n" "$country" "$pct" "$bfill" "$(format_bytes $bytes)"
                done
            else
                echo -e "${CYAN}║${NC} No data yet\033[K"
            fi

            # TOP 5 by Upload
            echo -e "${CYAN}╠─── ${YELLOW}TOP 5 BY UPLOAD${NC} ${DIM}(outbound traffic)${NC}\033[K"
            if [ "$total_out" -gt 0 ]; then
                for c in "${!cbw_out[@]}"; do echo "${cbw_out[$c]}|$c"; done | sort -t'|' -k1 -nr | head -7 | while IFS='|' read -r bytes country; do
                    local pct=$((bytes * 100 / total_out))
                    local blen=$((pct / 8)); [ "$blen" -lt 1 ] && blen=1; [ "$blen" -gt 14 ] && blen=14
                    local bfill=""; for ((i=0; i<blen; i++)); do bfill+="█"; done
                    printf "${CYAN}║${NC} %-16.16s %3d%% ${YELLOW}%-14s${NC} (%9s)\033[K\n" "$country" "$pct" "$bfill" "$(format_bytes $bytes)"
                done
            else
                echo -e "${CYAN}║${NC} No data yet\033[K"
            fi

            echo -e "${CYAN}╚${L}${NC}\033[K"
            printf "\033[J"
        fi

        # Progress bar at bottom
        printf "\033[${term_height};1H\033[K"
        printf "[${YELLOW}${bar}${NC}] Next refresh in %2ds  ${DIM}[q] Back${NC}" "$time_until_next"

        if read -t 1 -n 1 -s key < /dev/tty 2>/dev/null; then
            case "$key" in
                q|Q) exit_stats=1 ;;
            esac
        fi
    done

    echo -ne "\033[?25h"
    tput rmcup 2>/dev/null || true
    trap - SIGINT SIGTERM
}

# show_peers() - Live peer traffic by country using tcpdump + GeoIP
show_peers() {
    local stop_peers=0
    trap 'stop_peers=1' SIGINT SIGTERM

    local persist_dir="$INSTALL_DIR/traffic_stats"

    # Ensure tracker is running
    if ! is_tracker_active; then
        setup_tracker_service 2>/dev/null || true
    # IP access control / traffic management service
    setup_ipmgmt_service 2>/dev/null || true
    fi

    tput smcup 2>/dev/null || true
    echo -ne "\033[?25l"
    printf "\033[2J\033[H"

    local EL="\033[K"
    local cycle_start=$(date +%s)
    local last_refresh=0

    while [ $stop_peers -eq 0 ]; do
        local now=$(date +%s)
        local term_height=$(stty size </dev/tty 2>/dev/null | awk '{print $1}')
        [ -z "$term_height" ] || [ "$term_height" -lt 10 ] 2>/dev/null && term_height=$(tput lines 2>/dev/null || echo "${LINES:-24}")
        local cycle_elapsed=$(( (now - cycle_start) % 15 ))
        local time_left=$((15 - cycle_elapsed))

        # Progress bar
        local bar=""
        for ((i=0; i<cycle_elapsed; i++)); do bar+="●"; done
        for ((i=cycle_elapsed; i<15; i++)); do bar+="○"; done

        # Refresh data every 15 seconds or first run
        if [ $((now - last_refresh)) -ge 15 ] || [ "$last_refresh" -eq 0 ]; then
            last_refresh=$now
            cycle_start=$now

            printf "\033[H"

            echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════╗${NC}${EL}"
            echo -e "${CYAN}║${NC}  ${BOLD}LIVE PEER TRAFFIC BY COUNTRY${NC}                     ${DIM}[q] Back${NC}  ${EL}"
            echo -e "${CYAN}╠══════════════════════════════════════════════════════════════════════╣${NC}${EL}"
            printf "${CYAN}║${NC} Last Update: %-42s ${GREEN}[LIVE]${NC}${EL}\n" "$(date +%H:%M:%S)"
            echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════╝${NC}${EL}"
            echo -e "${EL}"

            # Load tracker data
            unset cumul_from cumul_to total_ips_count 2>/dev/null
            declare -A cumul_from cumul_to total_ips_count

            local grand_in=0 grand_out=0

            if [ -s "$persist_dir/cumulative_data" ]; then
                while IFS='|' read -r c f t; do
                    [ -z "$c" ] && continue
                    [[ "$c" == *"can't"* || "$c" == *"error"* ]] && continue
                    f=$(printf '%.0f' "${f:-0}" 2>/dev/null) || f=0
                    t=$(printf '%.0f' "${t:-0}" 2>/dev/null) || t=0
                    cumul_from["$c"]=$f
                    cumul_to["$c"]=$t
                    grand_in=$((grand_in + f))
                    grand_out=$((grand_out + t))
                done < "$persist_dir/cumulative_data"
            fi

            if [ -s "$persist_dir/cumulative_ips" ]; then
                while IFS='|' read -r c ip; do
                    [ -z "$c" ] && continue
                    [[ "$c" == *"can't"* || "$c" == *"error"* ]] && continue
                    total_ips_count["$c"]=$((${total_ips_count["$c"]:-0} + 1))
                done < "$persist_dir/cumulative_ips"
            fi

            # Get actual connected clients from docker logs (parallel)
            local total_clients=0
            local docker_ps_cache=$(docker ps --format '{{.Names}}' 2>/dev/null)
            local _peer_tmpdir=$(mktemp -d /tmp/.conduit_peer.XXXXXX)
            # mktemp already created the directory
            for ci in $(seq 1 $CONTAINER_COUNT); do
                local cname=$(get_container_name $ci)
                if echo "$docker_ps_cache" | grep -q "^${cname}$"; then
                    ( docker logs --tail 30 "$cname" 2>&1 | grep "\[STATS\]" | tail -1 > "$_peer_tmpdir/logs_${ci}" ) &
                fi
            done
            wait
            for ci in $(seq 1 $CONTAINER_COUNT); do
                if [ -f "$_peer_tmpdir/logs_${ci}" ]; then
                    local logs=$(cat "$_peer_tmpdir/logs_${ci}")
                    local conn=$(echo "$logs" | sed -n 's/.*Connected:[[:space:]]*\([0-9]*\).*/\1/p')
                    [[ "$conn" =~ ^[0-9]+$ ]] && total_clients=$((total_clients + conn))
                fi
            done
            rm -rf "$_peer_tmpdir"

            echo -e "${EL}"

            # Parse snapshot for speed and country distribution
            unset snap_from_bytes snap_to_bytes snap_from_ips snap_to_ips 2>/dev/null
            declare -A snap_from_bytes snap_to_bytes snap_from_ips snap_to_ips
            local snap_total_from_ips=0 snap_total_to_ips=0
            if [ -s "$persist_dir/tracker_snapshot" ]; then
                while IFS='|' read -r dir c bytes ip; do
                    [ -z "$c" ] && continue
                    [[ "$c" == *"can't"* || "$c" == *"error"* ]] && continue
                    bytes=$(printf '%.0f' "${bytes:-0}" 2>/dev/null) || bytes=0
                    if [ "$dir" = "FROM" ]; then
                        snap_from_bytes["$c"]=$(( ${snap_from_bytes["$c"]:-0} + bytes ))
                        snap_from_ips["$c|$ip"]=1
                    elif [ "$dir" = "TO" ]; then
                        snap_to_bytes["$c"]=$(( ${snap_to_bytes["$c"]:-0} + bytes ))
                        snap_to_ips["$c|$ip"]=1
                    fi
                done < "$persist_dir/tracker_snapshot"
            fi

            # Count unique snapshot IPs per country + totals
            unset snap_from_ip_cnt snap_to_ip_cnt 2>/dev/null
            declare -A snap_from_ip_cnt snap_to_ip_cnt
            for k in "${!snap_from_ips[@]}"; do
                local sc="${k%%|*}"
                snap_from_ip_cnt["$sc"]=$(( ${snap_from_ip_cnt["$sc"]:-0} + 1 ))
                snap_total_from_ips=$((snap_total_from_ips + 1))
            done
            for k in "${!snap_to_ips[@]}"; do
                local sc="${k%%|*}"
                snap_to_ip_cnt["$sc"]=$(( ${snap_to_ip_cnt["$sc"]:-0} + 1 ))
                snap_total_to_ips=$((snap_total_to_ips + 1))
            done

            # TOP 10 TRAFFIC FROM (peers connecting to you)
            echo -e "${GREEN}${BOLD} 📥 TOP 10 TRAFFIC FROM ${NC}${DIM}(peers connecting to you)${NC}${EL}"
            echo -e "${EL}"
            printf " ${BOLD}%-26s %10s %12s  %s${NC}${EL}\n" "Country" "Total" "Speed" "Clients"
            echo -e "${EL}"
            if [ "$grand_in" -gt 0 ]; then
                while IFS='|' read -r bytes country; do
                    [ -z "$country" ] && continue
                    local snap_b=${snap_from_bytes[$country]:-0}
                    local speed_val=$((snap_b / 15))
                    local speed_str=$(format_bytes $speed_val)
                    local ips_all=${total_ips_count[$country]:-0}
                    # Estimate clients per country using snapshot distribution
                    local snap_cnt=${snap_from_ip_cnt[$country]:-0}
                    local est_clients=0
                    if [ "$snap_total_from_ips" -gt 0 ] && [ "$snap_cnt" -gt 0 ]; then
                        est_clients=$(( (snap_cnt * total_clients) / snap_total_from_ips ))
                        [ "$est_clients" -eq 0 ] && [ "$snap_cnt" -gt 0 ] && est_clients=1
                    fi
                    printf " ${GREEN}%-26.26s${NC} %10s %10s/s  %s${EL}\n" "$country" "$(format_bytes $bytes)" "$speed_str" "$(format_number $est_clients)"
                done < <(for c in "${!cumul_from[@]}"; do echo "${cumul_from[$c]:-0}|$c"; done | sort -t'|' -k1 -nr | head -10)
            else
                echo -e " ${DIM}Waiting for data...${NC}${EL}"
            fi
            echo -e "${EL}"

            # TOP 10 TRAFFIC TO (data sent to peers)
            echo -e "${YELLOW}${BOLD} 📤 TOP 10 TRAFFIC TO ${NC}${DIM}(data sent to peers)${NC}${EL}"
            echo -e "${EL}"
            printf " ${BOLD}%-26s %10s %12s  %s${NC}${EL}\n" "Country" "Total" "Speed" "Clients"
            echo -e "${EL}"
            if [ "$grand_out" -gt 0 ]; then
                while IFS='|' read -r bytes country; do
                    [ -z "$country" ] && continue
                    local snap_b=${snap_to_bytes[$country]:-0}
                    local speed_val=$((snap_b / 15))
                    local speed_str=$(format_bytes $speed_val)
                    local ips_all=${total_ips_count[$country]:-0}
                    local snap_cnt=${snap_to_ip_cnt[$country]:-0}
                    local est_clients=0
                    if [ "$snap_total_to_ips" -gt 0 ] && [ "$snap_cnt" -gt 0 ]; then
                        est_clients=$(( (snap_cnt * total_clients) / snap_total_to_ips ))
                        [ "$est_clients" -eq 0 ] && [ "$snap_cnt" -gt 0 ] && est_clients=1
                    fi
                    printf " ${YELLOW}%-26.26s${NC} %10s %10s/s  %s${EL}\n" "$country" "$(format_bytes $bytes)" "$speed_str" "$(format_number $est_clients)"
                done < <(for c in "${!cumul_to[@]}"; do echo "${cumul_to[$c]:-0}|$c"; done | sort -t'|' -k1 -nr | head -10)
            else
                echo -e " ${DIM}Waiting for data...${NC}${EL}"
            fi

            echo -e "${EL}"
            printf "\033[J"
        fi

        # Progress bar at bottom
        printf "\033[${term_height};1H${EL}"
        printf "[${YELLOW}${bar}${NC}] Next refresh in %2ds  ${DIM}[q] Back${NC}" "$time_left"

        if read -t 1 -n 1 -s key < /dev/tty 2>/dev/null; then
            case "$key" in q|Q) stop_peers=1 ;; esac
        fi
    done
    echo -ne "\033[?25h"
    tput rmcup 2>/dev/null || true
    rm -f /tmp/conduit_peers_sorted
    trap - SIGINT SIGTERM
}

get_net_speed() {
    # Calculate System Network Speed (Active 0.5s Sample)
    # Returns: "RX_MBPS TX_MBPS"
    local iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5}')
    [ -z "$iface" ] && iface=$(ip route list default 2>/dev/null | awk '{print $5}')
    
    if [ -n "$iface" ] && [ -f "/sys/class/net/$iface/statistics/rx_bytes" ]; then
        local rx1=$(cat /sys/class/net/$iface/statistics/rx_bytes)
        local tx1=$(cat /sys/class/net/$iface/statistics/tx_bytes)
        
        sleep 0.5
        
        local rx2=$(cat /sys/class/net/$iface/statistics/rx_bytes)
        local tx2=$(cat /sys/class/net/$iface/statistics/tx_bytes)
        
        # Calculate Delta (Bytes)
        local rx_delta=$((rx2 - rx1))
        local tx_delta=$((tx2 - tx1))
        
        # Convert to Mbps: (bytes * 8 bits) / (0.5 sec * 1,000,000)
        # Formula simplified: bytes * 16 / 1000000
        
        local rx_mbps=$(awk -v b="$rx_delta" 'BEGIN { printf "%.2f", (b * 16) / 1000000 }')
        local tx_mbps=$(awk -v b="$tx_delta" 'BEGIN { printf "%.2f", (b * 16) / 1000000 }')
        
        echo "$rx_mbps $tx_mbps"
    else
        echo "0.00 0.00"
    fi
}

show_status() {
    local mode="${1:-normal}" # 'live' mode adds line clearing
    local EL=""
    if [ "$mode" == "live" ]; then
        EL="\033[K" # Erase Line escape code
    fi

    echo ""

    
    # Cache docker ps output once
    local docker_ps_cache=$(docker ps 2>/dev/null)

    # Count running containers and cache per-container stats
    local running_count=0
    declare -A _c_running _c_conn _c_cing _c_up _c_down
    local total_connecting=0
    local total_connected=0
    local uptime=""

    # Fetch all container logs in parallel
    local _st_tmpdir=$(mktemp -d /tmp/.conduit_st.XXXXXX)
    # mktemp already created the directory
    for i in $(seq 1 $CONTAINER_COUNT); do
        local cname=$(get_container_name $i)
        _c_running[$i]=false
        _c_conn[$i]="0"
        _c_cing[$i]="0"
        _c_up[$i]=""
        _c_down[$i]=""

        if echo "$docker_ps_cache" | grep -q "[[:space:]]${cname}$"; then
            _c_running[$i]=true
            running_count=$((running_count + 1))
            ( docker logs --tail 30 "$cname" 2>&1 | grep "\[STATS\]" | tail -1 > "$_st_tmpdir/logs_${i}" ) &
        fi
    done
    wait

    for i in $(seq 1 $CONTAINER_COUNT); do
        if [ "${_c_running[$i]}" = true ] && [ -f "$_st_tmpdir/logs_${i}" ]; then
            local logs=$(cat "$_st_tmpdir/logs_${i}")
            if [ -n "$logs" ]; then
                IFS='|' read -r c_connecting c_connected c_up_val c_down_val c_uptime_val <<< $(echo "$logs" | awk '{
                    cing=0; conn=0; up=""; down=""; ut=""
                    for(j=1;j<=NF;j++){
                        if($j=="Connecting:") cing=$(j+1)+0
                        else if($j=="Connected:") conn=$(j+1)+0
                        else if($j=="Up:"){for(k=j+1;k<=NF;k++){if($k=="|"||$k~/Down:/)break; up=up (up?" ":"") $k}}
                        else if($j=="Down:"){for(k=j+1;k<=NF;k++){if($k=="|"||$k~/Uptime:/)break; down=down (down?" ":"") $k}}
                        else if($j=="Uptime:"){for(k=j+1;k<=NF;k++){ut=ut (ut?" ":"") $k}}
                    }
                    printf "%d|%d|%s|%s|%s", cing, conn, up, down, ut
                }')
                _c_conn[$i]="${c_connected:-0}"
                _c_cing[$i]="${c_connecting:-0}"
                _c_up[$i]="${c_up_val}"
                _c_down[$i]="${c_down_val}"
                total_connecting=$((total_connecting + ${c_connecting:-0}))
                total_connected=$((total_connected + ${c_connected:-0}))
                if [ -z "$uptime" ]; then
                    uptime="${c_uptime_val}"
                fi
            fi
        fi
    done
    rm -rf "$_st_tmpdir"
    local connecting=$total_connecting
    local connected=$total_connected
    # Export for parent function to reuse (avoids duplicate docker logs calls)
    _total_connected=$total_connected

    # Aggregate upload/download across all containers
    local upload=""
    local download=""
    local total_up_bytes=0
    local total_down_bytes=0
    for i in $(seq 1 $CONTAINER_COUNT); do
        if [ -n "${_c_up[$i]}" ]; then
            local bytes=$(echo "${_c_up[$i]}" | awk '{
                val=$1; unit=toupper($2)
                if (unit ~ /^KB/) val*=1024
                else if (unit ~ /^MB/) val*=1048576
                else if (unit ~ /^GB/) val*=1073741824
                else if (unit ~ /^TB/) val*=1099511627776
                printf "%.0f", val
            }')
            total_up_bytes=$((total_up_bytes + ${bytes:-0}))
        fi
        if [ -n "${_c_down[$i]}" ]; then
            local bytes=$(echo "${_c_down[$i]}" | awk '{
                val=$1; unit=toupper($2)
                if (unit ~ /^KB/) val*=1024
                else if (unit ~ /^MB/) val*=1048576
                else if (unit ~ /^GB/) val*=1073741824
                else if (unit ~ /^TB/) val*=1099511627776
                printf "%.0f", val
            }')
            total_down_bytes=$((total_down_bytes + ${bytes:-0}))
        fi
    done
    if [ "$total_up_bytes" -gt 0 ]; then
        upload=$(awk -v b="$total_up_bytes" 'BEGIN {
            if (b >= 1099511627776) printf "%.2f TB", b/1099511627776
            else if (b >= 1073741824) printf "%.2f GB", b/1073741824
            else if (b >= 1048576) printf "%.2f MB", b/1048576
            else if (b >= 1024) printf "%.2f KB", b/1024
            else printf "%d B", b
        }')
    fi
    if [ "$total_down_bytes" -gt 0 ]; then
        download=$(awk -v b="$total_down_bytes" 'BEGIN {
            if (b >= 1099511627776) printf "%.2f TB", b/1099511627776
            else if (b >= 1073741824) printf "%.2f GB", b/1073741824
            else if (b >= 1048576) printf "%.2f MB", b/1048576
            else if (b >= 1024) printf "%.2f KB", b/1024
            else printf "%d B", b
        }')
    fi

    if [ "$running_count" -gt 0 ]; then

        # Run all 3 resource stat calls in parallel
        local _rs_tmpdir=$(mktemp -d /tmp/.conduit_rs.XXXXXX)
        # mktemp already created the directory
        ( get_container_stats > "$_rs_tmpdir/cstats" ) &
        ( get_system_stats > "$_rs_tmpdir/sys" ) &
        ( get_net_speed > "$_rs_tmpdir/net" ) &
        wait

        local stats=$(cat "$_rs_tmpdir/cstats" 2>/dev/null)
        local sys_stats=$(cat "$_rs_tmpdir/sys" 2>/dev/null)
        local net_speed=$(cat "$_rs_tmpdir/net" 2>/dev/null)
        rm -rf "$_rs_tmpdir"

        # Normalize App CPU (Docker % / Cores)
        local raw_app_cpu=$(echo "$stats" | awk '{print $1}' | tr -d '%')
        local num_cores=$(get_cpu_cores)
        local app_cpu="0%"
        local app_cpu_display=""

        if [[ "$raw_app_cpu" =~ ^[0-9.]+$ ]]; then
             app_cpu=$(awk -v cpu="$raw_app_cpu" -v cores="$num_cores" 'BEGIN {printf "%.2f%%", cpu / cores}')
             if [ "$num_cores" -gt 1 ]; then
                 app_cpu_display="${app_cpu} (${raw_app_cpu}% vCPU)"
             else
                 app_cpu_display="${app_cpu}"
             fi
        else
             app_cpu="${raw_app_cpu}%"
             app_cpu_display="${app_cpu}"
        fi

        # Keep full "Used / Limit" string for App RAM
        local app_ram=$(echo "$stats" | awk '{print $2, $3, $4}')

        local sys_cpu=$(echo "$sys_stats" | awk '{print $1}')
        local sys_ram_used=$(echo "$sys_stats" | awk '{print $2}')
        local sys_ram_total=$(echo "$sys_stats" | awk '{print $3}')
        local sys_ram_pct=$(echo "$sys_stats" | awk '{print $4}')

        local rx_mbps=$(echo "$net_speed" | awk '{print $1}')
        local tx_mbps=$(echo "$net_speed" | awk '{print $2}')
        local net_display="↓ ${rx_mbps} Mbps  ↑ ${tx_mbps} Mbps"
        
        if [ -n "$upload" ] || [ "$connected" -gt 0 ] || [ "$connecting" -gt 0 ]; then
            local status_line="${BOLD}Status:${NC} ${GREEN}Running${NC}"
            [ -n "$uptime" ] && status_line="${status_line} (${uptime})"
            echo -e "${status_line}${EL}"
            echo -e "  Containers: ${GREEN}${running_count}${NC}/${CONTAINER_COUNT}    Clients: ${GREEN}${connected}${NC} connected, ${YELLOW}${connecting}${NC} connecting${EL}"

            echo -e "${EL}"
            echo -e "${CYAN}═══ Traffic (current session) ═══${NC}${EL}"
            [ -n "$upload" ] && echo -e "  Upload:       ${CYAN}${upload}${NC}${EL}"
            [ -n "$download" ] && echo -e "  Download:     ${CYAN}${download}${NC}${EL}"

            echo -e "${EL}"
            echo -e "${CYAN}═══ Resource Usage ═══${NC}${EL}"
            printf "  %-8s CPU: ${YELLOW}%-20s${NC} | RAM: ${YELLOW}%-20s${NC}${EL}\n" "App:" "$app_cpu_display" "$app_ram"
            printf "  %-8s CPU: ${YELLOW}%-20s${NC} | RAM: ${YELLOW}%-20s${NC}${EL}\n" "System:" "$sys_cpu" "$sys_ram_used / $sys_ram_total"
            printf "  %-8s Net: ${YELLOW}%-43s${NC}${EL}\n" "Total:" "$net_display"


        else
             echo -e "${BOLD}Status:${NC} ${GREEN}Running${NC}${EL}"
             echo -e "  Containers: ${GREEN}${running_count}${NC}/${CONTAINER_COUNT}${EL}"
             echo -e "${EL}"
             echo -e "${CYAN}═══ Resource Usage ═══${NC}${EL}"
             printf "  %-8s CPU: ${YELLOW}%-20s${NC} | RAM: ${YELLOW}%-20s${NC}${EL}\n" "App:" "$app_cpu_display" "$app_ram"
             printf "  %-8s CPU: ${YELLOW}%-20s${NC} | RAM: ${YELLOW}%-20s${NC}${EL}\n" "System:" "$sys_cpu" "$sys_ram_used / $sys_ram_total"
             printf "  %-8s Net: ${YELLOW}%-43s${NC}${EL}\n" "Total:" "$net_display"
             echo -e "${EL}"
             echo -e "  Stats:        ${YELLOW}Waiting for first stats...${NC}${EL}"
        fi
        
    else
        echo -e "${BOLD}Status:${NC} ${RED}Stopped${NC}${EL}"
    fi
    

    
    echo -e "${EL}"
    echo -e "${CYAN}═══ SETTINGS ═══${NC}${EL}"
    # Check if any per-container overrides exist
    local has_overrides=false
    for i in $(seq 1 $CONTAINER_COUNT); do
        local mc_var="MAX_CLIENTS_${i}"
        local bw_var="BANDWIDTH_${i}"
        if [ -n "${!mc_var}" ] || [ -n "${!bw_var}" ]; then
            has_overrides=true
            break
        fi
    done
    if [ "$has_overrides" = true ]; then
        echo -e "  Containers:   ${CONTAINER_COUNT}${EL}"
        for i in $(seq 1 $CONTAINER_COUNT); do
            local mc=$(get_container_max_clients $i)
            local bw=$(get_container_bandwidth $i)
            local bw_d="Unlimited"
            [ "$bw" != "-1" ] && bw_d="${bw} Mbps"
            printf "  %-12s clients: %-5s bw: %s${EL}\n" "$(get_container_name $i)" "$mc" "$bw_d"
        done
    else
        echo -e "  Max Clients:  ${MAX_CLIENTS}${EL}"
        if [ "$BANDWIDTH" == "-1" ]; then
            echo -e "  Bandwidth:    Unlimited${EL}"
        else
            echo -e "  Bandwidth:    ${BANDWIDTH} Mbps${EL}"
        fi
        echo -e "  Containers:   ${CONTAINER_COUNT}${EL}"
    fi
    if [ "$DATA_CAP_GB" -gt 0 ] 2>/dev/null; then
        local usage=$(get_data_usage)
        local used_rx=$(echo "$usage" | awk '{print $1}')
        local used_tx=$(echo "$usage" | awk '{print $2}')
        local total_used=$((used_rx + used_tx + ${DATA_CAP_PRIOR_USAGE:-0}))
        echo -e "  Data Cap:     $(format_gb $total_used) / ${DATA_CAP_GB} GB${EL}"
    fi

    
    echo -e "${EL}"
    echo -e "${CYAN}═══ AUTO-START SERVICE ═══${NC}${EL}"
    # Check for systemd
    if command -v systemctl &>/dev/null && systemctl is-enabled conduit.service 2>/dev/null | grep -q "enabled"; then
        echo -e "  Auto-start:   ${GREEN}Enabled (systemd)${NC}${EL}"
        # Show service based on actual container state (systemd oneshot status is unreliable)
        local svc_containers=$(docker ps --filter "name=^conduit" --format '{{.Names}}' 2>/dev/null | wc -l)
        if [ "${svc_containers:-0}" -gt 0 ] 2>/dev/null; then
            echo -e "  Service:      ${GREEN}active${NC}${EL}"
        else
            echo -e "  Service:      ${YELLOW}inactive${NC}${EL}"
        fi
    # Check for OpenRC
    elif command -v rc-status &>/dev/null && rc-status -a 2>/dev/null | grep -q "conduit"; then
        echo -e "  Auto-start:   ${GREEN}Enabled (OpenRC)${NC}${EL}"
    # Check for SysVinit
    elif [ -f /etc/init.d/conduit ]; then
        echo -e "  Auto-start:   ${GREEN}Enabled (SysVinit)${NC}${EL}"
    else
        echo -e "  Auto-start:   ${YELLOW}Not configured${NC}${EL}"
        echo -e "  Note:         Docker restart policy handles restarts${EL}"
    fi
    # Check Background Tracker
    if is_tracker_active; then
        echo -e "  Tracker:      ${GREEN}Active${NC}${EL}"
    else
        echo -e "  Tracker:      ${YELLOW}Inactive${NC}${EL}"
    fi
    echo -e "${EL}"
}

start_conduit() {
    # Check data cap before starting
    if [ "$DATA_CAP_GB" -gt 0 ] 2>/dev/null; then
        local usage=$(get_data_usage)
        local used_rx=$(echo "$usage" | awk '{print $1}')
        local used_tx=$(echo "$usage" | awk '{print $2}')
        local total_used=$((used_rx + used_tx + ${DATA_CAP_PRIOR_USAGE:-0}))
        local cap_bytes=$(awk -v gb="$DATA_CAP_GB" 'BEGIN{printf "%.0f", gb * 1073741824}')
        if [ "$total_used" -ge "$cap_bytes" ] 2>/dev/null; then
            echo -e "${RED}⚠ Data cap exceeded ($(format_gb $total_used) / ${DATA_CAP_GB} GB). Containers will not start.${NC}"
            echo -e "${YELLOW}Reset or increase the data cap from the menu to start containers.${NC}"
            return 1
        fi
    fi

    echo "Starting Conduit ($CONTAINER_COUNT container(s))..."

    # Check if any stopped containers exist that will be recreated
    local has_stopped=false
    for i in $(seq 1 $CONTAINER_COUNT); do
        local name=$(get_container_name $i)
        if docker ps -a 2>/dev/null | grep -q "[[:space:]]${name}$"; then
            if ! docker ps 2>/dev/null | grep -q "[[:space:]]${name}$"; then
                has_stopped=true
                break
            fi
        fi
    done
    if [ "$has_stopped" = true ]; then
        echo -e "${YELLOW}⚠ Note: This will remove and recreate stopped containers with fresh instances.${NC}"
        echo -e "${YELLOW}  Your data volumes are preserved, but container logs will be reset.${NC}"
        echo -e "${YELLOW}  To resume stopped containers without recreating, use the 'c' menu → [s].${NC}"
        read -p "  Continue? (y/n): " confirm < /dev/tty || true
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo -e "  ${CYAN}Cancelled.${NC}"
            return 0
        fi
    fi

    for i in $(seq 1 $CONTAINER_COUNT); do
        local name=$(get_container_name $i)
        local vol=$(get_volume_name $i)

        # Check if container exists (running or stopped)
        if docker ps -a 2>/dev/null | grep -q "[[:space:]]${name}$"; then
            if docker ps 2>/dev/null | grep -q "[[:space:]]${name}$"; then
                echo -e "${GREEN}✓ ${name} is already running${NC}"
                continue
            fi
            echo "Recreating ${name}..."
            docker rm "$name" 2>/dev/null || true
        fi

        docker volume create "$vol" 2>/dev/null || true
        fix_volume_permissions $i
        run_conduit_container $i

        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ ${name} started${NC}"
        else
            echo -e "${RED}✗ Failed to start ${name}${NC}"
        fi
    done
    # Start background tracker
    setup_tracker_service 2>/dev/null || true
    return 0
}

stop_conduit() {
    echo "Stopping Conduit..."
    local stopped=0
    for i in $(seq 1 $CONTAINER_COUNT); do
        local name=$(get_container_name $i)
        if docker ps 2>/dev/null | grep -q "[[:space:]]${name}$"; then
            docker stop "$name" 2>/dev/null
            echo -e "${YELLOW}✓ ${name} stopped${NC}"
            stopped=$((stopped + 1))
        fi
    done
    # Also stop any extra containers beyond current count (from previous scaling)
    for i in $(seq $((CONTAINER_COUNT + 1)) 5); do
        local name=$(get_container_name $i)
        if docker ps -a 2>/dev/null | grep -q "[[:space:]]${name}$"; then
            docker stop "$name" 2>/dev/null || true
            docker rm "$name" 2>/dev/null || true
            echo -e "${YELLOW}✓ ${name} stopped and removed (extra)${NC}"
        fi
    done
    [ "$stopped" -eq 0 ] && echo -e "${YELLOW}No Conduit containers are running${NC}"
    # Stop background tracker
    stop_tracker_service 2>/dev/null || true
    return 0
}

restart_conduit() {
    # Check data cap before restarting
    if [ "$DATA_CAP_GB" -gt 0 ] 2>/dev/null; then
        local usage=$(get_data_usage)
        local used_rx=$(echo "$usage" | awk '{print $1}')
        local used_tx=$(echo "$usage" | awk '{print $2}')
        local total_used=$((used_rx + used_tx + ${DATA_CAP_PRIOR_USAGE:-0}))
        local cap_bytes=$(awk -v gb="$DATA_CAP_GB" 'BEGIN{printf "%.0f", gb * 1073741824}')
        if [ "$total_used" -ge "$cap_bytes" ] 2>/dev/null; then
            echo -e "${RED}⚠ Data cap exceeded ($(format_gb $total_used) / ${DATA_CAP_GB} GB). Containers will not restart.${NC}"
            echo -e "${YELLOW}Reset or increase the data cap from the menu to restart containers.${NC}"
            return 1
        fi
    fi

    echo "Restarting Conduit ($CONTAINER_COUNT container(s))..."
    for i in $(seq 1 $CONTAINER_COUNT); do
        local name=$(get_container_name $i)
        local vol=$(get_volume_name $i)
        local want_mc=$(get_container_max_clients $i)
        local want_bw=$(get_container_bandwidth $i)
        local want_cpus=$(get_container_cpus $i)
        local want_mem=$(get_container_memory $i)

        if docker ps 2>/dev/null | grep -q "[[:space:]]${name}$"; then
            # Container is running — check if settings match
            local cur_args=$(docker inspect --format '{{join .Args " "}}' "$name" 2>/dev/null)
            local needs_recreate=false
            # Check if max-clients or bandwidth args differ (portable, no -oP)
            local cur_mc=$(echo "$cur_args" | sed -n 's/.*--max-clients \([^ ]*\).*/\1/p' 2>/dev/null)
            local cur_bw=$(echo "$cur_args" | sed -n 's/.*--bandwidth \([^ ]*\).*/\1/p' 2>/dev/null)
            [ "$cur_mc" != "$want_mc" ] && needs_recreate=true
            [ "$cur_bw" != "$want_bw" ] && needs_recreate=true
            # Check resource limits
            local cur_nano=$(docker inspect --format '{{.HostConfig.NanoCpus}}' "$name" 2>/dev/null || echo 0)
            local cur_memb=$(docker inspect --format '{{.HostConfig.Memory}}' "$name" 2>/dev/null || echo 0)
            local want_nano=0
            [ -n "$want_cpus" ] && want_nano=$(awk -v c="$want_cpus" 'BEGIN{printf "%.0f", c*1000000000}')
            local want_memb=0
            if [ -n "$want_mem" ]; then
                local mv=${want_mem%[mMgG]}
                local mu=${want_mem: -1}
                [[ "$mu" =~ [gG] ]] && want_memb=$((mv * 1073741824)) || want_memb=$((mv * 1048576))
            fi
            [ "${cur_nano:-0}" != "$want_nano" ] && needs_recreate=true
            [ "${cur_memb:-0}" != "$want_memb" ] && needs_recreate=true

            if [ "$needs_recreate" = true ]; then
                echo "Settings changed for ${name}, recreating..."
                docker stop "$name" 2>/dev/null || true
                docker rm "$name" 2>/dev/null || true
                docker volume create "$vol" 2>/dev/null || true
                fix_volume_permissions $i
                run_conduit_container $i
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}✓ ${name} recreated with new settings${NC}"
                else
                    echo -e "${RED}✗ Failed to recreate ${name}${NC}"
                fi
            else
                docker restart "$name" 2>/dev/null
                echo -e "${GREEN}✓ ${name} restarted (settings unchanged)${NC}"
            fi
        elif docker ps -a 2>/dev/null | grep -q "[[:space:]]${name}$"; then
            # Container exists but stopped — check if settings match
            local cur_args=$(docker inspect --format '{{join .Args " "}}' "$name" 2>/dev/null)
            local cur_mc=$(echo "$cur_args" | sed -n 's/.*--max-clients \([^ ]*\).*/\1/p' 2>/dev/null)
            local cur_bw=$(echo "$cur_args" | sed -n 's/.*--bandwidth \([^ ]*\).*/\1/p' 2>/dev/null)
            local cur_nano=$(docker inspect --format '{{.HostConfig.NanoCpus}}' "$name" 2>/dev/null || echo 0)
            local cur_memb=$(docker inspect --format '{{.HostConfig.Memory}}' "$name" 2>/dev/null || echo 0)
            local want_nano=0
            [ -n "$want_cpus" ] && want_nano=$(awk -v c="$want_cpus" 'BEGIN{printf "%.0f", c*1000000000}')
            local want_memb=0
            if [ -n "$want_mem" ]; then
                local mv=${want_mem%[mMgG]}
                local mu=${want_mem: -1}
                [[ "$mu" =~ [gG] ]] && want_memb=$((mv * 1073741824)) || want_memb=$((mv * 1048576))
            fi
            if [ "$cur_mc" != "$want_mc" ] || [ "$cur_bw" != "$want_bw" ] || [ "${cur_nano:-0}" != "$want_nano" ] || [ "${cur_memb:-0}" != "$want_memb" ]; then
                echo "Settings changed for ${name}, recreating..."
                docker rm "$name" 2>/dev/null || true
                docker volume create "$vol" 2>/dev/null || true
                fix_volume_permissions $i
                run_conduit_container $i
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}✓ ${name} recreated with new settings${NC}"
                else
                    echo -e "${RED}✗ Failed to recreate ${name}${NC}"
                fi
            else
                docker start "$name" 2>/dev/null
                echo -e "${GREEN}✓ ${name} started${NC}"
            fi
        else
            # Container doesn't exist — create fresh
            docker volume create "$vol" 2>/dev/null || true
            fix_volume_permissions $i
            run_conduit_container $i
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✓ ${name} created and started${NC}"
            else
                echo -e "${RED}✗ Failed to create ${name}${NC}"
            fi
        fi
    done
    # Remove extra containers beyond current count
    for i in $(seq $((CONTAINER_COUNT + 1)) 5); do
        local name=$(get_container_name $i)
        if docker ps -a 2>/dev/null | grep -q "[[:space:]]${name}$"; then
            docker stop "$name" 2>/dev/null || true
            docker rm "$name" 2>/dev/null || true
            echo -e "${YELLOW}✓ ${name} removed (scaled down)${NC}"
        fi
    done
    # Stop tracker before backup to avoid racing with writes
    stop_tracker_service 2>/dev/null || true
    local persist_dir="$INSTALL_DIR/traffic_stats"
    if [ -s "$persist_dir/cumulative_data" ] || [ -s "$persist_dir/cumulative_ips" ]; then
        echo -e "${CYAN}⟳ Saving tracker data snapshot...${NC}"
        [ -s "$persist_dir/cumulative_data" ] && cp "$persist_dir/cumulative_data" "$persist_dir/cumulative_data.bak"
        [ -s "$persist_dir/cumulative_ips" ] && cp "$persist_dir/cumulative_ips" "$persist_dir/cumulative_ips.bak"
        [ -s "$persist_dir/geoip_cache" ] && cp "$persist_dir/geoip_cache" "$persist_dir/geoip_cache.bak"
        echo -e "${GREEN}✓ Tracker data snapshot saved${NC}"
    fi
    # Regenerate tracker script and ensure service is running
    setup_tracker_service 2>/dev/null || true
}

change_settings() {
    echo ""
    echo -e "${CYAN}═══ Current Settings ═══${NC}"
    echo ""
    printf "  ${BOLD}%-12s %-12s %-12s %-10s %-10s${NC}\n" "Container" "Max Clients" "Bandwidth" "CPU" "Memory"
    echo -e "  ${CYAN}──────────────────────────────────────────────────────────${NC}"
    for i in $(seq 1 $CONTAINER_COUNT); do
        local cname=$(get_container_name $i)
        local mc=$(get_container_max_clients $i)
        local bw=$(get_container_bandwidth $i)
        local cpus=$(get_container_cpus $i)
        local mem=$(get_container_memory $i)
        local bw_display="Unlimited"
        [ "$bw" != "-1" ] && bw_display="${bw} Mbps"
        local cpu_d="${cpus:-—}"
        local mem_d="${mem:-—}"
        printf "  %-12s %-12s %-12s %-10s %-10s\n" "$cname" "$mc" "$bw_display" "$cpu_d" "$mem_d"
    done
    echo ""
    echo -e "  Default: Max Clients=${GREEN}${MAX_CLIENTS}${NC}  Bandwidth=${GREEN}$([ "$BANDWIDTH" = "-1" ] && echo "Unlimited" || echo "${BANDWIDTH} Mbps")${NC}"
    echo ""

    # Select target
    echo -e "  ${BOLD}Apply settings to:${NC}"
    echo -e "  ${GREEN}a${NC}) All containers (set same values)"
    for i in $(seq 1 $CONTAINER_COUNT); do
        echo -e "  ${GREEN}${i}${NC}) $(get_container_name $i)"
    done
    echo ""
    read -p "  Select (a/1-${CONTAINER_COUNT}): " target < /dev/tty || true

    local targets=()
    if [ "$target" = "a" ] || [ "$target" = "A" ]; then
        for i in $(seq 1 $CONTAINER_COUNT); do targets+=($i); done
    elif [[ "$target" =~ ^[0-9]+$ ]] && [ "$target" -ge 1 ] && [ "$target" -le "$CONTAINER_COUNT" ]; then
        targets+=($target)
    else
        echo -e "  ${RED}Invalid selection.${NC}"
        return
    fi

    # Get new values
    local cur_mc=$(get_container_max_clients ${targets[0]})
    local cur_bw=$(get_container_bandwidth ${targets[0]})
    echo ""
    read -p "  New max-clients (1-1000) [${cur_mc}]: " new_clients < /dev/tty || true

    echo ""
    local cur_bw_display="Unlimited"
    [ "$cur_bw" != "-1" ] && cur_bw_display="${cur_bw} Mbps"
    echo "  Current bandwidth: ${cur_bw_display}"
    read -p "  Set unlimited bandwidth? [y/N]: " set_unlimited < /dev/tty || true

    local new_bandwidth=""
    if [[ "$set_unlimited" =~ ^[Yy]$ ]]; then
        new_bandwidth="-1"
    else
        read -p "  New bandwidth in Mbps (1-40) [${cur_bw}]: " input_bw < /dev/tty || true
        [ -n "$input_bw" ] && new_bandwidth="$input_bw"
    fi

    # Validate max-clients
    local valid_mc=""
    if [ -n "$new_clients" ]; then
        if [[ "$new_clients" =~ ^[0-9]+$ ]] && [ "$new_clients" -ge 1 ] && [ "$new_clients" -le 1000 ]; then
            valid_mc="$new_clients"
        else
            echo -e "  ${YELLOW}Invalid max-clients. Keeping current.${NC}"
        fi
    fi

    # Validate bandwidth
    local valid_bw=""
    if [ -n "$new_bandwidth" ]; then
        if [ "$new_bandwidth" = "-1" ]; then
            valid_bw="-1"
        elif [[ "$new_bandwidth" =~ ^[0-9]+$ ]] && [ "$new_bandwidth" -ge 1 ] && [ "$new_bandwidth" -le 40 ]; then
            valid_bw="$new_bandwidth"
        elif [[ "$new_bandwidth" =~ ^[0-9]*\.[0-9]+$ ]]; then
            local float_ok=$(awk -v val="$new_bandwidth" 'BEGIN { print (val >= 1 && val <= 40) ? "yes" : "no" }')
            [ "$float_ok" = "yes" ] && valid_bw="$new_bandwidth" || echo -e "  ${YELLOW}Invalid bandwidth. Keeping current.${NC}"
        else
            echo -e "  ${YELLOW}Invalid bandwidth. Keeping current.${NC}"
        fi
    fi

    # Apply to targets
    if [ "$target" = "a" ] || [ "$target" = "A" ]; then
        # Apply to all = update global defaults and clear per-container overrides
        [ -n "$valid_mc" ] && MAX_CLIENTS="$valid_mc"
        [ -n "$valid_bw" ] && BANDWIDTH="$valid_bw"
        for i in $(seq 1 5); do
            unset "MAX_CLIENTS_${i}" 2>/dev/null || true
            unset "BANDWIDTH_${i}" 2>/dev/null || true
        done
    else
        # Apply to specific container
        local idx=${targets[0]}
        if [ -n "$valid_mc" ]; then
            eval "MAX_CLIENTS_${idx}=${valid_mc}"
        fi
        if [ -n "$valid_bw" ]; then
            eval "BANDWIDTH_${idx}=${valid_bw}"
        fi
    fi

    save_settings

    # Recreate affected containers
    echo ""
    echo "  Recreating container(s) with new settings..."
    for i in "${targets[@]}"; do
        local name=$(get_container_name $i)
        docker rm -f "$name" 2>/dev/null || true
    done
    sleep 1
    for i in "${targets[@]}"; do
        local name=$(get_container_name $i)
        fix_volume_permissions $i
        run_conduit_container $i
        if [ $? -eq 0 ]; then
            local mc=$(get_container_max_clients $i)
            local bw=$(get_container_bandwidth $i)
            local bw_d="Unlimited"
            [ "$bw" != "-1" ] && bw_d="${bw} Mbps"
            echo -e "  ${GREEN}✓ ${name}${NC} — clients: ${mc}, bandwidth: ${bw_d}"
        else
            echo -e "  ${RED}✗ Failed to restart ${name}${NC}"
        fi
    done
}

change_resource_limits() {
    local cpu_cores=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
    local ram_mb=$(awk '/MemTotal/{printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo 512)
    echo ""
    echo -e "${CYAN}═══ RESOURCE LIMITS ═══${NC}"
    echo ""
    echo -e "  Set CPU and memory limits per container."
    echo -e "  ${DIM}System: ${cpu_cores} CPU core(s), ${ram_mb} MB RAM${NC}"
    echo ""

    # Show current limits
    printf "  ${BOLD}%-12s %-12s %-12s${NC}\n" "Container" "CPU Limit" "Memory Limit"
    echo -e "  ${CYAN}────────────────────────────────────────${NC}"
    for i in $(seq 1 $CONTAINER_COUNT); do
        local cname=$(get_container_name $i)
        local cpus=$(get_container_cpus $i)
        local mem=$(get_container_memory $i)
        local cpu_d="${cpus:-No limit}"
        local mem_d="${mem:-No limit}"
        [ -n "$cpus" ] && cpu_d="${cpus} cores"
        printf "  %-12s %-12s %-12s\n" "$cname" "$cpu_d" "$mem_d"
    done
    echo ""

    # Select target
    echo -e "  ${BOLD}Apply limits to:${NC}"
    echo -e "  ${GREEN}a${NC}) All containers"
    for i in $(seq 1 $CONTAINER_COUNT); do
        echo -e "  ${GREEN}${i}${NC}) $(get_container_name $i)"
    done
    echo -e "  ${GREEN}c${NC}) Clear all limits (remove restrictions)"
    echo ""
    read -p "  Select (a/1-${CONTAINER_COUNT}/c): " target < /dev/tty || true

    if [ "$target" = "c" ] || [ "$target" = "C" ]; then
        DOCKER_CPUS=""
        DOCKER_MEMORY=""
        for i in $(seq 1 5); do
            unset "CPUS_${i}" 2>/dev/null || true
            unset "MEMORY_${i}" 2>/dev/null || true
        done
        save_settings
        echo -e "  ${GREEN}✓ All resource limits cleared. Containers will use full system resources on next restart.${NC}"
        return
    fi

    local targets=()
    if [ "$target" = "a" ] || [ "$target" = "A" ]; then
        for i in $(seq 1 $CONTAINER_COUNT); do targets+=($i); done
    elif [[ "$target" =~ ^[0-9]+$ ]] && [ "$target" -ge 1 ] && [ "$target" -le "$CONTAINER_COUNT" ]; then
        targets+=($target)
    else
        echo -e "  ${RED}Invalid selection.${NC}"
        return
    fi

    local rec_cpu=$(awk -v c="$cpu_cores" 'BEGIN{v=c/2; if(v<0.5) v=0.5; printf "%.1f", v}')
    local rec_mem="256m"
    [ "$ram_mb" -ge 2048 ] && rec_mem="512m"
    [ "$ram_mb" -ge 4096 ] && rec_mem="1g"

    # CPU limit prompt
    echo ""
    echo -e "  ${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}CPU Limit${NC}"
    echo -e "  Limits how much processor power this container can use."
    echo -e "  This prevents it from slowing down other services on your system."
    echo -e ""
    echo -e "  ${DIM}Your system has ${GREEN}${cpu_cores}${NC}${DIM} core(s).${NC}"
    echo -e "  ${DIM}  0.5 = half a core    1.0 = one full core${NC}"
    echo -e "  ${DIM}  2.0 = two cores      ${cpu_cores}.0 = all cores (no limit)${NC}"
    echo -e ""
    echo -e "  Press Enter to keep current or use default."
    echo -e "  ${CYAN}───────────────────────────────────────────────────────────────${NC}"
    local cur_cpus=$(get_container_cpus ${targets[0]})
    local cpus_default="${cur_cpus:-${rec_cpu}}"
    read -p "  CPU limit [${cpus_default}]: " input_cpus < /dev/tty || true

    # Validate CPU
    local valid_cpus=""
    if [ -z "$input_cpus" ]; then
        # Enter pressed — keep current if set, otherwise no change
        [ -n "$cur_cpus" ] && valid_cpus="$cur_cpus"
    elif [[ "$input_cpus" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        local cpu_ok=$(awk -v val="$input_cpus" -v max="$cpu_cores" 'BEGIN { print (val > 0 && val <= max) ? "yes" : "no" }')
        if [ "$cpu_ok" = "yes" ]; then
            valid_cpus="$input_cpus"
        else
            echo -e "  ${YELLOW}Must be between 0.1 and ${cpu_cores}. Keeping current.${NC}"
            [ -n "$cur_cpus" ] && valid_cpus="$cur_cpus"
        fi
    else
        echo -e "  ${YELLOW}Invalid input. Keeping current.${NC}"
        [ -n "$cur_cpus" ] && valid_cpus="$cur_cpus"
    fi

    # Memory limit prompt
    echo ""
    echo -e "  ${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}Memory Limit${NC}"
    echo -e "  Maximum RAM this container can use."
    echo -e "  Prevents it from consuming all memory and crashing other services."
    echo -e ""
    echo -e "  ${DIM}Your system has ${GREEN}${ram_mb} MB${NC}${DIM} RAM.${NC}"
    echo -e "  ${DIM}  256m  = 256 MB (good for low-end systems)${NC}"
    echo -e "  ${DIM}  512m  = 512 MB (balanced)${NC}"
    echo -e "  ${DIM}  1g    = 1 GB   (high capacity)${NC}"
    echo -e ""
    echo -e "  Press Enter to keep current or use default."
    echo -e "  ${CYAN}───────────────────────────────────────────────────────────────${NC}"
    local cur_mem=$(get_container_memory ${targets[0]})
    local mem_default="${cur_mem:-${rec_mem}}"
    read -p "  Memory limit [${mem_default}]: " input_mem < /dev/tty || true

    # Validate memory
    local valid_mem=""
    if [ -z "$input_mem" ]; then
        # Enter pressed — keep current if set, otherwise no change
        [ -n "$cur_mem" ] && valid_mem="$cur_mem"
    elif [[ "$input_mem" =~ ^[0-9]+[mMgG]$ ]]; then
        local mem_val=${input_mem%[mMgG]}
        local mem_unit=${input_mem: -1}
        local mem_mb=$mem_val
        [[ "$mem_unit" =~ [gG] ]] && mem_mb=$((mem_val * 1024))
        if [ "$mem_mb" -ge 64 ] && [ "$mem_mb" -le "$ram_mb" ]; then
            valid_mem="$input_mem"
        else
            echo -e "  ${YELLOW}Must be between 64m and ${ram_mb}m. Keeping current.${NC}"
            [ -n "$cur_mem" ] && valid_mem="$cur_mem"
        fi
    else
        echo -e "  ${YELLOW}Invalid format. Use a number followed by m or g (e.g. 256m, 1g). Keeping current.${NC}"
        [ -n "$cur_mem" ] && valid_mem="$cur_mem"
    fi

    # Nothing changed
    if [ -z "$valid_cpus" ] && [ -z "$valid_mem" ]; then
        echo -e "  ${DIM}No changes made.${NC}"
        return
    fi

    # Apply
    if [ "$target" = "a" ] || [ "$target" = "A" ]; then
        [ -n "$valid_cpus" ] && DOCKER_CPUS="$valid_cpus"
        [ -n "$valid_mem" ] && DOCKER_MEMORY="$valid_mem"
        for i in $(seq 1 5); do
            unset "CPUS_${i}" 2>/dev/null || true
            unset "MEMORY_${i}" 2>/dev/null || true
        done
    else
        local idx=${targets[0]}
        [ -n "$valid_cpus" ] && eval "CPUS_${idx}=${valid_cpus}"
        [ -n "$valid_mem" ] && eval "MEMORY_${idx}=${valid_mem}"
    fi

    save_settings

    # Recreate affected containers
    echo ""
    echo "  Recreating container(s) with new resource limits..."
    for i in "${targets[@]}"; do
        local name=$(get_container_name $i)
        docker rm -f "$name" 2>/dev/null || true
    done
    sleep 1
    for i in "${targets[@]}"; do
        local name=$(get_container_name $i)
        fix_volume_permissions $i
        run_conduit_container $i
        if [ $? -eq 0 ]; then
            local cpus=$(get_container_cpus $i)
            local mem=$(get_container_memory $i)
            local cpu_d="${cpus:-no limit}"
            local mem_d="${mem:-no limit}"
            [ -n "$cpus" ] && cpu_d="${cpus} cores"
            echo -e "  ${GREEN}✓ ${name}${NC} — CPU: ${cpu_d}, Memory: ${mem_d}"
        else
            echo -e "  ${RED}✗ Failed to restart ${name}${NC}"
        fi
    done
}

#═══════════════════════════════════════════════════════════════════════
# show_logs() - Display color-coded Docker logs
#═══════════════════════════════════════════════════════════════════════
# Colors log entries based on their type:
#   [OK]     - Green   (successful operations)
#   [INFO]   - Cyan    (informational messages)
#   [STATS]  - Blue    (statistics)
#   [WARN]   - Yellow  (warnings)
#   [ERROR]  - Red     (errors)
#   [DEBUG]  - Gray    (debug messages)
#═══════════════════════════════════════════════════════════════════════
show_logs() {
    if ! docker ps -a 2>/dev/null | grep -q conduit; then
        echo -e "${RED}Conduit container not found.${NC}"
        return 1
    fi

    local target="conduit"
    if [ "$CONTAINER_COUNT" -gt 1 ]; then
        echo ""
        echo -e "${CYAN}Select container to view logs:${NC}"
        echo ""
        for i in $(seq 1 $CONTAINER_COUNT); do
            local cname=$(get_container_name $i)
            local status="${RED}Stopped${NC}"
            docker ps 2>/dev/null | grep -q "[[:space:]]${cname}$" && status="${GREEN}Running${NC}"
            echo -e "  ${i}. ${cname}  [${status}]"
        done
        echo ""
        read -p "  Select (1-${CONTAINER_COUNT}): " idx < /dev/tty || true
        if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt "$CONTAINER_COUNT" ]; then
            echo -e "${RED}Invalid selection.${NC}"
            return 1
        fi
        target=$(get_container_name $idx)
    fi

    echo -e "${CYAN}Streaming logs from ${target} (filtered, no [STATS])... Press Ctrl+C to stop${NC}"
    echo ""

    docker logs -f "$target" 2>&1 | grep -v "\[STATS\]"
}

uninstall_all() {
    telegram_disable_service
    rm -f /etc/systemd/system/conduit-telegram.service 2>/dev/null
    systemctl daemon-reload 2>/dev/null || true
    echo ""
    echo -e "${RED}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                    ⚠️  UNINSTALL CONDUIT                          ║${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "This will completely remove:"
    echo "  • All Conduit Docker containers (conduit, conduit-2..5)"
    echo "  • All Conduit data volumes"
    echo "  • Conduit Docker image"
    echo "  • Auto-start service (systemd/OpenRC/SysVinit)"
    echo "  • Background tracker service & stats data"
    echo "  • Configuration files & Management CLI"
    echo ""
    echo -e "${YELLOW}Docker engine will NOT be removed.${NC}"
    echo ""
    echo -e "${RED}WARNING: This action cannot be undone!${NC}"
    echo ""
    read -p "Are you sure you want to uninstall? (type 'yes' to confirm): " confirm < /dev/tty || true

    if [ "$confirm" != "yes" ]; then
        echo "Uninstall cancelled."
        return 0
    fi

    # Check for backup keys
    local keep_backups=false
    if [ -d "$BACKUP_DIR" ] && [ "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
        echo ""
        echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}  📁 Backup keys found in: ${BACKUP_DIR}${NC}"
        echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo "You have backed up node identity keys. These allow you to restore"
        echo "your node identity if you reinstall Conduit later."
        echo ""
        while true; do
            read -p "Do you want to KEEP your backup keys? (y/n): " keep_confirm < /dev/tty || true
            if [[ "$keep_confirm" =~ ^[Yy]$ ]]; then
                keep_backups=true
                echo -e "${GREEN}✓ Backup keys will be preserved.${NC}"
                break
            elif [[ "$keep_confirm" =~ ^[Nn]$ ]]; then
                echo -e "${YELLOW}⚠ Backup keys will be deleted.${NC}"
                break
            else
                echo "Please enter y or n."
            fi
        done
        echo ""
    fi

    echo ""
    echo -e "${BLUE}[INFO]${NC} Stopping Conduit container(s)..."
    for i in $(seq 1 5); do
        local name=$(get_container_name $i)
        docker stop "$name" 2>/dev/null || true
        docker rm -f "$name" 2>/dev/null || true
    done

    echo -e "${BLUE}[INFO]${NC} Removing Conduit Docker image..."
    docker rmi "$CONDUIT_IMAGE" 2>/dev/null || true

    echo -e "${BLUE}[INFO]${NC} Removing Conduit data volume(s)..."
    for i in $(seq 1 5); do
        local vol=$(get_volume_name $i)
        docker volume rm "$vol" 2>/dev/null || true
    done

    echo -e "${BLUE}[INFO]${NC} Removing auto-start service..."
    # Tracker service
    systemctl stop conduit-tracker.service 2>/dev/null || true
    systemctl disable conduit-tracker.service 2>/dev/null || true
    rm -f /etc/systemd/system/conduit-tracker.service
    pkill -f "conduit-tracker.sh" 2>/dev/null || true
    # Systemd
    systemctl stop conduit.service 2>/dev/null || true
    systemctl disable conduit.service 2>/dev/null || true
    rm -f /etc/systemd/system/conduit.service
    systemctl daemon-reload 2>/dev/null || true
    # OpenRC / SysVinit
    rc-service conduit stop 2>/dev/null || true
    rc-update del conduit 2>/dev/null || true
    service conduit stop 2>/dev/null || true
    update-rc.d conduit remove 2>/dev/null || true
    chkconfig conduit off 2>/dev/null || true
    rm -f /etc/init.d/conduit

    echo -e "${BLUE}[INFO]${NC} Removing configuration files..."
    if [ "$keep_backups" = true ]; then
        # Keep backup directory, remove everything else in /opt/conduit
        echo -e "${BLUE}[INFO]${NC} Preserving backup keys in ${BACKUP_DIR}..."
        # Remove files in /opt/conduit but keep backups subdirectory
        rm -f /opt/conduit/config.env 2>/dev/null || true
        rm -f /opt/conduit/conduit 2>/dev/null || true
        rm -f /opt/conduit/conduit-tracker.sh 2>/dev/null || true
        rm -rf /opt/conduit/traffic_stats 2>/dev/null || true
        find /opt/conduit -maxdepth 1 -type f -delete 2>/dev/null || true
    else
        # Remove everything including backups
        rm -rf /opt/conduit
    fi
    rm -f /usr/local/bin/conduit

    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    ✅ UNINSTALL COMPLETE!                         ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Conduit and all related components have been removed."
    if [ "$keep_backups" = true ]; then
        echo ""
        echo -e "${CYAN}📁 Your backup keys are preserved in: ${BACKUP_DIR}${NC}"
        echo "   You can use these to restore your node identity after reinstalling."
    fi
    echo ""
    echo "Note: Docker engine was NOT removed."
    echo ""
}

manage_containers() {
    local stop_manage=0
    trap 'stop_manage=1' SIGINT SIGTERM

    tput smcup 2>/dev/null || true
    echo -ne "\033[?25l"
    printf "\033[2J\033[H"

    local EL="\033[K"
    local need_input=true
    local mc_choice=""

    while [ $stop_manage -eq 0 ]; do
        # Soft update: cursor home, no clear
        printf "\033[H"

        echo -e "${EL}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}${EL}"
        echo -e "${CYAN}  MANAGE CONTAINERS${NC}    ${GREEN}${CONTAINER_COUNT}${NC}/5  Host networking${EL}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}${EL}"
        echo -e "${EL}"

        # Per-container stats table
        local docker_ps_cache=$(docker ps --format '{{.Names}}' 2>/dev/null)

        # Collect all docker data in parallel using a temp dir
        local _mc_tmpdir=$(mktemp -d /tmp/.conduit_mc.XXXXXX)
        # mktemp already created the directory

        local running_names=""
        for ci in $(seq 1 $CONTAINER_COUNT); do
            local cname=$(get_container_name $ci)
            if echo "$docker_ps_cache" | grep -q "^${cname}$"; then
                running_names+=" $cname"
                # Fetch logs in parallel background jobs
                ( docker logs --tail 30 "$cname" 2>&1 | grep "\[STATS\]" | tail -1 > "$_mc_tmpdir/logs_${ci}" ) &
            fi
        done
        # Fetch stats in parallel with logs
        if [ -n "$running_names" ]; then
            ( timeout 10 docker stats --no-stream --format "{{.Name}} {{.CPUPerc}} {{.MemUsage}}" $running_names > "$_mc_tmpdir/stats" 2>/dev/null ) &
        fi
        wait

        local all_dstats=""
        [ -f "$_mc_tmpdir/stats" ] && all_dstats=$(cat "$_mc_tmpdir/stats")

        printf "  ${BOLD}%-2s %-11s %-8s %-7s %-8s %-8s %-6s %-7s${NC}${EL}\n" \
            "#" "Container" "Status" "Clients" "Up" "Down" "CPU" "RAM"
        echo -e "  ${CYAN}─────────────────────────────────────────────────────────${NC}${EL}"

        for ci in $(seq 1 5); do
            local cname=$(get_container_name $ci)
            local status_text status_color
            local c_clients="-" c_up="-" c_down="-" c_cpu="-" c_ram="-"

            if [ "$ci" -le "$CONTAINER_COUNT" ]; then
                if echo "$docker_ps_cache" | grep -q "^${cname}$"; then
                    status_text="Running"
                    status_color="${GREEN}"
                    local logs=""
                    [ -f "$_mc_tmpdir/logs_${ci}" ] && logs=$(cat "$_mc_tmpdir/logs_${ci}")
                    if [ -n "$logs" ]; then
                        IFS='|' read -r conn cing mc_up mc_down <<< $(echo "$logs" | awk '{
                            cing=0; conn=0; up=""; down=""
                            for(j=1;j<=NF;j++){
                                if($j=="Connecting:") cing=$(j+1)+0
                                else if($j=="Connected:") conn=$(j+1)+0
                                else if($j=="Up:"){for(k=j+1;k<=NF;k++){if($k=="|"||$k~/Down:/)break; up=up (up?" ":"") $k}}
                                else if($j=="Down:"){for(k=j+1;k<=NF;k++){if($k=="|"||$k~/Uptime:/)break; down=down (down?" ":"") $k}}
                            }
                            printf "%d|%d|%s|%s", conn, cing, up, down
                        }')
                        c_clients="${conn:-0}/${cing:-0}"
                        c_up="${mc_up:-"-"}"
                        c_down="${mc_down:-"-"}"
                        [ -z "$c_up" ] && c_up="-"
                        [ -z "$c_down" ] && c_down="-"
                    fi
                    local dstats_line=$(echo "$all_dstats" | grep "^${cname} " 2>/dev/null)
                    if [ -n "$dstats_line" ]; then
                        c_cpu=$(echo "$dstats_line" | awk '{print $2}')
                        c_ram=$(echo "$dstats_line" | awk '{print $3}')
                    fi
                else
                    status_text="Stopped"
                    status_color="${RED}"
                fi
            else
                status_text="--"
                status_color="${YELLOW}"
            fi
            printf "  %-2s %-11s %b%-8s%b %-7s %-8s %-8s %-6s %-7s${EL}\n" \
                "$ci" "$cname" "$status_color" "$status_text" "${NC}" "$c_clients" "$c_up" "$c_down" "$c_cpu" "$c_ram"
        done

        rm -rf "$_mc_tmpdir"

        echo -e "${EL}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}${EL}"
        local max_add=$((5 - CONTAINER_COUNT))
        [ "$max_add" -gt 0 ] && echo -e "  ${GREEN}[a]${NC} Add container(s)      (max: ${max_add} more)${EL}"
        [ "$CONTAINER_COUNT" -gt 1 ] && echo -e "  ${RED}[r]${NC} Remove container(s)   (min: 1 required)${EL}"
        echo -e "  ${GREEN}[s]${NC} Start a container${EL}"
        echo -e "  ${RED}[t]${NC} Stop a container${EL}"
        echo -e "  ${YELLOW}[x]${NC} Restart a container${EL}"
        echo -e "  ${CYAN}[q]${NC} QR code for container${EL}"
        echo -e "  [b] Back to menu${EL}"
        echo -e "${EL}"
        printf "\033[J"

        echo -e "  ${CYAN}────────────────────────────────────────${NC}"
        echo -ne "\033[?25h"
        local _mc_start=$(date +%s)
        read -t 5 -p "  Enter choice: " mc_choice < /dev/tty 2>/dev/null || { mc_choice=""; }
        echo -ne "\033[?25l"
        local _mc_elapsed=$(( $(date +%s) - _mc_start ))

        # If read failed instantly (not a 5s timeout), /dev/tty is broken
        if [ -z "$mc_choice" ] && [ "$_mc_elapsed" -lt 2 ]; then
            _mc_tty_fails=$(( ${_mc_tty_fails:-0} + 1 ))
            [ "$_mc_tty_fails" -ge 3 ] && { echo -e "\n  ${RED}Input error. Cannot read from terminal.${NC}"; return; }
        else
            _mc_tty_fails=0
        fi

        # Empty = just refresh
        [ -z "$mc_choice" ] && continue

        case "$mc_choice" in
            a)
                if [ "$CONTAINER_COUNT" -ge 5 ]; then
                    echo -e "  ${RED}Already at maximum (5).${NC}"
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    continue
                fi
                local max_add=$((5 - CONTAINER_COUNT))
                read -p "  How many to add? (1-${max_add}): " add_count < /dev/tty || true
                if ! [[ "$add_count" =~ ^[0-9]+$ ]] || [ "$add_count" -lt 1 ] || [ "$add_count" -gt "$max_add" ]; then
                    echo -e "  ${RED}Invalid.${NC}"
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    continue
                fi
                local old_count=$CONTAINER_COUNT
                CONTAINER_COUNT=$((CONTAINER_COUNT + add_count))

                # Ask if user wants to set resource limits on new containers
                local set_limits=""
                local new_cpus="" new_mem=""
                echo ""
                read -p "  Set CPU/memory limits on new container(s)? [y/N]: " set_limits < /dev/tty || true
                if [[ "$set_limits" =~ ^[Yy]$ ]]; then
                    local cpu_cores=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
                    local ram_mb=$(awk '/MemTotal/{printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo 512)
                    local rec_cpu=$(awk -v c="$cpu_cores" 'BEGIN{v=c/2; if(v<0.5) v=0.5; printf "%.1f", v}')
                    local rec_mem="256m"
                    [ "$ram_mb" -ge 2048 ] && rec_mem="512m"
                    [ "$ram_mb" -ge 4096 ] && rec_mem="1g"

                    echo ""
                    echo -e "  ${CYAN}───────────────────────────────────────────────────────────────${NC}"
                    echo -e "  ${BOLD}CPU Limit${NC}"
                    echo -e "  Limits how much processor power this container can use."
                    echo -e "  This prevents it from slowing down other services on your system."
                    echo -e ""
                    echo -e "  ${DIM}Your system has ${GREEN}${cpu_cores}${NC}${DIM} core(s).${NC}"
                    echo -e "  ${DIM}  0.5 = half a core    1.0 = one full core${NC}"
                    echo -e "  ${DIM}  2.0 = two cores      ${cpu_cores}.0 = all cores (no limit)${NC}"
                    echo -e ""
                    echo -e "  Press Enter to use the recommended default."
                    echo -e "  ${CYAN}───────────────────────────────────────────────────────────────${NC}"
                    read -p "  CPU limit [${rec_cpu}]: " input_cpus < /dev/tty || true
                    [ -z "$input_cpus" ] && input_cpus="$rec_cpu"
                    if [[ "$input_cpus" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                        local cpu_ok=$(awk -v val="$input_cpus" -v max="$cpu_cores" 'BEGIN { print (val > 0 && val <= max) ? "yes" : "no" }')
                        if [ "$cpu_ok" = "yes" ]; then
                            new_cpus="$input_cpus"
                            echo -e "  ${GREEN}✓ CPU limit: ${new_cpus} core(s)${NC}"
                        else
                            echo -e "  ${YELLOW}Must be between 0.1 and ${cpu_cores}. Using default: ${rec_cpu}${NC}"
                            new_cpus="$rec_cpu"
                        fi
                    else
                        echo -e "  ${YELLOW}Invalid input. Using default: ${rec_cpu}${NC}"
                        new_cpus="$rec_cpu"
                    fi

                    echo ""
                    echo -e "  ${CYAN}───────────────────────────────────────────────────────────────${NC}"
                    echo -e "  ${BOLD}Memory Limit${NC}"
                    echo -e "  Maximum RAM this container can use."
                    echo -e "  Prevents it from consuming all memory and crashing other services."
                    echo -e ""
                    echo -e "  ${DIM}Your system has ${GREEN}${ram_mb} MB${NC}${DIM} RAM.${NC}"
                    echo -e "  ${DIM}  256m  = 256 MB (good for low-end systems)${NC}"
                    echo -e "  ${DIM}  512m  = 512 MB (balanced)${NC}"
                    echo -e "  ${DIM}  1g    = 1 GB   (high capacity)${NC}"
                    echo -e ""
                    echo -e "  Press Enter to use the recommended default."
                    echo -e "  ${CYAN}───────────────────────────────────────────────────────────────${NC}"
                    read -p "  Memory limit [${rec_mem}]: " input_mem < /dev/tty || true
                    [ -z "$input_mem" ] && input_mem="$rec_mem"
                    if [[ "$input_mem" =~ ^[0-9]+[mMgG]$ ]]; then
                        local mem_val=${input_mem%[mMgG]}
                        local mem_unit=${input_mem: -1}
                        local mem_mb_val=$mem_val
                        [[ "$mem_unit" =~ [gG] ]] && mem_mb_val=$((mem_val * 1024))
                        if [ "$mem_mb_val" -ge 64 ] && [ "$mem_mb_val" -le "$ram_mb" ]; then
                            new_mem="$input_mem"
                            echo -e "  ${GREEN}✓ Memory limit: ${new_mem}${NC}"
                        else
                            echo -e "  ${YELLOW}Must be between 64m and ${ram_mb}m. Using default: ${rec_mem}${NC}"
                            new_mem="$rec_mem"
                        fi
                    else
                        echo -e "  ${YELLOW}Invalid format. Using default: ${rec_mem}${NC}"
                        new_mem="$rec_mem"
                    fi
                    # Save per-container overrides for new containers
                    for i in $(seq $((old_count + 1)) $CONTAINER_COUNT); do
                        [ -n "$new_cpus" ] && eval "CPUS_${i}=${new_cpus}"
                        [ -n "$new_mem" ] && eval "MEMORY_${i}=${new_mem}"
                    done
                fi

                save_settings
                for i in $(seq $((old_count + 1)) $CONTAINER_COUNT); do
                    local name=$(get_container_name $i)
                    local vol=$(get_volume_name $i)
                    docker volume create "$vol" 2>/dev/null || true
                    fix_volume_permissions $i
                    run_conduit_container $i
                    if [ $? -eq 0 ]; then
                        local c_cpu=$(get_container_cpus $i)
                        local c_mem=$(get_container_memory $i)
                        local cpu_info="" mem_info=""
                        [ -n "$c_cpu" ] && cpu_info=", CPU: ${c_cpu}"
                        [ -n "$c_mem" ] && mem_info=", Mem: ${c_mem}"
                        echo -e "  ${GREEN}✓ ${name} started${NC}${cpu_info}${mem_info}"
                    else
                        echo -e "  ${RED}✗ Failed to start ${name}${NC}"
                    fi
                done
                read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                ;;
            r)
                if [ "$CONTAINER_COUNT" -le 1 ]; then
                    echo -e "  ${RED}Must keep at least 1 container.${NC}"
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    continue
                fi
                local max_rm=$((CONTAINER_COUNT - 1))
                read -p "  How many to remove? (1-${max_rm}): " rm_count < /dev/tty || true
                if ! [[ "$rm_count" =~ ^[0-9]+$ ]] || [ "$rm_count" -lt 1 ] || [ "$rm_count" -gt "$max_rm" ]; then
                    echo -e "  ${RED}Invalid.${NC}"
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    continue
                fi
                local old_count=$CONTAINER_COUNT
                CONTAINER_COUNT=$((CONTAINER_COUNT - rm_count))
                save_settings
                # Remove containers in parallel
                local _rm_pids=() _rm_names=()
                for i in $(seq $((CONTAINER_COUNT + 1)) $old_count); do
                    local name=$(get_container_name $i)
                    _rm_names+=("$name")
                    ( docker rm -f "$name" >/dev/null 2>&1 ) &
                    _rm_pids+=($!)
                done
                for idx in "${!_rm_pids[@]}"; do
                    if wait "${_rm_pids[$idx]}" 2>/dev/null; then
                        echo -e "  ${YELLOW}✓ ${_rm_names[$idx]} removed${NC}"
                    else
                        echo -e "  ${RED}✗ Failed to remove ${_rm_names[$idx]}${NC}"
                    fi
                done
                read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                ;;
            s)
                read -p "  Start which container? (1-${CONTAINER_COUNT}, or 'all'): " sc_idx < /dev/tty || true
                local sc_targets=()
                if [ "$sc_idx" = "all" ]; then
                    for i in $(seq 1 $CONTAINER_COUNT); do sc_targets+=($i); done
                elif [[ "$sc_idx" =~ ^[1-5]$ ]] && [ "$sc_idx" -le "$CONTAINER_COUNT" ]; then
                    sc_targets+=($sc_idx)
                else
                    echo -e "  ${RED}Invalid.${NC}"
                fi
                # Batch: get all existing containers and their inspect data in one call
                local existing_containers=$(docker ps -a --format '{{.Names}}' 2>/dev/null)
                local all_inspect=""
                local inspect_names=""
                for i in "${sc_targets[@]}"; do
                    local cn=$(get_container_name $i)
                    echo "$existing_containers" | grep -q "^${cn}$" && inspect_names+=" $cn"
                done
                [ -n "$inspect_names" ] && all_inspect=$(docker inspect --format '{{.Name}} {{.HostConfig.NanoCpus}} {{.HostConfig.Memory}}' $inspect_names 2>/dev/null)

                for i in "${sc_targets[@]}"; do
                    local name=$(get_container_name $i)
                    local vol=$(get_volume_name $i)
                    if echo "$existing_containers" | grep -q "^${name}$"; then
                        # Check if settings changed — recreate if needed
                        local needs_recreate=false
                        local want_cpus=$(get_container_cpus $i)
                        local want_mem=$(get_container_memory $i)
                        local insp_line=$(echo "$all_inspect" | grep "/${name} " 2>/dev/null)
                        local cur_nano=$(echo "$insp_line" | awk '{print $2}')
                        local cur_memb=$(echo "$insp_line" | awk '{print $3}')
                        local want_nano=0
                        [ -n "$want_cpus" ] && want_nano=$(awk -v c="$want_cpus" 'BEGIN{printf "%.0f", c*1000000000}')
                        local want_memb=0
                        if [ -n "$want_mem" ]; then
                            local mv=${want_mem%[mMgG]}; local mu=${want_mem: -1}
                            [[ "$mu" =~ [gG] ]] && want_memb=$((mv * 1073741824)) || want_memb=$((mv * 1048576))
                        fi
                        [ "${cur_nano:-0}" != "$want_nano" ] && needs_recreate=true
                        [ "${cur_memb:-0}" != "$want_memb" ] && needs_recreate=true
                        if [ "$needs_recreate" = true ]; then
                            echo -e "  Settings changed for ${name}, recreating..."
                            docker rm -f "$name" 2>/dev/null || true
                            docker volume create "$vol" 2>/dev/null || true
                            fix_volume_permissions $i
                            run_conduit_container $i
                        else
                            docker start "$name" 2>/dev/null
                        fi
                    else
                        docker volume create "$vol" 2>/dev/null || true
                        fix_volume_permissions $i
                        run_conduit_container $i
                    fi
                    if [ $? -eq 0 ]; then
                        echo -e "  ${GREEN}✓ ${name} started${NC}"
                    else
                        echo -e "  ${RED}✗ Failed to start ${name}${NC}"
                    fi
                done
                # Ensure tracker service is running when containers are started
                setup_tracker_service 2>/dev/null || true
                read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                ;;
            t)
                read -p "  Stop which container? (1-${CONTAINER_COUNT}, or 'all'): " sc_idx < /dev/tty || true
                if [ "$sc_idx" = "all" ]; then
                    # Stop all containers in parallel with short timeout
                    local _stop_pids=()
                    local _stop_names=()
                    for i in $(seq 1 $CONTAINER_COUNT); do
                        local name=$(get_container_name $i)
                        _stop_names+=("$name")
                        ( docker stop -t 3 "$name" >/dev/null 2>&1 ) &
                        _stop_pids+=($!)
                    done
                    for idx in "${!_stop_pids[@]}"; do
                        if wait "${_stop_pids[$idx]}" 2>/dev/null; then
                            echo -e "  ${YELLOW}✓ ${_stop_names[$idx]} stopped${NC}"
                        else
                            echo -e "  ${YELLOW}  ${_stop_names[$idx]} was not running${NC}"
                        fi
                    done
                elif [[ "$sc_idx" =~ ^[1-5]$ ]] && [ "$sc_idx" -le "$CONTAINER_COUNT" ]; then
                    local name=$(get_container_name $sc_idx)
                    if docker stop -t 3 "$name" 2>/dev/null; then
                        echo -e "  ${YELLOW}✓ ${name} stopped${NC}"
                    else
                        echo -e "  ${YELLOW}  ${name} was not running${NC}"
                    fi
                else
                    echo -e "  ${RED}Invalid.${NC}"
                fi
                read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                ;;
            x)
                read -p "  Restart which container? (1-${CONTAINER_COUNT}, or 'all'): " sc_idx < /dev/tty || true
                local xc_targets=()
                if [ "$sc_idx" = "all" ]; then
                    local persist_dir="$INSTALL_DIR/traffic_stats"
                    if [ -s "$persist_dir/cumulative_data" ] || [ -s "$persist_dir/cumulative_ips" ]; then
                        echo -e "  ${CYAN}⟳ Saving tracker data snapshot...${NC}"
                        [ -s "$persist_dir/cumulative_data" ] && cp "$persist_dir/cumulative_data" "$persist_dir/cumulative_data.bak"
                        [ -s "$persist_dir/cumulative_ips" ] && cp "$persist_dir/cumulative_ips" "$persist_dir/cumulative_ips.bak"
                        [ -s "$persist_dir/geoip_cache" ] && cp "$persist_dir/geoip_cache" "$persist_dir/geoip_cache.bak"
                        echo -e "  ${GREEN}✓ Tracker data snapshot saved${NC}"
                    fi
                    for i in $(seq 1 $CONTAINER_COUNT); do xc_targets+=($i); done
                elif [[ "$sc_idx" =~ ^[1-5]$ ]] && [ "$sc_idx" -le "$CONTAINER_COUNT" ]; then
                    xc_targets+=($sc_idx)
                else
                    echo -e "  ${RED}Invalid.${NC}"
                fi
                # Batch: get all existing containers and inspect data in one call
                local existing_containers=$(docker ps -a --format '{{.Names}}' 2>/dev/null)
                local all_inspect=""
                local inspect_names=""
                for i in "${xc_targets[@]}"; do
                    local cn=$(get_container_name $i)
                    echo "$existing_containers" | grep -q "^${cn}$" && inspect_names+=" $cn"
                done
                [ -n "$inspect_names" ] && all_inspect=$(docker inspect --format '{{.Name}} {{join .Args " "}} |||{{.HostConfig.NanoCpus}} {{.HostConfig.Memory}}' $inspect_names 2>/dev/null)

                for i in "${xc_targets[@]}"; do
                    local name=$(get_container_name $i)
                    local vol=$(get_volume_name $i)
                    local needs_recreate=false
                    local want_cpus=$(get_container_cpus $i)
                    local want_mem=$(get_container_memory $i)
                    local want_mc=$(get_container_max_clients $i)
                    local want_bw=$(get_container_bandwidth $i)
                    if echo "$existing_containers" | grep -q "^${name}$"; then
                        local insp_line=$(echo "$all_inspect" | grep "/${name} " 2>/dev/null)
                        local cur_args=$(echo "$insp_line" | sed 's/.*\/'"$name"' //' | sed 's/ |||.*//')
                        local cur_mc=$(echo "$cur_args" | sed -n 's/.*--max-clients \([^ ]*\).*/\1/p' 2>/dev/null)
                        local cur_bw=$(echo "$cur_args" | sed -n 's/.*--bandwidth \([^ ]*\).*/\1/p' 2>/dev/null)
                        [ "$cur_mc" != "$want_mc" ] && needs_recreate=true
                        [ "$cur_bw" != "$want_bw" ] && needs_recreate=true
                        local cur_nano=$(echo "$insp_line" | sed 's/.*|||//' | awk '{print $1}')
                        local cur_memb=$(echo "$insp_line" | sed 's/.*|||//' | awk '{print $2}')
                        local want_nano=0
                        [ -n "$want_cpus" ] && want_nano=$(awk -v c="$want_cpus" 'BEGIN{printf "%.0f", c*1000000000}')
                        local want_memb=0
                        if [ -n "$want_mem" ]; then
                            local mv=${want_mem%[mMgG]}; local mu=${want_mem: -1}
                            [[ "$mu" =~ [gG] ]] && want_memb=$((mv * 1073741824)) || want_memb=$((mv * 1048576))
                        fi
                        [ "${cur_nano:-0}" != "$want_nano" ] && needs_recreate=true
                        [ "${cur_memb:-0}" != "$want_memb" ] && needs_recreate=true
                    fi
                    if [ "$needs_recreate" = true ]; then
                        echo -e "  Settings changed for ${name}, recreating..."
                        docker rm -f "$name" 2>/dev/null || true
                        docker volume create "$vol" 2>/dev/null || true
                        fix_volume_permissions $i
                        run_conduit_container $i
                        if [ $? -eq 0 ]; then
                            echo -e "  ${GREEN}✓ ${name} recreated with new settings${NC}"
                        else
                            echo -e "  ${RED}✗ Failed to recreate ${name}${NC}"
                        fi
                    else
                        if docker restart -t 3 "$name" 2>/dev/null; then
                            echo -e "  ${GREEN}✓ ${name} restarted${NC}"
                        else
                            echo -e "  ${RED}✗ Failed to restart ${name}${NC}"
                        fi
                    fi
                done
                # Restart tracker to pick up new container state
                if command -v systemctl &>/dev/null && systemctl is-active --quiet conduit-tracker.service 2>/dev/null; then
                    systemctl restart conduit-tracker.service 2>/dev/null || true
                fi
                read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                ;;
            q)
                show_qr_code
                ;;
            b|"")
                stop_manage=1
                ;;
            *)
                echo -e "  ${RED}Invalid option.${NC}"
                read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                ;;
        esac
    done
    echo -ne "\033[?25h"
    tput rmcup 2>/dev/null || true
    trap - SIGINT SIGTERM
}

# Get default network interface
get_default_iface() {
    local iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
    [ -z "$iface" ] && iface=$(ip route list default 2>/dev/null | awk '{print $5}')
    echo "${iface:-eth0}"
}

# Get current data usage since baseline (in bytes)
get_data_usage() {
    local iface="${DATA_CAP_IFACE:-$(get_default_iface)}"
    if [ ! -f "/sys/class/net/$iface/statistics/rx_bytes" ]; then
        echo "0 0"
        return
    fi
    local rx=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
    local tx=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)
    local used_rx=$((rx - DATA_CAP_BASELINE_RX))
    local used_tx=$((tx - DATA_CAP_BASELINE_TX))
    # Handle counter reset (reboot) - re-baseline to current counters
    # Prior usage is preserved in DATA_CAP_PRIOR_USAGE via check_data_cap
    if [ "$used_rx" -lt 0 ] || [ "$used_tx" -lt 0 ]; then
        DATA_CAP_BASELINE_RX=$rx
        DATA_CAP_BASELINE_TX=$tx
        save_settings
        used_rx=0
        used_tx=0
    fi
    echo "$used_rx $used_tx"
}

# Check data cap and stop containers if exceeded
# Returns 1 if cap exceeded, 0 if OK or no cap set
DATA_CAP_EXCEEDED=false
_DATA_CAP_LAST_SAVED=0
check_data_cap() {
    [ "$DATA_CAP_GB" -eq 0 ] 2>/dev/null && return 0
    # Validate DATA_CAP_GB is numeric
    if ! [[ "$DATA_CAP_GB" =~ ^[0-9]+$ ]]; then
        return 0  # invalid cap value, treat as no cap
    fi
    local usage=$(get_data_usage)
    local used_rx=$(echo "$usage" | awk '{print $1}')
    local used_tx=$(echo "$usage" | awk '{print $2}')
    local session_used=$((used_rx + used_tx))
    local total_used=$((session_used + ${DATA_CAP_PRIOR_USAGE:-0}))
    # Periodically persist usage so it survives reboots (save every ~100MB change)
    local save_threshold=104857600
    local diff=$((total_used - _DATA_CAP_LAST_SAVED))
    [ "$diff" -lt 0 ] && diff=$((-diff))
    if [ "$diff" -ge "$save_threshold" ]; then
        DATA_CAP_PRIOR_USAGE=$total_used
        DATA_CAP_BASELINE_RX=$(cat /sys/class/net/${DATA_CAP_IFACE:-$(get_default_iface)}/statistics/rx_bytes 2>/dev/null || echo 0)
        DATA_CAP_BASELINE_TX=$(cat /sys/class/net/${DATA_CAP_IFACE:-$(get_default_iface)}/statistics/tx_bytes 2>/dev/null || echo 0)
        save_settings
        _DATA_CAP_LAST_SAVED=$total_used
    fi
    local cap_bytes=$(awk -v gb="$DATA_CAP_GB" 'BEGIN{printf "%.0f", gb * 1073741824}')
    if [ "$total_used" -ge "$cap_bytes" ] 2>/dev/null; then
        # Only stop containers once when cap is first exceeded
        if [ "$DATA_CAP_EXCEEDED" = false ]; then
            DATA_CAP_EXCEEDED=true
            DATA_CAP_PRIOR_USAGE=$total_used
            DATA_CAP_BASELINE_RX=$(cat /sys/class/net/${DATA_CAP_IFACE:-$(get_default_iface)}/statistics/rx_bytes 2>/dev/null || echo 0)
            DATA_CAP_BASELINE_TX=$(cat /sys/class/net/${DATA_CAP_IFACE:-$(get_default_iface)}/statistics/tx_bytes 2>/dev/null || echo 0)
            save_settings
            _DATA_CAP_LAST_SAVED=$total_used
            # Signal tracker to skip stuck-container restarts
            touch "$PERSIST_DIR/data_cap_exceeded" 2>/dev/null
            for i in $(seq 1 $CONTAINER_COUNT); do
                local name=$(get_container_name $i)
                docker stop "$name" 2>/dev/null || true
            done
        fi
        return 1  # cap exceeded
    else
        DATA_CAP_EXCEEDED=false
        rm -f "$PERSIST_DIR/data_cap_exceeded" 2>/dev/null
    fi
    return 0
}

# Format bytes to GB with 2 decimal places
format_gb() {
    awk -v b="$1" 'BEGIN{printf "%.2f", b / 1073741824}'
}

set_data_cap() {
    local iface=$(get_default_iface)
    echo ""
    echo -e "${CYAN}═══ DATA USAGE CAP ═══${NC}"
    if [ "$DATA_CAP_GB" -gt 0 ] 2>/dev/null; then
        local usage=$(get_data_usage)
        local used_rx=$(echo "$usage" | awk '{print $1}')
        local used_tx=$(echo "$usage" | awk '{print $2}')
        local total_used=$((used_rx + used_tx))
        echo -e "  Current cap:   ${GREEN}${DATA_CAP_GB} GB${NC}"
        echo -e "  Used:          $(format_gb $total_used) GB"
        echo -e "  Interface:     ${DATA_CAP_IFACE:-$iface}"
    else
        echo -e "  Current cap:   ${YELLOW}None${NC}"
        echo -e "  Interface:     $iface"
    fi
    echo ""
    echo "  Options:"
    echo "    1. Set new data cap"
    echo "    2. Reset usage counter"
    echo "    3. Remove cap"
    echo "    4. Back"
    echo ""
    read -p "  Choice: " cap_choice < /dev/tty || true

    case "$cap_choice" in
        1)
            read -p "  Enter cap in GB (e.g. 50): " new_cap < /dev/tty || true
            if [[ "$new_cap" =~ ^[0-9]+$ ]] && [ "$new_cap" -gt 0 ]; then
                DATA_CAP_GB=$new_cap
                DATA_CAP_IFACE=$iface
                DATA_CAP_PRIOR_USAGE=0
                # Snapshot current bytes as baseline
                DATA_CAP_BASELINE_RX=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
                DATA_CAP_BASELINE_TX=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)
                save_settings
                echo -e "  ${GREEN}✓ Data cap set to ${new_cap} GB on ${iface}${NC}"
            else
                echo -e "  ${RED}Invalid value.${NC}"
            fi
            ;;
        2)
            DATA_CAP_PRIOR_USAGE=0
            DATA_CAP_BASELINE_RX=$(cat /sys/class/net/${DATA_CAP_IFACE:-$iface}/statistics/rx_bytes 2>/dev/null || echo 0)
            DATA_CAP_BASELINE_TX=$(cat /sys/class/net/${DATA_CAP_IFACE:-$iface}/statistics/tx_bytes 2>/dev/null || echo 0)
            save_settings
            echo -e "  ${GREEN}✓ Usage counter reset${NC}"
            ;;
        3)
            DATA_CAP_GB=0
            DATA_CAP_BASELINE_RX=0
            DATA_CAP_BASELINE_TX=0
            DATA_CAP_PRIOR_USAGE=0
            DATA_CAP_IFACE=""
            save_settings
            echo -e "  ${GREEN}✓ Data cap removed${NC}"
            ;;
        4|"")
            return
            ;;
    esac
}

# Save all settings to file
save_settings() {
    local _tmp="$INSTALL_DIR/settings.conf.tmp.$$"
    cat > "$_tmp" << EOF
MAX_CLIENTS=$MAX_CLIENTS
BANDWIDTH=$BANDWIDTH
CONTAINER_COUNT=$CONTAINER_COUNT
DATA_CAP_GB=$DATA_CAP_GB
DATA_CAP_IFACE=$DATA_CAP_IFACE
DATA_CAP_BASELINE_RX=$DATA_CAP_BASELINE_RX
DATA_CAP_BASELINE_TX=$DATA_CAP_BASELINE_TX
DATA_CAP_PRIOR_USAGE=${DATA_CAP_PRIOR_USAGE:-0}
TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID"
TELEGRAM_INTERVAL=${TELEGRAM_INTERVAL:-6}
TELEGRAM_ENABLED=${TELEGRAM_ENABLED:-false}
TELEGRAM_ALERTS_ENABLED=${TELEGRAM_ALERTS_ENABLED:-true}
TELEGRAM_DAILY_SUMMARY=${TELEGRAM_DAILY_SUMMARY:-true}
TELEGRAM_WEEKLY_SUMMARY=${TELEGRAM_WEEKLY_SUMMARY:-true}
TELEGRAM_SERVER_LABEL="${TELEGRAM_SERVER_LABEL:-}"
TELEGRAM_START_HOUR=${TELEGRAM_START_HOUR:-0}
DOCKER_CPUS=${DOCKER_CPUS:-}
DOCKER_MEMORY=${DOCKER_MEMORY:-}
EOF
    # Save per-container overrides
    for i in $(seq 1 5); do
        local mc_var="MAX_CLIENTS_${i}"
        local bw_var="BANDWIDTH_${i}"
        local cpu_var="CPUS_${i}"
        local mem_var="MEMORY_${i}"
        [ -n "${!mc_var}" ] && echo "${mc_var}=${!mc_var}" >> "$_tmp"
        [ -n "${!bw_var}" ] && echo "${bw_var}=${!bw_var}" >> "$_tmp"
        [ -n "${!cpu_var}" ] && echo "${cpu_var}=${!cpu_var}" >> "$_tmp"
        [ -n "${!mem_var}" ] && echo "${mem_var}=${!mem_var}" >> "$_tmp"
    done
    chmod 600 "$_tmp" 2>/dev/null || true
    mv "$_tmp" "$INSTALL_DIR/settings.conf"
}

# ─── Telegram Bot Functions ───────────────────────────────────────────────────

escape_telegram_markdown() {
    local text="$1"
    text="${text//\\/\\\\}"
    text="${text//\*/\\*}"
    text="${text//_/\\_}"
    text="${text//\`/\\\`}"
    text="${text//\[/\\[}"
    text="${text//\]/\\]}"
    echo "$text"
}

telegram_send_message() {
    local message="$1"
    { [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; } && return 1
    # Prepend server label + IP (escape for Markdown)
    local label="${TELEGRAM_SERVER_LABEL:-$(hostname 2>/dev/null || echo 'unknown')}"
    label=$(escape_telegram_markdown "$label")
    local _ip=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null || echo "")
    if [ -n "$_ip" ]; then
        message="[${label} | ${_ip}] ${message}"
    else
        message="[${label}] ${message}"
    fi
    local response
    response=$(curl -s --max-time 10 --max-filesize 1048576 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
        --data-urlencode "text=$message" \
        --data-urlencode "parse_mode=Markdown" 2>/dev/null)
    [ $? -ne 0 ] && return 1
    echo "$response" | grep -q '"ok":true' && return 0
    return 1
}

telegram_test_message() {
    local interval_label="${TELEGRAM_INTERVAL:-6}"
    local report=$(telegram_build_report)
    local message="✅ *Conduit Manager Connected!*

🔗 *What is Psiphon Conduit?*
You are running a Psiphon relay node that helps people in censored regions access the open internet.

📬 *What this bot sends you every ${interval_label}h:*
• Container status & uptime
• Connected peers count
• Upload & download totals
• CPU & RAM usage
• Data cap usage (if set)
• Top countries being served

⚠️ *Alerts:*
If a container gets stuck and is auto-restarted, you will receive an immediate alert.

━━━━━━━━━━━━━━━━━━━━
🎮 *Available Commands:*
━━━━━━━━━━━━━━━━━━━━
/status — Full status report on demand
/peers — Show connected & connecting clients
/uptime — Uptime for each container
/containers — List all containers with status
/start\_N — Start container N (e.g. /start\_1)
/stop\_N — Stop container N (e.g. /stop\_2)
/restart\_N — Restart container N (e.g. /restart\_1)

Replace N with the container number (1-5).

━━━━━━━━━━━━━━━━━━━━
📊 *Your first report:*
━━━━━━━━━━━━━━━━━━━━

${report}"
    telegram_send_message "$message"
}

telegram_get_chat_id() {
    local response
    response=$(curl -s --max-time 10 --max-filesize 1048576 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates" 2>/dev/null)
    [ -z "$response" ] && return 1
    # Verify API returned success
    echo "$response" | grep -q '"ok":true' || return 1
    # Extract chat id: find "message"..."chat":{"id":NUMBER pattern
    # Use python if available for reliable JSON parsing, fall back to grep
    local chat_id=""
    if command -v python3 &>/dev/null; then
        chat_id=$(python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    msgs=d.get('result',[])
    if msgs:
        print(msgs[-1]['message']['chat']['id'])
except: pass
" <<< "$response" 2>/dev/null)
    fi
    # Fallback: POSIX-compatible grep extraction
    if [ -z "$chat_id" ]; then
        chat_id=$(echo "$response" | grep -o '"chat"[[:space:]]*:[[:space:]]*{[[:space:]]*"id"[[:space:]]*:[[:space:]]*-*[0-9]*' | grep -o -- '-*[0-9]*$' | tail -1 2>/dev/null)
    fi
    if [ -n "$chat_id" ]; then
        # Validate chat_id is numeric (with optional leading minus for groups)
        if ! echo "$chat_id" | grep -qE '^-?[0-9]+$'; then
            return 1
        fi
        TELEGRAM_CHAT_ID="$chat_id"
        return 0
    fi
    return 1
}

telegram_build_report() {
    local report="📊 *Conduit Status Report*"
    report+=$'\n'
    report+="🕐 $(date '+%Y-%m-%d %H:%M %Z')"
    report+=$'\n'
    report+=$'\n'

    # Container status & uptime (check all containers, use earliest start)
    local running_count=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "^conduit" 2>/dev/null || true)
    running_count=${running_count:-0}
    local total=$CONTAINER_COUNT
    if [ "$running_count" -gt 0 ]; then
        local earliest_start=""
        for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
            local cname=$(get_container_name $i)
            local started=$(docker inspect --format='{{.State.StartedAt}}' "$cname" 2>/dev/null | cut -d'.' -f1)
            if [ -n "$started" ]; then
                local se=$(date -d "$started" +%s 2>/dev/null || echo 0)
                if [ -z "$earliest_start" ] || [ "$se" -lt "$earliest_start" ] 2>/dev/null; then
                    earliest_start=$se
                fi
            fi
        done
        if [ -n "$earliest_start" ] && [ "$earliest_start" -gt 0 ] 2>/dev/null; then
            local now=$(date +%s)
            local up=$((now - earliest_start))
            local days=$((up / 86400))
            local hours=$(( (up % 86400) / 3600 ))
            local mins=$(( (up % 3600) / 60 ))
            if [ "$days" -gt 0 ]; then
                report+="⏱ Uptime: ${days}d ${hours}h ${mins}m"
            else
                report+="⏱ Uptime: ${hours}h ${mins}m"
            fi
            report+=$'\n'
        fi
    fi
    report+="📦 Containers: ${running_count}/${total} running"
    report+=$'\n'

    # Uptime percentage + streak
    local uptime_log="$INSTALL_DIR/traffic_stats/uptime_log"
    if [ -s "$uptime_log" ]; then
        local cutoff_24h=$(( $(date +%s) - 86400 ))
        local t24=$(awk -F'|' -v c="$cutoff_24h" '$1+0>=c' "$uptime_log" 2>/dev/null | wc -l)
        local u24=$(awk -F'|' -v c="$cutoff_24h" '$1+0>=c && $2+0>0' "$uptime_log" 2>/dev/null | wc -l)
        if [ "${t24:-0}" -gt 0 ] 2>/dev/null; then
            local avail_24h=$(awk "BEGIN {printf \"%.1f\", ($u24/$t24)*100}" 2>/dev/null || echo "0")
            report+="📈 Availability: ${avail_24h}% (24h)"
            report+=$'\n'
        fi
        # Streak: consecutive minutes at end of log with running > 0
        local streak_mins=$(awk -F'|' '{a[NR]=$2+0} END{n=0; for(i=NR;i>=1;i--){if(a[i]<=0) break; n++} print n}' "$uptime_log" 2>/dev/null)
        if [ "${streak_mins:-0}" -gt 0 ] 2>/dev/null; then
            local sd=$((streak_mins / 1440)) sh=$(( (streak_mins % 1440) / 60 )) sm=$((streak_mins % 60))
            local streak_str=""
            [ "$sd" -gt 0 ] && streak_str+="${sd}d "
            streak_str+="${sh}h ${sm}m"
            report+="🔥 Streak: ${streak_str}"
            report+=$'\n'
        fi
    fi

    # Connected peers + connecting (matching TUI format)
    local total_peers=0
    local total_connecting=0
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        local cname=$(get_container_name $i)
        local last_stat=$(docker logs --tail 400 "$cname" 2>&1 | grep "\[STATS\]" | tail -1)
        local peers=$(echo "$last_stat" | awk '{for(j=1;j<=NF;j++){if($j=="Connected:") print $(j+1)+0}}' | head -1)
        local cing=$(echo "$last_stat" | awk '{for(j=1;j<=NF;j++){if($j=="Connecting:") print $(j+1)+0}}' | head -1)
        total_peers=$((total_peers + ${peers:-0}))
        total_connecting=$((total_connecting + ${cing:-0}))
    done
    report+="👥 Clients: ${total_peers} connected, ${total_connecting} connecting"
    report+=$'\n'

    # CPU / RAM (normalize CPU by core count like dashboard)
    local stats=$(get_container_stats)
    local raw_cpu=$(echo "$stats" | awk '{print $1}')
    local cores=$(get_cpu_cores)
    local cpu=$(awk "BEGIN {printf \"%.1f%%\", ${raw_cpu%\%} / $cores}" 2>/dev/null || echo "$raw_cpu")
    local ram=$(echo "$stats" | awk '{print $2, $3, $4}')
    cpu=$(escape_telegram_markdown "$cpu")
    ram=$(escape_telegram_markdown "$ram")
    report+="🖥 CPU: ${cpu} | RAM: ${ram}"
    report+=$'\n'

    # Data usage
    if [ "${DATA_CAP_GB:-0}" -gt 0 ] 2>/dev/null; then
        local usage=$(get_data_usage 2>/dev/null)
        local used_rx=$(echo "$usage" | awk '{print $1}')
        local used_tx=$(echo "$usage" | awk '{print $2}')
        local total_used=$(( ${used_rx:-0} + ${used_tx:-0} + ${DATA_CAP_PRIOR_USAGE:-0} ))
        local used_gb=$(awk "BEGIN {printf \"%.2f\", $total_used/1073741824}" 2>/dev/null || echo "0")
        report+="📈 Data: ${used_gb} GB / ${DATA_CAP_GB} GB"
        report+=$'\n'
    fi

    # Container restart counts
    local total_restarts=0
    local restart_details=""
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        local cname=$(get_container_name $i)
        local rc=$(docker inspect --format='{{.RestartCount}}' "$cname" 2>/dev/null || echo 0)
        rc=${rc:-0}
        total_restarts=$((total_restarts + rc))
        [ "$rc" -gt 0 ] && restart_details+=" C${i}:${rc}"
    done
    if [ "$total_restarts" -gt 0 ]; then
        report+="🔄 Restarts: ${total_restarts}${restart_details}"
        report+=$'\n'
    fi

    # Top countries by connected peers (from tracker snapshot)
    local snap_file_peers="$INSTALL_DIR/traffic_stats/tracker_snapshot"
    if [ -s "$snap_file_peers" ]; then
        local top_peers
        top_peers=$(awk -F'|' '{if($2!="") cnt[$2]++} END{for(c in cnt) print cnt[c]"|"c}' "$snap_file_peers" 2>/dev/null | sort -t'|' -k1 -nr | head -3)
        if [ -n "$top_peers" ]; then
            report+="🗺 Top by peers:"
            report+=$'\n'
            while IFS='|' read -r cnt country; do
                [ -z "$country" ] && continue
                local safe_c=$(escape_telegram_markdown "$country")
                report+="  • ${safe_c}: ${cnt} clients"
                report+=$'\n'
            done <<< "$top_peers"
        fi
    fi

    # Top countries from cumulative_data (field 3 = upload bytes, matching dashboard)
    local data_file="$INSTALL_DIR/traffic_stats/cumulative_data"
    if [ -s "$data_file" ]; then
        local top_countries
        top_countries=$(awk -F'|' '{if($1!="" && $3+0>0) bytes[$1]+=$3+0} END{for(c in bytes) print bytes[c]"|"c}' "$data_file" 2>/dev/null | sort -t'|' -k1 -nr | head -3)
        if [ -n "$top_countries" ]; then
            report+="🌍 Top by upload:"
            report+=$'\n'
            while IFS='|' read -r bytes country; do
                [ -z "$country" ] && continue
                local safe_country=$(escape_telegram_markdown "$country")
                local fmt=$(format_bytes "$bytes" 2>/dev/null || echo "${bytes} B")
                report+="  • ${safe_country} (${fmt})"
                report+=$'\n'
            done <<< "$top_countries"
        fi
    fi

    # Unique IPs from tracker_snapshot
    local snapshot_file="$INSTALL_DIR/traffic_stats/tracker_snapshot"
    if [ -s "$snapshot_file" ]; then
        local active_clients=$(wc -l < "$snapshot_file" 2>/dev/null || echo 0)
        report+="📡 Total lifetime IPs served: ${active_clients}"
        report+=$'\n'
    fi

    # Total bandwidth served from cumulative_data
    if [ -s "$data_file" ]; then
        local total_bw
        total_bw=$(awk -F'|' '{s+=$2+0; s+=$3+0} END{printf "%.0f", s}' "$data_file" 2>/dev/null || echo 0)
        if [ "${total_bw:-0}" -gt 0 ] 2>/dev/null; then
            local total_bw_fmt=$(format_bytes "$total_bw" 2>/dev/null || echo "${total_bw} B")
            report+="📊 Total bandwidth served: ${total_bw_fmt}"
            report+=$'\n'
        fi
    fi

    echo "$report"
}

telegram_generate_notify_script() {
    cat > "$INSTALL_DIR/conduit-telegram.sh" << 'TGEOF'
#!/bin/bash
# Conduit Telegram Notification Service
# Runs as a systemd service, sends periodic status reports

INSTALL_DIR="/opt/conduit"

[ -f "$INSTALL_DIR/settings.conf" ] && source "$INSTALL_DIR/settings.conf"

# Exit if not configured
[ "$TELEGRAM_ENABLED" != "true" ] && exit 0
[ -z "$TELEGRAM_BOT_TOKEN" ] && exit 0
[ -z "$TELEGRAM_CHAT_ID" ] && exit 0

# Cache server IP once at startup
_server_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
    || curl -s --max-time 5 https://ifconfig.me 2>/dev/null \
    || echo "")

telegram_send() {
    local message="$1"
    # Prepend server label + IP (escape for Markdown)
    local label="${TELEGRAM_SERVER_LABEL:-$(hostname 2>/dev/null || echo 'unknown')}"
    label=$(escape_md "$label")
    if [ -n "$_server_ip" ]; then
        message="[${label} | ${_server_ip}] ${message}"
    else
        message="[${label}] ${message}"
    fi
    curl -s --max-time 10 --max-filesize 1048576 -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
        --data-urlencode "text=$message" \
        --data-urlencode "parse_mode=Markdown" >/dev/null 2>&1
}

escape_md() {
    local text="$1"
    text="${text//\\/\\\\}"
    text="${text//\*/\\*}"
    text="${text//_/\\_}"
    text="${text//\`/\\\`}"
    text="${text//\[/\\[}"
    text="${text//\]/\\]}"
    echo "$text"
}

get_container_name() {
    local i=$1
    if [ "$i" -le 1 ]; then
        echo "conduit"
    else
        echo "conduit-${i}"
    fi
}

get_cpu_cores() {
    local cores=1
    if command -v nproc &>/dev/null; then
        cores=$(nproc)
    elif [ -f /proc/cpuinfo ]; then
        cores=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
    fi
    [ "$cores" -lt 1 ] 2>/dev/null && cores=1
    echo "$cores"
}

track_uptime() {
    local running=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "^conduit" 2>/dev/null || true)
    running=${running:-0}
    echo "$(date +%s)|${running}" >> "$INSTALL_DIR/traffic_stats/uptime_log"
    # Trim to 10080 lines (7 days of per-minute entries)
    local log_file="$INSTALL_DIR/traffic_stats/uptime_log"
    local lines=$(wc -l < "$log_file" 2>/dev/null || echo 0)
    if [ "$lines" -gt 10080 ] 2>/dev/null; then
        tail -10080 "$log_file" > "${log_file}.tmp" && mv "${log_file}.tmp" "$log_file"
    fi
}

calc_uptime_pct() {
    local period_secs=${1:-86400}
    local log_file="$INSTALL_DIR/traffic_stats/uptime_log"
    [ ! -s "$log_file" ] && echo "0" && return
    local cutoff=$(( $(date +%s) - period_secs ))
    local total=0
    local up=0
    while IFS='|' read -r ts count; do
        [ "$ts" -lt "$cutoff" ] 2>/dev/null && continue
        total=$((total + 1))
        [ "$count" -gt 0 ] 2>/dev/null && up=$((up + 1))
    done < "$log_file"
    [ "$total" -eq 0 ] && echo "0" && return
    awk "BEGIN {printf \"%.1f\", ($up/$total)*100}" 2>/dev/null || echo "0"
}

rotate_cumulative_data() {
    local data_file="$INSTALL_DIR/traffic_stats/cumulative_data"
    local marker="$INSTALL_DIR/traffic_stats/.last_rotation_month"
    local current_month=$(date '+%Y-%m')
    local last_month=""
    [ -f "$marker" ] && last_month=$(cat "$marker" 2>/dev/null)
    # First run: just set the marker, don't archive
    if [ -z "$last_month" ]; then
        echo "$current_month" > "$marker"
        return
    fi
    if [ "$current_month" != "$last_month" ] && [ -s "$data_file" ]; then
        cp "$data_file" "${data_file}.${last_month}"
        echo "$current_month" > "$marker"
        # Delete archives older than 3 months (portable: 90 days in seconds)
        local cutoff_ts=$(( $(date +%s) - 7776000 ))
        for archive in "$INSTALL_DIR/traffic_stats/cumulative_data."[0-9][0-9][0-9][0-9]-[0-9][0-9]; do
            [ ! -f "$archive" ] && continue
            local archive_mtime=$(stat -c %Y "$archive" 2>/dev/null || stat -f %m "$archive" 2>/dev/null || echo 0)
            if [ "$archive_mtime" -gt 0 ] && [ "$archive_mtime" -lt "$cutoff_ts" ] 2>/dev/null; then
                rm -f "$archive"
            fi
        done
    fi
}

check_alerts() {
    [ "$TELEGRAM_ALERTS_ENABLED" != "true" ] && return
    local now=$(date +%s)
    local cooldown=3600

    # CPU + RAM check (single docker stats call)
    local conduit_containers=$(docker ps --format '{{.Names}}' 2>/dev/null | grep "^conduit" 2>/dev/null || true)
    local stats_line=""
    if [ -n "$conduit_containers" ]; then
        stats_line=$(timeout 10 docker stats --no-stream --format "{{.CPUPerc}} {{.MemPerc}}" $conduit_containers 2>/dev/null | head -1)
    fi
    local raw_cpu=$(echo "$stats_line" | awk '{print $1}')
    local ram_pct=$(echo "$stats_line" | awk '{print $2}')

    local cores=$(get_cpu_cores)
    local cpu_val=$(awk "BEGIN {printf \"%.0f\", ${raw_cpu%\%} / $cores}" 2>/dev/null || echo 0)
    if [ "${cpu_val:-0}" -gt 90 ] 2>/dev/null; then
        cpu_breach=$((cpu_breach + 1))
    else
        cpu_breach=0
    fi
    if [ "$cpu_breach" -ge 3 ] && [ $((now - last_alert_cpu)) -ge $cooldown ] 2>/dev/null; then
        telegram_send "⚠️ *Alert: High CPU*
CPU usage at ${cpu_val}% for 3\\+ minutes"
        last_alert_cpu=$now
        cpu_breach=0
    fi

    local ram_val=${ram_pct%\%}
    ram_val=${ram_val%%.*}
    if [ "${ram_val:-0}" -gt 90 ] 2>/dev/null; then
        ram_breach=$((ram_breach + 1))
    else
        ram_breach=0
    fi
    if [ "$ram_breach" -ge 3 ] && [ $((now - last_alert_ram)) -ge $cooldown ] 2>/dev/null; then
        telegram_send "⚠️ *Alert: High RAM*
Memory usage at ${ram_pct} for 3\\+ minutes"
        last_alert_ram=$now
        ram_breach=0
    fi

    # All containers down
    local running=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "^conduit" 2>/dev/null || true)
    running=${running:-0}
    if [ "$running" -eq 0 ] 2>/dev/null && [ $((now - last_alert_down)) -ge $cooldown ] 2>/dev/null; then
        telegram_send "🔴 *Alert: All containers down*
No Conduit containers are running\\!"
        last_alert_down=$now
    fi

    # Zero peers for 2+ hours
    local total_peers=0
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        local cname=$(get_container_name $i)
        local last_stat=$(timeout 5 docker logs --tail 400 "$cname" 2>&1 | grep "\[STATS\]" | tail -1)
        local peers=$(echo "$last_stat" | awk '{for(j=1;j<=NF;j++){if($j=="Connected:") print $(j+1)+0}}' | head -1)
        total_peers=$((total_peers + ${peers:-0}))
    done
    if [ "$total_peers" -eq 0 ] 2>/dev/null; then
        if [ "$zero_peers_since" -eq 0 ] 2>/dev/null; then
            zero_peers_since=$now
        elif [ $((now - zero_peers_since)) -ge 7200 ] && [ $((now - last_alert_peers)) -ge $cooldown ] 2>/dev/null; then
            telegram_send "⚠️ *Alert: Zero peers*
No connected peers for 2\\+ hours"
            last_alert_peers=$now
            zero_peers_since=$now
        fi
    else
        zero_peers_since=0
    fi
}

record_snapshot() {
    local running=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "^conduit" 2>/dev/null || true)
    running=${running:-0}
    local total_peers=0
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        local cname=$(get_container_name $i)
        local last_stat=$(docker logs --tail 400 "$cname" 2>&1 | grep "\[STATS\]" | tail -1)
        local peers=$(echo "$last_stat" | awk '{for(j=1;j<=NF;j++){if($j=="Connected:") print $(j+1)+0}}' | head -1)
        total_peers=$((total_peers + ${peers:-0}))
    done
    local data_file="$INSTALL_DIR/traffic_stats/cumulative_data"
    local total_bw=0
    [ -s "$data_file" ] && total_bw=$(awk -F'|' '{s+=$2+$3} END{print s+0}' "$data_file" 2>/dev/null)
    echo "$(date +%s)|${total_peers}|${total_bw:-0}|${running}" >> "$INSTALL_DIR/traffic_stats/report_snapshots"
    # Trim to 720 entries
    local snap_file="$INSTALL_DIR/traffic_stats/report_snapshots"
    local lines=$(wc -l < "$snap_file" 2>/dev/null || echo 0)
    if [ "$lines" -gt 720 ] 2>/dev/null; then
        tail -720 "$snap_file" > "${snap_file}.tmp" && mv "${snap_file}.tmp" "$snap_file"
    fi
}

build_summary() {
    local period_label="$1"
    local period_secs="$2"
    local snap_file="$INSTALL_DIR/traffic_stats/report_snapshots"
    [ ! -s "$snap_file" ] && return
    local cutoff=$(( $(date +%s) - period_secs ))
    local peak_peers=0
    local sum_peers=0
    local count=0
    local first_bw=0
    local last_bw=0
    local got_first=false
    while IFS='|' read -r ts peers bw running; do
        [ "$ts" -lt "$cutoff" ] 2>/dev/null && continue
        count=$((count + 1))
        sum_peers=$((sum_peers + ${peers:-0}))
        [ "${peers:-0}" -gt "$peak_peers" ] 2>/dev/null && peak_peers=${peers:-0}
        if [ "$got_first" = false ]; then
            first_bw=${bw:-0}
            got_first=true
        fi
        last_bw=${bw:-0}
    done < "$snap_file"
    [ "$count" -eq 0 ] && return

    local avg_peers=$((sum_peers / count))
    local period_bw=$((${last_bw:-0} - ${first_bw:-0}))
    [ "$period_bw" -lt 0 ] 2>/dev/null && period_bw=0
    local bw_fmt=$(awk "BEGIN {b=$period_bw; if(b>1099511627776) printf \"%.2f TB\",b/1099511627776; else if(b>1073741824) printf \"%.2f GB\",b/1073741824; else printf \"%.1f MB\",b/1048576}" 2>/dev/null)
    local uptime_pct=$(calc_uptime_pct "$period_secs")

    # New countries detection
    local countries_file="$INSTALL_DIR/traffic_stats/known_countries"
    local data_file="$INSTALL_DIR/traffic_stats/cumulative_data"
    local new_countries=""
    if [ -s "$data_file" ]; then
        local current_countries=$(awk -F'|' '{if($1!="") print $1}' "$data_file" 2>/dev/null | sort -u)
        if [ -f "$countries_file" ]; then
            new_countries=$(comm -23 <(echo "$current_countries") <(sort "$countries_file") 2>/dev/null | head -5 | tr '\n' ', ' | sed 's/,$//')
        fi
        echo "$current_countries" > "$countries_file"
    fi

    local msg="📋 *${period_label} Summary*"
    msg+=$'\n'
    msg+="🕐 $(date '+%Y-%m-%d %H:%M %Z')"
    msg+=$'\n'
    msg+=$'\n'
    msg+="📊 Bandwidth served: ${bw_fmt}"
    msg+=$'\n'
    msg+="👥 Peak peers: ${peak_peers} | Avg: ${avg_peers}"
    msg+=$'\n'
    msg+="⏱ Uptime: ${uptime_pct}%"
    msg+=$'\n'
    msg+="📈 Data points: ${count}"
    if [ -n "$new_countries" ]; then
        local safe_new=$(escape_md "$new_countries")
        msg+=$'\n'"🆕 New countries: ${safe_new}"
    fi

    telegram_send "$msg"
}

process_commands() {
    local offset_file="$INSTALL_DIR/traffic_stats/last_update_id"
    local offset=0
    [ -f "$offset_file" ] && offset=$(cat "$offset_file" 2>/dev/null)
    offset=${offset:-0}
    # Ensure numeric
    [ "$offset" -eq "$offset" ] 2>/dev/null || offset=0

    local response
    response=$(curl -s --max-time 10 --max-filesize 1048576 \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?offset=$((offset + 1))&timeout=0" 2>/dev/null)
    [ -z "$response" ] && return

    # Parse with python3 if available, otherwise skip
    if ! command -v python3 &>/dev/null; then
        return
    fi

    local parsed
    parsed=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    if not data.get('ok'): sys.exit(0)
    results = data.get('result', [])
    if not results: sys.exit(0)
    for r in results:
        uid = r.get('update_id', 0)
        msg = r.get('message', {})
        chat_id = msg.get('chat', {}).get('id', 0)
        text = msg.get('text', '')
        if str(chat_id) == '$TELEGRAM_CHAT_ID' and text.startswith('/'):
            print(f'{uid}|{text}')
        else:
            print(f'{uid}|')
except Exception:
    # On parse failure, try to extract max update_id to avoid re-fetching
    try:
        data = json.loads(sys.argv[1])
        results = data.get('result', [])
        if results:
            max_uid = max(r.get('update_id', 0) for r in results)
            if max_uid > 0:
                print(f'{max_uid}|')
    except Exception:
        pass
" "$response" 2>/dev/null)

    [ -z "$parsed" ] && return

    local max_id=$offset
    while IFS='|' read -r uid cmd; do
        [ -z "$uid" ] && continue
        [ "$uid" -gt "$max_id" ] 2>/dev/null && max_id=$uid
        case "$cmd" in
            /status|/status@*)
                local report=$(build_report)
                telegram_send "$report"
                ;;
            /peers|/peers@*)
                local total_peers=0
                local total_cing=0
                for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
                    local cname=$(get_container_name $i)
                    local last_stat=$(timeout 5 docker logs --tail 400 "$cname" 2>&1 | grep "\[STATS\]" | tail -1)
                    local peers=$(echo "$last_stat" | awk '{for(j=1;j<=NF;j++){if($j=="Connected:") print $(j+1)+0}}' | head -1)
                    local cing=$(echo "$last_stat" | awk '{for(j=1;j<=NF;j++){if($j=="Connecting:") print $(j+1)+0}}' | head -1)
                    total_peers=$((total_peers + ${peers:-0}))
                    total_cing=$((total_cing + ${cing:-0}))
                done
                telegram_send "👥 Clients: ${total_peers} connected, ${total_cing} connecting"
                ;;
            /uptime|/uptime@*)
                local ut_msg="⏱ *Uptime Report*"
                ut_msg+=$'\n'
                for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
                    local cname=$(get_container_name $i)
                    local is_running=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "^${cname}$" || true)
                    if [ "${is_running:-0}" -gt 0 ]; then
                        local started=$(docker inspect --format='{{.State.StartedAt}}' "$cname" 2>/dev/null)
                        if [ -n "$started" ]; then
                            local se=$(date -d "$started" +%s 2>/dev/null || echo 0)
                            local diff=$(( $(date +%s) - se ))
                            local d=$((diff / 86400)) h=$(( (diff % 86400) / 3600 )) m=$(( (diff % 3600) / 60 ))
                            ut_msg+="📦 Container ${i}: ${d}d ${h}h ${m}m"
                        else
                            ut_msg+="📦 Container ${i}: ⚠ unknown"
                        fi
                    else
                        ut_msg+="📦 Container ${i}: 🔴 stopped"
                    fi
                    ut_msg+=$'\n'
                done
                local avail=$(calc_uptime_pct 86400)
                ut_msg+=$'\n'
                ut_msg+="📈 Availability: ${avail}% (24h)"
                telegram_send "$ut_msg"
                ;;
            /containers|/containers@*)
                local ct_msg="📦 *Container Status*"
                ct_msg+=$'\n'
                local docker_names=$(docker ps --format '{{.Names}}' 2>/dev/null)
                for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
                    local cname=$(get_container_name $i)
                    ct_msg+=$'\n'
                    if echo "$docker_names" | grep -q "^${cname}$"; then
                        ct_msg+="C${i} (${cname}): 🟢 Running"
                        ct_msg+=$'\n'
                        local logs=$(timeout 5 docker logs --tail 400 "$cname" 2>&1 | grep "\[STATS\]" | tail -1)
                        if [ -n "$logs" ]; then
                            local c_cing c_conn c_up c_down
                            IFS='|' read -r c_cing c_conn c_up c_down <<< $(echo "$logs" | awk '{
                                cing=0; conn=0; up=""; down=""
                                for(j=1;j<=NF;j++){
                                    if($j=="Connecting:") cing=$(j+1)+0
                                    else if($j=="Connected:") conn=$(j+1)+0
                                    else if($j=="Up:"){for(k=j+1;k<=NF;k++){if($k=="|"||$k~/Down:/)break; up=up (up?" ":"") $k}}
                                    else if($j=="Down:"){for(k=j+1;k<=NF;k++){if($k=="|"||$k~/Uptime:/)break; down=down (down?" ":"") $k}}
                                }
                                printf "%d|%d|%s|%s", cing, conn, up, down
                            }')
                            ct_msg+="  👥 Connected: ${c_conn:-0} | Connecting: ${c_cing:-0}"
                            ct_msg+=$'\n'
                            ct_msg+="  ⬆ Up: ${c_up:-N/A}  ⬇ Down: ${c_down:-N/A}"
                        else
                            ct_msg+="  ⚠ No stats available yet"
                        fi
                    else
                        ct_msg+="C${i} (${cname}): 🔴 Stopped"
                    fi
                    ct_msg+=$'\n'
                done
                ct_msg+=$'\n'
                ct_msg+="/restart\_N  /stop\_N  /start\_N — manage containers"
                telegram_send "$ct_msg"
                ;;
            /restart_*|/stop_*|/start_*)
                local action="${cmd%%_*}"     # /restart, /stop, or /start
                action="${action#/}"          # restart, stop, or start
                local num="${cmd#*_}"
                num="${num%%@*}"              # strip @botname suffix
                if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "${CONTAINER_COUNT:-1}" ]; then
                    telegram_send "❌ Invalid container number: ${num}. Use 1-${CONTAINER_COUNT:-1}."
                else
                    local cname=$(get_container_name "$num")
                    if docker "$action" "$cname" >/dev/null 2>&1; then
                        local emoji="✅"
                        [ "$action" = "stop" ] && emoji="🛑"
                        [ "$action" = "start" ] && emoji="🟢"
                        telegram_send "${emoji} Container ${num} (${cname}): ${action} successful"
                    else
                        telegram_send "❌ Failed to ${action} container ${num} (${cname})"
                    fi
                fi
                ;;
            /help|/help@*)
                telegram_send "📖 *Available Commands*
/status — Full status report
/peers — Current peer count
/uptime — Per-container uptime + 24h availability
/containers — Per-container status
/restart\_N — Restart container N
/stop\_N — Stop container N
/start\_N — Start container N
/help — Show this help"
                ;;
        esac
    done <<< "$parsed"

    [ "$max_id" -gt "$offset" ] 2>/dev/null && echo "$max_id" > "$offset_file"
}

build_report() {
    local report="📊 *Conduit Status Report*"
    report+=$'\n'
    report+="🕐 $(date '+%Y-%m-%d %H:%M %Z')"
    report+=$'\n'
    report+=$'\n'

    # Container status + uptime
    local running=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "^conduit" 2>/dev/null || true)
    running=${running:-0}
    local total=${CONTAINER_COUNT:-1}
    report+="📦 Containers: ${running}/${total} running"
    report+=$'\n'

    # Uptime percentage + streak
    local uptime_log="$INSTALL_DIR/traffic_stats/uptime_log"
    if [ -s "$uptime_log" ]; then
        local avail_24h=$(calc_uptime_pct 86400)
        report+="📈 Availability: ${avail_24h}% (24h)"
        report+=$'\n'
        # Streak: consecutive minutes at end of log with running > 0
        local streak_mins=$(awk -F'|' '{a[NR]=$2+0} END{n=0; for(i=NR;i>=1;i--){if(a[i]<=0) break; n++} print n}' "$uptime_log" 2>/dev/null)
        if [ "${streak_mins:-0}" -gt 0 ] 2>/dev/null; then
            local sd=$((streak_mins / 1440)) sh=$(( (streak_mins % 1440) / 60 )) sm=$((streak_mins % 60))
            local streak_str=""
            [ "$sd" -gt 0 ] && streak_str+="${sd}d "
            streak_str+="${sh}h ${sm}m"
            report+="🔥 Streak: ${streak_str}"
            report+=$'\n'
        fi
    fi

    # Uptime from earliest container
    local earliest_start=""
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        local cname=$(get_container_name $i)
        local started=$(docker inspect --format='{{.State.StartedAt}}' "$cname" 2>/dev/null)
        [ -z "$started" ] && continue
        local se=$(date -d "$started" +%s 2>/dev/null || echo 0)
        if [ -z "$earliest_start" ] || [ "$se" -lt "$earliest_start" ] 2>/dev/null; then
            earliest_start=$se
        fi
    done
    if [ -n "$earliest_start" ] && [ "$earliest_start" -gt 0 ] 2>/dev/null; then
        local now=$(date +%s)
        local diff=$((now - earliest_start))
        local days=$((diff / 86400))
        local hours=$(( (diff % 86400) / 3600 ))
        local mins=$(( (diff % 3600) / 60 ))
        report+="⏱ Uptime: ${days}d ${hours}h ${mins}m"
        report+=$'\n'
    fi

    # Peers (connected + connecting, matching TUI format)
    local total_peers=0
    local total_connecting=0
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        local cname=$(get_container_name $i)
        local last_stat=$(docker logs --tail 400 "$cname" 2>&1 | grep "\[STATS\]" | tail -1)
        local peers=$(echo "$last_stat" | awk '{for(j=1;j<=NF;j++){if($j=="Connected:") print $(j+1)+0}}' | head -1)
        local cing=$(echo "$last_stat" | awk '{for(j=1;j<=NF;j++){if($j=="Connecting:") print $(j+1)+0}}' | head -1)
        total_peers=$((total_peers + ${peers:-0}))
        total_connecting=$((total_connecting + ${cing:-0}))
    done
    report+="👥 Clients: ${total_peers} connected, ${total_connecting} connecting"
    report+=$'\n'

    # Active unique clients
    local snapshot_file="$INSTALL_DIR/traffic_stats/tracker_snapshot"
    if [ -s "$snapshot_file" ]; then
        local active_clients=$(wc -l < "$snapshot_file" 2>/dev/null || echo 0)
        report+="👤 Total lifetime IPs served: ${active_clients}"
        report+=$'\n'
    fi

    # Total bandwidth served (all-time from cumulative_data)
    local data_file_bw="$INSTALL_DIR/traffic_stats/cumulative_data"
    if [ -s "$data_file_bw" ]; then
        local total_bytes=$(awk -F'|' '{s+=$2+$3} END{print s+0}' "$data_file_bw" 2>/dev/null)
        local total_served=""
        if [ "${total_bytes:-0}" -gt 0 ] 2>/dev/null; then
            total_served=$(awk "BEGIN {b=$total_bytes; if(b>1099511627776) printf \"%.2f TB\",b/1099511627776; else if(b>1073741824) printf \"%.2f GB\",b/1073741824; else printf \"%.1f MB\",b/1048576}" 2>/dev/null)
            report+="📡 Total served: ${total_served}"
            report+=$'\n'
        fi
    fi

    # CPU / RAM
    local stats=$(timeout 10 docker stats --no-stream --format "{{.CPUPerc}} {{.MemUsage}}" $(docker ps --format '{{.Names}}' 2>/dev/null | grep "^conduit") 2>/dev/null | head -1)
    local raw_cpu=$(echo "$stats" | awk '{print $1}')
    local cores=$(get_cpu_cores)
    local cpu=$(awk "BEGIN {printf \"%.1f%%\", ${raw_cpu%\%} / $cores}" 2>/dev/null || echo "$raw_cpu")
    local ram=$(echo "$stats" | awk '{print $2, $3, $4}')
    cpu=$(escape_md "$cpu")
    ram=$(escape_md "$ram")
    report+="🖥 CPU: ${cpu} | RAM: ${ram}"
    report+=$'\n'

    # Data usage
    if [ "${DATA_CAP_GB:-0}" -gt 0 ] 2>/dev/null; then
        local iface="${DATA_CAP_IFACE:-eth0}"
        local rx=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
        local tx=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)
        local total_used=$(( rx + tx + ${DATA_CAP_PRIOR_USAGE:-0} ))
        local used_gb=$(awk "BEGIN {printf \"%.2f\", $total_used/1073741824}" 2>/dev/null || echo "0")
        report+="📈 Data: ${used_gb} GB / ${DATA_CAP_GB} GB"
        report+=$'\n'
    fi

    # Container restart counts
    local total_restarts=0
    local restart_details=""
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        local cname=$(get_container_name $i)
        local rc=$(docker inspect --format='{{.RestartCount}}' "$cname" 2>/dev/null || echo 0)
        rc=${rc:-0}
        total_restarts=$((total_restarts + rc))
        [ "$rc" -gt 0 ] && restart_details+=" C${i}:${rc}"
    done
    if [ "$total_restarts" -gt 0 ]; then
        report+="🔄 Restarts: ${total_restarts}${restart_details}"
        report+=$'\n'
    fi

    # Top countries by connected peers (from tracker snapshot)
    local snap_file="$INSTALL_DIR/traffic_stats/tracker_snapshot"
    if [ -s "$snap_file" ]; then
        local top_peers
        top_peers=$(awk -F'|' '{if($2!="") cnt[$2]++} END{for(c in cnt) print cnt[c]"|"c}' "$snap_file" 2>/dev/null | sort -t'|' -k1 -nr | head -3)
        if [ -n "$top_peers" ]; then
            report+="🗺 Top by peers:"
            report+=$'\n'
            while IFS='|' read -r cnt country; do
                [ -z "$country" ] && continue
                local safe_c=$(escape_md "$country")
                report+="  • ${safe_c}: ${cnt} clients"
                report+=$'\n'
            done <<< "$top_peers"
        fi
    fi

    # Top countries by upload
    local data_file="$INSTALL_DIR/traffic_stats/cumulative_data"
    if [ -s "$data_file" ]; then
        local top_countries
        top_countries=$(awk -F'|' '{if($1!="" && $3+0>0) bytes[$1]+=$3+0} END{for(c in bytes) print bytes[c]"|"c}' "$data_file" 2>/dev/null | sort -t'|' -k1 -nr | head -3)
        if [ -n "$top_countries" ]; then
            report+="🌍 Top by upload:"
            report+=$'\n'
            local total_upload=$(awk -F'|' '{s+=$3+0} END{print s+0}' "$data_file" 2>/dev/null)
            while IFS='|' read -r bytes country; do
                [ -z "$country" ] && continue
                local pct=0
                [ "$total_upload" -gt 0 ] 2>/dev/null && pct=$(awk "BEGIN {printf \"%.0f\", ($bytes/$total_upload)*100}" 2>/dev/null || echo 0)
                local safe_country=$(escape_md "$country")
                local fmt=$(awk "BEGIN {b=$bytes; if(b>1073741824) printf \"%.1f GB\",b/1073741824; else if(b>1048576) printf \"%.1f MB\",b/1048576; else printf \"%.1f KB\",b/1024}" 2>/dev/null)
                report+="  • ${safe_country}: ${pct}% (${fmt})"
                report+=$'\n'
            done <<< "$top_countries"
        fi
    fi

    echo "$report"
}

# State variables
cpu_breach=0
ram_breach=0
zero_peers_since=0
last_alert_cpu=0
last_alert_ram=0
last_alert_down=0
last_alert_peers=0
last_rotation_ts=0

# Ensure data directory exists
mkdir -p "$INSTALL_DIR/traffic_stats"

# Persist daily/weekly timestamps across restarts
_ts_dir="$INSTALL_DIR/traffic_stats"
last_daily_ts=$(cat "$_ts_dir/.last_daily_ts" 2>/dev/null || echo 0)
[ "$last_daily_ts" -eq "$last_daily_ts" ] 2>/dev/null || last_daily_ts=0
last_weekly_ts=$(cat "$_ts_dir/.last_weekly_ts" 2>/dev/null || echo 0)
[ "$last_weekly_ts" -eq "$last_weekly_ts" ] 2>/dev/null || last_weekly_ts=0
last_report_ts=$(cat "$_ts_dir/.last_report_ts" 2>/dev/null || echo 0)
[ "$last_report_ts" -eq "$last_report_ts" ] 2>/dev/null || last_report_ts=0

while true; do
    sleep 60

    # Re-read settings
    [ -f "$INSTALL_DIR/settings.conf" ] && source "$INSTALL_DIR/settings.conf"

    # Exit if disabled
    [ "$TELEGRAM_ENABLED" != "true" ] && exit 0
    [ -z "$TELEGRAM_BOT_TOKEN" ] && exit 0

    # Core per-minute tasks
    process_commands
    track_uptime
    check_alerts

    # Daily rotation check (once per day, using wall-clock time)
    now_ts=$(date +%s)
    if [ $((now_ts - last_rotation_ts)) -ge 86400 ] 2>/dev/null; then
        rotate_cumulative_data
        last_rotation_ts=$now_ts
    fi

    # Daily summary (wall-clock, survives restarts)
    if [ "${TELEGRAM_DAILY_SUMMARY:-true}" = "true" ] && [ $((now_ts - last_daily_ts)) -ge 86400 ] 2>/dev/null; then
        build_summary "Daily" 86400
        last_daily_ts=$now_ts
        echo "$now_ts" > "$_ts_dir/.last_daily_ts"
    fi

    # Weekly summary (wall-clock, survives restarts)
    if [ "${TELEGRAM_WEEKLY_SUMMARY:-true}" = "true" ] && [ $((now_ts - last_weekly_ts)) -ge 604800 ] 2>/dev/null; then
        build_summary "Weekly" 604800
        last_weekly_ts=$now_ts
        echo "$now_ts" > "$_ts_dir/.last_weekly_ts"
    fi

    # Regular periodic report (wall-clock aligned to start hour)
    # Reports fire when current hour matches start_hour + N*interval
    interval_hours=${TELEGRAM_INTERVAL:-6}
    start_hour=${TELEGRAM_START_HOUR:-0}
    interval_secs=$((interval_hours * 3600))
    current_hour=$(date +%-H)
    # Check if this hour is a scheduled slot: (current_hour - start_hour) mod interval == 0
    hour_diff=$(( (current_hour - start_hour + 24) % 24 ))
    if [ "$interval_hours" -gt 0 ] && [ $((hour_diff % interval_hours)) -eq 0 ] 2>/dev/null; then
        # Only send once per slot (check if enough time passed since last report)
        if [ $((now_ts - last_report_ts)) -ge $((interval_secs - 120)) ] 2>/dev/null; then
            report=$(build_report)
            telegram_send "$report"
            record_snapshot
            last_report_ts=$now_ts
            echo "$now_ts" > "$_ts_dir/.last_report_ts"
        fi
    fi
done
TGEOF
    chmod 700 "$INSTALL_DIR/conduit-telegram.sh"
}

setup_telegram_service() {
    telegram_generate_notify_script
    if command -v systemctl &>/dev/null; then
        cat > /etc/systemd/system/conduit-telegram.service << EOF
[Unit]
Description=Conduit Telegram Notifications
After=network.target docker.service
Wants=docker.service

[Service]
Type=simple
ExecStart=/bin/bash $INSTALL_DIR/conduit-telegram.sh
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable conduit-telegram.service 2>/dev/null || true
        systemctl restart conduit-telegram.service 2>/dev/null || true
    fi
}

telegram_stop_notify() {
    if command -v systemctl &>/dev/null && [ -f /etc/systemd/system/conduit-telegram.service ]; then
        systemctl stop conduit-telegram.service 2>/dev/null || true
    fi
    # Also clean up legacy PID-based loop if present
    if [ -f "$INSTALL_DIR/telegram_notify.pid" ]; then
        local pid=$(cat "$INSTALL_DIR/telegram_notify.pid" 2>/dev/null)
        if echo "$pid" | grep -qE '^[0-9]+$' && kill -0 "$pid" 2>/dev/null; then
            kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
        fi
        rm -f "$INSTALL_DIR/telegram_notify.pid"
    fi
}

telegram_start_notify() {
    telegram_stop_notify
    if [ "$TELEGRAM_ENABLED" = "true" ] && [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        setup_telegram_service
    fi
}

telegram_disable_service() {
    if command -v systemctl &>/dev/null && [ -f /etc/systemd/system/conduit-telegram.service ]; then
        systemctl stop conduit-telegram.service 2>/dev/null || true
        systemctl disable conduit-telegram.service 2>/dev/null || true
    fi
}

show_about() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════${NC}"
    echo -e "              ${BOLD}ABOUT PSIPHON CONDUIT MANAGER${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}${GREEN}What is Psiphon Conduit?${NC}"
    echo -e "  Psiphon is a free anti-censorship tool helping millions access"
    echo -e "  the open internet. Conduit is their ${BOLD}P2P volunteer network${NC}."
    echo -e "  By running a node, you help users in censored regions connect."
    echo ""
    echo -e "  ${BOLD}${GREEN}How P2P Works${NC}"
    echo -e "  Unlike centralized VPNs, Conduit is ${CYAN}decentralized${NC}:"
    echo -e "    ${YELLOW}1.${NC} Your server registers with Psiphon's broker"
    echo -e "    ${YELLOW}2.${NC} Users discover your node through the P2P network"
    echo -e "    ${YELLOW}3.${NC} Direct encrypted WebRTC tunnels are established"
    echo -e "    ${YELLOW}4.${NC} Traffic: ${GREEN}User${NC} <--P2P--> ${CYAN}You${NC} <--> ${YELLOW}Internet${NC}"
    echo ""
    echo -e "  ${BOLD}${GREEN}Technical${NC}"
    echo -e "    Protocol:  WebRTC + DTLS (looks like video calls)"
    echo -e "    Ports:     TCP 443 required | Turbo: UDP 16384-32768"
    echo -e "    Resources: ~50MB RAM per 100 clients, runs in Docker"
    echo ""
    echo -e "  ${BOLD}${GREEN}Privacy${NC}"
    echo -e "    ${GREEN}✓${NC} End-to-end encrypted - you can't see user traffic"
    echo -e "    ${GREEN}✓${NC} No logs stored | Clean uninstall available"
    echo ""
    echo -e "${CYAN}──────────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}Made by Sam${NC}"
    echo -e "  GitHub:  ${CYAN}https://github.com/SamNet-dev/conduit-manager${NC}"
    echo -e "  Psiphon: ${CYAN}https://psiphon.ca${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    read -n 1 -s -r -p "  Press any key to return..." < /dev/tty || true
}

show_settings_menu() {
    local redraw=true
    while true; do
        if [ "$redraw" = true ]; then
            clear
            print_header

            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo -e "${CYAN}  SETTINGS & TOOLS${NC}"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo -e "  1. ⚙️  Change settings (max-clients, bandwidth)"
            echo -e "  2. 📊 Set data usage cap"
            echo -e "  l. 🖥️  Set resource limits (CPU, memory)"
            echo ""
            echo -e "  3. 💾 Backup node key"
            echo -e "  4. 📥 Restore node key"
            echo -e "  5. 🩺 Health check"
            echo ""
            echo -e "  6. 📱 Show QR Code & Conduit ID"
            echo -e "  7. ℹ️  Version info"
            echo -e "  8. 📖 About Conduit"
            echo ""
            echo -e "  9. 🔄 Reset tracker data"
            local tracker_status
            if is_tracker_active; then
                tracker_status="${GREEN}Active${NC}"
            else
                tracker_status="${RED}Inactive${NC}"
            fi
            echo -e "  r. 📡 Restart tracker service  (${tracker_status})"
            echo -e "  t. 📲 Telegram Notifications"
            local ipm_status="${RED}Disabled${NC}"
            [ "${IPMGMT_ENABLED}" = "true" ] && ipm_status="${GREEN}Enabled${NC}"
            echo -e "  g. 🌐 IP management (Geo-fencing)  (${ipm_status})"
            echo -e ""
            echo -e "  u. 🗑️  Uninstall"
            echo -e "  0. ← Back to main menu"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo ""
            redraw=false
        fi

        read -p "  Enter choice: " choice < /dev/tty || { return; }

        case "$choice" in
            1)
                change_settings
                redraw=true
                ;;
            2)
                set_data_cap
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            l|L)
                change_resource_limits
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            3)
                backup_key
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            4)
                restore_key
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            5)
                health_check
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            6)
                show_qr_code
                redraw=true
                ;;
            7)
                show_version
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            8)
                show_about
                redraw=true
                ;;
            9)
                echo ""
                while true; do
                    read -p "Reset tracker and delete all stats data? (y/n): " confirm < /dev/tty || true
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        echo "Stopping tracker service..."
                        stop_tracker_service 2>/dev/null || true
                        echo "Deleting tracker data..."
                        rm -rf /opt/conduit/traffic_stats 2>/dev/null || true
                        rm -f /opt/conduit/conduit-tracker.sh 2>/dev/null || true
                        echo "Restarting tracker service..."
                        regenerate_tracker_script
                        setup_tracker_service
                        echo -e "${GREEN}Tracker data has been reset.${NC}"
                        break
                    elif [[ "$confirm" =~ ^[Nn]$ ]]; then
                        echo "Cancelled."
                        break
                    else
                        echo "Please enter y or n."
                    fi
                done
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            r)
                echo ""
                echo -ne "  Regenerating tracker script... "
                regenerate_tracker_script
                echo -e "${GREEN}done${NC}"
                echo -ne "  Starting tracker service... "
                setup_tracker_service
                if is_tracker_active; then
                    echo -e "${GREEN}✓ Tracker is now active${NC}"
                else
                    echo -e "${RED}✗ Failed to start tracker. Run health check for details.${NC}"
                fi
                read -n 1 -s -r -p "  Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            t)
                show_telegram_menu
                redraw=true
                ;;
            u)
                uninstall_all
                exit 0
                ;;
            0)
                return
                ;;
            "")
                ;;
            *)
                echo -e "${RED}Invalid choice${NC}"
                ;;
        esac
    done
}

show_telegram_menu() {
    while true; do
        # Reload settings from disk to reflect any changes
        [ -f "$INSTALL_DIR/settings.conf" ] && source "$INSTALL_DIR/settings.conf"
        clear
        print_header
        if [ "$TELEGRAM_ENABLED" = "true" ] && [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
            # Already configured — show management menu
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo -e "${CYAN}  TELEGRAM NOTIFICATIONS${NC}"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo ""
            local _sh="${TELEGRAM_START_HOUR:-0}"
            echo -e "  Status: ${GREEN}✓ Enabled${NC} (every ${TELEGRAM_INTERVAL}h starting at ${_sh}:00)"
            echo ""
            local alerts_st="${GREEN}ON${NC}"
            [ "${TELEGRAM_ALERTS_ENABLED:-true}" != "true" ] && alerts_st="${RED}OFF${NC}"
            local daily_st="${GREEN}ON${NC}"
            [ "${TELEGRAM_DAILY_SUMMARY:-true}" != "true" ] && daily_st="${RED}OFF${NC}"
            local weekly_st="${GREEN}ON${NC}"
            [ "${TELEGRAM_WEEKLY_SUMMARY:-true}" != "true" ] && weekly_st="${RED}OFF${NC}"
            echo -e "  1. 📩 Send test message"
            echo -e "  2. ⏱  Change interval"
            echo -e "  3. ❌ Disable notifications"
            echo -e "  4. 🔄 Reconfigure (new bot/chat)"
            echo -e "  5. 🚨 Alerts (CPU/RAM/down):    ${alerts_st}"
            echo -e "  6. 📋 Daily summary:            ${daily_st}"
            echo -e "  7. 📊 Weekly summary:           ${weekly_st}"
            local cur_label="${TELEGRAM_SERVER_LABEL:-$(hostname 2>/dev/null || echo 'unknown')}"
            echo -e "  8. 🏷  Server label:            ${CYAN}${cur_label}${NC}"
            echo -e "  0. ← Back"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo ""
            read -p "  Enter choice: " tchoice < /dev/tty || return
            case "$tchoice" in
                1)
                    echo ""
                    echo -ne "  Sending test message... "
                    if telegram_test_message; then
                        echo -e "${GREEN}✓ Sent!${NC}"
                    else
                        echo -e "${RED}✗ Failed. Check your token/chat ID.${NC}"
                    fi
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                2)
                    echo ""
                    echo -e "  Select notification interval:"
                    echo -e "  1. Every 1 hour"
                    echo -e "  2. Every 3 hours"
                    echo -e "  3. Every 6 hours (recommended)"
                    echo -e "  4. Every 12 hours"
                    echo -e "  5. Every 24 hours"
                    echo ""
                    read -p "  Choice [1-5]: " ichoice < /dev/tty || true
                    case "$ichoice" in
                        1) TELEGRAM_INTERVAL=1 ;;
                        2) TELEGRAM_INTERVAL=3 ;;
                        3) TELEGRAM_INTERVAL=6 ;;
                        4) TELEGRAM_INTERVAL=12 ;;
                        5) TELEGRAM_INTERVAL=24 ;;
                        *) echo -e "  ${RED}Invalid choice${NC}"; read -n 1 -s -r -p "  Press any key..." < /dev/tty || true; continue ;;
                    esac
                    echo ""
                    echo -e "  What hour should reports start? (0-23, e.g. 8 = 8:00 AM)"
                    echo -e "  Reports will repeat every ${TELEGRAM_INTERVAL}h from this hour."
                    read -p "  Start hour [0-23] (default ${TELEGRAM_START_HOUR:-0}): " shchoice < /dev/tty || true
                    if [ -n "$shchoice" ] && [ "$shchoice" -ge 0 ] 2>/dev/null && [ "$shchoice" -le 23 ] 2>/dev/null; then
                        TELEGRAM_START_HOUR=$shchoice
                    fi
                    save_settings
                    telegram_start_notify
                    echo -e "  ${GREEN}✓ Reports every ${TELEGRAM_INTERVAL}h starting at ${TELEGRAM_START_HOUR:-0}:00${NC}"
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                3)
                    TELEGRAM_ENABLED=false
                    save_settings
                    telegram_disable_service
                    echo -e "  ${GREEN}✓ Telegram notifications disabled${NC}"
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                4)
                    telegram_setup_wizard
                    ;;
                5)
                    if [ "${TELEGRAM_ALERTS_ENABLED:-true}" = "true" ]; then
                        TELEGRAM_ALERTS_ENABLED=false
                        echo -e "  ${RED}✗ Alerts disabled${NC}"
                    else
                        TELEGRAM_ALERTS_ENABLED=true
                        echo -e "  ${GREEN}✓ Alerts enabled${NC}"
                    fi
                    save_settings
                    telegram_start_notify
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                6)
                    if [ "${TELEGRAM_DAILY_SUMMARY:-true}" = "true" ]; then
                        TELEGRAM_DAILY_SUMMARY=false
                        echo -e "  ${RED}✗ Daily summary disabled${NC}"
                    else
                        TELEGRAM_DAILY_SUMMARY=true
                        echo -e "  ${GREEN}✓ Daily summary enabled${NC}"
                    fi
                    save_settings
                    telegram_start_notify
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                7)
                    if [ "${TELEGRAM_WEEKLY_SUMMARY:-true}" = "true" ]; then
                        TELEGRAM_WEEKLY_SUMMARY=false
                        echo -e "  ${RED}✗ Weekly summary disabled${NC}"
                    else
                        TELEGRAM_WEEKLY_SUMMARY=true
                        echo -e "  ${GREEN}✓ Weekly summary enabled${NC}"
                    fi
                    save_settings
                    telegram_start_notify
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                8)
                    echo ""
                    local cur_label="${TELEGRAM_SERVER_LABEL:-$(hostname 2>/dev/null || echo 'unknown')}"
                    echo -e "  Current label: ${CYAN}${cur_label}${NC}"
                    echo -e "  This label appears in all Telegram messages to identify the server."
                    echo -e "  Leave blank to use hostname ($(hostname 2>/dev/null || echo 'unknown'))"
                    echo ""
                    read -p "  New label: " new_label < /dev/tty || true
                    TELEGRAM_SERVER_LABEL="${new_label}"
                    save_settings
                    telegram_start_notify
                    local display_label="${TELEGRAM_SERVER_LABEL:-$(hostname 2>/dev/null || echo 'unknown')}"
                    echo -e "  ${GREEN}✓ Server label set to: ${display_label}${NC}"
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                0) return ;;
            esac
        elif [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
            # Disabled but credentials exist — offer re-enable
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo -e "${CYAN}  TELEGRAM NOTIFICATIONS${NC}"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo ""
            echo -e "  Status: ${RED}✗ Disabled${NC} (credentials saved)"
            echo ""
            echo -e "  1. ✅ Re-enable notifications (every ${TELEGRAM_INTERVAL:-6}h)"
            echo -e "  2. 🔄 Reconfigure (new bot/chat)"
            echo -e "  0. ← Back"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo ""
            read -p "  Enter choice: " tchoice < /dev/tty || return
            case "$tchoice" in
                1)
                    TELEGRAM_ENABLED=true
                    save_settings
                    telegram_start_notify
                    echo -e "  ${GREEN}✓ Telegram notifications re-enabled${NC}"
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                2)
                    telegram_setup_wizard
                    ;;
                0) return ;;
            esac
        else
            # Not configured — run wizard
            telegram_setup_wizard
            return
        fi
    done
}

telegram_setup_wizard() {
    # Save and restore variables on Ctrl+C
    local _saved_token="$TELEGRAM_BOT_TOKEN"
    local _saved_chatid="$TELEGRAM_CHAT_ID"
    local _saved_interval="$TELEGRAM_INTERVAL"
    local _saved_enabled="$TELEGRAM_ENABLED"
    local _saved_starthour="$TELEGRAM_START_HOUR"
    local _saved_label="$TELEGRAM_SERVER_LABEL"
    trap 'TELEGRAM_BOT_TOKEN="$_saved_token"; TELEGRAM_CHAT_ID="$_saved_chatid"; TELEGRAM_INTERVAL="$_saved_interval"; TELEGRAM_ENABLED="$_saved_enabled"; TELEGRAM_START_HOUR="$_saved_starthour"; TELEGRAM_SERVER_LABEL="$_saved_label"; trap - SIGINT; echo; return' SIGINT
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════${NC}"
    echo -e "              ${BOLD}TELEGRAM NOTIFICATIONS SETUP${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}Step 1: Create a Telegram Bot${NC}"
    echo -e "  ${CYAN}─────────────────────────────${NC}"
    echo -e "  1. Open Telegram and search for ${BOLD}@BotFather${NC}"
    echo -e "  2. Send ${YELLOW}/newbot${NC}"
    echo -e "  3. Choose a name (e.g. \"My Conduit Monitor\")"
    echo -e "  4. Choose a username (e.g. \"my_conduit_bot\")"
    echo -e "  5. BotFather will give you a token like:"
    echo -e "     ${YELLOW}123456789:ABCdefGHIjklMNOpqrsTUVwxyz${NC}"
    echo ""
    echo -e "  ${BOLD}Recommended:${NC} Send these commands to @BotFather:"
    echo -e "     ${YELLOW}/setjoingroups${NC} → Disable (prevents adding to groups)"
    echo -e "     ${YELLOW}/setprivacy${NC}   → Enable (limits message access)"
    echo ""
    echo -e "  ${YELLOW}⚠ OPSEC Note:${NC} Enabling Telegram notifications creates"
    echo -e "  outbound connections to api.telegram.org from this server."
    echo -e "  This traffic may be visible to your network provider."
    echo ""
    read -p "  Enter your bot token: " TELEGRAM_BOT_TOKEN < /dev/tty || { trap - SIGINT; TELEGRAM_BOT_TOKEN="$_saved_token"; return; }
    echo ""
    # Trim whitespace
    TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN## }"
    TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN%% }"
    if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
        echo -e "  ${RED}No token entered. Setup cancelled.${NC}"
        read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
        trap - SIGINT; return
    fi

    # Validate token format
    if ! echo "$TELEGRAM_BOT_TOKEN" | grep -qE '^[0-9]+:[A-Za-z0-9_-]+$'; then
        echo -e "  ${RED}Invalid token format. Should be like: 123456789:ABCdefGHI...${NC}"
        TELEGRAM_BOT_TOKEN="$_saved_token"; TELEGRAM_CHAT_ID="$_saved_chatid"; TELEGRAM_INTERVAL="$_saved_interval"; TELEGRAM_ENABLED="$_saved_enabled"; TELEGRAM_START_HOUR="$_saved_starthour"; TELEGRAM_SERVER_LABEL="$_saved_label"
        read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
        trap - SIGINT; return
    fi

    echo ""
    echo -e "  ${BOLD}Step 2: Get Your Chat ID${NC}"
    echo -e "  ${CYAN}────────────────────────${NC}"
    echo -e "  1. Open your new bot in Telegram"
    echo -e "  2. Send it the message: ${YELLOW}/start${NC}"
    echo -e ""
    echo -e "  ${YELLOW}Important:${NC} You MUST send ${BOLD}/start${NC} to the bot first!"
    echo -e "  The bot cannot respond to you until you do this."
    echo -e ""
    echo -e "  3. Press Enter here when done..."
    echo ""
    read -p "  Press Enter after sending /start to your bot... " < /dev/tty || { trap - SIGINT; TELEGRAM_BOT_TOKEN="$_saved_token"; TELEGRAM_CHAT_ID="$_saved_chatid"; TELEGRAM_INTERVAL="$_saved_interval"; TELEGRAM_ENABLED="$_saved_enabled"; TELEGRAM_START_HOUR="$_saved_starthour"; TELEGRAM_SERVER_LABEL="$_saved_label"; return; }

    echo -ne "  Detecting chat ID... "
    local attempts=0
    TELEGRAM_CHAT_ID=""
    while [ $attempts -lt 3 ] && [ -z "$TELEGRAM_CHAT_ID" ]; do
        if telegram_get_chat_id; then
            break
        fi
        attempts=$((attempts + 1))
        sleep 2
    done

    if [ -z "$TELEGRAM_CHAT_ID" ]; then
        echo -e "${RED}✗ Could not detect chat ID${NC}"
        echo -e "  Make sure you sent /start to the bot and try again."
        TELEGRAM_BOT_TOKEN="$_saved_token"; TELEGRAM_CHAT_ID="$_saved_chatid"; TELEGRAM_INTERVAL="$_saved_interval"; TELEGRAM_ENABLED="$_saved_enabled"; TELEGRAM_START_HOUR="$_saved_starthour"; TELEGRAM_SERVER_LABEL="$_saved_label"
        read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
        trap - SIGINT; return
    fi
    echo -e "${GREEN}✓ Chat ID: ${TELEGRAM_CHAT_ID}${NC}"

    echo ""
    echo -e "  ${BOLD}Step 3: Notification Interval${NC}"
    echo -e "  ${CYAN}─────────────────────────────${NC}"
    echo -e "  1. Every 1 hour"
    echo -e "  2. Every 3 hours"
    echo -e "  3. Every 6 hours (recommended)"
    echo -e "  4. Every 12 hours"
    echo -e "  5. Every 24 hours"
    echo ""
    read -p "  Choice [1-5] (default 3): " ichoice < /dev/tty || true
    case "$ichoice" in
        1) TELEGRAM_INTERVAL=1 ;;
        2) TELEGRAM_INTERVAL=3 ;;
        4) TELEGRAM_INTERVAL=12 ;;
        5) TELEGRAM_INTERVAL=24 ;;
        *) TELEGRAM_INTERVAL=6 ;;
    esac

    echo ""
    echo -e "  ${BOLD}Step 4: Start Hour${NC}"
    echo -e "  ${CYAN}─────────────────────────────${NC}"
    echo -e "  What hour should reports start? (0-23, e.g. 8 = 8:00 AM)"
    echo -e "  Reports will repeat every ${TELEGRAM_INTERVAL}h from this hour."
    echo ""
    read -p "  Start hour [0-23] (default 0): " shchoice < /dev/tty || true
    if [ -n "$shchoice" ] && [ "$shchoice" -ge 0 ] 2>/dev/null && [ "$shchoice" -le 23 ] 2>/dev/null; then
        TELEGRAM_START_HOUR=$shchoice
    else
        TELEGRAM_START_HOUR=0
    fi

    echo ""
    echo -ne "  Sending test message... "
    if telegram_test_message; then
        echo -e "${GREEN}✓ Success!${NC}"
    else
        echo -e "${RED}✗ Failed to send. Check your token.${NC}"
        TELEGRAM_BOT_TOKEN="$_saved_token"; TELEGRAM_CHAT_ID="$_saved_chatid"; TELEGRAM_INTERVAL="$_saved_interval"; TELEGRAM_ENABLED="$_saved_enabled"; TELEGRAM_START_HOUR="$_saved_starthour"; TELEGRAM_SERVER_LABEL="$_saved_label"
        read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
        trap - SIGINT; return
    fi

    TELEGRAM_ENABLED=true
    save_settings
    telegram_start_notify

    trap - SIGINT
    echo ""
    echo -e "  ${GREEN}${BOLD}✓ Telegram notifications enabled!${NC}"
    echo -e "  You'll receive reports every ${TELEGRAM_INTERVAL}h starting at ${TELEGRAM_START_HOUR}:00."
    echo ""
    read -n 1 -s -r -p "  Press any key to return..." < /dev/tty || true
}

show_menu() {
    # Auto-fix systemd service files: rewrite stale/old files, single daemon-reload
    if command -v systemctl &>/dev/null; then
        local need_reload=false

        # Fix conduit.service if it has old format (Requires, Type=simple, Restart=always, hardcoded args)
        if [ -f /etc/systemd/system/conduit.service ]; then
            local need_rewrite=false
            grep -q "Requires=docker.service" /etc/systemd/system/conduit.service 2>/dev/null && need_rewrite=true
            grep -q "Type=simple" /etc/systemd/system/conduit.service 2>/dev/null && need_rewrite=true
            grep -q "Restart=always" /etc/systemd/system/conduit.service 2>/dev/null && need_rewrite=true
            grep -q "max-clients" /etc/systemd/system/conduit.service 2>/dev/null && need_rewrite=true
            if [ "$need_rewrite" = true ]; then
                cat > /etc/systemd/system/conduit.service << SVCEOF
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
                need_reload=true
            fi
        fi

        # Fix tracker service file
        if [ -f /etc/systemd/system/conduit-tracker.service ] && grep -q "Requires=docker.service" /etc/systemd/system/conduit-tracker.service 2>/dev/null; then
            sed -i 's/Requires=docker.service/Wants=docker.service/g' /etc/systemd/system/conduit-tracker.service
            need_reload=true
        fi

        # Single daemon-reload for all file changes
        if [ "$need_reload" = true ]; then
            systemctl daemon-reload 2>/dev/null || true
            systemctl reset-failed conduit.service 2>/dev/null || true
            systemctl enable conduit.service 2>/dev/null || true
        fi

        # Auto-fix conduit.service if it's in failed state
        local svc_state=$(systemctl is-active conduit.service 2>/dev/null)
        if [ "$svc_state" = "failed" ]; then
            systemctl reset-failed conduit.service 2>/dev/null || true
            systemctl restart conduit.service 2>/dev/null || true
        fi
    fi

    # Auto-start/upgrade tracker if containers are up
    local any_running=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "^conduit" 2>/dev/null || true)
    any_running=${any_running:-0}
    if [ "$any_running" -gt 0 ] 2>/dev/null; then
        local tracker_script="$INSTALL_DIR/conduit-tracker.sh"
        local old_hash=$(md5sum "$tracker_script" 2>/dev/null | awk '{print $1}')
        regenerate_tracker_script
        local new_hash=$(md5sum "$tracker_script" 2>/dev/null | awk '{print $1}')
        if ! is_tracker_active; then
            setup_tracker_service
        elif [ "$old_hash" != "$new_hash" ]; then
            # Script changed (upgrade), restart to pick up new code
            systemctl restart conduit-tracker.service 2>/dev/null || true
        fi
    fi

    # Load settings (Telegram service is only started explicitly by the user via the Telegram menu)
    [ -f "$INSTALL_DIR/settings.conf" ] && source "$INSTALL_DIR/settings.conf"

    # If the Telegram service is already running, regenerate the script and restart
    # so it picks up any code changes from a script upgrade
    if command -v systemctl &>/dev/null && systemctl is-active conduit-telegram.service &>/dev/null; then
        telegram_generate_notify_script
        systemctl restart conduit-telegram.service 2>/dev/null || true
    fi

    local redraw=true
    while true; do
        if [ "$redraw" = true ]; then
            clear
            print_header

            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo -e "${CYAN}  MAIN MENU${NC}"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo -e "  1. 📈 View status dashboard"
            echo -e "  2. 📊 Live connection stats"
            echo -e "  3. 📋 View logs"
            echo -e "  4. 🌍 Live peers by country"
            echo ""
            echo -e "  5. ▶️  Start Conduit"
            echo -e "  6. ⏹️  Stop Conduit"
            echo -e "  7. 🔁 Restart Conduit"
            echo -e "  8. 🔄 Update Conduit"
            echo ""
            echo -e "  9. ⚙️  Settings & Tools"
            echo -e "  c. 📦 Manage containers"
            echo -e "  a. 📊 Advanced stats"
            echo -e "  i. ℹ️  Info & Help"
            echo -e "  0. 🚪 Exit"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo ""
            redraw=false
        fi

        read -p "  Enter choice: " choice < /dev/tty || { echo "Input error. Exiting."; exit 1; }

        case "$choice" in
            1)
                show_dashboard
                redraw=true
                ;;
            2)
                show_live_stats
                redraw=true
                ;;
            3)
                show_logs
                redraw=true
                ;;
            4)
                show_peers
                redraw=true
                ;;
            5)
                start_conduit
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            6)
                stop_conduit
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            7)
                restart_conduit
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            8)
                update_conduit
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            9)
                show_settings_menu
                redraw=true
                ;;
            c)
                manage_containers
                redraw=true
                ;;
            a)
                show_advanced_stats
                redraw=true
                ;;
            i)
                show_info_menu
                redraw=true
                ;;
            0)
                echo "Exiting."
                exit 0
                ;;
            "")
                ;;
            *)
                echo -e "${RED}Invalid choice: ${NC}${YELLOW}$choice${NC}"
                ;;
        esac
    done
}

# Info hub - sub-page menu
show_info_menu() {
    local redraw=true
    while true; do
        if [ "$redraw" = true ]; then
            clear
            echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}  INFO & HELP${NC}"
            echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
            echo ""
            echo -e "  1. 📡 How the Tracker Works"
            echo -e "  2. 📊 Understanding the Stats Pages"
            echo -e "  3. 📦 Containers & Scaling"
            echo -e "  4. 🔒 Privacy & Security"
            echo -e "  5. 🚀 About Psiphon Conduit"
            echo ""
            echo -e "  [b] Back to menu"
            echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
            echo ""
            redraw=true
        fi
        read -p "  Select page: " info_choice < /dev/tty || break
        case "$info_choice" in
            1) _info_tracker; redraw=true ;;
            2) _info_stats; redraw=true ;;
            3) _info_containers; redraw=true ;;
            4) _info_privacy; redraw=true ;;
            5) show_about; redraw=true ;;
            b|"") break ;;
            *) echo -e "  ${RED}Invalid.${NC}"; sleep 1; redraw=true ;;
        esac
    done
}

_info_tracker() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  HOW THE TRACKER WORKS${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}What is it?${NC}"
    echo -e "  A background systemd service (conduit-tracker.service) that"
    echo -e "  monitors network traffic on your server using tcpdump."
    echo -e "  It runs continuously and captures ALL TCP/UDP traffic"
    echo -e "  (excluding SSH port 22) to track where traffic goes."
    echo ""
    echo -e "  ${BOLD}How it works${NC}"
    echo -e "  Every 15 seconds the tracker:"
    echo -e "    ${YELLOW}1.${NC} Captures network packets via tcpdump"
    echo -e "    ${YELLOW}2.${NC} Extracts source/destination IPs and byte counts"
    echo -e "    ${YELLOW}3.${NC} Resolves each IP to a country using GeoIP"
    echo -e "    ${YELLOW}4.${NC} Saves cumulative data to disk"
    echo ""
    echo -e "  ${BOLD}Data files${NC}  ${DIM}(in /opt/conduit/traffic_stats/)${NC}"
    echo -e "    ${CYAN}cumulative_data${NC}  - Country traffic totals (bytes in/out)"
    echo -e "    ${CYAN}cumulative_ips${NC}   - All unique IPs ever seen + country"
    echo -e "    ${CYAN}tracker_snapshot${NC} - Last 15-second cycle (for live views)"
    echo ""
    echo -e "  ${BOLD}Important${NC}"
    echo -e "  The tracker captures ALL server traffic, not just Conduit."
    echo -e "  IP counts include system updates, DNS, Docker pulls, etc."
    echo -e "  This is why unique IP counts are higher than client counts."
    echo -e "  To reset all data: Settings > Reset tracker data."
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    read -n 1 -s -r -p "  Press any key to return..." < /dev/tty || true
}

_info_stats() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  UNDERSTANDING THE STATS PAGES${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}Unique IPs vs Clients${NC}"
    echo -e "    ${YELLOW}IPs${NC}     = Total unique IP addresses seen in ALL network"
    echo -e "            traffic. Includes non-Conduit traffic (system"
    echo -e "            updates, DNS, Docker, etc). Always higher."
    echo -e "    ${GREEN}Clients${NC} = Actual Psiphon peers connected to your Conduit"
    echo -e "            containers. Comes from Docker logs. This is"
    echo -e "            the real number of people you are helping."
    echo ""
    echo -e "  ${BOLD}Dashboard (option 1)${NC}"
    echo -e "    Shows status, resources, traffic totals, and two"
    echo -e "    side-by-side TOP 5 charts:"
    echo -e "      ${GREEN}Active Clients${NC} - Estimated clients per country"
    echo -e "      ${YELLOW}Top Upload${NC}     - Countries you upload most to"
    echo ""
    echo -e "  ${BOLD}Live Peers (option 4)${NC}"
    echo -e "    Full-page traffic breakdown by country. Shows:"
    echo -e "      Total bytes, Speed (KB/s), Clients per country"
    echo -e "    Client counts are estimated from the snapshot"
    echo -e "    distribution scaled to actual connected count."
    echo ""
    echo -e "  ${BOLD}Advanced Stats (a)${NC}"
    echo -e "    Container resources (CPU, RAM, clients, bandwidth),"
    echo -e "    network speed, tracker status, and TOP 7 charts"
    echo -e "    for unique IPs, download, and upload by country."
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    read -n 1 -s -r -p "  Press any key to return..." < /dev/tty || true
}

_info_containers() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  CONTAINERS & SCALING${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}What are containers?${NC}"
    echo -e "  Each container is an independent Conduit node running"
    echo -e "  in Docker. Multiple containers let you serve more"
    echo -e "  clients simultaneously from the same server."
    echo ""
    echo -e "  ${BOLD}Naming${NC}"
    echo -e "    Container 1: ${CYAN}conduit${NC}      Volume: ${CYAN}conduit-data${NC}"
    echo -e "    Container 2: ${CYAN}conduit-2${NC}    Volume: ${CYAN}conduit-data-2${NC}"
    echo -e "    Container 3: ${CYAN}conduit-3${NC}    Volume: ${CYAN}conduit-data-3${NC}"
    echo -e "    ...up to 5 containers."
    echo ""
    echo -e "  ${BOLD}Scaling recommendations${NC}"
    echo -e "    ${YELLOW}1 CPU / <1GB RAM:${NC}  Stick with 1 container"
    echo -e "    ${YELLOW}2 CPUs / 2GB RAM:${NC}  1-2 containers"
    echo -e "    ${GREEN}4+ CPUs / 4GB RAM:${NC} 3-5 containers"
    echo -e "  Each container uses ~50MB RAM per 100 clients."
    echo ""
    echo -e "  ${BOLD}Per-container settings${NC}"
    echo -e "  You can set different max-clients and bandwidth for"
    echo -e "  each container in Settings > Change settings. Choose"
    echo -e "  'Apply to specific container' to customize individually."
    echo ""
    echo -e "  ${BOLD}Managing${NC}"
    echo -e "  Use Manage Containers (c) to add/remove containers,"
    echo -e "  start/stop individual ones, or view per-container stats."
    echo -e "  Each container has its own volume (identity key)."
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    read -n 1 -s -r -p "  Press any key to return..." < /dev/tty || true
}

_info_privacy() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  PRIVACY & SECURITY${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}Is my traffic visible?${NC}"
    echo -e "  ${GREEN}No.${NC} All Conduit traffic is end-to-end encrypted using"
    echo -e "  WebRTC + DTLS. You cannot see what users are browsing."
    echo -e "  The connection looks like a regular video call."
    echo ""
    echo -e "  ${BOLD}What data is stored?${NC}"
    echo -e "  Conduit Manager stores:"
    echo -e "    ${GREEN}Node identity key${NC} - Your unique node ID (in Docker volume)"
    echo -e "    ${GREEN}Settings${NC}          - Max clients, bandwidth, container count"
    echo -e "    ${GREEN}Tracker stats${NC}     - Country-level traffic aggregates"
    echo -e "  ${RED}No${NC} user browsing data, IP logs, or personal info is stored."
    echo ""
    echo -e "  ${BOLD}What can the tracker see?${NC}"
    echo -e "  The tracker only records:"
    echo -e "    - Which countries connect (via GeoIP lookup)"
    echo -e "    - How many bytes flow in/out per country"
    echo -e "    - Total unique IP addresses (not logged individually)"
    echo -e "  It cannot see URLs, content, or decrypt any traffic."
    echo ""
    echo -e "  ${BOLD}Uninstall${NC}"
    echo -e "  Full uninstall (option 9 > Uninstall) removes:"
    echo -e "    - All containers and Docker volumes"
    echo -e "    - Tracker service and all stats data"
    echo -e "    - Settings, systemd service files"
    echo -e "    - The conduit command itself"
    echo -e "  Nothing is left behind on your system."
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    read -n 1 -s -r -p "  Press any key to return..." < /dev/tty || true
}

# Command line interface
show_help() {
    echo "Usage: conduit [command]"
    echo ""
    echo "Commands:"
    echo "  status    Show current status with resource usage"
    echo "  stats     View live statistics"
    echo "  logs      View raw Docker logs"
    echo "  health    Run health check on Conduit container"
    echo "  start     Start Conduit container"
    echo "  stop      Stop Conduit container"
    echo "  restart   Restart Conduit container"
    echo "  update    Update to latest Conduit image"
    echo "  settings  Change max-clients/bandwidth"
    echo "  scale     Scale containers (1-5)"
    echo "  backup    Backup Conduit node identity key"
    echo "  restore   Restore Conduit node identity from backup"
    echo "  uninstall Remove everything (container, data, service)"
    echo "  menu      Open interactive menu (default)"
    echo "  version   Show version information"
    echo "  about     About Psiphon Conduit"
    echo "  help      Show this help"
}

show_version() {
    echo "Conduit Manager v${VERSION}"
    echo "Image: ${CONDUIT_IMAGE}"

    # Show actual running image digest if available
    if docker ps 2>/dev/null | grep -q "[[:space:]]conduit$"; then
        local actual=$(docker inspect --format='{{index .RepoDigests 0}}' "$CONDUIT_IMAGE" 2>/dev/null | grep -o 'sha256:[a-f0-9]*')
        if [ -n "$actual" ]; then
            echo "Running Digest:  ${actual}"
        fi
    fi
}

health_check() {
    echo -e "${CYAN}═══ CONDUIT HEALTH CHECK ═══${NC}"
    echo ""

    local all_ok=true

    # 1. Check if Docker is running
    echo -n "Docker daemon:        "
    if docker info &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC} - Docker is not running"
        all_ok=false
    fi

    # 2-5. Check each container
    for i in $(seq 1 $CONTAINER_COUNT); do
        local cname=$(get_container_name $i)
        local vname=$(get_volume_name $i)

        if [ "$CONTAINER_COUNT" -gt 1 ]; then
            echo ""
            echo -e "${CYAN}--- ${cname} ---${NC}"
        fi

        echo -n "Container exists:     "
        if docker ps -a 2>/dev/null | grep -q "[[:space:]]${cname}$"; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}FAILED${NC} - Container not found"
            all_ok=false
        fi

        echo -n "Container running:    "
        if docker ps 2>/dev/null | grep -q "[[:space:]]${cname}$"; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}FAILED${NC} - Container is stopped"
            all_ok=false
        fi

        echo -n "Restart count:        "
        local restarts=$(docker inspect --format='{{.RestartCount}}' "$cname" 2>/dev/null)
        if [ -n "$restarts" ]; then
            if [ "$restarts" -eq 0 ]; then
                echo -e "${GREEN}${restarts}${NC} (healthy)"
            elif [ "$restarts" -lt 5 ]; then
                echo -e "${YELLOW}${restarts}${NC} (some restarts)"
            else
                echo -e "${RED}${restarts}${NC} (excessive restarts)"
                all_ok=false
            fi
        else
            echo -e "${YELLOW}N/A${NC}"
        fi

        # Single docker logs call for network + stats checks
        local hc_logs=$(docker logs --tail 100 "$cname" 2>&1)
        local hc_stats_lines=$(echo "$hc_logs" | grep "\[STATS\]" || true)
        local hc_stats_count=0
        if [ -n "$hc_stats_lines" ]; then
            hc_stats_count=$(echo "$hc_stats_lines" | wc -l | tr -d ' ')
        fi
        hc_stats_count=${hc_stats_count:-0}
        local hc_last_stat=$(echo "$hc_stats_lines" | tail -1)
        local hc_connected=$(echo "$hc_last_stat" | sed -n 's/.*Connected:[[:space:]]*\([0-9]*\).*/\1/p' | head -1 | tr -d '\n')
        hc_connected=${hc_connected:-0}
        local hc_connecting=$(echo "$hc_last_stat" | sed -n 's/.*Connecting:[[:space:]]*\([0-9]*\).*/\1/p' | head -1 | tr -d '\n')
        hc_connecting=${hc_connecting:-0}

        echo -n "Network connection:   "
        if [ "$hc_connected" -gt 0 ] 2>/dev/null; then
            echo -e "${GREEN}OK${NC} (${hc_connected} peers connected, ${hc_connecting} connecting)"
        elif [ "$hc_stats_count" -gt 0 ] 2>/dev/null; then
            if [ "$hc_connecting" -gt 0 ] 2>/dev/null; then
                echo -e "${GREEN}OK${NC} (Connected, ${hc_connecting} peers connecting)"
            else
                echo -e "${GREEN}OK${NC} (Connected, awaiting peers)"
            fi
        elif echo "$hc_logs" | grep -q "\[OK\] Connected to Psiphon network"; then
            echo -e "${GREEN}OK${NC} (Connected, no stats available)"
        else
            local info_lines=0
            if [ -n "$hc_logs" ]; then
                info_lines=$(echo "$hc_logs" | grep "\[INFO\]" | wc -l | tr -d ' ')
            fi
            info_lines=${info_lines:-0}
            if [ "$info_lines" -gt 0 ] 2>/dev/null; then
                echo -e "${YELLOW}CONNECTING${NC} - Establishing connection..."
            else
                echo -e "${YELLOW}WAITING${NC} - Starting up..."
            fi
        fi

        echo -n "Stats output:         "
        if [ "$hc_stats_count" -gt 0 ] 2>/dev/null; then
            echo -e "${GREEN}OK${NC} (${hc_stats_count} entries)"
        else
            echo -e "${YELLOW}NONE${NC} - Run 'conduit restart' to enable"
        fi

        echo -n "Data volume:          "
        if docker volume inspect "$vname" &>/dev/null; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}FAILED${NC} - Volume not found"
            all_ok=false
        fi

        echo -n "Network (host mode):  "
        local network_mode=$(docker inspect --format='{{.HostConfig.NetworkMode}}' "$cname" 2>/dev/null)
        if [ "$network_mode" = "host" ]; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${YELLOW}WARN${NC} - Not using host network mode"
        fi
    done

    # Node key check (only on first volume)
    if [ "$CONTAINER_COUNT" -gt 1 ]; then
        echo ""
        echo -e "${CYAN}--- Shared ---${NC}"
    fi
    echo -n "Node identity key:    "
    local mountpoint=$(docker volume inspect conduit-data --format '{{ .Mountpoint }}' 2>/dev/null)
    local key_found=false
    if [ -n "$mountpoint" ] && [ -f "$mountpoint/conduit_key.json" ]; then
        key_found=true
    else
        # Snap Docker fallback: check via docker cp
        local tmp_ctr="conduit-health-tmp"
        docker rm -f "$tmp_ctr" 2>/dev/null || true
        if docker create --name "$tmp_ctr" -v conduit-data:/data alpine true 2>/dev/null; then
            if docker cp "$tmp_ctr:/data/conduit_key.json" - >/dev/null 2>&1; then
                key_found=true
            fi
            docker rm -f "$tmp_ctr" 2>/dev/null || true
        fi
    fi
    if [ "$key_found" = true ]; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}PENDING${NC} - Will be created on first run"
    fi

    # Tracker service check
    echo ""
    echo -e "${CYAN}--- Tracker ---${NC}"
    echo -n "Tracker service:      "
    if is_tracker_active; then
        echo -e "${GREEN}OK${NC} (active)"
    else
        echo -e "${RED}FAILED${NC} - Tracker service not running"
        echo -e "         Fix: Settings → Restart tracker (option r)"
        all_ok=false
    fi

    echo -n "tcpdump installed:    "
    if command -v tcpdump &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC} - tcpdump not found (tracker won't work)"
        all_ok=false
    fi

    echo -n "GeoIP available:      "
    if command -v geoiplookup &>/dev/null; then
        echo -e "${GREEN}OK${NC} (geoiplookup)"
    elif command -v mmdblookup &>/dev/null; then
        echo -e "${GREEN}OK${NC} (mmdblookup)"
    else
        echo -e "${YELLOW}WARN${NC} - No GeoIP tool found (countries show as Unknown)"
    fi

    echo -n "Tracker data:         "
    local tracker_data="$INSTALL_DIR/traffic_stats/cumulative_data"
    if [ -s "$tracker_data" ]; then
        local country_count=$(awk -F'|' '{if($1!="") c[$1]=1} END{print length(c)}' "$tracker_data" 2>/dev/null || echo 0)
        echo -e "${GREEN}OK${NC} (${country_count} countries tracked)"
    else
        echo -e "${YELLOW}NONE${NC} - No traffic data yet"
    fi

    echo ""
    if [ "$all_ok" = true ]; then
        echo -e "${GREEN}✓ All health checks passed${NC}"
        return 0
    else
        echo -e "${RED}✗ Some health checks failed${NC}"
        return 1
    fi
}

backup_key() {
    echo -e "${CYAN}═══ BACKUP CONDUIT NODE KEY ═══${NC}"
    echo ""

    # Create backup directory
    mkdir -p "$INSTALL_DIR/backups"

    # Create timestamped backup
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_file="$INSTALL_DIR/backups/conduit_key_${timestamp}.json"

    # Try direct mountpoint access first, fall back to docker cp (Snap Docker)
    local mountpoint=$(docker volume inspect conduit-data --format '{{ .Mountpoint }}' 2>/dev/null)

    if [ -n "$mountpoint" ] && [ -f "$mountpoint/conduit_key.json" ]; then
        if ! cp "$mountpoint/conduit_key.json" "$backup_file"; then
            echo -e "${RED}Error: Failed to copy key file${NC}"
            return 1
        fi
    else
        # Use docker cp fallback (works with Snap Docker)
        local tmp_ctr="conduit-backup-tmp"
        docker create --name "$tmp_ctr" -v conduit-data:/data alpine true 2>/dev/null || true
        if ! docker cp "$tmp_ctr:/data/conduit_key.json" "$backup_file" 2>/dev/null; then
            docker rm -f "$tmp_ctr" 2>/dev/null || true
            echo -e "${RED}Error: No node key found. Has Conduit been started at least once?${NC}"
            return 1
        fi
        docker rm -f "$tmp_ctr" 2>/dev/null || true
    fi

    chmod 600 "$backup_file"

    # Get node ID for display
    local node_id=$(cat "$backup_file" | grep "privateKeyBase64" | awk -F'"' '{print $4}' | base64 -d 2>/dev/null | tail -c 32 | base64 | tr -d '=\n')

    echo -e "${GREEN}✓ Backup created successfully${NC}"
    echo ""
    echo -e "  Backup file: ${CYAN}${backup_file}${NC}"
    echo -e "  Node ID:     ${CYAN}${node_id}${NC}"
    echo ""
    echo -e "${YELLOW}Important:${NC} Store this backup securely. It contains your node's"
    echo "private key which identifies your node on the Psiphon network."
    echo ""

    # List all backups
    echo "All backups:"
    ls -la "$INSTALL_DIR/backups/"*.json 2>/dev/null | awk '{print "  " $9 " (" $5 " bytes)"}'
}

restore_key() {
    echo -e "${CYAN}═══ RESTORE CONDUIT NODE KEY ═══${NC}"
    echo ""

    local backup_dir="$INSTALL_DIR/backups"

    # Check if backup directory exists and has files
    if [ ! -d "$backup_dir" ] || [ -z "$(ls -A "$backup_dir"/*.json 2>/dev/null)" ]; then
        echo -e "${YELLOW}No backups found in ${backup_dir}${NC}"
        echo ""
        echo "To restore from a custom path, provide the file path:"
        read -p "  Backup file path (or press Enter to cancel): " custom_path < /dev/tty || true

        if [ -z "$custom_path" ]; then
            echo "Restore cancelled."
            return 0
        fi

        if [ ! -f "$custom_path" ]; then
            echo -e "${RED}Error: File not found: ${custom_path}${NC}"
            return 1
        fi

        local backup_file="$custom_path"
    else
        # List available backups
        echo "Available backups:"
        local i=1
        local backups=()
        for f in "$backup_dir"/*.json; do
            backups+=("$f")
            local node_id=$(cat "$f" | grep "privateKeyBase64" | awk -F'"' '{print $4}' | base64 -d 2>/dev/null | tail -c 32 | base64 | tr -d '=\n' 2>/dev/null)
            echo "  ${i}. $(basename "$f") - Node: ${node_id:-unknown}"
            i=$((i + 1))
        done
        echo ""

        read -p "  Select backup number (or 0 to cancel): " selection < /dev/tty || true

        if [ "$selection" = "0" ] || [ -z "$selection" ]; then
            echo "Restore cancelled."
            return 0
        fi

        if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#backups[@]} ]; then
            echo -e "${RED}Invalid selection${NC}"
            return 1
        fi

        backup_file="${backups[$((selection - 1))]}"
    fi

    echo ""
    echo -e "${YELLOW}Warning:${NC} This will replace the current node key."
    echo "The container will be stopped and restarted."
    echo ""
    read -p "Proceed with restore? [y/N] " confirm < /dev/tty || true

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Restore cancelled."
        return 0
    fi

    # Stop all containers
    echo ""
    echo "Stopping Conduit..."
    stop_conduit

    # Try direct mountpoint access, fall back to docker cp (Snap Docker)
    local mountpoint=$(docker volume inspect conduit-data --format '{{ .Mountpoint }}' 2>/dev/null)
    local use_docker_cp=false

    if [ -z "$mountpoint" ] || [ ! -d "$mountpoint" ]; then
        use_docker_cp=true
    fi

    # Backup current key if exists
    if [ "$use_docker_cp" = "true" ]; then
        local timestamp=$(date '+%Y%m%d_%H%M%S')
        mkdir -p "$backup_dir"
        local tmp_ctr="conduit-restore-tmp"
        docker create --name "$tmp_ctr" -v conduit-data:/data alpine true 2>/dev/null || true
        if docker cp "$tmp_ctr:/data/conduit_key.json" "$backup_dir/conduit_key_pre_restore_${timestamp}.json" 2>/dev/null; then
            echo "  Current key backed up to: conduit_key_pre_restore_${timestamp}.json"
        fi
        # Copy new key in
        if ! docker cp "$backup_file" "$tmp_ctr:/data/conduit_key.json" 2>/dev/null; then
            docker rm -f "$tmp_ctr" 2>/dev/null || true
            echo -e "${RED}Error: Failed to copy key into container volume${NC}"
            return 1
        fi
        docker rm -f "$tmp_ctr" 2>/dev/null || true
        # Fix ownership
        docker run --rm -v conduit-data:/data alpine chown 1000:1000 /data/conduit_key.json 2>/dev/null || true
    else
        if [ -f "$mountpoint/conduit_key.json" ]; then
            local timestamp=$(date '+%Y%m%d_%H%M%S')
            mkdir -p "$backup_dir"
            cp "$mountpoint/conduit_key.json" "$backup_dir/conduit_key_pre_restore_${timestamp}.json"
            echo "  Current key backed up to: conduit_key_pre_restore_${timestamp}.json"
        fi
        if ! cp "$backup_file" "$mountpoint/conduit_key.json"; then
            echo -e "${RED}Error: Failed to copy key to volume${NC}"
            return 1
        fi
        chmod 600 "$mountpoint/conduit_key.json"
    fi

    # Restart all containers
    echo "Starting Conduit..."
    start_conduit

    local node_id=$(cat "$backup_file" | grep "privateKeyBase64" | awk -F'"' '{print $4}' | base64 -d 2>/dev/null | tail -c 32 | base64 | tr -d '=\n')

    echo ""
    echo -e "${GREEN}✓ Node key restored successfully${NC}"
    echo -e "  Node ID: ${CYAN}${node_id}${NC}"
}

recreate_containers() {
    echo "Recreating container(s) with updated image..."
    stop_tracker_service 2>/dev/null || true
    local persist_dir="$INSTALL_DIR/traffic_stats"
    if [ -s "$persist_dir/cumulative_data" ] || [ -s "$persist_dir/cumulative_ips" ]; then
        echo -e "${CYAN}⟳ Saving tracker data snapshot...${NC}"
        [ -s "$persist_dir/cumulative_data" ] && cp "$persist_dir/cumulative_data" "$persist_dir/cumulative_data.bak"
        [ -s "$persist_dir/cumulative_ips" ] && cp "$persist_dir/cumulative_ips" "$persist_dir/cumulative_ips.bak"
        [ -s "$persist_dir/geoip_cache" ] && cp "$persist_dir/geoip_cache" "$persist_dir/geoip_cache.bak"
        echo -e "${GREEN}✓ Tracker data snapshot saved${NC}"
    fi
    for i in $(seq 1 $CONTAINER_COUNT); do
        local name=$(get_container_name $i)
        docker rm -f "$name" 2>/dev/null || true
    done
    fix_volume_permissions
    for i in $(seq 1 $CONTAINER_COUNT); do
        run_conduit_container $i
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ $(get_container_name $i) updated and restarted${NC}"
        else
            echo -e "${RED}✗ Failed to start $(get_container_name $i)${NC}"
        fi
    done
    setup_tracker_service 2>/dev/null || true
}

update_conduit() {
    echo -e "${CYAN}═══ UPDATE CONDUIT ═══${NC}"
    echo ""

    # --- Phase 1: Script update ---
    echo "Checking for script updates..."
    local update_url="https://raw.githubusercontent.com/SamNet-dev/conduit-manager/main/conduit.sh"
    local tmp_script="/tmp/conduit_update_$$.sh"

    if curl -sL --max-time 30 --max-filesize 2097152 -o "$tmp_script" "$update_url" 2>/dev/null; then
        if grep -q "CONDUIT_IMAGE=" "$tmp_script" && grep -q "create_management_script" "$tmp_script" && bash -n "$tmp_script" 2>/dev/null; then
            echo -e "${GREEN}✓ Latest script downloaded${NC}"
            bash "$tmp_script" --update-components
            local update_status=$?
            rm -f "$tmp_script"
            if [ $update_status -eq 0 ]; then
                echo -e "${GREEN}✓ Management script updated${NC}"
                echo -e "${GREEN}✓ Tracker service updated${NC}"
            else
                echo -e "${RED}Script update failed. Continuing with Docker check...${NC}"
            fi
        else
            echo -e "${RED}Downloaded file doesn't look valid. Skipping script update.${NC}"
            rm -f "$tmp_script"
        fi
    else
        echo -e "${YELLOW}Could not download latest script. Skipping script update.${NC}"
        rm -f "$tmp_script"
    fi

    # --- Phase 2: Docker image update ---
    echo ""
    echo "Checking for Docker image updates..."
    local pull_output
    pull_output=$(docker pull "$CONDUIT_IMAGE" 2>&1)
    local pull_status=$?
    echo "$pull_output"

    if [ $pull_status -ne 0 ]; then
        echo -e "${RED}Failed to check for Docker updates. Check your internet connection.${NC}"
        echo ""
        echo -e "${GREEN}Script update complete.${NC}"
        return 1
    fi

    if echo "$pull_output" | grep -q "Status: Image is up to date"; then
        echo -e "${GREEN}Docker image is already up to date.${NC}"
    elif echo "$pull_output" | grep -q "Downloaded newer image\|Pull complete"; then
        echo ""
        echo -e "${YELLOW}A new Docker image is available.${NC}"
        echo -e "Recreating containers will cause brief downtime (~10 seconds)."
        echo ""
        read -p "Recreate containers with new image now? [y/N]: " answer < /dev/tty || true
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            recreate_containers
        else
            echo -e "${CYAN}Skipped. Containers will use the new image on next restart.${NC}"
        fi
    fi

    echo ""
    echo -e "${GREEN}Update complete.${NC}"
}

case "${1:-menu}" in
    status)   show_status ;;
    stats)    show_live_stats ;;
    logs)     show_logs ;;
    health)   health_check ;;
    start)    start_conduit ;;
    stop)     stop_conduit ;;
    restart)  restart_conduit ;;
    update)   update_conduit ;;
    peers)    show_peers ;;
    settings) change_settings ;;
    backup)   backup_key ;;
    restore)  restore_key ;;
    scale)    manage_containers ;;
    about)    show_about ;;
    uninstall) uninstall_all ;;
    version|-v|--version) show_version ;;
    help|-h|--help) show_help ;;
    menu|*)   show_menu ;;
esac
MANAGEMENT

    # Patch the INSTALL_DIR in the generated script
    sed -i "s#REPLACE_ME_INSTALL_DIR#$INSTALL_DIR#g" "$tmp_script"

    chmod +x "$tmp_script"
    if ! mv -f "$tmp_script" "$INSTALL_DIR/conduit"; then
        rm -f "$tmp_script"
        log_error "Failed to update management script"
        return 1
    fi
    # Force create symlink
    rm -f /usr/local/bin/conduit 2>/dev/null || true
    ln -s "$INSTALL_DIR/conduit" /usr/local/bin/conduit
    
    log_success "Management script installed: conduit"
}

#═══════════════════════════════════════════════════════════════════════
# Summary
#═══════════════════════════════════════════════════════════════════════

print_summary() {
    local init_type="Enabled"
    if [ "$HAS_SYSTEMD" = "true" ]; then
        init_type="Enabled (systemd)"
    elif command -v rc-update &>/dev/null; then
        init_type="Enabled (OpenRC)"
    elif [ -d /etc/init.d ]; then
        init_type="Enabled (SysVinit)"
    fi
    
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    ✅ INSTALLATION COMPLETE!                      ║${NC}"
    echo -e "${GREEN}╠═══════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  Conduit is running and ready to help users!                      ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                                                                   ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  📊 Settings:                                                     ${GREEN}║${NC}"
    printf "${GREEN}║${NC}     Max Clients: ${CYAN}%-4s${NC}                                             ${GREEN}║${NC}\n" "${MAX_CLIENTS}"
    if [ "$BANDWIDTH" == "-1" ]; then
        echo -e "${GREEN}║${NC}     Bandwidth:   ${CYAN}Unlimited${NC}                                        ${GREEN}║${NC}"
    else
        printf "${GREEN}║${NC}     Bandwidth:   ${CYAN}%-4s${NC} Mbps                                        ${GREEN}║${NC}\n" "${BANDWIDTH}"
    fi
    printf "${GREEN}║${NC}     Auto-start:  ${CYAN}%-20s${NC}                             ${GREEN}║${NC}\n" "${init_type}"
    echo -e "${GREEN}║${NC}                                                                   ${GREEN}║${NC}"
    echo -e "${GREEN}╠═══════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  COMMANDS:                                                        ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                                                                   ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}conduit${NC}               # Open management menu                    ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}conduit stats${NC}         # View live statistics + CPU/RAM          ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}conduit status${NC}        # Quick status with resource usage        ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}conduit logs${NC}          # View raw logs                           ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}conduit settings${NC}      # Change max-clients/bandwidth            ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}conduit uninstall${NC}     # Remove everything                       ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                                                                   ${GREEN}║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${YELLOW}View live stats now:${NC} conduit stats"
    echo ""
}

#═══════════════════════════════════════════════════════════════════════
# Uninstall Function
#═══════════════════════════════════════════════════════════════════════

uninstall() {
    if [ "${AUTO_INSTALL}" = "true" ]; then
        uninstall_silent
        log_success "Uninstall complete (headless)."
        return 0
    fi
    telegram_disable_service
    rm -f /etc/systemd/system/conduit-telegram.service 2>/dev/null
    systemctl daemon-reload 2>/dev/null || true
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo "║                    ⚠️  UNINSTALL CONDUIT                          "
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "This will completely remove:"
    echo "  • Conduit Docker container"
    echo "  • Conduit Docker image"
    echo "  • Conduit data volume (all stored data)"
    echo "  • Auto-start service (systemd/OpenRC/SysVinit)"
    echo "  • Configuration files"
    echo "  • Management CLI"
    echo ""
    echo -e "${RED}WARNING: This action cannot be undone!${NC}"
    echo ""
    read -p "Are you sure you want to uninstall? (type 'yes' to confirm): " confirm < /dev/tty || true
    
    if [ "$confirm" != "yes" ]; then
        echo "Uninstall cancelled."
        exit 0
    fi
    
    echo ""
    log_info "Stopping Conduit container(s)..."
    for i in 1 2 3 4 5; do
        local cname="conduit"
        local vname="conduit-data"
        [ "$i" -gt 1 ] && cname="conduit-${i}" && vname="conduit-data-${i}"
        docker stop "$cname" 2>/dev/null || true
        docker rm -f "$cname" 2>/dev/null || true
        docker volume rm "$vname" 2>/dev/null || true
    done

    log_info "Removing Conduit Docker image..."
    docker rmi "$CONDUIT_IMAGE" 2>/dev/null || true
    
    log_info "Removing auto-start service..."
    # Systemd
    systemctl stop conduit.service 2>/dev/null || true
    systemctl disable conduit.service 2>/dev/null || true
    rm -f /etc/systemd/system/conduit.service
    systemctl daemon-reload 2>/dev/null || true
    # OpenRC / SysVinit
    rc-service conduit stop 2>/dev/null || true
    rc-update del conduit 2>/dev/null || true
    service conduit stop 2>/dev/null || true
    update-rc.d conduit remove 2>/dev/null || true
    chkconfig conduit off 2>/dev/null || true
    rm -f /etc/init.d/conduit
    
    log_info "Removing configuration files..."
    [ -n "$INSTALL_DIR" ] && rm -rf "$INSTALL_DIR"
    rm -f /usr/local/bin/conduit
    
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    ✅ UNINSTALL COMPLETE!                         ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Conduit and all related components have been removed."
    echo ""
    echo "Note: Docker itself was NOT removed."
    echo ""
}

#═══════════════════════════════════════════════════════════════════════
# Main
#═══════════════════════════════════════════════════════════════════════

show_usage() {
    echo "Psiphon Conduit Manager v${VERSION}"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  (no args)      Install or open management menu if already installed"
    echo "  --reinstall    Force fresh reinstall"
    echo "  --uninstall    Completely remove Conduit and all components"
    echo "  --help, -h     Show this help message"
    echo ""
    echo "Examples:"
    echo "  sudo bash $0              # Install or open menu"
    echo "  sudo bash $0 --reinstall  # Fresh install"
    echo "  sudo bash $0 --uninstall  # Remove everything"
    echo ""
    echo "After install, use: conduit"
}

main() {
    # Handle command line arguments
    case "${1:-}" in
        --auto|--headless)
            AUTO_INSTALL=true
            ;;
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
            # Force reinstall
            FORCE_REINSTALL=true
            ;;
        --update-components)
            # Called by menu update to regenerate scripts without touching containers
            INSTALL_DIR="/opt/conduit"
            [ -f "$INSTALL_DIR/settings.conf" ] && source "$INSTALL_DIR/settings.conf"
            if ! create_management_script; then
                echo -e "${RED}Failed to update management script${NC}"
                exit 1
            fi
            # Rewrite conduit.service to correct format (fixes stale/old service files)
            if command -v systemctl &>/dev/null && [ -f /etc/systemd/system/conduit.service ]; then
                local need_rewrite=false
                # Detect old/mismatched service files
                grep -q "Requires=docker.service" /etc/systemd/system/conduit.service 2>/dev/null && need_rewrite=true
                grep -q "Type=simple" /etc/systemd/system/conduit.service 2>/dev/null && need_rewrite=true
                grep -q "Restart=always" /etc/systemd/system/conduit.service 2>/dev/null && need_rewrite=true
                grep -q "max-clients" /etc/systemd/system/conduit.service 2>/dev/null && need_rewrite=true
                if [ "$need_rewrite" = true ]; then
                    # Overwrite file first, then reload to replace old Restart=always definition
                    cat > /etc/systemd/system/conduit.service << SVCEOF
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
                    systemctl daemon-reload 2>/dev/null || true
                    systemctl stop conduit.service 2>/dev/null || true
                    systemctl reset-failed conduit.service 2>/dev/null || true
                    systemctl enable conduit.service 2>/dev/null || true
                    systemctl start conduit.service 2>/dev/null || true
                fi
            fi
            setup_tracker_service 2>/dev/null || true
            if [ "$TELEGRAM_ENABLED" = "true" ]; then
                telegram_generate_notify_script 2>/dev/null || true
                systemctl restart conduit-telegram 2>/dev/null || true
                echo -e "${GREEN}✓ Telegram service updated${NC}"
            fi
            exit 0
            ;;
    esac
    
    print_header
    ensure_root "$@"
    # Default to headless when stdin is not a TTY (e.g., curl | bash)
    if [ "${AUTO_INSTALL}" != "true" ] && [ ! -t 0 ]; then
        AUTO_INSTALL=true
    fi
    detect_os
    
    # Ensure all tools (including new ones like tcpdump) are present
    check_dependencies

    if [ "${AUTO_INSTALL}" = "true" ]; then
        update_system_packages
    fi
    
    # Check if already installed
    while [ -f "$INSTALL_DIR/conduit" ] && [ "$FORCE_REINSTALL" != "true" ]; do
        if [ "${AUTO_INSTALL}" = "true" ]; then
            log_info "Existing installation detected — performing automated cleanup for a fresh environment."
            uninstall_silent
            break
        fi
        echo -e "${GREEN}Conduit is already installed!${NC}"
        echo ""
        echo "What would you like to do?"
        echo ""
        echo "  1. 📊 Open management menu"
        echo "  2. 🔄 Reinstall (fresh install)"
        echo "  3. 🗑️  Uninstall"
        echo "  0. 🚪 Exit"
        echo ""
        read -p "  Enter choice: " choice < /dev/tty || { echo -e "\n  ${RED}Input error. Cannot read from terminal. Exiting.${NC}"; exit 1; }

        case "$choice" in
            1)
                echo -e "${CYAN}Updating management script and opening menu...${NC}"
                create_management_script
                # Regenerate Telegram script if enabled (picks up new features)
                if [ -f "$INSTALL_DIR/settings.conf" ]; then
                    source "$INSTALL_DIR/settings.conf"
                    if [ "$TELEGRAM_ENABLED" = "true" ]; then
                        telegram_generate_notify_script 2>/dev/null || true
                        systemctl restart conduit-telegram 2>/dev/null || true
                    fi
                fi
                exec "$INSTALL_DIR/conduit" menu
                ;;
            2)
                echo ""
                log_info "Starting fresh reinstall..."
                break
                ;;
            3)
                uninstall
                exit 0
                ;;
            0)
                echo "Exiting."
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid choice: ${NC}${YELLOW}$choice${NC}"
                echo -e "${CYAN}Returning to installer...${NC}"
                sleep 1
                ;;
        esac
    done

    # Settings: interactive by default, headless uses fixed defaults
    if [ "${AUTO_INSTALL}" = "true" ]; then
        apply_headless_defaults
    else
        prompt_settings
    fi

    echo ""
    echo -e "${CYAN}Starting installation...${NC}"
    echo ""

    #───────────────────────────────────────────────────────────────
    # Installation Steps (5 steps if backup exists, otherwise 4)
    #───────────────────────────────────────────────────────────────

    # Step 1: Install Docker (if not already installed)
    log_info "Step 1/5: Installing Docker..."
    install_docker

    echo ""

    # Step 2: Check for and optionally restore backup keys
    # This preserves node identity if user had a previous installation
    log_info "Step 2/5: Checking for previous node identity..."
    if [ "${AUTO_INSTALL}" != "true" ]; then
        check_and_offer_backup_restore || true
    else
        log_info "Headless mode: skipping interactive restore prompt."
    fi

    echo ""

    # Step 3: Start Conduit container
    log_info "Step 3/5: Starting Conduit..."
    # Clean up any existing containers from previous install/scaling
    docker stop conduit 2>/dev/null || true
    docker rm -f conduit 2>/dev/null || true
    for i in 2 3 4 5; do
        docker stop "conduit-${i}" 2>/dev/null || true
        docker rm -f "conduit-${i}" 2>/dev/null || true
    done
    run_conduit
    
    echo ""

    # Step 4: Save settings and configure auto-start service
    log_info "Step 4/5: Setting up auto-start..."
    save_settings_install
    setup_autostart
    setup_tracker_service 2>/dev/null || true

    echo ""

    # Step 5: Create the 'conduit' CLI management script
    log_info "Step 5/5: Creating management script..."
    create_management_script

    print_summary

    log_info "Installation complete. Opening management menu..."
    "$INSTALL_DIR/conduit" menu
}
#
# REACHED END OF SCRIPT - VERSION 1.2
# ###############################################################################
main "$@"


