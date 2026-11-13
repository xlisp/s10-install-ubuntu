#!/bin/sh
# ============================================================================
# FLASH-ME.sh — 在 TWRP 里运行（adb shell sh /tmp/pkg/FLASH-ME.sh）
# 一次完成：
#   1. U-Boot(大字体+blkmap x8修复)  -> boot 分区
#   2. payload.tar.gz（rootfs源+debs+内核+救援initramfs）-> userdata 尾部暂存区
#   3. ESP 分区：chroot mke2fs+debugfs 构建 ext4 引导镜像（systemd-boot +
#      extlinux 双引导，rescue 默认）并写入
# 完成后自动重启：U-Boot -> rescue 安装器（mainline 内核）-> 装 Ubuntu ->
# 切默认启动项 -> 重启进 Ubuntu（纯终端，getty+串口+SSH 登录）
#
# 本脚本与它引用的文件必须在同一目录（/tmp/pkg）。
# ============================================================================
set -x
P=/tmp/pkg

UD=/dev/block/by-name/userdata
BOOT=/dev/block/by-name/boot
[ -e "$UD" ] && [ -e "$BOOT" ] || { echo "FATAL: by-name nodes missing"; exit 1; }

for f in u-boot.img staging-payload.tar.gz ubuntu-base.tar.gz vmlinuz \
         BOOTAA64.EFI initramfs-rescue.gz; do
    [ -e "$P/$f" ] || { echo "FATAL: missing $P/$f"; exit 1; }
done

# ---------- 0. nodes ----------
mknod /dev/block/sda31 b 259 15 2>/dev/null
mknod /dev/zero c 1 5 2>/dev/null
mknod /dev/null c 1 3 2>/dev/null
mknod /dev/random c 1 8 2>/dev/null
mknod /dev/urandom c 1 9 2>/dev/null

# ---------- 1. U-Boot -> boot ----------
dd if=$P/u-boot.img of=$BOOT bs=4096 conv=fsync 2>&1 | tail -1
sync
echo "### U-Boot written to boot"

# ---------- 2. payload -> staging (userdata tail, sector 28959744 @4096) ------
dd if=$P/staging-payload.tar.gz of=$UD bs=4096 seek=28959744 2>&1 | tail -1
sync
echo "### payload staged (verify gzip magic, expect 1f8b):"
dd if=$UD bs=4096 skip=28959744 count=1 2>/dev/null | head -c 2 | xxd

# ---------- 3. ESP image build (chroot mke2fs + debugfs on RAM file) ----------
rm -rf /tmp/stage
mkdir -p /tmp/stage/dev/block
cd /tmp/stage || exit 1
tar xzf $P/ubuntu-base.tar.gz
mknod dev/null c 1 3 2>/dev/null
mknod dev/zero c 1 5 2>/dev/null
mknod dev/random c 1 8 2>/dev/null
mknod dev/urandom c 1 9 2>/dev/null
mknod dev/block/sda31 b 259 15 2>/dev/null
cp $P/BOOTAA64.EFI $P/vmlinuz $P/initramfs-rescue.gz $P/exynos9820-beyond1lte.dtb .
printf 'timeout 3\ndefault rescue.conf\nconsole-mode keep\neditor no\n' > cfg-loader.conf
printf 'title Rescue installer (S10 Ubuntu)\nlinux /vmlinuz\ninitrd /initramfs-rescue.gz\noptions console=tty0 loglevel=8 panic=30\n' > cfg-rescue.conf
printf 'title Ubuntu 26.04 LTS (S10)\nlinux /vmlinuz\noptions root=PARTLABEL=ubuntu-root rootwait rw console=tty0 console=ttyGS0,115200n8 loglevel=4\n' > cfg-ubuntu.conf
printf 'default rescue\nmenu title S10 rescue\ntimeout 0\n\nlabel rescue\n\tmenu label Rescue installer\n\tlinux /vmlinuz\n\tinitrd /initramfs-rescue.gz\n\tdtb /exynos9820-beyond1lte.dtb\n\tappend console=tty0 loglevel=8 panic=30\n\nlabel ubuntu\n\tmenu label Ubuntu 26.04\n\tlinux /vmlinuz\n\tdtb /exynos9820-beyond1lte.dtb\n\tappend root=PARTLABEL=ubuntu-root rootwait rw console=tty0 console=ttyGS0,115200n8 loglevel=4\n' > cfg-extlinux.conf
printf 'mkdir /EFI\nmkdir /EFI/BOOT\nwrite /BOOTAA64.EFI /EFI/BOOT/BOOTAA64.EFI\nmkdir /loader\nmkdir /loader/entries\nwrite /cfg-loader.conf /loader/loader.conf\nwrite /cfg-rescue.conf /loader/entries/rescue.conf\nwrite /cfg-ubuntu.conf /loader/entries/ubuntu.conf\nwrite /vmlinuz /vmlinuz\nwrite /initramfs-rescue.gz /initramfs-rescue.gz\nwrite /exynos9820-beyond1lte.dtb /exynos9820-beyond1lte.dtb\nmkdir /extlinux\nwrite /cfg-extlinux.conf /extlinux/extlinux.conf\nquit\n' > debugfs.cmds

chroot /tmp/stage /usr/sbin/mke2fs -q -F -t ext4 -b 1024 -L ESP /tmp/esp.img 512M \
    || { echo "FATAL: mke2fs ESP"; exit 1; }
chroot /tmp/stage /usr/sbin/debugfs -w -f /debugfs.cmds /tmp/esp.img 2>&1 | tail -4
chroot /tmp/stage /usr/sbin/debugfs -R "ls -l /" /tmp/esp.img 2>/dev/null | head -14

dd if=/tmp/stage/tmp/esp.img of=$UD bs=4096 seek=256 2>&1 | tail -1
sync

# ---------- 4. verify ----------
echo "=== GPT (EFI PART):"
dd if=$UD bs=1 skip=4096 count=8 2>/dev/null | xxd
echo "=== ESP ext4 magic (53ef):"
dd if=$UD bs=1 skip=1049656 count=2 2>/dev/null | xxd
echo "=== staging gzip (1f8b):"
dd if=$UD bs=4096 skip=28959744 count=1 2>/dev/null | head -c 2 | xxd
echo "=== boot ANDROID header:"
dd if=$BOOT bs=1 count=8 2>/dev/null | xxd

rm -rf /tmp/stage
echo "==================================================================="
echo " ALL WRITTEN. Rebooting — rescue installer runs automatically."
echo " After it completes it reboots again into Ubuntu (terminal login:"
echo " ubuntu/ubuntu or root/ubuntu on tty1, serial ttyGS0, or SSH over"
echo " the USB NCM network 172.16.42.1 once configured)."
echo "==================================================================="
sleep 5
reboot
