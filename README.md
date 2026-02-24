# MN-SC Core — Homelab Security Bundle
### Aequum Imperium Homelab Series | Version 1.0.0 | Minneapolis, MN

---

```
  █████╗ ███████╗ ██████╗ ██╗   ██╗██╗   ██╗███╗   ███╗
 ██╔══██╗██╔════╝██╔═══██╗██║   ██║██║   ██║████╗ ████║
 ███████║█████╗  ██║   ██║██║   ██║██║   ██║██╔████╔██║
 ██╔══██║██╔══╝  ██║▄▄ ██║██║   ██║██║   ██║██║╚██╔╝██║
 ██║  ██║███████╗╚██████╔╝╚██████╔╝╚██████╔╝██║ ╚═╝ ██║
 ╚═╝  ╚═╝╚══════╝ ╚══▀▀═╝  ╚═════╝  ╚═════╝ ╚═╝     ╚═╝
 IMPERIUM  //  MN-SC CORE  //  HOMELAB SECURITY BUNDLE
```

---

## What's In The Bundle

| Script | Version | Purpose |
|--------|---------|---------|
| `proxmox-harden.sh` | 2.0.0 | Post-install security hardening for Proxmox VE 8.x |
| `gen_key.sh` | 2.0.0 | Cryptographically secure password/key generator |
| `pulse.sh` | 2.0.0 | Live system health monitor with ASCII dashboard |
| `redact_check.sh` | 2.0.0 | Pre-transmission redaction compliance scanner |

---

## Who This Is For

You're running a self-hosted homelab. Maybe Proxmox, maybe a bare-metal
Linux box. You care about doing it properly — secure defaults, good
operational habits, no corporate dependency. These scripts were built
for exactly that environment.

Tested on Proxmox VE 8.x / Debian 12 Bookworm. Compatible with any
modern Debian/Ubuntu-based system.

---

## The Scripts

---

### 1. `proxmox-harden.sh` — Proxmox Post-Install Hardening

Takes a fresh Proxmox VE 8 install from default to hardened in under
5 minutes. Run it once right after install.

**What it hardens:**
- Switches to free community APT repos (removes paid subscription requirement)
- Removes the subscription nag screen from the web UI
- Updates all system packages
- Hardens SSH (disables root password login, enforces key auth)
- Enables automatic security updates
- Disables unnecessary services (rpcbind)
- Applies kernel network hardening via sysctl
- Installs and configures fail2ban for SSH + web UI brute-force protection
- Enables audit logging (auditd)
- Restarts pveproxy to apply all changes

**Usage:**
```bash
chmod +x proxmox-harden.sh
sudo ./proxmox-harden.sh
```

**Configuration flags** (edit at top of script before running):
```bash
DISABLE_ROOT_PASSWORD_SSH=true   # Set false if SSH keys not yet configured
INSTALL_FAIL2BAN=true
CONFIGURE_AUTO_UPDATES=true
REMOVE_NAG=true
HARDEN_SYSCTL=true
```

> **Note:** Set `DISABLE_ROOT_PASSWORD_SSH=false` if you haven't added
> your SSH public key yet. Add your key first, confirm it works, then
> re-run with it set to `true`.

---

### 2. `gen_key.sh` — Passkey Generator

Generates cryptographically secure passwords using `/dev/urandom`.
Includes entropy scoring so you know exactly how strong each key is.

**Usage:**
```bash
chmod +x gen_key.sh

./gen_key.sh                 # 24-char full character key
./gen_key.sh -l 32           # 32-char key
./gen_key.sh -l 16 -a        # 16-char alphanumeric only (safe for configs)
./gen_key.sh -l 48 -c        # Generate and copy to clipboard
./gen_key.sh -n 5            # Generate 5 keys at once
./gen_key.sh -l 20 -q        # Quiet mode — password only (pipe-friendly)
```

**Options:**
```
-l <length>   Length (default: 24, min: 8, max: 128)
-a            Alphanumeric only — A-Za-z0-9
-c            Copy to clipboard (requires xclip)
-n <count>    Generate multiple keys (max: 20)
-q            Quiet mode for use in scripts
```

**Pipe-friendly:**
```bash
# Use generated key directly in a script
NEW_PASS=$(./gen_key.sh -l 32 -a -q)
echo "Generated: $NEW_PASS"
```

---

### 3. `pulse.sh` — System Health Monitor

Real-time system dashboard with color-coded progress bars. Shows CPU,
memory, swap, disk, network, and Proxmox VM/CT counts if running on PVE.
Green / yellow / red thresholds at 70% and 90%.

**Usage:**
```bash
chmod +x pulse.sh

./pulse.sh              # Single snapshot
./pulse.sh -w           # Watch mode — live refresh every 5s
./pulse.sh -w -i 10    # Watch mode — refresh every 10s
./pulse.sh -q           # Quiet output (no ASCII banner)
```

**What it shows:**
- Hostname and local IP
- Current time and uptime
- CPU usage % with load averages (1m / 5m / 15m)
- CPU temperature (if sensors or thermal zone available)
- RAM and swap usage with visual bars
- Disk usage for root and any additional mount points
- Active network interfaces
- Running process count
- Proxmox VM and CT counts (auto-detected if running on PVE)

---

### 4. `redact_check.sh` — Redaction Compliance Scanner

Scans files and directories for T1/T2 sensitive data patterns before
you share documentation externally. Based on the MN-SC Core Redaction
Protocol. The scanner redacts actual credential values in its own
output — it won't re-expose what it finds.

**Data tiers:**
- **T1 SECRET** — passwords, API keys, tokens, master keys, SSH private keys
- **T2 RESTRICTED** — private IP ranges, MAC addresses, subnets, firmware versions

**Usage:**
```bash
chmod +x redact_check.sh

./redact_check.sh myfile.txt             # Scan a single file
./redact_check.sh ./docs                 # Scan a directory
./redact_check.sh -r ./docs             # Recursive scan
./redact_check.sh -s myfile.txt         # Strict mode (exit 1 on T1 hit)
./redact_check.sh -o report.txt myfile.txt  # Save report to file
./redact_check.sh -q myfile.txt         # Summary only
```

**CI/CD integration** — strict mode returns exit code 1 on T1 detection,
making it easy to gate on in a pipeline:
```bash
./redact_check.sh -s ./outbox && echo "Clear to send" || echo "BLOCKED"
```

---

## Recommended Workflow

```
1. Fresh Proxmox install
       ↓
2. Run proxmox-harden.sh
       ↓
3. Use gen_key.sh to generate strong credentials for all services
       ↓
4. Use pulse.sh to monitor node health
       ↓
5. Before sharing any spec or doc externally:
   Run redact_check.sh — clear to transmit only on green
```

---

## Requirements

- Debian 12 (Bookworm) or Ubuntu 22.04+
- Bash 5.x
- Root or sudo for `proxmox-harden.sh`
- `xclip` for clipboard feature in `gen_key.sh` (optional)
- `lm-sensors` for CPU temp in `pulse.sh` (optional)

All scripts are self-contained. No external dependencies beyond standard
GNU coreutils and Bash.

---

## Support & Feedback

Found a bug or want a feature? Reach out via Ko-fi or open an issue on
GitHub. If these scripts saved you time, consider sharing the bundle
with your homelab community.

---

## License

MIT License — free to use, modify, and distribute. Attribution appreciated.

---

*MN-SC Core — Minneapolis, MN | #MN #SiempreFuerte*
*Aequum Imperium Homelab Series | Bundle v1.0.0*
