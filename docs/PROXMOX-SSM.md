# AWS SSM Session Manager for Proxmox

Emergency console access to Proxmox VE hosts via AWS Systems Manager Session Manager.

## Overview

This guide covers deploying AWS SSM Agent on on-premises Proxmox hosts with IAM-based access control. SSM provides:

- **Emergency console access** when SSH is unavailable
- **No inbound ports** - agent initiates outbound HTTPS connections
- **IAM-based authentication** - use SSO groups to control access
- **Session logging** - optional CloudWatch/S3 audit trail

## Prerequisites

### On the Proxmox Host

- Proxmox VE 9.x on Debian 13 (Trixie)
- Python 3.x (included by default)
- Internet connectivity (HTTPS to AWS SSM endpoints)

### In AWS

- AWS CLI with IAM permissions to:
  - Create/manage IAM roles
  - Create SSM activations
  - Update SSM service settings
- AWS account with Systems Manager enabled
- (Optional) AWS IAM Identity Center for SSO group-based access

## Quick Start

```bash
# On the Proxmox host
sudo ./proxmox-ssm.py install --region <your-region>

# From any machine with AWS CLI
aws ssm start-session --target mi-XXXXXXXXX --region <your-region>
```

## Detailed Setup

### Step 1: Enable Advanced Instances Tier

Session Manager with on-premises hosts requires the advanced-instances tier:

```bash
aws ssm update-service-setting \
  --setting-id arn:aws:ssm:<region>:<account-id>:servicesetting/ssm/managed-instance/activation-tier \
  --setting-value advanced \
  --region <region>
```

**Note:** This may incur charges for managed instances.

### Step 2: Install SSM Agent

```bash
# Auto-create IAM role and activation
sudo ./proxmox-ssm.py install --region <region>

# Or with a custom instance name
sudo ./proxmox-ssm.py install --region <region> --instance-name my-proxmox-host

# Or use an existing activation
sudo ./proxmox-ssm.py install \
  --activation-code XXXX-XXXX-XXXX-XXXX \
  --activation-id xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
  --region <region>
```

### Step 3: Verify Registration

```bash
# On the Proxmox host
sudo ./proxmox-ssm.py status

# From AWS CLI
aws ssm describe-instance-information \
  --filters "Key=ResourceType,Values=ManagedInstance" \
  --region <region> \
  --query 'InstanceInformationList[*].[InstanceId,Name,PingStatus]' \
  --output table
```

### Step 4: Connect

```bash
aws ssm start-session --target mi-XXXXXXXXX --region <region>
```

## IAM Access Control

### Basic Setup (Open to Account)

The default setup allows anyone with `ssm:StartSession` permission in the account to connect. The script creates an IAM role `SSMHybridOnPremises` with `AmazonSSMManagedInstanceCore` attached.

### Restricting Access to Specific Groups

To limit who can connect via Session Manager, create a custom IAM policy:

#### Step 1: Create Access Policy

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "StartSessionOnPremisesHosts",
            "Effect": "Allow",
            "Action": ["ssm:StartSession"],
            "Resource": [
                "arn:aws:ssm:<region>:<account-id>:managed-instance/mi-*",
                "arn:aws:ssm:<region>::document/AWS-StartSSHSession",
                "arn:aws:ssm:<region>::document/SSM-SessionManagerRunShell"
            ]
        },
        {
            "Sid": "TerminateOwnSessions",
            "Effect": "Allow",
            "Action": ["ssm:TerminateSession", "ssm:ResumeSession"],
            "Resource": "arn:aws:ssm:*:*:session/${aws:userid}-*"
        },
        {
            "Sid": "DescribeInstances",
            "Effect": "Allow",
            "Action": [
                "ssm:DescribeInstanceInformation",
                "ssm:DescribeSessions",
                "ssm:GetConnectionStatus"
            ],
            "Resource": "*"
        }
    ]
}
```

Save as `ssm-session-policy.json` and create:

```bash
aws iam create-policy \
  --policy-name SSMSessionOnPremisesAccess \
  --policy-document file://ssm-session-policy.json \
  --description "Allow SSM Session Manager access to on-premises managed instances"
```

#### Step 2: Assign to Groups

**Option A: IAM Identity Center (SSO)**

1. Create a Permission Set in IAM Identity Center
2. Attach the `SSMSessionOnPremisesAccess` policy
3. Assign the Permission Set to your infrastructure groups
4. Assign to your AWS account

**Option B: IAM Groups**

```bash
# Attach policy to IAM group
aws iam attach-group-policy \
  --group-name InfraAdmins \
  --policy-arn arn:aws:iam::<account-id>:policy/SSMSessionOnPremisesAccess
```

#### Step 3: Restrict Other Users

Ensure users without the policy cannot start sessions. You can:

1. Use Service Control Policies (SCPs) at the org level
2. Remove broad SSM permissions from other roles
3. Use permission boundaries

### Restricting to Specific Instances

To limit access to specific managed instances (not all `mi-*`):

```json
{
    "Resource": [
        "arn:aws:ssm:<region>:<account-id>:managed-instance/mi-0123456789abcdef0"
    ]
}
```

Or use tags with conditions:

```json
{
    "Condition": {
        "StringEquals": {
            "ssm:resourceTag/Environment": "production"
        }
    }
}
```

## Session Logging

### Enable CloudWatch Logging

```bash
aws ssm update-document \
  --name "SSM-SessionManagerRunShell" \
  --content '{
    "schemaVersion": "1.0",
    "description": "Document to hold regional settings for Session Manager",
    "sessionType": "Standard_Stream",
    "inputs": {
      "cloudWatchLogGroupName": "/aws/ssm/session-logs",
      "cloudWatchEncryptionEnabled": true
    }
  }' \
  --document-version "\$LATEST" \
  --region <region>
```

### Enable S3 Logging

```bash
aws ssm update-document \
  --name "SSM-SessionManagerRunShell" \
  --content '{
    "schemaVersion": "1.0",
    "sessionType": "Standard_Stream",
    "inputs": {
      "s3BucketName": "your-session-logs-bucket",
      "s3KeyPrefix": "ssm-sessions/",
      "s3EncryptionEnabled": true
    }
  }' \
  --document-version "\$LATEST" \
  --region <region>
```

## Troubleshooting

### Agent Shows Offline

```bash
# Check agent status
sudo systemctl status amazon-ssm-agent

# Check logs
sudo journalctl -u amazon-ssm-agent -n 50

# Verify network connectivity
curl -v https://ssm.<region>.amazonaws.com
```

### Session Won't Start

1. Verify advanced-instances tier is enabled
2. Check IAM permissions include `ssm:StartSession`
3. Verify the managed instance is online:

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=mi-XXXXXXX" \
  --query 'InstanceInformationList[0].PingStatus'
```

### Permission Denied

```bash
# Check your current identity
aws sts get-caller-identity

# Check if you have the required permissions
aws iam simulate-principal-policy \
  --policy-source-arn <your-role-arn> \
  --action-names ssm:StartSession \
  --resource-arns arn:aws:ssm:<region>:<account>:managed-instance/mi-XXXXXXX
```

## Uninstalling

```bash
sudo ./proxmox-ssm.py uninstall
```

This will:
- Stop and disable the SSM agent
- Deregister from AWS (if credentials available)
- Remove the agent package
- Clean up configuration files

## Security Considerations

1. **Minimal Permissions**: The `SSMHybridOnPremises` role only has `AmazonSSMManagedInstanceCore` - the minimum needed for SSM functionality.

2. **No Inbound Access**: SSM uses outbound HTTPS only. No inbound firewall rules needed.

3. **Session Encryption**: All session traffic is encrypted via TLS.

4. **Audit Trail**: Enable CloudWatch/S3 logging for session audit trails.

5. **Time-Limited Access**: Activation codes expire after 30 days by default. Old registrations should be cleaned up.

## Network Requirements

The SSM agent needs outbound HTTPS (443) access to:

- `ssm.<region>.amazonaws.com`
- `ssmmessages.<region>.amazonaws.com`
- `ec2messages.<region>.amazonaws.com`
- `s3.<region>.amazonaws.com` (for agent updates)

No inbound ports are required.

## Cost Considerations

- **Advanced-instances tier**: Required for on-premises hosts. Check [AWS pricing](https://aws.amazon.com/systems-manager/pricing/) for current costs.
- **Session logging**: CloudWatch Logs or S3 storage costs if enabled.
- **Data transfer**: Minimal - only session I/O data.

## Related Documentation

- [AWS SSM Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html)
- [Hybrid Activations](https://docs.aws.amazon.com/systems-manager/latest/userguide/systems-manager-managedinstances.html)
- [Session Manager Preferences](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-preferences.html)
