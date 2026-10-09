const fs = require('node:fs');
const path = require('node:path');
const { createHash } = require('node:crypto');

let verified;
async function verifyModel(directory = process.env.QWEN_MODEL_DIR || path.join(__dirname, '../models/qwen3-0.6b')) {
  let manifest;
  try { manifest = JSON.parse(fs.readFileSync(path.join(directory, 'manifest.json'), 'utf8')); }
  catch { throw new Error('model-manifest-missing'); }
  if (manifest.model !== 'Qwen3-0.6B' || manifest.ollamaModel !== 'qwen3:0.6b'
    || manifest.quantization !== 'Q4_K_M' || !/^[a-f0-9]{40}$/.test(manifest.revision)
    || !/^[a-f0-9]{64}$/.test(manifest.sha256) || !Number.isSafeInteger(manifest.sizeBytes)
    || manifest.sizeBytes < 8 || typeof manifest.file !== 'string' || path.basename(manifest.file) !== manifest.file) {
    throw new Error('model-manifest-invalid');
  }
  const file = path.join(directory, manifest.file);
  let stat;
  try { stat = fs.statSync(file); } catch { throw new Error('model-file-missing'); }
  if (!stat.isFile() || stat.size !== manifest.sizeBytes) throw new Error('model-size-mismatch');
  const identity = [file, manifest.sha256, stat.size, stat.mtimeMs, stat.ctimeMs].join(':');
  if (verified?.identity === identity) return verified.promise;
  const promise = (async () => {
    const hash = createHash('sha256');
    let header;
    for await (const chunk of fs.createReadStream(file)) {
      if (!header) header = chunk.subarray(0, 4).toString('ascii');
      hash.update(chunk);
    }
    if (header !== 'GGUF' || hash.digest('hex') !== manifest.sha256) throw new Error('model-checksum-mismatch');
    const after = fs.statSync(file);
    if (after.mtimeMs !== stat.mtimeMs || after.ctimeMs !== stat.ctimeMs) throw new Error('model-changed-during-verification');
    return { ...manifest, path: file };
  })();
  verified = { identity, promise };
  try { return await promise; } catch (error) { verified = undefined; throw error; }
}

module.exports = { verifyModel };
