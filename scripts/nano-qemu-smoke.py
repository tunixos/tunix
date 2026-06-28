#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import select
import subprocess
import time
from pathlib import Path


def read_until(process: subprocess.Popen[bytes], needle: bytes, timeout: float) -> bytes:
    if process.stdout is None:
        raise RuntimeError("QEMU stdout is unavailable")
    fd = process.stdout.fileno()
    deadline = time.monotonic() + timeout
    output = bytearray()
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"QEMU exited early with status {process.returncode}: {output[-2000:]!r}")
        ready, _, _ = select.select([fd], [], [], 0.1)
        if not ready:
            continue
        data = os.read(fd, 65536)
        if not data:
            continue
        output.extend(data)
        if needle in output:
            return bytes(output)
    raise RuntimeError(f"timeout waiting for {needle!r}; tail={output[-2000:]!r}")


def run_once(qemu: str, image: Path, iteration: int) -> None:
    marker = f"TUNIX_NANO_{iteration:02d}_PASS".encode()
    command = [
        qemu,
        "-machine", "pc",
        "-m", "128M",
        "-drive", f"format=raw,file={image}",
        "-nographic",
        "-monitor", "none",
        "-serial", "stdio",
        "-no-reboot",
        "-no-shutdown",
    ]
    process = subprocess.Popen(
        command,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    if process.stdin is None:
        raise RuntimeError("QEMU stdin is unavailable")
    try:
        # /etc/bashrc emits this OSC title immediately before the first prompt.
        # Waiting for it prevents boot-time input from being consumed too early.
        read_until(process, b"Tunix Terminal", 20.0)
        process.stdin.write(b"echo __TUNIX_EDITOR_READY__\n")
        process.stdin.flush()
        read_until(process, b"__TUNIX_EDITOR_READY__", 15.0)

        process.stdin.write(b"rm -f /tmp/nano-smoke.txt\n")
        process.stdin.write(b"nano -I -x -w -t /tmp/nano-smoke.txt\n")
        process.stdin.flush()
        read_until(process, b"GNU nano", 8.0)

        payload = marker + b"\nsecond line\n"
        process.stdin.write(payload)
        process.stdin.write(b"\x18")  # Ctrl+X; -t saves immediately.
        process.stdin.flush()
        time.sleep(0.4)
        process.stdin.write(b"cat /tmp/nano-smoke.txt; echo __TUNIX_EDITOR_DONE__\n")
        process.stdin.flush()
        output = read_until(process, b"__TUNIX_EDITOR_DONE__", 8.0)
        if marker not in output:
            raise RuntimeError(f"saved marker was not returned by Tunix: {output[-2000:]!r}")
    finally:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("image", type=Path)
    parser.add_argument("--qemu", default="qemu-system-x86_64")
    parser.add_argument("--iterations", type=int, default=20)
    args = parser.parse_args()
    if not args.image.is_file():
        parser.error(f"image not found: {args.image}")
    if args.iterations < 1:
        parser.error("--iterations must be positive")

    for iteration in range(1, args.iterations + 1):
        run_once(args.qemu, args.image.resolve(), iteration)
        print(f"Tunix QEMU nano smoke {iteration:02d}/{args.iterations}: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
