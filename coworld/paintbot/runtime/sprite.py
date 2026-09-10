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


def clear(w, a, b):
    steps = max(abs(b["x"] - a["x"]), abs(b["z"] - a["z"])) // 25 + 1
    for i in range(1, steps + 1):
        x = a["x"] + (b["x"] - a["x"]) * i // steps
        z = a["z"] + (b["z"] - a["z"]) * i // steps
        if any(
            c["x"] < x < c["x"] + c["w"] and c["z"] < z < c["z"] + c["h"]
            for c in w["cover"]
        ):
            return False
    return True


def visible(w, slot, other):
    a = w["cogs"][slot]["pos"]
    cog = w["cogs"][other]
    b = cog["pos"]
    if cog["hp"] <= 0 or w["cogs"][slot]["hp"] <= 0:
        return False
    if slot == other:
        return True
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
def walkability(cover):
    raw = bytearray(1280 * 800 * 4)
    for z in range(11, 789):
        start = (z * 1280 + 11) * 4 + 3
        raw[start : (z * 1280 + 1269) * 4 : 4] = b"\xff" * 1258
    for cx, cz, cw, ch in cover:
        left, right = max(0, cx // 5), min(1280, (cx + cw) // 5 + 1)
        for z in range(max(0, cz // 5), min(800, (cz + ch) // 5 + 1)):
            raw[(z * 1280 + left) * 4 + 3 : (z * 1280 + right) * 4 : 4] = b"\x00" * (
                right - left
            )
    return literal_snappy(raw)


class SpriteView:
    def __init__(self, slot):
        self.slot = slot
        self.angle = 0 if slot % 2 == 0 else 128
        self.mask = 0
        self.initial = True

    def frame(self, w):
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
                    p["x"] // 5 - width // 2,
                    p["z"] // 5 - height // 2,
                    0,
                    0,
                    sid,
                )
            )

        if self.initial:
            sprite(
                2,
                "walkability map",
                1280,
                800,
                walkability(
                    tuple((c["x"], c["z"], c["w"], c["h"]) for c in w["cover"])
                ),
            )
            sprite(1, "map", 1280, 800)
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
                "hp " + str(c["hp"]) + "/3",
                {"x": c["pos"]["x"], "z": c["pos"]["z"] - 65},
                12,
                2,
            )
        item("own aim " + str(self.angle), me["pos"])
        item("game teams 2 map 1280x800", me["pos"])
        item("fire icon" if me["cooldown"] <= 1 else "fire icon cooldown", me["pos"])
        for side, color in enumerate(COLORS):
            h = w["hearts"][side]
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
                f"endzone {color} rect {x - 40},360 {x + 40},440",
                {"x": x * 5, "z": 2000},
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
            "goal": {"x": p["x"] + dx * 100, "z": p["z"] + dz * 100},
            "aim": {
                "x": p["x"] + round(math.cos(a) * 1800),
                "z": p["z"] - round(math.sin(a) * 1800),
            },
        }
