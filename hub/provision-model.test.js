const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { provisionModel } = require('./provision-model');

test('fresh LFS-pointer clone downloads verified weights once, survives recreation, and rejects corruption', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'vanguard-provision-'));
  const source = path.join(root, 'source'), destination = path.join(root, 'volume');
  fs.mkdirSync(source);
  const bytes = Buffer.from('GGUF synthetic provisioning fixture only');
  const manifest = { ...require('../models/qwen3-0.6b/manifest.json'), file: 'fixture.gguf', sizeBytes: bytes.length,
    sha256: createHash('sha256').update(bytes).digest('hex') };
  fs.writeFileSync(path.join(source, 'manifest.json'), JSON.stringify(manifest));
  fs.writeFileSync(path.join(source, 'Modelfile'), 'FROM ./fixture.gguf');
  fs.writeFileSync(path.join(source, manifest.file), 'version https://git-lfs.github.com/spec/v1');
  let requests = 0;
  const download = async url => { assert.equal(url, manifest.url); requests++; return new Response(bytes); };
  try {
    await provisionModel(source, destination, download);
    assert.equal(requests, 1);
    assert.deepEqual(fs.readFileSync(path.join(destination, manifest.file)), bytes);
    await provisionModel(source, destination, () => { throw Error('Network must not be required again'); });
    assert.equal(JSON.parse(fs.readFileSync(path.join(destination, 'provisioning.json'))).state, 'MODEL_LOADING');
    fs.writeFileSync(path.join(destination, manifest.file), Buffer.alloc(bytes.length));
    await assert.rejects(provisionModel(source, destination, async () => new Response(Buffer.alloc(bytes.length))), /checksum/);
    assert.equal(JSON.parse(fs.readFileSync(path.join(destination, 'provisioning.json'))).state, 'ERROR');
    assert.equal(fs.existsSync(path.join(destination, manifest.file + '.partial')), false);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});
