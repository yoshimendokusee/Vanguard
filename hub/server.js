const express = require('express');
const os = require('os');
const path = require('path');
const { openDb } = require('./db');
const { ingestBatch, MAX_BATCH } = require('./sync');
const { riskForRow } = require('./risk');
const { aiConfig, aiStatus, extractEmergency, triageAssist, validateTranscriptInput, AiError } = require('./ai');

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
    // Establish ETA/time order first; stable sort below adds hospital risk priority.
    const rows = db
      .prepare(
        `SELECT * FROM triage_reports
         ORDER BY (status != 'inbound'),
                  (eta_minutes IS NULL),
                  strftime('%s', created_at) + COALESCE(eta_minutes, 0) * 60,
                  created_at`
      )
      .all();
    const rank = { Immediate: 0, Unassessed: 1, Delayed: 2, Minor: 3, Deceased: 4 };
    const assessed = rows.map((row) => ({ ...row, ...riskForRow(row) }));
    // Preserve the SQL ETA/time order inside each provisional risk group.
    assessed.sort((a, b) => Number(a.status !== 'inbound') - Number(b.status !== 'inbound')
      || rank[a.effective_triage] - rank[b.effective_triage]);
    res.json(assessed);
  });

  app.patch('/api/triage/:id', (req, res) => {
    const { status } = req.body || {};
    if (!STATUSES.has(status)) return res.status(400).json({ ok: false, error: 'Bad status' });
    const info = db.prepare('UPDATE triage_reports SET status = ? WHERE id = ?').run(status, req.params.id);
    if (info.changes === 0) return res.status(404).json({ ok: false, error: 'Not found' });
    broadcast('triage', { updated: Number(req.params.id) });
    res.json({ ok: true });
  });

  // --- local AI (Qwen via Ollama): extraction assistant, never the triage authority ---
  app.get('/api/ai/status', async (_req, res) => {
    try {
      res.json(await aiStatus());
    } catch {
      const cfg = aiConfig();
      res.json({ ok: true, available: false, model: cfg.model, modelAvailable: false, error: 'ollama-unreachable', promptVersion: cfg.promptVersion, maxTranscript: cfg.maxTranscript });
    }
  });

  const parseAiBody = (req) => {
    const cfg = aiConfig();
    const checked = validateTranscriptInput(req.body, cfg.maxTranscript);
    if (checked.error) return { errorRes: { ok: false, ...checked.error }, cfg };
    return {
      transcript: checked.transcript,
      provenance: {
        device: req.body && req.body.device,
        sttEngine: req.body && req.body.sttEngine,
        sttRuntime: req.body && req.body.sttRuntime,
      },
      cfg,
    };
  };

  const aiFailure = (res, err, transcriptLen) => {
    if (err instanceof AiError) {
      console.log(`[ai] ${err.code} (transcript ${transcriptLen} chars)`);
      return res.status(err.httpStatus).json({ ok: false, error: err.code, message: err.message });
    }
    console.log(`[ai] inference-failed (transcript ${transcriptLen} chars)`);
    return res.status(502).json({ ok: false, error: 'inference-failed', message: 'Local AI inference failed' });
  };

  app.post('/api/ai/extract', async (req, res) => {
    const parsed = parseAiBody(req);
    if (parsed.errorRes) return res.status(400).json(parsed.errorRes);
    try {
      const result = await extractEmergency(parsed.transcript, parsed.provenance);
      res.json({ ok: true, ...result });
    } catch (err) {
      aiFailure(res, err, parsed.transcript.length);
    }
  });

  app.post('/api/ai/triage-assist', async (req, res) => {
    const parsed = parseAiBody(req);
    if (parsed.errorRes) return res.status(400).json(parsed.errorRes);
    try {
      const result = await triageAssist(parsed.transcript, parsed.provenance);
      res.json({ ok: true, ...result });
    } catch (err) {
      aiFailure(res, err, parsed.transcript.length);
    }
  });

  app.use(express.static(path.join(__dirname, 'public')));
  return app;
}

if (require.main === module) {
  const port = Number(process.env.PORT) || 3000;
  const host = process.env.HOST || '0.0.0.0';
  const app = createApp(openDb());
  app.listen(port, host, () => {
    if (host === '0.0.0.0') {
      console.log(`Vanguard hospital hub listening on :${port}`);
      for (const addrs of Object.values(os.networkInterfaces())) {
        for (const a of addrs || []) {
          if (a.family === 'IPv4' && !a.internal) console.log(`  LAN: http://${a.address}:${port}`);
        }
      }
    } else {
      console.log(`Vanguard hospital hub listening on http://${host}:${port}`);
    }
  });
}

module.exports = { createApp };
