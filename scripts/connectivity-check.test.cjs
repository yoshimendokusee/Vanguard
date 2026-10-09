const assert = require('node:assert/strict');
const test = require('node:test');
const { composeUpWithPullRetry } = require('./connectivity-check.cjs');

function dockerError(stderr) {
  const error = new Error('Command failed: docker compose up -d --build');
  error.stderr = Buffer.from(stderr);
  return error;
}

test('retries Compose startup after a transient Docker Hub timeout', () => {
  let attempts = 0;
  const waits = [];
  const compose = (...args) => {
    attempts++;
    if (attempts === 1) throw dockerError('auth.docker.io: context deadline exceeded');
    assert.deepEqual(args, ['up', '-d', '--build']);
    return 'started';
  };

  assert.equal(composeUpWithPullRetry(compose, ms => waits.push(ms)), 'started');
  assert.equal(attempts, 2);
  assert.deepEqual(waits, [5000]);
});

test('does not retry non-transient Compose failures', () => {
  const failure = dockerError('services.hub has an invalid configuration');
  let attempts = 0;

  assert.throws(() => composeUpWithPullRetry(() => { attempts++; throw failure; }, () => {}), error => error === failure);
  assert.equal(attempts, 1);
});

test('stops after three transient Compose startup failures', () => {
  const failure = dockerError('Client.Timeout exceeded while awaiting headers');
  let attempts = 0;
  const waits = [];

  assert.throws(() => composeUpWithPullRetry(() => { attempts++; throw failure; }, ms => waits.push(ms)), error => error === failure);
  assert.equal(attempts, 3);
  assert.deepEqual(waits, [5000, 15000]);
});
