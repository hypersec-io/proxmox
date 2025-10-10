# Proxmox Post-Installation Toolkit

[![License](https://img.shields.io/badge/license-Apache%202.0-green.svg)](LICENSE)
[![Proxmox](https://img.shields.io/badge/Proxmox-9.x-orange.svg)](https://www.proxmox.com/)
[![Debian](https://img.shields.io/badge/Debian-13%20Trixie-red.svg)](https://www.debian.org/)

A collection of idempotent scripts for post-installation configuration of Proxmox VE 9 on Debian 13 (Trixie). Includes system configuration, network tuning, power management, and ZFS settings.

---

## Features

### Core System Configuration
- **Kernel Parameter Tuning** - sysctl settings for VM/container workloads
- **Nested Virtualization** - Intel VT-x/AMD-V support for nested VMs
- **IOMMU/VFIO Configuration** - GPU and device passthrough support
- **SSD TRIM** - Automatic TRIM scheduling
- **Monitoring Tools** - htop, iotop, smartmontools

### Network Configuration
- **GbE Tier-Based Tuning** - Configuration for 1/10/25/40/100/200 GbE networks
- **TCP Buffer Scaling** - Buffer sizes based on network speed
- **BBR Congestion Control** - Congestion algorithm for high-speed links
- **NIC Hardware Offloading** - TSO, GSO, GRO enablement
- **Ring Buffer Configuration** - RX/TX queue sizes
- **Jumbo Frame Support** - MTU 9000 support for high-speed networks

### Power Management
- **CPU Frequency Scaling** - schedutil/ondemand governors with balanced profiles
- **PCIe ASPM** - Active State Power Management for PCIe devices
- **Storage Power Management** - SATA link power optimization
- **USB/PCI Runtime PM** - Selective power management for peripherals
- **Thermal Monitoring** - Temperature monitoring
- **Power Profiles** - Performance, Balanced, and Powersave modes

### ZFS Configuration
- **ARC Memory Management** - RAM-aware caching limits
- **Autotrim** - Automatic SSD TRIM for ZFS pools
- **Dataset Settings** - atime and xattr tuning
- **Data Integrity** - Preserves safety settings (sync, cache)

### Repository Management
- **No-Subscription Repos** - Community repository configuration
- **Enterprise Repo Disable** - Automatic enterprise source disabling

---

## Quick Start

### Prerequisites
- Proxmox VE 9.x installed
- Debian 13 (Trixie) base
- Root access
- Internet connection for package installation

### Installation

```bash
# Download the scripts
git clone https://github.com/yourusername/proxmox-postinstall.git
cd proxmox-postinstall/postinstall

# Make scripts executable
chmod +x *.sh

# Run scripts in recommended order
sudo ./proxmox-repo.sh              # 1. Configure repositories
sudo ./proxmox-optimize.sh          # 2. Core system optimization
sudo ./proxmox-network.sh 10gbe # 3. Network optimization (specify your tier)
sudo ./proxmox-power-management.sh  # 4. Power management (optional)
sudo ./proxmox-zfs.sh               # 5. ZFS optimization (if using ZFS)
```

### Post-Installation

```bash
# Update GRUB (if IOMMU or power settings changed)
sudo update-grub

# Reboot to apply all changes
sudo reboot

# Verify configuration
proxmox-status          # System status
power-status            # Power management status (if installed)
thermal-check           # CPU temperature check (if installed)
zfs-status              # ZFS status (if installed)
```

---

## Scripts Overview

### `proxmox-repo.sh`
**Purpose**: Configure Proxmox repositories for non-subscription use

**What it does**:
- Creates no-subscription repository configuration
- Disables enterprise repositories
- Updates package lists

**Idempotent**: Yes
**Requires Reboot**: No
**Backup Created**: No (safe operations)

---

### `proxmox-network.sh`
**Purpose**: Network configuration based on interface speed tier

**What it does**:
- Detects or accepts network speed tier (1/10/25/40/100/200 GbE)
- Configures TCP/UDP buffer sizes for the tier
- Configures network queue depths and backlogs
- Enables BBR congestion control for 10GbE+
- Configures NIC ring buffers and hardware offloading
- Provides Jumbo Frame support (--jumbo flag)
- Creates network monitoring commands

**Idempotent**: Yes
**Requires Reboot**: No
**Backup Location**: `/root/network-backup`

**Usage**:
```bash
sudo ./proxmox-network.sh 1gbe    # 1 Gigabit (default, conservative)
sudo ./proxmox-network.sh 10gbe   # 10 Gigabit (recommended)
sudo ./proxmox-network.sh 25gbe   # 25 Gigabit
sudo ./proxmox-network.sh 40gbe   # 40 Gigabit
sudo ./proxmox-network.sh 100gbe  # 100 Gigabit
sudo ./proxmox-network.sh 200gbe  # 200 Gigabit
```

**Network Tier Optimizations**:

| Tier | TCP Buffer Max | Backlog | Congestion | Ring Buffer | Use Case |
|------|---------------|---------|------------|-------------|----------|
| 1 GbE | 8 MB | 5K | CUBIC | 512 | Small deployments |
| 10 GbE | 32 MB | 30K | BBR | 2048 | Standard |
| 25 GbE | 64 MB | 50K | BBR | 4096 | High-speed |
| 40 GbE | 128 MB | 100K | BBR | 8192 | Very high-speed |
| 100 GbE | 256 MB | 250K | BBR | 8192 | Very high-speed |
| 200 GbE | 512 MB | 500K | BBR | 8192 | Very high-speed |

**Created Commands**:
- `network-status` - Current network configuration and statistics
- `network-test` - Performance testing guide

**Key Parameters Applied**:
```
net.core.rmem_max          # Maximum receive buffer
net.core.wmem_max          # Maximum send buffer
net.ipv4.tcp_rmem          # TCP receive buffer (min/default/max)
net.ipv4.tcp_wmem          # TCP send buffer (min/default/max)
net.core.netdev_max_backlog    # Network queue depth
net.ipv4.tcp_congestion_control # BBR or CUBIC
```

**Additional Optimizations**:
- Hardware offloading (TSO, GSO, GRO)
- Interrupt coalescing for 10GbE+
- TCP window scaling
- TCP timestamps and SACK
- Connection tracking limits

---

### `proxmox-optimize.sh`
**Purpose**: Core system configuration

**What it does**:
- [1/7] Backup current system settings
- [2/7] Install monitoring tools
- [3/7] Configure kernel parameters (sysctl)
- [4/7] Enable nested virtualization
- [5/7] Configure IOMMU for device passthrough
- [6/7] Enable SSD TRIM
- [7/7] Create management scripts

**Idempotent**: Yes
**Requires Reboot**: Yes (for IOMMU/nested virt)
**Backup Location**: `/root/backup`

**Created Commands**:
- `proxmox-status` - System status overview

**Kernel Parameters Applied**:
```
vm.swappiness=10
vm.vfs_cache_pressure=50
net.core.netdev_max_backlog=8192
net.ipv4.tcp_fin_timeout=30
fs.file-max=2097152
net.bridge.bridge-nf-call-iptables=1
```

---

### `proxmox-power-management.sh`
**Purpose**: Power management and thermal control

**What it does**:
- [1/8] Configure CPU frequency governor (schedutil)
- [2/8] Apply vendor-specific configuration (Intel/AMD)
- [3/8] Enable PCIe ASPM (powersave mode)
- [4/8] Configure SATA link power management
- [5/8] Enable network power management (WoL, EEE)
- [6/8] Configure USB selective suspend
- [7/8] Enable PCI runtime power management
- [8/8] Update kernel boot parameters

**Idempotent**: Yes
**Requires Reboot**: Yes (for kernel parameters)
**Backup Location**: `/root/power-backup-YYYYMMDD`

**Created Commands**:
- `power-status` - Current power state
- `thermal-check` - CPU temperature and frequency
- `performance-mode` - Very high-speed
- `balanced-mode` - Default balanced settings
- `powersave-mode` - Power saving mode

**Systemd Service**: `proxmox-power.service` (auto-applies on boot)

**Kernel Parameters Applied** (Intel):
```
intel_idle.max_cstate=6
intel_pstate=passive
pcie_aspm=powersave
```

**Kernel Parameters Applied** (AMD):
```
processor.max_cstate=6
amd_pstate=passive
pcie_aspm=powersave
```

---

### `proxmox-zfs.sh`
**Purpose**: Safe ZFS optimization for Proxmox storage

**What it does**:
- Calculate ARC size based on total RAM
- Apply runtime ARC limits
- Create persistent ZFS module configuration
- Enable autotrim on all pools
- Optimize VM storage datasets (atime, xattr)
- Generate status and tuning scripts

**Idempotent**: Yes
**Requires Reboot**: Recommended
**Backup Location**: None (safe operations)

**ARC Sizing Strategy**:
| Total RAM | ARC Min | ARC Max | VM Reserve |
|-----------|---------|---------|------------|
| 16 GB     | 1 GB    | 2 GB    | 14+ GB     |
| 32 GB     | 1 GB    | 3 GB    | 29+ GB     |
| 64 GB     | 2 GB    | 4 GB    | 60+ GB     |
| 128 GB    | 2 GB    | 6 GB    | 122+ GB    |
| 256+ GB   | 3 GB    | 8 GB    | 248+ GB    |

**Created Commands**:
- `zfs-status` - ZFS status
- `zfs-tune-guide` - Tuning recommendations

**Safety Settings Preserved**:
- `sync=standard` - Prevents data loss
- `compression` - Proxmox-managed per-volume
- `primarycache=all` - Full caching for performance

---

## Configuration Files

### Created/Modified System Files

```
/etc/sysctl.d/99-proxmox-optimize.conf       # Kernel parameters
/etc/modprobe.d/kvm-nested.conf              # Nested virtualization
/etc/modprobe.d/zfs.conf                     # ZFS ARC limits
/etc/modules                                 # VFIO modules
/etc/default/grub                            # Boot parameters
/etc/default/cpufrequtils                    # CPU governor
/etc/systemd/system/proxmox-power.service    # Power service
/etc/apt/sources.list.d/debian.sources       # Proxmox repos
```

### Backup Locations

```
/root/backup/                     # proxmox-optimize.sh backups
  ├── sysctl-backup-*.conf
  └── grub.backup.*

/root/power-backup-YYYYMMDD/      # Power management backups
  ├── grub
  ├── cpufrequtils
  └── modules-load.d/
```

---

## Management Commands

After installation, the following commands are available:

### System Status
```bash
proxmox-status      # Overall system status
                    # - Temperature sensors
                    # - Nested virtualization
                    # - IOMMU status
                    # - Memory usage
                    # - VM/Container counts
```

### Network Status
```bash
network-status      # Network configuration status
                    # - Configured GbE tier
                    # - TCP congestion control
                    # - Buffer sizes
                    # - Queue depths
                    # - Interface speeds and states

network-test        # Performance testing guide
                    # - iperf3 usage
                    # - Latency testing
                    # - Bandwidth measurement
```

### Power Management
```bash
power-status        # Power configuration status
                    # - CPU governor and driver
                    # - CPU frequencies
                    # - Temperature
                    # - PCIe ASPM status
                    # - Turbo/Boost status

thermal-check       # Detailed thermal check
                    # - Max CPU temperature
                    # - Threshold warnings
                    # - Current frequencies
                    # - Throttling indicators

performance-mode    # Switch to performance mode
balanced-mode       # Switch to balanced mode
powersave-mode      # Switch to powersave mode
```

### ZFS Management
```bash
zfs-status          # ZFS status overview
                    # - ARC memory usage
                    # - Hit ratio
                    # - Pool health
                    # - Fragmentation
                    # - VM volume settings

zfs-tune-guide      # Optimization guide
                    # - Applied settings
                    # - Proxmox-managed settings
                    # - Safety information
                    # - Advanced tuning options
```

---

## Safety & Idempotency

### Idempotent Design
All scripts are **fully idempotent** - safe to run multiple times:
- Check current state before applying changes
- Skip already-configured settings
- Provide clear status messages (Already configured vs Newly configured)

### Data Safety
- **No data loss risk** - All optimizations preserve data integrity
- **Automatic backups** - System configs backed up before changes
- **Conservative defaults** - Settings favor reliability over performance
- **Proxmox-aware** - Respects Proxmox's management of VMs and storage

### Error Handling
- Error trapping (`set -e`, `trap`)
- Graceful degradation on non-critical failures
- Detailed error messages with line numbers
- Continues on non-blocking errors

---

## CPU Vendor Support

### Intel
- Intel VT-x nested virtualization
- Intel IOMMU (VT-d)
- Intel P-state driver
- Intel Turbo Boost control

### AMD
- AMD-V nested virtualization
- AMD IOMMU (AMD-Vi)
- AMD P-state driver (EPP mode)
- AMD Core Performance Boost

---

## Compatibility

### Tested On
- Proxmox VE 9.x
- Debian 13 (Trixie)
- Intel Xeon, Core i-series CPUs
- AMD EPYC, Ryzen CPUs

### Hardware Requirements
- x86_64 CPU with virtualization extensions (Intel VT-x / AMD-V)
- IOMMU support (Intel VT-d / AMD-Vi) for device passthrough
- lm-sensors compatible CPU for thermal monitoring

### Optional Features
- ZFS support (for zfs optimization script)
- NVMe/SATA SSD (for TRIM optimization)
- Multiple CPU cores (for power management benefits)

---

## Troubleshooting

### Script Won't Run
```bash
# Ensure root permissions
sudo -i

# Make scripts executable
chmod +x /path/to/script.sh

# Check Proxmox version
pveversion
```

### IOMMU Not Enabled
```bash
# Check if enabled in GRUB
grep GRUB_CMDLINE_LINUX_DEFAULT /etc/default/grub

# Update GRUB and reboot
update-grub
reboot

# Verify after reboot
dmesg | grep -i iommu
```

### Power Management Not Working
```bash
# Check if CPU frequency scaling is available
ls /sys/devices/system/cpu/cpu0/cpufreq/

# Load required modules
modprobe acpi-cpufreq   # or amd-pstate / intel_pstate

# Check systemd service
systemctl status proxmox-power.service
```

### ZFS Script Fails
```bash
# Verify ZFS is installed
zpool list

# Check if running as root
whoami

# Verify ZFS modules loaded
lsmod | grep zfs
```

### Temperature Sensors Not Working
```bash
# Install lm-sensors
apt-get install lm-sensors

# Detect sensors
sensors-detect --auto

# Test reading
sensors
```

---

## Semantic Versioning

This project follows [Semantic Versioning 2.0.0](https://semver.org/):

- **MAJOR** version for incompatible API/script changes
- **MINOR** version for backwards-compatible functionality additions
- **PATCH** version for backwards-compatible bug fixes


See [CHANGELOG.md](CHANGELOG.md) for version history.

---

## Character & Emoji Policy

This project follows a strict character policy for compatibility:

### Console Output (Permitted)
- SUCCESS: OK
- ERROR: ERROR
- WARNING: WARNING
- INFO: INFO
- PENDING: 
- DONE: OK
- STEP: 

### Log Files (ASCII Only)
All logged output uses plain ASCII characters for compatibility with:
- Log shippers and aggregators
- Parsing tools and scripts
- Archival systems

See the character policy documentation for full details.

---

## Contributing

Contributions are welcome! Please read our [CONTRIBUTING.md](CONTRIBUTING.md) guide for details on:

- Code of conduct
- Development guidelines
- Coding standards
- Testing requirements
- Commit message format
- Pull request process
- Character & emoji policy

Quick checklist:
1. All scripts remain idempotent
2. Follow existing error handling patterns
3. Test on Proxmox VE 9.x
4. Update documentation and CHANGELOG
5. Follow semantic versioning
6. Adhere to character policy for output
7. Pass ShellCheck linting

---

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

```
Copyright 2025 HyperSec

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

---

## Disclaimer

These scripts modify system configuration. While designed to be safe and idempotent:
- Always test in a non-production environment first
- Review the code before running on production systems
- Ensure you have backups
- The authors are not responsible for any system issues

**Use at your own risk.**

---

## Support

- Issues: [GitHub Issues](https://github.com/yourusername/proxmox-postinstall/issues)
- Documentation: This README and inline script comments
- Community: Proxmox Forums, r/Proxmox

---

## Acknowledgments

- Proxmox VE Team for the virtualization platform
- Debian Project for the stable base system
- Community contributors and testers

---

