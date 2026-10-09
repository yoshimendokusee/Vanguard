const express = require('express');
const os = require('os');
const path = require('path');
const { existsSync } = require('node:fs');
const { openDb } = require('./db');
const { ingestBatch, MAX_BATCH } = require('./sync');
const { riskForRow } = require('./risk');
const { aiConfig, aiStatus, aiHealth, extractEmergency, triageAssist, validateTranscriptInput, glossaryFor, AiError } = require('./ai');
const { reportView, listReports, reviseReport } = require('./clinical');
const { getRecord, saveRecord, isId, fail } = require('./records');
const { randomUUID } = require('node:crypto');
const { hubAccess, validateLanAccess } = require('./access');
const { createCloudSync } = require('./cloud');

const STATUSES = new Set(['inbound', 'arrived', 'cancelled']);

function createApp(db, {
  hospital = process.env.HOSPITAL_NAME || 'Receiving Hospital · Emergency Department',
  cloud = createCloudSync(db),
} = {}) {
  const app = express();
  app.use('/api', (req, res, next) => {
    const id = req.get('X-Request-ID');
    req.requestId = isId(id) ? id.toLowerCase() : randomUUID();
    res.set('X-Request-ID', req.requestId);
    res.set('Cache-Control', 'no-store');
    next();
  });
  app.use(express.json({ limit: '1mb' }));
  app.use('/api', hubAccess());
  app.locals.cloud = cloud;

  // --- live updates (Server-Sent Events) -----------------------------------
  const clients = new Set();
  const broadcast = (event, data) => {
    const msg = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
    for (const res of clients) res.write(msg);
  };
  cloud.onChange((status) => broadcast('cloud', status));

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
  app.get('/api/config', (req, res) => res.json({ hospital, contractVersion: 1,
    user: req.user ? { id: req.user.id, role: req.user.role } : null }));

  app.post('/api/sync-triage', (req, res) => {
    const { watchId, reports } = req.body || {};
    if (typeof watchId !== 'string' || !watchId.trim() || watchId.trim().length > 64 || !Array.isArray(reports)) {
      return res.status(400).json({ ok: false, error: 'Expected { watchId, reports: [] }' });
    }
    if (reports.length > MAX_BATCH) {
      return res.status(413).json({ ok: false, error: `Max ${MAX_BATCH} reports per batch` });
    }
    const result = ingestBatch(db, watchId.trim(), reports);
    if (result.inserted.length) {
      broadcast('triage', { inserted: result.inserted.length });
      cloud.trigger();
    }
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
        .run(req.params.id, `${row.status} -> ${status}; ${req.user?.id || 'dashboard operator (unauthenticated)'}`, new Date().toISOString());
    }).immediate();
    broadcast('triage', { updated: Number(req.params.id) });
    res.json({ ok: true });
  });

  // --- Supabase backup (optional; never required for intake or the board) ---
  app.get('/api/cloud/status', (_req, res) => res.json({ ok: true, ...cloud.status() }));
  app.post('/api/cloud/sync', (req, res, next) => {
    cloud.syncNow({ retryRejected: req.body?.retryRejected === true })
      .then((status) => res.json({ ok: true, ...status }), next);
  });

  // --- local AI (Qwen via Ollama): extraction assistant, never the triage authority ---
  let healthRequest;
  app.get('/api/ai/health', async (req, res) => {
    // Concurrent status polls share a probe, never user transcripts or chat context.
    const health = await (healthRequest ||= aiHealth().finally(() => { healthRequest = undefined; }));
    res.status(health.status === 'ready' ? 200 : 503).json({ ...health, requestId: req.requestId });
  });

  app.get('/api/ai/status', async (_req, res) => {
    try {
      res.json(await aiStatus());
    } catch {
      const cfg = aiConfig();
      res.json({ ok: true, available: false, model: cfg.model, modelAvailable: false, error: 'ollama-unreachable', promptVersion: cfg.promptVersion, maxTranscript: cfg.maxTranscript });
    }
  });

  const parseAiBody = (req) => {
    let cfg;
    try { cfg = aiConfig(); } catch (error) { return { httpStatus: 503, errorRes: { ok: false, contractVersion: 1, requestId: req.requestId, error: error.code, message: error.message } }; }
    const checked = validateTranscriptInput(req.body, cfg.maxTranscript);
    if (checked.error) return { errorRes: { ok: false, contractVersion: 1, requestId: req.requestId, error: checked.error.code, message: checked.error.message }, cfg };
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
      return res.status(err.httpStatus).json({ ok: false, contractVersion: 1, requestId: res.get('X-Request-ID'), error: err.code, message: err.message });
    }
    console.log(`[ai] inference-failed (transcript ${transcriptLen} chars)`);
    return res.status(502).json({ ok: false, contractVersion: 1, requestId: res.get('X-Request-ID'), error: 'inference-failed', message: 'Local AI inference failed' });
  };

  app.post('/api/ai/extract', async (req, res) => {
    const parsed = parseAiBody(req);
    if (parsed.errorRes) return res.status(parsed.httpStatus || 400).json(parsed.errorRes);
    try {
      const result = await extractEmergency(parsed.transcript, parsed.provenance);
      res.json({ ok: true, contractVersion: 1, requestId: req.requestId, ...result });
    } catch (err) {
      aiFailure(res, err, parsed.transcript.length);
    }
  });

  // Offline terminology lookup. POST so patient text never appears in a URL or access log.
  app.post('/api/knowledge/lookup', (req, res) => {
    const checked = validateTranscriptInput(req.body, aiConfig().maxTranscript);
    if (checked.error) return res.status(400).json({ ok: false, ...checked.error });
    const { retrieval } = glossaryFor(checked.transcript);
    if (!retrieval) return res.status(503).json({ ok: false, error: 'knowledge-unavailable', message: 'Local terminology pack is not loaded' });
    res.json({ ok: true, retrieval });
  });

  app.post('/api/ai/triage-assist', async (req, res) => {
    const parsed = parseAiBody(req);
    if (parsed.errorRes) return res.status(parsed.httpStatus || 400).json(parsed.errorRes);
    try {
      const result = await triageAssist(parsed.transcript, parsed.provenance);
      res.json({ ok: true, contractVersion: 1, requestId: req.requestId, ...result });
    } catch (err) {
      aiFailure(res, err, parsed.transcript.length);
    }
  });
  app.post('/api/triage/:id/ai-extract', async (req, res, next) => {
    let transcript = '';
    try {
      const input = req.body;
      if (!input || !isId(input.requestId) || !Number.isSafeInteger(input.baseRevision)
        || input.baseRevision < 0 || Object.keys(input).some((key) => !['requestId', 'baseRevision'].includes(key))) {
        fail(400, 'Expected requestId and baseRevision');
      }
      const before = reportView(db, req.params.id, true);
      const replay = before.history.find((revision) => revision.request_id === input.requestId.toLowerCase());
      if (replay) {
        if (replay.kind !== 'extraction' || replay.actor !== 'Qwen/ollama'
          || replay.payload.baseRevision !== input.baseRevision) fail(409, 'Request ID conflict');
        return res.json({ ok: true, report: before, replay: true });
      }
      if (before.revision !== input.baseRevision) fail(409, 'Stale base revision');
      transcript = before.current_transcript;
      const checked = validateTranscriptInput({ transcript }, aiConfig().maxTranscript);
      if (checked.error) fail(400, checked.error.message);
      const result = await extractEmergency(transcript, { device: 'hospital-browser', sttEngine: 'preserved-report', sttRuntime: 'hub-v2' });
      const report = reviseReport(db, req.params.id, { ...input, kind: 'extraction', actor: 'Qwen/ollama',
        reason: 'Automatic provisional extraction; qualified verification required', processing: result.processing });
      broadcast('triage', { updated: report.id });
      res.json({ ok: true, ...result, report });
    } catch (error) {
      if (error instanceof AiError) aiFailure(res, error, transcript.length);
      else next(error);
    }
  });
  app.get('/api/triage/:id', (req, res) => res.json(reportView(db, req.params.id, true)));
  app.post('/api/triage/:id/revisions', (req, res) => {
    const result = reviseReport(db, req.params.id, req.user ? { ...req.body, actor: req.user.id } : req.body);
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

  const dashboard = existsSync(path.join(__dirname, 'dist/index.html')) ? 'dist' : 'public';
  app.use(express.static(path.join(__dirname, dashboard)));
  app.use((error, _req, res, _next) => {
    const status = error.type === 'entity.too.large' ? 413 : error.type === 'entity.parse.failed' ? 400 : error.status || 503;
    const message = error.type === 'entity.too.large' ? 'JSON body exceeds 1 MB'
      : error.type === 'entity.parse.failed' ? 'Malformed JSON' : error.status ? error.message : 'Database unavailable; retain and retry';
    res.status(status).json({ ok: false, contractVersion: 1, requestId: res.get('X-Request-ID'), error: message });
  });
  return app;
}

if (require.main === module) {
  validateLanAccess();
  const port = Number(process.env.PORT) || 3000;
  const host = process.env.HOST || '127.0.0.1';
  const app = createApp(openDb());
  app.locals.cloud.start();
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
