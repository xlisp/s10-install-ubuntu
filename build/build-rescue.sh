#!/bin/bash
# ============================================================================
# build-rescue.sh — assemble:
#   - rescue initramfs (busybox + alpine mke2fs + install script)
#   - payload.tar.gz (staged into userdata tail by recovery dd)
# The ESP is created by the rescue itself (ext4) from payload/esp/.
# The BOOT partition gets U-Boot (flash/u-boot.img), not this image.
# ============================================================================
set -e
cd "$(dirname "$0")"
SCRIPT_DIR="$(pwd)"
APKS=/tmp/alpine-apks
WORK=/tmp/rescue-build
STAGING_SECTORS=260000   # payload budget: 260000 * 4096 ≈ 1.016 GiB (region = 262144 sectors)

rm -rf "$WORK"
mkdir -p "$WORK"/{bin,lib,dev,proc,sys,tmp,x}

echo "== extract apks =="
for a in busybox-static musl e2fsprogs e2fsprogs-libs libblkid libuuid libarchive; do
    tar xzf "$APKS/$a.apk" -C "$WORK/x"
done
cp "$WORK/x/bin/busybox.static" "$WORK/bin/busybox"
cp "$WORK/x/sbin/mke2fs" "$WORK/bin/mke2fs"
chmod 755 "$WORK/bin/busybox" "$WORK/bin/mke2fs"
cp "$WORK/x/lib/ld-musl-aarch64.so.1" "$WORK/lib/" 2>/dev/null || \
    cp "$WORK/x/lib/libc.musl-aarch64.so.1" "$WORK/lib/ld-musl-aarch64.so.1"
for f in "$WORK/x/lib/libcom_err.so"* "$WORK/x/usr/lib/libcom_err.so"* \
         "$WORK/x/lib/libss.so"* "$WORK/x/usr/lib/libss.so"* \
         "$WORK/x/lib/libe2p.so"* "$WORK/x/usr/lib/libe2p.so"* \
         "$WORK/x/lib/libext2fs.so"* "$WORK/x/usr/lib/libext2fs.so"* \
         "$WORK/x/lib/libblkid.so"* "$WORK/x/usr/lib/libblkid.so"* \
         "$WORK/x/lib/libuuid.so"* "$WORK/x/usr/lib/libuuid.so"* \
         "$WORK/x/lib/libarchive.so"* "$WORK/x/usr/lib/libarchive.so*"; do
    [ -e "$f" ] && cp "$f" "$WORK/lib/"
done
ls "$WORK/bin" "$WORK/lib" | head -20

echo "== init + initramfs =="
sed "s/@PAYLOAD_SECTORS@/$STAGING_SECTORS/" "$SCRIPT_DIR/rescue/init" > "$WORK/init"
chmod 755 "$WORK/init"
cd "$WORK"
{ echo "init"; find bin lib -type f; } | cpio -o -H newc -C 4096 2>/dev/null | gzip -1 > initramfs.gz
ls -la initramfs.gz

echo "== payload.tar.gz =="
PAYLOAD="$WORK/payload"
rm -rf "$PAYLOAD" && mkdir -p "$PAYLOAD"
cp "$SCRIPT_DIR/flash/ubuntu-base.tar.gz" "$SCRIPT_DIR/flash/modules.tar.gz" "$SCRIPT_DIR/flash/u-boot.img" "$PAYLOAD/"
cp -a "$SCRIPT_DIR/assets/rootfs" "$PAYLOAD/overlay"
cp -a "$SCRIPT_DIR/assets/esp" "$PAYLOAD/esp"
cp -a "$SCRIPT_DIR/flash/debs" "$PAYLOAD/debs"
cp initramfs.gz "$PAYLOAD/esp/initramfs-rescue.gz"
cd "$PAYLOAD"
tar czf ../payload.tar.gz .
BLOB_BYTES=$(stat -f %z ../payload.tar.gz)
BLOB_SECTORS=$(( (BLOB_BYTES + 4095) / 4096 ))
echo "payload.tar.gz: $BLOB_BYTES bytes = $BLOB_SECTORS staging sectors (budget $STAGING_SECTORS)"
[ "$BLOB_SECTORS" -le "$STAGING_SECTORS" ] || { echo "FATAL: payload exceeds staging budget"; exit 1; }

cp ../payload.tar.gz "$SCRIPT_DIR/flash/staging-payload.tar.gz"
echo "staged blob: $SCRIPT_DIR/flash/staging-payload.tar.gz"
echo "DONE"
