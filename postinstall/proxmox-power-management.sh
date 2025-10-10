#!/bin/bash

#############################################
# Proxmox VE 9 Power Management Configuration
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
#   Power management and thermal control for Proxmox VE hosts.
#   Configures CPU frequency scaling, PCIe ASPM, storage/network
#   power management, and thermal monitoring.
#
# Usage:
#   sudo ./proxmox-power-management.sh
#
# Requirements:
#   - Proxmox VE 9.x
#   - Debian 13 (Trixie)
#   - Root privileges
#   - CPU with frequency scaling support
#
# Features:
#   - CPU governor configuration (schedutil/ondemand)
#   - Vendor-specific optimizations (Intel P-state / AMD P-state)
#   - PCIe Active State Power Management (ASPM)
#   - Storage, network, USB, and PCI runtime power management
#   - Thermal monitoring with temperature thresholds
#   - Power profile switching (performance/balanced/powersave)
#
# Idempotent: Yes (safe to run multiple times)
# Requires Reboot: Yes (for kernel parameter changes)
# Backup Location: /root/power-backup-YYYYMMDD
#
#############################################

set -eE  # Exit on error and enable error trap
trap 'handle_error $LINENO' ERR

# Error handler function
handle_error() {
    local line_no=$1
    echo -e "${RED}Error occurred at line ${line_no}${NC}"
    echo "Attempting to continue with remaining optimizations..."
    # Continue execution instead of exiting
}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root${NC}" 
   exit 1
fi

# Check Proxmox version
PVE_VERSION=$(pveversion | sed 's/.*pve-manager\/\([0-9]\).*/\1/')
if [ "$PVE_VERSION" != "9" ]; then
    echo -e "${YELLOW}Warning: This script is optimized for Proxmox 9${NC}"
    echo -e "${YELLOW}You are running Proxmox $PVE_VERSION${NC}"
    read -p "Continue anyway? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

echo -e "${GREEN}=== Proxmox 9 Power Management Setup ===${NC}"
echo -e "${BLUE}Configuring balanced power settings${NC}"
echo -e "${CYAN}Script is IDEMPOTENT - safe to run multiple times${NC}\n"

# Detect CPU vendor
echo "Detecting CPU vendor..."
CPU_VENDOR=$(lscpu | grep "Vendor ID" | awk '{print $3}')
CPU_MODEL=$(lscpu | grep "Model name" | cut -d: -f2 | xargs)
echo -e "${GREEN}Detected: $CPU_MODEL${NC}"
echo -e "${GREEN}Vendor: $CPU_VENDOR${NC}"

#############################################
# Create backup (only if not already backed up today)
#############################################
BACKUP_DATE=$(date +%Y%m%d)
BACKUP_DIR="/root/power-backup-${BACKUP_DATE}"
if [ ! -d "$BACKUP_DIR" ]; then
    echo -e "\n${YELLOW}Creating backup in $BACKUP_DIR${NC}"
    mkdir -p "$BACKUP_DIR"
    
    # Backup GRUB if exists
    [ -f /etc/default/grub ] && cp /etc/default/grub "$BACKUP_DIR/" 2>/dev/null || true
    
    # Backup existing power management configs
    [ -f /etc/default/cpufrequtils ] && cp /etc/default/cpufrequtils "$BACKUP_DIR/" 2>/dev/null || true
    [ -d /etc/modules-load.d ] && cp -r /etc/modules-load.d "$BACKUP_DIR/" 2>/dev/null || true
    
    echo -e "${GREEN}OK Backup created${NC}"
else
    echo -e "${CYAN}Backup already exists for today, skipping${NC}"
fi

#############################################
# CPU Governor Configuration
#############################################
echo -e "\n${YELLOW}[1/8] Configuring CPU Governor (schedutil - balanced)${NC}"

# Install required packages (idempotent - apt-get handles this)
echo "Checking required packages..."
dpkg -l cpufrequtils linux-cpupower 2>/dev/null | grep -q "^ii" || {
    echo "Installing required packages..."
    apt-get install -y cpufrequtils linux-cpupower 2>&1 | grep -E "Setting up|Processing" || true
}

# Check if cpufreq directory exists
echo "Checking CPU frequency scaling support..."
if [ ! -d "/sys/devices/system/cpu/cpu0/cpufreq" ]; then
    echo -e "${YELLOW}CPU frequency scaling not available - loading drivers${NC}"
    
    # Check if modules are already loaded
    if [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
        for driver in amd-pstate-epp amd-pstate acpi-cpufreq; do
            if ! lsmod | grep -q "^$driver"; then
                echo "Loading $driver..."
                modprobe $driver 2>/dev/null && echo -e "${GREEN}OK Loaded $driver${NC}" || true
            else
                echo "$driver already loaded"
            fi
        done
    elif [[ "$CPU_VENDOR" == "GenuineIntel" ]]; then
        for driver in intel_pstate acpi-cpufreq; do
            if ! lsmod | grep -q "^$driver"; then
                modprobe $driver 2>/dev/null || true
            fi
        done
    fi
    
    sleep 1  # Give driver time to initialize
fi

# Check available governors
echo "Checking available governors..."
if [ -f "/sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors" ]; then
    AVAILABLE_GOVERNORS=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null || echo "none")
    CURRENT_GOVERNOR=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "none")
    
    echo "Available governors: $AVAILABLE_GOVERNORS"
    echo "Current governor: $CURRENT_GOVERNOR"
    
    # Set governor based on availability
    if [[ $AVAILABLE_GOVERNORS == *"schedutil"* ]]; then
        GOVERNOR="schedutil"
    elif [[ $AVAILABLE_GOVERNORS == *"ondemand"* ]]; then
        GOVERNOR="ondemand"
    elif [[ $AVAILABLE_GOVERNORS == *"conservative"* ]]; then
        GOVERNOR="conservative"
    else
        GOVERNOR="performance"
        echo -e "${YELLOW}No power-saving governor available, using performance${NC}"
    fi
    
    if [ "$CURRENT_GOVERNOR" != "$GOVERNOR" ]; then
        echo "Setting $GOVERNOR governor..."
        for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            [ -f "$cpu" ] && echo "$GOVERNOR" > "$cpu" 2>/dev/null || true
        done
        echo -e "${GREEN}OK $GOVERNOR governor applied${NC}"
    else
        echo -e "${CYAN}Governor already set to $GOVERNOR${NC}"
    fi
    
    # Tune governor parameters
    if [ "$GOVERNOR" == "schedutil" ]; then
        echo "Tuning schedutil for balanced performance..."
        for policy in /sys/devices/system/cpu/cpufreq/policy*/; do
            [ -f "${policy}schedutil/rate_limit_us" ] && echo 1000 > "${policy}schedutil/rate_limit_us" 2>/dev/null || true
        done
    elif [ "$GOVERNOR" == "ondemand" ] && [ -d "/sys/devices/system/cpu/cpufreq/ondemand" ]; then
        echo "Tuning ondemand for balanced performance..."
        echo 80 > /sys/devices/system/cpu/cpufreq/ondemand/up_threshold 2>/dev/null || true
        echo 1 > /sys/devices/system/cpu/cpufreq/ondemand/powersave_bias 2>/dev/null || true
    fi
else
    echo -e "${YELLOW}CPU frequency scaling not available on this system${NC}"
fi

# Make governor persistent (idempotent - overwrites file)
echo 'GOVERNOR="schedutil"' > /etc/default/cpufrequtils

#############################################
# CPU-Specific Configuration
#############################################
echo -e "\n${YELLOW}[2/8] Applying CPU-specific configuration${NC}"

if [[ "$CPU_VENDOR" == "GenuineIntel" ]]; then
    echo "Applying Intel-specific settings..."
    
    # Intel P-state configuration
    if [ -d /sys/devices/system/cpu/intel_pstate ]; then
        CURRENT_MIN=$(cat /sys/devices/system/cpu/intel_pstate/min_perf_pct 2>/dev/null || echo "0")
        CURRENT_MAX=$(cat /sys/devices/system/cpu/intel_pstate/max_perf_pct 2>/dev/null || echo "0")
        
        if [ "$CURRENT_MIN" != "30" ] || [ "$CURRENT_MAX" != "100" ]; then
            echo 30 > /sys/devices/system/cpu/intel_pstate/min_perf_pct 2>/dev/null || true
            echo 100 > /sys/devices/system/cpu/intel_pstate/max_perf_pct 2>/dev/null || true
            echo -e "${GREEN}OK Intel P-state configured (30% min, 100% max)${NC}"
        else
            echo -e "${CYAN}Intel P-state already configured${NC}"
        fi
    fi
    
elif [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
    echo "Applying AMD-specific settings..."
    
    # Check for AMD P-state EPP
    if [ -f /sys/devices/system/cpu/amd_pstate/status ]; then
        CURRENT_STATUS=$(cat /sys/devices/system/cpu/amd_pstate/status 2>/dev/null || echo "")
        if [ "$CURRENT_STATUS" != "passive" ]; then
            echo "passive" > /sys/devices/system/cpu/amd_pstate/status 2>/dev/null || true
            echo -e "${GREEN}OK AMD P-state configured${NC}"
        else
            echo -e "${CYAN}AMD P-state already configured${NC}"
        fi
    fi
    
    # AMD Core Performance Boost
    if [ -f /sys/devices/system/cpu/cpufreq/boost ]; then
        CURRENT_BOOST=$(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || echo "0")
        if [ "$CURRENT_BOOST" != "1" ]; then
            echo 1 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
            echo -e "${GREEN}OK AMD Core Performance Boost enabled${NC}"
        else
            echo -e "${CYAN}AMD boost already enabled${NC}"
        fi
    fi
fi

#############################################
# PCIe ASPM Configuration
#############################################
echo -e "\n${YELLOW}[3/8] Configuring PCIe Power Management (balanced)${NC}"

if [ -f /sys/module/pcie_aspm/parameters/policy ]; then
    CURRENT_ASPM=$(cat /sys/module/pcie_aspm/parameters/policy | grep -oE '\[.*\]' | tr -d '[]' 2>/dev/null || echo "")
    
    if [ "$CURRENT_ASPM" != "powersave" ]; then
        echo "Current ASPM policy: $CURRENT_ASPM"
        if echo "powersave" > /sys/module/pcie_aspm/parameters/policy 2>/dev/null; then
            echo -e "${GREEN}OK PCIe ASPM set to powersave${NC}"
        else
            echo -e "${YELLOW}Could not change ASPM policy (may need kernel parameter)${NC}"
        fi
    else
        echo -e "${CYAN}PCIe ASPM already set to powersave${NC}"
    fi
else
    echo -e "${YELLOW}ASPM not available${NC}"
fi

#############################################
# Storage Power Management
#############################################
echo -e "\n${YELLOW}[4/8] Configuring Storage Power Management (balanced)${NC}"

# SATA Link Power Management
echo "Configuring SATA link power management..."
SATA_COUNT=0

# Temporarily disable error exit
set +e

for host in /sys/class/scsi_host/host*/; do
    if [ -f "${host}link_power_management_policy" ]; then
        CURRENT=$(cat "${host}link_power_management_policy" 2>/dev/null | tr -d ' ')
        
        # Check if already configured
        if [[ "$CURRENT" == "med_power_with_dipm" ]] || [[ "$CURRENT" == "medium_power" ]] || [[ "$CURRENT" == "min_power" ]]; then
            echo "  $(basename $host): Already configured ($CURRENT)"
        else
            echo "  $(basename $host): Current = $CURRENT"
            # Try different policy names
            for policy in "med_power_with_dipm" "medium_power" "min_power"; do
                if echo "$policy" > "${host}link_power_management_policy" 2>/dev/null; then
                    echo "    → Set to: $policy"
                    SATA_COUNT=$((SATA_COUNT + 1))
                    break
                fi
            done
        fi
    fi
done

# Re-enable error exit
set -e

[ $SATA_COUNT -gt 0 ] && echo "Configured $SATA_COUNT SATA controllers" || echo "All SATA controllers already configured"

#############################################
# Network Power Management
#############################################
echo -e "\n${YELLOW}[5/8] Configuring Network Power Management${NC}"

for iface in $(ls /sys/class/net/ | grep -E '^(eth|eno|enp|ens)'); do
    if [ -d "/sys/class/net/$iface" ] && [ "$iface" != "lo" ]; then
        echo "Checking $iface..."
        
        # Check current WoL setting
        CURRENT_WOL=$(ethtool "$iface" 2>/dev/null | grep "Wake-on:" | awk '{print $2}')
        if [ "$CURRENT_WOL" != "g" ]; then
            ethtool -s "$iface" wol g 2>/dev/null && echo "  WoL enabled" || true
        fi
        
        # Enable EEE if not already enabled
        ethtool --show-eee "$iface" 2>/dev/null | grep -q "EEE status: enabled" || {
            ethtool --set-eee "$iface" eee on 2>/dev/null && echo "  EEE enabled" || true
        }
    fi
done

#############################################
# USB Power Management
#############################################
echo -e "\n${YELLOW}[6/8] Configuring USB Power Management (selective)${NC}"

USB_CONFIGURED=0
USB_ALREADY=0

# Temporarily disable error exit for arithmetic operations
set +e

for usb in /sys/bus/usb/devices/*/power/control; do
    if [ -f "$usb" ]; then
        CURRENT=$(cat "$usb" 2>/dev/null || echo "")
        DEVICE_PATH=$(dirname $(dirname "$usb"))
        
        # Check for HID devices
        if [ -f "$DEVICE_PATH/bInterfaceClass" ]; then
            CLASS=$(cat "$DEVICE_PATH/bInterfaceClass" 2>/dev/null || echo "")
            if [ "$CLASS" == "03" ]; then
                if [ "$CURRENT" != "on" ]; then
                    if echo "on" > "$usb" 2>/dev/null; then
                        USB_CONFIGURED=$((USB_CONFIGURED + 1))
                    fi
                else
                    USB_ALREADY=$((USB_ALREADY + 1))
                fi
            else
                if [ "$CURRENT" != "auto" ]; then
                    if echo "auto" > "$usb" 2>/dev/null; then
                        USB_CONFIGURED=$((USB_CONFIGURED + 1))
                    fi
                else
                    USB_ALREADY=$((USB_ALREADY + 1))
                fi
            fi
        else
            if [ "$CURRENT" != "auto" ]; then
                if echo "auto" > "$usb" 2>/dev/null; then
                    USB_CONFIGURED=$((USB_CONFIGURED + 1))
                fi
            else
                USB_ALREADY=$((USB_ALREADY + 1))
            fi
        fi
    fi
done

# Re-enable error exit
set -e

echo -e "${GREEN}OK USB: $USB_CONFIGURED newly configured, $USB_ALREADY already configured${NC}"

#############################################
# Runtime PM for PCI Devices
#############################################
echo -e "\n${YELLOW}[7/8] Configuring PCI Runtime PM (selective)${NC}"

PCI_CONFIGURED=0
PCI_ALREADY=0

# Temporarily disable error exit for arithmetic operations
set +e

for pci in /sys/bus/pci/devices/*/power/control; do
    if [ -f "$pci" ]; then
        CURRENT=$(cat "$pci" 2>/dev/null || echo "")
        DEVICE=$(basename $(dirname $(dirname "$pci")))
        DEVICE_CLASS=$(cat "/sys/bus/pci/devices/$DEVICE/class" 2>/dev/null || echo "")
        
        # Skip critical devices
        if [[ "$DEVICE_CLASS" == "0x03"* ]] || \
           [[ "$DEVICE_CLASS" == "0x0108"* ]] || \
           [[ "$DEVICE_CLASS" == "0x0106"* ]]; then
            if [ "$CURRENT" != "on" ]; then
                if echo "on" > "$pci" 2>/dev/null; then
                    PCI_CONFIGURED=$((PCI_CONFIGURED + 1))
                fi
            else
                PCI_ALREADY=$((PCI_ALREADY + 1))
            fi
        else
            if [ "$CURRENT" != "auto" ]; then
                if echo "auto" > "$pci" 2>/dev/null; then
                    PCI_CONFIGURED=$((PCI_CONFIGURED + 1))
                fi
            else
                PCI_ALREADY=$((PCI_ALREADY + 1))
            fi
        fi
    fi
done

# Re-enable error exit
set -e

echo -e "${GREEN}OK PCI: $PCI_CONFIGURED newly configured, $PCI_ALREADY already configured${NC}"

#############################################
# Kernel Parameters Update
#############################################
echo -e "\n${YELLOW}[8/8] Updating Kernel Parameters${NC}"

# Prepare balanced kernel parameters
KERNEL_PARAMS="quiet"

if [[ "$CPU_VENDOR" == "GenuineIntel" ]]; then
    KERNEL_PARAMS="$KERNEL_PARAMS intel_idle.max_cstate=6 intel_pstate=passive pcie_aspm=powersave"
elif [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
    KERNEL_PARAMS="$KERNEL_PARAMS processor.max_cstate=6 amd_pstate=passive pcie_aspm=powersave"
else
    KERNEL_PARAMS="$KERNEL_PARAMS processor.max_cstate=6 pcie_aspm=powersave"
fi

# Check if parameters are already set
CURRENT_CMDLINE=$(grep "^GRUB_CMDLINE_LINUX_DEFAULT" /etc/default/grub | cut -d'"' -f2)
if [ "$CURRENT_CMDLINE" != "$KERNEL_PARAMS" ]; then
    echo "Updating kernel parameters..."
    sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"$KERNEL_PARAMS\"/" /etc/default/grub
    echo -e "${GREEN}OK Kernel parameters updated${NC}"
    echo -e "${YELLOW}  Remember to run: update-grub && reboot${NC}"
else
    echo -e "${CYAN}Kernel parameters already configured${NC}"
fi

#############################################
# Create/Update Systemd Service
#############################################
echo -e "\n${YELLOW}Creating/updating systemd service${NC}"

# Create service file (idempotent - overwrites)
cat > /etc/systemd/system/proxmox-power.service << 'EOF'
[Unit]
Description=Proxmox 9 Power Management
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/proxmox-power-apply.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Create apply script (idempotent - overwrites)
cat > /usr/local/bin/proxmox-power-apply.sh << 'EOF'
#!/bin/bash
# Apply power settings on boot - Idempotent

# Load CPU drivers if needed
if grep -q "AuthenticAMD" /proc/cpuinfo; then
    lsmod | grep -q "amd-pstate" || modprobe amd-pstate 2>/dev/null || true
    lsmod | grep -q "acpi-cpufreq" || modprobe acpi-cpufreq 2>/dev/null || true
fi

if grep -q "GenuineIntel" /proc/cpuinfo; then
    lsmod | grep -q "intel_pstate" || modprobe intel_pstate 2>/dev/null || true
fi

# Set governor if not already set
for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    if [ -f "$gov" ]; then
        CURRENT=$(cat "$gov" 2>/dev/null || echo "")
        [ "$CURRENT" != "schedutil" ] && [ "$CURRENT" != "ondemand" ] && \
            echo "schedutil" > "$gov" 2>/dev/null || true
    fi
done

# Set ASPM if not already set
if [ -f /sys/module/pcie_aspm/parameters/policy ]; then
    CURRENT=$(cat /sys/module/pcie_aspm/parameters/policy | grep -oE '\[.*\]' | tr -d '[]' 2>/dev/null || echo "")
    [ "$CURRENT" != "powersave" ] && echo "powersave" > /sys/module/pcie_aspm/parameters/policy 2>/dev/null || true
fi

# Apply USB power management
for usb in /sys/bus/usb/devices/*/power/control; do
    if [ -f "$usb" ]; then
        CURRENT=$(cat "$usb" 2>/dev/null || echo "")
        DEVICE_PATH=$(dirname $(dirname "$usb"))
        if [ -f "$DEVICE_PATH/bInterfaceClass" ]; then
            CLASS=$(cat "$DEVICE_PATH/bInterfaceClass" 2>/dev/null || echo "")
            if [ "$CLASS" == "03" ]; then
                [ "$CURRENT" != "on" ] && echo "on" > "$usb" 2>/dev/null || true
            else
                [ "$CURRENT" != "auto" ] && echo "auto" > "$usb" 2>/dev/null || true
            fi
        else
            [ "$CURRENT" != "auto" ] && echo "auto" > "$usb" 2>/dev/null || true
        fi
    fi
done
EOF

chmod +x /usr/local/bin/proxmox-power-apply.sh

# Enable service if not already enabled
if ! systemctl is-enabled proxmox-power.service >/dev/null 2>&1; then
    systemctl daemon-reload
    systemctl enable proxmox-power.service
    echo -e "${GREEN}OK Systemd service created and enabled${NC}"
else
    systemctl daemon-reload
    echo -e "${CYAN}Systemd service already enabled${NC}"
fi

#############################################
# Thermal Management
#############################################
echo -e "\n${YELLOW}Setting up thermal monitoring${NC}"

cat > /usr/local/bin/thermal-check << 'EOF'
#!/bin/bash
# Simple thermal check script

# Get max temperature
TEMP=$(sensors 2>/dev/null | grep -E "Core|Tdie|Package" | \
    awk '{print $3}' | sed 's/[^0-9.]//g' | sort -rn | head -1 | cut -d. -f1)

if [ -z "$TEMP" ]; then
    echo "Cannot read temperature"
    exit 1
fi

echo "Current max temperature: ${TEMP}°C"

# Temperature thresholds
if [ "$TEMP" -ge 95 ]; then
    echo "EMERGENCY: Critical temperature!"
    echo "Action: System should throttle automatically via hardware"
    echo "Consider: Checking cooling system immediately"
elif [ "$TEMP" -ge 85 ]; then
    echo "WARNING: High temperature detected"
    echo "Action: CPU will reduce frequency automatically"
    echo "Consider: Improving cooling or reducing load"
elif [ "$TEMP" -ge 75 ]; then
    echo "NOTICE: Temperature elevated but safe"
else
    echo "Temperature is normal"
fi

# Show current CPU frequencies
echo ""
echo "Current CPU frequencies:"
grep "cpu MHz" /proc/cpuinfo | head -4 | awk '{printf "  Core %d: %.0f MHz\n", NR-1, $4}'
EOF
chmod +x /usr/local/bin/thermal-check

echo -e "${GREEN}OK Thermal monitoring script created${NC}"
echo -e "${CYAN}Note: CPUs handle thermal throttling automatically${NC}"
echo -e "${CYAN}At critical temps (95°C+), the CPU will:${NC}"
echo -e "${CYAN}  1. Reduce frequency automatically${NC}"
echo -e "${CYAN}  2. Reduce voltage if needed${NC}"
echo -e "${CYAN}  3. Emergency shutdown at ~105-110°C${NC}"

#############################################
# Create/Update Management Scripts
#############################################
echo -e "\n${YELLOW}Creating power management scripts${NC}"

# All scripts are idempotent - they overwrite existing files

# Power status script
cat > /usr/local/bin/power-status << 'EOF'
#!/bin/bash
echo "=== Proxmox 9 Power Status ==="
echo ""
echo -n "CPU Governor: "
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "N/A"
echo -n "CPU Driver: "
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo "N/A"
echo ""
echo "CPU Frequencies (MHz):"
grep "cpu MHz" /proc/cpuinfo | head -4 | awk '{print "  CPU " NR-1 ": " $4 " MHz"}'
echo ""
echo -n "Temperature: "
if command -v sensors >/dev/null 2>&1; then
    TEMP=$(sensors 2>/dev/null | grep -E "Core|Tdie|Package" | \
        awk '{print $3}' | sed 's/[^0-9.]//g' | sort -rn | head -1 | cut -d. -f1)
    if [ -n "$TEMP" ]; then
        echo "${TEMP}°C"
    else
        echo "N/A"
    fi
else
    echo "N/A (sensors not installed)"
fi
echo ""
echo -n "PCIe ASPM: "
cat /sys/module/pcie_aspm/parameters/policy 2>/dev/null | grep -oE '\[.*\]' | tr -d '[]' || echo "N/A"
echo ""
if [ -f /sys/devices/system/cpu/cpufreq/boost ]; then
    echo -n "AMD Boost: "
    BOOST=$(cat /sys/devices/system/cpu/cpufreq/boost)
    [ "$BOOST" == "1" ] && echo "Enabled" || echo "Disabled"
elif [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
    echo -n "Intel Turbo: "
    TURBO=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)
    [ "$TURBO" == "0" ] && echo "Enabled" || echo "Disabled"
fi
EOF

# Performance mode
cat > /usr/local/bin/performance-mode << 'EOF'
#!/bin/bash
echo "Switching to PERFORMANCE mode..."
for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -f "$gov" ] && echo "performance" > "$gov" 2>/dev/null || true
done
[ -f /sys/module/pcie_aspm/parameters/policy ] && echo "default" > /sys/module/pcie_aspm/parameters/policy 2>/dev/null || true
for ctrl in /sys/bus/usb/devices/*/power/control; do 
    [ -f "$ctrl" ] && echo "on" > "$ctrl" 2>/dev/null || true
done
for ctrl in /sys/bus/pci/devices/*/power/control; do 
    [ -f "$ctrl" ] && echo "on" > "$ctrl" 2>/dev/null || true
done
echo -e "\033[0;32mPerformance mode activated\033[0m"
EOF

# Balanced mode
cat > /usr/local/bin/balanced-mode << 'EOF'
#!/bin/bash
echo "Switching to BALANCED mode..."
/usr/local/bin/proxmox-power-apply.sh
echo -e "\033[0;32mBalanced mode activated\033[0m"
EOF

# Powersave mode
cat > /usr/local/bin/powersave-mode << 'EOF'
#!/bin/bash
echo "Switching to POWERSAVE mode..."
for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -f "$gov" ] && echo "powersave" > "$gov" 2>/dev/null || true
done
[ -f /sys/module/pcie_aspm/parameters/policy ] && echo "powersupersave" > /sys/module/pcie_aspm/parameters/policy 2>/dev/null || true
for ctrl in /sys/bus/usb/devices/*/power/control; do 
    [ -f "$ctrl" ] && echo "auto" > "$ctrl" 2>/dev/null || true
done
for ctrl in /sys/bus/pci/devices/*/power/control; do 
    [ -f "$ctrl" ] && echo "auto" > "$ctrl" 2>/dev/null || true
done
echo -e "\033[0;32mPowersave mode activated\033[0m"
EOF

chmod +x /usr/local/bin/power-status
chmod +x /usr/local/bin/performance-mode
chmod +x /usr/local/bin/balanced-mode
chmod +x /usr/local/bin/powersave-mode

echo -e "${GREEN}OK Management scripts created/updated${NC}"

#############################################
# Summary
#############################################
echo -e "\n${GREEN}=== Power Management Configuration Complete ===${NC}"
echo -e "${CYAN}This script is IDEMPOTENT - safe to run multiple times${NC}"

echo -e "\n${CYAN}Configuration Status:${NC}"
# Show current status
echo -n "  • CPU Governor: "
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "N/A"
echo -n "  • PCIe ASPM: "
cat /sys/module/pcie_aspm/parameters/policy 2>/dev/null | grep -oE '\[.*\]' | tr -d '[]' || echo "N/A"

echo -e "\n${CYAN}Available Commands:${NC}"
echo -e "  ${GREEN}power-status${NC}      - Check current power state"
echo -e "  ${GREEN}thermal-check${NC}     - Check CPU temperature"
echo -e "  ${GREEN}balanced-mode${NC}     - Balanced power/performance"
echo -e "  ${GREEN}performance-mode${NC}  - Performance mode"
echo -e "  ${GREEN}powersave-mode${NC}    - Power saving mode"

# Check if grub needs updating
CURRENT_CMDLINE=$(grep "^GRUB_CMDLINE_LINUX_DEFAULT" /etc/default/grub | cut -d'"' -f2)
if [[ "$CURRENT_CMDLINE" != *"pcie_aspm"* ]] || [[ "$CURRENT_CMDLINE" != *"max_cstate"* ]]; then
    echo -e "\n${YELLOW}Action Required:${NC}"
    echo -e "  1. Run: ${GREEN}update-grub${NC}"
    echo -e "  2. ${GREEN}Reboot${NC} your system"
else
    echo -e "\n${GREEN}No reboot required - all settings active${NC}"
fi

echo -e "\n${GREEN}Script complete! (Run count safe)${NC}"