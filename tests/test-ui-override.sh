#!/bin/bash

#############################################
# Tests for the UI customisation
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
#   The UI customisation is one injected JavaScript file plus one edit to
#   index.html.tpl. Both are checked here without needing Proxmox:
#
#     - the generated JavaScript parses (a syntax error would silently break
#       the whole web UI, since the browser aborts the script)
#     - replace_once refuses ambiguous and absent matches, which is what stops
#       an edit landing in the wrong place
#     - the index.html.tpl edit is exact and idempotent
#
#   What is NOT covered: the visual result in a browser. Nothing here proves a
#   warning is actually relabelled on screen -- that needs a real PVE and a
#   browser. See tests/nested-pve.md.
#
# Usage:
#   ./tests/test-ui-override.sh
#
#############################################

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY_SCRIPT="${SCRIPT_DIR}/../postinstall/proxmox-update-policy.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=/dev/null
source "$POLICY_SCRIPT"

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
echo -e "\n${CYAN}generated JavaScript${NC}"
#############################################

POLICY_JS="$WORK/conservative-policy.js"
write_policy_js

check "file written" "yes" "$(if [ -s "$POLICY_JS" ]; then echo yes; else echo no; fi)"

# A syntax error here takes out the entire Proxmox web UI: the browser aborts
# the script and every later definition is lost. Parse it with whatever
# JavaScript engine is available.
JS_ENGINE=""
for candidate in node nodejs quickjs d8; do
    if command -v "$candidate" >/dev/null 2>&1; then
        JS_ENGINE="$candidate"
        break
    fi
done

if [ -n "$JS_ENGINE" ]; then
    case "$JS_ENGINE" in
        node|nodejs) syntax_out=$("$JS_ENGINE" --check "$POLICY_JS" 2>&1); syntax_rc=$? ;;
        *)           syntax_out=$("$JS_ENGINE" "$POLICY_JS" 2>&1); syntax_rc=$? ;;
    esac
    check "parses cleanly ($JS_ENGINE)" "0" "$syntax_rc"
    [ "$syntax_rc" -ne 0 ] && echo "$syntax_out" | head -5 | sed 's/^/       /'
else
    echo -e "  ${YELLOW}skip${NC} no JavaScript engine available to parse-check"
fi

# Balanced delimiters are a cheap proxy when no engine is present, and catch
# the most likely heredoc-mangling failure.
check "braces balanced" \
    "$(grep -o '{' "$POLICY_JS" | wc -l)" "$(grep -o '}' "$POLICY_JS" | wc -l)"
check "parens balanced" \
    "$(grep -o '(' "$POLICY_JS" | wc -l)" "$(grep -o ')' "$POLICY_JS" | wc -l)"

# The heredoc is quoted, so shell expansion must NOT have happened. A leaked
# "${...}" would mean the JS was built with the host's shell variables in it.
# shellcheck disable=SC2016  # literal '${' is exactly what is being searched for
check "no shell expansion leaked in" "0" "$(grep -c '\${' "$POLICY_JS")"

# Guards that make the override fail-safe rather than fail-broken.
check "guards on Ext being present" "1" \
    "$(grep -c "typeof Ext === 'undefined'" "$POLICY_JS")"
check "guards checked_command exists" "1" \
    "$(grep -c "typeof Proxmox.Utils.checked_command === 'function'" "$POLICY_JS")"
check "guards the class exists" "1" \
    "$(grep -c "Ext.ClassManager.get('Proxmox.node.APTRepositories')" "$POLICY_JS")"

# It must never claim overall health while a real problem is outstanding.
check "only claims good when nothing else is wrong" "1" \
    "$(grep -c 'remaining === 0' "$POLICY_JS")"

# Every class definition must be an OVERRIDE, never a redefinition. Redefining
# a Proxmox class would replace upstream's implementation wholesale and go
# stale silently; an override composes with whatever upstream ships.
check "every Ext.define is an override" \
    "$(grep -c 'Ext.define(' "$POLICY_JS")" "$(grep -c "override: '" "$POLICY_JS")"

# Reassigning a Proxmox.Utils function is the one non-override hook, and it is
# deliberate. Assert it is the ONLY one, so a future edit cannot quietly add
# more surface without this test noticing.
check "exactly one direct function replacement" "1" \
    "$(grep -cE '^[[:space:]]*Proxmox\.Utils\.[a-z_]+ = function' "$POLICY_JS")"

#############################################
echo -e "\n${CYAN}replace_once${NC}"
#############################################

printf 'alpha\nbeta\ngamma\n' > "$WORK/once.txt"
check "replaces a unique match" "0" \
    "$(replace_once "$WORK/once.txt" "beta" "BETA"; echo $?)"
check "result is correct" "BETA" "$(sed -n 2p "$WORK/once.txt")"

# Refusing on ambiguity is the whole point: it is what stops an edit landing on
# the wrong one of many identical lines.
printf 'dup\ndup\n' > "$WORK/dup.txt"
check "refuses an ambiguous match" "1" \
    "$(replace_once "$WORK/dup.txt" "dup" "CHANGED"; echo $?)"
check "leaves the file untouched" "dup" "$(sed -n 1p "$WORK/dup.txt")"

printf 'alpha\n' > "$WORK/missing.txt"
check "refuses an absent match" "1" \
    "$(replace_once "$WORK/missing.txt" "nothere" "X"; echo $?)"

check "refuses a missing file" "1" \
    "$(replace_once "$WORK/nosuchfile" "a" "b"; echo $?)"

# Regex metacharacters must be treated literally, not as a pattern.
printf 'value = a.b[0] (x)\n' > "$WORK/meta.txt"
check "treats metacharacters literally" "0" \
    "$(replace_once "$WORK/meta.txt" 'a.b[0] (x)' 'SAFE'; echo $?)"
check "metacharacter result" "value = SAFE" "$(cat "$WORK/meta.txt")"

# A literal match must not be found via regex interpretation.
printf 'axb\n' > "$WORK/nometa.txt"
check "does not regex-match a.b against axb" "1" \
    "$(replace_once "$WORK/nometa.txt" 'a.b' 'X'; echo $?)"

#############################################
echo -e "\n${CYAN}index.html.tpl edit${NC}"
#############################################

INDEX_TPL="$WORK/index.html.tpl"
cat > "$INDEX_TPL" << 'TPL'
<!DOCTYPE html>
<html>
  <head>
    <script type="text/javascript" src="/proxmoxlib.js?ver=[% wtversion %]"></script>
    <script type="text/javascript" src="/pve2/js/pvemanagerlib.js?ver=[% version %]"></script>
  </head>
</html>
TPL

check "adds the script tag" "0" "$(ensure_script_tag; echo $?)"
check "tag is present" "1" "$(grep -c 'conservative-policy.js' "$INDEX_TPL")"

# It must load BEFORE pvemanagerlib.js, or the override is applied after the
# code that uses it.
policy_line=$(grep -n 'conservative-policy.js' "$INDEX_TPL" | cut -d: -f1)
manager_line=$(grep -n 'pvemanagerlib.js' "$INDEX_TPL" | cut -d: -f1)
check "loads before pvemanagerlib.js" "yes" \
    "$(if [ "$policy_line" -lt "$manager_line" ]; then echo yes; else echo no; fi)"

# Re-running must not add it twice.
ensure_script_tag
ensure_script_tag
check "idempotent" "1" "$(grep -c 'conservative-policy.js' "$INDEX_TPL")"

# On a template that does not contain the anchor, it must decline rather than
# guess where to put it.
printf '<html><head></head></html>\n' > "$WORK/odd.tpl"
INDEX_TPL="$WORK/odd.tpl"
check "declines when the anchor is absent" "1" "$(ensure_script_tag; echo $?)"

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
