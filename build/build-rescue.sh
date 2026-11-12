#!/bin/bash
# ============================================================================
# build-rescue.sh — assemble rescue-boot.img (mainline kernel + busybox init)
# and payload.tar.gz for the staging region. Run from build/.
# ============================================================================
set -e
cd "$(dirname "$0")"

APKS=/tmp/alpine-apks
WORK=/tmp/rescue-build
rm -rf "$WORK"
mkdir -p "$WORK"/{bin,lib,dev,proc,sys,tmp}

echo "== extract apks =="
mkdir -p "$WORK/x"
for a in busybox-static musl e2fsprogs e2fsprogs-libs libblkid libuuid libarchive; do
    tar xzf "$APKS/$a.apk" -C "$WORK/x"
done
cp "$WORK/x/bin/busybox.static" "$WORK/bin/busybox"
chmod 755 "$WORK/bin/busybox"
# mke2fs + its libraries (run via musl loader at boot)
cp "$WORK/x/sbin/mke2fs" "$WORK/bin/mke2fs"
chmod 755 "$WORK/bin/mke2fs"
cp "$WORK/x/lib/ld-musl-aarch64.so.1" "$WORK/lib/" 2>/dev/null || \
    cp "$WORK/x/lib/libc.musl-aarch64.so.1" "$WORK/lib/ld-musl-aarch64.so.1"
for f in "$WORK"/x/usr/lib/libcom_err.so* "$WORK"/x/usr/lib/libss.so* \
         "$WORK"/x/lib/libblkid.so* "$WORK"/x/lib/libuuid.so* \
         "$WORK"/x/usr/lib/libe2p.so* "$WORK"/x/usr/lib/libext2fs.so* \
         "$WORK"/x/lib/libe2p.so* "$WORK"/x/lib/libext2fs.so* \
         "$WORK"/x/usr/lib/libblkid.so* "$WORK"/x/usr/lib/libuuid.so* \
         "$WORK"/x/usr/lib/libarchive.so* "$WORK"/x/lib/libarchive.so* \
         "$WORK"/x/lib/libcom_err.so* "$WORK"/x/usr/lib/libcom_err.so*; do
    [ -e "$f" ] && cp "$f" "$WORK/lib/"
done
ls -la "$WORK/bin" "$WORK/lib"

echo "== init (substitute payload size) =="
SCRIPT_DIR="$(pwd)"
mkdir -p "$WORK/initramfs-src"
# payload built first so we know its size
echo "== payload.tar.gz =="
PAYLOAD=$WORK/payload
rm -rf "$PAYLOAD" && mkdir -p "$PAYLOAD"
cp flash/ubuntu-base.tar.gz flash/modules.tar.gz flash/u-boot.img "$PAYLOAD/"
cp -a assets/rootfs "$PAYLOAD/overlay"
cp -a assets/esp "$PAYLOAD/esp"
cp -a flash/debs "$PAYLOAD/debs"
cd "$PAYLOAD" && tar czf ../payload.tar.gz . && cd ..
BLOB="$WORK/payload.tar.gz"
BLOB_BYTES=$(stat -f %z "$BLOB")
BLOB_SECTORS=$(( (BLOB_BYTES + 4095) / 4096 ))
echo "payload.tar.gz: $BLOB_BYTES bytes = $BLOB_SECTORS staging sectors"

sed "s/@PAYLOAD_SECTORS@/$BLOB_SECTORS/" "$SCRIPT_DIR/rescue/init" > "$WORK/init"
chmod 755 "$WORK/init"

echo "== initramfs cpio =="
cd "$WORK"
# /init at root of cpio; bin/lib beside it
cp init "$WORK/init.real"
# cpio needs ./init; build file list
{ echo "init"; echo "bin"; find bin -type f -o -type l; echo "lib"; find lib -type f; } > /tmp/filelist
cat /tmp/filelist | cpio -o -H newc -C 4096 2>/dev/null | gzip -1 > initramfs.gz
ls -la initramfs.gz

echo "== boot image =="
python3 "$SCRIPT_DIR/assets/mkbootimg_lite.py" --kernel "$SCRIPT_DIR/kernel/x/boot/vmlinuz" --ramdisk "$WORK/initramfs.gz" --out "$SCRIPT_DIR/flash/rescue-boot.img"
ls -la "$SCRIPT_DIR/flash/rescue-boot.img"

echo "== verify blob sector count for staging =="
echo "dd payload.tar.gz to sda31 at seek=28959744 sectors (bs=4096)"
echo "ALL DONE: flash/rescue-boot.img + staging blob at $WORK/payload.tar.gz"
