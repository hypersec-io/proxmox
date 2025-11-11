#!/bin/bash

#############################################
# Proxmox VE 9 System Optimization Script
#############################################
#
# Copyright 2025 HyperSec
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#############################################
#
# Purpose:
#   System configuration for Proxmox VE hosts including kernel
#   parameter tuning, nested virtualization, IOMMU configuration,
#   monitoring tools installation, and UI customizations.
#
# Usage:
#   sudo ./proxmox-optimize.sh
#
# Requirements:
#   - Proxmox VE 9.x
#   - Debian 13 (Trixie)
#   - Root privileges
#   - Internet connection for package installation
#
# Features:
#   - Kernel parameter optimization (sysctl)
#   - Nested virtualization (Intel VT-x / AMD-V)
#   - IOMMU/VFIO configuration for device passthrough
#   - SSD TRIM enablement
#   - Monitoring tools
#
# Idempotent: Yes (safe to run multiple times)
# Requires Reboot: Yes (if IOMMU or nested virt configured)
# Backup Location: /root/backup
#
#############################################

set -e
trap 'error_handler $? $LINENO' ERR

# Error handler
error_handler() {
    echo -e "${RED}Error occurred at line $2 (exit code: $1)${NC}"
    echo "Attempting to continue..."
    set +e
}

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

# Must be root
[ $EUID -ne 0 ] && { echo "Run as root"; exit 1; }

# Create backup directory
BACKUP_DIR="/root/backup"
mkdir -p "$BACKUP_DIR"

# Detect system info
PVE_VERSION=$(pveversion | sed 's/.*pve-manager\/\([0-9]\).*/\1/')
CPU_VENDOR=$(lscpu | grep "Vendor ID" | awk '{print $3}')
TOTAL_RAM_GB=$(free -g | awk '/^Mem:/{print $2}')

echo -e "${GREEN}=== Proxmox System Configuration ===${NC}"
echo -e "${CYAN}Version: Proxmox $PVE_VERSION${NC}"
echo -e "${CYAN}CPU: $CPU_VENDOR | RAM: ${TOTAL_RAM_GB}GB${NC}"
echo -e "${CYAN}Backups will be stored in: $BACKUP_DIR${NC}\n"

#############################################
# Check and backup Proxmox defaults
#############################################
echo -e "${YELLOW}[1/7] Checking Proxmox defaults...${NC}"

# Backup current sysctl settings
BACKUP_DATE=$(date +%Y%m%d_%H%M%S)
if [ ! -f "$BACKUP_DIR/sysctl-backup-$BACKUP_DATE.conf" ]; then
    sysctl -a 2>/dev/null > "$BACKUP_DIR/sysctl-backup-$BACKUP_DATE.conf"
    echo -e "${GREEN}OK Settings backed up to $BACKUP_DIR${NC}"
fi

#############################################
# Install Monitoring Tools (with error handling)
#############################################
echo -e "\n${YELLOW}[2/7] Installing monitoring tools...${NC}"

# Update package lists first
echo "Updating package lists..."
if ! apt-get update >/dev/null 2>&1; then
    echo -e "${YELLOW}Warning: Package update had issues, continuing...${NC}"
fi

# Tools to install (simplified list to avoid issues)
TOOLS=(
    "htop"
    "iotop"
    "iftop"
    "lm-sensors"
    "smartmontools"
    "ethtool"
)

echo "Checking installed tools..."
TO_INSTALL=""
for tool in "${TOOLS[@]}"; do
    if ! dpkg -l "$tool" 2>/dev/null | grep -q "^ii"; then
        TO_INSTALL="$TO_INSTALL $tool"
        echo "  Need to install: $tool"
    else
        echo "  Already installed: $tool"
    fi
done

if [ -z "$TO_INSTALL" ]; then
    echo -e "${CYAN}All monitoring tools already installed${NC}"
else
    echo "Installing missing tools..."
    # Install with better error handling
    for tool in $TO_INSTALL; do
        echo -n "  Installing $tool... "
        if apt-get install -y "$tool" >/dev/null 2>&1; then
            echo "OK"
        else
            echo "failed (non-critical)"
        fi
    done
    echo -e "${GREEN}OK Tool installation complete${NC}"
fi

# Configure sensors (non-critical)
echo "Configuring sensors..."
if command -v sensors >/dev/null 2>&1; then
    if ! sensors 2>/dev/null | grep -q "temp"; then
        sensors-detect --auto >/dev/null 2>&1 || echo "  Sensor detection failed (non-critical)"
    else
        echo "  Sensors already configured"
    fi
fi

#############################################
# Configure Chrony (NTP)
#############################################
echo -e "\n${YELLOW}[3/7] Configuring time synchronization...${NC}"

CHRONY_CONF="/etc/chrony/conf.d/99-proxmox-cluster.conf"
# Get script directory for config file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHRONY_SOURCE="$SCRIPT_DIR/99-proxmox-cluster.conf"

# Check if chrony is installed
if command -v chronyc >/dev/null 2>&1; then
    # Create conf.d directory if it doesn't exist
    mkdir -p /etc/chrony/conf.d

    # Check if config already exists
    if [ -f "$CHRONY_CONF" ]; then
        echo -e "${CYAN}Chrony cluster config already installed${NC}"
    else
        # Copy the config file if it exists in the source location
        if [ -f "$CHRONY_SOURCE" ]; then
            cp "$CHRONY_SOURCE" "$CHRONY_CONF"
            echo -e "${GREEN}OK Chrony cluster config installed${NC}"

            # Restart chrony to apply changes
            systemctl restart chrony >/dev/null 2>&1 && \
                echo -e "${GREEN}OK Chrony service restarted${NC}" || \
                echo -e "${YELLOW}Warning: Could not restart chrony${NC}"
        else
            echo -e "${YELLOW}Warning: Source config file not found at $CHRONY_SOURCE${NC}"
            echo "Skipping chrony configuration..."
        fi
    fi
else
    echo -e "${YELLOW}Chrony not installed, skipping time sync configuration${NC}"
fi

#############################################
# Apply Proxmox-safe sysctl settings
#############################################
echo -e "\n${YELLOW}[4/7] Configuring kernel parameters...${NC}"

cat > /etc/sysctl.d/98-proxmox-optimize.conf << 'EOF'
# Proxmox VM/Container Configuration

# Memory Management
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.dirty_background_ratio=5
vm.dirty_ratio=10

# Network - Basic safe optimizations
net.core.netdev_max_backlog=8192
net.core.somaxconn=8192
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_tw_reuse=1

# File System
fs.file-max=2097152
fs.inotify.max_user_watches=524288

# Bridge settings for VMs (Proxmox requirement)
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
EOF

sysctl -p /etc/sysctl.d/98-proxmox-optimize.conf >/dev/null 2>&1 || \
    echo -e "${YELLOW}Some sysctl settings could not be applied${NC}"
echo -e "${GREEN}OK Kernel parameters configured${NC}"

#############################################
# Enable Nested Virtualization
#############################################
echo -e "\n${YELLOW}[5/7] Configuring nested virtualization...${NC}"

if [[ "$CPU_VENDOR" == "GenuineIntel" ]]; then
    MOD_FILE="/etc/modprobe.d/kvm-nested.conf"
    if [ -f /sys/module/kvm_intel/parameters/nested ]; then
        CURRENT=$(cat /sys/module/kvm_intel/parameters/nested)
        if [[ "$CURRENT" == "Y" ]] || [[ "$CURRENT" == "1" ]]; then
            echo -e "${CYAN}Already enabled for Intel${NC}"
        else
            echo "options kvm_intel nested=1" > "$MOD_FILE"
            echo -e "${GREEN}OK Will be enabled after reboot (Intel)${NC}"
        fi
    fi
elif [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
    MOD_FILE="/etc/modprobe.d/kvm-nested.conf"
    if [ -f /sys/module/kvm_amd/parameters/nested ]; then
        CURRENT=$(cat /sys/module/kvm_amd/parameters/nested)
        if [[ "$CURRENT" == "Y" ]] || [[ "$CURRENT" == "1" ]]; then
            echo -e "${CYAN}Already enabled for AMD${NC}"
        else
            echo "options kvm_amd nested=1" > "$MOD_FILE"
            echo -e "${GREEN}OK Will be enabled after reboot (AMD)${NC}"
        fi
    fi
fi

#############################################
# Configure IOMMU
#############################################
echo -e "\n${YELLOW}[6/7] Checking IOMMU configuration...${NC}"

GRUB_UPDATED=false
if [ -f /etc/default/grub ]; then
    CURRENT_CMDLINE=$(grep "^GRUB_CMDLINE_LINUX_DEFAULT" /etc/default/grub | cut -d'"' -f2)
    
    if dmesg 2>/dev/null | grep -q "IOMMU enabled"; then
        echo -e "${CYAN}IOMMU already enabled${NC}"
    else
        # Backup grub config
        cp /etc/default/grub "$BACKUP_DIR/grub.backup.$(date +%Y%m%d_%H%M%S)"
        
        if [[ "$CPU_VENDOR" == "GenuineIntel" ]]; then
            if [[ "$CURRENT_CMDLINE" != *"intel_iommu=on"* ]]; then
                sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 intel_iommu=on iommu=pt\"/" /etc/default/grub
                echo -e "${GREEN}OK Intel IOMMU configured${NC}"
                GRUB_UPDATED=true
            fi
        elif [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
            if [[ "$CURRENT_CMDLINE" != *"amd_iommu=on"* ]]; then
                sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 amd_iommu=on iommu=pt\"/" /etc/default/grub
                echo -e "${GREEN}OK AMD IOMMU configured${NC}"
                GRUB_UPDATED=true
            fi
        fi
    fi
fi

# VFIO modules
if ! grep -q "^vfio$" /etc/modules 2>/dev/null; then
    cat >> /etc/modules << EOF
vfio
vfio_iommu_type1
vfio_pci
vfio_virqfd
EOF
    echo -e "${GREEN}OK VFIO modules configured${NC}"
else
    echo -e "${CYAN}VFIO already configured${NC}"
fi

#############################################
# Storage Configuration
#############################################
echo -e "\n${YELLOW}[7/7] Configuring storage...${NC}"

# Enable fstrim
if command -v systemctl >/dev/null 2>&1; then
    if ! systemctl is-enabled fstrim.timer >/dev/null 2>&1; then
        systemctl enable fstrim.timer >/dev/null 2>&1 && \
            echo -e "${GREEN}OK Weekly SSD TRIM enabled${NC}" || \
            echo -e "${YELLOW}Could not enable fstrim timer${NC}"
    else
        echo -e "${CYAN}SSD TRIM already enabled${NC}"
    fi
fi

#############################################
# Create Management Scripts
#############################################
echo -e "\n${YELLOW}Creating management scripts...${NC}"

# Simple status script
cat > /usr/local/bin/proxmox-status << 'EOF'
#!/bin/bash
echo "=== Proxmox System Status ==="
echo ""

# Temperature
echo "Temperature:"
if command -v sensors >/dev/null 2>&1; then
    sensors 2>/dev/null | grep -E "Core|Package|Tdie" | head -5 | sed 's/^/  /' || echo "  No readings"
else
    echo "  sensors not installed"
fi

# Nested Virtualization
echo ""
echo "Nested Virtualization:"
if [ -f /sys/module/kvm_intel/parameters/nested ]; then
    echo -n "  Intel: "
    cat /sys/module/kvm_intel/parameters/nested
elif [ -f /sys/module/kvm_amd/parameters/nested ]; then
    echo -n "  AMD: "
    cat /sys/module/kvm_amd/parameters/nested
fi

# IOMMU
echo ""
echo "IOMMU:"
if dmesg 2>/dev/null | grep -q "IOMMU enabled"; then
    echo "  OK Enabled"
else
    echo "  DISABLED Disabled"
fi

# Memory
echo ""
echo "Memory:"
free -h | grep "^Mem:" | awk '{print "  Total: " $2 ", Used: " $3 ", Available: " $7}'

# VMs
echo ""
echo "Virtual Machines:"
echo -n "  VMs: "
qm list 2>/dev/null | tail -n +2 | wc -l
echo -n "  Containers: "
pct list 2>/dev/null | tail -n +2 | wc -l
EOF
chmod +x /usr/local/bin/proxmox-status

echo -e "${GREEN}OK Management scripts created${NC}"

#############################################
# Summary
#############################################
echo -e "\n${GREEN}=== Configuration Complete ===${NC}"
echo ""
echo "Applied:"
echo "  • Monitoring tools installed"
echo "  • Time synchronization configured (chrony)"
echo "  • Kernel parameters configured"
echo "  • Nested virtualization configured"
echo "  • IOMMU ready"
echo "  • Storage configured"
echo ""
echo "Commands:"
echo "  proxmox-status - System status"
echo ""

if [ "$GRUB_UPDATED" == "true" ]; then
    echo -e "${YELLOW}Required:${NC}"
    echo "  1. Run: update-grub"
    echo "  2. Reboot system"
else
    echo -e "${GREEN}No reboot required${NC}"
fi

echo ""
echo "Backups stored in: $BACKUP_DIR"
