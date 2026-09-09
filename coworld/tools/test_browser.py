"""Exercise real WASM playback and the iframe readiness/error protocol."""
import argparse
import json
from pathlib import Path
from urllib.parse import quote
from playwright.sync_api import sync_playwright

GAMES = {'gota': ('gods_of_the_arena', 18680), 'lvd': ('light_vs_dark', 28800),
         'cta': ('call_to_adventure', 28800)}


def probe_url(base, game, replay):
    """Point a test iframe at a static viewer and a public replay file."""
    directory = GAMES[game][0]
    viewer = f'{base}/examples/{directory}/emscripten/{game}.html'
    if replay:
        viewer += '#replay=' + quote(base + '/tmp/coworld/' + replay, safe='')
    return base + '/coworld/tools/replay_probe.html?viewer=' + quote(viewer, safe='')


def click(page, x, y):
    """Hold a real mouse press across frames on software-rendered browsers."""
    page.mouse.move(x, y)
    page.mouse.down()
    page.wait_for_timeout(500)
    page.mouse.up()
    page.wait_for_timeout(500)


def check_browser(base, executable, output, games):
    """Verify rendering, replay determinism, controls, resize and visible errors."""
    report_path = output / 'browser.json'
    report = json.loads(report_path.read_text()) if report_path.exists() else {}
    output.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as p:
        options = {'headless': True, 'args': ['--enable-unsafe-swiftshader', '--use-angle=swiftshader']}
        if executable:
            options['executable_path'] = executable
        browser = p.chromium.launch(**options)
        page = browser.new_page(viewport={'width': 1280, 'height': 576})
        page.set_default_navigation_timeout(180000)
        for game in games:
            _, end_tick = GAMES[game]
            page.goto(probe_url(base, game, game + '.replay'))
            page.wait_for_function('replayMessages.some(x => x.type === "ready")', timeout=120000)
            frame = page.frames[1]
            assert not frame.evaluate('failed')
            assert frame.evaluate('Module.replayTick') >= 0
            page.screenshot(path=str(output / (game + '.png')), timeout=180000)
            print(game + ': first frame rendered', flush=True)
            # Turn looping off, then seek forward through every recorded tick.
            click(page, 210, 556)
            page.wait_for_timeout(100)
            click(page, 166, 556)
            frame.wait_for_function('Module.replayTick === ' + str(end_tick), timeout=600000)
            assert not frame.evaluate('failed'), frame.locator('#status').inner_text()
            report[game] = {'end_tick': end_tick, 'messages': page.evaluate('replayMessages')}
            # Rewind, change speed, then resize the real iframe canvas.
            click(page, 22, 556)
            page.wait_for_timeout(200)
            click(page, 362, 556)
            frame.wait_for_function('Module.replayTick < 2000', timeout=30000)
            page.set_viewport_size({'width': 960, 'height': 640})
            frame.wait_for_function('Module.canvas.width === 960 && Module.canvas.height === 640')
            page.set_viewport_size({'width': 1280, 'height': 576})
            report_path.write_text(json.dumps(report, indent=2) + '\n')
            print(game + ': full replay, seek, speed and resize passed', flush=True)
        for fixture in ['', 'corrupt.replay', 'divergent.replay']:
            page.goto(probe_url(base, 'cta', fixture))
            page.wait_for_function('replayMessages.some(x => x.type === "error")', timeout=120000)
            frame = page.frames[1]
            assert frame.locator('#status').is_visible()
            report[fixture or 'missing'] = page.evaluate('replayMessages')
            print((fixture or 'missing') + ': visible error passed', flush=True)
        browser.close()
    (output / 'browser.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--base', default='http://localhost:8765')
    parser.add_argument('--executable')
    parser.add_argument('--output', type=Path, default=Path('tmp/coworld/browser'))
    parser.add_argument('--games', nargs='+', choices=list(GAMES), default=list(GAMES))
    args = parser.parse_args()
    check_browser(args.base, args.executable, args.output, args.games)
