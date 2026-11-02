#!/usr/bin/env python3
# Draws the app icon, a dial: a ring with a knob on an indigo rounded
# square, as PNGs of every size an .icns needs, with nothing but the
# standard library. make icon turns them into macos/Resources/AppIcon.icns
# and settings/assets/icon.png.
import math, struct, sys, zlib

def smooth(d):
    # Coverage of a shape from its signed distance (inside < 0), over 1px.
    return min(1.0, max(0.0, 0.5 - d))

def rounded_square(x, y, half, radius):
    qx, qy = abs(x) - (half - radius), abs(y) - (half - radius)
    outside = math.hypot(max(qx, 0), max(qy, 0))
    inside = min(max(qx, qy), 0)
    return outside + inside - radius

def render(size, flat=False):
    rows = []
    s = size
    c = s / 2
    bg_half = s * 0.5 * (1.0 if flat else 0.86)
    bg_radius = bg_half * 0.44
    ring_r, ring_w = s * 0.30, s * 0.075
    knob_r = s * 0.115
    notch_r = s * 0.028
    for py in range(s):
        row = bytearray([0])
        for px in range(s):
            x, y = px + 0.5 - c, py + 0.5 - c
            a_bg = 1.0 if flat else smooth(rounded_square(x, y, bg_half, bg_radius))
            if a_bg <= 0:
                row += b"\0\0\0\0"
                continue
            t = (y / s + 0.5)
            r, g, b = 86 - 18 * t, 76 - 14 * t, 236 - 24 * t  # indigo, darker toward the bottom
            d = math.hypot(x, y)
            a_ring = smooth(abs(d - ring_r) - ring_w / 2)
            a_knob = smooth(d - knob_r)
            a_notch = smooth(math.hypot(x, y + ring_r) - notch_r)
            white = max(a_ring, a_knob)
            r = r + (255 - r) * white
            g = g + (255 - g) * white
            b = b + (255 - b) * white
            # The notch at the top of the ring, in the background colour.
            r = r + (86 - r) * a_notch
            g = g + (76 - g) * a_notch
            b = b + (236 - b) * a_notch
            row += bytes([int(r), int(g), int(b), int(255 * a_bg)])
        rows.append(bytes(row))
    raw = b"".join(rows)
    def chunk(t, body):
        return struct.pack(">I", len(body)) + t + body + struct.pack(">I", zlib.crc32(t + body) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", s, s, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))

if __name__ == "__main__":
    out, size = sys.argv[1], int(sys.argv[2])
    flat = len(sys.argv) > 3 and sys.argv[3] == "flat"
    open(out, "wb").write(render(size, flat))
