#!/bin/bash
#
# test-kvm.sh - KVM/QEMU cloud-init test with remote access support
#
# Usage:
#   ./scripts/test-kvm.sh              # Start and keep running
#   ./scripts/test-kvm.sh --destroy   # Destroy VM
#   ./scripts/test-kvm.sh --status    # Show status
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

# Configure libvirt for remote access
setup_remote_access() {
    log_info "Configuring libvirt for remote access..."
    
    # Enable TCP listener in libvirtd
    sudo sed -i 's/#listen_tcp = 1/listen_tcp = 1/' /etc/libvirt/libvirtd.conf
    sudo sed -i 's/#listen_addr = "192.168.0.1"/listen_addr = "0.0.0.0"/' /etc/libvirt/libvirtd.conf
    
    # Set auth to none for simplicity (in production, use SASL)
    sudo sed -i 's/#auth_tcp = "sasl"/auth_tcp = "none"/' /etc/libvirt/libvirtd.conf
    sudo sed -i 's/#auth_tls = "sasl"/auth_tls = "none"/' /etc/libvirt/libvirtd.conf
    
    # Restart libvirtd
    sudo systemctl restart libvirtd
    
    log_info "Libvirt configured for remote access"
}

# Configure default network for remote access
setup_network() {
    log_info "Configuring default network for remote access..."
    
    # Get default network XML and modify for listen on all interfaces
    sudo virsh -c qemu:///system net-dumpxml default > /tmp/default-network.xml
    
    # Modify to listen on 0.0.0.0
    sudo sed -i 's/127.0.0.1/0.0.0.0/g' /tmp/default-network.xml
    
    # Update network
    sudo virsh -c qemu:///system net-define /tmp/default-network.xml
    sudo virsh -c qemu:///system net-destroy default
    sudo virsh -c qemu:///system net-start default
    
    log_info "Network configured"
}

cleanup() {
    log_info "Cleaning up..."
    sudo virsh -c qemu:///system destroy "$VM_NAME" 2>/dev/null || true
    sudo virsh -c qemu:///system undefine "$VM_NAME" --nvram 2>/dev/null || true
    sudo rm -f /var/lib/libvirt/images/cloud-init-test.iso
    rm -f cloud-init-test.iso
    log_info "Done"
}

check_prereqs() {
    local missing=()
    for cmd in qemu-img virt-install virsh genisoimage; do
        if ! command -v $cmd &> /dev/null; then
            missing+=($cmd)
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing: ${missing[@]}"
        exit 1
    fi
}

get_image() {
    local img_url="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
    local img_file="noble-server-cloudimg-amd64.img"
    
    if [[ ! -f "$img_file" ]]; then
        log_info "Downloading Ubuntu 24.04 cloud image..."
        wget -q "$img_url"
    else
        log_info "Using existing image"
    fi
    
    if [[ "$img_file" != *.qcow2 ]]; then
        log_info "Converting to qcow2..."
        qemu-img convert -O qcow2 "$img_file" "$DISK_PATH"
    else
        cp "$img_file" "$DISK_PATH"
    fi
    
    qemu-img resize "$DISK_PATH" 20G
}

create_iso() {
    log_info "Creating cloud-init ISO..."
    
    local seed_dir=$(mktemp -d)
    local iso_in_tmp="/tmp/cloud-init-test.iso"
    
    cp "$ROLE_DIR/examples/user-data" "$seed_dir/"
    cp "$ROLE_DIR/examples/meta-data" "$seed_dir/"
    
    sudo genisoimage -output "$iso_in_tmp" -volid cidata -rock "$seed_dir/"
    sudo cp "$iso_in_tmp" /var/lib/libvirt/images/cloud-init-test.iso
    
    rm -rf "$seed_dir"
}

run_vm() {
    log_info "Starting VM..."
    
    sudo virsh -c qemu:///system destroy "$VM_NAME" 2>/dev/null || true
    sudo virsh -c qemu:///system undefine "$VM_NAME" --nvram 2>/dev/null || true
    
    # VNC on 0.0.0.0 for remote access
    # Using default NAT network for reliable testing
    # For macvtap (host-isolated), use: --network type=direct,source=eno1,source_mode=bridge,model=virtio
    sudo virt-install \
        --connect qemu:///system \
        --name "$VM_NAME" \
        --ram "$MEMORY" \
        --vcpus "$CPUS" \
        --disk path="$DISK_PATH,device=disk,bus=virtio" \
        --disk path="/var/lib/libvirt/images/cloud-init-test.iso,device=cdrom" \
        --os-variant ubuntu24.04 \
        --network network=default,model=virtio \
        --graphics vnc,listen=0.0.0.0,port=-1 \
        --boot hd,menu=on \
        --import \
        --noautoconsole
}

show_status() {
    if sudo virsh -c qemu:///system list --all | grep -q "$VM_NAME"; then
        local state=$(sudo virsh -c qemu:///system domstate "$VM_NAME" 2>/dev/null || echo "unknown")
        local ip=$(sudo virsh -c qemu:///system domifaddr "$VM_NAME" 2>/dev/null | grep "ipv4" | awk '{print $4}' || echo "N/A")
        local vnc=$(sudo virsh -c qemu:///system dumpxml "$VM_NAME" 2>/dev/null | grep "graphics" | grep -oP "port='\K[^']+")
        
        echo ""
        echo "=========================================="
        echo "  VM Status: $state"
        echo "=========================================="
        echo "  Name:     $VM_NAME"
        echo "  IP:       $ip"
        echo "  VNC Port: $vnc"
        echo ""
        echo "  Connect remotely with:"
        echo "    virt-manager -c 'qemu+tcp://$(hostname -I | awk '{print $1}')/system'"
        echo "    or"
        echo "    vnc://$(hostname -I | awk '{print $1}'):$vnc"
        echo ""
    else
        echo "VM '$VM_NAME' is not running"
    fi
}

main() {
    case "${1:-}" in
        --destroy|-d)
            cleanup
            exit 0
            ;;
        --status|-s)
            show_status
            exit 0
            ;;
        --setup|-S)
            setup_remote_access
            setup_network
            exit 0
            ;;
    esac
    
    echo "=========================================="
    echo "  KVM Cloud-Init Test with Remote Access"
    echo "=========================================="
    
    check_prereqs
    
    # Check if remote access is configured
    if ! grep -q 'listen_tcp = 1' /etc/libvirt/libvirtd.conf 2>/dev/null; then
        log_info "First run - setting up remote access..."
        setup_remote_access
        setup_network
    fi
    
    get_image
    create_iso
    run_vm
    
    sleep 5
    show_status
    
    echo ""
    echo "=========================================="
    echo "  Test Running"
    echo "=========================================="
    echo ""
    echo "To check status:  ./scripts/test-kvm.sh --status"
    echo "To destroy:       ./scripts/test-kvm.sh --destroy"
}

main "$@"
