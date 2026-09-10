"""Sprite-v1 semantic observations for unmodified Paintbot WASM policies.

Polyworld units are 1/5 of a legacy map pixel. No raster renderer or engine
internals are exposed to the guest; enemy actors respect range and cover.
"""

from functools import lru_cache
import math
import struct

COLORS = ("red", "blue")
SCALE = 5


def literal_snappy(raw):
    n = len(raw)
    out = bytearray()
    v = n
    while v >= 128:
        out.append((v & 127) | 128)
        v >>= 7
    out.append(v)
    # A Snappy literal: tag 60 + 32-bit little-endian length for large maps.
    size = max(1, ((n - 1).bit_length() + 7) // 8)
    out.append((59 + size) << 2)
    out.extend((n - 1).to_bytes(size, "little"))
    out.extend(raw)
    return bytes(out)


def land_wave(value, period, amplitude):
    phase = value % period
    half = period // 2
    t = phase % half
    magnitude = 4 * t * (half - t) * amplitude // (half * half)
    return magnitude if phase < half else -magnitude


def island_margin(x, z):
    nx, nz = abs(x - 3200) * 1000 // 5800, abs(z - 2000) * 1000 // 3050
    return (
        980
        - int(math.sqrt(math.sqrt(nx**4 + nz**4)))
        + land_wave(x + z, 2600, 28)
        + land_wave(x - z + 1100, 3700, 22)
    )


def land_coordinates(x, z):
    return (
        x + land_wave(z + 350, 2900, 360) + land_wave(x + z, 1700, 70),
        z + land_wave(x + 600, 3200, 230) + land_wave(z - x, 1900, 55),
    )


def forest_height(x, z):
    height = 0
    for cx, cz, h, r in [
        (-1900, 700, 600, 1100),
        (-1400, 3100, 480, 1000),
        (800, -900, 380, 1000),
        (3600, -900, 460, 1100),
        (5700, -800, 330, 900),
    ]:
        for px, pz in [(cx, cz), (6400 - cx, 4000 - cz)]:
            d2 = (x - px) ** 2 + (z - pz) ** 2
            height = max(height, max(0, h * (r * r - d2) // (r * r)))
    route = min(abs(x + 1700), abs(x - 8100), abs(z + 650), abs(z - 4650))
    height = height * (300 + min(route, 500)) // 800
    edge = max(0, -x, x - 6400, -z, z - 4000)
    return height * min(edge, 500) // 500


@lru_cache(maxsize=65536)
def terrain_height(
    x, z, wide=False, wilderness=False, deep=False, organic=False, island=False
):
    if island:
        return min(
            terrain_height(x, z, wide, wilderness, deep, organic),
            (island_margin(x, z) - 35) * 5,
        )
    if organic:
        x, z = land_coordinates(x, z)
    if wilderness and (x < 0 or x > 6400 or z < 0 or z > 4000):
        if deep:
            return forest_height(x, z)
        h = max(
            max(0, 180 - (abs(x - cx) + abs(z - cz)) // 3)
            for cx, cz in [
                (-500, 900),
                (-500, 3100),
                (6900, 900),
                (6900, 3100),
                (1700, -250),
                (4700, 4250),
            ]
        )
        return min(h, min(abs(x), abs(x - 6400), abs(z), abs(z - 4000)) // 2)

    def raised(x, z):
        if 1000 <= x <= 2200 and 200 <= z <= 1200:
            dx = max(abs(x - 1600) - 450, 0)
            dz = max(abs(z - 700) - 350, 0)
            if dx * dx + dz * dz <= 150 * 150:
                return 250
        if (500 if wide else 750) <= z <= (1100 if wide else 950):
            if 600 <= x < 1000:
                return (x - 600) * 250 // 400
            if 2200 < x <= 2800:
                return (2800 - x) * 250 // 600
        return 0

    h = max(raised(x, z), raised(6400 - x, 4000 - z))
    if h:
        return h
    along = max(0, min(400, x - 1400, 5000 - x))
    across = max(0, min(250, 500 - abs(z - 2000)))
    crossing = max(0, min(240, abs(x - 3200) - 160))
    return -(150 * along * across * crossing // (400 * 250 * 240))


def elevation(w, p):
    if w.get("rulesVersion", 0) < 9:
        return 0
    h = terrain_height(
        p["x"],
        p["z"],
        w.get("rulesVersion", 0) >= 11,
        w.get("rulesVersion", 0) >= 12,
        w.get("rulesVersion", 0) >= 14,
        w.get("rulesVersion", 0) >= 15,
        w.get("rulesVersion", 0) >= 16,
    )
    for t in w.get("trenches", []):
        if t["x"] <= p["x"] < t["x"] + t["w"] and t["z"] <= p["z"] < t["z"] + t["h"]:
            return h - 60
    return h


def clear(w, a, b):
    # The sprite frame queries the same pair for body, equipment and effects.
    cache = w.setdefault("_los_cache", {})
    key = (a["x"], a["z"], b["x"], b["z"])
    if key not in cache:
        cache[key] = _clear(w, a, b)
    return cache[key]


def _clear(w, a, b):
    layered = w.get("rulesVersion", 0) >= 9
    origin_height = elevation(w, a) + 120 if layered else 0
    height_delta = elevation(w, b) - elevation(w, a) if layered else 0
    steps = max(abs(b["x"] - a["x"]), abs(b["z"] - a["z"])) // 25 + 1
    # Only obstacles intersecting the ray bounds can block its samples.
    min_x, max_x = sorted((a["x"], b["x"]))
    min_z, max_z = sorted((a["z"], b["z"]))
    obstacles = [c for c in w["cover"]
                 if c["x"] <= max_x and c["x"] + c["w"] >= min_x
                 and c["z"] <= max_z and c["z"] + (c["h"] or c["w"]) >= min_z]
    for i in range(1, steps + 1):
        x = a["x"] + (b["x"] - a["x"]) * i // steps
        z = a["z"] + (b["z"] - a["z"]) * i // steps
        if layered:
            eye = origin_height + int(height_delta * i / steps)
            if elevation(w, {"x": x, "z": z}) > eye:
                return False
        if any(
            (
                (x - c["x"] - c["w"] / 2) ** 2 + (z - c["z"] - c["w"] / 2) ** 2
                < (c["w"] / 2) ** 2
            )
            if c["h"] == 0
            else (c["x"] < x < c["x"] + c["w"] and c["z"] < z < c["z"] + c["h"])
            for c in obstacles
        ):
            return False
    return True


def visible(w, slot, other):
    cog = w["cogs"][other]
    b = cog["pos"]
    if cog["hp"] <= 0 or w["cogs"][slot]["hp"] <= 0:
        return False
    if slot == other:
        return True
    return can_see_point(w, slot, b)


def can_see_point(w, slot, b):
    a = w["cogs"][slot]["pos"]
    aim = w["cogs"][slot]["aim"]
    if aim == {"x": 0, "z": 0}:
        aim = {"x": 5440 if slot % 2 == 0 else 960, "z": 2000}
    fx, fz = aim["x"] - a["x"], aim["z"] - a["z"]
    dx, dz = b["x"] - a["x"], b["z"] - a["z"]
    distance = dx * dx + dz * dz
    dot = fx * dx + fz * dz
    return (
        distance == 0 or (dot > 0 and 4 * dot * dot >= (fx * fx + fz * fz) * distance)
    ) and clear(w, a, b)


@lru_cache(maxsize=4)
def walkability(
    cover,
    layered=False,
    wide=False,
    wilderness=False,
    deep=False,
    organic=False,
    island=False,
):
    width, height = (2400, 1280) if deep else (1600, 960) if wilderness else (1280, 800)
    ox, oz = (2800, 1200) if deep else (800, 400) if wilderness else (0, 0)
    raw = bytearray(width * height * 4)
    for z in range(11, height - 11):
        start = (z * width + 11) * 4 + 3
        raw[start : (z * width + width - 11) * 4 : 4] = b"\xff" * (width - 22)
    for cx, cz, cw, ch in cover:
        cx, cz = cx + ox, cz + oz
        if ch == 0:
            r = cw / 2
            for z in range(max(0, cz // 5), min(height, (cz + cw) // 5 + 1)):
                dz = z * 5 - cz - r
                if abs(dz) >= r:
                    continue
                half = math.sqrt(r * r - dz * dz)
                left = max(0, math.ceil((cx + r - half) / 5))
                right = min(width, math.ceil((cx + r + half) / 5))
                raw[(z * width + left) * 4 + 3 : (z * width + right) * 4 : 4] = (
                    b"\x00" * (right - left)
                )
            continue
        left, right = max(0, cx // 5), min(width, (cx + cw) // 5 + 1)
        for z in range(max(0, cz // 5), min(height, (cz + ch) // 5 + 1)):
            raw[(z * width + left) * 4 + 3 : (z * width + right) * 4 : 4] = b"\x00" * (
                right - left
            )
    if island:
        for z in range(height):
            for x in range(width):
                if island_margin(x * 5 - ox, z * 5 - oz) < 59:
                    raw[(z * width + x) * 4 + 3] = 0
    if layered:
        # Reuse the height raster for all four slope probes. Computing the
        # island's procedural hills five times per pixel stalled hosted startup.
        from array import array

        heights = array(
            "i",
            (
                terrain_height(
                    x * 5 - ox, z * 5 - oz, wide, wilderness, deep, organic, island
                )
                for z in range(height)
                for x in range(width)
            ),
        )
        for z in range(11, height - 11):
            for x in range(11, width - 11):
                i = z * width + x
                if not raw[i * 4 + 3]:
                    continue
                h = heights[i]
                if (
                    abs(heights[i + 11] - h) > 80
                    or abs(heights[i - 11] - h) > 80
                    or abs(heights[i + 11 * width] - h) > 80
                    or abs(heights[i - 11 * width] - h) > 80
                ):
                    raw[i * 4 + 3] = 0
    return literal_snappy(raw)


class SpriteView:
    def __init__(self, slot):
        self.slot = slot
        self.angle = 0 if slot % 2 == 0 else 128
        self.mask = 0
        self.initial = True

    def frame(self, w):
        wilderness = w.get("rulesVersion", 0) >= 12
        deep = w.get("rulesVersion", 0) >= 14
        organic = w.get("rulesVersion", 0) >= 15
        ox, oz = (560, 240) if deep else (160, 80) if wilderness else (0, 0)
        width, height = (
            (2400, 1280) if deep else (1600, 960) if wilderness else (1280, 800)
        )
        out = bytearray(b"\x04")
        obj = 0

        def sprite(sid, label, width=1, height=1, pixels=b""):
            label = label.encode()
            out.extend(
                struct.pack("<BHHHI", 1, sid, width, height, len(pixels))
                + pixels
                + struct.pack("<H", len(label))
                + label
            )

        def item(label, p, width=1, height=1):
            nonlocal obj
            obj += 1
            sid = obj + 10
            sprite(sid, label, width, height)
            out.extend(
                struct.pack(
                    "<BHhhhBH",
                    2,
                    obj + 10,
                    p["x"] // 5 + ox - width // 2,
                    p["z"] // 5 + oz - height // 2,
                    0,
                    0,
                    sid,
                )
            )

        if self.initial:
            sprite(
                2,
                "walkability map",
                width,
                height,
                walkability(
                    tuple((c["x"], c["z"], c["w"], c["h"]) for c in w["cover"]),
                    w.get("rulesVersion", 0) >= 9,
                    w.get("rulesVersion", 0) >= 11,
                    wilderness,
                    deep,
                    organic,
                    w.get("rulesVersion", 0) >= 16,
                ),
            )
            sprite(1, "map", width, height)
            self.initial = False
        out.extend(struct.pack("<BHhhhBH", 2, 1, 0, 0, 0, 0, 1))
        me = w["cogs"][self.slot]
        for i, c in enumerate(w["cogs"]):
            if not visible(w, self.slot, i):
                continue
            label = (
                ("self " if i == self.slot else "player ")
                + COLORS[i % 2]
                + " "
                + ("right" if i % 2 == 0 else "left")
            )
            item(label, c["pos"], 12, 12)
            item(
                "hp "
                + str(c["hp"])
                + "/3"
                + (
                    " shield " + str(w["equipment"][i]["armor"])
                    if w.get("equipment") and w["equipment"][i]["armor"]
                    else ""
                ),
                {"x": c["pos"]["x"], "z": c["pos"]["z"] - 65},
                12,
                2,
            )
        for i, e in enumerate(w.get("equipment", [])):
            if not visible(w, self.slot, i):
                continue
            p = w["cogs"][i]["pos"]
            if e["grenade"]:
                item("grenade carried", p)
            if e["sprayCan"]:
                item("spray can carried", p)
                item("cog spray can " + COLORS[i % 2], p)
            if e["armor"]:
                item("shield", p)
            item("lives " + str(e["lives"]), p)
            if e["burst"]:
                for n in range(1, 6):
                    puff = {
                        key: p[key] + e["sprayAim"][key] * n // 5 for key in ("x", "z")
                    }
                    if clear(w, p, puff) and can_see_point(w, self.slot, puff):
                        item("spray paint puff", puff, 8 + n * 8, 8 + n * 8)
            if e["charge"]:
                aim = w["cogs"][i]["aim"]
                dx, dz = aim["x"] - p["x"], aim["z"] - p["z"]
                length = max(1, math.isqrt(dx * dx + dz * dz))
                reach = 150 + (1280 - 150) * e["charge"] // 24
                item(
                    "throw target",
                    {
                        "x": p["x"] + dx * reach // length,
                        "z": p["z"] + dz * reach // length,
                    },
                    104,
                    104,
                )
        for pickup in w.get("pickups", []):
            if pickup["readyAt"] <= w["tick"] and can_see_point(
                w, self.slot, pickup["pos"]
            ):
                label = {
                    "grenadePickup": "grenade",
                    "sprayPickup": "spray can",
                    "medkitPickup": "med kit",
                    "armorPickup": "shield",
                }[pickup["kind"]]
                item(label, pickup["pos"], 14, 14)
        for trench in w.get("trenches", []):
            item(
                "trench",
                {
                    "x": trench["x"] + trench["w"] // 2,
                    "z": trench["z"] + trench["h"] // 2,
                },
                trench["w"] // 5,
                trench["h"] // 5,
            )
        for grenade in w.get("grenades", []):
            age = w["tick"] - grenade["releasedAt"]
            length = max(1, grenade["landsAt"] - grenade["releasedAt"])
            p = {
                key: grenade["start"][key]
                + (grenade["target"][key] - grenade["start"][key]) * age // length
                for key in ("x", "z")
            }
            if can_see_point(w, self.slot, p):
                item("grenade air", p, 10, 10)
        for blast in w.get("blasts", []):
            if can_see_point(w, self.slot, blast["pos"]):
                item(
                    "blast stage " + str(min(3, (w["tick"] - blast["tick"]) // 6)),
                    blast["pos"],
                    104,
                    104,
                )
        item("own aim " + str(self.angle), me["pos"])
        item(f"game teams 2 map {width}x{height}", me["pos"])
        item("fire icon" if me["cooldown"] <= 1 else "fire icon cooldown", me["pos"])
        controls = w.get("controlHearts", [])
        for i, heart in enumerate(controls):
            owner = heart["owner"]
            item(f"control heart {i} owner {owner}", heart["pos"], 20, 20)
        for side, color in enumerate(COLORS):
            h = w["hearts"][side]
            if controls and side != self.slot % 2:
                candidates = [
                    (i, h)
                    for i, h in enumerate(controls)
                    if h["owner"] != self.slot % 2
                ]
                if candidates:
                    _, target = min(
                        candidates,
                        key=lambda pair: (pair[1]["pos"]["x"] - me["pos"]["x"]) ** 2
                        + (pair[1]["pos"]["z"] - me["pos"]["z"]) ** 2
                        - (12000000 if pair[0] == 2 + (self.slot // 2) % 8 else 0),
                    )
                    h = {"pos": target["pos"], "carrier": -1}

            carrier = h["carrier"]
            if carrier < 0 or visible(w, self.slot, carrier):
                item(
                    color + " flag" + (" planted" if carrier < 0 else ""),
                    h["pos"],
                    12,
                    12,
                )
            x = 192 if side == 0 else 1088
            item(
                f"endzone {color} rect {x + ox - 40},{360 + oz} {x + ox + 40},{440 + oz}",
                {"x": x * 5, "z": 2000},
            )
        for message in w.get("heard", [[] for _ in range(16)])[self.slot]:
            item(
                "shout " + str(message["slot"]) + " " + message["text"], message["pos"]
            )
        return bytes(out)

    def command(self, w, replies):
        for reply in replies:
            if reply[0] == 0x84:
                self.mask = reply[1]
        # Sprite aim buttons: B turns clockwise; Select counter-clockwise.
        self.angle = (
            self.angle + (5 if self.mask & 64 else 0) - (5 if self.mask & 16 else 0)
        ) % 256
        p = w["cogs"][self.slot]["pos"]
        a = self.angle * 2 * math.pi / 256
        dx = bool(self.mask & 8) - bool(self.mask & 4)
        dz = bool(self.mask & 2) - bool(self.mask & 1)
        return {
            "walk": True,
            "direct": True,
            "shoot": bool(self.mask & 32),
            "chargeGrenade": bool(self.mask & 128),
            "goal": {"x": p["x"] + dx * 100, "z": p["z"] + dz * 100},
            "aim": {
                "x": p["x"] + round(math.cos(a) * 1800),
                "z": p["z"] - round(math.sin(a) * 1800),
            },
        }
