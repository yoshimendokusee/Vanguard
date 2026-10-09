const express = require('express');
const os = require('os');
const path = require('path');
const { openDb } = require('./db');
const { ingestBatch, MAX_BATCH } = require('./sync');

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
    if (typeof watchId !== 'string' || !watchId.trim() || !Array.isArray(reports)) {
      return res.status(400).json({ ok: false, error: 'Expected { watchId, reports: [] }' });
    }
    if (reports.length > MAX_BATCH) {
      return res.status(413).json({ ok: false, error: `Max ${MAX_BATCH} reports per batch` });
    }
    const result = ingestBatch(db, watchId.trim().slice(0, 64), reports);
    if (result.inserted.length) broadcast('triage', { inserted: result.inserted.length });
    console.log(
      `[sync] ${watchId}: ${result.inserted.length} new, ${result.duplicates} duplicate, ${result.rejected.length} rejected`
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
    // Still-inbound first; Immediate > Unassessed (unknown could be critical)
    // > Delayed > Minor > Deceased; then soonest expected arrival.
    const rows = db
      .prepare(
        `SELECT * FROM triage_reports
         ORDER BY (status != 'inbound'),
                  CASE triage WHEN 'Immediate' THEN 0 WHEN 'Unassessed' THEN 1
                              WHEN 'Delayed' THEN 2 WHEN 'Minor' THEN 3 ELSE 4 END,
                  (eta_minutes IS NULL),
                  strftime('%s', created_at) + COALESCE(eta_minutes, 0) * 60,
                  created_at`
      )
      .all();
    res.json(rows);
  });

  app.patch('/api/triage/:id', (req, res) => {
    const { status } = req.body || {};
    if (!STATUSES.has(status)) return res.status(400).json({ ok: false, error: 'Bad status' });
    const info = db.prepare('UPDATE triage_reports SET status = ? WHERE id = ?').run(status, req.params.id);
    if (info.changes === 0) return res.status(404).json({ ok: false, error: 'Not found' });
    broadcast('triage', { updated: Number(req.params.id) });
    res.json({ ok: true });
  });

  app.use(express.static(path.join(__dirname, 'public')));
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
