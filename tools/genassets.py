"""Generate Rockrun's procedural textures (CC0, self-made).

Writes 64x64 RGBA PNGs to a target directory:
- boulder.png, boulder_small.png, boulder_big.png: irregular rocky
  boulders with shading, speckles and highlight, in three sizes.
- diamond.png: faceted teal crystal with glow and specular lines.
- dirt.png: organic 16px-style sand block with speckle noise.
Deterministic (seeded) so regeneration is reproducible.
"""
import math
import random

from PIL import Image, ImageDraw, ImageFilter

SIZE = 64
rng = random.Random(7)


def radial_shade(size, rgb, strength=0.55, center=(0.38, 0.32)):
    img = Image.new("RGB", (size, size), rgb)
    px = img.load()
    for y in range(size):
        for x in range(size):
            d = math.hypot(x / size - center[0], y / size - center[1])
            f = max(0.0, 1.0 - strength * d * 1.6)
            r, g, b = px[x, y]
            px[x, y] = (int(r * f), int(g * f), int(b * f))
    return img


def make_boulder(name, frac, seed):
    """Boulder occupying `frac` of the tile, rocky irregular polygon."""
    r = random.Random(seed)
    size = SIZE
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    rad = frac * size / 2
    cx = size / 2 + r.uniform(-1.5, 1.5)
    cy = size / 2 + r.uniform(-1.5, 1.5)
    n = r.randint(9, 12)
    base_pts = []
    for i in range(n):
        ang = 2 * math.pi * i / n
        wobble = r.uniform(0.82, 1.0)
        px = cx + math.cos(ang) * rad * wobble
        py = cy + math.sin(ang) * rad * wobble * r.uniform(0.9, 1.05)
        base_pts.append((px, py))

    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).polygon(base_pts, fill=255)

    shade = radial_shade(size, (178, 166, 148), strength=0.55,
                         center=(0.35, 0.28))
    # strata noise
    noise = Image.effect_noise((size, size), 24).convert("RGB")
    shade = Image.blend(shade, noise, 0.14)
    # broad dark facets
    facets = Image.new("RGB", (size, size), (0, 0, 0))
    fd = ImageDraw.Draw(facets)
    for _ in range(5):
        ang = r.uniform(0, 2 * math.pi)
        fx = cx + math.cos(ang) * rad * r.uniform(0.2, 0.7)
        fy = cy + math.sin(ang) * rad * r.uniform(0.2, 0.7)
        fw = rad * r.uniform(0.5, 0.9)
        fd.ellipse([fx - fw, fy - fw, fx + fw, fy + fw],
                   fill=tuple(r.randint(18, 42) for _ in range(3)))
    facets = facets.filter(ImageFilter.GaussianBlur(size * 0.09))
    shade = Image.composite(
        Image.eval(shade, lambda v: v,), shade, mask)
    subs = Image.new("RGB", (size, size), (0, 0, 0))
    subs.paste(shade, (0, 0))
    shade = Image.eval(
        Image.blend(subs, facets, 0.12), lambda v: min(255, v))

    img.paste(shade, (0, 0), mask)
    # top-left highlight rim
    rim = ImageDraw.Draw(img)
    for i in range(len(base_pts)):
        p1 = base_pts[i]
        p2 = base_pts[(i + 1) % len(base_pts)]
        mx = (p1[0] + p2[0]) / 2
        my = (p1[1] + p2[1]) / 2
        if (mx - cx) + (my - cy) < 0:
            rim.line([p1, p2], fill=(235, 228, 210, 230), width=3)
    img.putalpha(mask)

    # soft drop shadow
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sh = Image.new("L", (size, size), 0)
    ImageDraw.Draw(sh).polygon(base_pts, fill=110)
    sh = sh.filter(ImageFilter.GaussianBlur(3))
    shadow.putalpha(sh)
    outpos = (1, 2)
    final = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    final.paste(shadow, outpos, shadow)
    final.paste(img, (0, 0), mask)
    final.save(f"/home/gokr/git/rockrun/data/texture/{name}.png")
    return final


def make_diamond(seed):
    r = random.Random(seed)
    size = SIZE
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    cx, cy = size / 2, size / 2
    # crystal silhouette: table + culet facets (fills the canvas)
    w = size * 0.47
    table_y = cy - size * 0.34
    belt_y = cy - size * 0.04
    culet_y = cy + size * 0.42
    left_top, right_top = cx - w * 0.72, cx + w * 0.72
    left_belt, right_belt = cx - w, cx + w
    top_pts = [(left_top, table_y), (right_top, table_y),
               (right_belt, belt_y), (left_belt, belt_y)]
    bot_pts = [(left_belt, belt_y), (right_belt, belt_y), (cx, culet_y)]

    mask = Image.new("L", (size, size), 0)
    md = ImageDraw.Draw(mask)
    md.polygon(top_pts, fill=255)
    md.polygon(bot_pts, fill=255)

    # vertical gradient teal -> deep blue
    grad = Image.new("RGB", (size, size))
    gp = grad.load()
    top_c = (95, 235, 235)
    mid_c = (40, 160, 230)
    bot_c = (24, 60, 200)
    for y in range(size):
        t = y / size
        if y < belt_y:
            k = (y - table_y + 8) / (belt_y - table_y + 8)
            c = tuple(int(top_c[i] + (mid_c[i] - top_c[i]) * k) for i in range(3))
        else:
            k = (y - belt_y) / max(1, culet_y - belt_y)
            c = tuple(int(mid_c[i] + (bot_c[i] - mid_c[i]) * k) for i in range(3))
        for x in range(size):
            gp[x, y] = c

    # facet lines
    d = ImageDraw.Draw(grad)
    line = (210, 255, 255)
    table_w = (right_top - left_top) / 6
    for i in range(1, 6):
        tx = left_top + table_w * i
        k = i / 6
        bx = left_belt + (right_belt - left_belt) * k
        d.line([(tx, table_y), (bx, belt_y)], fill=line, width=2)
        d.line([(bx, belt_y + 2), (cx, culet_y)], fill=(170, 230, 250), width=1)
    # specular sparkle
    d.ellipse([cx - 8, table_y - 4, cx + 4, table_y + 8], fill=(245, 255, 255))

    grad = grad.filter(ImageFilter.GaussianBlur(0.5))
    img.paste(grad, (0, 0), mask)

    # outer glow
    glow = Image.new("L", (size, size), 0)
    gd = ImageDraw.Draw(glow)
    gd.polygon(top_pts, fill=90)
    gd.polygon(bot_pts, fill=90)
    glow = glow.filter(ImageFilter.GaussianBlur(4))
    glow_img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    glow_img.paste(Image.new("RGB", (size, size), (60, 210, 240)), (0, 0), glow)
    final = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    final.paste(glow_img, (0, 0), glow)
    final.paste(img, (0, 0), mask)
    final.save("/home/gokr/git/rockrun/data/texture/diamond.png")
    return final


def make_dirt(seed):
    """Organic sand block, full bleed (fills the whole tile)."""
    r = random.Random(seed)
    size = SIZE
    base = radial_shade(size, (196, 138, 62), strength=0.42,
                        center=(0.5, 0.5))
    noise = Image.effect_noise((size, size), 34).convert("RGB")
    base = Image.blend(base, noise, 0.20)
    d = ImageDraw.Draw(base)
    # pebbles and speckles
    for _ in range(26):
        x = r.uniform(4, size - 4)
        y = r.uniform(4, size - 4)
        rr = r.uniform(1.4, 3.2)
        shade = r.choice([(150, 102, 46), (170, 120, 55),
                          (215, 160, 85), (130, 92, 45)])
        d.ellipse([x - rr, y - rr, x + rr, y + rr], fill=shade)
    # subtle darker blotches
    blot = Image.new("RGB", (size, size), (0, 0, 0))
    bd = ImageDraw.Draw(blot)
    for _ in range(4):
        x = r.uniform(0, size)
        y = r.uniform(0, size)
        rr = r.uniform(8, 16)
        bd.ellipse([x - rr, y - rr, x + rr, y + rr],
                   fill=(r.randint(6, 22),) * 3)
    blot = blot.filter(ImageFilter.GaussianBlur(7))
    base = Image.blend(base, blot, 0.25)
    base = base.filter(ImageFilter.GaussianBlur(0.6))
    base.convert("RGBA").save("/home/gokr/git/rockrun/data/texture/dirt.png")
    return base


if __name__ == "__main__":
    # All blobs fill ~94% of the canvas so that object scale maps physics
    # sphere radius directly to what you see (auto-sized parts).
    make_boulder("boulder_small", 0.94, 11)
    make_boulder("boulder", 0.94, 23)
    make_boulder("boulder_big", 0.94, 41)
    make_diamond(5)
    make_dirt(3)
    print("wrote textures")
