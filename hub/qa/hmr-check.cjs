// Run against disposable synthetic storage; temporarily edits and restores frontend files.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { setTimeout: delay } = require('node:timers/promises');

async function check(base = 'http://localhost:3301') {
  const get = async (route) => {
    const response = await fetch(base + route);
    assert.equal(response.status, 200, route);
    return response.text();
  };
  for (let attempt = 0; ; attempt++) {
    try { assert.equal(JSON.parse(await get('/api/health')).ok, true); break; }
    catch (error) { if (attempt === 29) throw error; await delay(1000); }
  }
  assert.match(await get('/'), /\/@vite\/client/);
  await get('/dashboard.js');
  assert.match(await get('/hub-client.js'), /window.VanguardApi/);
  await get('/dashboard.css?direct');
  const socket = new WebSocket(base.replace(/^http/, 'ws') + '/', 'vite-hmr');
  const messages = [];
  socket.addEventListener('message', (event) => messages.push(JSON.parse(event.data)));
  const waitFor = async (predicate) => {
    for (let attempt = 0; attempt < 100; attempt++) {
      if (messages.some(predicate)) return;
      await delay(100);
    }
    throw new Error('Expected Vite WebSocket update was not received');
  };
  const css = path.join(__dirname, '../public/dashboard.css');
  const js = path.join(__dirname, '../public/dashboard.js');
  const originalCss = fs.readFileSync(css, 'utf8');
  const originalJs = fs.readFileSync(js, 'utf8');
  try {
    await waitFor((message) => message.type === 'connected');
    fs.writeFileSync(css, originalCss + '\nbody { --vanguard-hmr-check: verified; }\n');
    await waitFor((message) => message.type === 'update'
      && message.updates.some((update) => update.type === 'css-update' && update.path.split('?')[0] === '/dashboard.css'));
    assert.match(await get('/dashboard.css?direct'), /--vanguard-hmr-check: verified/);
    messages.length = 0;
    fs.writeFileSync(js, originalJs.replace("c.hospital;", "c.hospital + ' · HMR verified';"));
    await waitFor((message) => message.type === 'full-reload');
    assert.match(await get('/dashboard.js'), /HMR verified/);
    console.log('PASS: proxied API, Vite WebSocket, CSS hot update and JavaScript automatic reload');
  } finally {
    fs.writeFileSync(css, originalCss);
    fs.writeFileSync(js, originalJs);
    socket.close();
  }
}

if (require.main === module) {
  check(process.argv[2]).catch((error) => { console.error(error.message); process.exitCode = 1; });
}
module.exports = { check };
