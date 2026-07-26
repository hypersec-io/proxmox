#!/bin/bash

#############################################
# Unit tests for the conservative update policy
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
#   Prove the n-0.1 rule, on any machine. No Proxmox, no root, no apt, no
#   network. proxmox-update-policy.sh is sourced rather than executed, and the
#   pure version-arithmetic functions are driven directly.
#
#   This exists because the rule was silently wrong in production for months:
#   the pin was derived from pve-manager's version and applied to packages
#   using entirely different numbering, so it matched almost nothing. A bug
#   that shows up only as "the kernel upgraded when it should not have" needs
#   a test that fails loudly at commit time instead.
#
#   Integration coverage (does apt actually honour the generated file?) needs a
#   real PVE install -- see tests/nested-pve/README.md.
#
# Usage:
#   ./tests/test-update-policy.sh
#
#############################################

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY_SCRIPT="${SCRIPT_DIR}/../postinstall/proxmox-update-policy.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0

# The policy script returns early when sourced, before its root check, so this
# loads the functions without running anything and without needing root.
# shellcheck source=/dev/null
source "$POLICY_SCRIPT"

check() {
    # check <description> <expected> <actual>
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
echo -e "\n${CYAN}version_series${NC}"
#############################################

check "plain version"            "9.1"  "$(version_series 9.1.4)"
check "single trailing segment"  "9.1"  "$(version_series 9.1)"
check "debian revision"          "6.14" "$(version_series 6.14.11-4)"
check "pve suffix"               "10.1" "$(version_series 10.1.2-1~bpo12+pve1)"
check "epoch is stripped"        "4.1"  "$(version_series 3:4.1.1-1)"
check "non-numeric yields empty" ""     "$(version_series notaversion)"

#############################################
echo -e "\n${CYAN}series_list${NC}"
#############################################

check "distinct series, newest first" \
    $'9.2\n9.1' "$(series_list $'9.2.1\n9.2.0\n9.1.4')"
check "numeric sort, not lexical" \
    $'9.10\n9.9'  "$(series_list $'9.9.1\n9.10.0')"
check "epochs stripped" \
    "4.1" "$(series_list $'3:4.1.1-1')"
check "single series" \
    "9.1" "$(series_list $'9.1.4\n9.1.0')"

#############################################
echo -e "\n${CYAN}series_max -- numeric, not lexical${NC}"
#############################################

check "9.10 beats 9.9"  "9.10" "$(series_max 9.9 9.10)"
check "order agnostic"  "9.10" "$(series_max 9.10 9.9)"
check "equal"           "9.1"  "$(series_max 9.1 9.1)"
check "major wins"      "10.0" "$(series_max 9.9 10.0)"

#############################################
echo -e "\n${CYAN}resolve_target_series -- THE n-0.1 RULE${NC}"
#############################################

TWO_MINORS=$'9.2.1\n9.2.0\n9.1.4\n9.1.0'
ONE_MINOR=$'9.1.4\n9.1.0'

# The ordinary case: two minors on offer, take the older one.
check "n-0.1 when n-0.1 exists" \
    "9.1" "$(resolve_target_series "$TWO_MINORS" "9.1.4")"

# "unless the current version IS the only minor version": with nothing to step
# back to, pin to what is there. Pinning to a series the repo cannot serve
# would hold the host at its installed version forever, which is how a
# conservative policy quietly turns into "no security updates at all".
check "only one minor -> that minor" \
    "9.1" "$(resolve_target_series "$ONE_MINOR" "9.1.4")"

# The installed floor. Already on 9.2 and the repo's latest is 9.2: naive n-0.1
# says 9.1, which is a downgrade. Must clamp to installed.
check "installed floor beats n-0.1" \
    "9.2" "$(resolve_target_series "$TWO_MINORS" "9.2.1")"

# A host ahead of its own repo must stay put, never be walked back to what the
# repo happens to offer.
check "installed ahead of repo entirely" \
    "9.3" "$(resolve_target_series "$TWO_MINORS" "9.3.0")"

# Holding at the installed major is the conservative answer, not stepping the
# product back a major because the repo happens to still carry it.
check "never steps back a major below installed" \
    "9.1" "$(resolve_target_series $'10.0.1\n9.1.4' "9.1.4")"

# Fresh install, nothing installed yet.
check "no installed version" \
    "9.1" "$(resolve_target_series "$TWO_MINORS" "")"

# A .0-only repo cannot go below .0.
check "9.0 only" \
    "9.0" "$(resolve_target_series $'9.0.3\n9.0.1' "9.0.3")"

# Three minors: still exactly one step back, never two.
check "three minors steps back once" \
    "9.2" "$(resolve_target_series $'9.3.0\n9.2.2\n9.1.9' "9.1.9")"

# Package with its own scheme -- this is the case the old code got wrong.
check "qemu 11.x series" \
    "10.1" "$(resolve_target_series $'11.0.2\n10.1.2' "10.1.2")"

check "zfs 2.x series" \
    "2.3" "$(resolve_target_series $'2.4.3\n2.3.4' "2.3.4")"

check "epoch-carrying pbs client" \
    "4.1" "$(resolve_target_series $'3:4.2.3-1\n3:4.1.1-1' "3:4.1.1-1")"

# Empty input is a failure, not a silent empty pin.
check "empty version list fails" \
    "1" "$(resolve_target_series "" "9.1.4" >/dev/null; echo $?)"

#############################################
echo -e "\n${CYAN}regression: the 2026-07 production bug${NC}"
#############################################

# Every one of these packages was pinned to pve-manager's "9.1.*" and so was
# silently unpinned. Each must now resolve against its OWN series. If any of
# these ever returns something starting "9.1" again, the bug is back.
regression_case() {
    local pkg="$1" versions="$2" installed="$3" expected="$4"
    check "$pkg resolves to its own series" \
        "$expected" "$(resolve_target_series "$versions" "$installed")"
}

regression_case "pve-qemu-kvm"          $'11.0.2\n10.1.2' "10.1.2" "10.1"
regression_case "pve-container"         $'6.1.0\n6.0.12'  "6.0.12" "6.0"
regression_case "proxmox-backup-client" $'4.2.3\n4.1.1'   "4.1.1"  "4.1"
regression_case "zfsutils-linux"        $'2.4.3\n2.3.4'   "2.3.4"  "2.3"
regression_case "proxmox-widget-toolkit" $'5.1.0\n5.0.4'  "5.0.4"  "5.0"

#############################################
echo -e "\n${CYAN}real repository data${NC}"
#############################################

# Captured verbatim from `apt-cache madison pve-manager` against
# download.proxmox.com trixie/pve-no-subscription. Synthetic fixtures prove the
# arithmetic; this proves the arithmetic meets the shape the archive actually
# has. Note it carries BOTH series -- the CE repo does not keep only the
# current release, so the step back is genuinely reachable.
REAL_PVE_MANAGER=$'9.2.5\n9.2.4\n9.2.3\n9.2.2\n9.1.19\n9.1.18\n9.1.17\n9.1.16\n9.1.15\n9.1.14\n9.1.13\n9.1.12\n9.1.11\n9.1.9'

# A host installed at 9.1 holds at 9.1 and does NOT jump to 9.2. This is the
# rule doing its actual job.
check "9.1 host holds at 9.1, does not jump to 9.2" \
    "9.1" "$(resolve_target_series "$REAL_PVE_MANAGER" "9.1.19")"

# A host already at 9.2 stays at 9.2 -- the installed floor forbids walking a
# working host backwards just because an older series is still published.
check "9.2 host stays at 9.2" \
    "9.2" "$(resolve_target_series "$REAL_PVE_MANAGER" "9.2.5")"

# A fresh install with nothing present takes the conservative series.
check "fresh install takes 9.1" \
    "9.1" "$(resolve_target_series "$REAL_PVE_MANAGER" "")"

# Real pve-qemu-kvm data from the same repo: it is on its own 10.x/11.x series
# entirely, which is what the original implementation assumed away.
REAL_QEMU=$'11.0.2-2\n11.0.2-1\n11.0.0-4\n11.0.0-1\n10.2.1-2\n10.2.1-1\n10.1.2-7\n10.1.2-1\n10.0.2-4'
check "qemu 11 host holds at 11.0" \
    "11.0" "$(resolve_target_series "$REAL_QEMU" "11.0.2-2")"
check "qemu 10.1 host steps to 10.2" \
    "10.2" "$(resolve_target_series "$REAL_QEMU" "10.1.2-7")"

# Real zfsutils-linux data, including the Debian contrib build that carries a
# plain version alongside the -pve ones.
REAL_ZFS=$'2.4.3-pve1\n2.4.2-pve1\n2.4.1-pve2\n2.4.0-pve1\n2.3.4-pve1\n2.3.3-pve1\n2.3.2-2'
check "zfs 2.4 host holds at 2.4" \
    "2.4" "$(resolve_target_series "$REAL_ZFS" "2.4.3-pve1")"
check "zfs 2.3 host holds at 2.3" \
    "2.3" "$(resolve_target_series "$REAL_ZFS" "2.3.4-pve1")"

#############################################
echo -e "\n${CYAN}kernel ABI series${NC}"
#############################################

# get_kernel_series shells out to dpkg-query. Stub it on PATH so the ABI
# selection logic is testable off-host.
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

cat > "$STUB_DIR/dpkg-query" << 'STUB'
#!/bin/bash
# Emits what a PVE 9 host with two ABIs installed would report.
cat <<'PKGS'
proxmox-kernel-6.14
proxmox-kernel-6.14.11-4-pve-signed
proxmox-kernel-6.8
proxmox-kernel-helper
PKGS
STUB
chmod +x "$STUB_DIR/dpkg-query"

PATH_ORIG="$PATH"
PATH="$STUB_DIR:$PATH"
# Highest ABI meta wins; the -pve-signed image and the -helper package are not
# ABI metas and must not be selected.
check "picks highest ABI meta" "6.14" "$(get_kernel_series)"
PATH="$PATH_ORIG"

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
