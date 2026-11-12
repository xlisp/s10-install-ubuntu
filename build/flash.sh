#!/bin/bash
# ============================================================================
# flash.sh — mac-side driver: recovery via heimdall, payload push, install
# Run from build/:  ./flash.sh
# Requires: phone in Android with USB debugging authorized (start), cable ok.
# ============================================================================
set -e
cd "$(dirname "$0")"
HEIMDALL=Heimdall/build/bin/heimdall
ADB="adb -s R39M307GLZP"

echo "== 1. Reboot phone to Download mode =="
read -rp "Press ENTER when ready (data will NOT be touched yet)..." 
$ADB reboot download
sleep 15
$HEIMDALL detect || true

echo "== 2. Flash LineageOS recovery (heimdall) =="
$HEIMDALL flash --RECOVERY flash/recovery.img --no-reboot
echo "Recovery flashed. Now boot it:"
echo "  hold Power+VolDown ~7s to leave download mode,"
echo "  then IMMEDIATELY hold VolUp+Bixby until recovery boots."
read -rp "Press ENTER once recovery is booted and 'adb devices' shows recovery..."

$ADB devices

echo "== 3. Backup stock boot partition =="
$ADB shell "dd if=/dev/block/by-name/boot of=/tmp/boot-stock-backup.img bs=4096" 
$ADB pull /tmp/boot-stock-backup.img flash/boot-stock-backup.img
ls -la flash/boot-stock-backup.img

echo "== 4. Push payload =="
$ADB push flash/ubuntu-base.tar.gz /tmp/
$ADB push flash/modules.tar.gz /tmp/
$ADB push flash/u-boot.img /tmp/
$ADB shell mkdir -p /tmp/debs /tmp/overlay /tmp/esp
$ADB push flash/debs/*.deb /tmp/debs/
$ADB push assets/rootfs/. /tmp/overlay/
$ADB push assets/esp/. /tmp/esp/
$ADB push flash/install-ubuntu.sh flash/flash-uboot.sh /tmp/
$ADB shell chmod +x /tmp/install-ubuntu.sh /tmp/flash-uboot.sh

echo "== 5. Run rootfs installer on device =="
$ADB shell sh /tmp/install-ubuntu.sh

echo "== 6. Flash U-Boot to boot partition =="
$ADB shell sh /tmp/flash-uboot.sh

echo "== 7. Reboot into Ubuntu =="
$ADB reboot
echo "Done. Watch serial console / USB network. See README.md"
