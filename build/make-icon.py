#!/usr/bin/env python3
"""Draws the app icon: a restore point strip on a white rounded square.

Writes app/rootfs_common/icon.png and www/icon.png with the standard library only.
The UGREEN docs name both locations, so both exist.
"""
import pathlib
import struct
import zlib

SIZE = 256
SCALE = 4
FULL = SIZE * SCALE
RADIUS = 56 * SCALE
INK = (11, 111, 122)
MUTED = (150, 172, 180)
LATEST = (18, 50, 58)


def in_rounded_square(x, y, inset):
    low, high = inset, FULL - inset
    radius = RADIUS - inset
    if not (low <= x < high and low <= y < high):
        return False
    cx = min(max(x, low + radius), high - radius)
    cy = min(max(y, low + radius), high - radius)
    return (x - cx) ** 2 + (y - cy) ** 2 <= radius**2


# (center x, height, width, color) in icon pixels, on a shared baseline.
BASELINE = 182
BARS = [
    (52, 52, 10, INK),
    (78, 52, 10, INK),
    (104, 86, 18, INK),
    (130, 52, 10, INK),
    (156, 52, 10, INK),
    (182, 52, 10, INK),
    (208, 104, 18, LATEST),
]


def sample(x, y):
    """Returns the RGBA of one subpixel."""
    if not in_rounded_square(x, y, 0):
        return (0, 0, 0, 0)
    if not in_rounded_square(x, y, 2):
        return (232, 232, 232, 255)
    icon_x, icon_y = x / SCALE, y / SCALE
    if BASELINE <= icon_y < BASELINE + 6 and 34 <= icon_x < 222:
        return (*MUTED, 255)
    for center, height, width, color in BARS:
        if abs(icon_x - center) <= width / 2 and BASELINE - height <= icon_y < BASELINE:
            return (*color, 255)
    return (255, 255, 255, 255)


def render():
    rows = []
    for row in range(SIZE):
        pixels = bytearray([0])
        for column in range(SIZE):
            total = [0, 0, 0, 0]
            for sub_y in range(SCALE):
                for sub_x in range(SCALE):
                    r, g, b, a = sample(column * SCALE + sub_x, row * SCALE + sub_y)
                    total[0] += r * a
                    total[1] += g * a
                    total[2] += b * a
                    total[3] += a
            alpha = total[3]
            if alpha:
                pixels += bytes((total[0] // alpha, total[1] // alpha, total[2] // alpha, alpha // SCALE**2))
            else:
                pixels += bytes(4)
        rows.append(bytes(pixels))
    return b"".join(rows)


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


def main():
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(render(), 9))
        + chunk(b"IEND", b"")
    )
    base = pathlib.Path(__file__).resolve().parent.parent / "app" / "rootfs_common"
    for path in (base / "icon.png", base / "www" / "icon.png"):
        path.write_bytes(png)
        print(path, len(png), "bytes")


if __name__ == "__main__":
    main()
