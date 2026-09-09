"""Write reviewed asset lists, including external textures referenced by GLBs."""
import json
from pathlib import Path
import re
import struct

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT.parent / 'polyworld_data'
GAMES = {'gota': 'gods_of_the_arena', 'lvd': 'light_vs_dark', 'cta': 'call_to_adventure'}


def strings(source):
    """Extract string literals from a small Nim asset table."""
    return re.findall(r'"([^"\n]+)"', source)


def references(asset):
    """Read relative image and buffer URIs from a GLB's JSON chunk."""
    if asset.suffix != '.glb':
        return []
    data = asset.read_bytes()
    length, kind = struct.unpack_from('<II', data, 12)
    assert kind == 0x4e4f534a
    root = json.loads(data[20:20 + length])
    return [asset.parent / item['uri'] for key in ('images', 'buffers')
            for item in root.get(key, []) if item.get('uri') and not item['uri'].startswith('data:')]


terrain = (ROOT / 'src/polyworld/quadterrain.nim').read_text()
surfaces = strings((ROOT / 'src/polyworld/terrainsurfaces.nim').read_text().split('SurfaceNames* = [')[1].split(']')[0])
for game, directory in GAMES.items():
    graphics = (ROOT / 'examples' / directory / 'graphics.nim').read_text()
    content = (ROOT / 'examples' / directory / 'content.nim').read_text()
    selected = set()
    def add(name):
        """Include one required file or a directory loaded wholesale by the UI."""
        path = DATA / name
        assert path.exists(), name
        if path.is_dir():
            for child in path.rglob('*'):
                if child.is_file() and not child.name.startswith('.'):
                    selected.add(child.relative_to(DATA).as_posix())
        else:
            selected.add(name)
    for name in ['icons', 'themes/main', 'ui', 'fonts/Rubik-Regular.ttf',
                 'fonts/Rubik-Bold.ttf', 'fonts/OverpassMono-Regular.ttf',
                 f'themes/{game}/{game}_logo.png', 'terrain/low_poly_grass.glb']:
        add(name)
    for name in strings(terrain.split('TreeTextures = [')[1].split(']')[0]):
        add(f'terrain/handpainted_trees/{name}.png')
    tree_names = ['tree_fir_01', 'tree_fir_02']
    if game == 'cta':
        tree_names += ['tree_fir_03', 'tree_leafy_simple', 'tree_leafy_double']
    for name in tree_names:
        add(f'terrain/handpainted_trees/{name}.glb')
    for name in ['water_1_normal', 'water_2_normal']:
        add(f'terrain/water_normals/{name}.jpg')
    if game == 'cta':
        add('terrain/low_poly_rocks.glb')
        for name in strings(terrain.split('TerrainMaterials = [')[1].split(']')[0]):
            for channel in ['color', 'height']:
                add(f'terrain/cartoon_textures/{name}_{channel}.png')
    else:
        add('terrain/toon_enchanted_meadow/rocks.glb')
        for name in surfaces:
            for folder in ['tiles', 'stamps']:
                for channel in ['rgb', 'height']:
                    add(f'terrain/{folder}/{name}.{channel}.png')
        if game == 'gota':
            for name in ['mossy-building-stone-1', 'dry-stacked-stone-1']:
                for channel in ['rgb', 'height']:
                    add(f'terrain/tiles/{name}.{channel}.png')
    for name in re.findall(r'DataRoot\s*&\s*"/([^"\n]+)"', graphics + content):
        if Path(name).suffix:
            add(name)
    if game == 'gota':
        for name in re.findall(r'icon:\s*"([^"]+)"', content):
            if (DATA / 'abilities' / f'{name}.png').exists():
                add(f'abilities/{name}.png')
            elif (DATA / 'items' / f'{name}.png').exists():
                add(f'items/{name}.png')
    if game == 'cta':
        icons = content.split('AbilityIconFiles*')[1].split('] = [')[1].split(']')[0]
        for name in strings(icons):
            if name:
                add(f'abilities/{name}.png')
    if game == 'lvd':
        for name in list(selected):
            if name.startswith('characters/') and name.endswith('.glb'):
                add(str(Path(name).with_suffix('.profile.png')))
        props = graphics.split('BuildingProps = [')[1].split('BuildingPropHeights')[0]
        for name in strings(props) + ['mineral1']:
            if not name:
                continue
            for pack in ['low_poly_village', 'tower_defense_kit']:
                path = f'terrain/{pack}.{name}.profile.png'
                if (DATA / path).exists():
                    add(path)
    for name in list(selected):
        for path in references(DATA / name):
            add(path.resolve().relative_to(DATA.resolve()).as_posix())
    output = ROOT / 'examples' / directory / 'webdata.txt'
    output.write_text('# Required replay assets at the revision in coworld/assets.json.\n' + '\n'.join(sorted(selected)) + '\n')
    print(game, len(selected), round(sum((DATA / p).stat().st_size for p in selected) / 1024**2, 1), 'MiB')
