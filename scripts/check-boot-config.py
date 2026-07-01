#!/usr/bin/env python3
"""Keep the kernel and image builder initramfs limits in sync."""

from __future__ import annotations

import hashlib
import re
import runpy
import sys
from pathlib import Path


def parse_kernel_limit(header: Path) -> int:
    text = header.read_text(encoding="utf-8")
    match = re.search(
        r"^#define\s+TUNIX_INITRAMFS_MAX_BYTES\s+"
        r"\((\d+)ULL\s*\*\s*1024ULL\s*\*\s*1024ULL\)\s*$",
        text,
        re.MULTILINE,
    )
    if match is None:
        raise SystemExit(f"cannot parse TUNIX_INITRAMFS_MAX_BYTES from {header}")
    return int(match.group(1)) * 1024 * 1024


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit(
            f"usage: {sys.argv[0]} BOOT_MANIFEST_HEADER BUILD_IMAGE_PY STAMP"
        )

    header = Path(sys.argv[1])
    build_image = Path(sys.argv[2])
    stamp = Path(sys.argv[3])

    kernel_limit = parse_kernel_limit(header)
    image_namespace = runpy.run_path(str(build_image))
    image_limit = image_namespace.get("MAX_INITRAMFS_BYTES")
    if not isinstance(image_limit, int):
        raise SystemExit(f"MAX_INITRAMFS_BYTES is missing from {build_image}")
    if kernel_limit != image_limit:
        raise SystemExit(
            "initramfs limit mismatch: "
            f"kernel={kernel_limit} bytes image-builder={image_limit} bytes"
        )

    digest = hashlib.sha256()
    digest.update(header.read_bytes())
    digest.update(build_image.read_bytes())
    digest.update(str(kernel_limit).encode("ascii"))
    content = f"{digest.hexdigest()} {kernel_limit}\n"

    stamp.parent.mkdir(parents=True, exist_ok=True)
    if not stamp.exists() or stamp.read_text(encoding="ascii") != content:
        temporary = stamp.with_suffix(stamp.suffix + ".tmp")
        temporary.write_text(content, encoding="ascii")
        temporary.replace(stamp)

    print(f"boot config: initramfs limit {kernel_limit // (1024 * 1024)} MiB")


if __name__ == "__main__":
    main()
