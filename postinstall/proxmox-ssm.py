#!/usr/bin/env python3
"""
Proxmox VE AWS SSM Hybrid Activation

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
    Install and configure AWS Systems Manager Agent for on-premises
    Proxmox VE hosts. Enables emergency console access via AWS SSM
    Session Manager when SSH is unavailable.

Usage:
    sudo ./proxmox-ssm.py install [--region <region>] [--role-name <name>] [--instance-name <name>]
    sudo ./proxmox-ssm.py install --activation-code <code> --activation-id <id> [--region <region>]
    sudo ./proxmox-ssm.py uninstall
    sudo ./proxmox-ssm.py status

Requirements:
    - Proxmox VE on Debian
    - Root privileges
    - Internet connectivity (HTTPS to AWS SSM endpoints)
    - AWS CLI with appropriate IAM permissions (for install without existing activation)

Idempotent: Yes (safe to run multiple times)
Requires Reboot: No
"""

import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path


# ANSI colors
class Colors:
    GREEN = "\033[0;32m"
    YELLOW = "\033[1;33m"
    CYAN = "\033[0;36m"
    RED = "\033[0;31m"
    NC = "\033[0m"  # No Color


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
SSM_AGENT_DEB_URL = "https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/debian_amd64/amazon-ssm-agent.deb"
SSM_AGENT_DEB = Path("/tmp/amazon-ssm-agent.deb")
SSM_REGISTRATION_FILE = Path("/var/lib/amazon/ssm/registration")
BACKUP_DIR = Path("/root/backup/proxmox-config")
ACTIVATION_STORE = Path("/etc/amazon/ssm/activation-info")


@dataclass
class Config:
    region: str | None = None
    role_name: str = "SSMHybridOnPremises"
    instance_name: str | None = None
    activation_code: str | None = None
    activation_id: str | None = None


def run_cmd(
    cmd: list[str],
    check: bool = True,
    capture: bool = True,
    timeout: int = 60,
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


def aws_cmd(
    args: list[str],
    region: str,
    check: bool = True,
) -> dict | None:
    """Run an AWS CLI command and return parsed JSON output."""
    cmd = ["aws"] + args + ["--region", region, "--output", "json"]
    result = run_cmd(cmd, check=check)

    if result.returncode != 0:
        return None

    if result.stdout.strip():
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError:
            return None
    return None


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


def detect_region(config: Config) -> str | None:
    """Detect AWS region from various sources."""
    # 1. Already set via --region
    if config.region:
        return config.region

    # 2. AWS_REGION env var
    if os.environ.get("AWS_REGION"):
        return os.environ["AWS_REGION"]

    # 3. AWS_DEFAULT_REGION env var
    if os.environ.get("AWS_DEFAULT_REGION"):
        return os.environ["AWS_DEFAULT_REGION"]

    # 4. AWS CLI config
    if have_cmd("aws"):
        result = run_cmd(["aws", "configure", "get", "region"], check=False)
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()

    return None


def check_network_connectivity(region: str) -> bool:
    """Check if we can reach SSM endpoints."""
    endpoint = f"ssm.{region}.amazonaws.com"
    try:
        socket.create_connection((endpoint, 443), timeout=5)
        return True
    except (OSError, TimeoutError):
        return False


def is_agent_installed() -> bool:
    """Check if SSM agent is installed."""
    result = run_cmd(["dpkg", "-l", "amazon-ssm-agent"], check=False)
    return result.returncode == 0


def is_agent_registered() -> bool:
    """Check if SSM agent is registered."""
    return SSM_REGISTRATION_FILE.exists()


def get_managed_instance_id() -> str | None:
    """Get the managed instance ID from registration file."""
    if not SSM_REGISTRATION_FILE.exists():
        return None

    try:
        data = json.loads(SSM_REGISTRATION_FILE.read_text())
        return data.get("ManagedInstanceID")
    except (json.JSONDecodeError, OSError):
        return None


def get_stored_region() -> str | None:
    """Get the region from stored activation info."""
    if not ACTIVATION_STORE.exists():
        return None

    try:
        for line in ACTIVATION_STORE.read_text().splitlines():
            if line.startswith("REGION="):
                return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return None


# IAM Role Management


def check_iam_role_exists(config: Config) -> bool:
    """Check if the IAM role exists."""
    result = aws_cmd(
        ["iam", "get-role", "--role-name", config.role_name],
        region=config.region,
        check=False,
    )
    return result is not None


def create_iam_role(config: Config) -> None:
    """Create the IAM role for SSM hybrid activation."""
    print(f"Creating IAM role: {config.role_name}...")

    trust_policy = json.dumps({
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Principal": {"Service": "ssm.amazonaws.com"},
                "Action": "sts:AssumeRole",
            }
        ],
    })

    # Create role
    aws_cmd(
        [
            "iam",
            "create-role",
            "--role-name",
            config.role_name,
            "--assume-role-policy-document",
            trust_policy,
            "--description",
            "IAM role for SSM hybrid on-premises managed instances",
        ],
        region=config.region,
    )

    # Attach managed policy
    aws_cmd(
        [
            "iam",
            "attach-role-policy",
            "--role-name",
            config.role_name,
            "--policy-arn",
            "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
        ],
        region=config.region,
    )

    ok(f"Created IAM role: {config.role_name}")

    # Wait for IAM role to propagate (AWS eventual consistency)
    info("Waiting for IAM role to propagate...")
    time.sleep(10)


def ensure_iam_role(config: Config) -> None:
    """Ensure the IAM role exists with correct trust policy."""
    if check_iam_role_exists(config):
        ok(f"IAM role exists: {config.role_name}")

        # Verify trust policy
        result = aws_cmd(
            ["iam", "get-role", "--role-name", config.role_name],
            region=config.region,
        )

        if result:
            trust_doc = result.get("Role", {}).get("AssumeRolePolicyDocument", {})
            trust_str = json.dumps(trust_doc)
            if "ssm.amazonaws.com" not in trust_str:
                die(
                    f"IAM role {config.role_name} exists but doesn't trust "
                    "ssm.amazonaws.com. Fix manually or use a different role name."
                )
            ok("IAM role trust policy is correct")
    else:
        create_iam_role(config)


# SSM Activation


def create_activation(config: Config) -> tuple[str, str]:
    """Create SSM hybrid activation and return (code, id)."""
    print("Creating SSM hybrid activation...")

    instance_name = config.instance_name or socket.gethostname()

    result = aws_cmd(
        [
            "ssm",
            "create-activation",
            "--default-instance-name",
            instance_name,
            "--iam-role",
            config.role_name,
            "--registration-limit",
            "1",
            "--description",
            f"Proxmox host: {instance_name}",
        ],
        region=config.region,
    )

    if not result:
        die("Failed to create activation")

    activation_code = result.get("ActivationCode")
    activation_id = result.get("ActivationId")

    if not activation_code or not activation_id:
        die("Failed to parse activation response")

    # Store activation info
    ACTIVATION_STORE.parent.mkdir(parents=True, exist_ok=True)
    ACTIVATION_STORE.write_text(
        f"# SSM Hybrid Activation Info\n"
        f"# Created: {datetime.now().isoformat()}\n"
        f"ACTIVATION_ID={activation_id}\n"
        f"INSTANCE_NAME={instance_name}\n"
        f"REGION={config.region}\n"
        f"ROLE={config.role_name}\n"
        f"# Note: Activation code is not stored for security (one-time use)\n"
    )
    ACTIVATION_STORE.chmod(0o600)

    ok(f"Created activation: {activation_id}")
    return activation_code, activation_id


# SSM Agent Installation


def install_agent() -> None:
    """Download and install the SSM agent."""
    print("Installing SSM agent...")

    # Download agent
    if have_cmd("curl"):
        run_cmd(["curl", "-sL", "-o", str(SSM_AGENT_DEB), SSM_AGENT_DEB_URL])
    elif have_cmd("wget"):
        run_cmd(["wget", "-q", "-O", str(SSM_AGENT_DEB), SSM_AGENT_DEB_URL])
    else:
        die("Neither curl nor wget installed")

    if not SSM_AGENT_DEB.exists():
        die("Failed to download SSM agent")

    # Install
    result = run_cmd(["dpkg", "-i", str(SSM_AGENT_DEB)], check=False)
    if result.returncode != 0:
        run_cmd(["apt-get", "install", "-f", "-y"])

    # Cleanup
    SSM_AGENT_DEB.unlink(missing_ok=True)

    # Stop agent before registration
    run_cmd(["systemctl", "stop", "amazon-ssm-agent"], check=False)

    ok("SSM agent installed")


def register_agent(config: Config) -> None:
    """Register the SSM agent with activation credentials."""
    print("Registering SSM agent...")

    if not config.activation_code or not config.activation_id:
        die("Activation code and ID required for registration")

    run_cmd([
        "amazon-ssm-agent",
        "-register",
        "-code",
        config.activation_code,
        "-id",
        config.activation_id,
        "-region",
        config.region,
        "-y",
    ])

    # Start and enable agent
    run_cmd(["systemctl", "enable", "amazon-ssm-agent"])
    run_cmd(["systemctl", "start", "amazon-ssm-agent"])

    ok("SSM agent registered and started")


def wait_for_registration(config: Config) -> None:
    """Wait for SSM agent to come online."""
    print("Waiting for SSM registration to complete...")

    max_wait = 60
    interval = 5

    for waited in range(0, max_wait, interval):
        result = aws_cmd(
            [
                "ssm",
                "describe-instance-information",
                "--filters",
                f"Key=ActivationIds,Values={config.activation_id}",
                "--query",
                "InstanceInformationList[0]",
            ],
            region=config.region,
            check=False,
        )

        if result and result.get("PingStatus") == "Online":
            instance_id = result.get("InstanceId", "unknown")
            ok(f"SSM agent is online: {instance_id}")
            return

        time.sleep(interval)
        info(f"Waiting for agent to come online... ({waited + interval}/{max_wait}s)")

    warn("Agent may still be connecting. Check status with: proxmox-ssm.py status")


# Commands


def cmd_status(config: Config) -> None:
    """Show SSM agent status."""
    print()
    print("=== SSM Agent Status ===")
    print()

    # Agent installation
    if is_agent_installed():
        result = run_cmd(["amazon-ssm-agent", "--version"], check=False)
        version = result.stdout.strip().split("\n")[0] if result.returncode == 0 else "unknown"
        ok(f"SSM agent installed: {version}")
    else:
        warn("SSM agent not installed")
        return

    # Service status
    result = run_cmd(["systemctl", "is-active", "amazon-ssm-agent"], check=False)
    if result.returncode == 0:
        ok("SSM agent service: running")
    else:
        warn("SSM agent service: not running")

    result = run_cmd(["systemctl", "is-enabled", "amazon-ssm-agent"], check=False)
    if result.returncode == 0:
        ok("SSM agent service: enabled")
    else:
        warn("SSM agent service: disabled")

    # Registration status
    if is_agent_registered():
        ok("SSM agent: registered")
        instance_id = get_managed_instance_id()
        if instance_id:
            info(f"Managed Instance ID: {instance_id}")
    else:
        warn("SSM agent: not registered")

    # Activation info
    if ACTIVATION_STORE.exists():
        print()
        print("=== Activation Info ===")
        for line in ACTIVATION_STORE.read_text().splitlines():
            if not line.startswith("#"):
                print(f"  {line}")

    # AWS connectivity
    stored_region = get_stored_region()
    instance_id = get_managed_instance_id()

    if stored_region and instance_id and have_cmd("aws"):
        print()
        print("=== AWS Status ===")

        result = aws_cmd(
            [
                "ssm",
                "describe-instance-information",
                "--filters",
                f"Key=InstanceIds,Values={instance_id}",
                "--query",
                "InstanceInformationList[0]",
            ],
            region=stored_region,
            check=False,
        )

        if result:
            info(f"Ping Status: {result.get('PingStatus', 'unknown')}")
            info(f"Last Ping: {result.get('LastPingDateTime', 'unknown')}")
            info(f"Agent Version: {result.get('AgentVersion', 'unknown')}")

            if result.get("PingStatus") == "Online":
                print()
                print("=== Connection Command ===")
                info(f"aws ssm start-session --target {instance_id} --region {stored_region}")


def cmd_install(config: Config) -> None:
    """Install SSM agent and register with AWS."""
    if not is_root():
        die("Must run as root")

    # Check prerequisites
    print("Checking prerequisites...")

    if not have_cmd("aws"):
        die("AWS CLI not installed. Install with: apt-get install awscli")
    ok("AWS CLI installed")

    # Region check
    config.region = detect_region(config)
    if not config.region:
        die("AWS region not specified. Use --region <region> or set AWS_REGION")
    ok(f"AWS region: {config.region}")

    # Network check
    if check_network_connectivity(config.region):
        ok("Network connectivity to SSM endpoint")
    else:
        warn(f"Cannot reach ssm.{config.region}.amazonaws.com (may still work)")

    print()
    print("=== Installing SSM Agent ===")
    print()

    # Check if already registered
    if is_agent_registered():
        instance_id = get_managed_instance_id()
        ok(f"SSM agent already registered: {instance_id}")
        info("Use 'proxmox-ssm.py uninstall' first to re-register")
        return

    # Install agent if needed
    if not is_agent_installed():
        install_agent()
    else:
        ok("SSM agent already installed")
        run_cmd(["systemctl", "stop", "amazon-ssm-agent"], check=False)

    # Handle activation
    if config.activation_code and config.activation_id:
        info(f"Using provided activation: {config.activation_id}")
    else:
        ensure_iam_role(config)
        config.activation_code, config.activation_id = create_activation(config)

    # Register agent
    register_agent(config)

    # Wait for registration
    wait_for_registration(config)

    print()
    print("=== Installation Complete ===")
    instance_id = get_managed_instance_id()
    if instance_id:
        info(f"Managed Instance ID: {instance_id}")
        info(f"Connect with: aws ssm start-session --target {instance_id} --region {config.region}")


def cmd_uninstall(config: Config) -> None:
    """Uninstall SSM agent and deregister from AWS."""
    if not is_root():
        die("Must run as root")

    print()
    print("=== Uninstalling SSM Agent ===")
    print()

    # Stop service
    result = run_cmd(["systemctl", "is-active", "amazon-ssm-agent"], check=False)
    if result.returncode == 0:
        run_cmd(["systemctl", "stop", "amazon-ssm-agent"])
        ok("Stopped SSM agent service")

    # Disable service
    result = run_cmd(["systemctl", "is-enabled", "amazon-ssm-agent"], check=False)
    if result.returncode == 0:
        run_cmd(["systemctl", "disable", "amazon-ssm-agent"])
        ok("Disabled SSM agent service")

    # Deregister from AWS
    instance_id = get_managed_instance_id()
    stored_region = get_stored_region()

    if instance_id and stored_region and have_cmd("aws"):
        print(f"Deregistering managed instance: {instance_id}...")
        result = aws_cmd(
            ["ssm", "deregister-managed-instance", "--instance-id", instance_id],
            region=stored_region,
            check=False,
        )
        if result is not None:
            ok("Deregistered from AWS")
        else:
            warn("Could not deregister from AWS (may need manual cleanup)")

    # Backup and remove registration
    if SSM_REGISTRATION_FILE.exists():
        backup_file(SSM_REGISTRATION_FILE)
        SSM_REGISTRATION_FILE.unlink()
        ok("Removed registration file")

    # Backup and remove activation store
    if ACTIVATION_STORE.exists():
        backup_file(ACTIVATION_STORE)
        ACTIVATION_STORE.unlink()
        ok("Removed activation info")

    # Remove package
    if is_agent_installed():
        run_cmd(["dpkg", "--purge", "amazon-ssm-agent"])
        ok("Removed SSM agent package")

    # Cleanup directories
    shutil.rmtree("/var/lib/amazon/ssm", ignore_errors=True)
    shutil.rmtree("/etc/amazon/ssm", ignore_errors=True)

    print()
    ok("SSM agent uninstalled")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Proxmox VE AWS SSM Hybrid Activation",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Install with auto-created IAM role and activation
  sudo ./proxmox-ssm.py install --region ap-southeast-2

  # Install with existing activation
  sudo ./proxmox-ssm.py install --activation-code ABCD-1234 \\
      --activation-id 12345678-... --region ap-southeast-2

  # Check status
  sudo ./proxmox-ssm.py status

  # Uninstall
  sudo ./proxmox-ssm.py uninstall
""",
    )

    subparsers = parser.add_subparsers(dest="command", help="Command to run")

    # Install command
    install_parser = subparsers.add_parser("install", help="Install and register SSM agent")
    install_parser.add_argument("--region", help="AWS region")
    install_parser.add_argument(
        "--role-name",
        default="SSMHybridOnPremises",
        help="IAM role name (default: SSMHybridOnPremises)",
    )
    install_parser.add_argument("--instance-name", help="Managed instance name (default: hostname)")
    install_parser.add_argument(
        "--activation-code",
        help=(
            "Use existing activation code. Prefer SSM_ACTIVATION_CODE in the "
            "environment: a value passed here lands in shell history and is "
            "visible in 'ps' for the whole run"
        ),
    )
    install_parser.add_argument("--activation-id", help="Use existing activation ID")

    # Uninstall command
    subparsers.add_parser("uninstall", help="Uninstall and deregister SSM agent")

    # Status command
    subparsers.add_parser("status", help="Show SSM agent status")

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    config = Config()

    if args.command == "install":
        config.region = args.region
        config.role_name = args.role_name
        config.instance_name = args.instance_name
        # An activation code passed on the command line is recorded in shell
        # history and readable from /proc for the whole run. The environment is
        # the safer channel, so it wins where both are supplied.
        config.activation_code = os.environ.get("SSM_ACTIVATION_CODE") or args.activation_code
        config.activation_id = os.environ.get("SSM_ACTIVATION_ID") or args.activation_id

        if args.activation_code and not os.environ.get("SSM_ACTIVATION_CODE"):
            warn(
                "Activation code passed as an argument. It is now in your shell "
                "history -- clear it, or use SSM_ACTIVATION_CODE next time."
            )

        # Validate activation args
        if config.activation_code and not config.activation_id:
            die("An activation code requires an activation ID")
        if config.activation_id and not config.activation_code:
            die("An activation ID requires an activation code")

        cmd_install(config)

    elif args.command == "uninstall":
        cmd_uninstall(config)

    elif args.command == "status":
        cmd_status(config)


if __name__ == "__main__":
    main()
