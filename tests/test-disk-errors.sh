#!/bin/bash

#############################################
# Unit tests for drive error-recovery detection
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
#   Prove the two decisions that govern whether a drive gets its retry time
#   bounded, without needing the drive:
#
#     1. does this pool have redundancy?  (if not, bounding retries is HARMFUL)
#     2. does this drive support SCT ERC?  (if not, fall back to the kernel)
#
#   Both are parsed out of command output, so both are testable against real
#   captured output. The samples below are the actual shapes emitted by
#   zpool(8) and smartctl(8), including the Crucial BX500 and Samsung 860
#   responses recorded during the 2026-07-26 incident.
#
# Usage:
#   ./tests/test-disk-errors.sh
#
#############################################

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISK_SCRIPT="${SCRIPT_DIR}/../postinstall/proxmox-disk-errors.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0

# shellcheck source=/dev/null
source "$DISK_SCRIPT"

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
echo -e "\n${CYAN}pool_has_redundancy${NC}"
#############################################

RAIDZ1_STATUS='  pool: ssdbulk
 state: ONLINE
config:

	NAME                                   STATE     READ WRITE CKSUM
	ssdbulk                                ONLINE       0     0     0
	  raidz1-0                             ONLINE       0     0     0
	    ata-CT2000BX500SSD1_2224E63C9612   ONLINE       0     0     0
	    ata-CT2000BX500SSD1_2224E63C9613   ONLINE       0     0     0
	    ata-CT2000BX500SSD1_2224E63C9614   ONLINE       0     0     0'

MIRROR_STATUS='  pool: vmdata
 state: ONLINE
config:

	NAME             STATE     READ WRITE CKSUM
	vmdata           ONLINE       0     0     0
	  mirror-0       ONLINE       0     0     0
	    sdg          ONLINE       0     0     0
	    sdh          ONLINE       0     0     0
	  mirror-1       ONLINE       0     0     0
	    sde          ONLINE       0     0     0
	    sdf          ONLINE       0     0     0'

STRIPE_STATUS='  pool: scratch
 state: ONLINE
config:

	NAME        STATE     READ WRITE CKSUM
	scratch     ONLINE       0     0     0
	  sdb       ONLINE       0     0     0
	  sdc       ONLINE       0     0     0'

SINGLE_STATUS='  pool: rpool
 state: ONLINE
config:

	NAME        STATE     READ WRITE CKSUM
	rpool       ONLINE       0     0     0
	  nvme0n1p3 ONLINE       0     0     0'

RAIDZ2_STATUS='	NAME          STATE     READ WRITE CKSUM
	tank          ONLINE       0     0     0
	  raidz2-0    ONLINE       0     0     0
	    sda       ONLINE       0     0     0'

DRAID_STATUS='	NAME          STATE     READ WRITE CKSUM
	tank          ONLINE       0     0     0
	  draid1:2d:4c:0s-0  ONLINE  0     0     0
	    sda       ONLINE       0     0     0'

check "raidz1 is redundant"  "0" "$(pool_has_redundancy "$RAIDZ1_STATUS"; echo $?)"
check "raidz2 is redundant"  "0" "$(pool_has_redundancy "$RAIDZ2_STATUS"; echo $?)"
check "mirror is redundant"  "0" "$(pool_has_redundancy "$MIRROR_STATUS"; echo $?)"
check "draid is redundant"   "0" "$(pool_has_redundancy "$DRAID_STATUS"; echo $?)"

# These two are the safety gate. Bounding retries on a pool with no second copy
# tells the drive to abandon data nothing else holds -- strictly worse than
# waiting. A false positive here loses data.
check "plain stripe is NOT redundant" "1" "$(pool_has_redundancy "$STRIPE_STATUS"; echo $?)"
check "single disk is NOT redundant"  "1" "$(pool_has_redundancy "$SINGLE_STATUS"; echo $?)"

# A pool NAMED "mirror-of-stuff" or a disk whose id contains "raidz" must not
# be mistaken for a redundant vdev -- the match is anchored to the vdev column.
NAME_TRAP_STATUS='	NAME               STATE     READ WRITE CKSUM
	mirrorbackup       ONLINE       0     0     0
	  ata-raidz-fake   ONLINE       0     0     0'
check "pool/device named like a vdev is not redundant" \
    "1" "$(pool_has_redundancy "$NAME_TRAP_STATUS"; echo $?)"

#############################################
echo -e "\n${CYAN}scterc_supported / scterc_is_disabled${NC}"
#############################################

# Samsung 860 EVO/PRO: capable, but shipped switched off. This is the case that
# matters most -- the capability is present and doing nothing.
SAMSUNG_DISABLED='smartctl 7.4 2023-08-01 r5530 [x86_64-linux-6.14.11-4-pve] (local build)
Copyright (C) 2002-23, Bruce Allen, Christian Franke, www.smartmontools.org

SCT Error Recovery Control:
           Read: Disabled
          Write: Disabled'

SAMSUNG_ENABLED='SCT Error Recovery Control:
           Read:     70 (7.0 seconds)
          Write:     70 (7.0 seconds)'

# Crucial BX500: no SCT at all. This drive is why the outage happened -- its
# only possible backstop is the kernel command timeout.
BX500_UNSUPPORTED='smartctl 7.4 2023-08-01 r5530 [x86_64-linux-6.14.11-4-pve] (local build)
Copyright (C) 2002-23, Bruce Allen, Christian Franke, www.smartmontools.org

Warning: device does not support SCT Commands'

SCT_NO_ERC='SCT Commands not supported'

check "samsung disabled: supported"      "0" "$(scterc_supported "$SAMSUNG_DISABLED"; echo $?)"
check "samsung disabled: is disabled"    "0" "$(scterc_is_disabled "$SAMSUNG_DISABLED"; echo $?)"
check "samsung enabled: supported"       "0" "$(scterc_supported "$SAMSUNG_ENABLED"; echo $?)"
check "samsung enabled: not disabled"    "1" "$(scterc_is_disabled "$SAMSUNG_ENABLED"; echo $?)"
check "bx500: not supported"             "1" "$(scterc_supported "$BX500_UNSUPPORTED"; echo $?)"
check "SCT-but-no-ERC: not supported"    "1" "$(scterc_supported "$SCT_NO_ERC"; echo $?)"
check "empty output: not supported"      "1" "$(scterc_supported ""; echo $?)"

#############################################
echo -e "\n${CYAN}strip_partition_suffix${NC}"
#############################################

check "sata partition"      "sdc"      "$(strip_partition_suffix sdc1)"
check "sata whole disk"     "sdc"      "$(strip_partition_suffix sdc)"
check "double-letter dev"   "sdaa"     "$(strip_partition_suffix sdaa3)"
check "nvme partition"      "nvme0n1"  "$(strip_partition_suffix nvme0n1p3)"
check "nvme whole disk"     "nvme0n1"  "$(strip_partition_suffix nvme0n1)"
check "high partition num"  "sdc"      "$(strip_partition_suffix sdc12)"

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
