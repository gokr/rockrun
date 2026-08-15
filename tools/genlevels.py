"""Generate Rockrun level data (levels.ini).

Levels are ASCII maps: '#' wall, '.' dirt, ' ' empty, 'O' boulder,
'D' diamond, '@' player start, 'E' exit. Validation guarantees:
  - exact width/height per row
  - exactly one '@' and one 'E'
  - every boulder/diamond starts supported by something solid below
  - interior rows end at the border wall
The output is deterministic (seeded RNG).
"""
import random

WALL, DIRT, EMPTY, BOULDER, GEM, START, EXIT = '#', '.', ' ', 'O', 'D', '@', 'E'


def make_level(w, h):
    g = [[WALL if y in (0, h - 1) or x in (0, w - 1) else DIRT for x in range(w)]
         for y in range(h)]
    return g


def carve(g, x0, y0, x1, y1):
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            g[y][x] = EMPTY


def supported(g, x, y):
    return g[y + 1][x] in (DIRT, WALL, BOULDER, GEM)


def scatter(g, rng, w, h, symbol, count, reserved, bands):
    placed = []
    tries = 0
    while len(placed) < count and tries < 4000:
        tries += 1
        x = rng.randrange(2, w - 2)
        y = rng.randrange(2, h - 2)
        if g[y][x] != DIRT or (x, y) in reserved:
            continue
        if not supported(g, x, y):
            continue
        if bands and not any(bx0 <= x <= bx1 and by0 <= y <= by1
                             for bx0, by0, bx1, by1 in bands):
            continue
        g[y][x] = symbol
        placed.append((x, y))
        reserved.add((x, y))
    return placed


def emit(name, section, g, needed, time_limit):
    h = len(g)
    w = len(g[0])
    rows = [''.join(row) for row in g]
    gems = sum(r.count(GEM) for r in rows)
    assert all(len(r) == w for r in rows), "row width mismatch"
    assert sum(r.count(START) for r in rows) == 1
    assert sum(r.count(EXIT) for r in rows) == 1
    assert needed <= gems, f"{name}: needed {needed} > placed {gems}"
    # nothing may start mid-air
    for y in range(h - 2):
        for x in range(w):
            if g[y][x] in (BOULDER, GEM):
                assert supported(g, x, y), (name, x, y, g[y][x])
    print(f"-- {name}: {w}x{h}, {len([r for r in rows for c in r if c == BOULDER])} boulders, {gems} diamonds (need {needed})\n"
          + "\n".join(rows) + "\n")
    lines = [f"[{section}]", f"Name           = \"{name}\"",
             f"NeededDiamonds = {needed}", f"TimeLimit      = {time_limit}",
             f"RowCount       = {len(rows)}"]
    # One row per key: ORX treats #"..."# as a block literal, which keeps
    # the '#' tile characters from being interpreted as list separators.
    for i, r in enumerate(rows):
        lines.append(f'Row{i:<2}          = "{r}"')
    return '\n'.join(lines)


def level1():
    w, h = 40, 22
    rng = random.Random(41)
    g = make_level(w, h)
    reserved = set()
    # start pocket top-left: guaranteed corridor of dirt cols 4-8 with a gem at col 7
    ((px, py), (ex, ey)) = (2, 2), (36, 19)
    carve(g, 1, 1, 3, 1)          # elbow room above start
    g[py][px] = START
    reserved |= {(x, py) for x in range(1, 9)} | {(px, py), (ex, ey)}
    g[2][7] = GEM                 # startup-test gem: dig straight right
    reserved.add((7, 2))
    # open shaft for the startup-test boulder drop (cols 29-31, rows 2..6)
    carve(g, 29, 2, 31, 6)
    # caverns lower half - candidates for unearthing
    carve(g, 9, 12, 17, 13)
    carve(g, 22, 9, 26, 10)
    carve(g, 4, 16, 12, 17)
    carve(g, 30, 15, 37, 16)
    # exit alcove bottom-right; (35,19) is carved empty so tests can
    # teleport next to the exit deterministically
    carve(g, 35, 18, 37, 17)
    carve(g, 35, 19, 37, 19)
    g[ey][ex] = EXIT
    # boulders on dirt shelves (upper bands) + a few guarding the caverns
    bands = [(2, 3, 27, 6), (5, 14, 19, 15), (23, 11, 28, 11), (13, 18, 20, 18), (32, 4, 37, 6)]
    scatter(g, rng, w, h, BOULDER, 14, reserved, bands)
    # gems: corridor one already placed; others in dirt + some in cavern floors
    gbands = [(2, 4, 20, 9), (9, 12, 17, 13), (4, 16, 12, 17), (21, 8, 38, 13), (13, 18, 20, 19)]
    scatter(g, rng, w, h, GEM, 12, reserved, gbands)
    return emit("First Descent", "Level1", g, 8, 200)


def level2():
    w, h = 48, 26
    rng = random.Random(132)
    g = make_level(w, h)
    reserved = set()
    (px, py), (ex, ey) = (3, 3), (6, h - 3)
    carve(g, 2, 2, 5, 2)
    g[py][px] = START
    reserved |= {(2, 3), (3, 3), (4, 3), (5, 3), (ex, ey)}
    # grand central hall with pillars of dirt
    carve(g, 16, 10, 32, 16)
    for x in (20, 24, 28):
        for y in (13, 16):
            g[y][x] = DIRT
    # side shafts
    carve(g, 9, 4, 10, 20)
    carve(g, 38, 6, 39, 18)
    # lower galleries
    carve(g, 12, 19, 24, 20)
    carve(g, 28, 21, 44, 22)
    # exit grotto bottom-left
    carve(g, 4, h - 5, 8, h - 4)
    g[ey][ex] = EXIT
    bands = [(17, 9, 31, 9), (11, 4, 15, 8), (33, 4, 37, 8), (40, 6, 45, 12),
             (18, 17, 30, 17), (12, 18, 24, 18), (29, 20, 43, 20), (2, 6, 8, 12)]
    scatter(g, rng, w, h, BOULDER, 24, reserved, bands)
    gbands = [(6, 6, 45, 23), (16, 14, 32, 16), (12, 19, 24, 20), (28, 21, 44, 22)]
    scatter(g, rng, w, h, GEM, 24, reserved, gbands)
    return emit("Rolling Fields", "Level2", g, 16, 260)


def level3():
    w, h = 48, 26
    rng = random.Random(777)
    g = make_level(w, h)
    reserved = set()
    (px, py), (ex, ey) = (w - 4, 3), (w // 2, h - 3)
    carve(g, w - 6, 2, w - 3, 2)
    g[py][px] = START
    reserved |= {(x, 3) for x in range(w - 6, w - 2)} | {(px, py), (ex, ey)}
    # twin vaults linked by a low crawl
    carve(g, 6, 14, 20, 18)
    carve(g, 27, 8, 42, 12)
    carve(g, 21, 15, 26, 16)
    # deep lower mine
    carve(g, 8, 21, 40, 22)
    for x in range(14, 42, 7):
        g[22][x] = DIRT
    # exit crucible, guarded
    carve(g, w // 2 - 1, h - 5, w // 2 + 1, h - 4)
    g[ey][ex] = EXIT
    g[h - 4][w // 2 - 2] = BOULDER
    g[h - 4][w // 2 + 2] = BOULDER
    reserved |= {(w // 2 - 2, h - 4), (w // 2 + 2, h - 4)}
    bands = [(3, 4, 19, 10), (28, 6, 44, 7), (7, 13, 19, 13), (28, 13, 41, 13),
             (9, 20, 39, 20), (21, 14, 26, 14), (2, 16, 17, 19)]
    scatter(g, rng, w, h, BOULDER, 30, reserved, bands)
    gbands = [(4, 4, 44, 23), (6, 16, 20, 18), (27, 10, 42, 12), (8, 21, 40, 22)]
    scatter(g, rng, w, h, GEM, 30, reserved, gbands)
    return emit("Deep Vault", "Level3", g, 20, 320)


if __name__ == '__main__':
    parts = ["; Rockrun levels - generated by tools/genlevels.py",
             "; '#' wall  '.' dirt  ' ' empty  'O' boulder  'D' diamond  '@' player  'E' exit",
             ""]
    for fn in (level1, level2, level3):
        parts.append(fn())
        parts.append("")
    out = '\n'.join(parts)
    with open('/home/gokr/git/rockrun/data/config/levels.ini', 'w') as f:
        f.write(out)
    print("wrote levels.ini")
