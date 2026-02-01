#!/bin/bash

# =================================================================
# Project: IRANUX PSIPHON CONDUIT (Local Build Edition)
# Target OS: Ubuntu 24.04
# Logic: Downloads binary directly from GitHub to avoid Docker Denied errors.
# =================================================================

set -eo pipefail

# --- Configuration ---
MAX_CLIENTS=50
BANDWIDTH=10
INSTALL_DIR="/var/lib/conduit"
INSTALL_DATE_FILE="$INSTALL_DIR/install_date"
IRAN_IP_LIST="/etc/conduit/iran_ips.txt"
SMART_GUARD_CONF="/etc/conduit/smart_guard.status"
# URL for the official/reliable binary
BINARY_URL="https://github.com/Psiphon-Inc/psiphon-conduit/releases/latest/download/psiphon-conduit-linux-x86_64.zip"

# --- 1. Root Check ---
if [ "$EUID" -ne 0 ]; then
    exec sudo bash "$0" "$@"
fi

# --- 2. Environment Preparation ---
# Creating directories FIRST to prevent path errors.
prepare_env() {
    echo "[*] Creating system directories..."
    mkdir -p "$INSTALL_DIR"
    mkdir -p "/etc/conduit"
    mkdir -p "/tmp/conduit_build"
    
    echo "[*] Installing dependencies (Docker, Ipset, Unzip)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y && apt-get install -y curl docker.io ipset iptables jq unzip wget
    systemctl enable --now docker
}

# --- 3. Nuclear Clean ---
clean_old_stuff() {
    echo "[*] Cleaning up old instances..."
    docker stop conduit 2>/dev/null || true
    docker rm -f conduit 2>/dev/null || true
    systemctl stop conduit-guard 2>/dev/null || true
    rm -f /etc/systemd/system/conduit-guard.service
}

# --- 4. Smart Guard Setup ---
setup_guard() {
    if [ ! -f "$INSTALL_DATE_FILE" ]; then
        date +%s > "$INSTALL_DATE_FILE"
    fi
    echo "[*] Fetching Iran IP database..."
    curl -s -H "Cache-Control: no-cache" https://www.ip2location.com/free/visitor-blocker -d "countryCode=IR&format=cidr" > "$IRAN_IP_LIST" || echo "1.0.0.0/8" > "$IRAN_IP_LIST"
    echo "enabled" > "$SMART_GUARD_CONF"
}

# --- 5. Firewall Engine ---
apply_rules() {
    [ ! -f "$INSTALL_DATE_FILE" ] && return
    local start_t=$(cat "$INSTALL_DATE_FILE")
    local diff=$(( ($(date +%s) - start_t) / 3600 ))

    if [ "$diff" -ge 12 ]; then
        echo "[!] Grace period over. Enforcing 5-min session limit for foreigners."
        ipset destroy iran_ips 2>/dev/null || true
        ipset create iran_ips hash:net
        while read -r ip; do [[ -n "$ip" ]] && ipset add iran_ips "$ip" -!; done < "$IRAN_IP_LIST"

        iptables -F INPUT 2>/dev/null || true
        iptables -A INPUT -p tcp --dport 1080 -m set --match-set iran_ips src -j ACCEPT
        iptables -A INPUT -p tcp --dport 1080 -m recent --name non_iran --set
        iptables -A INPUT -p tcp --dport 1080 -m recent --name non_iran --update --seconds 300 -j DROP
    fi
}

# --- 6. Core Deployment (Local Binary Method) ---
# This mimics the "Original Code" behavior to avoid Docker Registry Denied errors.
deploy() {
    echo "[*] Downloading Conduit binary from GitHub..."
    cd /tmp/conduit_build
    wget -qO conduit.zip "$BINARY_URL"
    unzip -o conduit.zip && rm conduit.zip
    mv psiphon-conduit-linux-x86_64 conduit
    chmod +x conduit

    echo "[*] Building local Docker image (No Pull Required)..."
    cat <<EOF > Dockerfile
FROM ubuntu:24.04
COPY conduit /usr/local/bin/conduit
RUN chmod +x /usr/local/bin/conduit
ENTRYPOINT ["/usr/local/bin/conduit"]
EOF
    docker build -t conduit-local .

    echo "[*] Starting Container..."
    docker run -d --name conduit --restart always --network host \
        -v /root/conduit_backup:/data conduit-local \
        --max-clients $MAX_CLIENTS --bandwidth $BANDWIDTH
}

# --- 7. Management CLI (Flicker-Free) ---
finalize() {
    cat <<'EOF' > /usr/local/bin/conduit
#!/bin/bash
while true; do
    clear
    echo "======================================"
    echo "      IRANUX CONDUIT MANAGER"
    echo "======================================"
    echo "1) View Live Stats (Smooth Refresh)"
    echo "2) Restart Node"
    echo "3) Smart Guard Status"
    echo "4) Exit"
    echo "======================================"
    read -p "Select option: " opt
    case $opt in
        1) watch -n 2 "docker stats conduit --no-stream" ;;
        2) docker restart conduit && echo "Restarted." && sleep 1 ;;
        3) 
           start_t=$(cat /var/lib/conduit/install_date)
           diff=$(( ($(date +%s) - start_t) / 3600 ))
           echo "Uptime: $diff hours"
           [[ $diff -ge 12 ]] && echo "Guard: ACTIVE" || echo "Guard: GRACE PERIOD"
           read -p "Press Enter to return..." ;;
        4) exit 0 ;;
    esac
done
EOF
    chmod +x /usr/local/bin/conduit

    # Persistence Service
    cat <<EOF > /etc/systemd/system/conduit-guard.service
[Unit]
Description=Conduit Guard
After=network.target docker.service
[Service]
Type=oneshot
ExecStart=/bin/bash -c "source <(curl -sL -H 'Cache-Control: no-cache' https://raw.githubusercontent.com/iranux/PSIPHON-CONDUIT/main/Ubuntu24-iranux.sh) --apply-rules"
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable conduit-guard.service
}

# --- Execution ---
if [[ "$1" == "--apply-rules" ]]; then
    apply_rules
else
    echo "🚀 Installing Iranux Psiphon Conduit (Local Build)..."
    prepare_env
    clean_old_stuff
    setup_guard
    deploy
    apply_rules
    finalize
    echo "✅ Installation Success! Type 'conduit' to manage."
fi
