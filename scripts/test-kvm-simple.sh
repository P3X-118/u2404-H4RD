#!/bin/bash
#
# test-kvm-simple.sh - Simple KVM/QEMU cloud-init test using virt-install
#
# Requirements:
#   - qemu-kvm
#   - virt-install
#   - cloud-utils (for cloud-localds)
#   - genisoimage or mkisofs
#

set -e

ROLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM_NAME="ubuntu-hardened-test"
DISK_PATH="/var/lib/libvirt/images/${VM_NAME}.qcow2"
MEMORY=4096
CPUS=2

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

cleanup() {
    log_info "Cleaning up..."
    sudo virsh -c qemu:///system destroy "$VM_NAME" 2>/dev/null || true
    sudo virsh -c qemu:///system undefine "$VM_NAME" --nvram 2>/dev/null || true
    sudo rm -f /var/lib/libvirt/images/cloud-init-test.iso
    rm -f cloud-init-test.iso
    log_info "Done"
}

# Check prerequisites
check_prereqs() {
    local missing=()
    for cmd in qemu-img virt-install virsh cloud-localds genisoimage; do
        if ! command -v $cmd &> /dev/null; then
            missing+=($cmd)
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing: ${missing[@]}"
        echo "Install with: apt-get install qemu-utils libvirt-daemon-system virt-manager cloud-utils"
        exit 1
    fi
}

# Download base image
get_image() {
    local img_url="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
    local img_file="noble-server-cloudimg-amd64.img"
    
    if [[ ! -f "$img_file" ]]; then
        log_info "Downloading Ubuntu 24.04 cloud image..."
        wget -q "$img_url"
    else
        log_info "Using existing image"
    fi
    
    # Convert to qcow2 if needed
    if [[ "$img_file" != *.qcow2 ]]; then
        log_info "Converting to qcow2..."
        qemu-img convert -O qcow2 "$img_file" "$DISK_PATH"
    else
        cp "$img_file" "$DISK_PATH"
    fi
    
    # Resize
    qemu-img resize "$DISK_PATH" 20G
}

# Create cloud-init ISO
create_iso() {
    log_info "Creating cloud-init ISO..."
    
    local seed_dir=$(mktemp -d)
    local iso_in_tmp="/tmp/cloud-init-test.iso"
    
    cp "$ROLE_DIR/examples/user-data" "$seed_dir/"
    cp "$ROLE_DIR/examples/meta-data" "$seed_dir/"
    
    sudo genisoimage -output "$iso_in_tmp" -volid cidata -rock "$seed_dir/"
    
    # Copy to libvirt images directory for access
    sudo cp "$iso_in_tmp" /var/lib/libvirt/images/cloud-init-test.iso
    
    rm -rf "$seed_dir"
}

# Run VM
run_vm() {
    log_info "Starting VM..."
    
    # Clean up any existing
    sudo virsh -c qemu:///system destroy "$VM_NAME" 2>/dev/null || true
    sudo virsh -c qemu:///system undefine "$VM_NAME" --nvram 2>/dev/null || true
    
    sudo virt-install \
        --connect qemu:///system \
        --name "$VM_NAME" \
        --ram "$MEMORY" \
        --vcpus "$CPUS" \
        --disk path="$DISK_PATH,device=disk,bus=virtio" \
        --disk path="/var/lib/libvirt/images/cloud-init-test.iso,device=cdrom" \
        --os-variant ubuntu24.04 \
        --network network=default,model=virtio \
        --graphics vnc \
        --boot hd,menu=on \
        --import \
        --noautoconsole
    
    log_info "VM started. Waiting for cloud-init..."
    
    # Wait for cloud-init
    sleep 30
    
    # Show console
    log_info "Console output:"
    sudo virsh -c qemu:///system console "$VM_NAME" --safe || true
}

# Main
main() {
    echo "=========================================="
    echo "  KVM Cloud-Init Test"
    echo "=========================================="
    
    check_prereqs
    get_image
    create_iso
    run_vm
    
    echo ""
    echo "=========================================="
    echo "  Test Complete"
    echo "=========================================="
    echo ""
    echo "To connect:"
    echo "  virsh console $VM_NAME"
    echo ""
    echo "To clean up:"
    echo "  ./scripts/test-kvm.sh --destroy"
}

main "$@"
