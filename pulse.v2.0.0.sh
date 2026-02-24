#!/usr/bin/env bash
# =============================================================================
#  AEQUUM IMPERIUM — SYSTEM PULSE MONITOR
#  MN-SC Core | Minneapolis, MN | Homelab Series
#  Version: 2.0.0
#  License: MIT
# =============================================================================
#
#  USAGE:
#    ./pulse.sh              # Single snapshot
#    ./pulse.sh -w           # Watch mode (refreshes every 5s)
#    ./pulse.sh -w -i 10    # Watch mode, refresh every 10s
#    ./pulse.sh -q           # Minimal output (no ASCII header)
#
# =============================================================================

set -euo pipefail

# ── DEFAULTS ──────────────────────────────────────────────────────────────────
WATCH=false
INTERVAL=5
QUIET=false

# ── COLORS ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── ARGS ──────────────────────────────────────────────────────────────────────
while getopts ":wi:qh" opt; do
    case $opt in
        w) WATCH=true ;;
        i) INTERVAL="$OPTARG" ;;
        q) QUIET=true ;;
        h)
            echo "Usage: $0 [-w] [-i seconds] [-q]"
            echo "  -w         Watch mode (live refresh)"
            echo "  -i <sec>   Refresh interval (default: 5)"
            echo "  -q         Quiet — no ASCII banner"
            exit 0 ;;
        :) echo "Option -$OPTARG requires an argument." >&2; exit 1 ;;
        \?) echo "Unknown option: -$OPTARG" >&2; exit 1 ;;
    esac
done

# ── HELPERS ───────────────────────────────────────────────────────────────────

# Color threshold helper — green/yellow/red based on percentage
threshold_color() {
    local val=$1   # numeric percentage 0-100
    if   [[ $val -ge 90 ]]; then echo -e "${RED}"
    elif [[ $val -ge 70 ]]; then echo -e "${YELLOW}"
    else                         echo -e "${GREEN}"
    fi
}

# Draw a simple ASCII bar
# Usage: draw_bar <percent> <width>
draw_bar() {
    local pct=$1
    local width=${2:-30}
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local color
    color=$(threshold_color "$pct")
    printf "${color}"
    printf '█%.0s' $(seq 1 $filled 2>/dev/null) 2>/dev/null || true
    printf "${DIM}"
    printf '░%.0s' $(seq 1 $empty 2>/dev/null) 2>/dev/null || true
    printf "${NC}"
}

# ── DATA COLLECTION ───────────────────────────────────────────────────────────
collect() {
    # Date / Uptime
    CURRENT_DATE=$(date '+%Y-%m-%d  %H:%M:%S')
    UPTIME_CLEAN=$(uptime -p 2>/dev/null || uptime | sed 's/.*up /up /' | cut -d',' -f1-2)

    # Hostname
    HOST=$(hostname -s)

    # CPU load averages
    read -r LOAD1 LOAD5 LOAD15 <<< "$(uptime | awk -F'load average:' '{print $2}' | tr -d ' ' | tr ',' ' ')"

    # CPU core count for context
    CPU_CORES=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)

    # CPU usage % (1 second sample)
    CPU_PCT=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 | cut -d',' -f1 | awk '{printf "%.0f", $1}' 2>/dev/null || echo "0")

    # Memory
    MEM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    MEM_AVAIL_KB=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    MEM_USED_KB=$(( MEM_TOTAL_KB - MEM_AVAIL_KB ))
    MEM_PCT=$(( MEM_USED_KB * 100 / MEM_TOTAL_KB ))
    MEM_USED_H=$(free -h | awk '/^Mem:/ {print $3}')
    MEM_TOTAL_H=$(free -h | awk '/^Mem:/ {print $2}')

    # Swap
    SWAP_TOTAL_KB=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
    SWAP_FREE_KB=$(grep SwapFree /proc/meminfo | awk '{print $2}')
    SWAP_USED_KB=$(( SWAP_TOTAL_KB - SWAP_FREE_KB ))
    if [[ $SWAP_TOTAL_KB -gt 0 ]]; then
        SWAP_PCT=$(( SWAP_USED_KB * 100 / SWAP_TOTAL_KB ))
        SWAP_USED_H=$(free -h | awk '/^Swap:/ {print $3}')
        SWAP_TOTAL_H=$(free -h | awk '/^Swap:/ {print $2}')
    else
        SWAP_PCT=0
        SWAP_USED_H="0B"
        SWAP_TOTAL_H="0B"
    fi

    # Disk (root)
    DISK_USED_H=$(df -h / | awk 'NR==2 {print $3}')
    DISK_TOTAL_H=$(df -h / | awk 'NR==2 {print $2}')
    DISK_PCT=$(df / | awk 'NR==2 {gsub(/%/,""); print $5}')

    # Network interfaces and IP (fallback-safe)
    if command -v ip &>/dev/null; then
        NET_INTERFACES=$(ip -o link show 2>/dev/null | awk -F': ' '$2 !~ /lo|docker|veth|br-/ {print $2}' | head -4 | tr '\n' ' ')
        LOCAL_IP=$(ip -4 addr show scope global 2>/dev/null | grep inet | head -1 | awk '{print $2}' | cut -d'/' -f1)
    else
        NET_INTERFACES=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' | head -4 | tr '\n' ' ' || echo "N/A")
        LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "N/A")
    fi
    LOCAL_IP=${LOCAL_IP:-"N/A"}

    # CPU temp (if available)
    if command -v sensors &>/dev/null; then
        CPU_TEMP=$(sensors 2>/dev/null | grep -E 'Core 0|Package|Tdie|Tctl' | head -1 | awk '{print $3}' | tr -d '+°C' || echo "N/A")
    elif [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
        TEMP_RAW=$(cat /sys/class/thermal/thermal_zone0/temp)
        CPU_TEMP=$(awk "BEGIN {printf \"%.1f\", $TEMP_RAW/1000}")
    else
        CPU_TEMP="N/A"
    fi

    # Running processes
    PROC_COUNT=$(ps aux --no-header | wc -l)

    # Proxmox VMs/CTs (if applicable)
    if command -v qm &>/dev/null; then
        VM_COUNT=$(qm list 2>/dev/null | grep -c running || echo 0)
        CT_COUNT=$(pct list 2>/dev/null | grep -c running || echo 0)
        PVE_ACTIVE=true
    else
        VM_COUNT=0
        CT_COUNT=0
        PVE_ACTIVE=false
    fi
}

# ── RENDER ────────────────────────────────────────────────────────────────────
render() {
    collect

    if [[ "$QUIET" == false ]]; then
        clear 2>/dev/null || true

        # ASCII BANNER
        echo -e "${CYAN}${BOLD}"
        echo '  ██████╗ ██╗   ██╗██╗     ███████╗███████╗'
        echo '  ██╔══██╗██║   ██║██║     ██╔════╝██╔════╝'
        echo '  ██████╔╝██║   ██║██║     ███████╗█████╗  '
        echo '  ██╔═══╝ ██║   ██║██║     ╚════██║██╔══╝  '
        echo '  ██║     ╚██████╔╝███████╗███████║███████╗'
        echo '  ╚═╝      ╚═════╝ ╚══════╝╚══════╝╚══════╝'
        echo -e "${NC}"
        echo -e "  ${DIM}MN-SC CORE  //  SYSTEM PULSE  //  Minneapolis, MN${NC}"
        echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
    fi

    # ── HEADER ────────────────────────────────────────────────────────────────
    echo -e "  ${BOLD}HOST${NC}    ${CYAN}$HOST${NC}   ${DIM}|${NC}  ${BOLD}IP${NC} ${CYAN}$LOCAL_IP${NC}"
    echo -e "  ${BOLD}TIME${NC}    $CURRENT_DATE"
    echo -e "  ${BOLD}UPTIME${NC}  $UPTIME_CLEAN"
    echo ""

    # ── CPU ───────────────────────────────────────────────────────────────────
    echo -e "  ${BOLD}${MAGENTA}[ CPU ]${NC}"
    CPU_COLOR=$(threshold_color "$CPU_PCT")
    echo -ne "  Usage     $(draw_bar "$CPU_PCT") "
    echo -e "${CPU_COLOR}${CPU_PCT}%${NC}  ${DIM}(${CPU_CORES} cores)${NC}"
    echo -e "  Load avg  ${CYAN}${LOAD1}${NC} ${DIM}(1m)${NC}  ${CYAN}${LOAD5}${NC} ${DIM}(5m)${NC}  ${CYAN}${LOAD15}${NC} ${DIM}(15m)${NC}"
    if [[ "$CPU_TEMP" != "N/A" ]]; then
        echo -e "  Temp      ${CYAN}${CPU_TEMP}°C${NC}"
    fi
    echo ""

    # ── MEMORY ────────────────────────────────────────────────────────────────
    echo -e "  ${BOLD}${MAGENTA}[ MEMORY ]${NC}"
    MEM_COLOR=$(threshold_color "$MEM_PCT")
    echo -ne "  RAM       $(draw_bar "$MEM_PCT") "
    echo -e "${MEM_COLOR}${MEM_PCT}%${NC}  ${DIM}${MEM_USED_H} / ${MEM_TOTAL_H}${NC}"

    if [[ $SWAP_TOTAL_KB -gt 0 ]]; then
        SWAP_COLOR=$(threshold_color "$SWAP_PCT")
        echo -ne "  Swap      $(draw_bar "$SWAP_PCT") "
        echo -e "${SWAP_COLOR}${SWAP_PCT}%${NC}  ${DIM}${SWAP_USED_H} / ${SWAP_TOTAL_H}${NC}"
    fi
    echo ""

    # ── STORAGE ───────────────────────────────────────────────────────────────
    echo -e "  ${BOLD}${MAGENTA}[ STORAGE ]${NC}"
    DISK_COLOR=$(threshold_color "$DISK_PCT")
    echo -ne "  Root ( / ) $(draw_bar "$DISK_PCT") "
    echo -e "${DISK_COLOR}${DISK_PCT}%${NC}  ${DIM}${DISK_USED_H} / ${DISK_TOTAL_H}${NC}"

    # Additional mount points if present
    for mount in /mnt /mnt/archive /mnt/data /home; do
        if mountpoint -q "$mount" 2>/dev/null; then
            M_USED=$(df -h "$mount" | awk 'NR==2 {print $3}')
            M_TOTAL=$(df -h "$mount" | awk 'NR==2 {print $2}')
            M_PCT=$(df "$mount" | awk 'NR==2 {gsub(/%/,""); print $5}')
            M_COLOR=$(threshold_color "$M_PCT")
            echo -ne "  ${mount}   $(draw_bar "$M_PCT") "
            echo -e "${M_COLOR}${M_PCT}%${NC}  ${DIM}${M_USED} / ${M_TOTAL}${NC}"
        fi
    done
    echo ""

    # ── NETWORK ───────────────────────────────────────────────────────────────
    echo -e "  ${BOLD}${MAGENTA}[ NETWORK ]${NC}"
    echo -e "  Interfaces  ${CYAN}${NET_INTERFACES:-none detected}${NC}"
    echo -e "  Processes   ${CYAN}${PROC_COUNT}${NC} running"
    echo ""

    # ── PROXMOX (if detected) ─────────────────────────────────────────────────
    if [[ "$PVE_ACTIVE" == true ]]; then
        echo -e "  ${BOLD}${MAGENTA}[ PROXMOX VE ]${NC}"
        echo -e "  VMs running   ${CYAN}${VM_COUNT}${NC}"
        echo -e "  CTs running   ${CYAN}${CT_COUNT}${NC}"
        echo ""
    fi

    # ── FOOTER ────────────────────────────────────────────────────────────────
    if [[ "$QUIET" == false ]]; then
        echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        if [[ "$WATCH" == true ]]; then
            echo -e "  ${DIM}Refreshing every ${INTERVAL}s  //  Ctrl+C to exit${NC}\n"
        else
            echo -e "  ${DIM}MN-SC Core  //  Pulse v2.0.0  //  $(date '+%Y-%m-%d %H:%M:%S')${NC}\n"
        fi
    fi
}

# ── MAIN ──────────────────────────────────────────────────────────────────────
if [[ "$WATCH" == true ]]; then
    while true; do
        render
        sleep "$INTERVAL"
    done
else
    render
fi
