#!/bin/bash
# ============================================================================
# final-flash.sh — mac-side driver. Run while the phone is in TWRP with adb
# authorized. Assumes (already done once):
#   - GPT written into userdata: [esp 512MiB | ubuntu-root 110G | staging 1GiB]
#   - U-Boot flashed to the boot partition
# This script pushes the remaining payload and runs the device-side staging:
#   staging payload -> userdata tail; ESP image -> ESP partition; reboot.
# The rescue installer then runs on the mainline kernel automatically and
# installs Ubuntu, flips the boot entry and reboots into Ubuntu.
# ============================================================================
set -e
cd "$(dirname "$0")"
ADB="adb"

state=$($ADB get-state 2>/dev/null || true)
[ "$state" = "device" ] || { echo "FATAL: phone not in adb device state (TWRP + authorized). Current: '$state'"; exit 1; }

echo "== 1. push payload files =="
$ADB shell mkdir -p /tmp
$ADB push staging-payload.tar.gz /tmp/                      # staged into userdata tail
$ADB push ubuntu-base.tar.gz /tmp/                          # chroot base for mke2fs/debugfs
$ADB push assets/vmlinuz /tmp/vmlinuz                       # mainline kernel (pmOS 7.2)
$ADB push assets/esp/EFI/BOOT/systemd-bootaa64.efi /tmp/BOOTAA64.EFI
$ADB push initramfs-rescue.gz /tmp/initramfs-rescue.gz      # busybox rescue initramfs

echo "== 2. run device-side staging =="
$ADB push twrp-stage.sh /tmp/
$ADB shell 'sh /tmp/twrp-stage.sh' 2>&1 | tail -30

echo "== 3. reboot into U-Boot -> rescue installer =="
$ADB reboot
echo "Rebooted. The rescue installer runs on-screen (and via telnet on"
echo "172.16.42.1 once its USB gadget comes up). When it finishes it reboots"
echo "into Ubuntu automatically. Watch: nc/telnet 172.16.42.1 after setting"
echo "the Mac's USB interface to 172.16.42.2/24."
