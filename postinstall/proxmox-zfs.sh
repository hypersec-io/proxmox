#!/bin/bash

#############################################
# Proxmox VE 9 ZFS Safe Optimization Script
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
#   ZFS configuration for Proxmox VE storage with data integrity
#   as the top priority. Configures ARC memory limits, autotrim, and
#   dataset settings while preserving all safety-critical settings.
#
# Usage:
#   sudo ./proxmox-zfs.sh
#
# Requirements:
#   - Proxmox VE 9.x with ZFS
#   - Debian 13 (Trixie)
#   - Root privileges
#   - ZFS pools configured
#
# Features:
#   - RAM-aware ARC memory management
#   - Autotrim enablement for SSD optimization
#   - Dataset optimizations (atime, xattr)
#   - Preserves sync=standard for data safety
#   - NO data loss risk (assumes no UPS)
#
# Idempotent: Yes (safe to run multiple times)
# Requires Reboot: Recommended (for full effect)
# Backup Location: N/A (safe operations only)
#
#############################################

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

# Must be root
[ $EUID -ne 0 ] && { echo "Run as root"; exit 1; }

# Check if ZFS is installed
if ! command -v zfs &> /dev/null; then
    echo "ZFS is not installed on this system"
    exit 1
fi

echo -e "${GREEN}=== Proxmox ZFS Configuration ===${NC}"
echo -e "${CYAN}Applying power-loss resilient settings${NC}"
echo -e "${CYAN}Checking Proxmox defaults before making changes${NC}\n"

#############################################
# Calculate ARC values based on RAM
#############################################
echo "Analyzing system memory..."

# Get total RAM in bytes and GB
TOTAL_RAM=$(free -b | awk '/^Mem:/{print $2}')
TOTAL_RAM_GB=$((TOTAL_RAM / 1024 / 1024 / 1024))

echo "Total RAM: ${TOTAL_RAM_GB}GB"

# Set conservative ARC values for VMs
if [ $TOTAL_RAM_GB -le 16 ]; then
    ARC_MIN_GB=1
    ARC_MAX_GB=2
elif [ $TOTAL_RAM_GB -le 32 ]; then
    ARC_MIN_GB=1
    ARC_MAX_GB=3
elif [ $TOTAL_RAM_GB -le 64 ]; then
    ARC_MIN_GB=2
    ARC_MAX_GB=4
elif [ $TOTAL_RAM_GB -le 128 ]; then
    ARC_MIN_GB=2
    ARC_MAX_GB=6
else
    ARC_MIN_GB=3
    ARC_MAX_GB=8
fi

# Convert to bytes
ARC_MIN=$((ARC_MIN_GB * 1024 * 1024 * 1024))
ARC_MAX=$((ARC_MAX_GB * 1024 * 1024 * 1024))

echo "Setting ARC: ${ARC_MIN_GB}GB min, ${ARC_MAX_GB}GB max"
echo "Reserved for VMs: $((TOTAL_RAM_GB - ARC_MAX_GB))GB+"

#############################################
# Apply runtime changes
#############################################
echo -e "\n${YELLOW}Applying ARC limits...${NC}"

# Check current values
CURRENT_MIN=$(cat /sys/module/zfs/parameters/zfs_arc_min 2>/dev/null || echo "0")
CURRENT_MAX=$(cat /sys/module/zfs/parameters/zfs_arc_max 2>/dev/null || echo "0")

if [ "$CURRENT_MIN" != "$ARC_MIN" ] || [ "$CURRENT_MAX" != "$ARC_MAX" ]; then
    echo $ARC_MIN > /sys/module/zfs/parameters/zfs_arc_min
    echo $ARC_MAX > /sys/module/zfs/parameters/zfs_arc_max
    echo 3 > /proc/sys/vm/drop_caches
    echo -e "${GREEN}OK ARC limits applied${NC}"
else
    echo -e "${CYAN}ARC already configured${NC}"
fi

#############################################
# Make ARC settings persistent
#############################################
cat > /etc/modprobe.d/zfs.conf << EOF
# ZFS ARC Configuration for Proxmox VMs
# Generated: $(date)
# System RAM: ${TOTAL_RAM_GB}GB
# ARC Limits: ${ARC_MIN_GB}GB - ${ARC_MAX_GB}GB

# Memory limits
options zfs zfs_arc_min=$ARC_MIN
options zfs zfs_arc_max=$ARC_MAX

# Performance settings (no data loss risk)
options zfs zfs_arc_meta_limit_percent=75
options zfs zfs_compressed_arc_enabled=1
options zfs zvol_threads=8

# Keep Proxmox defaults for sync behavior
# sync=standard is maintained for data safety
EOF

update-initramfs -u -k all >/dev/null 2>&1
echo -e "${GREEN}OK Persistent configuration saved${NC}"

#############################################
# Enable autotrim on all pools (SAFE)
#############################################
echo -e "\n${YELLOW}Checking autotrim settings...${NC}"

for pool in $(zpool list -H -o name); do
    CURRENT_TRIM=$(zpool get -H -o value autotrim $pool)
    if [ "$CURRENT_TRIM" != "on" ]; then
        zpool set autotrim=on $pool
        echo -e "${GREEN}OK Autotrim enabled on $pool${NC}"
    else
        echo -e "${CYAN}Autotrim already enabled on $pool${NC}"
    fi
done

#############################################
# Check and report Proxmox storage settings
#############################################
echo -e "\n${YELLOW}Checking Proxmox storage configuration...${NC}"

if [ -f /etc/pve/storage.cfg ]; then
    echo "Current Proxmox ZFS storage settings:"
    
    for storage in $(grep "^zfspool:" /etc/pve/storage.cfg | cut -d: -f2 | tr -d ' '); do
        echo -e "\n  Storage: ${CYAN}$storage${NC}"
        
        # Check if sparse is enabled (Proxmox handles thin provisioning)
        if grep -A5 "^zfspool: $storage" /etc/pve/storage.cfg | grep -q "sparse"; then
            echo "    Thin provisioning: Enabled"
        else
            echo "    Thin provisioning: Disabled"
            echo -e "    ${YELLOW}Tip: Enable via Proxmox GUI (Datacenter->Storage->Edit)${NC}"
        fi
        
        # Get the pool for this storage
        POOL=$(grep -A5 "^zfspool: $storage" /etc/pve/storage.cfg | grep "pool" | awk '{print $2}')
        if [ -n "$POOL" ]; then
            # Check compression (Proxmox sets per-volume)
            COMP=$(zfs get -H -o value compression $POOL 2>/dev/null || echo "off")
            echo "    Compression: $COMP"
            
            # Check volblocksize (Proxmox default is 8k)
            VBS=$(zfs get -H -o value volblocksize $POOL 2>/dev/null || echo "8k")
            echo "    Default volblocksize: $VBS"
        fi
    done
else
    echo -e "${YELLOW}No Proxmox storage configuration found${NC}"
fi

#############################################
# Apply dataset configuration
#############################################
echo -e "\n${YELLOW}Applying dataset configuration...${NC}"

for dataset in $(zfs list -H -o name -t filesystem); do
    # Skip system datasets
    if [[ "$dataset" == "rpool/ROOT"* ]] || [[ "$dataset" == "rpool/var"* ]]; then
        continue
    fi
    
    # Only optimize VM storage datasets
    if [[ "$dataset" == *"data"* ]] || [[ "$dataset" == *"vm"* ]]; then
        echo "Checking $dataset..."
        
        # Disable atime (SAFE - reduces writes)
        CURRENT_ATIME=$(zfs get -H -o value atime "$dataset")
        if [ "$CURRENT_ATIME" != "off" ]; then
            zfs set atime=off "$dataset" 2>/dev/null && \
                echo -e "${GREEN}  OK Atime disabled${NC}"
        fi
        
        # Set xattr=sa for better performance (SAFE)
        CURRENT_XATTR=$(zfs get -H -o value xattr "$dataset")
        if [ "$CURRENT_XATTR" != "sa" ]; then
            zfs set xattr=sa "$dataset" 2>/dev/null && \
                echo -e "${GREEN}  OK Extended attributes optimized${NC}"
        fi
        
        # DO NOT change: sync, compression, recordsize, primarycache
        # These should be managed by Proxmox or kept at defaults for safety
    fi
done

#############################################
# Create status checking script
#############################################
cat > /usr/local/bin/zfs-status << 'EOF'
#!/bin/bash
echo "=== ZFS Status for Proxmox ==="
echo ""
echo "ARC Memory Usage:"
ARC_SIZE=$(awk '/^size/ {print $3}' /proc/spl/kstat/zfs/arcstats)
ARC_MIN=$(cat /sys/module/zfs/parameters/zfs_arc_min)
ARC_MAX=$(cat /sys/module/zfs/parameters/zfs_arc_max)
TOTAL_RAM=$(free -b | awk '/^Mem:/{print $2}')

echo "  Current: $((ARC_SIZE / 1024 / 1024 / 1024))GB"
echo "  Minimum: $((ARC_MIN / 1024 / 1024 / 1024))GB"
echo "  Maximum: $((ARC_MAX / 1024 / 1024 / 1024))GB"
echo "  System:  $((TOTAL_RAM / 1024 / 1024 / 1024))GB total"

# Hit ratio
HITS=$(awk '/^hits/ {print $3}' /proc/spl/kstat/zfs/arcstats)
MISSES=$(awk '/^misses/ {print $3}' /proc/spl/kstat/zfs/arcstats)
if [ $((HITS + MISSES)) -gt 0 ]; then
    RATIO=$((HITS * 100 / (HITS + MISSES)))
    echo "  Hit Ratio: ${RATIO}%"
fi

echo ""
echo "Pool Status:"
for pool in $(zpool list -H -o name); do
    echo "  $pool:"
    echo "    Health:   $(zpool get -H -o value health $pool)"
    echo "    Autotrim: $(zpool get -H -o value autotrim $pool)"
    
    # Check fragmentation
    FRAG=$(zpool get -H -o value fragmentation $pool)
    if [ "$FRAG" != "-" ]; then
        echo "    Fragmentation: $FRAG"
    fi
done

echo ""
echo "Proxmox VM Volumes:"
# Show a few VM volumes and their settings
for zvol in $(zfs list -H -o name -t volume | head -5); do
    SIZE=$(zfs get -H -o value volsize "$zvol")
    USED=$(zfs get -H -o value used "$zvol")
    REFER=$(zfs get -H -o value referenced "$zvol")
    COMPRESS=$(zfs get -H -o value compression "$zvol")
    SYNC=$(zfs get -H -o value sync "$zvol")
    
    echo "  ${zvol##*/}:"
    echo "    Size: $SIZE, Used: $USED, Referenced: $REFER"
    echo "    Compression: $COMPRESS, Sync: $SYNC"
done

echo ""
echo "Safety Check:"
echo -n "  Sync writes: "
SYNC_DISABLED=$(zfs get -H -o value sync | grep -c "disabled" || echo "0")
if [ "$SYNC_DISABLED" -eq 0 ]; then
    echo "OK Enabled (safe)"
else
    echo "WARNING Some datasets have sync disabled!"
fi
EOF
chmod +x /usr/local/bin/zfs-status

#############################################
# Create safe tuning guide
#############################################
cat > /usr/local/bin/zfs-tune-guide << 'EOF'
#!/bin/bash
echo "=== Proxmox ZFS Tuning Guide ==="
echo ""
echo "Configuration already applied:"
echo "  OK ARC memory limited for VMs"
echo "  OK Autotrim enabled"
echo "  OK Atime disabled on data datasets"
echo "  OK Extended attributes optimized"
echo ""
echo "Proxmox-managed settings (change via GUI):"
echo "  • Compression (per-volume)"
echo "  • Thin provisioning (sparse)"
echo "  • Volblocksize (at creation)"
echo "  • Cache settings"
echo ""
echo "Settings kept at defaults for safety:"
echo "  • sync=standard (prevents data loss)"
echo "  • primarycache=all (better performance)"
echo "  • logbias=latency (better for mixed workloads)"
echo "  • recordsize=128k (default is optimal)"
echo ""
echo "To improve performance further (with UPS only):"
echo "  • Add SLOG device (ZIL on fast SSD)"
echo "  • Add L2ARC device (cache on SSD)"
echo "  • Consider special vdev for metadata"
echo ""
echo "Monitor performance:"
echo "  zpool iostat -v 2"
echo "  arc_summary"
echo "  zfs-status"
EOF
chmod +x /usr/local/bin/zfs-tune-guide

#############################################
# Summary
#############################################
echo -e "\n${GREEN}=== ZFS Configuration Complete ===${NC}"
echo ""
echo "Applied Settings:"
echo "  • ARC Memory:  ${ARC_MIN_GB}-${ARC_MAX_GB}GB (leaves $((TOTAL_RAM_GB - ARC_MAX_GB))GB for VMs)"
echo "  • Autotrim:    Enabled (SSD optimization)"
echo "  • Atime:       Disabled (reduces writes)"
echo "  • Xattr:       Optimized (sa mode)"
echo ""
echo "Preserved for Safety:"
echo "  • Sync:        Standard (data integrity)"
echo "  • Compression: Per-volume (Proxmox managed)"
echo "  • Cache:       Default (all data + metadata)"
echo ""
echo "Commands Available:"
echo -e "  • ${CYAN}zfs-status${NC}      - Check current status"
echo -e "  • ${CYAN}zfs-tune-guide${NC}  - Tuning recommendations"
echo -e "  • ${CYAN}arc_summary${NC}     - Detailed ARC statistics"
echo ""

# Show current status
CURRENT_ARC=$(awk '/^size/ {print $3}' /proc/spl/kstat/zfs/arcstats)
echo "Current Status:"
echo "  • ARC using: $((CURRENT_ARC / 1024 / 1024 / 1024))GB of ${ARC_MAX_GB}GB max"

# Check if trim is running
if zpool status | grep -q "trimming"; then
    echo "  • TRIM: Currently running"
else
    echo "  • TRIM: Idle (runs automatically)"
fi

echo ""
echo -e "${YELLOW}Note:${NC} This configuration prioritizes data safety."
echo "      No settings that could cause data loss were applied."
echo ""
echo -e "${GREEN}Done! Reboot recommended for full effect.${NC}"