# Proxmox Post-Installation Toolkit

[![License](https://img.shields.io/badge/license-Apache%202.0-green.svg)](LICENSE)
[![Proxmox](https://img.shields.io/badge/Proxmox-9.x-orange.svg)](https://www.proxmox.com/)

Idempotent scripts for Proxmox VE post-installation configuration. Brought to you by the hoopy froods at HyperSec.

---

## What's in the Box

- **System Optimisation** - Kernel tuning, nested virtualisation, IOMMU/VFIO passthrough, SSD TRIM
- **Network Tuning** - Tier-based TCP/UDP buffers (1/10/25/40/100/200 GbE), BBR congestion control, NIC offloading
- **Power Management** - CPU governors, PCIe ASPM, thermal monitoring, power profiles
- **ZFS Tuning** - RAM-aware ARC sizing, autotrim, dataset settings
- **Repository Config** - No-subscription repos, enterprise repo disable
- **Conservative Updates** - N-1 minor version pinning, UI customisation, APT persistence hooks
- **Internal NAT** - Host-side VM networking with any IPv4 CIDR
- **Remote Access** - AWS SSM and NetBird agents for emergency console access

---

## Quick Start

```bash
# Download and extract
wget https://github.com/hypersec-io/proxmox/archive/refs/heads/main.zip
unzip main.zip && cd proxmox-main/postinstall
chmod +x *.sh *.py

# Run in order
sudo ./proxmox-repo.sh              # Configure repositories
sudo ./proxmox-optimize.sh          # Core system optimisation
sudo ./proxmox-zfs.sh               # ZFS tuning (if applicable)
sudo ./proxmox-power-management.sh  # Power management (optional)
sudo ./proxmox-network.sh 10gbe     # Network tuning (optional)
sudo ./proxmox-update-policy.sh enable  # Conservative updates (optional)
```

After running, update GRUB and reboot if prompted:

```bash
sudo update-grub && sudo reboot
```

---

## Scripts

### proxmox-repo.sh

Configures Proxmox VE repositories for community (no-subscription) use.

**What it does:**

- Creates no-subscription repository configuration
- Disables enterprise repositories
- Updates package lists

**Note:** UI customisations (warning suppression) are handled by `proxmox-update-policy.sh`.

| Property | Value |
|----------|-------|
| Idempotent | Yes |
| Reboot | No |
| Backup | None (safe operations) |

---

### proxmox-update-policy.sh

Conservative update policy with n-1 minor version pinning. Keeps you one minor version behind bleeding edge while allowing patch updates.

**What it does:**

- Pins Proxmox packages to one minor version behind latest
- Applies UI patches to replace "not recommended for production" warnings
- Creates APT hook for persistence across package updates
- Supports daily cron job for automatic policy refresh
- Never downgrades below installed version

**Policy behaviour:**

- **MAJOR:** Same as latest available
- **MINOR:** max(installed, n-1) - never downgrades
- **PATCH:** Latest within target minor

**Example:** If repo has 9.2.3, policy pins to 9.1.* (gets 9.1.x patches, skips 9.2.x)

**Commands:**

```bash
sudo ./proxmox-update-policy.sh enable       # Enable with UI patches
sudo ./proxmox-update-policy.sh enable --no-ui  # Enable without UI patches
sudo ./proxmox-update-policy.sh disable      # Disable and restore UI
sudo ./proxmox-update-policy.sh status       # Show policy and versions
sudo ./proxmox-update-policy.sh update       # Refresh pinning
sudo ./proxmox-update-policy.sh cron-enable  # Install daily cron
sudo ./proxmox-update-policy.sh cron-disable # Remove cron
```

**UI customisations:**

When enabled, modifies the Proxmox web interface:

- Replaces "not recommended for production" with "Conservative update policy active"
- Changes warning icons to green success indicators
- Persists across package updates via APT hook

**Compatibility:** Tested on PVE 9.x only. PVE 8.x may work.

| Property | Value |
|----------|-------|
| Idempotent | Yes |
| Reboot | No |
| Backup | `/root/backup/proxmox-config/` |

---

### proxmox-optimize.sh

Core system configuration for Proxmox VE hosts.

**What it does:**

- Backs up current settings
- Installs monitoring tools (htop, iotop, smartmontools)
- Configures kernel parameters (sysctl)
- Enables nested virtualisation (Intel VT-x / AMD-V)
- Configures IOMMU for device passthrough
- Enables SSD TRIM
- Creates management scripts

**Kernel parameters applied:**

```text
vm.swappiness=10
vm.vfs_cache_pressure=50
net.core.netdev_max_backlog=8192
net.ipv4.tcp_fin_timeout=30
fs.file-max=2097152
net.bridge.bridge-nf-call-iptables=1
```

**Created commands:** `proxmox-status`

| Property | Value |
|----------|-------|
| Idempotent | Yes |
| Reboot | Yes (for IOMMU/nested virt) |
| Backup | `/root/backup/proxmox-config/` |

---

### proxmox-network.sh

Network configuration based on interface speed tier.

**Usage:**

```bash
sudo ./proxmox-network.sh 1gbe     # 1 Gigabit (conservative)
sudo ./proxmox-network.sh 10gbe    # 10 Gigabit (recommended)
sudo ./proxmox-network.sh 25gbe    # 25 Gigabit
sudo ./proxmox-network.sh 40gbe    # 40 Gigabit
sudo ./proxmox-network.sh 100gbe   # 100 Gigabit
sudo ./proxmox-network.sh 200gbe   # 200 Gigabit
```

**What it does:**

- Detects or accepts network speed tier
- Configures TCP/UDP buffer sizes
- Configures queue depths and backlogs
- Enables BBR congestion control for 10GbE+
- Configures NIC ring buffers and hardware offloading
- Supports jumbo frames (--jumbo flag)

**Tier optimisations:**

| Tier | TCP Buffer Max | Backlog | Congestion | Ring Buffer |
|------|---------------|---------|------------|-------------|
| 1 GbE | 8 MB | 5K | CUBIC | 512 |
| 10 GbE | 32 MB | 30K | BBR | 2048 |
| 25 GbE | 64 MB | 50K | BBR | 4096 |
| 40 GbE | 128 MB | 100K | BBR | 8192 |
| 100 GbE | 256 MB | 250K | BBR | 8192 |
| 200 GbE | 512 MB | 500K | BBR | 8192 |

**Created commands:** `network-status`, `network-test`

| Property | Value |
|----------|-------|
| Idempotent | Yes |
| Reboot | No |
| Backup | `/root/backup/proxmox-config/` |

---

### proxmox-power-management.sh

Power management and thermal control.

**What it does:**

- Configures CPU frequency governor (schedutil)
- Applies vendor-specific settings (Intel/AMD)
- Enables PCIe ASPM (powersave mode)
- Configures SATA link power management
- Enables network power management (WoL, EEE)
- Configures USB selective suspend
- Enables PCI runtime power management
- Updates kernel boot parameters

**Kernel parameters (Intel):**

```text
intel_idle.max_cstate=6
intel_pstate=passive
pcie_aspm=powersave
```

**Kernel parameters (AMD):**

```text
processor.max_cstate=6
amd_pstate=passive
pcie_aspm=powersave
```

**Created commands:** `power-status`, `thermal-check`, `performance-mode`, `balanced-mode`, `powersave-mode`

**Systemd service:** `proxmox-power.service` (auto-applies on boot)

| Property | Value |
|----------|-------|
| Idempotent | Yes |
| Reboot | Yes (for kernel parameters) |
| Backup | `/root/backup/proxmox-config/` |

---

### proxmox-zfs.sh

Safe ZFS optimisation for Proxmox storage.

**What it does:**

- Calculates ARC size based on total RAM
- Applies runtime ARC limits
- Creates persistent ZFS module configuration
- Enables autotrim on all pools
- Optimises VM storage datasets (atime, xattr)
- Generates status and tuning scripts

**ARC sizing:**

| Total RAM | ARC Min | ARC Max | VM Reserve |
|-----------|---------|---------|------------|
| 16 GB | 1 GB | 2 GB | 14+ GB |
| 32 GB | 1 GB | 3 GB | 29+ GB |
| 64 GB | 2 GB | 4 GB | 60+ GB |
| 128 GB | 2 GB | 6 GB | 122+ GB |
| 256+ GB | 3 GB | 8 GB | 248+ GB |

**Safety settings preserved:** `sync=standard`, `compression` (Proxmox-managed), `primarycache=all`

**Created commands:** `zfs-status`, `zfs-tune-guide`

| Property | Value |
|----------|-------|
| Idempotent | Yes |
| Reboot | Recommended |
| Backup | None (safe operations) |

---

### proxmox-internal-nat.sh

Host-side internal VM network with NAT outbound.

**Usage:**

```bash
sudo ./proxmox-internal-nat.sh apply --lan-cidr 10.42.0.0/16
sudo ./proxmox-internal-nat.sh remove
sudo ./proxmox-internal-nat.sh status --lan-cidr 10.42.0.0/16
sudo ./proxmox-internal-nat.sh health --lan-cidr 10.42.0.0/16
```

**Commands:**

- `apply` - Create internal bridge, enable forwarding, add NAT rules
- `remove` - Remove all configuration and rules
- `status` - Show CONFIG intent vs LIVE runtime state
- `health` - Deeper dataplane checks (routes + nft rules/counters)

**Options:**

- `--lan-cidr <CIDR>` - Network CIDR (required for apply/status/health)
- `--lan-gw <IP>` - Gateway IP (default: first usable host)
- `--wan-bridge <name>` - WAN bridge name (default: vmbr0)
- `--lan-bridge <name>` - LAN bridge name (default: vmbr1)
- `--reload` - Reload networking after changes

**Safety:**

- Does NOT reload networking unless `--reload` is passed
- Uses isolated nftables tables (won't conflict with pve-firewall)
- All files backed up before modification

| Property | Value |
|----------|-------|
| Idempotent | Yes |
| Reboot | No |
| Backup | Inline (marked sections) |

---

### proxmox-ssm.py

AWS Systems Manager agent for emergency console access via AWS SSM Session Manager.

**Usage:**

```bash
# Install with auto-created IAM role and activation
sudo ./proxmox-ssm.py install --region ap-southeast-2

# Install with existing activation
sudo ./proxmox-ssm.py install --activation-code XXXX --activation-id YYYY --region ap-southeast-2

# Check status
sudo ./proxmox-ssm.py status

# Uninstall
sudo ./proxmox-ssm.py uninstall
```

**What it does:**

- Installs AWS SSM agent from official .deb package
- Creates IAM role with SSM trust policy (if not exists)
- Creates hybrid activation for on-premises registration
- Registers host as AWS managed instance
- Enables Session Manager access via AWS console/CLI

**Region auto-detection (in order):**

1. `--region` flag
2. `AWS_REGION` environment variable
3. `AWS_DEFAULT_REGION` environment variable
4. `aws configure get region`
5. Error if none found

**Requirements:**

- AWS CLI installed with appropriate IAM permissions
- Internet connectivity to AWS SSM endpoints
- For Session Manager: Advanced-instances tier enabled

**Connect after install:**

```bash
aws ssm start-session --target mi-XXXXXXXXX --region ap-southeast-2
```

| Property | Value |
|----------|-------|
| Idempotent | Yes |
| Reboot | No |
| Backup | `/root/backup/proxmox-config/` |

---

### proxmox-netbird.py

NetBird WireGuard mesh agent for emergency access. BSD-3-Clause licensed open source.

**Usage:**

```bash
# Install and connect to NetBird cloud
sudo ./proxmox-netbird.py install --setup-key nb-setup-XXXXXXXX

# Install and connect to self-hosted control plane
sudo ./proxmox-netbird.py install --setup-key XXXX --management-url https://netbird.example.com:443

# Check status
sudo ./proxmox-netbird.py status

# Uninstall
sudo ./proxmox-netbird.py uninstall
```

**What it does:**

- Adds NetBird APT repository
- Installs netbird package
- Connects to management server with setup key
- Creates WireGuard tunnel (wt0 interface)

**Getting a setup key:**

1. Go to <https://app.netbird.io> (or your self-hosted console)
2. Navigate to Setup Keys
3. Create a new key (reusable or one-time)
4. Use with `--setup-key`

**Supports:**

- NetBird cloud (api.netbird.io) - default
- Self-hosted control plane (`--management-url`)

| Property | Value |
|----------|-------|
| Idempotent | Yes |
| Reboot | No |
| Backup | `/root/backup/proxmox-config/` |

---

## Configuration Files

### Created/Modified

```text
/etc/sysctl.d/99-proxmox-optimize.conf       # Kernel parameters
/etc/modprobe.d/kvm-nested.conf              # Nested virtualisation
/etc/modprobe.d/zfs.conf                     # ZFS ARC limits
/etc/modules                                 # VFIO modules
/etc/default/grub                            # Boot parameters
/etc/default/cpufrequtils                    # CPU governor
/etc/systemd/system/proxmox-power.service    # Power service
/etc/apt/sources.list.d/debian.sources       # Proxmox repos
/etc/apt/preferences.d/proxmox-conservative  # Update policy pinning
/etc/apt/apt.conf.d/99proxmoxpolicy          # Update policy APT hook
/usr/local/bin/proxmox-policy-hook.sh        # Update policy hook script
/usr/share/pve-manager/js/conservative-policy.js  # UI policy flag
```

### Backup Locations

All backups are stored in `/root/backup/proxmox-config/` with timestamped filenames:

```text
/root/backup/proxmox-config/
  - sysctl-backup-YYYYMMDD_HHMMSS.conf      # System
  - grub.backup.YYYYMMDD_HHMMSS             # System
  - network-sysctl-YYYYMMDD_HHMMSS.conf     # Network
  - power-grub-YYYYMMDD_HHMMSS              # Power
  - power-cpufrequtils-YYYYMMDD_HHMMSS      # Power
  - proxmoxlib.js.original                  # Update policy
  - pvemanagerlib.js.original               # Update policy
  - index.html.tpl.original                 # Update policy
```

---

## Management Commands

After installation, these commands are available:

```bash
# System
proxmox-status              # Overall system status

# Network
network-status              # Network configuration
network-test                # Performance testing guide

# Power
power-status                # Power configuration
thermal-check               # CPU temperature check
performance-mode            # Switch to performance
balanced-mode               # Switch to balanced
powersave-mode              # Switch to powersave

# ZFS
zfs-status                  # ZFS status overview
zfs-tune-guide              # Tuning recommendations

# Update Policy
proxmox-update-policy.sh status   # Policy status
proxmox-update-policy.sh enable   # Enable policy
proxmox-update-policy.sh disable  # Disable policy
proxmox-update-policy.sh update   # Refresh pinning

# Remote Access
proxmox-ssm.py status             # SSM agent status
proxmox-netbird.py status         # NetBird status
```

---

## Safety

### Idempotent Design

All scripts are safe to run multiple times:

- Check current state before applying changes
- Skip already-configured settings
- Clear status messages (Already configured vs Newly configured)

### Data Safety

- No data loss risk - all optimisations preserve data integrity
- Automatic backups - system configs backed up before changes
- Conservative defaults - reliability over performance
- Proxmox-aware - respects Proxmox's management of VMs and storage

### Error Handling

- Error trapping (`set -e`, `trap`)
- Graceful degradation on non-critical failures
- Detailed error messages with line numbers

---

## CPU Support

### Intel

- Intel VT-x nested virtualisation
- Intel IOMMU (VT-d)
- Intel P-state driver
- Intel Turbo Boost control

### AMD

- AMD-V nested virtualisation
- AMD IOMMU (AMD-Vi)
- AMD P-state driver (EPP mode)
- AMD Core Performance Boost

---

## Compatibility

**Tested on:**

- Proxmox VE 9.x / Debian 13 (Trixie) only
- PVE 8.x may work but is untested
- Intel Xeon, Core i-series CPUs
- AMD EPYC, Ryzen CPUs

**Requirements:**

- x86_64 CPU with virtualisation extensions (Intel VT-x / AMD-V)
- IOMMU support (Intel VT-d / AMD-Vi) for device passthrough
- lm-sensors compatible CPU for thermal monitoring

---

## Troubleshooting

### Script Won't Run

```bash
sudo -i                    # Ensure root
chmod +x /path/to/script.sh
pveversion                 # Check Proxmox version
```

### IOMMU Not Enabled

```bash
grep GRUB_CMDLINE_LINUX_DEFAULT /etc/default/grub
update-grub && reboot
dmesg | grep -i iommu      # Verify after reboot
```

### Power Management Not Working

```bash
ls /sys/devices/system/cpu/cpu0/cpufreq/
modprobe acpi-cpufreq      # or amd-pstate / intel_pstate
systemctl status proxmox-power.service
```

### ZFS Script Fails

```bash
zpool list                 # Verify ZFS installed
whoami                     # Check root
lsmod | grep zfs           # Verify modules loaded
```

### Temperature Sensors Not Working

```bash
apt-get install lm-sensors
sensors-detect --auto
sensors
```

---

## Versioning

This project uses [Semantic Versioning](https://semver.org/):

- **MAJOR** - Incompatible changes
- **MINOR** - Backwards-compatible additions
- **PATCH** - Backwards-compatible fixes

See [CHANGELOG.md](CHANGELOG.md) for history.

---

## Contributing

Contributions welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

Quick checklist:

- Scripts remain idempotent
- Follow existing error handling patterns
- Test on Proxmox VE 9.x
- Update documentation
- Pass ShellCheck

---

## License

Apache License 2.0 - see [LICENSE](LICENSE).

```text
Copyright 2025 HyperSec

Licensed under the Apache License, Version 2.0
```

---

## Disclaimer

These scripts modify system configuration. While designed to be safe and idempotent:

- Test in non-production first
- Review code before running on production
- Ensure you have backups

**Use at your own risk.**

---

## Support

- Issues: [GitHub Issues](https://github.com/hypersec-io/proxmox/issues)
- Documentation: This README and inline script comments

---

## Acknowledgments

- Proxmox VE Team
- Debian Project
- Community contributors
