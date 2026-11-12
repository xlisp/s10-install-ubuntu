#!/bin/sh
# ============================================================================
# flash-uboot.sh — run inside TWRP/LineageOS recovery (adb shell)
# Backs up the stock boot partition, then writes the U-Boot boot image.
# ============================================================================
set -x

BOOT=/dev/block/by-name/boot
if [ ! -e "$BOOT" ]; then
    mkdir -p /dev/block/by-name
    mm=$(cat /sys/class/block/sda14/dev 2>/dev/null)
    major=$(printf '%s' "$mm" | cut -d: -f1)
    minor=$(printf '%s' "$mm" | cut -d: -f2)
    [ -e /dev/block/sda14 ] || mknod /dev/block/sda14 b "$major" "$minor"
    ln -sf /dev/block/sda14 "$BOOT"
    echo "created fallback node sda14 ($major:$minor)"
fi
[ -e "$BOOT" ] || { echo "FATAL: $BOOT not found"; exit 1; }
[ -f /tmp/u-boot.img ] || { echo "FATAL: /tmp/u-boot.img missing (adb push it first)"; exit 1; }

# 1. Backup stock boot (idempotent — keeps the first backup)
if [ ! -f /tmp/boot-stock-backup.img ]; then
    dd if="$BOOT" of=/tmp/boot-stock-backup.img bs=4096
    sync
    echo "stock boot backed up: $(ls -la /tmp/boot-stock-backup.img)"
    echo ">>> adb pull /tmp/boot-stock-backup.img  BEFORE rebooting! <<<"
fi

# 2. Flash U-Boot
dd if=/tmp/u-boot.img of="$BOOT" bs=4096 conv=fsync
sync
echo "U-Boot flashed to boot partition."
echo "Reboot now: the device will chainload S-Boot -> U-Boot -> systemd-boot -> Ubuntu"
