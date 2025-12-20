#!/bin/bash

#############################################
# Proxmox VE Conservative Update Policy
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
#   Implement a conservative update policy for Proxmox VE that pins
#   packages to one minor version behind the latest available. This
#   allows the latest patch level within that minor version while
#   avoiding bleeding-edge minor releases.
#
# Policy:
#   - MAJOR: Same as latest available
#   - MINOR: max(installed_minor, n-1) - never downgrades
#   - PATCH: Latest available within the target minor
#
# Example:
#   If repo has 9.2.3, 9.1.5, 9.0.8 available:
#   - Policy pins to 9.1.* (allowing up to 9.1.5)
#   If repo only has 9.0.x available:
#   - Policy pins to 9.0.* (can't go below 0)
#   If installed is 9.1.x and repo has 9.1.0 as latest:
#   - Policy pins to 9.1.* (never downgrades to 9.0.*)
#
# Usage:
#   sudo ./proxmox-update-policy.sh [command]
#
# Commands:
#   enable      - Enable conservative update policy (default)
#   disable     - Disable policy and allow all updates
#   status      - Show current policy and pinned versions
#   update      - Refresh pinning based on current repo state
#   cron-enable - Install daily cron job to auto-update pinning
#   cron-disable- Remove the cron job
#
# Requirements:
#   - Proxmox VE
#   - Root privileges
#
# Idempotent: Yes (safe to run multiple times)
# Requires Reboot: No
#
#############################################

set -e

# Colours
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

# Configuration
PREFERENCES_FILE="/etc/apt/preferences.d/proxmox-conservative"
CRON_FILE="/etc/cron.daily/proxmox-update-policy"
SCRIPT_PATH="$(readlink -f "$0")"
APT_HOOK_FILE="/etc/apt/apt.conf.d/99proxmoxpolicy"
HOOK_SCRIPT="/usr/local/bin/proxmox-policy-hook.sh"
BACKUP_DIR="/root/backup/proxmox-config"

# UI patching files
WIDGET_FILE="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
MANAGER_FILE="/usr/share/pve-manager/js/pvemanagerlib.js"
INDEX_TPL="/usr/share/pve-manager/index.html.tpl"
POLICY_JS="/usr/share/pve-manager/js/conservative-policy.js"

# Core Proxmox packages to pin
PROXMOX_PACKAGES=(
    "proxmox-ve"
    "pve-manager"
    "pve-kernel-*"
    "pve-qemu-kvm"
    "pve-container"
    "pve-firewall"
    "pve-ha-manager"
    "pve-cluster"
    "proxmox-backup-client"
    "proxmox-widget-toolkit"
)

# Must be root
[ $EUID -ne 0 ] && { echo "Run as root"; exit 1; }

#############################################
# Helper Functions
#############################################

get_installed_version() {
    local pkg="$1"
    dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || echo ""
}

get_installed_minor() {
    # Get the major.minor of the currently installed proxmox-ve
    local installed
    installed=$(get_installed_version "proxmox-ve")
    if [ -n "$installed" ]; then
        echo "$installed" | grep -oE '^[0-9]+\.[0-9]+' || echo ""
    else
        echo ""
    fi
}

get_available_versions() {
    # Get all available versions of proxmox-ve from apt cache
    # Returns sorted list of versions (newest first)
    apt-cache madison proxmox-ve 2>/dev/null | \
        awk -F'|' '{print $2}' | \
        tr -d ' ' | \
        sort -V -r | \
        uniq
}

get_latest_minor() {
    # Extract the highest minor version from available versions
    # Input: list of versions (one per line)
    # Output: major.minor (e.g., "9.2")
    local versions="$1"
    echo "$versions" | head -1 | grep -oE '^[0-9]+\.[0-9]+' || echo ""
}

get_target_minor() {
    # Calculate target minor version (n-1 from latest, minimum 0)
    # Input: major.minor string (e.g., "9.2")
    # Output: major.minor string (e.g., "9.1")
    local latest_minor="$1"
    local major minor target_minor

    major=$(echo "$latest_minor" | cut -d. -f1)
    minor=$(echo "$latest_minor" | cut -d. -f2)

    if [ "$minor" -gt 0 ]; then
        target_minor=$((minor - 1))
    else
        target_minor=0
    fi

    echo "${major}.${target_minor}"
}

get_available_minors() {
    # Get list of unique minor versions available
    # Input: list of versions
    # Output: unique major.minor values, sorted descending
    local versions="$1"
    echo "$versions" | grep -oE '^[0-9]+\.[0-9]+' | sort -V -r | uniq
}

#############################################
# UI Patching Functions
#############################################
# These functions modify Proxmox UI to suppress "not recommended
# for production" warnings when conservative update policy is active.
#
# APPROACH: External JS file + minimal unified diff patches
#   1. Create /usr/share/pve-manager/js/conservative-policy.js (sets flag)
#   2. Apply patch files using the standard `patch` utility
#   3. Patches are tested with --dry-run before application
#
# NOTE: This does NOT imply Enterprise Edition functionality or Proxmox
# EE value-add. It simply indicates that a conservative update policy
# is in place for stability.
#
# SAFETY: Each patch is validated with --dry-run before application.
# If the patch doesn't apply cleanly, it's skipped (no partial changes).
# Clean backups are always created for easy restoration.
# If conservative-policy.js is deleted, all patched code falls back to
# original Proxmox behavior (the flag check returns false/undefined).
#
# COMPATIBILITY: Proxmox VE 9.x (PVE 8.x at own risk)

# Backup file paths
WIDGET_BACKUP="${BACKUP_DIR}/proxmoxlib.js.original"
MANAGER_BACKUP="${BACKUP_DIR}/pvemanagerlib.js.original"
INDEX_BACKUP="${BACKUP_DIR}/index.html.tpl.original"

# Apply a single patch file safely (dry-run first, then apply)
# Returns 0 on success, 1 if pattern not found (silent - expected for version differences)
apply_patch() {
    local file="$1"
    local patch_content="$2"
    local description="$3"
    local quiet="$4"

    # Test if patch applies cleanly
    if echo "$patch_content" | patch --dry-run --ignore-whitespace -f "$file" >/dev/null 2>&1; then
        # Apply the patch
        if echo "$patch_content" | patch --ignore-whitespace -f "$file" >/dev/null 2>&1; then
            [ -z "$quiet" ] && echo -e "${GREEN}OK $description${NC}"
            return 0
        fi
    fi
    # Silent return - pattern not found is expected for version-specific patches
    return 1
}

patch_ui() {
    # Patch Proxmox UI to suppress no-subscription warnings
    # Returns 0 on success, 1 if skipped (patterns not found)
    local quiet="${1:-}"
    local patches_applied=0

    # Check required files exist
    if [ ! -f "$WIDGET_FILE" ]; then
        [ -z "$quiet" ] && echo -e "${YELLOW}Widget file not found, skipping UI patch${NC}"
        return 1
    fi
    if [ ! -f "$INDEX_TPL" ]; then
        [ -z "$quiet" ] && echo -e "${YELLOW}Index template not found, skipping UI patch${NC}"
        return 1
    fi

    # Check if already patched
    if [ -f "$POLICY_JS" ]; then
        [ -z "$quiet" ] && echo -e "${CYAN}UI already patched for conservative policy${NC}"
        return 0
    fi

    # Create backup directory
    mkdir -p "$BACKUP_DIR"

    # Backup originals (only if not already backed up)
    if [ ! -f "$WIDGET_BACKUP" ]; then
        cp "$WIDGET_FILE" "$WIDGET_BACKUP"
        [ -z "$quiet" ] && echo -e "${GREEN}OK Saved $WIDGET_BACKUP${NC}"
    fi
    if [ ! -f "$INDEX_BACKUP" ]; then
        cp "$INDEX_TPL" "$INDEX_BACKUP"
        [ -z "$quiet" ] && echo -e "${GREEN}OK Saved $INDEX_BACKUP${NC}"
    fi
    if [ -f "$MANAGER_FILE" ] && [ ! -f "$MANAGER_BACKUP" ]; then
        cp "$MANAGER_FILE" "$MANAGER_BACKUP"
        [ -z "$quiet" ] && echo -e "${GREEN}OK Saved $MANAGER_BACKUP${NC}"
    fi

    # STEP 1: Create our external JS file (contains all our logic)
    cat > "$POLICY_JS" << 'POLICY_JS_EOF'
// Conservative Update Policy - UI Customization
// Installed by: proxmox-update-policy.sh
//
// This file sets a flag that proxmoxlib.js checks to suppress
// "not recommended for production" warnings for no-subscription repos.
//
// NOTE: This does NOT imply Enterprise Edition functionality.
// It indicates a conservative update policy is in place for stability.
//
// If this file is deleted, all UI warnings revert to original behavior.
(function() {
    'use strict';
    Proxmox.Utils = Proxmox.Utils || {};
    Proxmox.Utils.conservativePolicyActive = true;
})();
POLICY_JS_EOF
    [ -z "$quiet" ] && echo -e "${GREEN}OK Created $POLICY_JS${NC}"

    # STEP 2: Apply patches to index.html.tpl (add script tag)
    # Patch: Insert our script tag after proxmoxlib.js
    local INDEX_PATCH
    read -r -d '' INDEX_PATCH << 'PATCH_EOF' || true
--- a/index.html.tpl
+++ b/index.html.tpl
@@ -1,2 +1,3 @@
     <script type="text/javascript" src="/proxmoxlib.js?ver=[% wtversion %]"></script>
+    <script type="text/javascript" src="/pve2/js/conservative-policy.js"></script>
     <script type="text/javascript" src="/pve2/js/pvemanagerlib.js?ver=[% version %]"></script>
PATCH_EOF

    if ! grep -qF "conservative-policy.js" "$INDEX_TPL" 2>/dev/null; then
        apply_patch "$INDEX_TPL" "$INDEX_PATCH" "Patched index.html.tpl (script tag)" "$quiet" && ((++patches_applied))
    fi

    # STEP 3: Apply patches to proxmoxlib.js
    # Patch 3a: Add condition to repos.nosubscription check (PVE 8+)
    local WIDGET_PATCH_1
    read -r -d '' WIDGET_PATCH_1 << 'PATCH_EOF' || true
--- a/proxmoxlib.js
+++ b/proxmoxlib.js
@@ -1 +1 @@
-                if (repos.nosubscription) {
+                if (repos.nosubscription && !Proxmox.Utils.conservativePolicyActive) {
PATCH_EOF

    apply_patch "$WIDGET_FILE" "$WIDGET_PATCH_1" "Patched proxmoxlib.js (nosubscription check)" "$quiet" && ((++patches_applied))

    # Patch 3b: Add condition to column renderer warning
    local WIDGET_PATCH_2
    read -r -d '' WIDGET_PATCH_2 << 'PATCH_EOF' || true
--- a/proxmoxlib.js
+++ b/proxmoxlib.js
@@ -1 +1 @@
-                    if (components[0].match(/\w+(-no-subscription|test)\s*$/i)) {
+                    if (components[0].match(/\w+(-no-subscription|test)\s*$/i) && !(Proxmox.Utils.conservativePolicyActive && components[0].match(/no-subscription/))) {
PATCH_EOF

    apply_patch "$WIDGET_FILE" "$WIDGET_PATCH_2" "Patched proxmoxlib.js (column renderer)" "$quiet" && ((++patches_applied))

    # Patch 3c: Add custom status text when policy is active
    local WIDGET_PATCH_3
    read -r -d '' WIDGET_PATCH_3 << 'PATCH_EOF' || true
--- a/proxmoxlib.js
+++ b/proxmoxlib.js
@@ -1,3 +1,7 @@
             let iconCls = Proxmox.Utils.get_health_icon(status, true);

+            if (Proxmox.Utils.conservativePolicyActive && status === 'good') {
+                text = 'Conservative update policy active (latest patch, last minor release)';
+            }
+
             vm.set('state', {
PATCH_EOF

    apply_patch "$WIDGET_FILE" "$WIDGET_PATCH_3" "Patched proxmoxlib.js (status text)" "$quiet" && ((++patches_applied))

    # Patch 3d: Handle non-production status - show policy message instead of warning
    # PVE 9 format (multi-line with spaces)
    local WIDGET_PATCH_4
    read -r -d '' WIDGET_PATCH_4 << 'PATCH_EOF' || true
--- a/proxmoxlib.js
+++ b/proxmoxlib.js
@@ -1 +1 @@
-                        gettext('Non production-ready repository enabled!'),
+                        Proxmox.Utils.conservativePolicyActive ? 'Conservative update policy active' : gettext('Non production-ready repository enabled!'),
PATCH_EOF

    apply_patch "$WIDGET_FILE" "$WIDGET_PATCH_4" "Patched proxmoxlib.js (non-production text)" "$quiet" && ((++patches_applied))

    # Patch 3e: Change warning icon to success when policy is active (non-production block)
    # PVE 9 format (multi-line)
    local WIDGET_PATCH_5
    read -r -d '' WIDGET_PATCH_5 << 'PATCH_EOF' || true
--- a/proxmoxlib.js
+++ b/proxmoxlib.js
@@ -1,4 +1,4 @@
                    fmt(
                        Proxmox.Utils.conservativePolicyActive ? 'Conservative update policy active' : gettext('Non production-ready repository enabled!'),
-                        'exclamation-circle warning',
+                        Proxmox.Utils.conservativePolicyActive ? 'check-circle good' : 'exclamation-circle warning',
                    )
PATCH_EOF

    apply_patch "$WIDGET_FILE" "$WIDGET_PATCH_5" "Patched proxmoxlib.js (non-production icon)" "$quiet" && ((++patches_applied))

    # Patch 3f: PVE 8 format (single line) - alternative for older versions
    local WIDGET_PATCH_6
    read -r -d '' WIDGET_PATCH_6 << 'PATCH_EOF' || true
--- a/proxmoxlib.js
+++ b/proxmoxlib.js
@@ -1 +1 @@
-		   fmt(gettext('Non production-ready repository enabled!'), 'exclamation-circle warning');
+		   fmt(Proxmox.Utils.conservativePolicyActive ? 'Conservative update policy active' : gettext('Non production-ready repository enabled!'), Proxmox.Utils.conservativePolicyActive ? 'check-circle good' : 'exclamation-circle warning');
PATCH_EOF

    apply_patch "$WIDGET_FILE" "$WIDGET_PATCH_6" "Patched proxmoxlib.js (non-production PVE8)" "$quiet" && ((++patches_applied))

    # STEP 4: Apply patches to pvemanagerlib.js (Setup Wizard)
    if [ -f "$MANAGER_FILE" ]; then
        local MANAGER_PATCH
        read -r -d '' MANAGER_PATCH << 'PATCH_EOF' || true
--- a/pvemanagerlib.js
+++ b/pvemanagerlib.js
@@ -1 +1 @@
-                              'The no-subscription repository is not the best choice for production setups.',
+                              Proxmox.Utils.conservativePolicyActive ? 'Conservative update policy active (latest patch, last minor release)' : 'The no-subscription repository is not the best choice for production setups.',
PATCH_EOF

        apply_patch "$MANAGER_FILE" "$MANAGER_PATCH" "Patched pvemanagerlib.js (setup wizard)" "$quiet" && ((++patches_applied))
    fi

    [ -z "$quiet" ] && echo -e "${CYAN}Applied $patches_applied patches${NC}"

    # Restart pveproxy to apply changes
    if systemctl restart pveproxy.service 2>/dev/null; then
        [ -z "$quiet" ] && echo -e "${GREEN}OK pveproxy service restarted${NC}"
    else
        [ -z "$quiet" ] && echo -e "${YELLOW}Note: Restart pveproxy manually or refresh browser${NC}"
    fi

    return 0
}

unpatch_ui() {
    # Restore original Proxmox UI files and remove our additions
    local quiet="${1:-}"

    # Check if patched (our JS file exists)
    if [ ! -f "$POLICY_JS" ]; then
        [ -z "$quiet" ] && echo -e "${CYAN}UI not patched (already original)${NC}"
        return 0
    fi

    local restored=false

    # Remove our external JS file
    if [ -f "$POLICY_JS" ]; then
        rm -f "$POLICY_JS"
        [ -z "$quiet" ] && echo -e "${GREEN}OK Removed $POLICY_JS${NC}"
        restored=true
    fi

    # Restore index.html.tpl from backup or remove our line
    if [ -f "$INDEX_BACKUP" ]; then
        cp "$INDEX_BACKUP" "$INDEX_TPL"
        [ -z "$quiet" ] && echo -e "${GREEN}OK Restored $INDEX_TPL from backup${NC}"
        restored=true
    elif grep -qF "conservative-policy.js" "$INDEX_TPL" 2>/dev/null; then
        # Fallback: remove just our script line
        sed -i '/conservative-policy.js/d' "$INDEX_TPL"
        [ -z "$quiet" ] && echo -e "${GREEN}OK Removed script tag from $INDEX_TPL${NC}"
        restored=true
    fi

    # Restore proxmoxlib.js from backup or reinstall package
    if [ -f "$WIDGET_BACKUP" ]; then
        cp "$WIDGET_BACKUP" "$WIDGET_FILE"
        [ -z "$quiet" ] && echo -e "${GREEN}OK Restored $WIDGET_FILE from backup${NC}"
        restored=true
    elif grep -qF "conservativePolicyActive" "$WIDGET_FILE" 2>/dev/null; then
        # Fallback: reinstall package
        [ -z "$quiet" ] && echo "No widget backup, reinstalling package..."
        if apt-get install --reinstall -y proxmox-widget-toolkit >/dev/null 2>&1; then
            [ -z "$quiet" ] && echo -e "${GREEN}OK Restored via package reinstall${NC}"
            restored=true
        fi
    fi

    # Restore pvemanagerlib.js from backup or reinstall package
    if [ -f "$MANAGER_BACKUP" ]; then
        cp "$MANAGER_BACKUP" "$MANAGER_FILE"
        [ -z "$quiet" ] && echo -e "${GREEN}OK Restored $MANAGER_FILE from backup${NC}"
        restored=true
    elif grep -qF "conservativePolicyActive" "$MANAGER_FILE" 2>/dev/null; then
        # Fallback: reinstall package
        [ -z "$quiet" ] && echo "No manager backup, reinstalling package..."
        if apt-get install --reinstall -y pve-manager >/dev/null 2>&1; then
            [ -z "$quiet" ] && echo -e "${GREEN}OK Restored via package reinstall${NC}"
            restored=true
        fi
    fi

    # Restart pveproxy if we made changes
    if [ "$restored" = true ]; then
        if systemctl restart pveproxy.service 2>/dev/null; then
            [ -z "$quiet" ] && echo -e "${GREEN}OK pveproxy service restarted${NC}"
        fi
    fi

    return 0
}

install_ui_hook() {
    # Install APT hook to reapply UI patches after package updates
    # Uses the standard `patch` utility for robustness across PVE versions
    local quiet="${1:-}"

    if [ -f "$APT_HOOK_FILE" ] && [ -f "$HOOK_SCRIPT" ]; then
        [ -z "$quiet" ] && echo -e "${CYAN}UI persistence hook already installed${NC}"
        return 0
    fi

    # Create hook script that reapplies patches after package updates
    cat > "$HOOK_SCRIPT" << 'HOOK_EOF'
#!/bin/bash
# Proxmox Conservative Update Policy - UI Hook
# Re-applies UI patches after proxmox-widget-toolkit or pve-manager updates
# Uses the standard `patch` utility for robustness across PVE versions

WIDGET_FILE="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
MANAGER_FILE="/usr/share/pve-manager/js/pvemanagerlib.js"
INDEX_TPL="/usr/share/pve-manager/index.html.tpl"
POLICY_JS="/usr/share/pve-manager/js/conservative-policy.js"

# Check if conservative policy is enabled
[ ! -f "/etc/apt/preferences.d/proxmox-conservative" ] && exit 0

# Check if our JS file exists (indicates we should be patched)
[ ! -f "$POLICY_JS" ] && exit 0

# Helper: Apply a patch safely (dry-run first)
apply_patch() {
    local file="$1"
    local patch_content="$2"
    if echo "$patch_content" | patch --dry-run --ignore-whitespace -f "$file" >/dev/null 2>&1; then
        echo "$patch_content" | patch --ignore-whitespace -f "$file" >/dev/null 2>&1
    fi
}

# Re-patch proxmoxlib.js if needed (after proxmox-widget-toolkit update)
if [ -f "$WIDGET_FILE" ] && ! grep -qF "conservativePolicyActive" "$WIDGET_FILE" 2>/dev/null; then
    # Patch 1: nosubscription check (PVE 8+)
    apply_patch "$WIDGET_FILE" '--- a/proxmoxlib.js
+++ b/proxmoxlib.js
@@ -1 +1 @@
-                if (repos.nosubscription) {
+                if (repos.nosubscription && !Proxmox.Utils.conservativePolicyActive) {'

    # Patch 2: column renderer warning
    apply_patch "$WIDGET_FILE" '--- a/proxmoxlib.js
+++ b/proxmoxlib.js
@@ -1 +1 @@
-                    if (components[0].match(/\w+(-no-subscription|test)\s*$/i)) {
+                    if (components[0].match(/\w+(-no-subscription|test)\s*$/i) && !(Proxmox.Utils.conservativePolicyActive && components[0].match(/no-subscription/))) {'

    # Patch 3: status text
    apply_patch "$WIDGET_FILE" '--- a/proxmoxlib.js
+++ b/proxmoxlib.js
@@ -1,3 +1,7 @@
             let iconCls = Proxmox.Utils.get_health_icon(status, true);

+            if (Proxmox.Utils.conservativePolicyActive && status === '"'"'good'"'"') {
+                text = '"'"'Conservative update policy active (latest patch, last minor release)'"'"';
+            }
+
             vm.set('"'"'state'"'"', {'

    # Patch 4: non-production text
    apply_patch "$WIDGET_FILE" '--- a/proxmoxlib.js
+++ b/proxmoxlib.js
@@ -1 +1 @@
-                        gettext('"'"'Non production-ready repository enabled!'"'"'),
+                        Proxmox.Utils.conservativePolicyActive ? '"'"'Conservative update policy active'"'"' : gettext('"'"'Non production-ready repository enabled!'"'"'),'

    # Patch 5: non-production icon (with context to target correct instance) - PVE 9
    apply_patch "$WIDGET_FILE" '--- a/proxmoxlib.js
+++ b/proxmoxlib.js
@@ -1,4 +1,4 @@
                    fmt(
                        Proxmox.Utils.conservativePolicyActive ? '"'"'Conservative update policy active'"'"' : gettext('"'"'Non production-ready repository enabled!'"'"'),
-                        '"'"'exclamation-circle warning'"'"',
+                        Proxmox.Utils.conservativePolicyActive ? '"'"'check-circle good'"'"' : '"'"'exclamation-circle warning'"'"',
                    )'

    # Patch 6: PVE 8 format (single line)
    apply_patch "$WIDGET_FILE" '--- a/proxmoxlib.js
+++ b/proxmoxlib.js
@@ -1 +1 @@
-		   fmt(gettext('"'"'Non production-ready repository enabled!'"'"'), '"'"'exclamation-circle warning'"'"');
+		   fmt(Proxmox.Utils.conservativePolicyActive ? '"'"'Conservative update policy active'"'"' : gettext('"'"'Non production-ready repository enabled!'"'"'), Proxmox.Utils.conservativePolicyActive ? '"'"'check-circle good'"'"' : '"'"'exclamation-circle warning'"'"');'
fi

# Re-patch pvemanagerlib.js if needed (after pve-manager update)
if [ -f "$MANAGER_FILE" ] && ! grep -qF "conservativePolicyActive" "$MANAGER_FILE" 2>/dev/null; then
    apply_patch "$MANAGER_FILE" '--- a/pvemanagerlib.js
+++ b/pvemanagerlib.js
@@ -1 +1 @@
-                              '"'"'The no-subscription repository is not the best choice for production setups.'"'"',
+                              Proxmox.Utils.conservativePolicyActive ? '"'"'Conservative update policy active (latest patch, last minor release)'"'"' : '"'"'The no-subscription repository is not the best choice for production setups.'"'"','
fi

# Re-patch index.html.tpl if needed (after pve-manager update)
if [ -f "$INDEX_TPL" ] && ! grep -qF "conservative-policy.js" "$INDEX_TPL" 2>/dev/null; then
    apply_patch "$INDEX_TPL" '--- a/index.html.tpl
+++ b/index.html.tpl
@@ -1,2 +1,3 @@
     <script type="text/javascript" src="/proxmoxlib.js?ver=[% wtversion %]"></script>
+    <script type="text/javascript" src="/pve2/js/conservative-policy.js"></script>
     <script type="text/javascript" src="/pve2/js/pvemanagerlib.js?ver=[% version %]"></script>'
fi

# Restart service
systemctl restart pveproxy.service >/dev/null 2>&1 || true
HOOK_EOF

    chmod +x "$HOOK_SCRIPT"

    # Create APT hook
    cat > "$APT_HOOK_FILE" << 'APT_EOF'
DPkg::Post-Invoke {
    "/usr/local/bin/proxmox-policy-hook.sh";
};
APT_EOF

    [ -z "$quiet" ] && echo -e "${GREEN}OK UI persistence hook installed${NC}"
    return 0
}

remove_ui_hook() {
    # Remove APT hook for UI patches
    local quiet="${1:-}"
    local removed=false

    if [ -f "$APT_HOOK_FILE" ]; then
        rm -f "$APT_HOOK_FILE"
        removed=true
    fi

    if [ -f "$HOOK_SCRIPT" ]; then
        rm -f "$HOOK_SCRIPT"
        removed=true
    fi

    if [ "$removed" = true ]; then
        [ -z "$quiet" ] && echo -e "${GREEN}OK UI persistence hook removed${NC}"
    else
        [ -z "$quiet" ] && echo -e "${CYAN}UI persistence hook not installed${NC}"
    fi
    return 0
}

show_status() {
    echo -e "${GREEN}=== Proxmox Update Policy Status ===${NC}\n"

    if [ -f "$PREFERENCES_FILE" ]; then
        echo -e "${CYAN}Policy: ENABLED (conservative n-1)${NC}"
        echo -e "Preferences file: $PREFERENCES_FILE\n"

        # Extract pinned version from file
        local pinned_version
        pinned_version=$(grep -oP 'Pin: version \K[0-9]+\.[0-9]+' "$PREFERENCES_FILE" 2>/dev/null | head -1)
        if [ -n "$pinned_version" ]; then
            echo -e "Pinned to minor version: ${CYAN}${pinned_version}.*${NC}"
        fi
    else
        echo -e "${YELLOW}Policy: DISABLED (all updates allowed)${NC}"
    fi

    # Cron status
    echo ""
    if [ -f "$CRON_FILE" ]; then
        echo -e "Auto-update cron: ${GREEN}ENABLED${NC} (daily)"
    else
        echo -e "Auto-update cron: ${YELLOW}DISABLED${NC}"
    fi

    # UI patch status
    if [ -f "$POLICY_JS" ]; then
        echo -e "UI customization: ${GREEN}APPLIED${NC}"
        echo -e "  Policy JS: $POLICY_JS"
        if grep -qF "conservativePolicyActive" "$WIDGET_FILE" 2>/dev/null; then
            echo -e "  proxmoxlib.js: ${GREEN}patched${NC}"
        else
            echo -e "  proxmoxlib.js: ${YELLOW}needs patching${NC}"
        fi
        if grep -qF "conservative-policy.js" "$INDEX_TPL" 2>/dev/null; then
            echo -e "  index.html.tpl: ${GREEN}patched${NC}"
        else
            echo -e "  index.html.tpl: ${YELLOW}needs patching${NC}"
        fi
    else
        echo -e "UI customization: ${YELLOW}NOT APPLIED${NC}"
    fi

    # Backup status
    echo ""
    echo -e "${GREEN}Backups:${NC}"
    if [ -f "$WIDGET_BACKUP" ]; then
        echo -e "  proxmoxlib.js: ${GREEN}saved${NC}"
    else
        echo -e "  proxmoxlib.js: ${YELLOW}not saved${NC}"
    fi
    if [ -f "$INDEX_BACKUP" ]; then
        echo -e "  index.html.tpl: ${GREEN}saved${NC}"
    else
        echo -e "  index.html.tpl: ${YELLOW}not saved${NC}"
    fi

    # UI hook status
    if [ -f "$APT_HOOK_FILE" ] && [ -f "$HOOK_SCRIPT" ]; then
        echo -e "UI persistence hook: ${GREEN}INSTALLED${NC}"
    else
        echo -e "UI persistence hook: ${YELLOW}NOT INSTALLED${NC}"
    fi

    echo ""
    echo -e "${GREEN}Current installation:${NC}"
    local pve_version
    pve_version=$(get_installed_version "proxmox-ve")
    local manager_version
    manager_version=$(get_installed_version "pve-manager")
    echo "  proxmox-ve:  $pve_version"
    echo "  pve-manager: $manager_version"

    echo ""
    echo -e "${GREEN}Repository analysis:${NC}"
    local versions
    versions=$(get_available_versions)

    if [ -z "$versions" ]; then
        echo -e "  ${RED}Could not query available versions${NC}"
        return
    fi

    local latest_minor
    latest_minor=$(get_latest_minor "$versions")
    local target_minor
    target_minor=$(get_target_minor "$latest_minor")
    local available_minors
    available_minors=$(get_available_minors "$versions")

    echo "  Latest available: $(echo "$versions" | head -1)"
    echo "  Latest minor: $latest_minor"
    echo "  Target minor (n-1): $target_minor"
    echo ""
    echo "  Available minor versions:"
    echo "$available_minors" | while read -r m; do
        local latest_patch
        latest_patch=$(echo "$versions" | grep "^${m}\." | head -1)
        if [ "$m" = "$target_minor" ]; then
            echo -e "    ${GREEN}• $m (target) - latest patch: $latest_patch${NC}"
        else
            echo "    • $m - latest patch: $latest_patch"
        fi
    done

    echo ""
    echo -e "${GREEN}APT policy for proxmox-ve:${NC}"
    apt-cache policy proxmox-ve 2>/dev/null | grep -E "Installed|Candidate" | sed 's/^/  /'
}

enable_policy() {
    local quiet="${1:-}"
    local no_ui="${2:-}"

    [ -z "$quiet" ] && echo -e "${GREEN}=== Enabling Conservative Update Policy ===${NC}\n"

    # Refresh apt cache first
    [ -z "$quiet" ] && echo "Refreshing package lists..."
    apt-get update >/dev/null 2>&1

    # Get available versions
    local versions
    versions=$(get_available_versions)

    if [ -z "$versions" ]; then
        echo -e "${RED}Error: Could not query available Proxmox versions${NC}"
        echo "Ensure apt sources are configured correctly"
        exit 1
    fi

    # Calculate target minor version
    local latest_minor
    latest_minor=$(get_latest_minor "$versions")
    if [ -z "$latest_minor" ]; then
        echo -e "${RED}Error: Could not determine latest minor version${NC}"
        exit 1
    fi

    local target_minor
    target_minor=$(get_target_minor "$latest_minor")

    # Get currently installed minor version as floor (never downgrade)
    local installed_minor
    installed_minor=$(get_installed_minor)

    # Ensure target is at least the installed minor (never downgrade)
    if [ -n "$installed_minor" ]; then
        # Compare versions: if installed > target, use installed as floor
        local installed_major installed_min target_major target_min
        installed_major=$(echo "$installed_minor" | cut -d. -f1)
        installed_min=$(echo "$installed_minor" | cut -d. -f2)
        target_major=$(echo "$target_minor" | cut -d. -f1)
        target_min=$(echo "$target_minor" | cut -d. -f2)

        # If installed minor is greater than computed target, use installed as floor
        if [ "$installed_major" -eq "$target_major" ] && [ "$installed_min" -gt "$target_min" ]; then
            [ -z "$quiet" ] && echo -e "${YELLOW}Note: Installed version ($installed_minor) > n-1 target ($target_minor)${NC}"
            [ -z "$quiet" ] && echo -e "${YELLOW}Using installed minor as floor: $installed_minor${NC}"
            target_minor="$installed_minor"
        fi
    fi

    # Verify target minor exists in repo
    local available_minors
    available_minors=$(get_available_minors "$versions")
    if ! echo "$available_minors" | grep -qE "^${target_minor}$"; then
        # Target minor not available, use latest minor instead
        [ -z "$quiet" ] && echo -e "${YELLOW}Note: Minor version $target_minor not available in repo${NC}"
        [ -z "$quiet" ] && echo -e "${YELLOW}Falling back to latest minor: $latest_minor${NC}"
        target_minor="$latest_minor"
    fi

    local latest_in_target
    latest_in_target=$(echo "$versions" | grep "^${target_minor}\." | head -1)

    [ -z "$quiet" ] && echo "Repository latest: $(echo "$versions" | head -1)"
    [ -z "$quiet" ] && echo "Latest minor: $latest_minor"
    [ -z "$quiet" ] && echo "Target minor (n-1): $target_minor"
    [ -z "$quiet" ] && echo "Latest patch in target: $latest_in_target"
    [ -z "$quiet" ] && echo ""

    # Build preferences file content
    local prefs_content
    local repo_latest
    repo_latest=$(echo "$versions" | head -1)
    prefs_content="# Proxmox VE Conservative Update Policy (n-1 minor)
# Generated: $(date -Iseconds)
#
# Policy: Stay one minor version behind latest
# Repository latest: ${repo_latest}
# Target minor: ${target_minor}.*
#
# This allows patch updates within ${target_minor}.x while avoiding
# bleeding-edge minor releases.
#
# To disable: sudo proxmox-update-policy.sh disable
# To refresh: sudo proxmox-update-policy.sh update

"

    for pkg in "${PROXMOX_PACKAGES[@]}"; do
        prefs_content+="Package: $pkg
Pin: version ${target_minor}.*
Pin-Priority: 1000

"
    done

    # Write preferences file
    echo "$prefs_content" > "$PREFERENCES_FILE"
    [ -z "$quiet" ] && echo -e "${GREEN}OK Created $PREFERENCES_FILE${NC}"

    # Apply UI patches (replace scary warnings with policy info)
    if [ -z "$no_ui" ]; then
        [ -z "$quiet" ] && echo ""
        [ -z "$quiet" ] && echo -e "${YELLOW}Applying UI customizations...${NC}"
        patch_ui "$quiet"
        install_ui_hook "$quiet"
    else
        [ -z "$quiet" ] && echo ""
        [ -z "$quiet" ] && echo -e "${CYAN}Skipping UI customizations (--no-ui)${NC}"
    fi

    [ -z "$quiet" ] && echo ""
    [ -z "$quiet" ] && echo -e "${GREEN}Conservative update policy enabled.${NC}"
    [ -z "$quiet" ] && echo ""
    [ -z "$quiet" ] && echo "Policy:"
    [ -z "$quiet" ] && echo "  • Pinned to minor version: $target_minor.*"
    [ -z "$quiet" ] && echo "  • Patch updates within $target_minor.x will install"
    [ -z "$quiet" ] && echo "  • Minor version $latest_minor.x will NOT auto-install"
    [ -z "$quiet" ] && echo ""
    [ -z "$quiet" ] && echo "The pinning updates automatically when:"
    [ -z "$quiet" ] && echo "  • You run: sudo $0 update"
    [ -z "$quiet" ] && echo "  • Cron job runs (if enabled with: sudo $0 cron-enable)"
}

disable_policy() {
    echo -e "${GREEN}=== Disabling Conservative Update Policy ===${NC}\n"

    if [ -f "$PREFERENCES_FILE" ]; then
        rm -f "$PREFERENCES_FILE"
        echo -e "${GREEN}OK Removed $PREFERENCES_FILE${NC}"

        # Remove UI patches and hook
        echo ""
        echo -e "${YELLOW}Restoring original UI...${NC}"
        remove_ui_hook ""
        unpatch_ui ""

        echo ""
        echo "Updating package lists..."
        apt-get update >/dev/null 2>&1
        echo -e "${GREEN}OK Package lists updated${NC}"

        echo ""
        echo -e "${YELLOW}All Proxmox updates are now allowed.${NC}"
        echo "Run 'apt update && apt dist-upgrade' to upgrade to latest version."
    else
        echo -e "${CYAN}Policy already disabled (no preferences file found)${NC}"
    fi
}

update_policy() {
    echo -e "${GREEN}=== Updating Conservative Update Policy ===${NC}\n"

    if [ ! -f "$PREFERENCES_FILE" ]; then
        echo -e "${YELLOW}Policy not enabled. Run 'enable' first.${NC}"
        exit 1
    fi

    # Re-run enable to refresh pinning
    enable_policy
}

enable_cron() {
    echo -e "${GREEN}=== Enabling Daily Cron Job ===${NC}\n"

    cat > "$CRON_FILE" << EOF
#!/bin/bash
# Proxmox Conservative Update Policy - Daily refresh
# Installed by: proxmox-update-policy.sh cron-enable
#
# This job refreshes the APT pinning daily to track n-1 minor version

# Run quietly, only output on error
"$SCRIPT_PATH" update --quiet 2>&1 | logger -t proxmox-update-policy
EOF

    chmod +x "$CRON_FILE"
    echo -e "${GREEN}OK Installed $CRON_FILE${NC}"
    echo ""
    echo "The pinning will now update daily to track the n-1 minor version."
    echo "Check logs with: journalctl -t proxmox-update-policy"
}

disable_cron() {
    echo -e "${GREEN}=== Disabling Daily Cron Job ===${NC}\n"

    if [ -f "$CRON_FILE" ]; then
        rm -f "$CRON_FILE"
        echo -e "${GREEN}OK Removed $CRON_FILE${NC}"
    else
        echo -e "${CYAN}Cron job already disabled${NC}"
    fi
}

show_help() {
    echo "Proxmox VE Conservative Update Policy"
    echo ""
    echo "Usage: $0 {enable|disable|status|update|cron-enable|cron-disable} [options]"
    echo ""
    echo "Commands:"
    echo "  enable       - Enable policy (pin to n-1 minor version)"
    echo "  disable      - Disable policy (allow all updates)"
    echo "  status       - Show current policy and available versions"
    echo "  update       - Refresh pinning based on current repo state"
    echo "  cron-enable  - Install daily cron job to auto-update pinning"
    echo "  cron-disable - Remove the daily cron job"
    echo ""
    echo "Options:"
    echo "  --no-ui      - Skip UI customizations (keep original warnings)"
    echo "  --quiet      - Minimal output (for cron/scripts)"
    echo ""
    echo "Policy behaviour:"
    echo "  MAJOR: Same as latest available"
    echo "  MINOR: max(installed, n-1) - never downgrades below installed"
    echo "  PATCH: Latest available within target minor"
    echo ""
    echo "UI customizations:"
    echo "  When enabled, replaces Proxmox 'not recommended for production'"
    echo "  warnings with 'Conservative n-1 update policy active' messages."
    echo "  Changes warning icons/colors to green success indicators."
    echo "  APT hook maintains patches across package updates."
    echo ""
    echo "Example:"
    echo "  $0 enable            # Enable with UI patches"
    echo "  $0 enable --no-ui    # Enable without UI patches"
    echo "  If repo has 9.2.3 as latest, policy pins to 9.1.*"
    echo "  If repo has 9.0.5 as latest, policy pins to 9.0.* (can't go below 0)"
}

#############################################
# Main
#############################################

case "${1:-help}" in
    enable)
        # Parse options
        shift
        no_ui=""
        for arg in "$@"; do
            case "$arg" in
                --no-ui) no_ui="true" ;;
            esac
        done
        enable_policy "" "$no_ui"
        ;;
    disable)
        disable_policy
        ;;
    status)
        show_status
        ;;
    update)
        # Parse options
        shift
        quiet=""
        no_ui=""
        for arg in "$@"; do
            case "$arg" in
                --quiet) quiet="quiet" ;;
                --no-ui) no_ui="true" ;;
            esac
        done
        if [ -n "$quiet" ]; then
            enable_policy "$quiet" "$no_ui"
        else
            update_policy
        fi
        ;;
    cron-enable)
        enable_cron
        ;;
    cron-disable)
        disable_cron
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        show_help
        exit 1
        ;;
esac
