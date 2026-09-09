"""Package the live three-game demo for a static nginx server."""

import argparse
import gzip
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
GAMES = [('gota', 'gods_of_the_arena', 10),
         ('lvd', 'light_vs_dark', 2),
         ('cta', 'call_to_adventure', 4)]


def package(destination, release):
    """Copy runtime files and make every deployed URL independent of the repo."""
    if not re.fullmatch(r'[a-zA-Z0-9_-]+', release):
        raise ValueError('Release must contain only letters, numbers, _ or -.')
    destination.mkdir(parents=True, exist_ok=False)
    page = (ROOT / 'tools/demo/index.html').read_text()
    for game, directory, seats in GAMES:
        source = ROOT / 'examples' / directory
        bundle = source / 'emscripten'
        if 'configurePolyworldWebInputs' not in (bundle / f'{game}.js').read_text():
            raise ValueError(f'{game} needs a live -d:emscripten build.')
        target = destination / 'releases' / release / game
        target.mkdir(parents=True)
        for extension in ('html', 'js', 'wasm', 'data'):
            shutil.copyfile(bundle / f'{game}.{extension}',
                            target / f'{game}.{extension}')
        script = target / f'{game}.js'
        javascript = script.read_text()
        label = re.search(r"var PACKAGE_NAME = '([^']+)';", javascript)
        if not label or Path(label[1]).name != f'{game}.data':
            raise ValueError(f'{game} has an unknown asset package label.')
        javascript = javascript.replace(label[1], f'{game}.data')
        script.write_text(javascript)
        shutil.copyfile(source / 'players/base.bas', target / 'base.bas')
        old = (f'../../examples/{directory}/emscripten/{game}.html'
               f'?bot=../players/base.bas:{seats}')
        new = f'../releases/{release}/{game}/{game}.html?bot=base.bas:{seats}'
        if page.count(old) != 1:
            raise ValueError(f'The demo must contain exactly one {game} iframe.')
        page = page.replace(old, new)
    page = re.sub(r'    <!--.*?-->\n', '', page, flags=re.S)
    demo = destination / 'demo'
    demo.mkdir()
    (demo / 'index.html').write_text(page)
    files = {}
    for path in sorted(destination.rglob('*')):
        if not path.is_file():
            continue
        data = path.read_bytes()
        files[str(path.relative_to(destination))] = {
            'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()
        }
        if path.suffix in ('.html', '.js', '.wasm', '.data', '.bas'):
            path.with_name(path.name + '.gz').write_bytes(
                gzip.compress(data, compresslevel=9, mtime=0))
    revision = subprocess.check_output(
        ['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    manifest = {
        'release': release,
        'source_revision': revision,
        'dependencies_sha256': hashlib.sha256(
            (ROOT / 'coworld/dependencies.lock').read_bytes()).hexdigest(),
        'files': files,
    }
    (destination / 'releases' / release / 'manifest.json').write_text(
        json.dumps(manifest, indent=2) + '\n')
    print(f'Packaged {len(files)} files for /polyworld/demo/ in {destination}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--release', required=True)
    args = parser.parse_args()
    package(args.destination, args.release)
