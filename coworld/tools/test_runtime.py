"""Exercise the file handoff against compiled native Coworld games."""
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.request

from websockets.sync.client import connect

ROOT = Path(__file__).resolve().parents[2]
GAMES = {'gota': ('gods_of_the_arena', 10), 'lvd': ('light_vs_dark', 2),
         'cta': ('call_to_adventure', 4)}


def episode(game, count, scripts, failure=False, ticks=240):
    """Run a local file roster and inspect outputs at the completion marker."""
    with tempfile.TemporaryDirectory(prefix=f'coworld-{game}-') as temp:
        root = Path(temp)
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
        config = {'tokens': [f'token-{i}' for i in range(count)],
                  'players': [{'name': f'Player {i}'} for i in range(count)],
                  'seed': 2026, 'max_ticks': ticks}
        seats = []
        for slot, script in enumerate(scripts):
            source = root / f'player-{slot}'
            source.write_text(script)
            seats.append({'slot': slot, 'file_uri': source.as_uri(),
                          'content_hash': 'sha256:' + hashlib.sha256(source.read_bytes()).hexdigest(),
                          'size_bytes': source.stat().st_size,
                          'log_uri': (root / f'player-{slot}.log').as_uri(),
                          'artifact_uri': (root / f'player-{slot}.zip').as_uri()})
        env = dict(os.environ, COGAME_HOST='127.0.0.1', COGAME_PORT=str(port))
        inputs = {'CONFIG': config, 'PLAYER_SEATS': {
            'schema': 'coworld-player-seats/1', 'seats': seats,
            'player_status_uri': (root / 'status.json').as_uri()}}
        for key, value in inputs.items():
            path = root / f'{key}.json'
            path.write_text(json.dumps(value))
            env[f'COGAME_{key}_URI'] = path.as_uri()
        for key, name in [('RESULTS', 'results.json'), ('SAVE_REPLAY', 'replay'),
                          ('PLAYER_FAILURE', 'failure.json')]:
            env[f'COGAME_{key}_URI'] = (root / name).as_uri()
        with (root / 'game.log').open('w') as log:
            proc = subprocess.Popen([str(ROOT / 'tmp/coworld' / game)], env=env,
                                    cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
            try:
                marker = root / ('failure.json' if failure else 'results.json')
                deadline = time.monotonic() + 120
                while not marker.exists():
                    assert proc.poll() is None, (root / 'game.log').read_text()
                    assert time.monotonic() < deadline, 'episode timed out'
                    time.sleep(.02)
                output = json.loads(marker.read_text())
                assert (root / 'status.json').exists(), 'completion preceded status'
                logs = [(root / f'player-{i}.log').read_text() for i in range(count)]
                for i, private in enumerate(logs):
                    assert len(private.encode()) <= 10 * 1024 * 1024
                    if f'PRIVATE-{i}' in scripts[i]:
                        assert f'PRIVATE-{i}' in private
                        assert all(f'PRIVATE-{i}' not in other for j, other in enumerate(logs) if j != i)
                assert 'PRIVATE-' not in (root / 'game.log').read_text()
                if any(len(script) > 7000 for script in scripts):
                    assert len(logs[0].encode()) == 10 * 1024 * 1024
                    assert logs[0].endswith('[Player log truncated at 10 MiB.]\n')
                if failure:
                    assert not (root / 'results.json').exists()
                    assert output['failed_policy_index'] == 0
                    assert 'BASIC error:' in logs[0]
                else:
                    assert len(output['scores']) == count
                    assert set(output['scores']) <= {0, 1}
                    assert (root / 'replay').stat().st_size > 0
                    assert all('completed.' in private or 'log truncated' in private for private in logs)
                url = f'http://127.0.0.1:{port}'
                assert urllib.request.urlopen(url + '/healthz').status == 200
                assert urllib.request.urlopen(url + '/client/global').status == 200
                with connect(url.replace('http:', 'ws:') + '/global') as ws:
                    assert json.loads(ws.recv(timeout=5))['type'] == 'status'
                    assert ws.ping(b'coworld-certification-ping').wait(5)
                assert proc.poll() is None, 'server stopped before collection'
                if any('WHILE' in script for script in scripts):
                    assert 'BASIC error:' in logs[0]
                    status = json.loads((root / 'status.json').read_text())
                    assert status['players'][0]['exit_code'] == 1
            finally:
                proc.terminate()
                proc.wait(timeout=5)


for game, (_, count) in GAMES.items():
    episode(game, count, [f'PRINT "PRIVATE-{i}"\nEND\n' for i in range(count)])
    episode(game, count, [''] * count)
    episode(game, count, ['THIS IS NOT BASIC\n'] + ['END\n'] * (count - 1), failure=True)
    episode(game, count, ['WHILE 1\nWEND\n'] + ['END\n'] * (count - 1))
    print(f'{game}: runtime contracts passed', flush=True)

episode('lvd', 2, ['PRINT "' + 'x' * 7900 + '"\nEND\n', 'END\n'], ticks=28800)
print('10 MiB player log bound passed', flush=True)
