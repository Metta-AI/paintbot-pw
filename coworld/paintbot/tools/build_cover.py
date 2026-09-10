"""Build a masonry bunker GLB with exact 2.6 x 4.2 collision dimensions."""

import os
import json
import struct
from pathlib import Path

root = Path(__file__).resolve().parents[3]
vertices, normals, uvs, indices = [], [], [], []


def box(x, y, z, width, height, depth):
    points = [
        (x - width / 2, y, z - depth / 2),
        (x + width / 2, y, z - depth / 2),
        (x + width / 2, y, z + depth / 2),
        (x - width / 2, y, z + depth / 2),
    ]
    points += [(a, b + height, c) for a, b, c in points]
    for face, normal in [
        ([0, 3, 2, 1], (0, -1, 0)),
        ([4, 5, 6, 7], (0, 1, 0)),
        ([0, 1, 5, 4], (0, 0, -1)),
        ([1, 2, 6, 5], (1, 0, 0)),
        ([2, 3, 7, 6], (0, 0, 1)),
        ([3, 0, 4, 7], (-1, 0, 0)),
    ]:
        start = len(vertices)
        vertices.extend(points[i] for i in face)
        normals.extend([normal] * 4)
        uvs.extend([(0, 0), (1, 0), (1, 1), (0, 1)])
        indices.extend(start + i for i in [0, 1, 2, 0, 2, 3])


for row in range(3):
    for z in range(3):
        box(0, row * 0.53, z * 1.4 - 1.4, 2.6, 0.50, 1.37)
box(0, 1.59, 0, 2.6, 0.18, 4.2)
blob = bytearray()
views = []
accessors = []


def append(data):
    while len(blob) % 4:
        blob.append(0)
    views.append(dict(buffer=0, byteOffset=len(blob), byteLength=len(data)))
    blob.extend(data)
    return len(views) - 1


def accessor(values, components, kind, ctype, fmt):
    data = struct.pack(
        "<" + fmt * len(values) * components,
        *(v for row in values for v in (row if isinstance(row, tuple) else (row,))),
    )
    item = dict(
        bufferView=append(data), componentType=ctype, count=len(values), type=kind
    )
    if kind == "VEC3":
        item["min"] = [min(v[i] for v in values) for i in range(components)]
        item["max"] = [max(v[i] for v in values) for i in range(components)]
    accessors.append(item)
    return len(accessors) - 1


pos = accessor(vertices, 3, "VEC3", 5126, "f")
norm = accessor(normals, 3, "VEC3", 5126, "f")
uv = accessor(uvs, 2, "VEC2", 5126, "f")
idx = accessor(indices, 1, "SCALAR", 5123, "H")
texture = (
    Path(os.environ.get("POLYWORLD_DATA", root.parent / "polyworld_data"))
    / "terrain/tiles/mossy-building-stone-1.rgb.png"
)
image = append(texture.read_bytes())
doc = dict(
    asset=dict(version="2.0", generator="Paintbot masonry generator"),
    buffers=[dict(byteLength=len(blob))],
    bufferViews=views,
    accessors=accessors,
    images=[dict(bufferView=image, mimeType="image/png")],
    samplers=[dict(wrapS=10497, wrapT=10497)],
    textures=[dict(source=0, sampler=0)],
    materials=[
        dict(
            pbrMetallicRoughness=dict(
                baseColorTexture=dict(index=0), metallicFactor=0, roughnessFactor=1
            )
        )
    ],
    meshes=[
        dict(
            name="cover",
            primitives=[
                dict(
                    attributes=dict(POSITION=pos, NORMAL=norm, TEXCOORD_0=uv),
                    indices=idx,
                    material=0,
                )
            ],
        )
    ],
    nodes=[dict(name="cover", mesh=0)],
    scenes=[dict(nodes=[0])],
    scene=0,
)
header = json.dumps(doc, separators=(",", ":")).encode()
header += b" " * ((-len(header)) % 4)
blob += b"\0" * ((-len(blob)) % 4)
output = root / "tmp/paintbot-cover.glb"
output.parent.mkdir(exist_ok=True)
output.write_bytes(
    struct.pack("<III", 0x46546C67, 2, 28 + len(header) + len(blob))
    + struct.pack("<II", len(header), 0x4E4F534A)
    + header
    + struct.pack("<II", len(blob), 0x004E4942)
    + blob
)
