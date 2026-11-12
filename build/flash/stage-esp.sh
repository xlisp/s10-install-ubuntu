#!/bin/sh
# stage-esp.sh — run in TWRP: build 512MiB ext4 ESP image in RAM via chroot
# mke2fs + debugfs (no loop devices involved), then dd it to the ESP region.
set -x
# keep TWRP's own PATH (its tools may live in /sbin, not /system/bin)
echo "PATH=$PATH"

rm -rf /tmp/stage
mkdir -p /tmp/stage/dev/block /tmp/stage/debs /tmp/stage/cfg
cd /tmp/stage || exit 1
tar xzf /tmp/ubuntu-base.tar.gz

mknod dev/null c 1 3 2>/dev/null
mknod dev/zero c 1 5 2>/dev/null
mknod dev/random c 1 8 2>/dev/null
mknod dev/urandom c 1 9 2>/dev/null
mknod dev/block/sda31 b 259 15 2>/dev/null

cp /tmp/BOOTAA64.EFI /tmp/vmlinuz /tmp/initramfs-rescue.gz .

printf 'timeout 3\ndefault rescue.conf\nconsole-mode keep\neditor no\n' > cfg/loader.conf
printf 'title Rescue installer (S10 Ubuntu)\nlinux /vmlinuz\ninitrd /initramfs-rescue.gz\noptions console=tty0 loglevel=7 panic=30\n' > cfg/rescue.conf
printf 'title Ubuntu 26.04 LTS (S10)\nlinux /vmlinuz\noptions root=PARTLABEL=ubuntu-root rootwait rw console=tty0 console=ttyGS0,115200n8 loglevel=4\n' > cfg/ubuntu.conf

printf 'mkdir /EFI\nmkdir /EFI/BOOT\nwrite /BOOTAA64.EFI /EFI/BOOT/BOOTAA64.EFI\nmkdir /loader\nmkdir /loader/entries\nwrite /cfg/loader.conf /loader/loader.conf\nwrite /cfg/rescue.conf /loader/entries/rescue.conf\nwrite /cfg/ubuntu.conf /loader/entries/ubuntu.conf\nwrite /vmlinuz /vmlinuz\nwrite /initramfs-rescue.gz /initramfs-rescue.gz\nquit\n' > debugfs.cmds

chroot /tmp/stage /usr/sbin/mke2fs -q -F -t ext4 -b 1024 -L ESP /tmp/esp.img 512M || { echo "FATAL mke2fs"; exit 1; }
chroot /tmp/stage /usr/sbin/debugfs -w -f /debugfs.cmds /tmp/esp.img 2>&1 | tail -4
chroot /tmp/stage /usr/sbin/debugfs -R "ls -l /" /tmp/esp.img 2>/dev/null | head -12

ls -la /tmp/esp.img
echo "=== writing ESP image to partition ==="
dd if=/tmp/esp.img of=/dev/block/by-name/userdata bs=4096 seek=256 2>&1 | tail -1
sync
echo "=== verify (magic at ESP start +1K = ext4 53ef):"
dd if=/dev/block/by-name/userdata bs=1 skip=1048576 count=64 2>/dev/null | xxd | head -2
dd if=/dev/block/by-name/userdata bs=1 skip=1049656 count=2 2>/dev/null | xxd
echo "DONE — ESP seeded. Now reboot into U-Boot (rescue will run)."
