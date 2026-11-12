#!/usr/bin/env python3
"""Build the ESP FAT32 image (raw, mount-free) with pyfatfs.

Contents: systemd-boot (BOOTAA64.EFI), vmlinuz, rescue installer entry
(+ its initramfs), and the final ubuntu entry.
"""
import shutil
import sys
from pathlib import Path

from pyfatfs.PyFatFS import PyFatFS
from pyfatfs.EightDotThree import EightDotThree

ROOT = Path(__file__).resolve().parent
IMG = ROOT / "flash" / "esp.img"
SIZE_MB = 512

# boot entries
LOADER_CONF = """timeout 3
default rescue.conf
console-mode keep
editor no
"""

RESCUE_CONF = """title Rescue installer (S10 Ubuntu)
linux /vmlinuz
initrd /initramfs-rescue.gz
options console=tty0 loglevel=7
"""

UBUNTU_CONF = """title Ubuntu 26.04 LTS (S10)
linux /vmlinuz
options root=PARTLABEL=ubuntu-root rootwait rw console=tty0 console=ttyGS0,115200n8 loglevel=4
"""


def main() -> int:
    src_vmlinuz = ROOT / "assets" / "vmlinuz"
    src_efi = ROOT / "assets" / "esp" / "EFI" / "BOOT" / "systemd-bootaa64.efi"
    src_initramfs = Path("/tmp/rescue-build/initramfs.gz")
    for f in (src_vmlinuz, src_efi, src_initramfs):
        if not f.exists():
            print(f"FATAL: missing {f}")
            return 1

    IMG.unlink(missing_ok=True)
    fs = PyFatFS.create(IMG, size=SIZE_MB * 1024 * 1024, volume_label="ESP")
    with fs.open("EFI/BOOT", "w", create_dir=True):
        pass
    fs.setcon(src_efi.read_bytes(), "/EFI/BOOT/BOOTAA64.EFI")
    fs.setcon(src_vmlinuz.read_bytes(), "/vmlinuz")
    fs.setcon(src_initramfs.read_bytes(), "/initramfs-rescue.gz")
    with fs.open("/loader", "w", create_dir=True):
        pass
    with fs.open("/loader/entries", "w", create_dir=True):
        pass
    fs.setcon(LOADER_CONF.encode(), "/loader/loader.conf")
    fs.setcon(RESCUE_CONF.encode(), "/loader/entries/rescue.conf")
    fs.setcon(UBUNTU_CONF.encode(), "/loader/entries/ubuntu.conf")
    fs.close()

    listing = PyFatFS(IMG).list("/")
    print("image contents:", [f.name for f in listing])
    print(f"OK: {IMG} ({IMG.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
