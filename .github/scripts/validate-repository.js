const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

function validateRepository(root) {
  const read = (file) => fs.readFileSync(path.join(root, file), 'utf8');
  for (const file of [
    'watch/pubspec.yaml', 'watch/pubspec.lock', 'watch/analysis_options.yaml',
    'watch/lib/main.dart', 'watch/lib/db/triage_db.dart',
    'hub/package.json', 'hub/package-lock.json', 'hub/server.js', 'hub/sync.js',
    'hub/db.js', 'hub/public/index.html', 'hub/sync.test.js', 'hub/contract.test.js',
    'hub/Dockerfile', 'hub/docker-compose.yml', 'hub/compose.dev.yaml',
    'hub/vite.config.mjs', 'hub/public/dashboard.js', 'hub/public/dashboard.css',
    'compose.yaml', '.env.example',
    'docs/architecture.md', 'docs/api-contract.md', 'docs/GITHUB_WORKFLOW.md',
    'database/migrations/README.md', '.github/PULL_REQUEST_TEMPLATE.md',
    '.github/branch-policy.md', '.github/rulesets/main.json', '.github/workflows/pr-ci.yml',
  ]) {
    assert.ok(fs.statSync(path.join(root, file)).isFile(), `Missing required file: ${file}`);
  }

  const pkg = JSON.parse(read('hub/package.json'));
  const lock = JSON.parse(read('hub/package-lock.json'));
  assert.equal(lock.lockfileVersion, 3, 'Use the existing npm lockfile format');
  assert.deepEqual(lock.packages[''].dependencies, pkg.dependencies, 'Hub dependencies differ from lockfile');
  assert.deepEqual(lock.packages[''].devDependencies, pkg.devDependencies, 'Hub dev dependencies differ from lockfile');
  assert.equal(lock.packages[''].engines.node, pkg.engines.node, 'Node engine differs from lockfile');
  assert.equal(pkg.scripts.test, 'node --test', 'Update CI when changing the hub test runner');
  assert.ok(!fs.existsSync(path.join(root, '.github/workflows/ci.yml')), 'Remove duplicate legacy CI workflow');

  const workflow = read('.github/workflows/pr-ci.yml');
  const rootCompose = read('compose.yaml');
  const hubCompose = read('hub/docker-compose.yml');
  assert.ok(rootCompose.includes('./hub/docker-compose.yml'), 'Root Compose must include the production hub');
  assert.ok(!rootCompose.includes('compose.dev.yaml'), 'Default Docker startup must not publish the Vite development port');
  assert.ok(/:\s*3000:3000/.test(hubCompose), 'Default Docker web app must publish host port 3000');
  assert.ok(!hubCompose.includes('HUB_PORT'), 'Default Docker web app host port must stay fixed at 3000');
  const jobNames = [...workflow.matchAll(/^    name: (.+)$/gm)].map((m) => m[1]);
  const policy = JSON.parse(read('.github/rulesets/main.json'));
  assert.equal(policy.target, 'branch');
  assert.equal(policy.enforcement, 'active');
  assert.deepEqual(policy.bypass_actors, [], 'No routine bypass actors');
  assert.deepEqual(policy.conditions.ref_name, { include: ['refs/heads/main'], exclude: [] });
  const rules = new Map(policy.rules.map((rule) => [rule.type, rule.parameters]));
  for (const type of ['deletion', 'non_fast_forward', 'required_linear_history', 'pull_request', 'required_status_checks']) {
    assert.ok(rules.has(type), `Missing main protection: ${type}`);
  }
  assert.ok(!rules.has('update'), 'An update restriction without bypass actors would also block PR merges');
  const reviews = rules.get('pull_request');
  assert.equal(reviews.required_approving_review_count, 1);
  assert.deepEqual(reviews.allowed_merge_methods, ['squash']);
  for (const key of ['dismiss_stale_reviews_on_push', 'require_last_push_approval', 'required_review_thread_resolution']) {
    assert.equal(reviews[key], true, `Missing review protection: ${key}`);
  }
  const checks = rules.get('required_status_checks');
  assert.equal(checks.strict_required_status_checks_policy, true);
  assert.deepEqual(checks.required_status_checks.map((check) => check.context).sort(), jobNames.sort(), 'Ruleset must require every stable CI job name');
  assert.ok(checks.required_status_checks.every((check) => check.integration_id === 15368), 'Require checks from GitHub Actions');

  const defined = new Set([...read('.env.example').matchAll(/^([A-Z][A-Z0-9_]*)=/gm)].map((m) => m[1]));
  const appFiles = [
    'hub/server.js', 'hub/db.js', 'watch/lib/services/sync_service.dart',
    'watch/lib/services/speech_service.dart', 'hub/docker-compose.yml',
    'hub/compose.dev.yaml', 'hub/vite.config.mjs',
  ];
  for (const file of appFiles) {
    const text = read(file);
    const used = [
      ...[...text.matchAll(/process\.env\.([A-Z][A-Z0-9_]*)/g)].map((m) => m[1]),
      ...[...text.matchAll(/String\.fromEnvironment\(\s*'([A-Z][A-Z0-9_]*)'/g)].map((m) => m[1]),
      ...(/\.ya?ml$/.test(file) ? [...text.matchAll(/\$\{([A-Z][A-Z0-9_]*)(?=[:}])/g)].map((m) => m[1]) : []),
    ];
    for (const name of used) assert.ok(defined.has(name), `${file}: document ${name} in .env.example`);
  }

  // shortcut: no migration runners exist, require runner and upgrade-test integration before accepting executable migrations.
  for (const dir of ['database/migrations/watch', 'database/migrations/hub']) {
    const files = fs.readdirSync(path.join(root, dir));
    assert.ok(!files.some((file) => /\.(sql|dart|js)$/.test(file)), `${dir}: integrate a migration runner and populated upgrade tests, then update this guard`);
  }
}

if (require.main === module) {
  validateRepository(path.resolve(__dirname, '../..'));
  console.log('PASS: repository structure, locked configuration, environment examples and CI/ruleset consistency');
}

module.exports = { validateRepository };
