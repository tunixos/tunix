#!/usr/bin/env python3
"""Stamp the real permissions onto an initramfs tar.

The rootfs is staged on a Windows drive through drvfs, which reports every file
as 0777 root:root no matter what the build did. Every mode in the image would
therefore be world-writable and no setuid bit would survive -- which is fine
while everything runs as root, and useless the moment it does not.

So the modes are decided here rather than taken from the staging tree. A file
that starts with the ELF magic or a #! line is a program and gets 0755, anything
else is data and gets 0644; directories get 0755. The rules file then overrides
whatever needs to differ: /etc/shadow, the setuid tools, the sticky /tmp, and
the home directory's ownership.

ustar headers are fixed size, so the fields are patched in place and only the
512-byte blocks that change are written back.
"""

import fnmatch
import sys

BLOCK = 512
MODE_OFFSET, MODE_SIZE = 100, 8
UID_OFFSET, GID_OFFSET, ID_SIZE = 108, 116, 8
SIZE_OFFSET, SIZE_SIZE = 124, 12
CHECKSUM_OFFSET, CHECKSUM_SIZE = 148, 8
TYPE_OFFSET = 156
PREFIX_OFFSET, PREFIX_SIZE = 345, 155
NAME_SIZE = 100


def parse_octal(field):
    text = field.split(b"\0")[0].strip()
    return int(text, 8) if text else 0


def write_octal(header, offset, size, value):
    header[offset:offset + size] = ("%0*o\0" % (size - 1, value)).encode()


def checksum(header):
    blank = bytearray(header)
    blank[CHECKSUM_OFFSET:CHECKSUM_OFFSET + CHECKSUM_SIZE] = b" " * CHECKSUM_SIZE
    return sum(blank)


def member_path(header):
    name = header[0:NAME_SIZE].split(b"\0")[0].decode()
    prefix = header[PREFIX_OFFSET:PREFIX_OFFSET + PREFIX_SIZE].split(b"\0")[0].decode()
    if prefix:
        name = prefix + "/" + name
    if name.startswith("./"):
        name = name[1:]
    elif not name.startswith("/"):
        name = "/" + name
    return name


def read_rules(path):
    rules = []
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            fields = line.split()
            if len(fields) not in (2, 4):
                raise SystemExit("apply-permissions: bad rule: %s" % line)
            pattern, mode = fields[0], fields[1]
            uid = int(fields[2]) if len(fields) == 4 else None
            gid = int(fields[3]) if len(fields) == 4 else None
            rules.append((pattern, None if mode == "-" else int(mode, 8), uid, gid))
    return rules


def default_mode(image, offset, kind, size):
    if kind == b"5":
        return 0o755
    if kind in (b"2", b"1"):
        return 0o777
    if size == 0:
        return 0o644
    image.seek(offset + BLOCK)
    head = image.read(4)
    if head.startswith(b"\x7fELF") or head.startswith(b"#!"):
        return 0o755
    return 0o644


def apply(image_path, rules_path):
    rules = read_rules(rules_path)
    patched = 0
    with open(image_path, "r+b") as image:
        offset = 0
        while True:
            image.seek(offset)
            block = image.read(BLOCK)
            if len(block) < BLOCK or block[0:1] == b"\0":
                break
            header = bytearray(block)
            path = member_path(header)
            kind = header[TYPE_OFFSET:TYPE_OFFSET + 1]
            size = parse_octal(header[SIZE_OFFSET:SIZE_OFFSET + SIZE_SIZE])

            mode = default_mode(image, offset, kind, size)
            uid, gid = 0, 0
            candidate = path + "/" if kind == b"5" and not path.endswith("/") else path
            for pattern, rule_mode, rule_uid, rule_gid in rules:
                if not fnmatch.fnmatchcase(candidate, pattern):
                    continue
                if rule_mode is not None:
                    mode = rule_mode
                if rule_uid is not None:
                    uid, gid = rule_uid, rule_gid

            if (parse_octal(header[MODE_OFFSET:MODE_OFFSET + MODE_SIZE]) != mode or
                    parse_octal(header[UID_OFFSET:UID_OFFSET + ID_SIZE]) != uid or
                    parse_octal(header[GID_OFFSET:GID_OFFSET + ID_SIZE]) != gid):
                write_octal(header, MODE_OFFSET, MODE_SIZE, mode)
                write_octal(header, UID_OFFSET, ID_SIZE, uid)
                write_octal(header, GID_OFFSET, ID_SIZE, gid)
                write_octal(header, CHECKSUM_OFFSET, CHECKSUM_SIZE - 1, checksum(header))
                header[CHECKSUM_OFFSET + CHECKSUM_SIZE - 1:CHECKSUM_OFFSET + CHECKSUM_SIZE] = b" "
                image.seek(offset)
                image.write(header)
                patched += 1

            offset += BLOCK + ((size + BLOCK - 1) // BLOCK) * BLOCK
    print("apply-permissions: %d entries stamped in %s" % (patched, image_path))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: apply-permissions.py <initramfs.tar> <rules>")
    apply(sys.argv[1], sys.argv[2])
