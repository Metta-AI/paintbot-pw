"""Hand-shaped round cottages and planted circular beds for the local art review."""

import json, math, struct
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
    (0.24, 0.39, 0.22),
    (0.34, 0.49, 0.24),
    (0.42, 0.55, 0.27),
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
    while len(blob)%4: blob.append(0)
    data=struct.pack('<'+'I'*count,*range(count))
    view=len(views)
    views.append(dict(buffer=0,byteOffset=len(blob),byteLength=len(data)))
    blob.extend(data)
    access.append(dict(bufferView=view,componentType=5125,count=count,type='SCALAR'))
    return len(access)-1


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
        l = math.sqrt(sum(x * x for x in n)) or 1
        n = tuple(x / l for x in n)
        p, ns = batches.setdefault(col, ([], []))
        p.extend([a, b, c])
        ns.extend([n] * 3)

    def loft(rings, col, segments=48, offset=(0, 0, 0), wobble=0):
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
                tone = col + (j % 3 if col == 3 else 0)
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

    if name == "round-cottage":
        loft(
            [(0, 0), (1.02, 0), (1.05, 0.18), (0.99, 0.28), (0.94, 1.35), (0.90, 1.65)],
            0,
            wobble=0.025,
        )
        # Swept, layered moss roof with a bent peak; no rectangular roof planes.
        for level, (r, y) in enumerate(
            [
                (1.20, 1.38),
                (1.10, 1.62),
                (0.94, 1.87),
                (0.73, 2.13),
                (0.48, 2.38),
                (0.25, 2.59),
            ]
        ):
            loft(
                [(r, y), (r * 1.035, y + 0.04), (r * 0.76, y + 0.30)],
                3,
                wobble=0.035,
                offset=(level * 0.018, 0, 0),
            )
        loft([(0.22, 2.57), (0.07, 2.83), (0, 2.94)], 3, offset=(0.13, 0, 0))
        # Tall rounded door and circular, honey-lit windows facing the lane.
        disk(0, 0.64, 0.987, 0.33, 0.61, 2)
        disk(0, 0.64, 0.994, 0.265, 0.54, 7)
        disk(0.16, 0.61, 1.003, 0.035, 0.035, 8)
        for x in [-0.60, 0.60]:
            disk(x, 1.03, 0.80, 0.255, 0.27, 2)
            disk(x, 1.03, 0.815, 0.19, 0.20, 8)
            disk(x, 1.03, 0.825, 0.12, 0.13, 9)
        loft([(0, 0), (0.45, 0), (0.45, 0.14), (0, 0.14)], 10, offset=(0, 0, 1.0))
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
                    POSITION=addbuf(p, "VEC3", 3), NORMAL=addbuf(n, "VEC3", 3)
                ),
                indices=indices(len(p)),
                material=color,
                mode=4,
            )
        )
    meshes.append(dict(name=name, primitives=prim))
    nodes.append(dict(name=name, mesh=len(meshes) - 1))


for name in ["round-cottage", "round-garden"]:
    model(name)
doc = dict(
    asset=dict(version="2.0"),
    buffers=[dict(byteLength=len(blob))],
    bufferViews=views,
    accessors=access,
    materials=[
        dict(
            pbrMetallicRoughness=dict(
                baseColorFactor=[*c, 1], metallicFactor=0, roughnessFactor=1
            ),
            doubleSided=True,
        )
        for c in colors
    ],
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
