# Nested PVE integration testing

The suite in this directory runs anywhere and covers the decision logic. What
it cannot cover is the part that needs a real Proxmox install: patching the web
UI, the APT hook's exit status, ZFS module parameters actually taking effect,
and the cleanup path finding real artefacts.

Proxmox VE runs fine as a KVM guest, so the harness is a nested PVE VM on an
existing host.

## What nested testing covers

| Area | Covered? | Notes |
|---|---|---|
| `proxmox-update-policy.sh` pin generation | Yes | Real repos, real `apt-cache policy` |
| APT hook exit status | Yes | `apt-get install --reinstall`, check `$?` |
| UI patching + `pveproxy` restart behaviour | Yes | Real `proxmoxlib.js` |
| `proxmox-cleanup.sh` detection | Yes | Plant old artefacts, run it |
| `proxmox-repo.sh` | Yes | Real repository configuration |
| ZFS `zvol_threads` / `zvol_num_taskqs` | Mostly | Attach virtual disks, build a pool, read `/sys/module/zfs/parameters/` |
| `proxmox-disk-errors.sh` SCT ERC branch | **No** | virtio/virtio-scsi disks report "SCT not supported" -- only the fallback path runs |
| `proxmox-disk-errors.sh` timeout branch | Yes | `/sys/block/sdX/device/timeout` exists on virtio-scsi |
| IOMMU, power management, NIC offload | **No** | Needs real hardware |

The SCT ERC path needs either a physically passed-through SATA disk or a real
host. Do not claim it is tested when it is not.

## Traps when building the guest from a cloud image

Both of these were hit building the harness, and both bite the same way on a
real Debian-to-PVE conversion.

**cloud-init rewrites `/etc/hosts` on every boot.** Debian cloud images ship
`manage_etc_hosts: True`, which points the FQDN at `127.0.1.1`. PVE requires
its hostname to resolve to a real address, so `pmxcfs` exits and
`pve-cluster` fails -- taking `/etc/pve` and the whole web UI with it. It works
until the first reboot, then stops. Disable it *before* installing PVE:

```bash
sed -i 's/^manage_etc_hosts:.*/manage_etc_hosts: false/' /etc/cloud/cloud.cfg
printf '127.0.0.1 localhost\n<ip> <fqdn> <shortname>\n' > /etc/hosts
hostname -i    # must print the real IP, never 127.0.x.x
```

**Installing PVE discards root's SSH keys.** `pve-manager` replaces
`/root/.ssh/authorized_keys` with a symlink into `/etc/pve/priv/`, which is
empty on a fresh install -- and unreadable at all while `pve-cluster` is down.
On a remote host that is a lockout with no way back in. Keep an access path
that PVE does not manage:

```bash
cp /root/.ssh/id_rsa.pub /etc/ssh/authorized_keys_test
printf 'AuthorizedKeysFile /etc/ssh/authorized_keys_test .ssh/authorized_keys\n' \
    > /etc/ssh/sshd_config.d/99-test-access.conf
```

A BIOS/UEFI mismatch also needs sorting: cloud images ship `grub-pc`, so a
guest booted with OVMF needs `grub-efi-amd64` and `grub-cloud-amd64`/`grub-pc`
removed, or the kernel install leaves dpkg in a failed state.

## Host requirements

Nested virtualisation must be on -- `proxmox-optimize.sh` configures this:

```bash
cat /sys/module/kvm_intel/parameters/nested   # or kvm_amd
# expect: Y or 1
```

## Sizing

Keep it small. A nested PVE that is not running guests of its own needs very
little, and the point is to test configuration, not performance.

| Setting | Value | Why |
|---|---|---|
| Memory | 2048 MB, balloon 1024 | PVE 9 installs and runs apt comfortably here |
| Cores | 2 | `nproc` feeds the zvol taskq calculation, so more than 1 is useful |
| Disk | 16 G on a mirrored pool | Not on a raidz pool of consumer drives |
| CPU type | `host` | Nested virt needs the vendor flags passed through |
| Start on boot | **No** | These are started for a test run and stopped after |

Extra small disks (4 G each) can be attached to build a real ZFS pool inside
the guest and exercise the pool-layout detection in `proxmox-disk-errors.sh`.

## Reproducing the stall

The failure that caused the incident -- a device that stalls rather than
erroring -- can be simulated inside the guest with `dm-delay` or `dm-flakey`
layered under a scratch pool. That is how you prove the zvol taskq partitioning
actually contains the blast radius rather than assuming it does.

**Run fault injection inside the guest only.** Never against the host's pools.

## Two guests, and what each one proves

The n-0.1 rule needs two starting states, because the interesting behaviour is
different at each:

| Guest | State | Proves |
|---|---|---|
| current | installed at the newest series | the installed floor holds it there and the next minor does not land |
| behind | installed one series back | the pin holds it at that series while a newer one is published |

Both stay **stopped** unless a test is running, and only one runs at a time.
Each carries a snapshot to roll back to, so a test cycle starts from a known
state rather than from whatever the last run left behind.

### Getting a guest onto an older series

The Proxmox CE archive keeps older minors -- it does **not** carry only the
current release -- so a guest can be walked back with a temporary pin rather
than installed from an old ISO:

```bash
cat > /etc/apt/preferences.d/force-old << 'EOF'
Package: pve-manager
Pin: version 9.1.*
Pin-Priority: 1001

Package: proxmox-ve
Pin: version 9.1.*
Pin-Priority: 1001
EOF
apt-get update
apt-get dist-upgrade -y --allow-downgrades
rm /etc/apt/preferences.d/force-old
```

Priority 1001 is deliberate here and is exactly what the real policy must never
use: at 1000 or above apt will downgrade to reach a pin. That is the property
being borrowed to build the fixture.

### The assertion

With the guest on the older series and the policy applied, apt must not move:

```bash
apt-cache policy pve-manager        # Candidate must equal Installed
apt-get -s dist-upgrade             # must report 0 upgraded
```

Without the policy the same host shows the newer series as its candidate. That
before-and-after pair is the whole test.

### What still does not need a VM

`test-apt-pinning.sh` covers the pinning semantics deterministically against a
synthetic repository, and `test-update-policy.sh` carries fixtures captured
verbatim from the real archive. Reach for the guests only for what apt cannot
model: the UI customisation, the APT hook's exit status, and ZFS module
parameters.
