#!/bin/bash
#
# cloud-init-seed.sh - Generate cloud-init seed ISO
#
# Usage:
#   ./cloud-init-seed.sh --user-data user-data --meta-data meta-data --output cloud-init.iso
#

set -e

OUTPUT="cloud-init.iso"
USER_DATA=""
META_DATA=""
SEED_DIR=$(mktemp -d)

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -u, --user-data FILE    Path to user-data file (required)"
    echo "  -m, --meta-data FILE    Path to meta-data file (required)"
    echo "  -o, --output FILE       Output ISO file (default: cloud-init.iso)"
    echo "  -h, --help             Show this help message"
    echo ""
    echo "Example:"
    echo "  $0 -u examples/user-data -m examples/meta-data -o cloud-init.iso"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -u|--user-data)
            USER_DATA="$2"
            shift 2
            ;;
        -m|--meta-data)
            META_DATA="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

if [[ -z "$USER_DATA" ]] || [[ -z "$META_DATA" ]]; then
    echo "Error: Both --user-data and --meta-data are required"
    usage
fi

if [[ ! -f "$USER_DATA" ]]; then
    echo "Error: user-data file not found: $USER_DATA"
    exit 1
fi

if [[ ! -f "$META_DATA" ]]; then
    echo "Error: meta-data file not found: $META_DATA"
    exit 1
fi

cp "$USER_DATA" "$SEED_DIR/user-data"
cp "$META_DATA" "$SEED_DIR/meta-data"

if command -v genisoimage &> /dev/null; then
    genisoimage -output "$OUTPUT" -volid cidata -rock "$SEED_DIR/"
elif command -v mkisofs &> /dev/null; then
    mkisofs -o "$OUTPUT" -V cidata -r -J "$SEED_DIR/"
elif command -v cloud-localds &> /dev/null; then
    cloud-localds "$OUTPUT" "$USER_DATA" "$META_DATA"
else
    echo "Error: No ISO creation tool found. Install genisoimage, mkisofs, or cloud-utils"
    rm -rf "$SEED_DIR"
    exit 1
fi

rm -rf "$SEED_DIR"

echo "Created: $OUTPUT"
echo ""
echo "To use with Proxmox:"
echo "  qm set <vmid> --ide2 local:iso/$OUTPUT,media=cdrom"
echo ""
echo "To use with libvirt:"
echo "  virsh attach-disk <vmname> $OUTPUT --type cdrom --mode readonly"
