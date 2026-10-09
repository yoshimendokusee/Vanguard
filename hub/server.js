const express = require('express');
const os = require('os');
const path = require('path');
const { openDb } = require('./db');
const { ingestBatch, MAX_BATCH } = require('./sync');
const { reportView, listReports, reviseReport } = require('./clinical');
const { getRecord, saveRecord, isId, fail } = require('./records');

const STATUSES = new Set(['inbound', 'arrived', 'cancelled']);

function createApp(db, { hospital = process.env.HOSPITAL_NAME || 'Receiving Hospital · Emergency Department' } = {}) {
  const app = express();
  app.use(express.json({ limit: '1mb' }));

  // --- live updates (Server-Sent Events) -----------------------------------
  const clients = new Set();
  const broadcast = (event, data) => {
    const msg = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
    for (const res of clients) res.write(msg);
  };

  app.get('/api/events', (req, res) => {
    res.set({
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      Connection: 'keep-alive',
    });
    res.flushHeaders();
    res.write('retry: 2000\n\n');
    clients.add(res);
    const keepAlive = setInterval(() => res.write(': ping\n\n'), 20000);
    req.on('close', () => {
      clearInterval(keepAlive);
      clients.delete(res);
    });
  });

  // --- watch -> hospital -----------------------------------------------------
  app.get('/api/health', (_req, res) => res.json({ ok: true, time: new Date().toISOString() }));
  app.get('/api/config', (_req, res) => res.json({ hospital }));

  app.post('/api/sync-triage', (req, res) => {
    const { watchId, reports } = req.body || {};
    if (typeof watchId !== 'string' || !watchId.trim() || watchId.trim().length > 64 || !Array.isArray(reports)) {
      return res.status(400).json({ ok: false, error: 'Expected { watchId, reports: [] }' });
    }
    if (reports.length > MAX_BATCH) {
      return res.status(413).json({ ok: false, error: `Max ${MAX_BATCH} reports per batch` });
    }
    const result = ingestBatch(db, watchId.trim(), reports);
    if (result.inserted.length) broadcast('triage', { inserted: result.inserted.length });
    console.log(
      `[sync] ${result.inserted.length} new, ${result.duplicates} duplicate, ${result.rejected.length} rejected`
    );
    res.json({
      ok: true,
      inserted: result.inserted.length,
      duplicates: result.duplicates,
      rejected: result.rejected,
      ackLocalIds: result.ackLocalIds,
    });
  });

  // --- ED dashboard API ------------------------------------------------------
  app.get('/api/triage', (_req, res) => {
    res.json(listReports(db));
  });

  app.patch('/api/triage/:id', (req, res) => {
    const { status } = req.body || {};
    if (!STATUSES.has(status)) return res.status(400).json({ ok: false, error: 'Bad status' });
    if (!/^[1-9]\d*$/.test(req.params.id) || !Number.isSafeInteger(Number(req.params.id))) return res.status(400).json({ ok: false, error: 'Bad report ID' });
    db.transaction(() => {
      const row = db.prepare('SELECT status FROM triage_reports WHERE id = ?').get(req.params.id);
      if (!row) fail(404, 'Not found');
      if (row.status === status) return;
      db.prepare('UPDATE triage_reports SET status = ? WHERE id = ?').run(status, req.params.id);
      db.prepare("INSERT INTO report_events (report_id, event, detail, created_at) VALUES (?, 'status', ?, ?)")
        .run(req.params.id, `${row.status} -> ${status}; dashboard operator (unauthenticated)`, new Date().toISOString());
    }).immediate();
    broadcast('triage', { updated: Number(req.params.id) });
    res.json({ ok: true });
  });

  app.get('/api/triage/:id', (req, res) => res.json(reportView(db, req.params.id, true)));
  app.post('/api/triage/:id/revisions', (req, res) => {
    const result = reviseReport(db, req.params.id, req.body);
    broadcast('triage', { updated: result.id });
    res.json(result);
  });

  for (const [plural, kind] of [['patients', 'patient'], ['encounters', 'encounter']]) {
    app.post(`/api/${plural}`, (req, res) => {
      const id = req.body?.[`${kind}Id`];
      res.json(saveRecord(db, kind, id, req.body, true));
    });
    app.get(`/api/${plural}/:id`, (req, res) => {
      if (!isId(req.params.id)) fail(400, 'Invalid record ID');
      res.json(getRecord(db, kind, req.params.id));
    });
    app.post(`/api/${plural}/:id/revisions`, (req, res) => res.json(saveRecord(db, kind, req.params.id, req.body)));
  }

  app.use(express.static(path.join(__dirname, 'public')));
  app.use((error, _req, res, _next) => {
    const status = error.type === 'entity.too.large' ? 413 : error.type === 'entity.parse.failed' ? 400 : error.status || 503;
    const message = error.type === 'entity.too.large' ? 'JSON body exceeds 1 MB'
      : error.type === 'entity.parse.failed' ? 'Malformed JSON' : error.status ? error.message : 'Database unavailable; retain and retry';
    res.status(status).json({ ok: false, error: message });
  });
  return app;
}

if (require.main === module) {
  const port = Number(process.env.PORT) || 3000;
  const app = createApp(openDb());
  app.listen(port, '0.0.0.0', () => {
    console.log(`Vanguard hospital hub listening on :${port}`);
    for (const addrs of Object.values(os.networkInterfaces())) {
      for (const a of addrs || []) {
        if (a.family === 'IPv4' && !a.internal) console.log(`  LAN: http://${a.address}:${port}`);
      }
    }
  });
}

module.exports = { createApp };
