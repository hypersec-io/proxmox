#!/bin/bash

#############################################
# Unit tests for superseded-artefact detection
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
#   The cleanup script DELETES files, so its detection has to be exact in both
#   directions: never remove a legitimate config, always catch the junk. These
#   drive the classifiers against real captured content.
#
# Usage:
#   ./tests/test-cleanup.sh
#
#############################################

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANUP_SCRIPT="${SCRIPT_DIR}/../postinstall/proxmox-cleanup.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0

# shellcheck source=/dev/null
source "$CLEANUP_SCRIPT"

check() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        printf '  %bok%b   %s\n' "$GREEN" "$NC" "$desc"
    else
        FAIL=$((FAIL + 1))
        printf '  %bFAIL%b %s\n' "$RED" "$NC" "$desc"
        printf '       expected: %s\n' "$expected"
        printf '       actual:   %s\n' "$actual"
    fi
}

#############################################
echo -e "\n${CYAN}looks_like_sysctl_dump${NC}"
#############################################

# The head of the real 1192-line file found in /etc/sysctl.d.
REAL_DUMP='abi.vsyscall32 = 1
debug.exception-trace = 1
debug.kprobes-optimization = 1
dev.cdrom.autoclose = 1
dev.cdrom.info = CD-ROM information, Id: cdrom.c 3.20 2003/12/17
dev.cdrom.info =
dev.hpet.max-user-freq = 64
kernel.random.boot_id = 3f2504e0-4f89-11d3-9a0c-0305e82c3301
kernel.random.entropy_avail = 256'

# The current, legitimate config. Must NEVER be classified as a dump.
REAL_CONFIG='# Proxmox VM/Container Configuration

# Memory Management
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.dirty_background_ratio=5

# Network - Basic safe optimizations
net.core.netdev_max_backlog=8192
net.ipv4.tcp_fin_timeout=30'

NETWORK_CONFIG='# Proxmox Network Configuration - 10 Gigabit
net.core.rmem_max = 33554432
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_forward = 1'

check "real sysctl -a dump detected"    "0" "$(looks_like_sysctl_dump "$REAL_DUMP"; echo $?)"
check "legitimate config is not a dump" "1" "$(looks_like_sysctl_dump "$REAL_CONFIG"; echo $?)"
check "network config is not a dump"    "1" "$(looks_like_sysctl_dump "$NETWORK_CONFIG"; echo $?)"
check "empty is not a dump"             "1" "$(looks_like_sysctl_dump ""; echo $?)"

#############################################
echo -e "\n${CYAN}has_readonly_keys${NC}"
#############################################

# The real content of 99-proxmox-tweaks.conf. entropy_avail is a statistic,
# not a setting: "sysctl: setting key ...: Operation not permitted", every boot.
TWEAKS_WITH_READONLY='# Proxmox tweaks
vm.swappiness=10
kernel.random.entropy_avail=4096
net.ipv4.tcp_keepalive_time=600'

check "entropy_avail detected"       "0" "$(has_readonly_keys "$TWEAKS_WITH_READONLY"; echo $?)"
check "clean config has none"        "1" "$(has_readonly_keys "$REAL_CONFIG"; echo $?)"
check "network config has none"      "1" "$(has_readonly_keys "$NETWORK_CONFIG"; echo $?)"
check "spaced assignment detected"   "0" "$(has_readonly_keys 'kernel.random.entropy_avail = 4096'; echo $?)"
check "leading whitespace detected"  "0" "$(has_readonly_keys '   kernel.random.entropy_avail=4096'; echo $?)"

# A COMMENTED-OUT read-only key is inert and must not condemn the file.
check "commented-out key ignored" \
    "1" "$(has_readonly_keys '# kernel.random.entropy_avail=4096'; echo $?)"

# A writable key whose name merely contains a read-only one must not match.
check "writable neighbour not matched" \
    "1" "$(has_readonly_keys 'kernel.random.write_wakeup_threshold=1024'; echo $?)"

#############################################
echo -e "\n${CYAN}sysctl_keys / orphaned_keys${NC}"
#############################################

check "extracts settable keys" \
    $'net.ipv4.tcp_fin_timeout\nvm.swappiness' \
    "$(sysctl_keys $'vm.swappiness=10\nnet.ipv4.tcp_fin_timeout=30')"

# A commented key is inert; counting it would make a file look like it still
# carried a setting it does not.
check "ignores commented keys" \
    "vm.swappiness" \
    "$(sysctl_keys $'vm.swappiness=10\n# kernel.random.entropy_avail=4096')"

check "tolerates spaces around =" \
    "net.core.rmem_max" \
    "$(sysctl_keys 'net.core.rmem_max = 33554432')"

# The real content from the live host. Removing the tweaks file because a
# newer generation exists would have dropped five keys the replacement has no
# equivalent for -- silently, and with only a backup to notice it by.
HOST_TWEAKS='vm.swappiness=10
vm.dirty_background_ratio=5
vm.dirty_ratio=10
vm.dirty_expire_centisecs=12000
vm.dirty_writeback_centisecs=1500
net.core.netdev_max_backlog=8192
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_probes=3
net.ipv4.tcp_keepalive_intvl=30
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=512'

HOST_OPTIMIZE='vm.swappiness=10
vm.vfs_cache_pressure=50
vm.dirty_background_ratio=5
vm.dirty_ratio=10
net.core.netdev_max_backlog=8192
net.core.somaxconn=8192
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_tw_reuse=1
fs.file-max=2097152
fs.inotify.max_user_watches=524288'

check "finds the five keys the replacement lacks" \
    $'fs.inotify.max_user_instances\nnet.ipv4.tcp_keepalive_intvl\nnet.ipv4.tcp_keepalive_probes\nvm.dirty_expire_centisecs\nvm.dirty_writeback_centisecs' \
    "$(orphaned_keys "$HOST_TWEAKS" "$HOST_OPTIMIZE")"

# A genuinely superseded file has nothing the replacement lacks, and must
# still be removable -- the guard must not block every cleanup.
check "fully covered file has no orphans" \
    "" "$(orphaned_keys $'vm.swappiness=10\nvm.dirty_ratio=10' "$HOST_OPTIMIZE")"

check "empty old file has no orphans" \
    "" "$(orphaned_keys "" "$HOST_OPTIMIZE")"

# A differing VALUE on a shared key is not an orphan: the replacement still
# sets it, so nothing is lost by removing the older file.
check "differing value is not an orphan" \
    "" "$(orphaned_keys 'net.ipv4.tcp_keepalive_time=600' "$HOST_OPTIMIZE")"

#############################################
echo -e "\n${CYAN}network_tier_from_path${NC}"
#############################################

check "10gbe" "10gbe" "$(network_tier_from_path /etc/sysctl.d/99-proxmox-network-10gbe.conf)"
check "1gbe"  "1gbe"  "$(network_tier_from_path /etc/sysctl.d/99-proxmox-network-1gbe.conf)"
check "200gbe" "200gbe" "$(network_tier_from_path /etc/sysctl.d/99-proxmox-network-200gbe.conf)"
check "non-tier file yields empty" "" "$(network_tier_from_path /etc/sysctl.d/98-proxmox-optimize.conf)"

# The reason stale tier files matter: filename sort, not the chosen tier,
# decides which wins. "1gbe" sorts after "10gbe", so running 10gbe and then
# 1gbe leaves the host on 1gbe buffers -- and running 1gbe then 10gbe ALSO
# leaves it on 1gbe.
check "sort order puts 1gbe last (the trap)" \
    "/etc/sysctl.d/99-proxmox-network-1gbe.conf" \
    "$(printf '%s\n' /etc/sysctl.d/99-proxmox-network-10gbe.conf /etc/sysctl.d/99-proxmox-network-1gbe.conf | sort | tail -1)"

#############################################
echo -e "\n${CYAN}Summary${NC}"
#############################################

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}All ${PASS} checks passed.${NC}"
    exit 0
fi
echo -e "${RED}${FAIL} of $((PASS + FAIL)) checks failed.${NC}"
exit 1
