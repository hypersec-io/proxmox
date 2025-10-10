#!/bin/bash

#############################################
# Proxmox VE 9 Repository Configuration
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
#   Configure Proxmox VE repositories for community (no-subscription)
#   use. Disables enterprise repositories and enables the free
#   community repository.
#
# Usage:
#   sudo ./proxmox-repo.sh
#
# Requirements:
#   - Proxmox VE 9.x
#   - Debian 13 (Trixie)
#   - Root privileges
#   - Internet connection
#
# Features:
#   - Creates no-subscription repository configuration
#   - Disables enterprise repositories
#   - Updates package lists
#
# Idempotent: Yes (safe to run multiple times)
# Requires Reboot: No
# Backup Location: N/A (safe operations)
#
#############################################

set -e

# Must be root
[ $EUID -ne 0 ] && { echo "Run as root"; exit 1; }

echo "Configuring Proxmox repositories..."

# 1. Create no-subscription repository file
cat > /etc/apt/sources.list.d/debian.sources << 'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

# 2. Disable enterprise repositories (idempotent - won't fail if already disabled)
[ -f "/etc/apt/sources.list.d/pve-enterprise.sources" ] && \
    mv -n "/etc/apt/sources.list.d/pve-enterprise.sources" "/etc/apt/sources.list.d/pve-enterprise.sources.disabled" 2>/dev/null || true

[ -f "/etc/apt/sources.list.d/ceph.sources" ] && \
    mv -n "/etc/apt/sources.list.d/ceph.sources" "/etc/apt/sources.list.d/ceph.sources.disabled" 2>/dev/null || true

# 3. Update package list
apt-get update >/dev/null 2>&1

echo "Done."