# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
"""Draw Kai's monochrome tray shield (16, 20, 24, 32, 40, 48 px) in two
colours and write one .ico per colour, with no third-party modules.

usage: python -I scripts/release/make-tray-icons.py OUT_DIR

  tray-dark.ico   a dark shield, for a light taskbar
  tray-light.ico  a white shield, for a dark taskbar
  tray-off-*.ico  the same shield with a slash, shown while Kai is paused
"""
import os
import struct
import sys
import zlib

SIZES = (16, 20, 24, 32, 40, 48)


def shield(x, y):
    """Inside the shield outline, in a 0..1 square: flat top, straight sides
    down to 55%, then curving to a point at the bottom."""
    if y < 0.08 or y > 0.95:
        return False
    half = 0.40 if y < 0.55 else 0.40 * ((0.95 - y) / 0.40) ** 0.75
    top = 0.08 + 0.06 * abs(x - 0.5) / 0.40      # the top dips slightly to the edges
    return abs(x - 0.5) <= half and y >= top


def inner(x, y, w):
    """The hollow inside, w = stroke width as a fraction."""
    if y < 0.08 + w or y > 0.95 - w * 1.6:
        return False
    half = (0.40 - w) if y < 0.55 else (0.40 - w) * max(0.0, (0.95 - w * 1.6 - y) / (0.40 - w * 1.6)) ** 0.75
    top = 0.08 + w + 0.06 * abs(x - 0.5) / 0.40
    return abs(x - 0.5) <= half and y >= top


def check(x, y, w):
    """A check mark inside the shield."""
    def seg(ax, ay, bx, by):
        dx, dy = bx - ax, by - ay
        t = max(0.0, min(1.0, ((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy)))
        px, py = ax + t * dx, ay + t * dy
        return ((x - px) ** 2 + (y - py) ** 2) ** 0.5 <= w / 2
    return seg(0.33, 0.50, 0.46, 0.63) or seg(0.46, 0.63, 0.69, 0.36)


def slash(x, y, w):
    dx, dy = 0.84 - 0.16, 0.88 - 0.12
    t = max(0.0, min(1.0, ((x - 0.16) * dx + (y - 0.12) * dy) / (dx * dx + dy * dy)))
    px, py = 0.16 + t * dx, 0.12 + t * dy
    return ((x - px) ** 2 + (y - py) ** 2) ** 0.5 <= w / 2


def render(n, rgb, paused):
    ss = 6
    w = max(1.6 / n, 0.085)
    rows = []
    for j in range(n):
        row = bytearray([0])
        for i in range(n):
            cov = 0
            for sj in range(ss):
                for si in range(ss):
                    x, y = (i + (si + 0.5) / ss) / n, (j + (sj + 0.5) / ss) / n
                    on = shield(x, y) and not inner(x, y, w)
                    on = on or check(x, y, w * 1.1)
                    if paused:
                        on = (on and not slash(x, y, w * 2.6)) or slash(x, y, w)
                    cov += on
            a = round(255 * cov / (ss * ss))
            row += bytes(rgb) + bytes([a])
        rows.append(bytes(row))
    raw = b"".join(rows)

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", n, n, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def ico(images):
    head = struct.pack("<HHH", 0, 1, len(images))
    off = 6 + 16 * len(images)
    ent, blob = b"", b""
    for n, d in images:
        ent += struct.pack("<BBBBHHII", n % 256, n % 256, 0, 0, 1, 32, len(d), off + len(blob))
        blob += d
    return head + ent + blob


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    for name, rgb in (("dark", (0x24, 0x25, 0x32)), ("light", (0xFF, 0xFF, 0xFF))):
        for paused, pre in ((False, "tray-"), (True, "tray-off-")):
            with open(os.path.join(out, pre + name + ".ico"), "wb") as f:
                f.write(ico([(n, render(n, rgb, paused)) for n in SIZES]))
    print(out + ": tray-{dark,light}.ico, tray-off-{dark,light}.ico")


if __name__ == "__main__":
    main()
