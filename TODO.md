# Backlog

## Python Migration

Port the remaining bash scripts to Python 3 (stdlib only, no PyPI deps):

- [ ] proxmox-repo.sh
- [ ] proxmox-optimize.sh
- [ ] proxmox-network.sh
- [ ] proxmox-power-management.sh
- [ ] proxmox-zfs.sh
- [ ] proxmox-update-policy.sh
- [ ] proxmox-internal-nat.sh

Already done:
- [x] proxmox-ssm.py
- [x] proxmox-netbird.py

## Ansible Roles

Create Ansible equivalents for each script:

- [ ] role: proxmox_repo
- [ ] role: proxmox_optimize
- [ ] role: proxmox_network
- [ ] role: proxmox_power
- [ ] role: proxmox_zfs
- [ ] role: proxmox_update_policy
- [ ] role: proxmox_internal_nat
- [ ] role: proxmox_ssm
- [ ] role: proxmox_netbird

Structure:
```
ansible/
  roles/
    proxmox_*/
      tasks/
      handlers/
      defaults/
      templates/
```
