#!/usr/bin/env python3
"""Draws the NextMob icon and writes it as a PNG.

    python3 -I tools/make-icon.py media/icon-400.png 400

No third-party modules: shapes are signed distance functions, anti-aliased
analytically from the distance (coverage = 0.5 - d, clamped), and the PNG is
assembled with zlib and struct. That keeps the icon reproducible from source
rather than being an opaque binary nobody can edit.

The mark is a targeting reticle with three claw slashes through it: the reticle
is what the addon does, the claws are what it does it to. Both are chunky on
purpose -- CurseForge shows this at 64px in listings and smaller in search, so
thin detail would turn to mud.
"""

import math
import struct
import sys
import zlib

# --- colours ---------------------------------------------------------------
BG_INNER = (0x23, 0x2F, 0x40)   # lifted centre, so the disc has some depth
BG_OUTER = (0x0E, 0x12, 0x18)   # near black at the corners
GOLD     = (0xE8, 0xAE, 0x3C)
GOLD_DIM = (0xA8, 0x7A, 0x22)   # shadow side of the ring
CLAW     = (0xE5, 0x45, 0x2B)
CLAW_DIM = (0x9E, 0x24, 0x15)


def clamp(x, lo=0.0, hi=1.0):
    return lo if x < lo else hi if x > hi else x


def lerp(a, b, t):
    return a + (b - a) * t


def mix(c1, c2, t):
    return tuple(lerp(c1[i], c2[i], t) for i in range(3))


# --- signed distance functions, all in pixel units -------------------------
def sd_rounded_rect(px, py, half, radius):
    qx = abs(px) - (half - radius)
    qy = abs(py) - (half - radius)
    outside = math.hypot(max(qx, 0.0), max(qy, 0.0))
    return outside + min(max(qx, qy), 0.0) - radius


def sd_ring(px, py, radius, thickness):
    return abs(math.hypot(px, py) - radius) - thickness * 0.5


def sd_capsule(px, py, ax, ay, bx, by, radius):
    bax, bay = bx - ax, by - ay
    pax, pay = px - ax, py - ay
    denom = bax * bax + bay * bay
    h = clamp((pax * bax + pay * bay) / denom) if denom else 0.0
    return math.hypot(pax - bax * h, pay - bay * h) - radius


def sd_blade(px, py, ax, ay, bx, by, rmax):
    """A slash: widest in the middle, sharp at both tips.

    A constant-radius capsule reads as a stick and a one-way taper reads as a
    matchstick. Swelling the radius towards the middle is what makes the shape
    say "claw mark" at a glance.
    """
    bax, bay = bx - ax, by - ay
    pax, pay = px - ax, py - ay
    denom = bax * bax + bay * bay
    h = clamp((pax * bax + pay * bay) / denom) if denom else 0.0
    taper = 1.0 - (2.0 * h - 1.0) ** 2          # 0 at the tips, 1 mid-blade
    return math.hypot(pax - bax * h, pay - bay * h) - rmax * (taper ** 0.55)


def render(size):
    s = size / 400.0          # every measurement below is in 400px units
    half = size / 2.0
    ring_r, ring_t = 136 * s, 26 * s
    tick_in, tick_out = 96 * s, 170 * s
    tick_r = 13 * s

    # Three slashes, rotated together, swept across the middle. Kept inside
    # the ring: a slash that runs past it fights the reticle instead of
    # sitting in it.
    angle = math.radians(-38)
    ca, sa = math.cos(angle), math.sin(angle)
    claws = []
    # Staggered along their own axis as well as spaced across it: three
    # slashes with their tips in a row look like petals, not a claw.
    for offset, length, width, shift in ((-56 * s, 100 * s, 11 * s,  16 * s),
                                         (0.0,     118 * s, 13 * s,  0.0),
                                         (56 * s,   98 * s, 10 * s, -14 * s)):
        x0, y0 = offset, -length + shift
        x1, y1 = offset, length + shift
        claws.append((
            x0 * ca - y0 * sa, x0 * sa + y0 * ca,
            x1 * ca - y1 * sa, x1 * sa + y1 * ca,
            width,
        ))

    ticks = []
    for a in (0, 90, 180, 270):
        r = math.radians(a)
        ticks.append((
            math.cos(r) * tick_in, math.sin(r) * tick_in,
            math.cos(r) * tick_out, math.sin(r) * tick_out,
        ))

    px_bytes = bytearray()
    for y in range(size):
        for x in range(size):
            # pixel centre, relative to the middle of the image
            cx = x + 0.5 - half
            cy = y + 0.5 - half

            # background plate: rounded square, radial shading
            d_bg = sd_rounded_rect(cx, cy, half, 92 * s)
            a_bg = clamp(0.5 - d_bg)
            t = clamp(math.hypot(cx, cy) / (half * 1.05))
            r, g, b = mix(BG_INNER, BG_OUTER, t * t)
            alpha = a_bg

            # claw slashes, drawn first so the reticle sits over them
            for (ax, ay, bx, by, width) in claws:
                d = sd_blade(cx, cy, ax, ay, bx, by, width)
                a_c = clamp(0.5 - d)
                # A dark outline around every slash, drawn whether or not the
                # slash covers this pixel. With the slashes behind the reticle
                # this is what keeps them from melting into the dark plate.
                lip = clamp(0.5 - (d - 5.0 * s))
                if lip > a_c:
                    k = lip - a_c
                    r = lerp(r, 0x0E, k)
                    g = lerp(g, 0x12, k)
                    b = lerp(b, 0x18, k)
                    alpha = alpha + (1 - alpha) * k
                if a_c > 0:
                    shade = clamp(0.5 + (cx + cy) / (300 * s))
                    col = mix(CLAW, CLAW_DIM, shade)
                    r = lerp(r, col[0], a_c)
                    g = lerp(g, col[1], a_c)
                    b = lerp(b, col[2], a_c)
                    alpha = alpha + (1 - alpha) * a_c

            # reticle ring, lit from the top left
            d_ring = sd_ring(cx, cy, ring_r, ring_t)
            a_ring = clamp(0.5 - d_ring)
            if a_ring > 0:
                shade = clamp(0.5 + (cx + cy) / (260 * s))
                col = mix(GOLD, GOLD_DIM, shade)
                r = lerp(r, col[0], a_ring)
                g = lerp(g, col[1], a_ring)
                b = lerp(b, col[2], a_ring)
                alpha = alpha + (1 - alpha) * a_ring

            # four ticks reaching in towards the centre
            for (ax, ay, bx, by) in ticks:
                d = sd_capsule(cx, cy, ax, ay, bx, by, tick_r)
                a_t = clamp(0.5 - d)
                if a_t > 0:
                    r = lerp(r, GOLD[0], a_t)
                    g = lerp(g, GOLD[1], a_t)
                    b = lerp(b, GOLD[2], a_t)
                    alpha = alpha + (1 - alpha) * a_t

            px_bytes += bytes((
                int(clamp(r, 0, 255) + 0.5),
                int(clamp(g, 0, 255) + 0.5),
                int(clamp(b, 0, 255) + 0.5),
                int(clamp(alpha) * 255 + 0.5),
            ))
    return bytes(px_bytes)


def write_png(path, size, pixels):
    def chunk(tag, data):
        out = struct.pack(">I", len(data)) + tag + data
        return out + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    stride = size * 4
    raw = bytearray()
    for y in range(size):
        raw.append(0)                                  # filter type 0
        raw += pixels[y * stride:(y + 1) * stride]

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as fh:
        fh.write(png)


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "media/icon-400.png"
    size = int(sys.argv[2]) if len(sys.argv) > 2 else 400
    write_png(out, size, render(size))
    print(f"wrote {out} at {size}x{size}")
