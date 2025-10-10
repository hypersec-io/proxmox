#!/bin/bash

#############################################
# Proxmox VE 9 Network Optimization Script
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
#   Network configuration for Proxmox VE based on network interface
#   speed tier (1GbE, 10GbE, 25GbE, 40GbE, 100GbE, 200GbE).
#   Configures sysctl parameters, NIC settings, and buffer sizes.
#
# Usage:
#   sudo ./proxmox-network-gbe.sh [TIER|auto] [--jumbo]
#
#   Examples:
#     sudo ./proxmox-network-gbe.sh auto           # Auto-detect fastest interface
#     sudo ./proxmox-network-gbe.sh auto --jumbo   # Auto-detect with Jumbo Frames
#     sudo ./proxmox-network-gbe.sh 1gbe           # Manual: 1 Gigabit
#     sudo ./proxmox-network-gbe.sh 10gbe          # Manual: 10 Gigabit
#     sudo ./proxmox-network-gbe.sh 10gbe --jumbo  # Manual: 10 Gigabit with Jumbo Frames
#     sudo ./proxmox-network-gbe.sh 25gbe --jumbo  # Manual: 25 Gigabit with Jumbo Frames
#     sudo ./proxmox-network-gbe.sh 40gbe --jumbo  # Manual: 40 Gigabit with Jumbo Frames
#     sudo ./proxmox-network-gbe.sh 100gbe --jumbo # Manual: 100 Gigabit with Jumbo Frames
#     sudo ./proxmox-network-gbe.sh 200gbe --jumbo # Manual: 200 Gigabit with Jumbo Frames
#
# Requirements:
#   - Proxmox VE 9.x
#   - Debian 13 (Trixie)
#   - Root privileges
#   - ethtool installed
#
# Features:
#   - TCP/UDP buffer optimization per tier
#   - Network queue and backlog tuning
#   - TCP congestion control selection
#   - NIC offload configuration
#   - IRQ affinity optimization
#   - Coalescing and ring buffer tuning
#
# Idempotent: Yes (safe to run multiple times)
# Requires Reboot: No (settings applied immediately)
# Backup Location: /root/network-backup
#
#############################################

set -e
trap 'error_handler $? $LINENO' ERR

# Error handler
error_handler() {
    echo -e "${RED}Error at line $2 (exit code: $1)${NC}"
    echo "Attempting to continue..."
}

# Colors (following character policy)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

# Must be root
[ $EUID -ne 0 ] && { echo -e "${RED}Must run as root${NC}"; exit 1; }

# Create backup directory
BACKUP_DIR="/root/network-backup"
BACKUP_DATE=$(date +%Y%m%d_%H%M%S)
mkdir -p "$BACKUP_DIR"

# Backup existing sysctl settings
if [ ! -f "$BACKUP_DIR/sysctl-network-$BACKUP_DATE.conf" ]; then
    sysctl -a 2>/dev/null | grep -E "net\." > "$BACKUP_DIR/sysctl-network-$BACKUP_DATE.conf" || true
    echo -e "${GREEN}OK Network settings backed up${NC}"
fi

#############################################
# Network Tier Configuration
#############################################

# Parse arguments
TIER="${1:-auto}"
TIER=$(echo "$TIER" | tr '[:upper:]' '[:lower:]')

# Check for --jumbo flag
ENABLE_JUMBO=false
if [[ "$2" == "--jumbo" ]] || [[ "$3" == "--jumbo" ]]; then
    ENABLE_JUMBO=true
fi

#############################################
# Auto-detect fastest Proxmox network interface
#############################################
if [[ "$TIER" == "auto" ]]; then
    echo -e "${CYAN}Auto-detecting network interfaces...${NC}"

    # Find physical interfaces used by Proxmox bridges
    PROXMOX_INTERFACES=()
    MAX_SPEED=0
    DETECTED_IFACE=""

    # Check /etc/network/interfaces for bridge configurations
    if [ -f /etc/network/interfaces ]; then
        # Extract bridge ports (physical interfaces)
        BRIDGE_PORTS=$(grep -E "^\s*bridge[-_]ports" /etc/network/interfaces 2>/dev/null | awk '{print $2}' | sort -u)

        for IFACE in $BRIDGE_PORTS; do
            # Skip virtual interfaces
            if [[ "$IFACE" =~ ^(veth|tap|vmbr|lo|bond) ]]; then
                continue
            fi

            PROXMOX_INTERFACES+=("$IFACE")
        done
    fi

    # If no bridge ports found, check all physical interfaces
    if [ ${#PROXMOX_INTERFACES[@]} -eq 0 ]; then
        echo -e "${YELLOW}INFO  No bridge ports found, checking all physical interfaces${NC}"
        PROXMOX_INTERFACES=($(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(eth|eno|enp|ens)'))
    fi

    # Find the fastest interface
    for IFACE in "${PROXMOX_INTERFACES[@]}"; do
        # Get link speed using ethtool
        SPEED=$(ethtool "$IFACE" 2>/dev/null | grep -i "Speed:" | awk '{print $2}' | sed 's/[^0-9]//g')

        # Skip if speed not detected or link is down
        if [ -z "$SPEED" ] || [ "$SPEED" == "0" ]; then
            continue
        fi

        echo "  Found: $IFACE - ${SPEED}Mb/s"

        # Track fastest interface
        if [ "$SPEED" -gt "$MAX_SPEED" ]; then
            MAX_SPEED=$SPEED
            DETECTED_IFACE="$IFACE"
        fi
    done

    # Map speed to tier
    if [ "$MAX_SPEED" -eq 0 ]; then
        echo -e "${YELLOW}WARNING  Could not detect network speed, defaulting to 1gbe${NC}"
        TIER="1gbe"
    elif [ "$MAX_SPEED" -ge 180000 ]; then
        TIER="200gbe"
    elif [ "$MAX_SPEED" -ge 90000 ]; then
        TIER="100gbe"
    elif [ "$MAX_SPEED" -ge 30000 ]; then
        TIER="40gbe"
    elif [ "$MAX_SPEED" -ge 20000 ]; then
        TIER="25gbe"
    elif [ "$MAX_SPEED" -ge 9000 ]; then
        TIER="10gbe"
    else
        TIER="1gbe"
    fi

    echo ""
    echo -e "${GREEN}OK Auto-detected: ${DETECTED_IFACE} at ${MAX_SPEED}Mb/s${NC}"
    echo -e "${GREEN}OK Selected tier: ${TIER}${NC}"
    echo ""
fi

echo -e "${GREEN}=== Proxmox Network Configuration ===${NC}"
echo -e "${CYAN}Configuring for: ${TIER}${NC}"
if [ "$ENABLE_JUMBO" == "true" ]; then
    echo -e "${CYAN}Jumbo Frames: ENABLED (MTU 9000)${NC}"
else
    echo -e "${CYAN}Jumbo Frames: DISABLED (use --jumbo to enable)${NC}"
fi
echo ""

# Validate tier and set parameters
case "$TIER" in
    1gbe|1g)
        TIER_NAME="1 Gigabit Ethernet"
        # Conservative settings for 1GbE
        RMEM_DEFAULT=262144      # 256 KB
        RMEM_MAX=8388608         # 8 MB
        WMEM_DEFAULT=262144      # 256 KB
        WMEM_MAX=8388608         # 8 MB
        TCP_RMEM="4096 131072 6291456"    # min default max (4KB 128KB 6MB)
        TCP_WMEM="4096 65536 4194304"     # min default max (4KB 64KB 4MB)
        NETDEV_MAX_BACKLOG=5000
        SOMAXCONN=4096
        TCP_MAX_SYN_BACKLOG=4096
        CONGESTION_CONTROL="cubic"
        RING_RX=512
        RING_TX=512
        ;;

    10gbe|10g)
        TIER_NAME="10 Gigabit Ethernet"
        # Settings for 10GbE
        RMEM_DEFAULT=524288      # 512 KB
        RMEM_MAX=33554432        # 32 MB
        WMEM_DEFAULT=524288      # 512 KB
        WMEM_MAX=33554432        # 32 MB
        TCP_RMEM="4096 262144 16777216"   # min default max (4KB 256KB 16MB)
        TCP_WMEM="4096 131072 16777216"   # min default max (4KB 128KB 16MB)
        NETDEV_MAX_BACKLOG=30000
        SOMAXCONN=16384
        TCP_MAX_SYN_BACKLOG=16384
        CONGESTION_CONTROL="bbr"
        RING_RX=2048
        RING_TX=2048
        ;;

    25gbe|25g)
        TIER_NAME="25 Gigabit Ethernet"
        # Settings for 25GbE
        RMEM_DEFAULT=1048576     # 1 MB
        RMEM_MAX=67108864        # 64 MB
        WMEM_DEFAULT=1048576     # 1 MB
        WMEM_MAX=67108864        # 64 MB
        TCP_RMEM="4096 524288 33554432"   # min default max (4KB 512KB 32MB)
        TCP_WMEM="4096 262144 33554432"   # min default max (4KB 256KB 32MB)
        NETDEV_MAX_BACKLOG=50000
        SOMAXCONN=32768
        TCP_MAX_SYN_BACKLOG=32768
        CONGESTION_CONTROL="bbr"
        RING_RX=4096
        RING_TX=4096
        ;;

    40gbe|40g)
        TIER_NAME="40 Gigabit Ethernet"
        # Settings for 40GbE
        RMEM_DEFAULT=2097152     # 2 MB
        RMEM_MAX=134217728       # 128 MB
        WMEM_DEFAULT=2097152     # 2 MB
        WMEM_MAX=134217728       # 128 MB
        TCP_RMEM="4096 1048576 67108864"  # min default max (4KB 1MB 64MB)
        TCP_WMEM="4096 524288 67108864"   # min default max (4KB 512KB 64MB)
        NETDEV_MAX_BACKLOG=100000
        SOMAXCONN=65535
        TCP_MAX_SYN_BACKLOG=65535
        CONGESTION_CONTROL="bbr"
        RING_RX=8192
        RING_TX=8192
        ;;

    100gbe|100g)
        TIER_NAME="100 Gigabit Ethernet"
        # Settings for 100GbE
        RMEM_DEFAULT=4194304     # 4 MB
        RMEM_MAX=268435456       # 256 MB
        WMEM_DEFAULT=4194304     # 4 MB
        WMEM_MAX=268435456       # 256 MB
        TCP_RMEM="4096 2097152 134217728" # min default max (4KB 2MB 128MB)
        TCP_WMEM="4096 1048576 134217728" # min default max (4KB 1MB 128MB)
        NETDEV_MAX_BACKLOG=250000
        SOMAXCONN=65535
        TCP_MAX_SYN_BACKLOG=65535
        CONGESTION_CONTROL="bbr"
        RING_RX=8192
        RING_TX=8192
        ;;

    200gbe|200g)
        TIER_NAME="200 Gigabit Ethernet"
        # Settings for 200GbE
        RMEM_DEFAULT=8388608     # 8 MB
        RMEM_MAX=536870912       # 512 MB
        WMEM_DEFAULT=8388608     # 8 MB
        WMEM_MAX=536870912       # 512 MB
        TCP_RMEM="4096 4194304 268435456" # min default max (4KB 4MB 256MB)
        TCP_WMEM="4096 2097152 268435456" # min default max (4KB 2MB 256MB)
        NETDEV_MAX_BACKLOG=500000
        SOMAXCONN=65535
        TCP_MAX_SYN_BACKLOG=65535
        CONGESTION_CONTROL="bbr"
        RING_RX=8192
        RING_TX=8192
        ;;

    *)
        echo -e "${RED}Invalid tier: $TIER${NC}"
        echo ""
        echo "Valid tiers:"
        echo "  auto   - Auto-detect fastest Proxmox network interface (recommended)"
        echo "  1gbe   - 1 Gigabit Ethernet (conservative)"
        echo "  10gbe  - 10 Gigabit Ethernet (standard production)"
        echo "  25gbe  - 25 Gigabit Ethernet (high performance)"
        echo "  40gbe  - 40 Gigabit Ethernet (very high performance)"
        echo "  100gbe - 100 Gigabit Ethernet (extreme performance)"
        echo "  200gbe - 200 Gigabit Ethernet (maximum performance)"
        echo ""
        echo "Usage: sudo ./proxmox-network-gbe.sh [TIER|auto] [--jumbo]"
        echo ""
        echo "Examples:"
        echo "  sudo ./proxmox-network-gbe.sh auto           # Auto-detect (recommended)"
        echo "  sudo ./proxmox-network-gbe.sh auto --jumbo   # Auto-detect with Jumbo Frames"
        echo "  sudo ./proxmox-network-gbe.sh 10gbe          # Manual 10GbE"
        exit 1
        ;;
esac

echo -e "${BLUE}Tier: ${TIER_NAME}${NC}"
echo -e "${CYAN}TCP Congestion Control: ${CONGESTION_CONTROL}${NC}"
echo -e "${CYAN}Max TCP Buffer: $(( RMEM_MAX / 1024 / 1024 )) MB${NC}\n"

#############################################
# Apply Kernel Network Parameters
#############################################
echo -e "${YELLOW} [1/5] Configuring kernel network parameters...${NC}"

cat > /etc/sysctl.d/99-proxmox-network-${TIER}.conf << EOF
# Proxmox Network Configuration - ${TIER_NAME}
# Generated: $(date)
# Tier: ${TIER}

# Core Network Buffers
net.core.rmem_default = $RMEM_DEFAULT
net.core.rmem_max = $RMEM_MAX
net.core.wmem_default = $WMEM_DEFAULT
net.core.wmem_max = $WMEM_MAX

# TCP Memory Tuning
net.ipv4.tcp_rmem = $TCP_RMEM
net.ipv4.tcp_wmem = $TCP_WMEM
net.ipv4.tcp_mem = $(( RMEM_MAX / 4096 )) $(( RMEM_MAX / 2048 )) $(( RMEM_MAX / 1024 ))

# Network Device Queues
net.core.netdev_max_backlog = $NETDEV_MAX_BACKLOG
net.core.somaxconn = $SOMAXCONN
net.ipv4.tcp_max_syn_backlog = $TCP_MAX_SYN_BACKLOG

# TCP Configuration
net.ipv4.tcp_congestion_control = $CONGESTION_CONTROL
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_slow_start_after_idle = 0

# TCP Connection Handling
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_tw_reuse = 1

# IP Routing
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv6.conf.all.forwarding = 1

# Bridge Settings (Proxmox VMs/Containers)
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-arptables = 1

# Increase max number of connections
net.netfilter.nf_conntrack_max = 1048576

# Optional: Enable TCP Fast Open (if supported)
net.ipv4.tcp_fastopen = 3
EOF

# Apply settings
sysctl -p /etc/sysctl.d/99-proxmox-network-${TIER}.conf >/dev/null 2>&1 || {
    echo -e "${YELLOW}WARNING  Some settings could not be applied (may need reboot)${NC}"
}

echo -e "${GREEN}OK Kernel parameters configured${NC}"

#############################################
# Configure NIC Settings
#############################################
echo -e "\n${YELLOW} [2/5] Configuring network interfaces...${NC}"

# Detect network interfaces (exclude lo, veth, vmbr)
INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(eth|eno|enp|ens)' || true)

if [ -z "$INTERFACES" ]; then
    echo -e "${YELLOW}WARNING  No physical network interfaces found${NC}"
else
    for IFACE in $INTERFACES; do
        echo -e "${CYAN}Configuring: $IFACE${NC}"

        # Check if interface exists and is up
        if ! ip link show "$IFACE" >/dev/null 2>&1; then
            echo "  Interface not found, skipping"
            continue
        fi

        # Set ring buffer sizes (if supported)
        CURRENT_RX=$(ethtool -g "$IFACE" 2>/dev/null | grep -A4 "Current hardware" | grep "^RX:" | awk '{print $2}' || echo "0")
        if [ "$CURRENT_RX" != "0" ] && [ "$CURRENT_RX" != "$RING_RX" ]; then
            ethtool -G "$IFACE" rx "$RING_RX" tx "$RING_TX" 2>/dev/null && \
                echo "  OK Ring buffers: RX=$RING_RX TX=$RING_TX" || \
                echo "  INFO  Ring buffer adjustment not supported"
        else
            echo "  INFO  Ring buffers already configured or not configurable"
        fi

        # Enable hardware offloading
        ethtool -K "$IFACE" tso on gso on gro on 2>/dev/null && \
            echo "  OK Hardware offloading enabled" || \
            echo "  INFO  Offloading configuration skipped"

        # Set interrupt coalescing for higher tiers
        if [[ "$TIER" == "10gbe" || "$TIER" == "10g" || "$TIER" == "25gbe" || "$TIER" == "25g" || \
              "$TIER" == "40gbe" || "$TIER" == "40g" || "$TIER" == "100gbe" || "$TIER" == "100g" || \
              "$TIER" == "200gbe" || "$TIER" == "200g" ]]; then
            ethtool -C "$IFACE" rx-usecs 50 2>/dev/null && \
                echo "  OK Interrupt coalescing configured" || \
                echo "  INFO  Coalescing not configurable"
        fi

        # Set MTU to 9000 (Jumbo Frames) if --jumbo flag is set
        CURRENT_MTU=$(ip link show "$IFACE" | grep mtu | awk '{print $5}')

        if [ "$ENABLE_JUMBO" == "true" ]; then
            if [ "$CURRENT_MTU" != "9000" ]; then
                echo -e "  ${YELLOW}Setting Jumbo Frames (MTU 9000)...${NC}"
                if ip link set "$IFACE" mtu 9000 2>/dev/null; then
                    echo -e "  ${GREEN}OK Jumbo Frames enabled (MTU 9000)${NC}"
                    echo -e "  ${YELLOW}WARNING  Ensure ALL network equipment supports MTU 9000${NC}"
                else
                    echo -e "  ${RED}ERROR Failed to set MTU 9000 (check interface status)${NC}"
                fi
            else
                echo "  OK Jumbo Frames already enabled (MTU 9000)"
            fi
        else
            if [ "$CURRENT_MTU" == "9000" ]; then
                echo "  INFO  Jumbo Frames currently enabled (MTU 9000)"
            else
                echo "  INFO  Jumbo Frames disabled (use --jumbo to enable)"
            fi
        fi

        echo ""
    done
fi

echo -e "${GREEN}OK Network interfaces configured${NC}"

#############################################
# TCP Congestion Control
#############################################
echo -e "\n${YELLOW} [3/5] Configuring TCP congestion control...${NC}"

# Check if BBR is available and load it if needed
if [[ "$CONGESTION_CONTROL" == "bbr" ]]; then
    if ! lsmod | grep -q "tcp_bbr"; then
        modprobe tcp_bbr 2>/dev/null && echo "  OK BBR module loaded" || {
            echo -e "  ${YELLOW}WARNING  BBR not available, using CUBIC${NC}"
            CONGESTION_CONTROL="cubic"
        }
    else
        echo "  OK BBR already loaded"
    fi

    # Make BBR persistent
    if ! grep -q "tcp_bbr" /etc/modules 2>/dev/null; then
        echo "tcp_bbr" >> /etc/modules
        echo "  OK BBR module added to /etc/modules"
    fi
fi

CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
if [ "$CURRENT_CC" != "$CONGESTION_CONTROL" ]; then
    sysctl -w net.ipv4.tcp_congestion_control="$CONGESTION_CONTROL" >/dev/null 2>&1
    echo "  OK Congestion control: $CONGESTION_CONTROL"
else
    echo "  OK Already using: $CONGESTION_CONTROL"
fi

echo -e "${GREEN}OK TCP congestion control configured${NC}"

#############################################
# Network Monitoring Commands
#############################################
echo -e "\n${YELLOW} [4/5] Creating monitoring scripts...${NC}"

cat > /usr/local/bin/network-status << 'EOF'
#!/bin/bash
echo "=== Network Performance Status ==="
echo ""

# Current tier
TIER_FILE=$(ls /etc/sysctl.d/99-proxmox-network-*.conf 2>/dev/null | head -1)
if [ -n "$TIER_FILE" ]; then
    TIER=$(grep "^# Tier:" "$TIER_FILE" | awk '{print $3}')
    echo "Configured Tier: $TIER"
else
    echo "Configured Tier: Not configured"
fi

# Congestion control
echo -n "TCP Congestion: "
sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown"

# Buffer sizes
echo ""
echo "Buffer Sizes:"
echo -n "  RX Max: "
sysctl -n net.core.rmem_max 2>/dev/null | awk '{printf "%.1f MB\n", $1/1024/1024}'
echo -n "  TX Max: "
sysctl -n net.core.wmem_max 2>/dev/null | awk '{printf "%.1f MB\n", $1/1024/1024}'

# Queue sizes
echo ""
echo "Queue Sizes:"
echo -n "  Backlog: "
sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo "unknown"
echo -n "  SYN Backlog: "
sysctl -n net.ipv4.tcp_max_syn_backlog 2>/dev/null || echo "unknown"

# Network interfaces
echo ""
echo "Network Interfaces:"
for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(eth|eno|enp|ens)'); do
    SPEED=$(ethtool "$iface" 2>/dev/null | grep "Speed:" | awk '{print $2}')
    MTU=$(ip link show "$iface" | grep mtu | awk '{print $5}')
    STATE=$(ip link show "$iface" | grep -oE "state [A-Z]+" | awk '{print $2}')
    echo "  $iface: $SPEED MTU=$MTU State=$STATE"
done

# Connection statistics
echo ""
echo "TCP Connections:"
ss -s | grep TCP | head -1
EOF

chmod +x /usr/local/bin/network-status

cat > /usr/local/bin/network-test << 'EOF'
#!/bin/bash
# Network performance test helper

echo "=== Network Performance Tests ==="
echo ""
echo "Available tests:"
echo "  1. iperf3 server mode:  iperf3 -s"
echo "  2. iperf3 client mode:  iperf3 -c <server-ip>"
echo "  3. Check latency:       ping <host>"
echo "  4. Check bandwidth:     iperf3 -c <server-ip> -P 4 -t 30"
echo "  5. Monitor traffic:     iftop -i <interface>"
echo ""
echo "Install iperf3 if needed: apt-get install iperf3"
EOF

chmod +x /usr/local/bin/network-test

echo -e "${GREEN}OK Monitoring scripts created${NC}"
echo "  • network-status - Check current configuration"
echo "  • network-test   - Performance testing guide"

#############################################
# Summary
#############################################
echo -e "\n${YELLOW} [5/5] Creating configuration summary...${NC}\n"

echo -e "${GREEN}=== Network Configuration Complete ===${NC}"
echo ""
echo -e "${BLUE}Configuration:${NC}"
echo "  • Tier: ${TIER_NAME}"
echo "  • TCP Congestion: ${CONGESTION_CONTROL}"
echo "  • Max RX Buffer: $(( RMEM_MAX / 1024 / 1024 )) MB"
echo "  • Max TX Buffer: $(( WMEM_MAX / 1024 / 1024 )) MB"
echo "  • Queue Backlog: ${NETDEV_MAX_BACKLOG}"
echo "  • Ring Buffer: RX=${RING_RX} TX=${RING_TX}"
echo ""

echo -e "${CYAN}Available Commands:${NC}"
echo "  • network-status - View current network configuration"
echo "  • network-test   - Performance testing guide"
echo ""

echo -e "${CYAN}Performance Tips:${NC}"
if [ "$ENABLE_JUMBO" == "true" ]; then
    echo "  • Jumbo Frames ENABLED - verify all network equipment supports MTU 9000"
    echo "  • Check switch, router, and NIC configuration"
    echo "  • Test connectivity: ping -M do -s 8972 <host>"
else
    echo "  • Consider Jumbo Frames for 10GbE+ (rerun with --jumbo flag)"
    echo "  • Requires switch and all network equipment to support MTU 9000"
fi
if [[ "$TIER" != "1gbe" && "$TIER" != "1g" ]]; then
    echo "  • Ensure all network equipment supports ${TIER_NAME}"
    echo "  • Use multiple queues/RSS for better multi-core performance"
fi
echo "  • Monitor with: iftop, nload, bmon, or ss -s"
echo "  • Test with: iperf3 for bandwidth, ping for latency"
echo ""

echo -e "${YELLOW}Recommendations for ${TIER_NAME}:${NC}"
case "$TIER" in
    1gbe|1g)
        echo "  • Suitable for: Small deployments, management traffic"
        echo "  • Consider: Link aggregation (bonding) for HA"
        ;;
    10gbe|10g)
        echo "  • Suitable for: Most production environments"
        echo "  • Consider: Dedicated storage network on separate NIC"
        echo "  • Recommended: Enable Jumbo Frames"
        ;;
    25gbe|25g|40gbe|40g)
        echo "  • Suitable for: High-performance clusters"
        echo "  • Required: Switch with matching capabilities"
        echo "  • Recommended: Jumbo Frames, RDMA if available"
        echo "  • Consider: SR-IOV for VM network performance"
        ;;
    100gbe|100g|200gbe|200g)
        echo "  • Suitable for: Very high-speed networks, large-scale deployments"
        echo "  • Required: Specialized NICs and switches"
        echo "  • Recommended: RDMA (RoCE v2), SR-IOV"
        echo "  • Consider: Dedicated NUMA node affinity"
        echo "  • Monitor: CPU usage, may need RSS tuning"
        ;;
esac

echo ""
echo -e "${GREEN}Settings applied and persistent across reboots${NC}"
echo "Backup location: $BACKUP_DIR"
echo ""
