#!/usr/bin/env python3
"""
Proxmox VE NetBird Agent Installation

Copyright 2025 HyperSec

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

Purpose:
    Install and configure NetBird WireGuard mesh agent for on-premises
    Proxmox VE hosts. Provides emergency access via secure WireGuard
    tunnel when SSH is unavailable.

    NetBird is BSD-3-Clause licensed open source software with no
    commercial restrictions. Supports both self-hosted and cloud
    (netbird.io) control planes.

Usage:
    sudo ./proxmox-netbird.py install --setup-key <key> [--management-url <url>]
    sudo ./proxmox-netbird.py uninstall
    sudo ./proxmox-netbird.py status

Requirements:
    - Proxmox VE on Debian
    - Root privileges
    - Internet connectivity
    - Setup key from NetBird management console

Idempotent: Yes (safe to run multiple times)
Requires Reboot: No
"""

import argparse
import os
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Optional
from urllib.request import urlopen, Request
from urllib.error import URLError


# ANSI colors
class Colors:
    GREEN = "\033[0;32m"
    YELLOW = "\033[1;33m"
    CYAN = "\033[0;36m"
    RED = "\033[0;31m"
    NC = "\033[0m"


def ok(msg: str) -> None:
    print(f"{Colors.GREEN}OK{Colors.NC} - {msg}")


def warn(msg: str) -> None:
    print(f"{Colors.YELLOW}WARN{Colors.NC} - {msg}")


def info(msg: str) -> None:
    print(f"{Colors.CYAN}INFO{Colors.NC} - {msg}")


def error(msg: str) -> None:
    print(f"{Colors.RED}ERROR{Colors.NC} - {msg}", file=sys.stderr)


def die(msg: str) -> None:
    error(msg)
    sys.exit(1)


# Paths
NETBIRD_GPG_URL = "https://pkgs.netbird.io/debian/public.key"
NETBIRD_REPO_URL = "https://pkgs.netbird.io/debian"
APT_KEYRING = Path("/etc/apt/keyrings/netbird.asc")
APT_SOURCE = Path("/etc/apt/sources.list.d/netbird.sources")
NETBIRD_CONFIG = Path("/etc/netbird/config.json")
BACKUP_DIR = Path("/root/backup/proxmox-config")

# Default management URL (NetBird cloud)
DEFAULT_MANAGEMENT_URL = "https://api.netbird.io:443"


@dataclass
class Config:
    setup_key: Optional[str] = None
    management_url: str = DEFAULT_MANAGEMENT_URL


def run_cmd(
    cmd: list[str],
    check: bool = True,
    capture: bool = True,
    timeout: int = 120,
) -> subprocess.CompletedProcess:
    """Run a command and return the result."""
    try:
        result = subprocess.run(
            cmd,
            check=check,
            capture_output=capture,
            text=True,
            timeout=timeout,
        )
        return result
    except subprocess.CalledProcessError as e:
        if check:
            error(f"Command failed: {' '.join(cmd)}")
            if e.stderr:
                error(e.stderr.strip())
            raise
        return e
    except subprocess.TimeoutExpired:
        die(f"Command timed out: {' '.join(cmd)}")


def have_cmd(cmd: str) -> bool:
    """Check if a command is available."""
    return shutil.which(cmd) is not None


def is_root() -> bool:
    """Check if running as root."""
    return os.geteuid() == 0


def backup_file(path: Path) -> None:
    """Create a timestamped backup of a file."""
    if not path.exists():
        return

    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup_path = BACKUP_DIR / f"{path.name}.bak.{timestamp}"
    shutil.copy2(path, backup_path)
    print(f"Backup: {path} -> {backup_path}")


def fetch_url(url: str, timeout: int = 30) -> bytes:
    """Fetch URL content using stdlib."""
    req = Request(url, headers={"User-Agent": "proxmox-netbird/1.0"})
    try:
        with urlopen(req, timeout=timeout) as response:
            return response.read()
    except URLError as e:
        die(f"Failed to fetch {url}: {e}")


def is_netbird_installed() -> bool:
    """Check if NetBird is installed."""
    return have_cmd("netbird")


def is_netbird_connected() -> bool:
    """Check if NetBird is connected."""
    if not is_netbird_installed():
        return False

    result = run_cmd(["netbird", "status"], check=False)
    if result.returncode != 0:
        return False

    # Check for "Connected" in output
    return "Connected" in result.stdout or "Status: Connected" in result.stdout


def get_netbird_status() -> dict:
    """Get NetBird status as a dict."""
    if not is_netbird_installed():
        return {"installed": False}

    result = run_cmd(["netbird", "status", "--json"], check=False)
    if result.returncode != 0:
        # Try without --json for older versions
        result = run_cmd(["netbird", "status"], check=False)
        return {
            "installed": True,
            "raw_output": result.stdout if result.returncode == 0 else None,
        }

    try:
        import json
        return {"installed": True, **json.loads(result.stdout)}
    except Exception:
        return {"installed": True, "raw_output": result.stdout}


def check_wireguard() -> bool:
    """Check if WireGuard kernel module is available."""
    # Check if module is loaded or can be loaded
    result = run_cmd(["modprobe", "-n", "wireguard"], check=False)
    return result.returncode == 0


# Installation


def add_apt_repository() -> None:
    """Add NetBird APT repository."""
    print("Adding NetBird APT repository...")

    # Create keyring directory
    APT_KEYRING.parent.mkdir(parents=True, exist_ok=True)

    # Download and save GPG key
    gpg_key = fetch_url(NETBIRD_GPG_URL)
    APT_KEYRING.write_bytes(gpg_key)
    APT_KEYRING.chmod(0o644)
    ok(f"Added GPG key: {APT_KEYRING}")

    # Get architecture
    result = run_cmd(["dpkg", "--print-architecture"])
    arch = result.stdout.strip()

    # Get distribution codename
    result = run_cmd(["lsb_release", "-cs"], check=False)
    if result.returncode == 0:
        codename = result.stdout.strip()
    else:
        # Fallback: read from os-release
        codename = "stable"
        try:
            for line in Path("/etc/os-release").read_text().splitlines():
                if line.startswith("VERSION_CODENAME="):
                    codename = line.split("=", 1)[1].strip().strip('"')
                    break
        except OSError:
            pass

    # Write sources file (deb822 format)
    apt_source_content = f"""Types: deb
URIs: {NETBIRD_REPO_URL}
Suites: stable
Components: main
Architectures: {arch}
Signed-By: {APT_KEYRING}
"""
    APT_SOURCE.write_text(apt_source_content)
    APT_SOURCE.chmod(0o644)
    ok(f"Added APT source: {APT_SOURCE}")


def install_netbird() -> None:
    """Install NetBird package."""
    print("Installing NetBird...")

    # Update package lists
    run_cmd(["apt-get", "update", "-qq"])

    # Install netbird
    run_cmd(["apt-get", "install", "-y", "netbird"])

    ok("NetBird installed")


def configure_netbird(config: Config) -> None:
    """Configure and connect NetBird."""
    print("Configuring NetBird...")

    # Build netbird up command
    cmd = ["netbird", "up"]

    if config.setup_key:
        cmd.extend(["--setup-key", config.setup_key])

    if config.management_url and config.management_url != DEFAULT_MANAGEMENT_URL:
        cmd.extend(["--management-url", config.management_url])

    # Run netbird up (this may take a while for initial connection)
    result = run_cmd(cmd, timeout=120, check=False)

    if result.returncode != 0:
        if "already connected" in result.stderr.lower() or "already connected" in result.stdout.lower():
            ok("NetBird already connected")
            return
        error(f"Failed to connect: {result.stderr or result.stdout}")
        die("NetBird connection failed")

    ok("NetBird connected")


def wait_for_connection(timeout: int = 60) -> bool:
    """Wait for NetBird to establish connection."""
    print("Waiting for NetBird connection...")

    interval = 5
    for waited in range(0, timeout, interval):
        if is_netbird_connected():
            return True

        time.sleep(interval)
        info(f"Waiting for connection... ({waited + interval}/{timeout}s)")

    return False


# Commands


def cmd_status(config: Config) -> None:
    """Show NetBird status."""
    print()
    print("=== NetBird Status ===")
    print()

    if not is_netbird_installed():
        warn("NetBird not installed")
        return

    # Get version
    result = run_cmd(["netbird", "version"], check=False)
    if result.returncode == 0:
        ok(f"NetBird installed: {result.stdout.strip()}")
    else:
        ok("NetBird installed")

    # Service status
    result = run_cmd(["systemctl", "is-active", "netbird"], check=False)
    if result.returncode == 0:
        ok("NetBird service: running")
    else:
        warn("NetBird service: not running")

    result = run_cmd(["systemctl", "is-enabled", "netbird"], check=False)
    if result.returncode == 0:
        ok("NetBird service: enabled")
    else:
        warn("NetBird service: disabled")

    # Connection status
    print()
    print("=== Connection Status ===")

    status = get_netbird_status()

    if status.get("raw_output"):
        # Parse text output
        for line in status["raw_output"].splitlines():
            line = line.strip()
            if line:
                print(f"  {line}")
    elif status.get("installed"):
        # JSON output available
        if status.get("daemonStatus"):
            info(f"Daemon: {status['daemonStatus']}")
        if status.get("managementStatus"):
            management = status["managementStatus"]
            info(f"Management: {management.get('connected', 'unknown')}")
            if management.get("url"):
                info(f"Management URL: {management['url']}")
        if status.get("signalStatus"):
            info(f"Signal: {status['signalStatus'].get('connected', 'unknown')}")
        if status.get("localPeerState"):
            peer = status["localPeerState"]
            if peer.get("ip"):
                info(f"Local IP: {peer['ip']}")
            if peer.get("pubKey"):
                info(f"Public Key: {peer['pubKey'][:16]}...")
        if status.get("peers"):
            peers = status["peers"]
            connected = sum(1 for p in peers if p.get("connStatus") == "Connected")
            info(f"Peers: {connected}/{len(peers)} connected")

    # WireGuard interface
    print()
    print("=== Network Interface ===")

    result = run_cmd(["ip", "addr", "show", "wt0"], check=False)
    if result.returncode == 0:
        ok("WireGuard interface: wt0")
        for line in result.stdout.splitlines():
            if "inet " in line:
                info(f"  {line.strip()}")
    else:
        warn("WireGuard interface wt0 not found")


def cmd_install(config: Config) -> None:
    """Install and configure NetBird."""
    if not is_root():
        die("Must run as root")

    print("Checking prerequisites...")

    # Check WireGuard
    if check_wireguard():
        ok("WireGuard kernel module available")
    else:
        warn("WireGuard kernel module may not be available (NetBird will use userspace)")

    print()
    print("=== Installing NetBird ===")
    print()

    # Check if already installed and connected
    if is_netbird_installed():
        ok("NetBird already installed")

        if is_netbird_connected():
            ok("NetBird already connected")
            info("Use 'proxmox-netbird.py uninstall' to reinstall")
            return
        else:
            info("NetBird installed but not connected, will configure...")
    else:
        # Add repository and install
        add_apt_repository()
        install_netbird()

    # Enable and start service
    run_cmd(["systemctl", "enable", "netbird"], check=False)
    run_cmd(["systemctl", "start", "netbird"], check=False)

    # Configure and connect
    if config.setup_key:
        configure_netbird(config)

        # Wait for connection
        if wait_for_connection():
            ok("NetBird connection established")
        else:
            warn("Connection may still be establishing. Check status with: proxmox-netbird.py status")
    else:
        info("No setup key provided. NetBird is installed but not connected.")
        info("Connect with: netbird up --setup-key <YOUR_SETUP_KEY>")

    print()
    print("=== Installation Complete ===")

    # Show assigned IP if connected
    result = run_cmd(["ip", "-4", "addr", "show", "wt0"], check=False)
    if result.returncode == 0:
        for line in result.stdout.splitlines():
            if "inet " in line:
                ip = line.strip().split()[1]
                info(f"NetBird IP: {ip}")
                break


def cmd_uninstall(config: Config) -> None:
    """Uninstall NetBird."""
    if not is_root():
        die("Must run as root")

    print()
    print("=== Uninstalling NetBird ===")
    print()

    # Disconnect
    if is_netbird_installed():
        run_cmd(["netbird", "down"], check=False)
        ok("Disconnected from NetBird network")

    # Stop service
    result = run_cmd(["systemctl", "is-active", "netbird"], check=False)
    if result.returncode == 0:
        run_cmd(["systemctl", "stop", "netbird"])
        ok("Stopped NetBird service")

    # Disable service
    result = run_cmd(["systemctl", "is-enabled", "netbird"], check=False)
    if result.returncode == 0:
        run_cmd(["systemctl", "disable", "netbird"])
        ok("Disabled NetBird service")

    # Remove package
    if is_netbird_installed():
        run_cmd(["apt-get", "remove", "--purge", "-y", "netbird"])
        ok("Removed NetBird package")

    # Remove APT source
    if APT_SOURCE.exists():
        backup_file(APT_SOURCE)
        APT_SOURCE.unlink()
        ok(f"Removed APT source: {APT_SOURCE}")

    # Remove GPG key
    if APT_KEYRING.exists():
        APT_KEYRING.unlink()
        ok(f"Removed GPG key: {APT_KEYRING}")

    # Cleanup config
    if NETBIRD_CONFIG.exists():
        backup_file(NETBIRD_CONFIG)

    # Remove config directory
    netbird_dir = Path("/etc/netbird")
    if netbird_dir.exists():
        shutil.rmtree(netbird_dir, ignore_errors=True)
        ok("Removed NetBird config directory")

    # Remove state directory
    netbird_state = Path("/var/lib/netbird")
    if netbird_state.exists():
        shutil.rmtree(netbird_state, ignore_errors=True)
        ok("Removed NetBird state directory")

    print()
    ok("NetBird uninstalled")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Proxmox VE NetBird Agent Installation",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
NetBird is BSD-3-Clause licensed open source software.
Supports both self-hosted and cloud (netbird.io) control planes.

Examples:
  # Install and connect to NetBird cloud
  sudo ./proxmox-netbird.py install --setup-key nb-setup-XXXXXXXX

  # Install and connect to self-hosted control plane
  sudo ./proxmox-netbird.py install --setup-key nb-setup-XXXX --management-url https://netbird.example.com:443

  # Check status
  sudo ./proxmox-netbird.py status

  # Uninstall
  sudo ./proxmox-netbird.py uninstall

Getting a setup key:
  1. Go to https://app.netbird.io (or your self-hosted console)
  2. Navigate to Setup Keys
  3. Create a new key (reusable or one-time)
  4. Use the key with --setup-key
""",
    )

    subparsers = parser.add_subparsers(dest="command", help="Command to run")

    # Install command
    install_parser = subparsers.add_parser("install", help="Install and configure NetBird")
    install_parser.add_argument("--setup-key", help="NetBird setup key for authentication")
    install_parser.add_argument(
        "--management-url",
        default=DEFAULT_MANAGEMENT_URL,
        help=f"Management server URL (default: {DEFAULT_MANAGEMENT_URL})",
    )

    # Uninstall command
    subparsers.add_parser("uninstall", help="Uninstall NetBird")

    # Status command
    subparsers.add_parser("status", help="Show NetBird status")

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    config = Config()

    if args.command == "install":
        config.setup_key = args.setup_key
        config.management_url = args.management_url
        cmd_install(config)

    elif args.command == "uninstall":
        cmd_uninstall(config)

    elif args.command == "status":
        cmd_status(config)


if __name__ == "__main__":
    main()
