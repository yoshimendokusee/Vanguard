const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { verifyModel } = require('./model');

test('model verification rejects missing, corrupt, changed and incorrectly configured artifacts', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'qwen-artifact-'));
  try {
    await assert.rejects(verifyModel(directory), /manifest-missing/);
    const weights = Buffer.from('GGUF synthetic integrity test');
    const manifest = { ...require('../models/qwen3-0.6b/manifest.json'), file: 'fixture.gguf',
      sizeBytes: weights.length, sha256: createHash('sha256').update(weights).digest('hex') };
    const save = () => fs.writeFileSync(path.join(directory, 'manifest.json'), JSON.stringify(manifest));
    save();
    await assert.rejects(verifyModel(directory), /file-missing/);
    fs.writeFileSync(path.join(directory, manifest.file), weights);
    assert.equal((await verifyModel(directory)).sha256, manifest.sha256);
    assert.equal((await verifyModel(directory)).sha256, manifest.sha256);
    fs.writeFileSync(path.join(directory, manifest.file), Buffer.alloc(weights.length));
    await assert.rejects(verifyModel(directory), /checksum-mismatch/);
    fs.writeFileSync(path.join(directory, manifest.file), 'version https://git-lfs.github.com/spec/v1');
    await assert.rejects(verifyModel(directory), /size-mismatch/);
    manifest.file = '../outside.gguf'; save();
    await assert.rejects(verifyModel(directory), /manifest-invalid/);
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});
