#!/usr/bin/env bash
# =============================================================================
#  AEQUUM IMPERIUM — REDACTION COMPLIANCE SCANNER
#  MN-SC Core | Minneapolis, MN | Homelab Series
#  Version: 2.0.0
#  License: MIT
# =============================================================================
#
#  WHAT THIS SCRIPT DOES:
#    Scans files or directories for T1/T2 data exposure patterns before
#    sharing documentation externally. Based on the MN-SC Core Redaction
#    Protocol (Ref: MN-2026-REDACT-01).
#
#    T1 — SECRET:     Passwords, keys, tokens, credentials
#    T2 — RESTRICTED: IP addresses, subnets, MAC addresses, firmware versions
#
#  USAGE:
#    ./redact_check.sh <file>           # Scan a single file
#    ./redact_check.sh <directory>      # Scan all files in a directory
#    ./redact_check.sh -r <directory>   # Recursive directory scan
#    ./redact_check.sh -s <file>        # Strict mode (T1 only, exit 1 on hit)
#    ./redact_check.sh -o <report.txt>  # Save report to file
#    ./redact_check.sh -q <file>        # Quiet — summary only
#
# =============================================================================

set -euo pipefail

# ── DEFAULTS ──────────────────────────────────────────────────────────────────
RECURSIVE=false
STRICT=false
QUIET=false
OUTPUT_FILE=""
TARGET=""

# ── COLORS ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── COUNTERS ──────────────────────────────────────────────────────────────────
T1_HITS=0
T2_HITS=0
FILES_SCANNED=0
FILES_CLEAN=0
FILES_FLAGGED=0

# ── ARGS ──────────────────────────────────────────────────────────────────────
usage() {
    echo -e "\n${BOLD}AEQUUM IMPERIUM — Redaction Scanner v2.0.0${NC}"
    echo -e "${DIM}MN-SC Core | Minneapolis, MN${NC}\n"
    echo "Usage: $0 [OPTIONS] <target>"
    echo ""
    echo "Options:"
    echo "  -r             Recursive directory scan"
    echo "  -s             Strict mode — exit code 1 if any T1 found"
    echo "  -o <file>      Save full report to file"
    echo "  -q             Quiet — summary line only"
    echo "  -h             Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 specs.txt"
    echo "  $0 -r ./docs"
    echo "  $0 -s -o report.txt ./outbox"
    echo ""
    exit 0
}

while getopts ":rso:qh" opt; do
    case $opt in
        r) RECURSIVE=true ;;
        s) STRICT=true ;;
        o) OUTPUT_FILE="$OPTARG" ;;
        q) QUIET=true ;;
        h) usage ;;
        :) echo "Option -$OPTARG requires an argument." >&2; exit 1 ;;
        \?) echo "Unknown option: -$OPTARG. Use -h for help." >&2; exit 1 ;;
    esac
done

shift $((OPTIND - 1))
TARGET="${1:-}"

[[ -z "$TARGET" ]] && echo -e "${RED}[ERROR]${NC} No target specified. Usage: $0 [OPTIONS] <target>" && exit 1
[[ ! -e "$TARGET" ]] && echo -e "${RED}[ERROR]${NC} Target not found: $TARGET" && exit 1

# ── PATTERN DEFINITIONS ───────────────────────────────────────────────────────
# T1 — SECRET patterns
declare -A T1_PATTERNS=(
    ["PASSWORD"]='(?i)(password|passwd|pass)\s*[:=]\s*\S+'
    ["API_KEY"]='(?i)(api[_-]?key|apikey)\s*[:=]\s*\S+'
    ["SECRET"]='(?i)(secret|secret[_-]?key)\s*[:=]\s*\S+'
    ["TOKEN"]='(?i)(token|auth[_-]?token|access[_-]?token)\s*[:=]\s*\S+'
    ["PRIVATE_KEY"]='(?i)(private[_-]?key|priv[_-]?key)\s*[:=]\s*\S+'
    ["MASTER_KEY"]='(?i)(master[_-]?key|masterkey)\s*[:=]\s*\S+'
    ["CREDENTIAL"]='(?i)(credential|cred)\s*[:=]\s*\S+'
    ["SSH_KEY"]='-----BEGIN (RSA|EC|DSA|OPENSSH) PRIVATE KEY-----'
)

# T2 — RESTRICTED patterns
declare -A T2_PATTERNS=(
    ["IPV4_PRIVATE_10"]='10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'
    ["IPV4_PRIVATE_172"]='172\.(1[6-9]|2[0-9]|3[0-1])\.[0-9]{1,3}\.[0-9]{1,3}'
    ["IPV4_PRIVATE_192"]='192\.168\.[0-9]{1,3}\.[0-9]{1,3}'
    ["MAC_ADDRESS"]='([0-9A-Fa-f]{2}[:\-]){5}[0-9A-Fa-f]{2}'
    ["SUBNET_CIDR"]='[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}'
    ["FIRMWARE_VER"]='(?i)firmware\s*[:=v]\s*[0-9]+\.[0-9]+'
)

# ── OUTPUT BUFFER (for optional file report) ──────────────────────────────────
REPORT_BUFFER=""
report() {
    local line="$*"
    if [[ -n "$OUTPUT_FILE" ]]; then
        REPORT_BUFFER+="${line}"$'\n'
    fi
    echo -e "$line"
}

# ── SCAN A SINGLE FILE ────────────────────────────────────────────────────────
scan_file() {
    local file="$1"
    local file_t1=0
    local file_t2=0
    local file_hits=""

    # Skip binary files
    if file "$file" | grep -qE 'binary|ELF|executable'; then
        [[ "$QUIET" == false ]] && echo -e "  ${DIM}SKIP${NC}  ${DIM}$file (binary)${NC}"
        return
    fi

    (( FILES_SCANNED++ )) || true

    # Scan T1 patterns
    for label in "${!T1_PATTERNS[@]}"; do
        pattern="${T1_PATTERNS[$label]}"
        if grep -qP "$pattern" "$file" 2>/dev/null; then
            matches=$(grep -nP "$pattern" "$file" 2>/dev/null || true)
            while IFS= read -r match; do
                line_num=$(echo "$match" | cut -d: -f1)
                line_content=$(echo "$match" | cut -d: -f2-)
                # Redact the actual value in output for safety
                safe_content=$(echo "$line_content" | sed -E 's/([:=]\s*)\S+/\1[VALUE-REDACTED]/g')
                file_hits+="    ${RED}[T1-${label}]${NC} line ${line_num}: ${safe_content}\n"
                (( file_t1++ )) || true
                (( T1_HITS++ )) || true
            done <<< "$matches"
        fi
    done

    # Scan T2 patterns
    for label in "${!T2_PATTERNS[@]}"; do
        pattern="${T2_PATTERNS[$label]}"
        if grep -qP "$pattern" "$file" 2>/dev/null; then
            matches=$(grep -nP "$pattern" "$file" 2>/dev/null || true)
            while IFS= read -r match; do
                line_num=$(echo "$match" | cut -d: -f1)
                line_content=$(echo "$match" | cut -d: -f2-)
                file_hits+="    ${ORANGE}[T2-${label}]${NC} line ${line_num}: ${line_content}\n"
                (( file_t2++ )) || true
                (( T2_HITS++ )) || true
            done <<< "$matches"
        fi
    done

    # Output per-file result
    if [[ $file_t1 -gt 0 || $file_t2 -gt 0 ]]; then
        (( FILES_FLAGGED++ )) || true
        if [[ "$QUIET" == false ]]; then
            report ""
            if [[ $file_t1 -gt 0 ]]; then
                report "  ${RED}${BOLD}[FLAGGED]${NC}  $file"
            else
                report "  ${ORANGE}${BOLD}[CAUTION]${NC}  $file"
            fi
            report "  ${DIM}T1 hits: ${file_t1}  |  T2 hits: ${file_t2}${NC}"
            echo -e "$file_hits"
        fi
    else
        (( FILES_CLEAN++ )) || true
        [[ "$QUIET" == false ]] && report "  ${GREEN}[CLEAN]${NC}    $file"
    fi
}

# ── BUILD FILE LIST ───────────────────────────────────────────────────────────
declare -a FILE_LIST=()

if [[ -f "$TARGET" ]]; then
    FILE_LIST=("$TARGET")
elif [[ -d "$TARGET" ]]; then
    if [[ "$RECURSIVE" == true ]]; then
        while IFS= read -r -d '' f; do
            FILE_LIST+=("$f")
        done < <(find "$TARGET" -type f -print0)
    else
        while IFS= read -r -d '' f; do
            FILE_LIST+=("$f")
        done < <(find "$TARGET" -maxdepth 1 -type f -print0)
    fi
fi

[[ ${#FILE_LIST[@]} -eq 0 ]] && echo -e "${RED}[ERROR]${NC} No scannable files found in: $TARGET" && exit 1

# ── HEADER ────────────────────────────────────────────────────────────────────
if [[ "$QUIET" == false ]]; then
    echo -e "${RED}${BOLD}"
    echo '  ██████╗ ███████╗██████╗  █████╗  ██████╗████████╗'
    echo '  ██╔══██╗██╔════╝██╔══██╗██╔══██╗██╔════╝╚══██╔══╝'
    echo '  ██████╔╝█████╗  ██║  ██║███████║██║        ██║   '
    echo '  ██╔══██╗██╔══╝  ██║  ██║██╔══██║██║        ██║   '
    echo '  ██║  ██║███████╗██████╔╝██║  ██║╚██████╗   ██║   '
    echo '  ╚═╝  ╚═╝╚══════╝╚═════╝ ╚═╝  ╚═╝ ╚═════╝   ╚═╝  '
    echo -e "${NC}"
    echo -e "  ${DIM}REDACTION COMPLIANCE SCANNER  //  MN-SC Core  //  Minneapolis, MN${NC}"
    echo -e "  ${DIM}Protocol Ref: MN-2026-REDACT-01  //  v2.0.0${NC}"
    echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}TARGET${NC}    $TARGET"
    echo -e "  ${BOLD}MODE${NC}      $( [[ "$RECURSIVE" == true ]] && echo "Recursive" || echo "Single-level" )$( [[ "$STRICT" == true ]] && echo "  |  STRICT" || echo "" )"
    echo -e "  ${BOLD}FILES${NC}     ${#FILE_LIST[@]} queued for scan"
    echo ""
    echo -e "  ${DIM}T1 SECRET patterns:    ${#T1_PATTERNS[@]} rules${NC}"
    echo -e "  ${DIM}T2 RESTRICTED patterns: ${#T2_PATTERNS[@]} rules${NC}"
    echo ""
    echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
fi

# ── RUN SCAN ──────────────────────────────────────────────────────────────────
for f in "${FILE_LIST[@]}"; do
    scan_file "$f"
done

# ── SUMMARY ───────────────────────────────────────────────────────────────────
echo ""
echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${BOLD}SCAN COMPLETE${NC}  //  $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
echo -e "  Files scanned   ${CYAN}${FILES_SCANNED}${NC}"
echo -e "  Clean           ${GREEN}${FILES_CLEAN}${NC}"
echo -e "  Flagged         $( [[ $FILES_FLAGGED -gt 0 ]] && echo "${RED}${FILES_FLAGGED}${NC}" || echo "${GREEN}0${NC}" )"
echo ""
echo -e "  T1 (SECRET) hits      $( [[ $T1_HITS -gt 0 ]] && echo "${RED}${BOLD}${T1_HITS} — DO NOT SHARE${NC}" || echo "${GREEN}0${NC}" )"
echo -e "  T2 (RESTRICTED) hits  $( [[ $T2_HITS -gt 0 ]] && echo "${ORANGE}${T2_HITS} — review before sharing${NC}" || echo "${GREEN}0${NC}" )"
echo ""

if [[ $T1_HITS -gt 0 ]]; then
    echo -e "  ${RED}${BOLD}⚠  T1 EXPOSURE DETECTED — REDACT BEFORE TRANSMITTING${NC}"
    echo -e "  ${DIM}Replace T1 values with [REDACTED-T1] token${NC}"
elif [[ $T2_HITS -gt 0 ]]; then
    echo -e "  ${ORANGE}${BOLD}⚠  T2 DATA PRESENT — REVIEW BEFORE SHARING EXTERNALLY${NC}"
    echo -e "  ${DIM}Replace with descriptive placeholders e.g. [DEVICE-IP]${NC}"
else
    echo -e "  ${GREEN}${BOLD}✓  NO SENSITIVE PATTERNS DETECTED — CLEAR TO TRANSMIT${NC}"
fi

echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ── SAVE REPORT ───────────────────────────────────────────────────────────────
if [[ -n "$OUTPUT_FILE" && -n "$REPORT_BUFFER" ]]; then
    echo "$REPORT_BUFFER" > "$OUTPUT_FILE"
    echo -e "  ${DIM}Report saved to: $OUTPUT_FILE${NC}\n"
fi

# ── EXIT CODE ─────────────────────────────────────────────────────────────────
if [[ "$STRICT" == true && $T1_HITS -gt 0 ]]; then
    exit 1
fi

exit 0
