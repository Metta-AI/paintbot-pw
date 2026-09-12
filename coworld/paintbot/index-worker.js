/* Run the same Nim verifier away from the UI thread. One worker per replay. */
importScripts('paintbot-index.js');
onmessage = async ({data}) => {
  try {
    const module = await PaintbotIndex({noInitialRun: true});
    module.FS.writeFile('/episode.replay', new Uint8Array(data));
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
