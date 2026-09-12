/* Compressed assets and verified replay analysis load concurrently. */
(() => {
  const isReplay = Module.arguments?.includes('--replay');
  const started = performance.now();
  const status = document.getElementById('status') || document.getElementById('loading-detail');
  const stages = {assets: 'Downloading artwork', replay: isReplay ? 'Downloading replay' : ''};
  let stopped = false;
  const abort = new AbortController();
  let worker;
  function progress(stage, label) {
    if (stopped) return;
    stages[stage] = label;
    status.textContent = Object.values(stages).filter(Boolean).join('\n');
    if (typeof message === 'function') message('phase', {phase: stage, detail: label, elapsed_ms: performance.now() - started});
  }
  function failure(error) {
    if (stopped) return;
    stopped = true;
    clearTimeout(timeout);
    abort.abort();
    worker?.terminate();
    fail(error);
  }
  Module.startupPhase = label => {
    stages.assets = '';
    stages.replay = '';
    progress('graphics', label + '…');
  };
  const timeout = setTimeout(() => failure(new Error('Replay loading timed out. Reload to retry.')), 120000);
  const firstFrame = Module.polyworldFrame;
  Module.polyworldFrame = (...args) => { clearTimeout(timeout); firstFrame?.(...args); };
  window.addEventListener('pagehide', () => { clearTimeout(timeout); abort.abort(); worker?.terminate(); }, {once: true});

  async function download(url, stage, limit) {
    const response = await fetch(url, {signal: abort.signal});
    if (!response.ok) throw new Error(`Download failed (${response.status}): ${url}`);
    const total = Number(response.headers.get('Content-Length'));
    if (total > limit) throw new Error('Download exceeds size limit');
    const reader = response.body.getReader();
    const chunks = [];
    let size = 0, last = 0;
    for (;;) {
      const {done, value} = await reader.read();
      if (done) break;
      size += value.length;
      if (size > limit) { await reader.cancel(); throw new Error('Download exceeds size limit'); }
      chunks.push(value);
      if (performance.now() - last > 150) {
        progress(stage, `Downloading ${stage === 'assets' ? 'artwork' : 'replay'}: ${(size / 1048576).toFixed(1)} MB${total ? ` / ${(total / 1048576).toFixed(1)} MB` : ''}`);
        last = performance.now();
      }
    }
    return new Uint8Array(await new Blob(chunks).arrayBuffer());
  }
  async function inflate(bytes, format, limit) {
    const reader = new Blob([bytes]).stream().pipeThrough(new DecompressionStream(format)).getReader();
    let size = 0;
    const chunks = [];
    for (;;) {
      const {done, value} = await reader.read();
      if (done) break;
      size += value.length;
      if (size > limit) { await reader.cancel(); throw new Error('Decompressed file exceeds size limit'); }
      chunks.push(value);
    }
    return new Uint8Array(await new Blob(chunks).arrayBuffer());
  }
  async function prepareReplay() {
    const uri = new URLSearchParams(location.hash.slice(1)).get('replay') || new URLSearchParams(location.search).get('replay');
    if (!uri) throw new Error('No replay was supplied. Open a completed episode replay.');
    let bytes = await download(uri, 'replay', 64 * 1048576);
    const gzip = bytes[0] === 31 && bytes[1] === 139;
    const zlib = (bytes[0] & 15) === 8 && (bytes[0] >> 4) <= 7 && ((bytes[0] << 8) | bytes[1]) % 31 === 0;
    if (gzip || zlib) bytes = await inflate(bytes, gzip ? 'gzip' : 'deflate', 64 * 1048576);
    if (!bytes.length) throw new Error('The replay file is empty');
    progress('replay', 'Verifying replay in background…');
    const index = await new Promise((resolve, reject) => {
      worker = new Worker('index-worker.js');
      worker.onerror = event => reject(new Error(event.message || 'Replay verifier failed'));
      worker.onmessage = ({data}) => {
        if (data.type === 'progress') progress('replay', `Verifying replay: ${Math.floor(data.tick * 100 / data.total)}%`);
        if (data.type === 'error') reject(new Error(data.message));
        if (data.type === 'complete') resolve(data.index);
      };
      // Retain these same bytes for the viewer; only the worker's index returns
      // via transfer. No network lookup or external index is trusted here.
      worker.postMessage(bytes.buffer);
    });
    worker.terminate();
    progress('replay', 'Replay verified');
    return {bytes, index};
  }
  const replay = isReplay ? prepareReplay() : Promise.resolve(null);
  replay.catch(failure);
  if (isReplay) {
    Module.preRun = [() => {
      addRunDependency('verified-replay');
      replay.then(result => {
        if (stopped) return;
        FS.writeFile('/episode.replay', result.bytes);
        FS.writeFile('/episode.index', result.index);
        removeRunDependency('verified-replay');
      }).catch(failure);
    }];
  }
  const assets = (async () => {
    const zipped = await download(Module.assetPackage || 'paintbot.data.gz', 'assets', 128 * 1048576);
    progress('assets', 'Unpacking artwork…');
    const bytes = await inflate(zipped, 'gzip', 128 * 1048576);
    Module.getPreloadedPackage = () => bytes.buffer;
    progress('assets', 'Artwork ready');
  })();
  const wasm = (async () => {
    const response = await fetch('paintbot.wasm', {signal: abort.signal});
    if (!response.ok) throw new Error(`Viewer download failed (${response.status})`);
    const compiled = await WebAssembly.compileStreaming(response);
    Module.instantiateWasm = (imports, receive) => {
      WebAssembly.instantiate(compiled, imports).then(instance => receive(instance, compiled)).catch(failure);
      return {};
    };
  })();
  Promise.all([assets, wasm]).then(() => {
    if (stopped) return;
    const script = document.createElement('script');
    script.src = 'paintbot.js';
    script.onerror = () => failure(new Error('Could not load viewer code'));
    document.body.append(script);
  }).catch(failure);
})();
