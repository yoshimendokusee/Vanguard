const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { validateRepository } = require('./validate-repository');

const root = path.resolve(__dirname, '../..');

function withFixture(change) {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'vanguard-validation-'));
  try {
    for (const file of ['.github', 'docs', 'database', 'supabase']) {
      fs.cpSync(path.join(root, file), path.join(temp, file), { recursive: true });
    }
    for (const file of ['hub', 'watch']) {
      fs.cpSync(path.join(root, file), path.join(temp, file), {
        recursive: true,
        filter: (source) => !/(?:^|\/)(?:node_modules|data|build|\.build|\.swiftpm|\.dart_tool|\.gradle)(?:\/|$)/.test(source)
          && !/\.(?:db|sqlite|zip)$/.test(source),
      });
    }
    for (const file of ['.env.example', 'compose.yaml']) {
      fs.copyFileSync(path.join(root, file), path.join(temp, file));
    }
    change(temp);
  } finally {
    fs.rmSync(temp, { recursive: true, force: true });
  }
}

test('current repository passes validation', () => validateRepository(root));

test('renaming a required CI check fails validation', () => withFixture((temp) => {
  const file = path.join(temp, '.github/workflows/pr-ci.yml');
  fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replace('name: Hub tests', 'name: Renamed hub check'));
  assert.throws(() => validateRepository(temp), /every stable CI job name/);
}));

test('undocumented application environment variables fail validation', () => withFixture((temp) => {
  fs.appendFileSync(path.join(temp, 'hub/server.js'), '\nconst setting = process.env.UNDOCUMENTED_SETTING;\n');
  assert.throws(() => validateRepository(temp), /UNDOCUMENTED_SETTING/);
}));

test('unintegrated SQL migrations fail validation', () => withFixture((temp) => {
  fs.writeFileSync(path.join(temp, 'database/migrations/hub/0001_test.sql'), 'CREATE TABLE sample (id INTEGER);');
  assert.throws(() => validateRepository(temp), /migration runner and populated upgrade tests/);
}));

test('missing application configuration fails validation', () => withFixture((temp) => {
  fs.unlinkSync(path.join(temp, 'watch/pubspec.lock'));
  assert.throws(() => validateRepository(temp), /ENOENT/);
}));

test('acceptance gate fails for failed, skipped, cancelled or missing jobs', () => {
  const workflow = fs.readFileSync(path.join(root, '.github/workflows/pr-ci.yml'), 'utf8');
  const script = workflow.match(/node <<'JS'\n([\s\S]*?)\n          JS/)[1].replace(/^          /gm, '');
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'vanguard-gate-'));
  try {
    for (const result of ['success', 'failure', 'skipped', 'cancelled', undefined]) {
      const results = Object.fromEntries(['repository', 'secrets', 'hub', 'watch', 'docker'].map((id) => [id, { result: 'success' }]));
      results.watch = { result };
      const outcome = spawnSync(process.execPath, ['-'], {
        input: script,
        env: { ...process.env, RESULTS: JSON.stringify(results), GITHUB_STEP_SUMMARY: path.join(temp, 'summary.md') },
        encoding: 'utf8',
      });
      assert.equal(outcome.status, result === 'success' ? 0 : 1, outcome.stderr);
    }
  } finally {
    fs.rmSync(temp, { recursive: true, force: true });
  }
});
