/* Run the same Nim verifier away from the UI thread. One worker per replay. */
// The verifier build matches the replay's seat count: this directory, or s<N>/ for a crowd replay.
onmessage = async ({data}) => {
  try {
    const directory = data.directory || '';
    importScripts(directory + 'paintbot-index.js');
    const module = await PaintbotIndex({noInitialRun: true, locateFile: path => directory + path});
    module.FS.writeFile('/episode.replay', new Uint8Array(data.buffer));
    module.callMain(['--replay', '/episode.replay']);
    if (module.FS.analyzePath('/index.error').exists) {
      throw new Error(module.FS.readFile('/index.error', {encoding: 'utf8'}));
    }
    const index = module.FS.readFile('/episode.index');
    postMessage({type: 'complete', index}, [index.buffer]);
  } catch (error) {
    postMessage({type: 'error', message: String(error?.message || error)});
  } finally {
    close();
  }
};
