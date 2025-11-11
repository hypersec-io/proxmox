# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.2.2](https://github.com/hypersec-io/proxmox/compare/v2.2.1...v2.2.2) (2025-11-11)


### Bug Fixes

* move UI customizations from optimize to repo script ([34b9be7](https://github.com/hypersec-io/proxmox/commit/34b9be70d0e9d31ba51fe06e9687ba625a86c70f))

## [2.2.1](https://github.com/hypersec-io/proxmox/compare/v2.2.0...v2.2.1) (2025-11-10)


### Bug Fixes

* Move 99-proxmox-cluster.conf to postinstall directory ([9024c09](https://github.com/hypersec-io/proxmox/commit/9024c09d49700e472c9f084932372187ffa4f37d))
* Update semantic-release config to reference scripts in postinstall directory ([5726bf6](https://github.com/hypersec-io/proxmox/commit/5726bf675300cfc6284a758e5203ed2aef3d205e))

## [2.1.2] - 2025-10-30

### Added

- Chrony (NTP) time synchronization configuration in proxmox-optimize.sh
- Installation of 99-proxmox-cluster.conf for improved cluster time stability
- Step counter updated from 7 to 8 steps in optimization script

### Changed

- Updated recommended script execution order in README.md
  - New order: repo → optimize → zfs → power (optional) → network (optional)
- Changed installation method to prefer download/unzip over git clone
- Updated all repository references to hypersec-io/proxmox

### Fixed

- README.md now uses main branch zip for "latest" downloads instead of version-specific releases

## [2.1.1] - 2025-10-27

### Fixed
- Corrected sysctl.d file load order to ensure network settings (99-proxmox-network.conf) properly override base optimize settings (98-proxmox-optimize.conf)

## [2.1.0] - 2025-10-10

### Added
- **NEW: Network Optimization Script** (`proxmox-network.sh`)
  - **Auto-detection** of fastest Proxmox-bound network interface
  - Detects physical interfaces used by Proxmox bridges
  - Tier-based network optimization (1/10/25/40/100/200 GbE)
  - TCP/UDP buffer scaling based on network speed
  - BBR congestion control for high-speed networks
  - NIC hardware offloading configuration
  - Ring buffer and queue optimization
  - Optional Jumbo Frames support (--jumbo flag)
  - Network monitoring commands (`network-status`, `network-test`)
- Thermal management functionality moved to power management script
- Enhanced `power-status` command with real-time CPU temperature monitoring
- `thermal-check` command for detailed temperature and frequency analysis
- Temperature threshold warnings (75°C, 85°C, 95°C)
- Comprehensive README.md with detailed documentation
- CHANGELOG.md following Keep a Changelog format
- CONTRIBUTING.md with development guidelines
- Apache 2.0 LICENSE
- Semantic versioning support with package.json and .releaserc.json
- Character and emoji policy compliance (CHARS-POLICY.md)
- .gitignore for project files

### Changed
- **BREAKING**: Removed version numbers from script headers (managed by semantic-release)
- Thermal management now part of `proxmox-power-management.sh` instead of optimize script
- Step numbering reduced from 9 to 7 in `proxmox-optimize.sh`
- Updated all script headers with Apache 2.0 license
- Updated `proxmox-repo.sh` header comments for clarity
- Improved logical organization of features
- README now references Apache 2.0 instead of MIT

### Removed
- Non-functional subscription nag removal code
- Thermal management section from `proxmox-optimize.sh`
- Outdated references to subscription nag in comments
- Version numbers from code headers (now in package.json only)

### Fixed
- Corrected step numbering throughout optimize script
- Removed ineffective proxmoxlib.js patching code

## [2.0.0] - 2024-09-01

### Added
- Initial release for Proxmox VE 9.x on Debian 13 (Trixie)
- Core system optimization script (`proxmox-optimize.sh`)
  - Kernel parameter tuning via sysctl
  - Nested virtualization support (Intel/AMD)
  - IOMMU and VFIO configuration
  - SSD TRIM optimization
  - Essential monitoring tools installation
- Comprehensive power management script (`proxmox-power-management.sh`)
  - CPU frequency scaling with schedutil/ondemand governors
  - PCIe ASPM configuration
  - Storage, network, USB, and PCI power management
  - Vendor-specific optimizations (Intel P-state, AMD P-state)
  - Power profile switching (performance/balanced/powersave)
  - Systemd service for persistence
- ZFS optimization script (`proxmox-zfs.sh`)
  - RAM-aware ARC memory management
  - Autotrim enablement
  - Dataset optimizations (atime, xattr)
  - Safety-first approach preserving data integrity
- Repository configuration script (`proxmox-repo.sh`)
  - No-subscription repository setup
  - Enterprise repository disabling

### Features
- Fully idempotent design - safe to run multiple times
- Comprehensive error handling with trap mechanisms
- Automatic backup creation before modifications
- Colored console output for better user experience
- Vendor detection (Intel vs AMD) for optimizations
- Management command suite:
  - `proxmox-status` - System status overview
  - `power-status` - Power configuration status
  - `performance-mode`, `balanced-mode`, `powersave-mode` - Power profiles
  - `zfs-status` - ZFS status and statistics
  - `zfs-tune-guide` - ZFS tuning recommendations

### Technical Details
- Supports Proxmox VE 9.x
- Debian 13 (Trixie) base system
- Intel VT-x and AMD-V virtualization
- IOMMU support (VT-d/AMD-Vi)
- ZFS filesystem support

### Documentation
- Comprehensive inline comments
- Script headers with purpose and description
- Safety notes and warnings
- Backup location documentation

## Previous Versions

### Ported
- Ported from HyperSec Proxmox on prem core scrips
- Upgraded from Proxmox 8.x and 7.x
- Repository configuration

## Contributing

Please read [CONTRIBUTING.md](CONTRIBUTING.md) for details on our code of conduct and the process for submitting pull requests.

---

## Links

- [Semantic Versioning 2.0.0](https://semver.org/)
- [Keep a Changelog](https://keepachangelog.com/)
- [Proxmox VE Documentation](https://pve.proxmox.com/pve-docs/)
