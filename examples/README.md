# Cloud-Init Examples

This directory contains example cloud-init configuration files for deploying the hardened Ubuntu 24.04 image.

## Usage

### For KVM/Proxmox (NoCloud)

1. Place `user-data` and `meta-data` in a directory (e.g., `/seed/`)
2. Create an ISO or use a virtio drive
3. Mount the seed directory to the VM

Example for Proxmox:
```bash
# Create cloud-init ISO
genisoimage -output cloud-init.iso -volid cidata -rock user-data meta-data

# Attach to VM
qm set <vmid> --ide2 local:iso/cloud-init.iso,media=cdrom
```

### Variables

Override these in your Ansible playbook or inventory:

| Variable | Default | Description |
|----------|---------|-------------|
| `ubtu24stig_install_cloud_init` | `true` | Install cloud-init |
| `cloud_init_datasource` | `nocloud` | Datasource (nocloud, ec2, azure, gce) |
| `cloud_init_default_user` | `ubuntu` | Default username |
| `cloud_init_hostname` | `ansible hostname` | VM hostname |
| `cloud_init_password` | - | User password (hashed) |
| `cloud_init_ssh_keys` | `[]` | List of SSH public keys |
| `cloud_init_packages` | `[]` | Packages to install |
| `cloud_init_runcmd` | `[]` | Commands to run at boot |

### Generating Password Hash

```bash
# Generate SHA-512 password hash
mkpasswd --method=sha-512
```

### Creating a RAW Image with Cloud-Init

```bash
# Create empty image file
dd if=/dev/zero of=ubuntu-hardened.raw bs=1G count=20

# Partition and format
# (use gdisk, fdisk, or virt-manager)

# Mount and extract Ubuntu 24.04 cloud image
# Apply hardening role
# Add cloud-init configuration

# Compress for storage
gzip ubuntu-hardened.raw
```
