// Hub -> Supabase backup. SQLite stays the source of truth: reports are queued
// with a stable UUID, uploaded only when the hub is online, and marked synced
// only for UUIDs Supabase returns. The hub signs in as its own Supabase Auth
// user with the publishable key, so the cloud table's RLS still applies. A
// cloud upload is a backup, not hospital delivery or clinical review.
const { randomUUID } = require('node:crypto');

const BATCH = 100;
const MAX_BACKOFF_MS = 10 * 60 * 1000;
const SETTINGS = ['SUPABASE_URL', 'SUPABASE_ANON_KEY', 'SUPABASE_HUB_EMAIL', 'SUPABASE_HUB_PASSWORD'];

function isServerKey(key) {
  if (key.startsWith('sb_secret_')) return true;
  const parts = key.split('.');
  if (parts.length !== 3) return false;
  try {
    return JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8')).role === 'service_role';
  } catch {
    return false;
  }
}

/** Reads cloud settings; `error` explains why cloud sync stays disabled. */
function cloudConfig(env = process.env) {
  const values = Object.fromEntries(SETTINGS.map((name) => [name, (env[name] || '').trim()]));
  const config = {
    url: values.SUPABASE_URL.replace(/\/+$/, ''),
    key: values.SUPABASE_ANON_KEY,
    email: values.SUPABASE_HUB_EMAIL,
    password: env.SUPABASE_HUB_PASSWORD || '',
    intervalMs: Math.max(Number(env.CLOUD_SYNC_INTERVAL_MS) || 30000, 5000),
    timeoutMs: 15000,
    error: null,
  };
  const missing = SETTINGS.filter((name) => !values[name]);
  let url = null;
  try { url = new URL(config.url); } catch { /* reported below */ }
  if (missing.length === SETTINGS.length) config.error = 'Cloud sync is not configured';
  else if (missing.length) config.error = `Cloud sync needs ${missing.join(', ')} in .env`;
  else if (SETTINGS.some((name) => values[name].includes('<'))) config.error = 'Replace the <placeholder> Supabase values in .env';
  else if (!url || url.protocol !== 'https:' || !url.hostname) config.error = 'SUPABASE_URL must use HTTPS';
  else if (isServerKey(config.key)) {
    config.error = 'SUPABASE_ANON_KEY must be the publishable/anon key, not a secret or service-role key';
  }
  return config;
}

const cloudPayload = (row) => ({
  report_id: row.cloud_report_id,
  watch_id: row.watch_id,
  location: row.location,
  injuries: row.injuries,
  triage: row.triage,
  patient_count: row.patient_count,
  age_group: row.age_group,
  eta_minutes: row.eta_minutes,
  raw_text: row.raw_text,
  created_at: row.created_at,
});

class CloudError extends Error {
  constructor(message, status = null, code = null) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

// Only Supabase's short message is kept; `details`/`hint` can echo row content.
function cloudError(action, res, data) {
  const reason = data && (data.error_description || data.msg || data.message);
  const text = typeof reason === 'string' ? `: ${reason.slice(0, 200)}` : '';
  return new CloudError(`${action} (HTTP ${res.status})${text}`, res.status, data && data.code);
}

// Row-level rejections: constraint/format errors, conflicts and RLS refusals.
const rowRejected = (error) => error.status === 400 || error.status === 409
  || (error.status === 403 && error.code === '42501');

function createCloudSync(db, { config = cloudConfig(), fetch = globalThis.fetch, log = console.log } = {}) {
  const listeners = new Set();
  const state = { running: null, again: false, retryRejected: false, started: false, timer: null,
    failures: 0, lastAttemptAt: null, lastSuccessAt: null, lastError: null, session: null };

  const unqueued = db.prepare(`SELECT r.id FROM triage_reports r
    LEFT JOIN cloud_sync c ON c.report_id = r.id WHERE c.report_id IS NULL ORDER BY r.id`);
  const enqueue = db.prepare('INSERT INTO cloud_sync (report_id, cloud_report_id, queued_at) VALUES (?, ?, ?)');
  const pending = db.prepare(`SELECT c.cloud_report_id, r.* FROM cloud_sync c JOIN triage_reports r ON r.id = c.report_id
    WHERE c.synced_at IS NULL AND c.rejected_reason IS NULL ORDER BY r.id LIMIT ?`);
  const markSynced = db.prepare(`UPDATE cloud_sync SET synced_at = ?, owner_id = ?
    WHERE cloud_report_id = ? AND synced_at IS NULL`);
  const reject = db.prepare('UPDATE cloud_sync SET rejected_reason = ? WHERE cloud_report_id = ? AND synced_at IS NULL');
  const counts = db.prepare(`SELECT (SELECT COUNT(*) FROM triage_reports) AS total,
    (SELECT COUNT(*) FROM cloud_sync WHERE synced_at IS NOT NULL) AS synced,
    (SELECT COUNT(*) FROM cloud_sync WHERE synced_at IS NULL AND rejected_reason IS NOT NULL) AS rejected`);

  function status() {
    const { total, synced, rejected } = counts.get();
    const message = config.error || state.lastError;
    return {
      configured: !config.error,
      state: config.error ? 'disabled' : state.running ? 'syncing' : state.lastError ? 'error' : state.lastSuccessAt ? 'ok' : 'idle',
      message,
      pending: total - synced - rejected,
      synced,
      rejected,
      lastAttemptAt: state.lastAttemptAt,
      lastSuccessAt: state.lastSuccessAt,
    };
  }
  const notify = () => {
    const current = status();
    for (const listener of listeners) listener(current);
  };

  async function call(path, headers, body) {
    let res;
    try {
      res = await fetch(`${config.url}${path}`, {
        method: 'POST',
        headers: { apikey: config.key, 'Content-Type': 'application/json', ...headers },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(config.timeoutMs),
      });
    } catch (error) {
      throw new CloudError(error.name === 'TimeoutError' ? 'Supabase timed out' : 'Supabase unreachable (offline?)');
    }
    return { res, data: await res.json().catch(() => null) };
  }

  async function session() {
    if (state.session && state.session.expiresAt - 60000 > Date.now()) return state.session;
    state.session = null;
    const { res, data } = await call('/auth/v1/token?grant_type=password', {},
      { email: config.email, password: config.password });
    if (!res.ok || typeof data?.access_token !== 'string' || typeof data?.user?.id !== 'string') {
      throw cloudError('Supabase hub sign-in failed', res, data);
    }
    state.session = { token: data.access_token, userId: data.user.id,
      expiresAt: Date.now() + (Number(data.expires_in) || 3600) * 1000 };
    return state.session;
  }

  async function send(batch, auth) {
    const { res, data } = await call('/rest/v1/triage_reports?on_conflict=report_id&select=report_id',
      { Authorization: `Bearer ${auth.token}`, Prefer: 'resolution=merge-duplicates,return=representation' },
      batch.map(cloudPayload));
    if (res.status === 401) state.session = null;
    if (!res.ok || !Array.isArray(data)) throw cloudError('Supabase upload failed', res, data);
    const acknowledged = new Set(data.map((row) => String(row?.report_id).toLowerCase()));
    const sent = batch.filter((row) => acknowledged.has(row.cloud_report_id));
    const at = new Date().toISOString();
    db.transaction(() => { for (const row of sent) markSynced.run(at, auth.userId, row.cloud_report_id); }).immediate();
    if (sent.length !== batch.length) {
      throw new CloudError(`Supabase acknowledged ${sent.length} of ${batch.length} reports; the rest stay queued`);
    }
    return sent.length;
  }

  // A rejected batch is retried row by row so one bad report cannot block the rest.
  async function sendIsolating(batch, auth) {
    try {
      return await send(batch, auth);
    } catch (error) {
      if (!rowRejected(error)) throw error;
      if (batch.length === 1) {
        reject.run(error.message, batch[0].cloud_report_id);
        return 0;
      }
      let sent = 0;
      for (const row of batch) sent += await sendIsolating([row], auth);
      return sent;
    }
  }

  async function run() {
    state.lastAttemptAt = new Date().toISOString();
    notify();
    let sent = 0;
    try {
      db.transaction(() => {
        if (state.retryRejected) db.prepare('UPDATE cloud_sync SET rejected_reason = NULL WHERE synced_at IS NULL').run();
        const at = new Date().toISOString();
        for (const { id } of unqueued.all()) enqueue.run(id, randomUUID(), at);
      }).immediate();
      state.retryRejected = false;
      if (pending.all(1).length) {
        const auth = await session();
        for (let batch = pending.all(BATCH); batch.length; batch = pending.all(BATCH)) {
          sent += await sendIsolating(batch, auth);
        }
      }
      state.lastSuccessAt = new Date().toISOString();
      state.lastError = null;
      state.failures = 0;
    } catch (error) {
      state.lastError = error instanceof CloudError ? error.message : 'Cloud sync failed; reports stay queued';
      state.failures += 1;
    }
    const current = status();
    if (sent || state.lastError) {
      log(`[cloud] sent ${sent}, pending ${current.pending}, rejected ${current.rejected}${state.lastError ? `; ${state.lastError}` : ''}`);
    }
  }

  function schedule(delay) {
    clearTimeout(state.timer);
    if (!state.started || config.error) return;
    state.timer = setTimeout(() => {
      syncNow().catch(() => log('[cloud] sync failed; reports stay queued'));
    }, delay);
    state.timer.unref?.();
  }

  /** Runs one sync (or joins the running one) and resolves with the status. */
  function syncNow({ retryRejected = false } = {}) {
    if (config.error) return Promise.resolve(status());
    state.retryRejected ||= retryRejected;
    if (state.running) {
      state.again = true;
      return state.running.then(status);
    }
    clearTimeout(state.timer);
    state.running = run().finally(() => {
      state.running = null;
      notify();
      if (state.again) {
        state.again = false;
        schedule(0);
      } else {
        schedule(state.failures ? Math.min(config.intervalMs * 2 ** state.failures, MAX_BACKOFF_MS) : config.intervalMs);
      }
    });
    return state.running.then(status);
  }

  return {
    status,
    syncNow,
    onChange(listener) { listeners.add(listener); },
    /** New reports sync soon, but failures keep their backoff. */
    trigger() { if (!state.failures && !state.running) schedule(2000); },
    start() {
      state.started = true;
      if (config.error) log(`[cloud] disabled: ${config.error}`);
      else schedule(0);
    },
    stop() {
      state.started = false;
      clearTimeout(state.timer);
    },
  };
}

module.exports = { cloudConfig, cloudPayload, createCloudSync };
