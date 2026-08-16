"""Generate Rockrun's procedural textures (CC0, self-made).

Writes 64x64 RGBA PNGs to a target directory:
- boulder.png, boulder_small.png, boulder_big.png: irregular rocky
  boulders with shading, speckles and highlight, in three sizes.
- diamond.png: faceted teal crystal with glow and specular lines.
- dirt.png: organic 16px-style sand block with speckle noise.
Deterministic (seeded) so regeneration is reproducible.
"""
import math
import os
import random

# Output next to the repo the script lives in (was hardcoded to the
# main worktree, which corrupts it when run from a worktree).
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data", "texture")
SOUND_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data", "sound")

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
    cx = size / 2 + r.uniform(-1.0, 1.0)
    cy = size / 2 + r.uniform(-1.0, 1.0)
    n = r.randint(9, 12)
    base_pts = []
    for i in range(n):
        ang = 2 * math.pi * i / n
        wobble = r.uniform(0.9, 1.0)
        px = cx + math.cos(ang) * rad * wobble
        py = cy + math.sin(ang) * rad * wobble * r.uniform(0.94, 1.02)
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

    # soft drop shadow, close and subtle
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sh = Image.new("L", (size, size), 0)
    ImageDraw.Draw(sh).polygon(base_pts, fill=70)
    sh = sh.filter(ImageFilter.GaussianBlur(1.5))
    shadow.putalpha(sh)
    final = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    final.paste(shadow, (1, 1), shadow)
    final.paste(img, (0, 0), mask)
    final.save(os.path.join(OUT_DIR, f"{name}.png"))
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
    final.save(os.path.join(OUT_DIR, "diamond.png"))
    return final


def make_dirt(seed):
    """Organic sand block, full bleed; several pebbles per tile so even
    small 8px blocks read as granular."""
    r = random.Random(seed)
    size = SIZE
    base = radial_shade(size, (196, 138, 62), strength=0.42,
                        center=(0.5, 0.5))
    noise = Image.effect_noise((size, size), 34).convert("RGB")
    base = Image.blend(base, noise, 0.18)
    d = ImageDraw.Draw(base)
    # many tiny pebbles
    for _ in range(34):
        x = r.uniform(3, size - 3)
        y = r.uniform(3, size - 3)
        rr = r.uniform(1.1, 2.4)
        shade = r.choice([(150, 102, 46), (170, 120, 55),
                          (215, 160, 85), (130, 92, 45), (190, 140, 70)])
        d.ellipse([x - rr, y - rr, x + rr, y + rr], fill=shade)
    # a few bigger stones
    for _ in range(4):
        x = r.uniform(6, size - 6)
        y = r.uniform(6, size - 6)
        rr = r.uniform(2.6, 4.2)
        shade = r.choice([(142, 96, 44), (162, 114, 52), (205, 152, 80)])
        d.ellipse([x - rr, y - rr, x + rr, y + rr], fill=shade)
        d.ellipse([x - rr * 0.4, y - rr * 0.45, x + rr * 0.2, y + rr * 0.1],
                  fill=(232, 190, 120))
    # subtle darker blotches
    blot = Image.new("RGB", (size, size), (0, 0, 0))
    bd = ImageDraw.Draw(blot)
    for _ in range(3):
        x = r.uniform(0, size)
        y = r.uniform(0, size)
        rr = r.uniform(7, 14)
        bd.ellipse([x - rr, y - rr, x + rr, y + rr],
                   fill=(r.randint(6, 22),) * 3)
    blot = blot.filter(ImageFilter.GaussianBlur(7))
    base = Image.blend(base, blot, 0.22)
    base = base.filter(ImageFilter.GaussianBlur(0.5))
    base.convert("RGBA").save(os.path.join(OUT_DIR, "dirt.png"))
    return base


def make_firefly(name, body_rgb, wing_rgb, seed):
    """Glowing bug sprite: winged critter that hugs walls. Drawn large in
    the canvas so the critter reads clearly at game scale."""
    r = random.Random(seed)
    size = SIZE
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    cx, cy = size / 2, size / 2

    glow = Image.new("L", (size, size), 0)
    ImageDraw.Draw(glow).ellipse([2, 2, size - 2, size - 2], fill=90)
    glow = glow.filter(ImageFilter.GaussianBlur(6))
    glow_img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    glow_img.paste(Image.new("RGB", (size, size), body_rgb), (0, 0), glow)
    img.paste(glow_img, (0, 0), glow)

    d = ImageDraw.Draw(img)
    # two big wings reaching the canvas edges
    for sx in (-1, 1):
        wpts = [(cx, cy - 4),
                (cx + sx * 30, cy - 18),
                (cx + sx * 28, cy + 4),
                (cx, cy + 8)]
        d.polygon(wpts, fill=wing_rgb + (170,), outline=(20, 20, 40, 255))
    # body
    d.ellipse([cx - 13, cy - 13, cx + 13, cy + 13],
              fill=body_rgb + (255,), outline=(25, 25, 45, 255))
    d.ellipse([cx - 5, cy - 5, cx + 5, cy + 5], fill=(255, 255, 255, 255))
    # eyes
    d.ellipse([cx - 8, cy - 9, cx - 2, cy - 3], fill=(10, 10, 25, 255))
    d.ellipse([cx + 2, cy - 9, cx + 8, cy - 3], fill=(10, 10, 25, 255))
    img.save(os.path.join(OUT_DIR, f"{name}.png"))
    return img


def make_hero_strips():
    """Cuts the Kenney adventurer sheet (tools/kenney-characters.png,
    9x3 grid of 24px tiles with 1px spacing) into three animation strips.
    Row 0 holds the same character model in several palette variants,
    each a 2-frame walk cycle: green (0-1), blue (2-3), pink (4-5),
    brown (6-7) - the pink pair is 'player 1'. All strips use the hero's
    own pink/brown frames so the hero never changes character between
    states; row 1/2 hold other characters and are not used. A procedural
    pickaxe swing is drawn over the dig frames so the action reads as
    digging."""
    src = os.path.join(os.path.dirname(__file__), "kenney-characters.png")
    sheet = Image.open(src).convert("RGBA")
    plans = {
        "idle": [4, 5],
        "run": [4, 5, 6, 7],
        "dig": [4, 5, 4],
    }
    for name, sel in plans.items():
        out = Image.new("RGBA", (24 * len(sel), 24), (0, 0, 0, 0))
        for n, i in enumerate(sel):
            col, row = i % 9, i // 9
            tile = sheet.crop((col * 25, row * 25, col * 25 + 24, row * 25 + 24))
            if name == "dig":
                tile = add_pickaxe(tile, n)
            out.paste(tile, (n * 24, 0), tile)
        out.save(os.path.join(OUT_DIR, f"{name}.png"))


def make_beeps():
    """Synthesizes the countdown beeps as 16-bit mono WAVs: a short
    880Hz 'beep' and the long 660Hz final 'BEEEEP'."""
    import wave
    import struct
    rate = 22050

    def tone(freq, dur, vol=0.5):
        n = int(rate * dur)
        frames = bytearray()
        for i in range(n):
            t = i / rate
            # quick attack, gentle release - no clicks
            env = min(1.0, t / 0.01, (dur - t) / 0.03)
            sample = int(vol * 32767 * env * math.sin(2 * math.pi * freq * t))
            frames += struct.pack('<h', sample)
        return bytes(frames)

    for name, freq, dur in (("beep", 880.0, 0.12), ("beep_go", 660.0, 0.7)):
        with wave.open(os.path.join(SOUND_DIR, name + ".wav"), 'wb') as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(rate)
            w.writeframes(tone(freq, dur))
    print("wrote beep sounds")


def add_pickaxe(tile, step):
    """Draws a clearly visible swinging pickaxe over a dig frame:
    step 0 winds up, step 1 is overhead, step 2 is swung down in front."""
    d = ImageDraw.Draw(tile)
    angles = {0: -60, 1: 75, 2: -140}
    angle = math.radians(angles[step])
    px, py = 13.0, 14.0            # grip point (hands)
    handle_len = 14.5
    hx = px + handle_len * math.cos(angle)
    hy = py + handle_len * math.sin(angle)
    # handle: thick brown shaft with a darker outline
    d.line([(px, py), (hx, hy)], fill=(70, 40, 15, 255), width=5)
    d.line([(px, py), (hx, hy)], fill=(140, 90, 35, 255), width=3)
    # head: crescent pick, drawn as two short thick strokes at the tip
    perp = angle + math.pi / 2
    head_pts = [(hx + 7.5 * math.cos(perp), hy + 7.5 * math.sin(perp)),
                (hx - 4.0 * math.cos(perp), hy - 4.0 * math.sin(perp))]
    d.line(head_pts, fill=(30, 30, 35, 255), width=6)
    d.line(head_pts, fill=(205, 210, 215, 255), width=3)
    # small bright sparkle at the working end
    ex = hx + 8.5 * math.cos(perp)
    ey = hy + 8.5 * math.sin(perp)
    d.ellipse([ex - 1.5, ey - 1.5, ex + 1.5, ey + 1.5], fill=(255, 255, 240, 255))
    return tile


def make_icon():
    """512x512 app icon: a boulder with a gem, on a dark cave backdrop."""
    size = 512
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # rounded backdrop
    d.rounded_rectangle([8, 8, size - 8, size - 8], radius=90,
                        fill=(18, 20, 30, 255))
    # cave sand hint at the bottom
    d.rounded_rectangle([40, 360, 472, 460], radius=40,
                        fill=(120, 84, 46, 255))
    # boulder: irregular polygon with facets
    cx, cy, r = 210, 260, 150
    pts = [(cx + r * math.cos(a), cy + r * math.sin(a))
           for a in [i * 2 * math.pi / 10 for i in range(10)]]
    d.polygon(pts, fill=(150, 138, 120, 255), outline=(70, 60, 50, 255))
    # boulder facets
    d.polygon([(cx - 60, cy - 70), (cx + 40, cy - 100), (cx + 80, cy - 20),
               (cx - 10, cy + 10)], fill=(120, 108, 92, 255))
    d.polygon([(cx + 10, cy + 20), (cx + 110, cy - 10), (cx + 90, cy + 90),
               (cx + 20, cy + 80)], fill=(96, 84, 70, 255))
    d.ellipse([cx - 70, cy - 110, cx + 30, cy - 60], fill=(190, 182, 165, 255))
    # gem sticking out of the sand
    gx, gy = 330, 310
    d.polygon([(gx, gy - 70), (gx + 70, gy - 40), (gx + 55, gy + 30),
               (gx - 55, gy + 30), (gx - 70, gy - 40)], fill=(60, 210, 240, 255))
    d.polygon([(gx, gy - 70), (gx, gy + 30), (gx - 55, gy + 30),
               (gx - 70, gy - 40)], fill=(40, 160, 220, 255))
    d.polygon([(gx, gy - 70), (gx + 70, gy - 40), (gx + 55, gy + 30),
               (gx, gy + 30)], fill=(90, 230, 250, 255))
    d.polygon([(gx, gy - 70), (gx, gy + 30)], fill=(200, 250, 255, 255))
    d.ellipse([gx - 12, gy - 58, gx + 10, gy - 40], fill=(240, 255, 255, 255))
    out = os.path.join(os.path.dirname(__file__), "..", "assets")
    os.makedirs(out, exist_ok=True)
    img.save(os.path.join(out, "rockrun.png"))
    return img


if __name__ == "__main__":
    # Blobs are drawn slightly larger than the canvas so the rock fills it
    # nearly edge to edge: the visible rock then matches the physics
    # sphere (object size = full cell), leaving no gap to the sand.
    make_boulder("boulder_small", 1.06, 11)
    make_boulder("boulder", 1.06, 23)
    make_boulder("boulder_big", 1.06, 41)
    make_icon()
    make_diamond(5)
    make_dirt(3)
    # Fireflies: teal wall-hugger (turns right) and purple butterfly
    # (turns left).
    make_firefly("firefly", (90, 235, 225), (40, 190, 210), 51)
    make_firefly("butterfly", (225, 95, 235), (160, 60, 190), 77)
    make_hero_strips()
    make_beeps()
    print("wrote textures")
