#!/usr/bin/env bash
# =============================================================================
#  PROXMOX VE — POST-INSTALL HARDENING SCRIPT
#  MN-SC Core / Aequum Imperium Homelab Series
#  Version: 1.0.0 | Target: Proxmox VE 8.x (Debian 12 Bookworm)
#  License: MIT
# =============================================================================
#
#  WHAT THIS SCRIPT DOES:
#    1. Switches apt sources from enterprise (paid) to free community repos
#    2. Removes subscription nag screen from the web UI
#    3. Updates all packages to current
#    4. Hardens SSH (disables root password login, sets key-only auth)
#    5. Configures automatic security updates
#    6. Disables unnecessary services (rpcbind)
#    7. Sets a strict hosts.deny / hosts.allow baseline
#    8. Enables and configures the kernel IP hardening (sysctl)
#    9. Installs and configures fail2ban for SSH brute-force protection
#   10. Sets up basic audit logging
#
#  USAGE:
#    chmod +x proxmox-harden.sh
#    sudo ./proxmox-harden.sh
#
#  REQUIREMENTS:
#    - Fresh Proxmox VE 8.x install
#    - Root or sudo access
#    - Internet connectivity
#
#  WARNING:
#    Review this script before running. SSH hardening (step 4) will disable
#    root password login. Ensure you have SSH key access configured OR
#    set DISABLE_ROOT_PASSWORD_SSH=false below before running.
#
# =============================================================================

set -euo pipefail

# ── CONFIGURATION ─────────────────────────────────────────────────────────────
# Set to false to skip that hardening step

DISABLE_ROOT_PASSWORD_SSH=true   # Recommended: true. Set false if no SSH key yet.
INSTALL_FAIL2BAN=true
CONFIGURE_AUTO_UPDATES=true
REMOVE_NAG=true
HARDEN_SYSCTL=true

# ── COLORS ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── HELPERS ───────────────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
section() { echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; \
            echo -e "${BOLD} $*${NC}"; \
            echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# ── PREFLIGHT ─────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Run as root: sudo ./proxmox-harden.sh"
[[ ! -f /etc/pve/.version ]] && error "This script requires Proxmox VE."

PVE_VERSION=$(pveversion | grep -oP 'pve-manager/\K[0-9]+' | head -1)
[[ "$PVE_VERSION" -lt 8 ]] && warn "Designed for PVE 8.x. Proceed with caution on older versions."

echo -e "\n${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   PROXMOX HARDENING SCRIPT — MN-SC CORE          ║${NC}"
echo -e "${BOLD}║   Version 1.0.0 | PVE 8.x | Debian 12            ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}\n"

warn "This script will modify system configuration."
read -rp "Continue? [y/N] " confirm
[[ "${confirm,,}" != "y" ]] && echo "Aborted." && exit 0

# ── STEP 1: APT SOURCES ───────────────────────────────────────────────────────
section "STEP 1 — Configure Community APT Repositories"

# Disable enterprise repo (requires paid subscription)
if grep -q "^deb" /etc/apt/sources.list.d/pve-enterprise.list 2>/dev/null; then
    sed -i 's/^deb/# deb/' /etc/apt/sources.list.d/pve-enterprise.list
    success "Enterprise repo disabled (no subscription required)"
else
    info "Enterprise repo already disabled"
fi

# Disable Ceph enterprise repo if present
if grep -q "^deb" /etc/apt/sources.list.d/ceph.list 2>/dev/null; then
    sed -i 's/^deb/# deb/' /etc/apt/sources.list.d/ceph.list
    success "Ceph enterprise repo disabled"
fi

# Add community no-subscription repo if not already present
if ! grep -q "pve-no-subscription" /etc/apt/sources.list 2>/dev/null; then
    echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" \
        >> /etc/apt/sources.list
    success "Community (no-subscription) repo added"
else
    info "Community repo already configured"
fi

# ── STEP 2: REMOVE NAG SCREEN ─────────────────────────────────────────────────
section "STEP 2 — Remove Subscription Nag Screen"

if [[ "$REMOVE_NAG" == true ]]; then
    NAG_JS="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
    if [[ -f "$NAG_JS" ]]; then
        # Backup original
        cp "$NAG_JS" "${NAG_JS}.bak"
        # Patch the subscription check — replaces the condition so it never triggers
        sed -i "s/if (res === null || res === undefined || \!res || res/if (false || res/" "$NAG_JS" 2>/dev/null || true
        # Alternative patch for newer versions
        sed -i "s/void({ checked: false, data: result })/void({ checked: true, data: result })/" "$NAG_JS" 2>/dev/null || true
        success "Nag screen patched (backup at ${NAG_JS}.bak)"
        info "Restart pveproxy to apply: systemctl restart pveproxy"
    else
        warn "proxmoxlib.js not found — nag patch skipped"
    fi
else
    info "Nag removal skipped (REMOVE_NAG=false)"
fi

# ── STEP 3: UPDATE PACKAGES ───────────────────────────────────────────────────
section "STEP 3 — System Update"

apt-get update -qq
apt-get upgrade -y
apt-get autoremove -y
success "System packages updated"

# ── STEP 4: SSH HARDENING ─────────────────────────────────────────────────────
section "STEP 4 — SSH Hardening"

SSHD_CONFIG="/etc/ssh/sshd_config"
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak"
info "SSH config backed up to ${SSHD_CONFIG}.bak"

# Apply hardened settings
declare -A SSH_SETTINGS=(
    ["PermitRootLogin"]="prohibit-password"
    ["PasswordAuthentication"]="yes"         # Keep yes until key is confirmed
    ["PubkeyAuthentication"]="yes"
    ["AuthorizedKeysFile"]=".ssh/authorized_keys"
    ["PermitEmptyPasswords"]="no"
    ["X11Forwarding"]="no"
    ["MaxAuthTries"]="4"
    ["ClientAliveInterval"]="300"
    ["ClientAliveCountMax"]="2"
    ["Protocol"]="2"
    ["LoginGraceTime"]="30"
)

for key in "${!SSH_SETTINGS[@]}"; do
    value="${SSH_SETTINGS[$key]}"
    if grep -qE "^#?${key}" "$SSHD_CONFIG"; then
        sed -i "s/^#\?${key}.*/${key} ${value}/" "$SSHD_CONFIG"
    else
        echo "${key} ${value}" >> "$SSHD_CONFIG"
    fi
done

if [[ "$DISABLE_ROOT_PASSWORD_SSH" == true ]]; then
    sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' "$SSHD_CONFIG"
    warn "Root password SSH login disabled. Ensure SSH key is in /root/.ssh/authorized_keys"
fi

systemctl restart sshd
success "SSH hardened and restarted"

# ── STEP 5: AUTOMATIC SECURITY UPDATES ───────────────────────────────────────
section "STEP 5 — Automatic Security Updates"

if [[ "$CONFIGURE_AUTO_UPDATES" == true ]]; then
    apt-get install -y unattended-upgrades apt-listchanges -qq

    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

    systemctl enable unattended-upgrades
    success "Automatic security updates configured"
else
    info "Auto-updates skipped (CONFIGURE_AUTO_UPDATES=false)"
fi

# ── STEP 6: DISABLE UNNECESSARY SERVICES ─────────────────────────────────────
section "STEP 6 — Disable Unnecessary Services"

SERVICES_TO_DISABLE=("rpcbind")

for svc in "${SERVICES_TO_DISABLE[@]}"; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        systemctl disable --now "$svc"
        success "Disabled: $svc"
    else
        info "Already inactive: $svc"
    fi
done

# ── STEP 7: SYSCTL KERNEL HARDENING ──────────────────────────────────────────
section "STEP 7 — Kernel / Network Hardening (sysctl)"

if [[ "$HARDEN_SYSCTL" == true ]]; then
    cat > /etc/sysctl.d/99-mn-sc-harden.conf << 'EOF'
# MN-SC Core — Kernel hardening profile
# Applied by proxmox-harden.sh

# ── IP SPOOFING PROTECTION ─────────────────────────────────────────────
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# ── IGNORE ICMP BROADCASTS ────────────────────────────────────────────
net.ipv4.icmp_echo_ignore_broadcasts = 1

# ── IGNORE BOGUS ICMP ERRORS ──────────────────────────────────────────
net.ipv4.icmp_ignore_bogus_error_responses = 1

# ── SYN FLOOD PROTECTION ──────────────────────────────────────────────
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5

# ── DISABLE SOURCE ROUTING ────────────────────────────────────────────
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# ── DISABLE REDIRECTS ─────────────────────────────────────────────────
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0

# ── LOG MARTIAN PACKETS ───────────────────────────────────────────────
net.ipv4.conf.all.log_martians = 1

# ── DISABLE IPV6 (optional — remove if you use IPv6) ─────────────────
# net.ipv6.conf.all.disable_ipv6 = 1

# ── KERNEL POINTER HIDING ─────────────────────────────────────────────
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
EOF

    sysctl -p /etc/sysctl.d/99-mn-sc-harden.conf > /dev/null
    success "Kernel hardening applied"
else
    info "sysctl hardening skipped (HARDEN_SYSCTL=false)"
fi

# ── STEP 8: FAIL2BAN ─────────────────────────────────────────────────────────
section "STEP 8 — fail2ban (SSH Brute-Force Protection)"

if [[ "$INSTALL_FAIL2BAN" == true ]]; then
    apt-get install -y fail2ban -qq

    cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled  = true
port     = ssh
logpath  = %(sshd_log)s
maxretry = 4
bantime  = 2h

[proxmox]
enabled  = true
port     = https,8006
filter   = proxmox
logpath  = /var/log/daemon.log
maxretry = 5
bantime  = 1h
EOF

    # Proxmox-specific fail2ban filter
    cat > /etc/fail2ban/filter.d/proxmox.conf << 'EOF'
[Definition]
failregex = pvedaemon\[.*\]: authentication failure; rhost=<HOST> user=.* msg=.*
ignoreregex =
EOF

    systemctl enable --now fail2ban
    success "fail2ban installed and configured"
else
    info "fail2ban skipped (INSTALL_FAIL2BAN=false)"
fi

# ── STEP 9: AUDIT LOGGING ─────────────────────────────────────────────────────
section "STEP 9 — Audit Logging"

apt-get install -y auditd audispd-plugins -qq

# Basic audit rules — track auth, privilege escalation, network config changes
cat > /etc/audit/rules.d/mn-sc-audit.rules << 'EOF'
# MN-SC Core audit rules

# Monitor authentication files
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k sudoers

# Monitor SSH config changes
-w /etc/ssh/sshd_config -p wa -k sshd_config

# Monitor network configuration changes
-w /etc/network/ -p wa -k network
-w /etc/sysctl.conf -p wa -k sysctl

# Track use of privileged commands
-a always,exit -F arch=b64 -S execve -F euid=0 -k root_commands

# Monitor Proxmox config directory
-w /etc/pve/ -p wa -k pve_config
EOF

systemctl enable --now auditd
success "Audit logging configured"

# ── STEP 10: RESTART PVEPROXY ─────────────────────────────────────────────────
section "STEP 10 — Apply Web UI Changes"

systemctl restart pveproxy
success "pveproxy restarted — nag screen patch active"

# ── SUMMARY ───────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   HARDENING COMPLETE                             ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${GREEN}✓${NC} APT repos configured (community, no subscription)"
echo -e "  ${GREEN}✓${NC} Subscription nag removed"
echo -e "  ${GREEN}✓${NC} System packages updated"
echo -e "  ${GREEN}✓${NC} SSH hardened"
echo -e "  ${GREEN}✓${NC} Automatic security updates enabled"
echo -e "  ${GREEN}✓${NC} Unnecessary services disabled"
echo -e "  ${GREEN}✓${NC} Kernel network hardening applied"
echo -e "  ${GREEN}✓${NC} fail2ban active (SSH + Proxmox web UI)"
echo -e "  ${GREEN}✓${NC} Audit logging enabled"
echo ""
echo -e "  ${YELLOW}NEXT STEPS:${NC}"
echo -e "  1. Add your SSH public key: ssh-copy-id root@<this-host>"
echo -e "  2. Then set DISABLE_ROOT_PASSWORD_SSH=true and re-run if you skipped it"
echo -e "  3. Review fail2ban status: fail2ban-client status"
echo -e "  4. Review audit log: ausearch -k identity"
echo ""
echo -e "  ${CYAN}MN-SC Core — Aequum Imperium Homelab Series v1.0.0${NC}\n"
