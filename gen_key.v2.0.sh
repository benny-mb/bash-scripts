#!/usr/bin/env bash
# =============================================================================
#  AEQUUM IMPERIUM — PASSKEY GENERATION PROTOCOL
#  MN-SC Core | Minneapolis, MN | Homelab Series
#  Version: 2.0.0
#  License: MIT
# =============================================================================
#
#  WHAT THIS SCRIPT DOES:
#    Generates cryptographically secure random passwords using /dev/urandom.
#    Supports full printable character sets or restricted alphanumeric mode.
#    Optional clipboard copy via xclip.
#
#  USAGE:
#    ./gen_key.sh [OPTIONS]
#
#  OPTIONS:
#    -l <length>    Password length (default: 24, min: 8, max: 128)
#    -a             Alphanumeric only (safe for scripts/configs/web forms)
#    -c             Copy to clipboard (requires xclip)
#    -n <count>     Generate multiple keys (default: 1, max: 20)
#    -q             Quiet mode — output password only (useful for scripting)
#    -h             Show this help
#
#  EXAMPLES:
#    ./gen_key.sh                    # 24-char full character password
#    ./gen_key.sh -l 32             # 32-char full character password
#    ./gen_key.sh -l 16 -a         # 16-char alphanumeric only
#    ./gen_key.sh -l 32 -c         # generate and copy to clipboard
#    ./gen_key.sh -n 5             # generate 5 passwords
#    ./gen_key.sh -l 20 -q         # quiet mode for use in scripts
#
# =============================================================================

set -euo pipefail

# ── DEFAULTS ──────────────────────────────────────────────────────────────────
LENGTH=24
ALPHANUMERIC=false
CLIPBOARD=false
COUNT=1
QUIET=false

# ── COLORS ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── HELPERS ───────────────────────────────────────────────────────────────────
info()  { [[ "$QUIET" == false ]] && echo -e "${CYAN}[INFO]${NC}  $*"; }
warn()  { [[ "$QUIET" == false ]] && echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

usage() {
    echo -e "\n${BOLD}AEQUUM IMPERIUM — Passkey Generator v2.0.0${NC}"
    echo -e "${DIM}MN-SC Core | Minneapolis, MN${NC}\n"
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -l <length>   Password length (default: 24, min: 8, max: 128)"
    echo "  -a            Alphanumeric only (A-Za-z0-9)"
    echo "  -c            Copy to clipboard (requires xclip)"
    echo "  -n <count>    Number of passwords to generate (default: 1, max: 20)"
    echo "  -q            Quiet mode — output password only"
    echo "  -h            Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 -l 32 -a       # 32-char alphanumeric"
    echo "  $0 -l 48 -c       # 48-char full, copy to clipboard"
    echo "  $0 -n 5 -l 16     # 5 passwords, 16 chars each"
    echo ""
    exit 0
}

# ── ARGUMENT PARSING ──────────────────────────────────────────────────────────
while getopts ":l:acn:qh" opt; do
    case $opt in
        l) LENGTH="$OPTARG" ;;
        a) ALPHANUMERIC=true ;;
        c) CLIPBOARD=true ;;
        n) COUNT="$OPTARG" ;;
        q) QUIET=true ;;
        h) usage ;;
        :) error "Option -$OPTARG requires an argument." ;;
        \?) error "Unknown option: -$OPTARG. Use -h for help." ;;
    esac
done

# ── INPUT VALIDATION ──────────────────────────────────────────────────────────
[[ "$LENGTH" =~ ^[0-9]+$ ]]  || error "Length must be a positive integer. Got: '$LENGTH'"
[[ "$COUNT"  =~ ^[0-9]+$ ]]  || error "Count must be a positive integer. Got: '$COUNT'"
[[ "$LENGTH" -ge 8   ]]      || error "Minimum length is 8. Got: $LENGTH"
[[ "$LENGTH" -le 128 ]]      || error "Maximum length is 128. Got: $LENGTH"
[[ "$COUNT"  -ge 1   ]]      || error "Count must be at least 1."
[[ "$COUNT"  -le 20  ]]      || error "Maximum count is 20. Got: $COUNT"

# Check /dev/urandom is available
[[ -r /dev/urandom ]] || error "/dev/urandom not readable. Cannot generate secure keys."

# Warn if clipboard requested but xclip not found
if [[ "$CLIPBOARD" == true ]] && ! command -v xclip &>/dev/null; then
    warn "xclip not found. Install with: sudo apt install xclip"
    CLIPBOARD=false
fi

# ── PASSWORD GENERATION ───────────────────────────────────────────────────────
generate_password() {
    if [[ "$ALPHANUMERIC" == true ]]; then
        LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$LENGTH"
    else
        # Full printable set excluding space
        # Backslash excluded to prevent issues in most contexts
        LC_ALL=C tr -dc '!"#$%&()*+,\-./:;<=>?@A-Z[\]^_`a-z{|}~0-9' < /dev/urandom | head -c "$LENGTH"
    fi
    echo ""
}

# ── OUTPUT ────────────────────────────────────────────────────────────────────
if [[ "$QUIET" == false ]]; then
    echo -e "\n${BOLD}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   AEQUUM IMPERIUM — PASSKEY GENERATOR v2.0.0     ║${NC}"
    echo -e "${BOLD}║   MN-SC Core | Minneapolis, MN                   ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}\n"

    MODE_LABEL=$( [[ "$ALPHANUMERIC" == true ]] && echo "Alphanumeric" || echo "Full printable" )
    echo -e "  ${DIM}Length:${NC} $LENGTH  |  ${DIM}Mode:${NC} $MODE_LABEL  |  ${DIM}Count:${NC} $COUNT"
    echo -e "  ${DIM}Source:${NC} /dev/urandom (cryptographically secure)\n"
    echo -e "  ────────────────────────────────────────────────────"
fi

LAST_PASSWORD=""
for ((i = 1; i <= COUNT; i++)); do
    PASSWORD=$(generate_password)
    LAST_PASSWORD="$PASSWORD"

    if [[ "$QUIET" == true ]]; then
        echo "$PASSWORD"
    else
        if [[ "$COUNT" -gt 1 ]]; then
            echo -e "  ${DIM}[$i]${NC} ${GREEN}${BOLD}$PASSWORD${NC}"
        else
            echo -e "  ${GREEN}${BOLD}$PASSWORD${NC}"
        fi
    fi
done

if [[ "$QUIET" == false ]]; then
    echo -e "  ────────────────────────────────────────────────────\n"
fi

# ── CLIPBOARD ─────────────────────────────────────────────────────────────────
if [[ "$CLIPBOARD" == true ]]; then
    # Copy last generated password to clipboard
    echo -n "$LAST_PASSWORD" | xclip -selection clipboard
    info "Last key copied to clipboard."
fi

# ── STRENGTH INDICATOR ────────────────────────────────────────────────────────
if [[ "$QUIET" == false ]]; then
    if [[ "$ALPHANUMERIC" == true ]]; then
        CHARSET=62
    else
        CHARSET=91
    fi

    # Rough entropy estimate: log2(charset^length)
    # Using awk for float math
    ENTROPY=$(awk "BEGIN { printf \"%.0f\", $LENGTH * log($CHARSET) / log(2) }")

    if   [[ "$ENTROPY" -ge 128 ]]; then STRENGTH="${GREEN}EXCELLENT${NC}"
    elif [[ "$ENTROPY" -ge 80  ]]; then STRENGTH="${GREEN}STRONG${NC}"
    elif [[ "$ENTROPY" -ge 60  ]]; then STRENGTH="${YELLOW}ADEQUATE${NC}"
    else                                STRENGTH="${RED}WEAK — increase length${NC}"
    fi

    echo -e "  ${DIM}Entropy:${NC} ~${ENTROPY} bits  |  ${DIM}Strength:${NC} $(echo -e $STRENGTH)\n"
    echo -e "  ${DIM}Store in a password manager. Never reuse keys.${NC}\n"
fi
