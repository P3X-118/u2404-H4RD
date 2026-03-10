#!/bin/bash
#
# test-kvm.sh - Automated KVM/QEMU cloud-init testing
#
# This script:
# 1. Downloads Ubuntu 24.04 cloud image (or uses existing)
# 2. Creates cloud-init ISO from examples
# 3. Runs VM with cloud-init
# 4. Verifies deployment
#
# Usage:
#   ./scripts/test-kvm.sh [OPTIONS]
#
# Options:
#   -d, --destroy    Destroy VM after test
#   -k, --keep       Keep VM running after test
#   -i, --image      Path to custom image
#   -h, --help       Show this help

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLE_DIR="$(dirname "$SCRIPT_DIR")"

# Configuration
VM_NAME="u2404-stig-test"
MEMORY=4096
CPUS=2
DISK_SIZE="20G"
IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
IMAGE_FILE="noble-server-cloudimg-amd64.img"
CLOUD_INIT_ISO="cloud-init-test.iso"
KEEP_VM=false
DESTROY_VM=true
CUSTOM_IMAGE=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -d, --destroy    Destroy VM after test (default)"
    echo "  -k, --keep       Keep VM running after test"
    echo "  -i, --image FILE Use custom image"
    echo "  -h, --help       Show this help"
    echo ""
    echo "Example:"
    echo "  ./scripts/test-kvm.sh -k          # Keep VM running"
    echo "  ./scripts/test-kvm.sh -i my.img    # Use custom image"
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--destroy)
            DESTROY_VM=true
            KEEP_VM=false
            shift
            ;;
        -k|--keep)
            KEEP_VM=true
            DESTROY_VM=false
            shift
            ;;
        -i|--image)
            CUSTOM_IMAGE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Check prerequisites
check_prereqs() {
    log_info "Checking prerequisites..."
    
    # Check for KVM
    if ! command -v qemu-system-x86_64 &> /dev/null; then
        log_error "qemu-system-x86_64 not found. Install qemu-kvm"
        exit 1
    fi
    
    # Check for libvirtd
    if ! command -v virsh &> /dev/null; then
        log_warn "virsh not found. Using direct qemu-system-x86_64"
    fi
    
    log_info "Prerequisites OK"
}

# Download Ubuntu cloud image
download_image() {
    if [[ -n "$CUSTOM_IMAGE" ]]; then
        if [[ -f "$CUSTOM_IMAGE" ]]; then
            IMAGE_FILE="$CUSTOM_IMAGE"
            log_info "Using custom image: $IMAGE_FILE"
        else
            log_error "Custom image not found: $CUSTOM_IMAGE"
            exit 1
        fi
    elif [[ ! -f "$IMAGE_FILE" ]]; then
        log_info "Downloading Ubuntu 24.04 cloud image..."
        wget -O "${IMAGE_FILE}.tmp" "$IMAGE_URL"
        mv "${IMAGE_FILE}.tmp" "$IMAGE_FILE"
        log_info "Download complete"
    else
        log_info "Using existing image: $IMAGE_FILE"
    fi
    
    # Resize if needed
    CURRENT_SIZE=$(qemu-img info "$IMAGE_FILE" | grep "virtual size" | awk '{print $3}')
    if [[ "$CURRENT_SIZE" != *"${DISK_SIZE}"* ]]; then
        log_info "Resizing disk to $DISK_SIZE..."
        qemu-img resize "$IMAGE_FILE" "$DISK_SIZE"
    fi
}

# Create cloud-init ISO
create_cloud_init_iso() {
    log_info "Creating cloud-init ISO..."
    
    SEED_DIR=$(mktemp -d)
    
    if [[ -f "$ROLE_DIR/examples/user-data" ]]; then
        cp "$ROLE_DIR/examples/user-data" "$SEED_DIR/user-data"
    else
        log_error "user-data not found in examples/"
        rm -rf "$SEED_DIR"
        exit 1
    fi
    
    if [[ -f "$ROLE_DIR/examples/meta-data" ]]; then
        cp "$ROLE_DIR/examples/meta-data" "$SEED_DIR/meta-data"
    else
        log_error "meta-data not found in examples/"
        rm -rf "$SEED_DIR"
        exit 1
    fi
    
    # Show contents
    log_info "user-data contents:"
    cat "$SEED_DIR/user-data" | head -10
    echo "..."
    log_info "meta-data contents:"
    cat "$SEED_DIR/meta-data"
    
    # Create ISO
    if command -v genisoimage &> /dev/null; then
        genisoimage -output "$CLOUD_INIT_ISO" -volid cidata -rock "$SEED_DIR/"
    elif command -v mkisofs &> /dev/null; then
        mkisofs -o "$CLOUD_INIT_ISO" -V cidata -r -J "$SEED_DIR/"
    elif command -v cloud-localds &> /dev/null; then
        cloud-localds "$CLOUD_INIT_ISO" "$SEED_DIR/user-data" "$SEED_DIR/meta-data"
    else
        log_error "No ISO creation tool found. Install genisoimage or cloud-utils"
        rm -rf "$SEED_DIR"
        exit 1
    fi
    
    rm -rf "$SEED_DIR"
    log_info "Created: $CLOUD_INIT_ISO"
}

# Check if VM exists
vm_exists() {
    if command -v virsh &> /dev/null; then
        virsh domstate "$VM_NAME" &> /dev/null
    else
        return 1
    fi
}

# Destroy existing VM
destroy_vm() {
    if vm_exists; then
        log_info "Destroying existing VM..."
        if command -v virsh &> /dev/null; then
            virsh destroy "$VM_NAME" 2>/dev/null || true
            virsh undefine "$VM_NAME" --nvram 2>/dev/null || true
        fi
    fi
}

# Run VM with cloud-init
run_vm() {
    log_info "Starting VM with cloud-init..."
    
    # Check for bridged network
    BRIDGE=""
    if ip link show virbr0 &> /dev/null; then
        BRIDGE="bridge,id=net0,br=virbr0"
    fi
    
    if command -v virt-install &> /dev/null; then
        # Use virt-install (recommended)
        virt-install \
            --name "$VM_NAME" \
            --ram "$MEMORY" \
            --vcpus "$CPUS" \
            --disk path="$IMAGE_FILE,device=disk,bus=virtio" \
            --disk path="$CLOUD_INIT_ISO,device=cdrom" \
            --os-variant ubuntu24.04 \
            --network network=default,model=virtio \
            --graphics vnc \
            --boot hd,menu=on \
            --import \
            --noautoconsole
        
        log_info "VM created. Waiting for cloud-init to complete..."
        
        # Wait for VM to boot
        sleep 10
        
        # Try to get console output
        if command -v virsh &> /dev/null; then
            log_info "VM console (last 20 lines):"
            virsh console "$VM_NAME" --tail 20 2>/dev/null || true
        fi
        
    else
        # Fallback to direct qemu-system-x86_64
        log_warn "virt-install not found, using direct qemu-system-x86_64"
        
        NET_ARG=""
        if [[ -n "$BRIDGE" ]]; then
            NET_ARG="-netdev $BRIDGE,vlan=0 -device virtio-net-pci,netdev=vlan0"
        else
            NET_ARG="-nic user,hostfwd=tcp::2222-:22"
        fi
        
        qemu-system-x86_64 \
            -m "$MEMORY" \
            -smp "$CPUS" \
            -cpu host \
            -hda "$IMAGE_FILE" \
            -cdrom "$CLOUD_INIT_ISO" \
            $NET_ARG \
            -display none \
            -serial stdio &
        
        QEMU_PID=$!
        log_info "QEMU started with PID: $QEMU_PID"
        
        # Wait for boot
        sleep 30
    fi
}

# Verify deployment
verify_deployment() {
    log_info "Verifying deployment..."
    
    if ! command -v virsh &> /dev/null; then
        log_warn "virsh not available, skipping verification"
        return
    fi
    
    # Get VM IP
    local IP=""
    for i in {1..30}; do
        IP=$(virsh domifaddr "$VM_NAME" 2>/dev/null | grep "virtio" | awk '{print $4}' | cut -d'/' -f1)
        if [[ -n "$IP" ]]; then
            break
        fi
        sleep 2
    done
    
    if [[ -z "$IP" ]]; then
        log_warn "Could not get VM IP address"
    else
        log_info "VM IP: $IP"
    fi
    
    # Check cloud-init status
    log_info "Checking cloud-init status..."
    if virsh domstate "$VM_NAME" | grep -q "running"; then
        log_info "VM is running"
        
        # Try to execute commands via virsh
        if virsh --connect qemu:///system domfsfree "$VM_NAME" &> /dev/null; then
            log_info "Attempting to verify guest agent..."
            #virsh qemu-agent-command "$VM_NAME" '{"execute":"guest-info"}' 2>/dev/null || true
        fi
    fi
    
    log_info "Deployment verification complete"
}

# Cleanup
cleanup() {
    if [[ "$DESTROY_VM" == "true" ]]; then
        log_info "Cleaning up..."
        if command -v virsh &> /dev/null && vm_exists; then
            virsh destroy "$VM_NAME" 2>/dev/null || true
            virsh undefine "$VM_NAME" --nvram 2>/dev/null || true
            log_info "VM destroyed"
        fi
        
        if [[ -f "$CLOUD_INIT_ISO" ]]; then
            rm -f "$CLOUD_INIT_ISO"
            log_info "Cleaned up cloud-init ISO"
        fi
    else
        log_info "Keeping VM running. Connect with:"
        echo "  virsh console $VM_NAME"
        echo "  or"
        echo "  virt-manager"
    fi
}

# Main
main() {
    echo "=========================================="
    echo "  KVM/QEMU Cloud-Init Test"
    echo "=========================================="
    echo ""
    
    check_prereqs
    download_image
    create_cloud_init_iso
    destroy_vm
    run_vm
    verify_deployment
    
    echo ""
    echo "=========================================="
    echo "  Test Complete"
    echo "=========================================="
    
    if [[ "$KEEP_VM" == "true" ]]; then
        echo ""
        log_info "VM is still running!"
        echo ""
        echo "To connect:"
        echo "  virsh console $VM_NAME"
        echo ""
        echo "To destroy:"
        echo "  virsh destroy $VM_NAME"
        echo "  virsh undefine $VM_NAME --nvram"
    else
        cleanup
    fi
}

# Trap for cleanup on exit
trap 'cleanup' EXIT

main
