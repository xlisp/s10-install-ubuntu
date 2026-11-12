#!/bin/sh
# ============================================================================
# twrp-stage.sh — run inside TWRP (adb shell sh /tmp/twrp-stage.sh)
# One-shot device-side preparation:
#   1. writes payload.tar.gz (from /tmp/staging-payload.tar.gz) into the
#      staging region (userdata tail, 1GiB, sector 28959744 @4096)
#   2. builds the ESP filesystem image in RAM (chroot mke2fs + debugfs on a
#      regular file — no loop devices, no Rust coreutils)
#   3. dd's the ESP image into the ESP partition (userdata offset 1MiB)
#   4. verifies and reboots into U-Boot -> rescue -> installer
#
# Expected in /tmp (pushed from the Mac by final-flash.sh):
#   ubuntu-base.tar.gz  vmlinuz  BOOTAA64.EFI  initramfs-rescue.gz
#   staging-payload.tar.gz
# ============================================================================
set -x

UD=/dev/block/by-name/userdata
[ -e "$UD" ] || { echo "FATAL: $UD missing"; exit 1; }

# --- 0. device nodes (TWRP devtmpfs lacks some) ------------------------------
mknod /dev/block/sda31 b 259 15 2>/dev/null
mknod /dev/zero c 1 5 2>/dev/null
mknod /dev/null c 1 3 2>/dev/null
mknod /dev/random c 1 8 2>/dev/null
mknod /dev/urandom c 1 9 2>/dev/null

for f in /tmp/ubuntu-base.tar.gz /tmp/vmlinuz /tmp/BOOTAA64.EFI \
         /tmp/initramfs-rescue.gz /tmp/staging-payload.tar.gz; do
    [ -e "$f" ] || { echo "FATAL: missing $f"; exit 1; }
done

# --- 1. stage the payload blob into the userdata tail ------------------------
STAGING_SEEK=28959744          # sector 28959744 (4096B) = byte 118,613,061,632
dd if=/tmp/staging-payload.tar.gz of=$UD bs=4096 seek=$STAGING_SEEK 2>&1 | tail -1
sync
echo "=== staging verify (must match mac sha):"
dd if=$UD bs=4096 skip=$STAGING_SEEK count=1 2>/dev/null | sha256sum
sha256sum /tmp/staging-payload.tar.gz

# --- 2. stage chroot: ubuntu-base provides mke2fs + debugfs (C, no Rust) ------
rm -rf /tmp/stage
mkdir -p /tmp/stage/dev/block
cd /tmp/stage || exit 1
tar xzf /tmp/ubuntu-base.tar.gz
mknod dev/null c 1 3 2>/dev/null
mknod dev/zero c 1 5 2>/dev/null
mknod dev/random c 1 8 2>/dev/null
mknod dev/urandom c 1 9 2>/dev/null
mknod dev/block/sda31 b 259 15 2>/dev/null
cp /tmp/BOOTAA64.EFI /tmp/vmlinuz /tmp/initramfs-rescue.gz .

# --- 3. build the ESP filesystem image in RAM --------------------------------
printf 'timeout 3\ndefault rescue.conf\nconsole-mode keep\neditor no\n' > cfg-loader.conf
printf 'title Rescue installer (S10 Ubuntu)\nlinux /vmlinuz\ninitrd /initramfs-rescue.gz\noptions console=tty0 loglevel=7 panic=30\n' > cfg-rescue.conf
printf 'title Ubuntu 26.04 LTS (S10)\nlinux /vmlinuz\noptions root=PARTLABEL=ubuntu-root rootwait rw console=tty0 console=ttyGS0,115200n8 loglevel=4\n' > cfg-ubuntu.conf
printf 'mkdir /EFI\nmkdir /EFI/BOOT\nwrite /BOOTAA64.EFI /EFI/BOOT/BOOTAA64.EFI\nmkdir /loader\nmkdir /loader/entries\nwrite /cfg-loader.conf /loader/loader.conf\nwrite /cfg-rescue.conf /loader/entries/rescue.conf\nwrite /cfg-ubuntu.conf /loader/entries/ubuntu.conf\nwrite /vmlinuz /vmlinuz\nwrite /initramfs-rescue.gz /initramfs-rescue.gz\nquit\n' > debugfs.cmds

chroot /tmp/stage /usr/sbin/mke2fs -q -F -t ext4 -b 1024 -L ESP /tmp/esp.img 512M \
    || { echo "FATAL: mke2fs ESP"; exit 1; }
chroot /tmp/stage /usr/sbin/debugfs -w -f /debugfs.cmds /tmp/esp.img 2>&1 | tail -4
chroot /tmp/stage /usr/sbin/debugfs -R "ls -l /" /tmp/esp.img 2>/dev/null | head -12
ls -la /tmp/stage/tmp/esp.img

# --- 4. write ESP image into the ESP partition (userdata offset 1MiB) --------
dd if=/tmp/stage/tmp/esp.img of=$UD bs=4096 seek=256 2>&1 | tail -1
sync

# --- 5. verify ----------------------------------------------------------------
echo "=== GPT (expect EFI PART):"
dd if=$UD bs=1 skip=4096 count=8 2>/dev/null | xxd
echo "=== ESP ext4 magic (expect 53 ef):"
dd if=$UD bs=1 skip=1049656 count=2 2>/dev/null | xxd
echo "=== staging gzip magic (expect 1f 8b):"
dd if=$UD bs=4096 skip=28959744 count=1 2>/dev/null | head -c 2 | xxd

rm -rf /tmp/stage
echo "==================================================================="
echo " STAGING + ESP DONE. Rebooting — U-Boot will boot the rescue"
echo " installer (default entry), which installs Ubuntu, then flips"
echo " the default boot entry to Ubuntu and reboots again."
echo "==================================================================="
