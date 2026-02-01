#!/bin/bash
#
# Conduit Manager Menu - Iranux Edition
#

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

show_header() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║       PSIPHON CONDUIT MANAGER          ║${NC}"
    echo -e "${BLUE}║           (Iranux Repo)                ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
    echo ""
}

check_status() {
    if docker ps | grep -q conduit; then
        echo -e "Status: ${GREEN}RUNNING${NC}"
        # Extract uptime
        docker ps -f name=conduit --format "Uptime: {{.Status}}"
    else
        echo -e "Status: ${RED}STOPPED${NC}"
    fi
}

show_logs() {
    echo "Showing last 50 logs (Press Ctrl+C to exit)..."
    docker logs -f --tail 50 conduit
}

restart_conduit() {
    echo "Restarting service..."
    docker restart conduit
    echo -e "${GREEN}Done.${NC}"
    sleep 1
}

print_tokens() {
    echo "--- Server Keys & Info ---"
    # Try to find the key in the volume
    if docker exec conduit cat /home/conduit/data/conduit_key.json &>/dev/null; then
         docker exec conduit cat /home/conduit/data/conduit_key.json
    else
         echo "Key file not found inside container."
    fi
    echo ""
    echo "Press Enter to return..."
    read
}

uninstall_conduit() {
    echo -e "${RED}WARNING: This will remove Conduit and all data.${NC}"
    read -p "Are you sure? (y/n): " choice
    if [[ "$choice" == "y" ]]; then
        docker stop conduit
        docker rm conduit
        docker volume rm conduit-data
        rm -f /usr/local/bin/conduit
        echo "Uninstalled."
        exit 0
    fi
}

# Main Loop
while true; do
    show_header
    check_status
    echo ""
    echo "1) 📜 Show Logs (Live)"
    echo "2) 🔄 Restart Service"
    echo "3) 🔑 Show Server Key/Tokens"
    echo "4) 🛑 Stop Service"
    echo "5) ▶️ Start Service"
    echo "6) ❌ Uninstall"
    echo "0) Exit"
    echo ""
    read -p "Select option: " opt

    case $opt in
        1) show_logs ;;
        2) restart_conduit ;;
        3) print_tokens ;;
        4) docker stop conduit; sleep 1 ;;
        5) docker start conduit; sleep 1 ;;
        6) uninstall_conduit ;;
        0) exit 0 ;;
        *) echo "Invalid option"; sleep 1 ;;
    esac
done
