const fs = require('node:fs');
const path = require('node:path');
const { Readable } = require('node:stream');
const { pipeline } = require('node:stream/promises');
const { verifyModel } = require('./model');

// Initial setup may download pinned weights; inference containers have no internet route.
async function provisionModel(source, destination, fetchImpl = fetch) {
  const manifest = JSON.parse(fs.readFileSync(path.join(source, 'manifest.json'), 'utf8'));
  if (manifest.file !== path.basename(manifest.file) || !/^[a-f0-9]{40}$/.test(manifest.revision)
    || !/^[a-f0-9]{64}$/.test(manifest.sha256) || !Number.isSafeInteger(manifest.sizeBytes)
    || manifest.sizeBytes < 8 || !manifest.url.startsWith(`https://huggingface.co/${manifest.conversion}/resolve/${manifest.revision}/`)) {
    throw Error('model-manifest-invalid');
  }
  fs.mkdirSync(destination, { recursive: true });
  const state = (value, error) => {
    const file = path.join(destination, 'provisioning.json');
    fs.writeFileSync(file + '.tmp', JSON.stringify({ state: value, error, updatedAt: new Date().toISOString() }));
    fs.renameSync(file + '.tmp', file);
  };
  const temporary = path.join(destination, manifest.file + '.partial');
  try {
    state('INITIALIZING');
    if (path.resolve(source) !== path.resolve(destination)) fs.writeFileSync(path.join(destination, 'manifest.json'), JSON.stringify(manifest));
    try { await verifyModel(destination); }
    catch {
      try {
        await verifyModel(source);
        fs.copyFileSync(path.join(source, manifest.file), temporary);
      } catch {
        state('MODEL_DOWNLOADING');
        const response = await fetchImpl(manifest.url, { signal: AbortSignal.timeout(15 * 60_000) });
        if (!response.ok || !response.body) throw Error('model-download-failed');
        let bytes = 0;
        await pipeline(Readable.from((async function* () {
          for await (const chunk of response.body) {
            bytes += chunk.length;
            if (bytes > manifest.sizeBytes) throw Error('model-size-mismatch');
            yield chunk;
          }
        })()), fs.createWriteStream(temporary));
        if (bytes !== manifest.sizeBytes) throw Error('model-size-mismatch');
      }
      // Verify the staging directory before replacing any working model.
      const staging = fs.mkdtempSync(path.join(destination, '.verify-'));
      try {
        fs.writeFileSync(path.join(staging, 'manifest.json'), JSON.stringify(manifest));
        fs.linkSync(temporary, path.join(staging, manifest.file));
        await verifyModel(staging);
      } finally { fs.rmSync(staging, { recursive: true, force: true }); }
      fs.renameSync(temporary, path.join(destination, manifest.file));
    }
    fs.writeFileSync(path.join(destination, 'checksums.sha256'), `${manifest.sha256}  ${manifest.file}\n`);
    if (path.resolve(source) !== path.resolve(destination)) fs.copyFileSync(path.join(source, 'Modelfile'), path.join(destination, 'Modelfile'));
    state('MODEL_LOADING');
    console.log('Pinned Qwen weights verified; local Ollama import can start');
  } catch (error) {
    fs.rmSync(temporary, { force: true });
    state('ERROR', error.message);
    throw error;
  }
}

if (require.main === module) provisionModel('/model-source', '/models/qwen3-0.6b')
  .catch(error => { console.error(error.message); process.exitCode = 1; });
module.exports = { provisionModel };
