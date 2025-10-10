# Contributing to Proxmox Post-Installation Toolkit

Thank you for your interest in contributing to the Proxmox Post-Installation Toolkit! This document provides guidelines and best practices for contributing to this project.

---

## Table of Contents

1. [Code of Conduct](#code-of-conduct)
2. [Getting Started](#getting-started)
3. [Development Guidelines](#development-guidelines)
4. [Coding Standards](#coding-standards)
5. [Testing Requirements](#testing-requirements)
6. [Commit Guidelines](#commit-guidelines)
7. [Pull Request Process](#pull-request-process)
8. [Character & Emoji Policy](#character--emoji-policy)
9. [Release Process](#release-process)

---

## Code of Conduct

### Our Pledge

We are committed to providing a welcoming and inclusive environment for all contributors. We expect all participants to:

- Be respectful and professional
- Accept constructive criticism gracefully
- Focus on what is best for the community
- Show empathy towards other community members

### Unacceptable Behavior

- Harassment, trolling, or discriminatory comments
- Personal attacks or insults
- Publishing others' private information
- Any conduct that would be inappropriate in a professional setting

### Enforcement

Violations may result in temporary or permanent ban from the project. Report violations to the project maintainers.

---

## Getting Started

### Prerequisites

Before contributing, ensure you have:

1. **Test Environment**
   - Proxmox VE 9.x installation (VM or physical)
   - Debian 13 (Trixie) base system
   - Root access for testing
   - Snapshot/backup capability for rollback

2. **Development Tools**
   - Git for version control
   - Bash 5.x or higher
   - ShellCheck for linting
   - Text editor with shell script support

3. **Knowledge**
   - Bash scripting fundamentals
   - Linux system administration
   - Proxmox VE architecture
   - Semantic versioning principles

### Fork and Clone

```bash
# Fork the repository on GitHub
# Then clone your fork
git clone https://github.com/YOUR_USERNAME/proxmox-postinstall.git
cd proxmox-postinstall/postinstall

# Add upstream remote
git remote add upstream https://github.com/ORIGINAL_OWNER/proxmox-postinstall.git
```

---

## Development Guidelines

### Design Principles

1. **Idempotency**
   - All scripts MUST be idempotent (safe to run multiple times)
   - Check current state before applying changes
   - Skip already-configured settings with clear messaging

2. **Safety First**
   - Never risk data loss
   - Create backups before modifications
   - Provide rollback information
   - Use conservative defaults

3. **Error Handling**
   - Use `set -e` or `set -eE` with traps
   - Catch and handle errors gracefully
   - Provide clear error messages with context
   - Continue on non-critical errors when safe

4. **User Experience**
   - Clear, colored console output
   - Progress indicators
   - Informative status messages
   - Complete documentation

### Script Structure

All scripts should follow this structure:

```bash
#!/bin/bash

#############################################
# Script Name
# Brief description
# Version: X.Y.Z
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
#   Detailed explanation of what this script does
#
# Usage:
#   sudo ./script-name.sh
#
# Requirements:
#   - Proxmox VE 9.x
#   - Debian 13 (Trixie)
#   - Root privileges
#
# Idempotent: Yes/No
# Requires Reboot: Yes/No
# Backup Location: /path/to/backup
#
#############################################

set -e
trap 'error_handler $? $LINENO' ERR

# Error handler
error_handler() {
    echo -e "${RED}Error at line $2 (exit code: $1)${NC}"
    # Additional error handling
}

# Colors (following character policy)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Root check
[ $EUID -ne 0 ] && { echo "Must run as root"; exit 1; }

# Main script logic...
```

---

## Coding Standards

### Shell Script Standards

1. **ShellCheck Compliance**
   ```bash
   # All scripts must pass ShellCheck with no errors
   shellcheck -x script-name.sh
   ```

2. **Bash Best Practices**
   - Use `#!/bin/bash` (not `/bin/sh`)
   - Quote all variables: `"$variable"`
   - Use `[[` instead of `[` for conditionals
   - Prefer `$(command)` over backticks
   - Use meaningful variable names in UPPER_CASE

3. **Functions**
   ```bash
   # Use functions for repeated logic
   function_name() {
       local param1="$1"
       local param2="$2"
       # Function body
   }
   ```

4. **Conditionals**
   ```bash
   # Check existence before acting
   if [ -f "$file" ]; then
       # Do something
   fi

   # Use idempotent checks
   if ! grep -q "setting" "$config"; then
       echo "setting" >> "$config"
   fi
   ```

### Documentation Standards

1. **Inline Comments**
   - Explain WHY, not WHAT
   - Document non-obvious logic
   - Add warnings for dangerous operations

2. **Section Headers**
   ```bash
   #############################################
   # Section Name
   #############################################
   echo -e "\n${YELLOW}[X/Y] Section description...${NC}"
   ```

3. **Variable Documentation**
   ```bash
   # Brief description of variable purpose
   VARIABLE_NAME="value"
   ```

---

## Testing Requirements

### Before Submitting

1. **Static Analysis**
   ```bash
   # Run ShellCheck
   shellcheck -x *.sh

   # Check for common issues
   grep -n "TODO\|FIXME\|XXX" *.sh
   ```

2. **Manual Testing**
   - Test on fresh Proxmox VE 9.x installation
   - Run script at least twice (verify idempotency)
   - Test with Intel AND AMD systems (if applicable)
   - Verify all created commands work
   - Check backup files are created

3. **Verification Checklist**
   - [ ] Script runs without errors
   - [ ] Idempotent (safe to run multiple times)
   - [ ] Backups created in correct location
   - [ ] Status messages are clear and helpful
   - [ ] Error handling works correctly
   - [ ] All created commands are functional
   - [ ] Documentation is accurate
   - [ ] No hardcoded paths (use variables)
   - [ ] Character policy compliance

### Test Environment Setup

```bash
# Create test snapshot before running
pvesh create /nodes/NODE/snapshot -vmid VMID -snapname pre-test

# Run script
sudo ./script-name.sh

# Verify changes
# Run verification commands...

# Test idempotency
sudo ./script-name.sh

# Rollback if needed
pvesh delete /nodes/NODE/snapshot -vmid VMID -snapname pre-test
```

---

## Commit Guidelines

### Commit Message Format

We follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <subject>

<body>

<footer>
```

**Types:**
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `style`: Code style changes (formatting, no logic change)
- `refactor`: Code refactoring
- `test`: Adding or updating tests
- `chore`: Maintenance tasks

**Examples:**
```
feat(power): add thermal monitoring to power management

- Move thermal-check from optimize to power script
- Add temperature display to power-status
- Include thermal warnings for 75C, 85C, 95C thresholds

Closes #123
```

```
fix(optimize): correct step numbering after nag removal

The subscription nag removal was deleted, reducing total
steps from 9 to 7. Updated all step indicators.
```

```
docs(readme): add troubleshooting section

Added common issues and solutions for:
- IOMMU enablement
- Power management setup
- ZFS configuration
```

### Commit Best Practices

- Keep commits atomic (one logical change)
- Write clear, descriptive messages
- Reference issues when applicable
- Sign commits if possible: `git commit -s`

---

## Pull Request Process

### Before Creating PR

1. **Update your fork**
   ```bash
   git fetch upstream
   git rebase upstream/main
   ```

2. **Run quality checks**
   ```bash
   shellcheck -x *.sh
   # Fix any issues
   ```

3. **Update documentation**
   - Update README.md if adding features
   - Add entry to CHANGELOG.md
   - Update script headers with version info

### Creating the PR

1. **Push to your fork**
   ```bash
   git push origin feature-branch
   ```

2. **Open PR on GitHub**
   - Use a clear, descriptive title
   - Fill out the PR template completely
   - Link related issues
   - Add screenshots/output if applicable

3. **PR Description Template**
   ```markdown
   ## Description
   Brief description of changes

   ## Type of Change
   - [ ] Bug fix
   - [ ] New feature
   - [ ] Breaking change
   - [ ] Documentation update

   ## Testing
   - [ ] Tested on Proxmox VE 9.x
   - [ ] Verified idempotency
   - [ ] ShellCheck passed
   - [ ] Documentation updated

   ## Related Issues
   Fixes #issue_number

   ## Screenshots
   (if applicable)
   ```

### Review Process

1. **Automated Checks**
   - ShellCheck linting
   - Character policy validation
   - Documentation check

2. **Maintainer Review**
   - Code quality
   - Functionality
   - Safety considerations
   - Documentation completeness

3. **Required Approvals**
   - At least one maintainer approval
   - All checks passing
   - No unresolved conversations

### After Approval

- Maintainer will merge using squash or rebase
- Your contribution will be in the next release
- CHANGELOG.md will be updated
- You'll be credited in release notes

---

## Character & Emoji Policy

### Console Output (Permitted)

Following the project character policy:

```bash
# Success/Status Indicators
echo -e "${GREEN}OK Operation successful${NC}"
echo -e "${GREEN}OK Task completed${NC}"

# Errors/Warnings
echo -e "${RED}ERROR Operation failed${NC}"
echo -e "${YELLOW}WARNING Warning: Check configuration${NC}"

# Info/Progress
echo -e "${CYAN}INFO Information message${NC}"
echo -e "${CYAN} Processing...${NC}"

# Steps
echo -e "${YELLOW} Step 1/5: Configure system${NC}"
```

### Log Files (ASCII Only)

For logged output, strip all emojis and Unicode:

```bash
# Console (with emojis)
echo -e "${GREEN}OK Success${NC}"

# Log file (ASCII only)
echo "SUCCESS: Operation completed" >> "$LOG_FILE"
```

### Prohibited

Do NOT use:
- Arbitrary emojis not in the policy
- Unicode box-drawing outside approved set
- Special characters without purpose
- Excessive formatting

---

## Release Process

### Semantic Versioning

We follow [SemVer 2.0.0](https://semver.org/):

- **MAJOR**: Incompatible changes (X.0.0)
- **MINOR**: New features, backwards-compatible (0.X.0)
- **PATCH**: Bug fixes, backwards-compatible (0.0.X)

### Version Bumping

```bash
# For new features
# Update version in:
# - README.md badge
# - CHANGELOG.md
# - Package files

# Current: 2.1.0
# Next minor: 2.2.0
# Next major: 3.0.0
# Next patch: 2.1.1
```

### Release Checklist

- [ ] All tests passing
- [ ] CHANGELOG.md updated
- [ ] Version bumped in all files
- [ ] Documentation updated
- [ ] Git tag created
- [ ] Release notes written

### Automated Releases

We use semantic-release for automated versioning:

```bash
# Commits trigger releases:
# feat: -> minor version bump
# fix: -> patch version bump
# BREAKING CHANGE: -> major version bump
```

---

## Questions?

- **Issues**: Open a GitHub issue
- **Discussions**: Use GitHub Discussions
- **Security**: Email security concerns privately

---

## Recognition

Contributors will be recognized in:
- CHANGELOG.md release notes
- GitHub contributors page
- Project README.md (for significant contributions)

---

## License

By contributing, you agree that your contributions will be licensed under the Apache License 2.0.

---

**Thank you for contributing to make Proxmox deployment better for everyone!**
