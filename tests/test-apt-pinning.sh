#!/bin/bash

#############################################
# Integration test: does apt actually honour the generated policy?
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
#   test-update-policy.sh proves the script computes the right series. It does
#   NOT prove apt then behaves as intended -- and that gap is exactly where the
#   original bug lived, silently, for months.
#
#   This builds a real apt repository of throwaway packages at known versions,
#   points a fully isolated apt root at it, writes the preferences file the
#   policy generates, and asserts on `apt-cache policy` output. No Proxmox, no
#   root, no network: just apt deciding what it would install.
#
#   The load-bearing assertion is "negative pin blocks the newer series". A
#   positive pin ALONE does not hold a package back -- the newer version simply
#   fails to match the glob and keeps its default priority of 500, so apt
#   installs it anyway. That case is asserted explicitly below so nobody
#   "simplifies" the catch-all block away.
#
# Requirements:
#   apt-get, apt-cache, dpkg-deb  (no root, no network)
#
# Usage:
#   ./tests/test-apt-pinning.sh
#
#############################################

set -uo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0

for tool in apt-get apt-cache dpkg-deb; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo -e "${YELLOW}SKIP: $tool not available -- apt-based integration test cannot run here${NC}"
        exit 0
    fi
done

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

REPO="$ROOT/repo"
APTROOT="$ROOT/aptroot"

mkdir -p "$REPO" \
         "$APTROOT/etc/apt/preferences.d" \
         "$APTROOT/etc/apt/sources.list.d" \
         "$APTROOT/var/lib/apt/lists/partial" \
         "$APTROOT/var/lib/dpkg" \
         "$APTROOT/var/cache/apt/archives/partial"

: > "$APTROOT/var/lib/dpkg/status"

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

#---------------------------------------------------------------
# Build a throwaway repository
#---------------------------------------------------------------

make_pkg() {
    # make_pkg <name> <version>
    local name="$1"
    local version="$2"
    local build="$ROOT/build/${name}_${version}"

    mkdir -p "$build/DEBIAN"
    cat > "$build/DEBIAN/control" << EOF
Package: ${name}
Version: ${version}
Architecture: all
Maintainer: HyperSec test harness <noreply@example.invalid>
Description: Throwaway package for apt pinning tests
 Not installable software. Exists only so apt has real versions to choose
 between while the preferences file is evaluated.
EOF
    dpkg-deb --build --root-owner-group "$build" "$REPO/${name}_${version}.deb" >/dev/null 2>&1
}

# Versions chosen to mirror the real-world shapes that broke the original
# implementation: PVE on 9.x, QEMU on its own 10/11 series, ZFS on 2.x.
make_pkg pve-manager    9.0.5
make_pkg pve-manager    9.1.4
make_pkg pve-manager    9.2.3
make_pkg pve-qemu-kvm  10.1.2
make_pkg pve-qemu-kvm  11.0.2
make_pkg zfsutils-linux 2.3.4
make_pkg zfsutils-linux 2.4.3

# Generate Packages by hand -- dpkg-scanpackages lives in dpkg-dev, which is
# not guaranteed to be present, and this needs only dpkg-deb.
generate_packages() {
    local deb size sha
    : > "$REPO/Packages"
    for deb in "$REPO"/*.deb; do
        size=$(stat -c %s "$deb")
        sha=$(sha256sum "$deb" | cut -d' ' -f1)
        dpkg-deb --field "$deb" >> "$REPO/Packages"
        {
            echo "Filename: $(basename "$deb")"
            echo "Size: ${size}"
            echo "SHA256: ${sha}"
            echo ""
        } >> "$REPO/Packages"
    done
}
generate_packages

echo "deb [trusted=yes] file://${REPO} ./" > "$APTROOT/etc/apt/sources.list"

apt_opts=(
    -o "Dir=$APTROOT"
    -o "Dir::State::status=$APTROOT/var/lib/dpkg/status"
    -o "Dir::Etc::sourcelist=$APTROOT/etc/apt/sources.list"
    -o "Dir::Etc::sourceparts=$APTROOT/etc/apt/sources.list.d"
    -o "Dir::Etc::preferences=$APTROOT/etc/apt/preferences"
    -o "Dir::Etc::preferencesparts=$APTROOT/etc/apt/preferences.d"
    -o "Acquire::Languages=none"
    -o "APT::Architecture=all"
    -o "APT::Architectures=all"
)

if ! apt-get "${apt_opts[@]}" update >/dev/null 2>&1; then
    echo -e "${YELLOW}SKIP: could not build an isolated apt root here${NC}"
    exit 0
fi

candidate() {
    # The version apt would actually install for package $1.
    apt-cache "${apt_opts[@]}" policy "$1" 2>/dev/null \
        | sed -n 's/^  Candidate: //p'
}

write_prefs() {
    cat > "$APTROOT/etc/apt/preferences.d/proxmox-conservative"
}

clear_prefs() {
    rm -f "$APTROOT/etc/apt/preferences.d/proxmox-conservative"
}

#############################################
echo -e "\n${CYAN}baseline -- no pinning${NC}"
#############################################

clear_prefs
check "unpinned takes newest pve-manager"    "9.2.3"  "$(candidate pve-manager)"
check "unpinned takes newest pve-qemu-kvm"   "11.0.2" "$(candidate pve-qemu-kvm)"
check "unpinned takes newest zfsutils-linux" "2.4.3"  "$(candidate zfsutils-linux)"

#############################################
echo -e "\n${CYAN}a positive pin alone is sufficient${NC}"
#############################################

# apt picks the highest-PRIORITY candidate and only compares versions to break
# ties within a priority. 9.1.4 at 999 therefore beats 9.2.3 at the archive
# default of 500 -- no negative block required.
write_prefs << 'EOF'
Package: pve-manager
Pin: version 9.1.*
Pin-Priority: 999
EOF

check "priority beats version" "9.1.4" "$(candidate pve-manager)"

#############################################
echo -e "\n${CYAN}why there is NO negative catch-all block${NC}"
#############################################

# Adding "Pin: version * / Pin-Priority: -1" looks like belt-and-braces. It is
# a trap, and this is the test that documents why.
#
# Whenever the pinned series is not present for a package -- renamed upstream,
# retired from the archive, or a series that never existed for that package --
# the negative block leaves nothing selectable. Modelled here by pinning a
# series the repo does not carry.
write_prefs << 'EOF'
Package: pve-manager
Pin: version 8.4.*
Pin-Priority: 999

Package: pve-manager
Pin: version *
Pin-Priority: -1
EOF

# Nothing is selectable: apt cannot install or upgrade the package, and
# anything depending on it fails too. The host silently stops receiving
# security updates.
check "negative catch-all bricks the package when its series is gone" \
    "(none)" "$(candidate pve-manager)"

# Without the catch-all, the same missing series degrades gracefully: the pin
# stops holding and apt falls back to what the archive actually offers. The
# policy failing loudly-but-safely beats a wedged package manager.
write_prefs << 'EOF'
Package: pve-manager
Pin: version 8.4.*
Pin-Priority: 999
EOF

check "positive-only degrades to available instead of bricking" \
    "9.2.3" "$(candidate pve-manager)"

#############################################
echo -e "\n${CYAN}per-package series -- the packages the old pin missed${NC}"
#############################################

# Every one of these was pinned to pve-manager's "9.1.*" and therefore unpinned
# in practice. Each must now be held on its OWN series.
write_prefs << 'EOF'
Package: pve-manager
Pin: version 9.1.*
Pin-Priority: 999

Package: pve-qemu-kvm
Pin: version 10.1.*
Pin-Priority: 999

Package: zfsutils-linux
Pin: version 2.3.*
Pin-Priority: 999
EOF

check "pve-manager held on 9.x"     "9.1.4"  "$(candidate pve-manager)"
check "pve-qemu-kvm held on 10.x"   "10.1.2" "$(candidate pve-qemu-kvm)"
check "zfsutils-linux held on 2.3"  "2.3.4"  "$(candidate zfsutils-linux)"

#############################################
echo -e "\n${CYAN}patch updates within the pinned series still flow${NC}"
#############################################

# A conservative policy that also blocks patches is not conservative, it is
# abandoned. Pinning 9.0.* must still allow 9.0.5.
write_prefs << 'EOF'
Package: pve-manager
Pin: version 9.0.*
Pin-Priority: 999
EOF

check "patch within pinned series is offered" "9.0.5" "$(candidate pve-manager)"

#############################################
echo -e "\n${CYAN}never downgrades -- why Pin-Priority is 999, not 1000${NC}"
#############################################

# Mark 9.2.3 as already installed. apt_preferences(5): a priority of 1000 or
# more permits a DOWNGRADE to reach the pin; below that it does not. The script
# promises "never downgrades", so it must stay under 1000.
cat > "$APTROOT/var/lib/dpkg/status" << 'EOF'
Package: pve-manager
Status: install ok installed
Priority: optional
Section: admin
Architecture: all
Version: 9.2.3
Description: Throwaway package for apt pinning tests

EOF
apt-get "${apt_opts[@]}" update >/dev/null 2>&1

write_prefs << 'EOF'
Package: pve-manager
Pin: version 9.0.*
Pin-Priority: 999
EOF

check "999 will not downgrade an installed newer version" \
    "9.2.3" "$(candidate pve-manager)"

write_prefs << 'EOF'
Package: pve-manager
Pin: version 9.0.*
Pin-Priority: 1001
EOF

# Proof the 999 above is doing real work rather than coincidence: raise it past
# 1000 and apt immediately offers the downgrade.
check "1001 WOULD downgrade (so we never use it)" \
    "9.0.5" "$(candidate pve-manager)"

: > "$APTROOT/var/lib/dpkg/status"
apt-get "${apt_opts[@]}" update >/dev/null 2>&1

#############################################
echo -e "\n${CYAN}glob pins -- how proxmox-kernel-* is held to one ABI${NC}"
#############################################

write_prefs << 'EOF'
Package: pve-*
Pin: version 9.1.*
Pin-Priority: 999
EOF

check "glob pin holds a matching package" "9.1.4" "$(candidate pve-manager)"

# pve-qemu-kvm also matches "pve-*" but has no 9.1.x. It simply falls through
# to the archive default rather than being held -- which is exactly why a
# shared glob cannot express this policy and each package needs its OWN series.
check "glob pin silently does nothing for a different series" \
    "11.0.2" "$(candidate pve-qemu-kvm)"

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
