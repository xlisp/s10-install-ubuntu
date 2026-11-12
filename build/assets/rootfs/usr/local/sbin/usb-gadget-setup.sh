#!/bin/sh
# Configure USB configfs gadget: NCM (network for macOS/Linux) + ACM (serial console)
set -e

CONFIGFS=/sys/kernel/config
GADGET="$CONFIGFS/usb_gadget/g1"

mount -t configfs none "$CONFIGFS" 2>/dev/null || true

if [ -e "$GADGET/UDC" ] && [ -s "$GADGET/UDC" ]; then
    echo "gadget already bound to UDC $(cat "$GADGET/UDC")"
    exit 0
fi

mkdir -p "$GADGET"
echo 0x1d6b  > "$GADGET/idVendor"    # Linux Foundation
echo 0x0104  > "$GADGET/idProduct"   # Multifunction Composite Gadget
echo 0x0100  > "$GADGET/bcdDevice"
echo 0x0300  > "$GADGET/bcdUSB"
echo 0x0080  > "$GADGET/bmAttributes"

mkdir -p "$GADGET/strings/0x409"
echo "s10-linux"               > "$GADGET/strings/0x409/serialnumber"
echo "Samsung S10 (Ubuntu)"    > "$GADGET/strings/0x409/product"
echo "S10 Linux Project"       > "$GADGET/strings/0x409/manufacturer"

mkdir -p "$GADGET/configs/c.1/strings/0x409"
echo "NCM+ACM" > "$GADGET/configs/c.1/strings/0x409/configuration"
echo 250       > "$GADGET/configs/c.1/MaxPower"

mkdir -p "$GADGET/functions/ncm.usb0"
mkdir -p "$GADGET/functions/acm.usb0"

# Stable MACs so macOS does not create a new interface each boot
echo 9a:44:f2:10:20:30 > "$GADGET/functions/ncm.usb0/host_addr"
echo 9a:44:f2:10:20:31 > "$GADGET/functions/ncm.usb0/dev_addr"

ln -sf "$GADGET/functions/ncm.usb0" "$GADGET/configs/c.1/f1"
ln -sf "$GADGET/functions/acm.usb0" "$GADGET/configs/c.1/f2"

UDC=$(ls /sys/class/udc 2>/dev/null | head -n 1)
if [ -z "$UDC" ]; then
    echo "ERROR: no UDC available" >&2
    exit 1
fi
echo "$UDC" > "$GADGET/UDC"
echo "gadget bound to $UDC"
