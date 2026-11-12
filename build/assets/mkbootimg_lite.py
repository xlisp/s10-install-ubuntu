#!/usr/bin/env python3
"""Minimal Android boot image (header v0) packer, tuned for exynos9820 S-Boot.

Params match the stock/LineageOS images of SM-G973N (beyond1lte):
  page_size=2048, kernel_addr=0x10008000, tags_addr=0x10000100
"""
import argparse
import struct
import sys

PAGE_SIZE = 2048
KERNEL_ADDR = 0x10008000
TAGS_ADDR = 0x10000100
HEADER_V0_SIZE = 2 * PAGE_SIZE  # header + one page padding


def pad(data: bytes, size: int = PAGE_SIZE) -> bytes:
    rem = len(data) % size
    return data + b"\x00" * ((size - rem) % size)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--kernel", required=True)
    ap.add_argument("--ramdisk", help="gzipped ramdisk cpio (optional)")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    kernel = open(args.kernel, "rb").read()
    ramdisk = b""
    if args.ramdisk:
        ramdisk = open(args.ramdisk, "rb").read()

    # struct boot_img_hdr_v0:
    #   magic[8], kernel_size, kernel_addr, ramdisk_size, ramdisk_addr,
    #   second_size, second_addr, tags_addr, page_size, dt_size(=0), unused[8],
    #   name[16], cmdline[512], id[8]
    RAMDISK_ADDR = 0x11000000  # from real beyond1lte boot image
    header = b"ANDROID!"
    header += struct.pack("<I", len(kernel))
    header += struct.pack("<I", KERNEL_ADDR)
    header += struct.pack("<I", len(ramdisk))
    header += struct.pack("<I", RAMDISK_ADDR)
    header += struct.pack("<I", 0)  # second_size
    header += struct.pack("<I", 0)  # second_addr
    header += struct.pack("<I", TAGS_ADDR)
    header += struct.pack("<I", PAGE_SIZE)
    header += struct.pack("<I", 0)  # dt_size
    header += b"\x00" * 8  # unused[2]
    header += b"\x00" * 16  # name
    header += b"\x00" * 512  # cmdline
    header += b"\x00" * 8  # id
    assert len(header) == 8 + 9 * 4 + 8 + 16 + 512 + 8, len(header)

    img = pad(header, PAGE_SIZE) + pad(kernel)
    if ramdisk:
        img += pad(ramdisk)
    with open(args.out, "wb") as f:
        f.write(img)
    print(
        f"wrote {args.out}: kernel {len(kernel)}, ramdisk {len(ramdisk)}, total {len(img)} bytes"
    )


if __name__ == "__main__":
    sys.exit(main())
