#!/bin/sh
# ============================================================================
# install-ubuntu.sh — run inside TWRP/LineageOS recovery (adb shell)
#
# Installs Ubuntu 26.04 (resolute) rootfs into the userdata partition using a
# GPT layout [ESP(fat32) | ubuntu-root(ext4)], replicating the pmOS/Nura boot
# design: S-Boot -> U-Boot(boot partition) -> EFI -> systemd-boot -> kernel.
#
# Expected files in /tmp (pushed via adb push):
#   ubuntu-base.tar.gz   Ubuntu 26.04 base rootfs tarball
#   debs/                dependency closure (systemd, udev, kmod, ssh...)
#   modules.tar.gz       kernel modules (lib/modules tree)
#   overlay/             rootfs config overlay (etc/, usr/local/sbin/)
#   esp/                 loader.conf + entries/ + EFI seed dirs
#
# Everything runs from a RAM staging copy so the same binaries that will live
# on the device do the partitioning/formatting (sfdisk, mke2fs, mkfs.vfat).
# ============================================================================
set -x

UD=/dev/block/by-name/userdata
[ -e "$UD" ] || { echo "FATAL: $UD not found"; exit 1; }
UDPATH=$(readlink -f "$UD")
echo "userdata block: $UDPATH"

# check pushed payload
for f in /tmp/ubuntu-base.tar.gz /tmp/modules.tar.gz /tmp/overlay /tmp/esp /tmp/debs; do
    [ -e "$f" ] || { echo "FATAL: missing $f (adb push it first)"; exit 1; }
done

# ----------------------------------------------------------------------------
# 1. RAM staging: extract ubuntu-base, unpack fdisk+dosfstools debs into it
# ----------------------------------------------------------------------------
rm -rf /tmp/stage /tmp/mnt /tmp/esp_mnt
mkdir -p /tmp/stage /tmp/mnt /tmp/esp_mnt
cd /tmp/stage
tar xzf /tmp/ubuntu-base.tar.gz
echo "base extracted: $(ls /tmp/stage | wc -l) entries"

mkdir -p /tmp/stage/debs
cp /tmp/debs/*.deb /tmp/stage/debs/
# bind pseudo-filesystems into the staging chroot
mount -t proc proc /tmp/stage/proc 2>/dev/null
mount -t sysfs sys /tmp/stage/sys 2>/dev/null
mount -o bind /dev /tmp/stage/dev 2>/dev/null

DEBIAN_FRONTEND=noninteractive chroot /tmp/stage /usr/bin/env \
    DEBIAN_FRONTEND=noninteractive \
    /usr/bin/dpkg --unpack --force-depends \
    /debs/fdisk*.deb /debs/libfdisk*.deb /debs/libsmartcols*.deb \
    /debs/dosfstools*.deb 2>&1 | tail -3
chroot /tmp/stage /sbin/ldconfig
echo "staging tools ready: $(chroot /tmp/stage /usr/bin/which sfdisk mkfs.vfat mke2fs)"

# ----------------------------------------------------------------------------
# 2. Partition userdata as a disk: GPT [esp 512MiB | ubuntu-root rest]
# ----------------------------------------------------------------------------
chroot /tmp/stage /sbin/wipefs -a "$UDPATH" 2>/dev/null
chroot /tmp/stage /usr/bin/sfdisk --force "$UDPATH" <<'PARTS'
label: gpt
name="esp", size=512MiB, type=uefi
name="ubuntu-root", type=linux
PARTS

# expose partitions via loop device (works regardless of nested-partition quirks)
LO=$(chroot /tmp/stage /usr/sbin/losetup -f --show "$UDPATH")
echo "loop device: $LO"
chroot /tmp/stage /usr/sbin/blockdev --rereadpt "$LO"
sleep 1
ls -la /dev/block/$(basename "$LO")* || ls -la ${LO}p1 ${LO}p2
P1="${LO}p1"
P2="${LO}p2"
[ -e "$P1" ] && [ -e "$P2" ] || { echo "FATAL: loop partitions missing"; exit 1; }

# ----------------------------------------------------------------------------
# 3. Filesystems
# ----------------------------------------------------------------------------
chroot /tmp/stage /sbin/mke2fs -q -t ext4 -b 4096 -L ubuntu-root -m 1 "$P2"
if chroot /tmp/stage /sbin/mkfs.vfat -F 32 -n ESP "$P1" 2>/dev/null; then
    echo "ESP formatted as fat32"
else
    echo "WARN: mkfs.vfat failed, ESP will be ext4 (U-Boot can read ext4)"
    chroot /tmp/stage /sbin/mke2fs -q -t ext4 -L ESP "$P1"
fi

# ----------------------------------------------------------------------------
# 4. Mount and populate rootfs
# ----------------------------------------------------------------------------
mount -t ext4 "$P2" /tmp/mnt
cd /tmp/mnt
tar xzf /tmp/ubuntu-base.tar.gz
mkdir -p /tmp/mnt/tmp/debs /tmp/mnt/boot/efi
cp /tmp/debs/*.deb /tmp/mnt/tmp/debs/

# kernel modules
mkdir -p /tmp/mnt/usr/lib
tar xzf /tmp/modules.tar.gz -C /tmp/mnt/usr/lib

# config overlay
cp -a /tmp/overlay/. /tmp/mnt/
# apt sources: fill in codename from the base's os-release
CODENAME=$(grep -E "^VERSION_CODENAME=" /tmp/mnt/usr/lib/os-release | cut -d= -f2)
sed -i "s/@CODENAME@/$CODENAME/g" /tmp/mnt/etc/apt/sources.list.d/ubuntu.sources
echo "codename: $CODENAME"

# ----------------------------------------------------------------------------
# 5. Install the init system + tooling from debs (dpkg unpack + configure)
# ----------------------------------------------------------------------------
# move pseudo-fs binds from stage to real rootfs chroot
mount -t proc proc /tmp/mnt/proc 2>/dev/null
mount -t sysfs sys /tmp/mnt/sys 2>/dev/null
mount -o bind /dev /tmp/mnt/dev 2>/dev/null

chroot /tmp/mnt /usr/bin/env DEBIAN_FRONTEND=noninteractive \
    /usr/bin/dpkg --unpack --force-depends /tmp/debs/*.deb 2>&1 | tail -5
chroot /tmp/mnt /sbin/ldconfig
chroot /tmp/mnt /usr/bin/env DEBIAN_FRONTEND=noninteractive \
    /usr/bin/dpkg --configure -a 2>&1 | tail -5
chroot /tmp/mnt /usr/bin/env DEBIAN_FRONTEND=noninteractive \
    /usr/bin/dpkg --configure -a 2>&1 | tail -5
echo "init sanity: $(ls -la /tmp/mnt/sbin/init)"

# ----------------------------------------------------------------------------
# 6. Users, enables, and final config
# ----------------------------------------------------------------------------
chroot /tmp/mnt /bin/bash -c '
printf "root:ubuntu\n" | chpasswd
id ubuntu >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo ubuntu
printf "ubuntu:ubuntu\n" | chpasswd
'

R=/tmp/mnt
mkdir -p $R/etc/systemd/system/multi-user.target.wants
W=$R/etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/usb-gadget.service   $W/usb-gadget.service
ln -sf /etc/systemd/system/firstboot.service    $W/firstboot.service
ln -sf /usr/lib/systemd/system/systemd-networkd.service $W/systemd-networkd.service
ln -sf /usr/lib/systemd/system/serial-getty@.service $R/etc/systemd/system/getty.target.wants/serial-getty@ttyGS0.service
ln -sf /usr/lib/systemd/system/getty@.service   $R/etc/systemd/system/getty.target.wants/getty@tty1.service
# suspend is broken on exynos9820 mainline — disable
ln -sf /dev/null $R/etc/systemd/system/sleep.target
ln -sf /dev/null $R/etc/systemd/system/suspend.target
ln -sf /dev/null $R/etc/systemd/system/hibernate.target

# ----------------------------------------------------------------------------
# 7. ESP: kernel + systemd-boot
# ----------------------------------------------------------------------------
if mount -t vfat "$P1" /tmp/esp_mnt 2>/dev/null; then
    echo "ESP mounted as vfat"
else
    mount -t ext4 "$P1" /tmp/esp_mnt && echo "ESP mounted as ext4"
fi
mkdir -p /tmp/esp_mnt/EFI/BOOT /tmp/esp_mnt/loader/entries
cp /tmp/esp/loader/loader.conf /tmp/esp_mnt/loader/
cp /tmp/esp/loader/entries/ubuntu-2604.conf /tmp/esp_mnt/loader/entries/
cp /tmp/esp/EFI/BOOT/BOOTAA64.EFI /tmp/esp_mnt/EFI/BOOT/BOOTAA64.EFI 2>/dev/null || \
    cp /tmp/esp/EFI/BOOT/systemd-bootaa64.efi /tmp/esp_mnt/EFI/BOOT/BOOTAA64.EFI
cp /tmp/esp/vmlinuz /tmp/esp_mnt/vmlinuz
ls -la /tmp/esp_mnt /tmp/esp_mnt/EFI/BOOT /tmp/esp_mnt/loader/entries

# ----------------------------------------------------------------------------
# 8. Wrap up
# ----------------------------------------------------------------------------
cd /tmp
sync
umount /tmp/esp_mnt
umount /tmp/mnt/proc /tmp/mnt/sys /tmp/mnt/dev 2>/dev/null
umount /tmp/mnt
chroot /tmp/stage /usr/sbin/losetup -d "$LO" 2>/dev/null
umount /tmp/stage/proc /tmp/stage/sys /tmp/stage/dev 2>/dev/null

echo "================================================================"
echo "ROOTFS DONE. Next: flash U-Boot to boot partition:"
echo "  adb pull /tmp/boot-stock-backup.img   (if not done yet!)"
echo "  dd if=/tmp/u-boot.img of=$UD../by-name/boot"
echo "  (or run: sh /tmp/flash-uboot.sh)"
echo "================================================================"
