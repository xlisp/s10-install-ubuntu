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
#   esp/                 vmlinuz + EFI/BOOT + loader.conf + entries/
#
# NOTE: recovery /dev has no by-name links, no loop nodes and bind mounts are
# unreliable across adb sessions — everything needed is created with mknod.
# ============================================================================
set -x

# chroot helper: recovery may or may not ship chroot
if command -v chroot >/dev/null 2>&1; then
    CHROOT="chroot"
elif command -v busybox >/dev/null 2>&1 && busybox chroot true 2>/dev/null; then
    CHROOT="busybox chroot"
elif [ -x /sbin/busybox ]; then
    CHROOT="/sbin/busybox chroot"
else
    echo "FATAL: no chroot available in recovery"; exit 1
fi
echo "using CHROOT=$CHROOT"

mknod_from_sysfs() {  # $1=node path, $2=sysfs block name
    mm=$(cat /sys/class/block/$2/dev 2>/dev/null) || return 1
    major=$(printf '%s' "$mm" | cut -d: -f1)
    minor=$(printf '%s' "$mm" | cut -d: -f2)
    mkdir -p "$(dirname "$1")"
    [ -e "$1" ] || mknod "$1" b "$major" "$minor"
}

UD=/dev/block/by-name/userdata
mkdir -p /dev/block/by-name
mknod_from_sysfs /dev/block/sda31 sda31 || { echo "FATAL: sda31 missing from sysfs"; exit 1; }
ln -sf /dev/block/sda31 "$UD"
UDPATH=/dev/block/sda31
echo "userdata block: $UDPATH ($(cat /sys/class/block/sda31/dev))"

# loop nodes for recovery /dev
for n in null zero random urandom; do
    case $n in
        null)   [ -e /dev/null ]    || mknod /dev/null c 1 3 ;;
        zero)   [ -e /dev/zero ]    || mknod /dev/zero c 1 5 ;;
        random) [ -e /dev/random ]  || mknod /dev/random c 1 8 ;;
        urandom) [ -e /dev/urandom ] || mknod /dev/urandom c 1 9 ;;
    esac
done
[ -e /dev/loop-control ] || mknod /dev/loop-control c 10 237
# loop driver max_part=7 -> each device reserves 8 minors (loopN = 7:N*8)
i=0
while [ $i -le 15 ]; do
    [ -e /dev/loop$i ] || mknod /dev/loop$i b 7 $((i * 8))
    i=$((i + 1))
done

# check pushed payload
for f in /tmp/ubuntu-base.tar.gz /tmp/modules.tar.gz /tmp/overlay /tmp/esp /tmp/debs; do
    [ -e "$f" ] || { echo "FATAL: missing $f (adb push it first)"; exit 1; }
done

# ----------------------------------------------------------------------------
# 1. RAM staging: extract ubuntu-base, unpack fdisk+dosfstools debs into it
# ----------------------------------------------------------------------------
rm -rf /tmp/stage /tmp/mnt /tmp/esp_mnt
mkdir -p /tmp/stage/dev/block /tmp/mnt /tmp/esp_mnt
cd /tmp/stage
tar xzf /tmp/ubuntu-base.tar.gz
echo "base extracted: $(ls /tmp/stage | wc -l) entries"

mkdir -p /tmp/stage/debs
cp /tmp/debs/*.deb /tmp/stage/debs/
# chroot device nodes: only what sfdisk/mke2fs/losetup need
mknod /tmp/stage/dev/block/sda31 b 259 15 2>/dev/null
mknod /tmp/stage/dev/loop-control c 10 237 2>/dev/null
i=0
while [ $i -le 15 ]; do
    mknod /tmp/stage/dev/loop$i b 7 $((i * 8)) 2>/dev/null
    i=$((i + 1))
done

$CHROOT /tmp/stage /bin/sh -c \
    'PATH=/usr/sbin:/usr/bin:/sbin:/bin DEBIAN_FRONTEND=noninteractive \
     dpkg --unpack --force-depends /debs/libsmartcols*.deb /debs/libreadline8t64*.deb /debs/libfdisk*.deb /debs/fdisk*.deb /debs/dosfstools*.deb' 2>&1 | tail -3
$CHROOT /tmp/stage /usr/sbin/ldconfig
echo "staging tools ready:"
$CHROOT /tmp/stage /bin/sh -c 'export PATH=/usr/sbin:/usr/bin:/sbin:/bin; which sfdisk mkfs.vfat mke2fs losetup blockdev wipefs'

# ----------------------------------------------------------------------------
# 2. Partition userdata as a disk: GPT [esp 512MiB | ubuntu-root rest]
# ----------------------------------------------------------------------------
$CHROOT /tmp/stage /usr/sbin/wipefs -a "$UDPATH" 2>/dev/null
printf 'label: gpt\nname="esp", size=512MiB, type=uefi\nname="ubuntu-root", type=linux\n' > /tmp/stage/parts.sfdisk
$CHROOT /tmp/stage /bin/sh -c 'export PATH=/usr/sbin:/usr/bin:/sbin:/bin; sfdisk --force /dev/block/sda31 < /parts.sfdisk' || { echo "FATAL: sfdisk failed"; exit 1; }

# Map the two partitions as standalone loop devices via byte offsets —
# the recovery kernel has no loop partition-scan support (max_part=0).
# Parse start/sector counts from the sfdisk table we just wrote.
LSIZE=$(cat /sys/class/block/sda/queue/logical_block_size 2>/dev/null || echo 4096)
echo "logical block size: $LSIZE"
TABLE=$($CHROOT /tmp/stage /usr/sbin/sfdisk -l -o Device,Start,Sectors "$UDPATH" 2>/dev/null)
echo "$TABLE"
set -- $(printf '%s\n' "$TABLE" | grep 'sda31p1 ')
P1START=$2; P1SEC=$3
set -- $(printf '%s\n' "$TABLE" | grep 'sda31p2 ')
P2START=$2; P2SEC=$3
[ -n "$P1START" ] && [ -n "$P2START" ] || { echo "FATAL: cannot parse partition table"; exit 1; }

# detach ALL stale loop attachments from previous runs (paths may be stale)
$CHROOT /tmp/stage /bin/sh -c 'export PATH=/usr/sbin:/usr/bin:/sbin:/bin
    for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do losetup -d /dev/loop$i 2>/dev/null; done
    losetup -a 2>/dev/null
    true'

MAPS=$($CHROOT /tmp/stage /bin/sh -c '
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin
    L1=$(losetup -f --show -o $(($1 * 4096)) --sizelimit $(($2 * 4096)) /dev/block/sda31) || exit 1
    dd if=/dev/zero of="$L1" bs=4096 count=8 2>/dev/null || { echo "verify-fail $L1"; losetup -d "$L1" 2>/dev/null; exit 2; }
    L2=$(losetup -f --show -o $(($3 * 4096)) --sizelimit $(($4 * 4096)) /dev/block/sda31) || { losetup -d "$L1" 2>/dev/null; exit 1; }
    dd if=/dev/zero of="$L2" bs=4096 count=8 2>/dev/null || { echo "verify-fail $L2"; losetup -d "$L1" "$L2" 2>/dev/null; exit 2; }
    echo "$L1 $L2"
' sh "$P1START" "$P1SEC" "$P2START" "$P2SEC")
P1=${MAPS%% *}
P2=${MAPS##* }
echo "esp loop:  $P1 (offset $P1START, $P1SEC sectors)"
echo "root loop: $P2 (offset $P2START, $P2SEC sectors)"
ls -la "$P1" "$P2"
[ -e "$P1" ] && [ -e "$P2" ] || { echo "FATAL: loop maps missing"; exit 1; }

# ----------------------------------------------------------------------------
# 3. Filesystems
# ----------------------------------------------------------------------------
$CHROOT /tmp/stage /usr/sbin/mke2fs -q -t ext4 -b 4096 -L ubuntu-root -m 1 "$P2"
# ESP as ext4: recovery mount of vfat is broken; U-Boot reads ext4 natively
$CHROOT /tmp/stage /usr/sbin/mke2fs -q -t ext4 -b 4096 -L ESP "$P1"
echo "both filesystems created (ext4)"

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
mkdir -p /tmp/mnt/proc /tmp/mnt/sys
mount -t proc proc /tmp/mnt/proc
mount -t sysfs sys /tmp/mnt/sys
mount -o bind /dev /tmp/mnt/dev

$CHROOT /tmp/mnt /bin/sh -c 'PATH=/usr/sbin:/usr/bin:/sbin:/bin DEBIAN_FRONTEND=noninteractive dpkg --unpack --force-depends /tmp/debs/*.deb' > /tmp/dpkg-unpack.log 2>&1
tail -3 /tmp/dpkg-unpack.log
$CHROOT /tmp/mnt /usr/sbin/ldconfig
$CHROOT /tmp/mnt /bin/sh -c 'PATH=/usr/sbin:/usr/bin:/sbin:/bin DEBIAN_FRONTEND=noninteractive dpkg --configure -a' > /tmp/dpkg-conf1.log 2>&1
tail -3 /tmp/dpkg-conf1.log
$CHROOT /tmp/mnt /bin/sh -c 'PATH=/usr/sbin:/usr/bin:/sbin:/bin DEBIAN_FRONTEND=noninteractive dpkg --configure -a' > /tmp/dpkg-conf2.log 2>&1
tail -3 /tmp/dpkg-conf2.log
grep -c "^Setting up" /tmp/dpkg-conf1.log /tmp/dpkg-conf2.log
echo "init sanity: $(ls -la /tmp/mnt/usr/sbin/init 2>/dev/null)"

# ----------------------------------------------------------------------------
# 6. Users, enables, and final config
# ----------------------------------------------------------------------------
$CHROOT /tmp/mnt /bin/bash -c '
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
printf "root:ubuntu\n" | chpasswd
id ubuntu >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo ubuntu
printf "ubuntu:ubuntu\n" | chpasswd
'

R=/tmp/mnt
mkdir -p $R/etc/systemd/system/multi-user.target.wants $R/etc/systemd/system/getty.target.wants
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
mount -t ext4 "$P1" /tmp/esp_mnt || { echo "FATAL: cannot mount ESP"; exit 1; }
echo "ESP mounted as ext4"
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
$CHROOT /tmp/stage /usr/sbin/losetup -d "$P1" "$P2" 2>/dev/null

echo "================================================================"
echo "ROOTFS DONE. Next: flash U-Boot to boot partition:"
echo "  adb pull /tmp/boot-stock-backup.img   (if not done yet!)"
echo "  (or run: sh /tmp/flash-uboot.sh)"
echo "================================================================"
