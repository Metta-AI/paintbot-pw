"""Hand-shaped round cottages and planted circular beds for the local art review."""

import json
import math
import struct
from pathlib import Path

root = Path(__file__).resolve().parents[3]
blob = bytearray()
views = []
access = []
meshes = []
nodes = []
colors = [
    (0.83, 0.68, 0.42),
    (0.91, 0.79, 0.53),
    (0.63, 0.38, 0.19),
    (0.80, 0.95, 0.70),
    (0.88, 1.0, 0.76),
    (0.96, 1.0, 0.82),
    (0.16, 0.24, 0.16),
    (0.27, 0.15, 0.09),
    (0.96, 0.65, 0.22),
    (0.12, 0.26, 0.28),
    (0.47, 0.31, 0.17),
    (0.28, 0.18, 0.11),
    (0.30, 0.55, 0.18),
    (0.89, 0.23, 0.10),
]


def addbuf(values, kind, components):
    while len(blob) % 4:
        blob.append(0)
    flat = [v for row in values for v in row]
    data = struct.pack("<" + "f" * len(flat), *flat)
    idx = len(views)
    views.append(dict(buffer=0, byteOffset=len(blob), byteLength=len(data)))
    blob.extend(data)
    a = dict(bufferView=idx, componentType=5126, count=len(values), type=kind)
    if kind == "VEC3":
        a.update(
            min=[min(v[i] for v in values) for i in range(3)],
            max=[max(v[i] for v in values) for i in range(3)],
        )
    access.append(a)
    return len(access) - 1


def indices(count):
    while len(blob) % 4:
        blob.append(0)
    data = struct.pack("<" + "I" * count, *range(count))
    view = len(views)
    views.append(dict(buffer=0, byteOffset=len(blob), byteLength=len(data)))
    blob.extend(data)
    access.append(dict(bufferView=view, componentType=5125, count=count, type="SCALAR"))
    return len(access) - 1


def model(name):
    batches = {}

    def tri(a, b, c, col):
        u = [b[i] - a[i] for i in range(3)]
        v = [c[i] - a[i] for i in range(3)]
        n = [
            u[1] * v[2] - u[2] * v[1],
            u[2] * v[0] - u[0] * v[2],
            u[0] * v[1] - u[1] * v[0],
        ]
        length = math.sqrt(sum(x * x for x in n)) or 1
        n = tuple(x / length for x in n)
        p, ns = batches.setdefault(col, ([], []))
        p.extend([a, b, c])
        ns.extend([n] * 3)

    def loft(rings, col, segments=48, offset=(0, 0, 0), wobble=0):
        dense = []
        for a, b in zip(rings, rings[1:]):
            for j in range(5):
                f = j / 5
                dense.append((a[0] * (1 - f) + b[0] * f, a[1] * (1 - f) + b[1] * f))
        rings = dense + [rings[-1]]

        def p(k, j):
            r, y = rings[k]
            t = 2 * math.pi * j / segments
            r *= 1 + wobble * math.sin(3 * t + 0.7) + wobble * 0.4 * math.cos(5 * t)
            return (
                offset[0] + r * math.cos(t),
                offset[1] + y,
                offset[2] + r * math.sin(t),
            )

        for k in range(len(rings) - 1):
            for j in range(segments):
                a, b, c, d = p(k, j), p(k, j + 1), p(k + 1, j + 1), p(k + 1, j)
                tone = col
                tri(a, c, b, tone)
                tri(a, d, c, tone)

    def disk(cx, cy, z, rx, ry, col):
        for j in range(40):
            a = 2 * math.pi * j / 40
            b = 2 * math.pi * (j + 1) / 40
            tri(
                (cx, cy, z),
                (cx + rx * math.cos(a), cy + ry * math.sin(a), z),
                (cx + rx * math.cos(b), cy + ry * math.sin(b), z),
                col,
            )

    if name != "round-garden":
        bark = name == "stump-house"
        loft(
            [(0, 0), (1.03, 0), (1.06, 0.15), (0.99, 0.28), (0.92, 1.20), (0.86, 1.45)],
            10 if bark else 0,
            wobble=0.06,
        )
        if name == "mushroom-house":
            loft(
                [
                    (0, 1.30),
                    (1.38, 1.30),
                    (1.48, 1.45),
                    (1.30, 1.78),
                    (0.91, 2.03),
                    (0.42, 2.18),
                    (0, 2.22),
                ],
                2,
                wobble=0.025,
            )
            for j in range(9):
                a = j * 2.4
                r = 0.40 + 0.1 * (j % 6)
                loft(
                    [(0, 0), (0.12, 0.025), (0, 0.05)],
                    1,
                    offset=(r * math.cos(a), 2.17 - r * 0.26, r * math.sin(a)),
                )
        elif name == "spiral-house":
            loft(
                [
                    (1.25, 1.24),
                    (1.35, 1.35),
                    (1.18, 1.62),
                    (0.8, 1.92),
                    (0.4, 2.16),
                    (0.1, 2.35),
                ],
                3,
                wobble=0.07,
            )
            for j in range(26):
                a = j * 0.30
                r = 0.5 * (1 - j / 30)
                loft(
                    [(0.10, 0), (0.08, 0.08)],
                    3,
                    segments=10,
                    offset=(0.3 + r * math.cos(a), 2.2 + j * 0.025, r * math.sin(a)),
                )
        elif bark:
            for j in range(13):
                a = j * 2 * math.pi / 13
                loft(
                    [(0.16, 0), (0.12, 0.75), (0.08, 1.5)],
                    2,
                    segments=7,
                    offset=(0.86 * math.cos(a), 0, 0.86 * math.sin(a)),
                )
            loft(
                [(1.17, 1.25), (1.22, 1.36), (1.05, 1.58), (0.65, 1.82), (0, 1.98)],
                3,
                wobble=0.08,
            )
        else:
            loft(
                [
                    (1.18, 1.23),
                    (1.28, 1.33),
                    (1.25, 1.48),
                    (1.03, 1.74),
                    (0.68, 1.91),
                    (0, 2.03),
                ],
                3,
                wobble=0.065,
            )
            loft(
                [(0.23, 0), (0.22, 0.6), (0.28, 0.65)],
                0,
                segments=14,
                offset=(-0.35, 1.67, -0.25),
            )
        for x in [-0.60, 0.60]:
            disk(x, 0.91, 0.80, 0.23, 0.25, 2)
            disk(x, 0.91, 0.815, 0.165, 0.185, 8)
    else:
        loft(
            [(0, 0), (1, 0), (1, 0.25), (0.93, 0.30), (0, 0.30)],
            10,
            segments=40,
            wobble=0.05,
        )
        loft(
            [(0, 0.30), (0.90, 0.30), (0.9, 0.32), (0, 0.32)],
            11,
            segments=40,
            wobble=0.03,
        )
        for i in range(14):
            a = i * 2.4
            r = 0.16 + 0.058 * (i % 10)
            x = r * math.cos(a)
            z = r * math.sin(a)
            loft(
                [(0, 0), (0.12, 0.07), (0.15, 0.16), (0.10, 0.24), (0, 0.28)],
                12,
                segments=8,
                offset=(x, 0.31, z),
            )
            if i % 3 == 0:
                loft(
                    [(0, 0), (0.09, 0.06), (0, 0.13)],
                    13,
                    segments=10,
                    offset=(x, 0.38, z + 0.06),
                )
    prim = []
    for color, (p, n) in batches.items():
        prim.append(
            dict(
                attributes=dict(
                    POSITION=addbuf(p, "VEC3", 3),
                    NORMAL=addbuf(n, "VEC3", 3),
                    TEXCOORD_0=addbuf(
                        [
                            (
                                (v[0] * 0.32 + 0.5, v[2] * 0.32 + 0.5)
                                if color in [3, 4, 5]
                                else (
                                    math.atan2(v[2], v[0]) / (2 * math.pi) + 0.5,
                                    v[1] / 3,
                                )
                            )
                            for v in p
                        ],
                        "VEC2",
                        2,
                    ),
                ),
                indices=indices(len(p)),
                material=color,
                mode=4,
            )
        )
    meshes.append(dict(name=name, primitives=prim))
    nodes.append(dict(name=name, mesh=len(meshes) - 1))


for name in [
    "round-cottage",
    "mushroom-house",
    "stump-house",
    "spiral-house",
    "round-garden",
]:
    model(name)
images = []
for name in ["mossy-building-stone-1.rgb.png", "grass-2.rgb.png"]:
    while len(blob) % 4:
        blob.append(0)
    data = (root.parent / "polyworld_data/terrain/tiles" / name).read_bytes()
    images.append(dict(bufferView=len(views), mimeType="image/png"))
    views.append(dict(buffer=0, byteOffset=len(blob), byteLength=len(data)))
    blob.extend(data)
materials = []
for i, c in enumerate(colors):
    pbr = dict(baseColorFactor=[*c, 1], metallicFactor=0, roughnessFactor=1)
    if i in [0, 1]:
        pbr["baseColorTexture"] = dict(index=0)
    if i in [3, 4, 5]:
        pbr["baseColorTexture"] = dict(index=1)
    materials.append(dict(pbrMetallicRoughness=pbr, doubleSided=True))
doc = dict(
    asset=dict(version="2.0"),
    buffers=[dict(byteLength=len(blob))],
    bufferViews=views,
    accessors=access,
    materials=materials,
    images=images,
    samplers=[dict(wrapS=10497, wrapT=10497)],
    textures=[dict(source=0, sampler=0), dict(source=1, sampler=0)],
    meshes=meshes,
    nodes=nodes,
    scenes=[dict(nodes=list(range(len(nodes))))],
    scene=0,
)
h = json.dumps(doc, separators=(",", ":")).encode()
h += b" " * (-len(h) % 4)
blob += b"\0" * (-len(blob) % 4)
(root / "tmp/round-village.glb").write_bytes(
    struct.pack("<III", 0x46546C67, 2, 28 + len(h) + len(blob))
    + struct.pack("<II", len(h), 0x4E4F534A)
    + h
    + struct.pack("<II", len(blob), 0x004E4942)
    + blob
)
