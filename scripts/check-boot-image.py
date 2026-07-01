#!/usr/bin/env python3
"""Verify that the disk manifest describes the initramfs actually embedded."""

from __future__ import annotations

import math
import struct
import sys
from pathlib import Path

SECTOR_SIZE = 512
MANIFEST_LBA = 64
MANIFEST_MAGIC = 0x4D414E49
MANIFEST_VERSION = 3
MANIFEST_FORMAT = "<IHHQIQIQQIQII"


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(f"usage: {sys.argv[0]} IMAGE INITRAMFS")

    image_path = Path(sys.argv[1])
    initramfs_path = Path(sys.argv[2])
    image = image_path.read_bytes()
    initramfs_size = initramfs_path.stat().st_size

    offset = MANIFEST_LBA * SECTOR_SIZE
    packed_size = struct.calcsize(MANIFEST_FORMAT)
    if len(image) < offset + packed_size:
        raise SystemExit("disk image is too small to contain the boot manifest")

    fields = struct.unpack_from(MANIFEST_FORMAT, image, offset)
    (
        magic,
        version,
        manifest_size,
        _stage2_lba,
        _stage2_sectors,
        _kernel_lba,
        _kernel_sectors,
        _kernel_size,
        initramfs_lba,
        initramfs_sectors,
        manifest_initramfs_size,
        _kernel_crc,
        _initramfs_crc,
    ) = fields

    if magic != MANIFEST_MAGIC or version != MANIFEST_VERSION:
        raise SystemExit("disk image contains an invalid boot manifest")
    if manifest_size != packed_size:
        raise SystemExit(
            f"boot manifest size mismatch: image={manifest_size} expected={packed_size}"
        )
    if manifest_initramfs_size != initramfs_size:
        raise SystemExit(
            "boot manifest initramfs size mismatch: "
            f"image={manifest_initramfs_size} file={initramfs_size}"
        )

    expected_sectors = math.ceil(initramfs_size / SECTOR_SIZE)
    if initramfs_sectors != expected_sectors:
        raise SystemExit(
            "boot manifest initramfs sector mismatch: "
            f"image={initramfs_sectors} expected={expected_sectors}"
        )

    end = initramfs_lba * SECTOR_SIZE + initramfs_size
    if end > len(image):
        raise SystemExit("initramfs extends beyond the end of the disk image")

    print(
        "boot image: manifest/initramfs size verified "
        f"({initramfs_size} bytes, {initramfs_sectors} sectors)"
    )


if __name__ == "__main__":
    main()
