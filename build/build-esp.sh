#!/bin/bash
# Build the ESP FAT32 image (raw, no dmg wrapper): systemd-boot + vmlinuz +
# rescue installer entry + rescue initramfs.
set -e
cd "$(dirname "$0")"

IMG=$PWD/flash/esp.img
rm -f "$IMG"

echo "== create raw image + FAT32 =="
mkfile -n 512m "$IMG"
newfs_msdos -F 32 -v ESP "$IMG"
MNT=$(mktemp -d)
hdiutil attach "$IMG" -mountpoint "$MNT" -quiet -nobrowse

echo "== populate =="
mkdir -p "$MNT/EFI/BOOT" "$MNT/loader/entries"
cp assets/esp/EFI/BOOT/systemd-bootaa64.efi "$MNT/EFI/BOOT/BOOTAA64.EFI"
cp assets/vmlinuz "$MNT/vmlinuz"
# rescue initramfs built by build-rescue.sh
if [ ! -f /tmp/rescue-build/initramfs.gz ]; then
    echo "FATAL: run build-rescue.sh first (need /tmp/rescue-build/initramfs.gz)"; exit 1
fi
cp /tmp/rescue-build/initramfs.gz "$MNT/initramfs-rescue.gz"
cat > "$MNT/loader/loader.conf" <<'EOF'
timeout 3
default rescue.conf
console-mode keep
editor no
EOF
cat > "$MNT/loader/entries/rescue.conf" <<'EOF'
title Rescue installer (S10 Ubuntu)
linux /vmlinuz
initrd /initramfs-rescue.gz
options console=tty0 loglevel=7
EOF
cat > "$MNT/loader/entries/ubuntu.conf" <<'EOF'
title Ubuntu 26.04 LTS (S10)
linux /vmlinuz
options root=PARTLABEL=ubuntu-root rootwait rw console=tty0 console=ttyGS0,115200n8 loglevel=4
EOF
ls -la "$MNT" "$MNT/loader/entries"

hdiutil detach "$MNT" -quiet
ls -la "$IMG"
echo "ESP image done: $IMG"
