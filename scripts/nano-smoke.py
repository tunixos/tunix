#!/usr/bin/env python3
from __future__ import annotations

import argparse
import fcntl
import os
import pty
import select
import struct
import subprocess
import tempfile
import termios
import time
from pathlib import Path


def drain(fd: int, seconds: float) -> bytes:
    deadline = time.monotonic() + seconds
    chunks: list[bytes] = []
    while time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.05)
        if not ready:
            continue
        try:
            data = os.read(fd, 65536)
        except OSError:
            break
        if not data:
            break
        chunks.append(data)
    return b"".join(chunks)


def run_once(binary: Path, terminfo_dir: Path, iteration: int) -> None:
    with tempfile.TemporaryDirectory(prefix="tunix-nano-") as tmp:
        target = Path(tmp) / "smoke.txt"
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 34, 120, 0, 0))
        env = os.environ.copy()
        env.update({
            "TERM": "tunix-256color",
            "TERMINFO": str(terminfo_dir),
            "HOME": tmp,
            "LANG": "C.UTF-8",
        })
        process = subprocess.Popen(
            [str(binary), "-I", "-x", "-w", "-t", str(target)],
            stdin=slave,
            stdout=slave,
            stderr=slave,
            env=env,
            start_new_session=True,
            close_fds=True,
        )
        os.close(slave)
        try:
            screen = drain(master, 0.8)
            if not screen:
                raise RuntimeError("nano produced no terminal output")
            payload = f"Tunix nano smoke {iteration:02d}\nsecond line\n".encode()
            os.write(master, payload)
            time.sleep(0.1)
            os.write(master, b"\x18")  # Ctrl+X; -t saves without a prompt.
            try:
                status = process.wait(timeout=5)
            except subprocess.TimeoutExpired as exc:
                process.kill()
                raise RuntimeError("nano did not exit after Ctrl+X") from exc
            drain(master, 0.2)
            if status != 0:
                raise RuntimeError(f"nano exited with status {status}")
            actual = target.read_bytes()
            if payload not in actual:
                raise RuntimeError(f"saved file mismatch: {actual!r}")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    parser.add_argument("terminfo", type=Path)
    parser.add_argument("--iterations", type=int, default=20)
    args = parser.parse_args()

    if args.iterations < 1:
        parser.error("--iterations must be positive")
    if not args.binary.is_file():
        parser.error(f"binary not found: {args.binary}")
    if not args.terminfo.is_dir():
        parser.error(f"terminfo directory not found: {args.terminfo}")

    for iteration in range(1, args.iterations + 1):
        run_once(args.binary.resolve(), args.terminfo.resolve(), iteration)
        print(f"nano smoke {iteration:02d}/{args.iterations}: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
