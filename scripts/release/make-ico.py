# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
"""Pack PNG files into one Windows .ico (PNG-compressed entries, Vista+).

usage: python -I scripts/release/make-ico.py OUT.ico IN1.png [IN2.png ...]

Used for installer/windows/Kai.ico from the macOS app icon set
(app/macos/Sources/Assets.xcassets/AppIcon.appiconset), so both platforms
show the same icon. No third-party modules.
"""
import struct
import sys


def png_size(data):
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise SystemExit("not a PNG")
    return struct.unpack(">II", data[16:24])


def main():
    out, ins = sys.argv[1], sys.argv[2:]
    images = []
    for p in ins:
        with open(p, "rb") as f:
            d = f.read()
        w, h = png_size(d)
        if w != h or w > 256:
            raise SystemExit(p + ": must be square and at most 256 px")
        images.append((w, d))
    images.sort()
    header = struct.pack("<HHH", 0, 1, len(images))
    offset = 6 + 16 * len(images)
    entries, blobs = b"", b""
    for w, d in images:
        b = 0 if w == 256 else w
        entries += struct.pack("<BBBBHHII", b, b, 0, 0, 1, 32, len(d), offset + len(blobs))
        blobs += d
    with open(out, "wb") as f:
        f.write(header + entries + blobs)
    print(out + ": " + ", ".join(str(w) for w, _ in images) + " px")


if __name__ == "__main__":
    main()
