"""Build the approved Paint Crew cog as a textured-color, animated GLB.
Rounded screen shell, cyan face, two rubber wheels, metal struts and tool arms.
No human character meshes are used.
"""

import json, math, struct
from pathlib import Path

root = Path(__file__).resolve().parents[3]


def build(team):
    blob = bytearray()
    views = []
    accessors = []
    meshes = []
    nodes = []
    colors = [
        ([0.87, 0.19, 0.12, 1] if team == "red" else [0.10, 0.48, 0.86, 1]),
        [0.065, 0.085, 0.09, 1],
        [0.24, 0.28, 0.28, 1],
        [0.54, 0.48, 0.32, 1],
        [0.025, 0.12, 0.15, 1],
        [0.15, 0.96, 1, 1],
        [0.88, 0.84, 0.67, 1],
    ]
    materials = [
        {
            "name": n,
            "pbrMetallicRoughness": {
                "baseColorFactor": c,
                "metallicFactor": 0.25 if i in [2, 3] else 0,
                "roughnessFactor": 0.8,
            },
            **({"emissiveFactor": [0.12, 0.7, 0.8]} if i == 5 else {}),
        }
        for i, (n, c) in enumerate(
            zip(
                ["enamel", "rubber", "steel", "brass", "screen", "cyan", "scuffs"],
                colors,
            )
        )
    ]

    def accessor(values, typ, components, fmt, ctype):
        while len(blob) % 4:
            blob.append(0)
        raw = struct.pack(
            "<" + fmt * len(values) * components,
            *(x for row in values for x in (row if components > 1 else [row])),
        )
        views.append({"buffer": 0, "byteOffset": len(blob), "byteLength": len(raw)})
        blob.extend(raw)
        a = {
            "bufferView": len(views) - 1,
            "componentType": ctype,
            "count": len(values),
            "type": typ,
        }
        if typ == "VEC3":
            a.update(
                min=[min(v[i] for v in values) for i in range(3)],
                max=[max(v[i] for v in values) for i in range(3)],
            )
        accessors.append(a)
        return len(accessors) - 1

    def mesh(name, verts, norms, idx, material, center):
        meshes.append(
            {
                "name": name,
                "primitives": [
                    {
                        "attributes": {
                            "POSITION": accessor(verts, "VEC3", 3, "f", 5126),
                            "NORMAL": accessor(norms, "VEC3", 3, "f", 5126),
                        },
                        "indices": accessor(idx, "SCALAR", 1, "H", 5123),
                        "material": material,
                    }
                ],
            }
        )
        nodes.append({"name": name, "mesh": len(meshes) - 1, "translation": center})
        return len(nodes) - 1

    def box(name, center, size, material, r=0.04):
        verts = []
        norms = []
        idx = []
        half = [x / 2 for x in size]
        r = min(r, min(half) * 0.9)
        for axis in range(3):
            u = (axis + 1) % 3
            v = (axis + 2) % 3
            for sign in [-1, 1]:
                start = len(verts)
                n = 6
                for j in range(n + 1):
                    for i in range(n + 1):
                        p = [0.0, 0.0, 0.0]
                        p[axis] = sign * half[axis]
                        p[u] = (2 * i / n - 1) * half[u]
                        p[v] = (2 * j / n - 1) * half[v]
                        core = [
                            max(-half[k] + r, min(half[k] - r, p[k])) for k in range(3)
                        ]
                        d = [p[k] - core[k] for k in range(3)]
                        length = math.sqrt(sum(x * x for x in d))
                        normal = [x / length for x in d]
                        verts.append([core[k] + normal[k] * r for k in range(3)])
                        norms.append(normal)
                for j in range(n):
                    for i in range(n):
                        a = start + j * (n + 1) + i
                        b = a + 1
                        c = a + n + 1
                        d = c + 1
                        idx.extend(
                            [a, b, d, a, d, c] if sign > 0 else [a, d, b, a, c, d]
                        )
        return mesh(name, verts, norms, idx, material, center)

    def wheel(name, x):
        verts = []
        norms = []
        idx = []
        for i in range(25):
            a = i * math.tau / 24
            for j in range(9):
                b = j * math.tau / 8
                radius = 0.27 + 0.075 * math.cos(b)
                verts.append(
                    [0.075 * math.sin(b), radius * math.cos(a), radius * math.sin(a)]
                )
                norms.append(
                    [math.sin(b), math.cos(b) * math.cos(a), math.cos(b) * math.sin(a)]
                )
        for i in range(24):
            for j in range(8):
                a = i * 9 + j
                idx.extend([a, a + 9, a + 10, a, a + 10, a + 1])
        return mesh(name, verts, norms, idx, 1, [x, 0.345, 0])

    wheels = []
    for side in [-1, 1]:
        wheels.append(wheel("wheel-" + str(side), side * 0.47))
        box("axle", [side * 0.43, 0.345, 0], [0.2, 0.12, 0.12], 3)
        box("strut", [side * 0.32, 0.63, -0.04], [0.11, 0.55, 0.13], 2)
        box("fender", [side * 0.45, 0.64, 0], [0.16, 0.12, 0.43], 0)
        box("shoulder", [side * 0.47, 1.22, 0.01], [0.2, 0.22, 0.23], 3)
        box("arm", [side * 0.55, 0.99, 0.11], [0.11, 0.4, 0.13], 2)
        box("hand", [side * 0.54, 0.83, 0.25], [0.15, 0.14, 0.18], 3)
    box("chassis", [0, 0.86, -0.02], [0.58, 0.3, 0.46], 2, 0.10)
    box("shell", [0, 1.35, 0], [0.88, 0.7, 0.63], 0, 0.14)
    box("screen-rim", [0, 1.28, 0.302], [0.73, 0.45, 0.065], 3, 0.05)
    box("screen", [0, 1.28, 0.343], [0.66, 0.38, 0.035], 4, 0.05)
    for x in [-0.17, 0.17]:
        box("eye", [x, 1.32, 0.366], [0.105, 0.10, 0.025], 5, 0.045)
    for x, y in [(-0.055, 1.20), (0, 1.18), (0.055, 1.20)]:
        box("smile", [x, y, 0.367], [0.06, 0.03, 0.02], 5, 0.01)
    box("marker", [0.53, 0.91, 0.47], [0.10, 0.10, 0.5], 2)
    box("hopper", [0.53, 1.06, 0.43], [0.22, 0.20, 0.27], 0, 0.05)
    box("tank", [0, 1.2, -0.40], [0.3, 0.44, 0.22], 3, 0.09)
    for i in range(10):
        # Small cream nicks break up the enameled shell without obscuring the face.
        x = ((i * 37) % 17 / 17 - 0.5) * 0.65
        y = 1.48 + ((i * 7) % 9) / 90
        box(
            "enamel-nick",
            [x, y, 0.314],
            [0.025 + (i % 3) * 0.01, 0.012, 0.012],
            6,
            0.003,
        )
    times = accessor([0.0, 0.25, 0.5, 0.75, 1.0], "SCALAR", 1, "f", 5126)
    rot = accessor(
        [
            [math.sin(a / 2), 0, 0, math.cos(a / 2)]
            for a in [0, math.pi / 2, math.pi, 3 * math.pi / 2, 2 * math.pi]
        ],
        "VEC4",
        4,
        "f",
        5126,
    )
    animations = [
        {
            "name": "Roll",
            "samplers": [{"input": times, "output": rot, "interpolation": "LINEAR"}],
            "channels": [
                {"sampler": 0, "target": {"node": i, "path": "rotation"}}
                for i in wheels
            ],
        }
    ]
    doc = {
        "asset": {"version": "2.0", "generator": "Paint Crew Cog"},
        "buffers": [{"byteLength": len(blob)}],
        "bufferViews": views,
        "accessors": accessors,
        "materials": materials,
        "meshes": meshes,
        "nodes": nodes,
        "animations": animations,
        "scenes": [{"nodes": list(range(len(nodes)))}],
        "scene": 0,
    }
    header = json.dumps(doc, separators=(",", ":")).encode()
    header += b" " * ((-len(header)) % 4)
    blob += b"\0" * ((-len(blob)) % 4)
    out = root / f"tmp/paintbot-cog-{team}.glb"
    out.write_bytes(
        struct.pack("<III", 0x46546C67, 2, 28 + len(header) + len(blob))
        + struct.pack("<II", len(header), 0x4E4F534A)
        + header
        + struct.pack("<II", len(blob), 0x004E4942)
        + blob
    )


for team in ["red", "blue"]:
    build(team)
