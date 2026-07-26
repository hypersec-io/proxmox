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
#   Implement a conservative update policy for Proxmox VE: hold every managed
#   package one MINOR version behind the latest available, while still taking
#   every PATCH within that minor. Lets a CE (no-subscription) host behave like
#   an enterprise one -- current on fixes, never first onto a new minor.
#
# The n-0.1 rule:
#   Deliberately NOT called "n-1", which reads as one MAJOR back. The step is
#   one tenth: 9.2 -> 9.1, never 9.x -> 8.x.
#
#   - MAJOR: unchanged, always
#   - MINOR: max(installed_minor, second-highest minor offered by the repo)
#   - PATCH: latest available within that minor
#
#   Each package resolves against ITS OWN version series. They do not share a
#   numbering scheme -- see the PIN_PACKAGES comment below for why assuming
#   they did produced the exact opposite of this policy in production.
#
# Example (pve-manager):
#   Repo offers 9.2.3, 9.1.5, 9.0.8   -> pin 9.1.* (takes up to 9.1.5)
#   Repo offers 9.1.x only            -> pin 9.1.* (nothing to step back to)
#   Repo offers 9.0.x only            -> pin 9.0.* (cannot go below .0)
#   Installed 9.2.1, repo latest 9.2  -> pin 9.2.* (never downgrades)
#
# Usage:
#   sudo ./proxmox-update-policy.sh [command]
#
# Commands:
#   enable      - Enable conservative update policy (default)
#   disable     - Disable policy and allow all updates
#   ui-only     - Suppress subscription warnings WITHOUT pinning anything
#   ui-disable  - Remove the UI customisation, leave pinning alone
#   status      - Show current policy and pinned versions
#   update      - Refresh pinning based on current repo state
#   cron-enable - Install daily cron job to auto-update pinning
#   cron-disable- Remove the cron job
#
# Pinning and the UI customisation are INDEPENDENT. A host can hold its
# packages back, suppress the subscription warnings, both, or neither. They
# were previously welded together -- the APT hook gated on the pinning file --
# so a host that wanted latest packages silently got the warnings back with no
# way to say otherwise.
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

# The served copy above lives in a pve-manager-owned directory, so a package
# update can delete it. This is the master copy, outside anything dpkg manages:
# it is both the marker that the customisation is installed and the source the
# APT hook restores from.
UI_STATE_DIR="/usr/local/share/proxmox-conservative"
UI_STATE_JS="${UI_STATE_DIR}/conservative-policy.js"

# Packages to pin, and how each of them is actually versioned.
#
# These packages do NOT share a version series. Pinning them all to
# pve-manager's series -- as this script did before 2026-07 -- matched only
# proxmox-ve and pve-manager; every other entry silently pinned nothing:
#
#   pve-manager             9.1.4    PVE release series      pin matched
#   proxmox-ve              9.1.0    PVE release series      pin matched
#   pve-qemu-kvm           10.1.2    QEMU upstream series    never matched
#   pve-container           6.0.x    own series              never matched
#   pve-firewall            6.0.x    own series              never matched
#   pve-ha-manager          5.0.x    own series              never matched
#   proxmox-backup-client   4.1.1    PBS series              never matched
#   proxmox-widget-toolkit  5.0.x    own series              never matched
#   pve-kernel-*                     not a package name      never matched
#   zfsutils-linux          2.3.x    OpenZFS series          not listed
#
# The net effect was the inverse of the stated intent: it held back the
# management UI while letting the kernel, QEMU, ZFS and the PBS client run to
# latest -- exactly the components a conservative policy exists to hold back.
# Verified on a live host running pve-manager 9.1.4 with the kernel, QEMU and
# ZFS all free to jump a major version.
#
# Each package is now pinned against ITS OWN series, resolved from the repo at
# run time rather than assumed.
PIN_PACKAGES=(
    "proxmox-ve"
    "pve-manager"
    "pve-qemu-kvm"
    "pve-container"
    "pve-firewall"
    "pve-ha-manager"
    "pve-cluster"
    "qemu-server"
    "proxmox-backup-client"
    "proxmox-widget-toolkit"
    "zfsutils-linux"
)

# ZFS userland is split across several binary packages built from one source.
# apt refuses a transaction that moves only some of them, so anything pinned to
# the zfsutils-linux series has to carry its siblings along.
ZFS_SIBLINGS=(
    "zfs-initramfs"
    "zfs-zed"
    "libzfs*linux"
    "libzpool*linux"
    "libnvpair*linux"
    "libuutil*linux"
)

# apt_preferences(5): a priority of 1000 or more lets apt DOWNGRADE to reach the
# pin. That directly contradicts this script's "never downgrades" policy -- if
# the pin were ever computed low, apt would happily walk the host backwards.
# 999 sits in the 990..1000 band: it beats the archive default of 500, so the
# pin is honoured, but apt will not downgrade to satisfy it.
PIN_PRIORITY=999

#############################################
# Helper Functions
#############################################

#---------------------------------------------------------------
# Pure version arithmetic
#---------------------------------------------------------------
# Everything below this banner is deliberately free of apt, dpkg and the
# filesystem: it is string arithmetic on version numbers only. That is what
# makes the n-0.1 rule testable without a Proxmox host -- see
# tests/test-update-policy.sh, which sources this script and drives these
# functions directly. The apt-facing wrappers come after.

strip_epoch() {
    # Debian versions may carry an "N:" epoch (proxmox-backup-client does).
    # An epoch in a pin glob matches nothing, so it has to come off.
    local version="$1"
    echo "${version#*:}"
}

version_series() {
    # major.minor of a version string; empty if it does not start with one.
    strip_epoch "$1" | grep -oE '^[0-9]+\.[0-9]+' || true
}

series_list() {
    # Distinct major.minor series in a version list, newest first.
    local versions="$1"
    echo "$versions" | grep -oE '^([0-9]+:)?[0-9]+\.[0-9]+' | sed 's/^[0-9]*://' | sort -V -r | uniq
}

series_max() {
    # The higher of two series, comparing numerically rather than as strings
    # (9.10 beats 9.9; a lexical compare gets that backwards).
    printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1
}

resolve_target_series() {
    # THE n-0.1 RULE, in one place.
    #   $1 available versions, newest first (newline separated)
    #   $2 installed version, or empty
    # Prints the series to pin to, or fails if $1 yields no usable series.
    #
    #   MINOR  max(installed_series, second-highest series in the repo)
    #   PATCH  free within that series
    #
    # n-0.1 is taken from the repo's actual series list rather than computed by
    # subtracting one. Arithmetic gets this wrong the moment a package rolls a
    # major: one series back from pve-qemu-kvm 11.0 is 10.1, not 11.-1, and
    # only the repo knows that 10.1 was the last one. This was the shape of the
    # original bug -- assuming a numbering scheme instead of reading it.
    local versions="$1" installed="$2"
    local available latest target installed_series

    [ -z "$versions" ] && return 1

    available=$(series_list "$versions")
    [ -z "$available" ] && return 1

    latest=$(echo "$available" | head -1)
    target=$(echo "$available" | sed -n '2p')

    # "unless the current version IS the only minor version" -- with a single
    # series on offer there is nothing to step back to, so pin to it.
    [ -z "$target" ] && target="$latest"

    # Never pin below what is installed: that asks apt for a downgrade. Applied
    # last so it also overrides the single-series fallback above -- a host that
    # is somehow ahead of its repo must stay where it is, not be walked back.
    #
    # A consequence worth understanding: on a host INSTALLED AT LATEST this
    # clamp means the policy resolves to the current series rather than
    # stepping back. That is intended. The rule holds the host where it is and
    # stops the NEXT minor landing unattended; it is not a mechanism for
    # walking a working host backwards. Stepping back only happens where the
    # host is genuinely behind, which is where the floor does not bind.
    installed_series=$(version_series "$installed")
    [ -n "$installed_series" ] && target=$(series_max "$target" "$installed_series")

    echo "$target"
}

#---------------------------------------------------------------
# apt-facing wrappers
#---------------------------------------------------------------

get_installed_version() {
    local pkg="$1"
    dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || echo ""
}

get_available_versions() {
    # Every version of $1 the configured repos can offer, newest first.
    local pkg="${1:-proxmox-ve}"
    apt-cache madison "$pkg" 2>/dev/null | \
        awk -F'|' '{gsub(/ /, "", $2); print $2}' | \
        sort -V -r | \
        uniq
}

get_kernel_series() {
    # The kernel does not follow the PVE release series: the ABI lives in the
    # PACKAGE NAME (proxmox-kernel-6.14) and the version tracks that ABI
    # (6.14.11-4). The old "pve-kernel-*" glob matched nothing at all -- that
    # has not been the package name since PVE 8.
    #
    # Pin to the ABI currently installed: patch updates within the ABI still
    # flow, but a new ABI does not land unattended. Holding the kernel back is
    # the whole point of a conservative policy.
    dpkg-query -W -f='${Package}\n' 'proxmox-kernel-*' 2>/dev/null | \
        grep -E '^proxmox-kernel-[0-9]+\.[0-9]+$' | \
        sed 's/^proxmox-kernel-//' | \
        sort -V -r | \
        head -1
}

resolve_pin_series() {
    # Target series for one real package, from that package's OWN versions.
    local pkg="$1"
    resolve_target_series "$(get_available_versions "$pkg")" "$(get_installed_version "$pkg")"
}

#---------------------------------------------------------------
# Cluster coordination
#---------------------------------------------------------------
# A PVE cluster requires its nodes to run matching versions. Resolving the
# policy independently on each node does not guarantee that: a node that runs
# the cron job an hour after upstream publishes a release resolves a different
# series to one that ran before, and the cluster silently splits across two
# minors until someone notices.
#
# When the node is in a cluster, the resolved series are written to and read
# from /etc/pve -- the replicated cluster filesystem -- so whichever node
# resolves first decides for all of them, and every other node reproduces that
# decision verbatim rather than recomputing it.
#
# A standalone node has no /etc/pve/, takes the local path, and behaves exactly
# as before. That is deliberate: the same script, unchanged, is what makes a
# single-node box and a cluster node interchangeable.
#
# The standalone path is verified on a real PVE host. The CLUSTERED path is not
# -- it has only been exercised against a single node, where in_cluster() is
# false and none of the coordination below runs. Writes to /etc/pve are
# best-effort for that reason: pmxcfs is read-only without quorum, and a node
# that has lost quorum must not be able to change a cluster-wide policy.
# Treat the coordination as unproven until it has run on a real cluster.

CLUSTER_POLICY_FILE="/etc/pve/proxmox-conservative-series"

in_cluster() {
    # pmxcfs mounts /etc/pve on any PVE host, clustered or not; the
    # corosync config is what actually distinguishes a cluster member.
    [ -f /etc/pve/corosync.conf ]
}

cluster_series_get() {
    # Series previously agreed for package $1, or empty.
    local pkg="$1"
    [ -r "$CLUSTER_POLICY_FILE" ] || return 0
    awk -F'=' -v p="$pkg" '$1 == p { print $2; exit }' "$CLUSTER_POLICY_FILE"
}

cluster_series_put() {
    # Record the agreed series for package $1. Best-effort: /etc/pve is
    # read-only when the node has lost quorum, and a node without quorum has no
    # business changing a cluster-wide policy anyway.
    local pkg="$1" series="$2" tmp

    [ -d /etc/pve ] || return 0
    tmp=$(mktemp) || return 0

    if [ -r "$CLUSTER_POLICY_FILE" ]; then
        grep -v "^${pkg}=" "$CLUSTER_POLICY_FILE" > "$tmp" 2>/dev/null || true
    fi
    echo "${pkg}=${series}" >> "$tmp"

    cp "$tmp" "$CLUSTER_POLICY_FILE" 2>/dev/null || true
    rm -f "$tmp"
    return 0
}

resolve_pin_series_coordinated() {
    # Standalone: resolve locally.
    # Clustered:  reuse the cluster's agreed series if one exists, otherwise
    #             resolve locally and publish it for the other nodes.
    local pkg="$1" series

    if ! in_cluster; then
        resolve_pin_series "$pkg"
        return 0
    fi

    series=$(cluster_series_get "$pkg")
    if [ -n "$series" ]; then
        echo "$series"
        return 0
    fi

    series=$(resolve_pin_series "$pkg")
    [ -n "$series" ] && cluster_series_put "$pkg" "$series"
    echo "$series"
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
INDEX_BACKUP="${BACKUP_DIR}/index.html.tpl.original"

replace_once() {
    # replace_once <file> <search> <replace>
    #
    # Literal, unambiguous, in-place replacement. Refuses unless the search
    # text occurs EXACTLY once, so an edit can never land somewhere unintended.
    #
    # This replaced a `patch --ignore-whitespace -f` approach that fed patch(1)
    # placeholder hunk headers ("@@ -1 +1 @@"). With no usable line numbers
    # patch falls back to fuzzy matching, and a short repeated line such as
    # "'exclamation-circle warning'," occurs in dozens of places in an 850 KB
    # bundle -- so it could, and did, edit the wrong one.
    local file="$1" search="$2" replace="$3"
    local count

    [ -f "$file" ] || return 1
    count=$(grep -F -c -- "$search" "$file" 2>/dev/null || true)
    [ -z "$count" ] && count=0
    [ "$count" -eq 1 ] || return 1

    # perl rather than sed: \Q..\E quotes the search literally, so no character
    # in either string needs escaping. perl is always present on a PVE host --
    # pve-manager itself is written in it.
    # LC_ALL=C: an SSH session forwarding LC_* that the host lacks makes perl
    # emit a block of locale warnings on every call. They are harmless and they
    # bury the script's real output.
    LC_ALL=C SEARCH="$search" REPLACE="$replace" perl -0777 -i -pe '
        BEGIN { $s = $ENV{SEARCH}; $r = $ENV{REPLACE}; }
        my $n = s/\Q$s\E/$r/;
        die "expected exactly one replacement, made $n\n" unless $n == 1;
    ' "$file"
}

write_policy_js() {
    # The whole customisation, as an ExtJS override.
    #
    # Written to the master copy; install_policy_js puts it where pveproxy
    # serves it from. Tests point POLICY_JS at a temporary path, so the two
    # stay separate rather than one being derived from the other.
    mkdir -p "$(dirname "$POLICY_JS")"
    cat > "$POLICY_JS" << 'POLICY_JS_EOF'
// Conservative Update Policy - UI customisation
// Installed by: proxmox-update-policy.sh
//
// This file is ADDITIVE. It does not modify any Proxmox source file.
// Everything below is an ExtJS override, which is the framework's own
// supported extension mechanism, so it survives proxmox-widget-toolkit and
// pve-manager package updates untouched.
//
// It replaced an approach that text-patched proxmoxlib.js in seven places.
// That broke on every PVE release which restructured the file -- on PVE 9.2.5
// only two of the seven still matched -- and because the patches carried
// placeholder line numbers, patch(1) fuzzy-matched short repeated lines and
// could edit an unintended one. The only file still touched is
// index.html.tpl, which gains a single <script> tag.
//
// Intent: state the update policy that is actually in force. This relabels
// repository status. It does NOT represent the host as holding a subscription
// and does not alter what the host is entitled to.
//
// Fail-safe by construction: every hook is guarded, and if upstream renames
// what is hooked, the original Proxmox behaviour is left in place. The failure
// mode is "the warning comes back", never a broken UI.
//
// Deleting this file restores stock behaviour completely.
(function () {
    'use strict';

    if (typeof Ext === 'undefined' || typeof Proxmox === 'undefined') {
        return;
    }

    var POLICY_TEXT =
        'Conservative update policy active (one minor back, latest patch)';
    var NOSUB = /no-subscription/i;
    var NOT_PROD = /not recommended for production|NOT production-ready|not the best choice/i;

    Proxmox.Utils = Proxmox.Utils || {};
    Proxmox.Utils.conservativePolicyActive = true;

    // 1. The "You do not have a valid subscription" modal shown after login.
    //
    // Upstream routes commands through a subscription check. Call the command
    // directly instead. Guarded, so if the function is renamed or removed
    // upstream this simply does nothing.
    if (typeof Proxmox.Utils.checked_command === 'function') {
        Proxmox.Utils.checked_command = function (orig_cmd) {
            if (typeof orig_cmd === 'function') {
                orig_cmd();
            }
        };
    }

    // 2. The repository status panel.
    //
    // Rather than reimplementing upstream's checks -- which would go stale and
    // stop reflecting new ones -- let updateState() run and then rewrite the
    // entries it produced. Matching is on content, not on source structure.
    if (Ext.ClassManager && Ext.ClassManager.get('Proxmox.node.APTRepositories')) {
        Ext.define('ConservativePolicy.override.APTRepositories', {
            override: 'Proxmox.node.APTRepositories',

            // afterRender, NOT initComponent. A ViewModel is resolved against
            // the component's position in the container hierarchy, which is not
            // settled during initComponent -- getViewModel() there can return
            // null, and the whole override would silently do nothing. By
            // afterRender the component is in the hierarchy and the store the
            // repository check writes into definitely exists.
            afterRender: function () {
                var me = this;
                me.callParent(arguments);

                // afterRender can fire again if the panel is re-rendered;
                // attaching the listener twice would double-count.
                if (me.conservativePolicyHooked) {
                    return;
                }

                var vm = me.getViewModel ? me.getViewModel() : null;
                if (!vm) {
                    return;
                }

                var store = vm.get('errorstore');
                if (!store || typeof store.on !== 'function') {
                    return;
                }

                var rewriting = false;
                var rewrite = function () {
                    if (rewriting) {
                        return;
                    }
                    rewriting = true;
                    try {
                        var replaced = 0;
                        var remaining = 0;

                        store.each(function (rec) {
                            var message = String(rec.get('message') || '');
                            var status = rec.get('status');

                            if (
                                status === 'warning' &&
                                NOSUB.test(message) &&
                                NOT_PROD.test(message)
                            ) {
                                rec.set('status', 'good');
                                rec.set('message', POLICY_TEXT);
                                replaced += 1;
                            } else if (status !== 'good') {
                                remaining += 1;
                            }
                        });

                        // Only claim overall health when the no-subscription
                        // warnings were the ONLY thing wrong. A real problem --
                        // a misconfigured suite, a parse error, an enterprise
                        // repo without a subscription -- must still surface.
                        if (
                            replaced > 0 &&
                            remaining === 0 &&
                            typeof Proxmox.Utils.get_health_icon === 'function'
                        ) {
                            vm.set('state', {
                                iconCls: Proxmox.Utils.get_health_icon('good', true),
                                text: POLICY_TEXT
                            });
                        }
                    } finally {
                        rewriting = false;
                    }
                };

                me.conservativePolicyHooked = true;
                store.on('datachanged', rewrite);
                store.on('add', rewrite);

                // The check may already have run and populated the store
                // before this listener was attached.
                rewrite();
            }
        });
    }
})();
POLICY_JS_EOF
}

# The single edit still made to a Proxmox file: load our script.
INDEX_ANCHOR='    <script type="text/javascript" src="/pve2/js/pvemanagerlib.js?ver=[% version %]"></script>'
INDEX_INSERT='    <script type="text/javascript" src="/pve2/js/conservative-policy.js"></script>
    <script type="text/javascript" src="/pve2/js/pvemanagerlib.js?ver=[% version %]"></script>'

ensure_script_tag() {
    # Idempotent. Returns 0 if the tag is present (or was just added).
    if grep -qF "conservative-policy.js" "$INDEX_TPL" 2>/dev/null; then
        return 0
    fi
    replace_once "$INDEX_TPL" "$INDEX_ANCHOR" "$INDEX_INSERT"
}

patch_ui() {
    # Install the UI customisation.
    # Returns 0 on success, 1 if it could not be applied.
    local quiet="${1:-}"

    if [ ! -f "$INDEX_TPL" ]; then
        [ -z "$quiet" ] && echo -e "${YELLOW}Index template not found, skipping UI customisation${NC}"
        return 1
    fi

    mkdir -p "$BACKUP_DIR"
    if [ ! -f "$INDEX_BACKUP" ]; then
        cp "$INDEX_TPL" "$INDEX_BACKUP"
        [ -z "$quiet" ] && echo -e "${GREEN}OK Saved $INDEX_BACKUP${NC}"
    fi

    # Master copy first, then the served copy. A pve-manager update can delete
    # the served one; the master survives and the APT hook restores from it.
    mkdir -p "$UI_STATE_DIR"
    POLICY_JS="$UI_STATE_JS" write_policy_js
    install -m 0644 "$UI_STATE_JS" "$POLICY_JS"
    [ -z "$quiet" ] && echo -e "${GREEN}OK Wrote $POLICY_JS${NC}"

    if ensure_script_tag; then
        [ -z "$quiet" ] && echo -e "${GREEN}OK Script tag present in $(basename "$INDEX_TPL")${NC}"
    else
        echo -e "${RED}Error: could not add the script tag to $INDEX_TPL${NC}"
        echo "  The expected pvemanagerlib.js line was missing or appeared more than once."
        echo "  PVE version: $(get_installed_version pve-manager)"
        echo "  Repository pinning is unaffected; only the UI customisation is."
        return 1
    fi

    if systemctl restart pveproxy.service 2>/dev/null; then
        [ -z "$quiet" ] && echo -e "${GREEN}OK pveproxy restarted${NC}"
    else
        [ -z "$quiet" ] && echo -e "${YELLOW}Note: restart pveproxy manually or refresh the browser${NC}"
    fi

    return 0
}

unpatch_ui() {
    # Restore stock UI.
    local quiet="${1:-}"
    local restored=false

    if [ -f "$UI_STATE_JS" ]; then
        rm -f "$UI_STATE_JS"
        rmdir "$UI_STATE_DIR" 2>/dev/null || true
        restored=true
    fi

    if [ -f "$POLICY_JS" ]; then
        rm -f "$POLICY_JS"
        [ -z "$quiet" ] && echo -e "${GREEN}OK Removed $POLICY_JS${NC}"
        restored=true
    fi

    if grep -qF "conservative-policy.js" "$INDEX_TPL" 2>/dev/null; then
        # Only our own line is removed; nothing else in the template is touched.
        sed -i '/conservative-policy\.js/d' "$INDEX_TPL"
        [ -z "$quiet" ] && echo -e "${GREEN}OK Removed script tag from $INDEX_TPL${NC}"
        restored=true
    fi

    # Earlier versions edited proxmoxlib.js and pvemanagerlib.js directly. A
    # host upgraded from one of those still carries those edits, and removing
    # this policy has to undo them too.
    local legacy
    for legacy in "$WIDGET_FILE" "$MANAGER_FILE"; do
        [ -f "$legacy" ] || continue
        if grep -qF "conservativePolicyActive" "$legacy" 2>/dev/null; then
            [ -z "$quiet" ] && echo -e "${YELLOW}Legacy in-place edits found in $(basename "$legacy"), reinstalling package...${NC}"
            case "$legacy" in
                *proxmox-widget-toolkit*) apt-get install --reinstall -y proxmox-widget-toolkit >/dev/null 2>&1 || true ;;
                *pve-manager*)            apt-get install --reinstall -y pve-manager >/dev/null 2>&1 || true ;;
            esac
            restored=true
        fi
    done

    if [ "$restored" = true ]; then
        systemctl restart pveproxy.service >/dev/null 2>&1 || true
    else
        [ -z "$quiet" ] && echo -e "${CYAN}UI not customised (already stock)${NC}"
    fi

    return 0
}

install_ui_hook() {
    # Reassert the customisation after a package update removes it.
    local quiet="${1:-}"

    cat > "$HOOK_SCRIPT" << 'HOOK_EOF'
#!/bin/bash
# Proxmox Conservative Update Policy - UI hook
# Installed by: proxmox-update-policy.sh -- do not edit, changes are overwritten.
#
# Runs from DPkg::Post-Invoke, so its exit status IS apt's exit status. A guard
# used as the LAST command reports failure whenever it is the one that
# short-circuits -- which is the steady state, since normally there is nothing
# to do. That made apt report an error on EVERY package operation once the
# customisation was already in place. Every exit below is explicit and the
# final line is `exit 0`.
#
# Only two things need reasserting: our own JS file, and the one <script> tag.
# Nothing here patches a Proxmox source file, so there is no `patch` dependency
# and nothing to go stale when upstream restructures its JavaScript.

INDEX_TPL="/usr/share/pve-manager/index.html.tpl"
POLICY_JS="/usr/share/pve-manager/js/conservative-policy.js"
UI_STATE_JS="/usr/local/share/proxmox-conservative/conservative-policy.js"
ANCHOR='    <script type="text/javascript" src="/pve2/js/pvemanagerlib.js?ver=[% version %]"></script>'

# Gate on the UI customisation's OWN marker, not on the pinning file. The two
# are independent: a host can suppress the subscription warnings while tracking
# latest packages, and gating on the pins meant that host silently got neither.
[ -f "$UI_STATE_JS" ] || exit 0
[ -f "$INDEX_TPL" ] || exit 0

CHANGED=0

# pve-manager updates replace index.html.tpl, dropping our tag.
if ! grep -qF "conservative-policy.js" "$INDEX_TPL" 2>/dev/null; then
    if [ "$(grep -F -c -- "$ANCHOR" "$INDEX_TPL" 2>/dev/null || echo 0)" -eq 1 ]; then
        LC_ALL=C ANCHOR="$ANCHOR" perl -0777 -i -pe '
            BEGIN { $a = $ENV{ANCHOR}; }
            my $ins = "    <script type=\"text/javascript\" src=\"/pve2/js/conservative-policy.js\"></script>\n" . $a;
            s/\Q$a\E/$ins/;
        ' "$INDEX_TPL" && CHANGED=1
    fi
fi

# The served copy lives in a pve-manager-owned directory and is removed by a
# package update. Restore it from the master copy rather than just complaining:
# the content comes from that file, so a stale hook cannot write stale content.
if [ ! -f "$POLICY_JS" ]; then
    mkdir -p "$(dirname "$POLICY_JS")"
    if install -m 0644 "$UI_STATE_JS" "$POLICY_JS" 2>/dev/null; then
        CHANGED=1
        logger -t proxmox-policy-hook "restored conservative-policy.js"
    else
        logger -t proxmox-policy-hook "could not restore conservative-policy.js from $UI_STATE_JS"
    fi
fi

# Restart pveproxy ONLY if something actually changed. Restarting it on every
# apt operation bounces the web UI and API for no benefit in the overwhelmingly
# common case where there was nothing to do.
if [ "$CHANGED" -eq 1 ]; then
    systemctl restart pveproxy.service >/dev/null 2>&1 || true
    logger -t proxmox-policy-hook "reinstated conservative-policy.js script tag"
fi

exit 0
HOOK_EOF

    chmod +x "$HOOK_SCRIPT"

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
        echo -e "${CYAN}Policy: ENABLED (conservative n-0.1)${NC}"
        echo -e "Preferences file: $PREFERENCES_FILE\n"

        # Report what the file ACTUALLY pins, per package. The previous version
        # of this output showed a single "Pinned to minor version: 9.1.*" line
        # taken from the first Pin: it found, which is the original bug in
        # miniature -- it implied one series governed everything, so a policy
        # that was pinning almost nothing still looked healthy here.
        local written
        written=$(grep -c '^Pin-Priority: [0-9]' "$PREFERENCES_FILE" 2>/dev/null || echo 0)
        echo -e "Pins written: ${CYAN}${written}${NC}"
        echo "In effect (package -> series):"
        awk '/^Package:/ { pkg = substr($0, 10) }
             /^Pin: version [0-9]/ { printf "  %-30s %s\n", pkg, substr($0, 14) }' \
            "$PREFERENCES_FILE" 2>/dev/null
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

    # UI customisation status. Both halves must be present: the override file
    # does nothing if nothing loads it, and the script tag does nothing if the
    # file it points at is gone.
    echo ""
    if [ -f "$POLICY_JS" ]; then
        echo -e "UI customization: ${GREEN}APPLIED${NC}"
        echo -e "  Override JS: $POLICY_JS"
    else
        echo -e "UI customization: ${YELLOW}NOT APPLIED${NC}"
    fi
    if grep -qF "conservative-policy.js" "$INDEX_TPL" 2>/dev/null; then
        echo -e "  Script tag:  ${GREEN}present${NC}"
    else
        echo -e "  Script tag:  ${YELLOW}missing (run 'update' to reinstate)${NC}"
    fi

    # A host upgraded from a version that edited Proxmox source in place still
    # carries those edits. They are inert but confusing, and 'disable' cleans
    # them up, so say so rather than leaving them to be discovered later.
    if grep -qF "conservativePolicyActive" "$WIDGET_FILE" 2>/dev/null || \
       grep -qF "conservativePolicyActive" "$MANAGER_FILE" 2>/dev/null; then
        echo -e "  ${YELLOW}Legacy in-place edits present in Proxmox source files.${NC}"
        echo -e "  ${YELLOW}'disable' reinstates the stock packages.${NC}"
    fi

    # Backup status
    echo ""
    echo -e "${GREEN}Backups:${NC}"
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

    local latest_minor target_minor available_minors
    available_minors=$(series_list "$versions")
    latest_minor=$(echo "$available_minors" | head -1)
    target_minor=$(resolve_target_series "$versions" "$(get_installed_version proxmox-ve)")

    echo "  Latest available: $(echo "$versions" | head -1)"
    echo "  Latest minor: $latest_minor"
    echo "  Target minor (n-0.1): $target_minor"
    if [ "$target_minor" = "$latest_minor" ]; then
        echo -e "    ${CYAN}(n-0.1 unavailable or already installed - holding at latest)${NC}"
    fi
    echo ""
    echo "  Available minor versions:"
    echo "$available_minors" | while read -r m; do
        local latest_patch
        latest_patch=$(echo "$versions" | grep -E "^([0-9]+:)?${m//./\\.}\." | head -1)
        if [ "$m" = "$target_minor" ]; then
            echo -e "    ${GREEN}- $m (target) - latest patch: $latest_patch${NC}"
        else
            echo "    - $m - latest patch: $latest_patch"
        fi
    done

    # What each package actually resolved to. The old status output showed a
    # single "Pinned to minor version" line, which was the bug in miniature: it
    # implied one series governed everything.
    echo ""
    echo -e "${GREEN}Per-package pin resolution:${NC}"
    local pkg series
    for pkg in "${PIN_PACKAGES[@]}"; do
        series=$(resolve_pin_series "$pkg")
        if [ -n "$series" ]; then
            printf '  %-26s %s.*\n' "$pkg" "$series"
        else
            printf '  %-26s %s\n' "$pkg" "(not installed / not in repo)"
        fi
    done
    series=$(get_kernel_series)
    printf '  %-26s %s\n' "proxmox-kernel-*" "${series:+${series}.*}${series:-(no ABI meta installed)}"

    echo ""
    echo -e "${GREEN}APT policy for proxmox-ve:${NC}"
    apt-cache policy proxmox-ve 2>/dev/null | grep -E "Installed|Candidate" | sed 's/^/  /'
}

enable_policy() {
    local quiet="${1:-}"
    local no_ui="${2:-}"

    [ -z "$quiet" ] && echo -e "${GREEN}=== Enabling Conservative Update Policy ===${NC}\n"

    # Refresh apt cache first.
    #
    # The output is captured rather than discarded. Sending it to /dev/null and
    # relying on `set -e` produced a silent exit 100 with no diagnostic at all,
    # which is indistinguishable from the script hanging. The commonest cause
    # is the enterprise repository: installing proxmox-ve adds
    # pve-enterprise.sources, so a host set up on the CE repos grows a 401 the
    # moment PVE itself is installed.
    [ -z "$quiet" ] && echo "Refreshing package lists..."
    local apt_log apt_rc
    apt_log=$(mktemp)
    apt-get update >"$apt_log" 2>&1 || apt_rc=$?

    if [ -n "${apt_rc:-}" ]; then
        echo -e "${RED}Error: apt-get update failed (exit ${apt_rc})${NC}"
        grep -E '^(E|W|Err):' "$apt_log" | head -10 | sed 's/^/  /'
        if grep -q 'enterprise.proxmox.com' "$apt_log"; then
            echo ""
            echo -e "${YELLOW}The enterprise repository is enabled and returns 401 without a"
            echo -e "subscription. Installing proxmox-ve re-adds it, so it comes back even"
            echo -e "on a host configured for the no-subscription repos.${NC}"
            echo ""
            echo "  sudo ./proxmox-repo.sh    # disables it again, safe to re-run"
        fi
        rm -f "$apt_log"
        echo ""
        echo "Refusing to generate a pinning policy from an incomplete package list."
        exit 1
    fi
    rm -f "$apt_log"

    # proxmox-ve still anchors the human-facing summary, but it no longer
    # dictates every other package's pin -- each one resolves its own series.
    local versions
    versions=$(get_available_versions proxmox-ve)

    if [ -z "$versions" ]; then
        echo -e "${RED}Error: Could not query available Proxmox versions${NC}"
        echo "Ensure apt sources are configured correctly"
        exit 1
    fi

    local latest_minor target_minor
    latest_minor=$(series_list "$versions" | head -1)
    target_minor=$(resolve_target_series "$versions" "$(get_installed_version proxmox-ve)")

    if [ -z "$target_minor" ]; then
        echo -e "${RED}Error: Could not determine a target series for proxmox-ve${NC}"
        exit 1
    fi

    [ -z "$quiet" ] && echo "Repository latest: $(echo "$versions" | head -1)"
    [ -z "$quiet" ] && echo "PVE latest series: $latest_minor"
    [ -z "$quiet" ] && echo "PVE target series (n-0.1): $target_minor"
    [ -z "$quiet" ] && echo ""
    [ -z "$quiet" ] && echo "Resolving each package against its own series:"

    # Build preferences file content
    local prefs_content
    prefs_content="# Proxmox VE Conservative Update Policy (n-0.1 minor)
# Generated: $(date -Iseconds)
#
# Every package below is pinned to ITS OWN version series, resolved from the
# repository when this file was generated. These packages do NOT share a
# numbering scheme: pinning them all to the PVE series pins proxmox-ve and
# pve-manager and nothing else, leaving the kernel, QEMU and ZFS free to run to
# latest -- the inverse of the intent.
#
# PVE series: ${target_minor}.* (latest available: ${latest_minor}.*)
#
# Pin-Priority ${PIN_PRIORITY} is deliberate: 1000 or above would let apt
# DOWNGRADE to reach a pin. 999 still beats the archive default of 500.
#
# Regenerate after a release: sudo proxmox-update-policy.sh update
# Remove entirely:            sudo proxmox-update-policy.sh disable

"

    local pkg series pinned=0 skipped=""

    add_pin() {
        # $1 Package: line (may hold several names/globs), $2 series
        #
        # ONE positive block per package, and deliberately no negative
        # catch-all. apt selects the highest-PRIORITY candidate and only
        # compares versions to break ties within a priority, so raising the
        # wanted series to 999 is already enough to hold a 500-priority newer
        # version back. This is asserted in tests/test-apt-pinning.sh.
        #
        # A catch-all "Pin: version * / Pin-Priority: -1" block looks like
        # belt-and-braces and is a trap. Whenever the pinned series is not
        # actually present for a package -- a package renamed upstream, a
        # series retired from the archive, or simply a series that never
        # existed for that package -- the negative block leaves it with NO
        # selectable version at all. apt reports "Candidate: (none)", anything
        # depending on it fails to install, and the host silently stops
        # receiving security updates.
        #
        # Without it, the same situation degrades safely: apt falls back to
        # what the archive offers, so the policy stops holding rather than
        # wedging the package manager. A policy that visibly stops working
        # beats one that quietly bricks apt. Both behaviours are asserted in
        # tests/test-apt-pinning.sh.
        prefs_content+="Package: $1
Pin: version ${2}.*
Pin-Priority: ${PIN_PRIORITY}

"
        pinned=$((pinned + 1))
        [ -z "$quiet" ] && printf '  %-26s -> %s.*\n' "$1" "$2"
    }

    if in_cluster; then
        [ -z "$quiet" ] && echo -e "${CYAN}  Cluster member -- series coordinated via $CLUSTER_POLICY_FILE${NC}"
    fi

    for pkg in "${PIN_PACKAGES[@]}"; do
        series=$(resolve_pin_series_coordinated "$pkg")
        if [ -z "$series" ]; then
            # Not every package exists on every install (pve-ha-manager on a
            # single node, proxmox-backup-client if never installed). Pinning a
            # package apt has never heard of is harmless but dishonest in the
            # status output, so record it instead.
            skipped+=" $pkg"
            continue
        fi
        add_pin "$pkg" "$series"
    done

    # ZFS userland ships as several binary packages from one source, and apt
    # refuses a transaction that moves only some of them. They all follow
    # zfsutils-linux.
    local zfs_series
    zfs_series=$(resolve_pin_series_coordinated "zfsutils-linux")
    if [ -n "$zfs_series" ]; then
        add_pin "${ZFS_SIBLINGS[*]}" "$zfs_series"
    fi

    # The kernel is pinned by ABI, not by PVE series -- see get_kernel_series.
    # In a cluster the ABI is coordinated like everything else: live migration
    # between nodes running different kernel ABIs is where subtle guest
    # problems come from, so all nodes hold the same one.
    local kernel_series
    if in_cluster; then
        kernel_series=$(cluster_series_get "proxmox-kernel")
        if [ -z "$kernel_series" ]; then
            kernel_series=$(get_kernel_series)
            [ -n "$kernel_series" ] && cluster_series_put "proxmox-kernel" "$kernel_series"
        fi
    else
        kernel_series=$(get_kernel_series)
    fi
    if [ -n "$kernel_series" ]; then
        add_pin "proxmox-kernel-* proxmox-headers-*" "$kernel_series"
    else
        skipped+=" proxmox-kernel-*"
    fi

    if [ -n "$skipped" ] && [ -z "$quiet" ]; then
        echo -e "${CYAN}  Not installed / not in repo, no pin written:${NC}$skipped"
    fi

    # A run that resolves nothing must not silently replace a working policy
    # file with an empty one -- that would leave the host wide open while
    # status still reported ENABLED.
    if [ "$pinned" -eq 0 ]; then
        echo -e "${RED}Error: no package resolved to a version series${NC}"
        echo "Refusing to write an empty policy. Check 'apt-get update' succeeded."
        exit 1
    fi

    # Write preferences file
    echo "$prefs_content" > "$PREFERENCES_FILE"
    [ -z "$quiet" ] && echo -e "${GREEN}OK Created $PREFERENCES_FILE (${pinned} pins)${NC}"

    # Apply UI patches (replace scary warnings with policy info)
    if [ -z "$no_ui" ]; then
        [ -z "$quiet" ] && echo ""
        [ -z "$quiet" ] && echo -e "${YELLOW}Applying UI customizations...${NC}"
        # patch_ui returns 1 when the PVE UI files are absent. Unguarded under
        # `set -e` that aborts the whole run *after* the preferences file has
        # been written but before the APT hook is installed, leaving the policy
        # half-applied and unable to survive the next package update.
        patch_ui "$quiet" || true
        install_ui_hook "$quiet" || true
    else
        [ -z "$quiet" ] && echo ""
        [ -z "$quiet" ] && echo -e "${CYAN}Skipping UI customizations (--no-ui)${NC}"
    fi

    [ -z "$quiet" ] && echo ""
    [ -z "$quiet" ] && echo -e "${GREEN}Conservative update policy enabled.${NC}"
    [ -z "$quiet" ] && echo ""
    [ -z "$quiet" ] && echo "Policy (n-0.1: one minor back, latest patch):"
    [ -z "$quiet" ] && echo "  - ${pinned} pins written, each against its own version series"
    [ -z "$quiet" ] && echo "  - PVE held at $target_minor.x; patch updates within it still install"
    if [ "$target_minor" = "$latest_minor" ]; then
        # Saying "$latest_minor will NOT auto-install" here would be nonsense --
        # it IS the series being held. Report what is actually true instead.
        [ -z "$quiet" ] && echo "  - $target_minor is the newest series available, so nothing is held back yet"
        [ -z "$quiet" ] && echo "  - The next minor will not auto-install once it appears"
    else
        [ -z "$quiet" ] && echo "  - PVE $latest_minor.x will NOT auto-install"
    fi
    [ -z "$quiet" ] && echo ""
    [ -z "$quiet" ] && echo "The pinning updates automatically when:"
    [ -z "$quiet" ] && echo "  - You run: sudo $0 update"
    [ -z "$quiet" ] && echo "  - Cron job runs (if enabled with: sudo $0 cron-enable)"
}

disable_policy() {
    echo -e "${GREEN}=== Disabling Conservative Update Policy ===${NC}\n"

    if [ -f "$PREFERENCES_FILE" ]; then
        rm -f "$PREFERENCES_FILE"
        echo -e "${GREEN}OK Removed $PREFERENCES_FILE${NC}"

        # The coordinated series live on the replicated cluster filesystem, so
        # removing them here removes them for every node. That is the intended
        # meaning of "disable" on a cluster -- leaving them would have the next
        # node to run `enable` silently reinstate the old decision.
        if in_cluster && [ -f "$CLUSTER_POLICY_FILE" ]; then
            rm -f "$CLUSTER_POLICY_FILE"
            echo -e "${GREEN}OK Removed $CLUSTER_POLICY_FILE (cluster-wide)${NC}"
        fi

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
# This job refreshes the APT pinning daily to track n-0.1 minor version

# Run quietly, only output on error
"$SCRIPT_PATH" update --quiet 2>&1 | logger -t proxmox-update-policy
EOF

    chmod +x "$CRON_FILE"
    echo -e "${GREEN}OK Installed $CRON_FILE${NC}"
    echo ""
    echo "The pinning will now update daily to track the n-0.1 minor version."
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
    echo "Usage: Usage: $0 {enable|disable|status|update|cron-enable|cron-disable} [options] {enable|disable|ui-only|ui-disable|status|update|cron-enable|cron-disable} [options]"
    echo ""
    echo "Commands:"
    echo "  enable       - Enable policy (pin to n-0.1 minor version)"
    echo "  disable      - Disable policy (allow all updates)"
    echo "  ui-only      - Suppress subscription warnings WITHOUT pinning"
    echo "  ui-disable   - Remove the UI customisation, leave pinning alone"
    echo "  status       - Show current policy and available versions"
    echo "  update       - Refresh pinning based on current repo state"
    echo "  cron-enable  - Install daily cron job to auto-update pinning"
    echo "  cron-disable - Remove the daily cron job"
    echo ""
    echo "Options:"
    echo "  --no-ui      - Skip UI customizations (keep original warnings)"
    echo "  --quiet      - Minimal output (for cron/scripts)"
    echo ""
    echo "The n-0.1 rule:"
    echo "  One MINOR back, latest PATCH within it. Not 'n-1' -- the step is a"
    echo "  tenth, never a major: 9.2 -> 9.1, never 9.x -> 8.x."
    echo ""
    echo "  MAJOR: unchanged, always"
    echo "  MINOR: max(installed, second-highest minor the repo offers)"
    echo "  PATCH: latest available within that minor"
    echo ""
    echo "  Each package resolves against its OWN version series -- pve-qemu-kvm"
    echo "  is on 10.x and zfsutils-linux on 2.x while PVE is on 9.x."
    echo ""
    echo "UI customizations:"
    echo "  When enabled, replaces Proxmox 'not recommended for production'"
    echo "  warnings with 'Conservative update policy active' messages."
    echo "  Changes warning icons/colors to green success indicators."
    echo "  APT hook maintains patches across package updates."
    echo ""
    echo "Example:"
    echo "  $0 enable            # Enable with UI patches"
    echo "  $0 enable --no-ui    # Enable without UI patches"
    echo "  Repo offers 9.2.3 and 9.1.5  -> pins 9.1.*"
    echo "  Repo offers 9.1.x only       -> pins 9.1.* (nothing to step back to)"
    echo "  Repo offers 9.0.5 only       -> pins 9.0.* (cannot go below .0)"
}

#############################################
# Main
#############################################

# Sourcing this file defines the functions without running anything, so the
# version arithmetic behind the n-0.1 rule can be unit-tested on any machine --
# no Proxmox, no root, no apt. See tests/test-update-policy.sh.
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    return 0
fi

# Root is required to execute, but not to source: the guard lives here rather
# than at the top of the file so the tests can load the functions unprivileged.
[ "$EUID" -ne 0 ] && { echo "Run as root"; exit 1; }

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
    ui-only)
        # Suppress the subscription warnings WITHOUT pinning anything.
        #
        # The two are independent concerns and were previously welded together:
        # the hook gated on the pinning file, so a host that wanted latest
        # packages silently got the warnings back with no way to say otherwise.
        echo -e "${GREEN}=== UI Customisation Only (no version pinning) ===${NC}\n"
        patch_ui "" || exit 1
        install_ui_hook "" || exit 1
        echo ""
        echo "The subscription warnings are suppressed. No packages are pinned:"
        echo "this host tracks whatever the repository offers."
        echo ""
        echo "To pin as well:  sudo $0 enable"
        echo "To undo:         sudo $0 ui-disable"
        ;;
    ui-disable)
        echo -e "${GREEN}=== Removing UI Customisation ===${NC}\n"
        remove_ui_hook ""
        unpatch_ui ""
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
