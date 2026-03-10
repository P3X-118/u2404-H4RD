# Cloud-Init Seed Configuration Guide

This directory contains the cloud-init configuration files needed to bootstrap the hardened Ubuntu 24.04 image.

## Seed Directory Structure

The seed directory contains two required files:

```
/seed/
├── user-data    # Cloud-init configuration (cloud-config or autoinstall)
└── meta-data    # Instance metadata (hostname, instance-id)
```

## How Cloud-Init Seed Works

### 1. NoCloud Datasource
The role configures cloud-init to use the `nocloud` datasource, which reads configuration from a local filesystem (FAT32, ISO9660, or VFAT).

### 2. Boot Process
1. VM boots from the hardened image
2. Cloud-init scans for datasource media (CD-ROM, USB, or virtio-disk)
3. If `user-data` and `meta-data` are found in `/seed/`, cloud-init applies them
4. The system is configured according to the user-data specification

### 3. Seed Location Options

| Method | Description |
|--------|-------------|
| **CD-ROM/ISO** | Attach cloud-init ISO as secondary drive |
| **USB Drive** | FAT32-formatted USB with seed files |
| **Virtio Disk** | Secondary virtio disk with seed partition |
| **Network** | Combine with NoCloud-net for network retrieval |

## Creating a Cloud-Init ISO

### Method 1: Using genisoimage (Linux)

```bash
# Create directory for seed files
mkdir -p seed

# Copy user-data and meta-data
cp examples/user-data seed/
cp examples/meta-data seed/

# Generate ISO (volume label MUST be 'cidata')
genisoimage -output cloud-init.iso -volid cidata -rock seed/

# Cleanup
rm -rf seed
```

### Method 2: Using mkisofs

```bash
mkisofs -o cloud-init.iso -V cidata -r -J seed/
```

### Method 3: Using cloud-localds (from cloud-utils)

```bash
# Install cloud-utils
apt-get install cloud-utils

# Create cloud-init image
cloud-localds cloud-init.img user-data meta-data
```

## Deploying to Different Hypervisors

### Proxmox VE

```bash
# Upload the hardened image
qm importdisk <vmid> ubuntu-hardened.raw local-lvm

# Upload cloud-init ISO
qm set <vmid> --ide2 local:iso/cloud-init.iso,media=cdrom

# Configure VM
qm set <vmid> --boot order=ide2
qm set <vmid> --cores 2
qm set <vmid> --memory 4096
```

### Libvirt/KVM (virsh)

```bash
# Define VM with cloud-init ISO
virt-install \
  --name ubuntu-hardened \
  --ram 4096 \
  --disk path=/var/lib/libvirt/images/ubuntu-hardened.qcow2,device=disk \
  --disk path=/var/lib/libvirt/images/cloud-init.iso,device=cdrom \
  --vcpus 2 \
  --os-variant ubuntu24.04 \
  --network network=default \
  --graphics vnc \
  --boot hd
```

### VMware ESXi

1. Upload the hardened image as VMDK
2. Upload cloud-init ISO to datastore
3. Add CD/DVD drive to VM, point to ISO
4. Ensure VM firmware is BIOS/UEFI compatible

## Customizing user-data

### Basic Cloud-Config (Interactive Setup)

```yaml
#cloud-config
users:
  - name: admin
    primary_group: admin
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ssh-rsa AAAA...

package_update: true
package_upgrade: true

packages:
  - vim
  - curl
  - htop

runcmd:
  - systemctl enable sshd
  - systemctl restart sshd
```

### Autoinstall (Unattended)

```yaml
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: us
  identity:
    hostname: my-server
    password: "$6$..."
    username: admin
  ssh:
    install-server: true
    allow-pw: false
  storage:
    layout:
      name: lvm
```

## Generating Password Hash

```bash
# Method 1: mkpasswd (whois package)
apt-get install whois
mkpasswd --method=sha-512

# Method 2: python3
python3 -c "import crypt; print(crypt.crypt('password', crypt.mksalt(crypt.METHOD_SHA512)))"

# Method 3: openssl
openssl passwd -6
```

## Troubleshooting

### Cloud-init Not Running

```bash
# Check cloud-init status
cloud-init status

# Enable cloud-init
systemctl enable cloud-init

# Manually trigger
cloud-init init
cloud-init modules --mode config
cloud-init modules --mode final
```

### Logs

```bash
# Cloud-init logs
journalctl -u cloud-init
less /var/log/cloud-init.log
less /var/log/cloud-init-output.log
```

### Common Issues

| Issue | Solution |
|-------|----------|
| No user logged in | Check SSH keys in user-data |
| Password auth fails | Ensure `allow-pw: true` or use SSH keys |
| Hostname not set | Verify meta-data contains `local-hostname` |
| Packages not installed | Check package section syntax in user-data |

## Integration with Hardening Role

The Ansible role will:

1. Install cloud-init package
2. Configure `/etc/cloud/cloud.cfg.d/99_datasource.cfg` to use NoCloud
3. Create seed directory at `/var/lib/cloud/seed/nocloud/`

You can customize the seed files by setting these variables:

```yaml
cloud_init_hostname: my-server
cloud_init_username: admin
cloud_init_ssh_keys:
  - ssh-rsa AAAA...
cloud_init_packages:
  - vim
  - curl
```
