(function () {
  'use strict';
  let token = '';
  try { token = sessionStorage.getItem('vanguard-access-token') || ''; } catch {}
  const uuid = () => '10000000-1000-4000-8000-100000000000'.replace(/[018]/g,
    c => (Number(c) ^ crypto.getRandomValues(new Uint8Array(1))[0] & 15 >> Number(c) / 4).toString(16));
  let browserId;
  try { browserId = localStorage.getItem('vanguard-browser-id'); } catch {}
  if (!browserId) { browserId = 'WEB-' + uuid(); try { localStorage.setItem('vanguard-browser-id', browserId); } catch {} }
  let owner = token ? undefined : browserId;
  if (token) { try { owner = sessionStorage.getItem('vanguard-owner'); } catch {} }
  async function request(route, options = {}) {
    if (!route.startsWith('/api/') || route.includes('..')) throw Error('Use a same-origin Vanguard API path');
    const headers = new Headers(options.headers);
    headers.set('X-Request-ID', options.requestId || uuid());
    if (token) headers.set('Authorization', 'Bearer ' + token);
    return fetch(route, { ...options, headers, signal: options.signal || AbortSignal.timeout(130000) });
  }
  async function identity() {
    if (owner) return owner;
    const response = await request('/api/config');
    if (!response.ok) throw Error('Configure your hospital access token in Settings');
    const config = await response.json();
    owner = config.user?.id || browserId;
    sessionStorage.setItem('vanguard-owner', owner);
    return owner;
  }
  const outboxKey = reportId => 'vanguard-outbox-' + owner + '/' + reportId;
  async function pending() {
    await identity();
    const legacy = 'vanguard-outbox-' + owner;
    for (const report of JSON.parse(localStorage.getItem(legacy) || '[]')) localStorage.setItem(outboxKey(report.reportId), JSON.stringify(report));
    localStorage.removeItem(legacy);
    const prefix = outboxKey('');
    return Array.from({ length: localStorage.length }, (_, index) => localStorage.key(index))
      .filter(key => key?.startsWith(prefix)).map(key => JSON.parse(localStorage.getItem(key)))
      .sort((a, b) => a.createdAt.localeCompare(b.createdAt));
  }
  async function retain(report) {
    await identity();
    // One atomic key per report prevents another tab's capture overwriting the queue.
    try { localStorage.setItem(outboxKey(report.reportId), JSON.stringify(report)); }
    catch { const error = Error('Local storage is full or unavailable; keep this transcript and retry'); error.code = 'local-storage-unavailable'; throw error; }
  }
  const extracting = new Set();
  async function prepare(report, kind = 'extract') {
    extracting.add(report.reportId);
    try {
      await retain({ ...report, readyToSend: false, aiOperation: kind });
      const requestId = uuid();
      const response = await request('/api/ai/' + kind, { method: 'POST', requestId, headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ transcript: report.rawText, device: 'hospital-browser', sttEngine: 'typed/hub-form', sttRuntime: 'hub-ai-v1' }) });
      const result = await response.json();
      if (!response.ok || result.ok !== true || result.contractVersion !== 1 || result.processing?.version !== 1
        || result.processing.originalTranscript !== report.rawText || result.requestId !== requestId
        || result.requestId !== response.headers.get('X-Request-ID')) {
        throw Error('Invalid inference response; original retained');
      }
      const allowed = { breathing: ['normal', 'abnormal', 'absent', 'unknown'], consciousness: ['alert', 'unresponsive', 'unknown'],
        severeBleeding: ['present', 'absent', 'unknown'], walking: ['able', 'unable', 'unknown'] };
      if (!Object.entries(allowed).every(([key, values]) => values.includes(result.processing.observations?.[key]))) throw Error('Invalid observations; original retained');
      await retain({ ...report, readyToSend: true, processing: result.processing });
      return result;
    } catch (error) {
      // Unavailable extraction must still preserve and transmit an Unassessed original.
      await retain({ ...report, readyToSend: true });
      throw error;
    } finally { extracting.delete(report.reportId); }
  }
  let sending;
  async function flush() {
    if (sending) return sending;
    sending = (async () => {
      for (const report of await pending()) {
        if (extracting.has(report.reportId)) continue;
        if (report.readyToSend === false) {
          try { await prepare(report, report.aiOperation); } catch {}
        }
        const current = (await pending()).find(row => row.reportId === report.reportId);
        if (!current) continue;
        const { readyToSend, aiOperation, ...wire } = current;
        const response = await request('/api/sync-triage', { method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ watchId: browserId, reports: [wire] }) });
        const body = await response.json();
        if (!response.ok || body.ok !== true || !Array.isArray(body.ackLocalIds)
          || body.ackLocalIds.length !== 1 || body.ackLocalIds[0] !== report.localId
          || !Array.isArray(body.rejected) || body.rejected.length) throw Error('Report retained; no valid hospital receipt');
        if (localStorage.getItem(outboxKey(report.reportId)) !== JSON.stringify(current)) throw Error('Report changed while awaiting receipt; updated original retained');
        localStorage.removeItem(outboxKey(report.reportId));
      }
    })().finally(() => { sending = undefined; });
    return sending;
  }
  async function events(onOpen, onTriage, onError) {
    // Bounded stream reconnects; authenticated polling remains the fallback.
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        const response = await request('/api/events', { signal: new AbortController().signal });
        if (!response.ok) throw Error('Stream access unavailable');
        onOpen();
        const reader = response.body.getReader(), decoder = new TextDecoder();
        let buffer = '';
        while (true) {
          const { value, done } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });
          let end;
          while ((end = buffer.indexOf('\n\n')) >= 0) {
            if (/^event: triage$/m.test(buffer.slice(0, end))) onTriage();
            buffer = buffer.slice(end + 2);
          }
          if (buffer.length > 1_048_576) { await reader.cancel(); throw Error('Invalid event stream'); }
        }
      } catch { onError(); }
      await new Promise(resolve => setTimeout(resolve, 2000));
    }
  }
  window.VanguardApi = { request, uuid, browserId, pending, retain, prepare, flush, events,
    async setToken(value) {
      const credential = value.trim();
      const response = await fetch('/api/config', { headers: credential ? { Authorization: 'Bearer ' + credential } : {}, signal: AbortSignal.timeout(8000) });
      if (!response.ok) throw Error('Hospital token refused');
      const config = await response.json();
      sessionStorage.setItem('vanguard-access-token', credential);
      sessionStorage.setItem('vanguard-owner', config.user?.id || browserId);
      location.reload();
    } };
})();
