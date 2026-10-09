  // What to get ready for, per finding (advisory; edit freely, no watch update needed).
  // Keys must match the canonical finding names in watch/lib/nlp/triage_parser.dart.
  const PREP = {
    'Not breathing': 'Resus bay',
    'Difficulty breathing': 'Oxygen / airway',
    'Drowning': 'Airway + warming',
    'Unconscious': 'Neuro obs',
    'Severe bleeding': 'Blood / OR',
    'Head injury': 'CT / neurosurgery',
    'Chest pain': 'ECG / cardiology',
    'Electrocution': 'Cardiac monitor',
    'Pregnant / labor': 'OB / delivery',
    'Fracture': 'X-ray / ortho',
    'Laceration': 'Suturing',
    'Bleeding': 'Haemostasis',
    'Hypothermia': 'Active warming',
    'Burn': 'Burn care',
    'Snakebite': 'Antivenom',
    'Weak / dehydrated': 'IV fluids',
  };
  const category = (r) => r.effective_triage || r.triage;
  const TRIAGE = ['Immediate', 'Unassessed', 'Delayed', 'Minor', 'Deceased'];
  const RANK = { Immediate: 0, Unassessed: 1, Delayed: 2, Minor: 3, Deceased: 4 };
  // Display names follow START mass-casualty triage; the stored values (the keys) never change.
  const LABEL = { Immediate: 'Immediate', Unassessed: 'Unassessed', Delayed: 'Delayed', Minor: 'Minor', Deceased: 'Deceased' };
  const VIEW_TITLE = { inbound: 'On the way', arrived: 'Arrived', cancelled: 'Cancelled', all: 'All reports', settings: 'Settings' };

  let rows = [];
  let view = 'inbound';
  let cat = null;
  let query = '';
  const expanded = {}; // patient rows the user opened or closed, by report id; unset follows the priority patient
  let autoId = null; // On the way: the highest provisional priority patient, open until the user says otherwise
  let range = 60; // board look-ahead, in minutes (60 or 180)
  let show = 'all'; // On the way board: all | urgent (Immediate and Unassessed)
  let bsel = null; // board column the user picked (0-5, 'later' or 'noeta'); null follows the soonest column with patients
  let loadState = 'loading'; // loading | ok | error
  let retrying = false;
  const PAGE = 50;
  let limit = PAGE;
  const seen = new Set();
  let firstLoad = true;
  let soundOn = false;
  let themePref = 'auto';
  let ready = {}; // readiness ticks per report id, kept in this browser only
  try {
    soundOn = localStorage.getItem('sound') === '1';
    show = localStorage.getItem('show') === 'urgent' ? 'urgent' : 'all';
    themePref = localStorage.getItem('theme') || 'auto';
    ready = JSON.parse(localStorage.getItem('ready') || '{}') || {};
  } catch (_) {}
  const saveReady = () => { try { localStorage.setItem('ready', JSON.stringify(ready)); } catch (_) {} };

  const $ = (id) => document.getElementById(id);
  const fmt = (iso) => new Date(iso).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  const num = (n) => new Intl.NumberFormat().format(n);
  const plural = (n, w) => `${num(n)} ${w}${n === 1 ? '' : 's'}`;

  function el(tag, cls, text) {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text !== undefined) n.textContent = text; // textContent only: transcripts are untrusted
    return n;
  }
  const shape = (c) => el('i', `shape ${c}`);
  const fmtDur = (m) => {
    if (m < 60) return `${num(m)} min`;
    if (m < 1440) { const h = Math.floor(m / 60), r = m % 60; return r ? `${h} h ${r} min` : `${h} h`; }
    const d = Math.floor(m / 1440), h = Math.floor((m % 1440) / 60);
    return h ? `${num(d)} d ${h} h` : `${num(d)} d`;
  };
  const ago = (iso) => {
    const m = Math.round((Date.now() - Date.parse(iso)) / 60000);
    return m < 1 ? 'just now' : m === 1 ? '1 min ago' : `${fmtDur(m)} ago`;
  };
  // An air-gapped watch has no network time. A clock that is days off, or ahead of the hub,
  // cannot anchor a countdown, so fall back to when the hub received the report.
  const badClock = (r) => {
    const c = Date.parse(r.created_at), v = Date.parse(r.received_at);
    return !Number.isFinite(c) || (Number.isFinite(v) && (v - c > 7 * 864e5 || c - v > 2 * 36e5));
  };
  const baseIso = (r) => (badClock(r) ? r.received_at : r.created_at);
  const etaAt = (r) => (r.eta_minutes ? Date.parse(baseIso(r)) + r.eta_minutes * 60000 : null);
  const minsLeft = (r) => { const t = etaAt(r); return t === null ? null : Math.round((t - Date.now()) / 60000); };
  // Draft setups for terms the hospital's own table above does not cover (public/setups.json).
  // The hospital's mappings always win; the draft is unreviewed and labelled as such.
  const PREP_DRAFT = {};
  const prepFor = (label) => (PREP[label] ? [PREP[label]] : (PREP_DRAFT[label] || []));
  const labelsOf = (r) => r.injuries.split(',').map((s) => s.trim());
  const usesDraft = (r) => labelsOf(r).some((s) => !PREP[s] && PREP_DRAFT[s]);
  const needsOf = (r) => [...new Set(labelsOf(r).flatMap(prepFor))];
  // For a report saved from the AI panel (findings superseded by AI processing, transcript not
  // corrected since), list setups for its saved terms as a read-only suggestion, each with the
  // saved term that caused it so a reviewer can check the link. They are never part of
  // readyItems, the readiness count or the board totals, which keep the safety rule.
  const suggestedOf = (r) => {
    if (!(r.source_findings_current === false && r.processing && r.current_transcript === r.raw_text)) return [];
    const why = new Map();
    for (const label of labelsOf(r)) {
      for (const setup of prepFor(label)) why.set(setup, [...(why.get(setup) || []), label]);
    }
    // Same age rule the board's checklist already applies.
    if ((r.age_group === 'Child' || r.age_group === 'Infant') && !why.has('Paediatrics')) why.set('Paediatrics', [`age group ${r.age_group}`]);
    return [...why].map(([setup, because]) => ({ setup, because }));
  };
  const readyItems = (r) => {
    if (r.source_findings_current === false) return [];
    const set = new Set(needsOf(r));
    if (r.age_group === 'Child' || r.age_group === 'Infant') set.add('Paediatrics');
    return [...set];
  };
  const countOf = (r) => r.patient_count_known === false ? 0 : r.patient_count;
  const patients = (list) => list.reduce((s, r) => s + countOf(r), 0);
  const noun = (r) => {
    if (r.patient_count_known === false) return 'Patient count unknown';
    const o = { Child: ['child', 'children'], Infant: ['infant', 'infants'], Elderly: ['elderly patient', 'elderly patients'], Adult: ['adult', 'adults'] }[r.age_group] || ['patient', 'patients'];
    return `${num(r.patient_count)} ${o[r.patient_count === 1 ? 0 : 1]}`;
  };

  // ---------- data ----------
  async function load() {
    try {
      const res = await fetch('/api/triage');
      if (!res.ok) throw new Error('bad status');
      const next = await res.json();
      const fresh = firstLoad ? [] : next.filter((r) => !seen.has(r.id));
      rows = next;
      loadState = 'ok';
      for (const k of Object.keys(expanded)) if (!rows.some((r) => String(r.id) === k)) delete expanded[k];
      for (const k of Object.keys(ready)) if (!rows.some((r) => String(r.id) === k)) delete ready[k];
      saveReady();
      render();
      announceAll(fresh);
    } catch (_) {
      loadState = 'error';
      render();
    }
  }

  async function setStatus(r, status, btn) {
    btn.disabled = true;
    btn.classList.add('loading');
    btn.setAttribute('aria-busy', 'true');
    try {
      const res = await fetch(`/api/triage/${r.id}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ status }),
      });
      if (!res.ok) throw new Error('bad status');
      await load();
    } catch (_) {
      btn.disabled = false;
      btn.classList.remove('loading');
      btn.removeAttribute('aria-busy');
      toast('Could not update this report. Check the hub connection and try again.');
    }
  }

  // ---------- theme ----------
  const mq = window.matchMedia('(prefers-color-scheme: dark)');
  function applyTheme() {
    const dark = themePref === 'dark' || (themePref === 'auto' && mq.matches);
    document.documentElement.setAttribute('data-theme', dark ? 'dark' : 'light');
    document.querySelector('meta[name="theme-color"]').setAttribute('content', dark ? '#061419' : '#DCEDF1');
    document.querySelectorAll('.seg button').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.t === themePref)));
  }
  document.querySelectorAll('.seg button').forEach((b) => {
    b.onclick = () => {
      themePref = b.dataset.t;
      try { localStorage.setItem('theme', themePref); } catch (_) {}
      applyTheme();
    };
  });
  mq.addEventListener('change', applyTheme); // follow the OS while on Auto
  applyTheme();

  // ---------- alerts ----------
  function toast(title, sub, category) {
    const t = el('div', `toast ${category || ''}`, title);
    if (sub) t.append(el('small', '', sub));
    const box = $('toasts');
    while (box.children.length >= 4) box.firstChild.remove(); // never let a backlog fill the screen
    box.append(t);
    setTimeout(() => t.remove(), 7000);
  }
  function announce(r) {
    toast(`New ${LABEL[category(r)]} · ${noun(r)}: ${r.injuries}`,
          `From ${r.location}${r.eta_minutes ? `, ETA ${r.eta_minutes} min` : ''}`, category(r));
    if (soundOn && category(r) === 'Immediate') beep();
  }
  // A watch syncing a backlog arrives as one batch: summarise it instead of one toast per report.
  function announceAll(list) {
    if (list.length <= 3) { list.forEach(announce); return; }
    const imm = list.filter((r) => category(r) === 'Immediate');
    toast(plural(list.length, 'new report'),
          `${plural(patients(list), 'patient')}${imm.length ? `, ${plural(patients(imm), 'Immediate patient')}` : ''}`,
          imm.length ? 'Immediate' : '');
    if (soundOn && imm.length) beep();
  }
  function beep() {
    try {
      const ctx = new (window.AudioContext || window.webkitAudioContext)();
      [0, 0.28, 0.56].forEach((d) => {
        const o = ctx.createOscillator(), g = ctx.createGain();
        o.frequency.value = 880; o.connect(g); g.connect(ctx.destination);
        g.gain.setValueAtTime(0.15, ctx.currentTime + d); g.gain.setValueAtTime(0, ctx.currentTime + d + 0.18);
        o.start(ctx.currentTime + d); o.stop(ctx.currentTime + d + 0.2);
      });
    } catch (_) {}
  }

  // ---------- derived data ----------
  const inView = () => rows.filter((r) => view === 'all' || r.status === view);
  const matches = (r, q) => !q || [r.injuries, r.location, r.watch_id, r.raw_text, r.current_transcript, r.age_group, r.triage, category(r), LABEL[category(r)]].join(' ').toLowerCase().includes(q);
  function visible() {
    const q = query.trim().toLowerCase();
    return inView().filter((r) => (!cat || category(r) === cat) && matches(r, q));
  }
  // On the way ignores the category tabs: the board's own Show control and rows do that job.
  function inboundList() {
    const q = query.trim().toLowerCase();
    return inView().filter((r) => matches(r, q));
  }
  function priorityPatient(list) {
    const live = list.filter((r) => category(r) !== 'Deceased');
    return live.sort((a, b) => RANK[category(a)] - RANK[category(b)]
      || (etaAt(a) ?? Infinity) - (etaAt(b) ?? Infinity))[0] || null;
  }
  const isOpen = (r) => (r.id in expanded ? expanded[r.id] : r.id === autoId);

  // ---------- render ----------
  // One atomic, debounced spoken status for meaningful changes in the totals, instead of making every counter live.
  let lastStatus = '', statusTimer = null;
  function announceStatus(inbound) {
    if (loadState !== 'ok') return;
    const total = patients(inbound), need = patients(inbound.filter((r) => category(r) === 'Immediate'));
    const msg = total
      ? `${plural(total, 'patient')} inbound, ${num(need)} ${need === 1 ? 'needs' : 'need'} care right away`
      : 'No patients inbound';
    if (firstLoad) { lastStatus = msg; return; }
    if (msg === lastStatus) return;
    lastStatus = msg;
    clearTimeout(statusTimer);
    statusTimer = setTimeout(() => { $('live-status').textContent = msg; }, 800);
  }

  // Lists and panels are rebuilt on every update, which would drop keyboard focus.
  // Controls carry data-fk; after a rebuild, focus goes back to the matching control.
  function restoreFocus(key) {
    let n = document.querySelector(`[data-fk="${CSS.escape(key)}"]`);
    if (!n && key.startsWith('act:')) n = document.querySelector('#list .item') || $('list-h');
    if (n && n !== document.activeElement) {
      if (!n.matches('button, input, a, summary')) n.tabIndex = -1;
      n.focus({ preventScroll: true });
    }
  }

  function render() {
    const focusKey = document.activeElement && document.activeElement.dataset ? document.activeElement.dataset.fk : null;
    const inbound = rows.filter((r) => r.status === 'inbound');
    announceStatus(inbound);
    renderNav();
    const list = loadState === 'loading' ? [] : view === 'inbound' ? inboundList() : isHistory() ? historyRows() : visible();
    renderSummary(inbound, list);
    renderCats();
    renderFilters();
    renderAlert();
    autoId = view === 'inbound' ? (priorityPatient(list.filter((r) => r.status === 'inbound')) || {}).id ?? null : null;
    const board = renderBoard(list); // On the way: the reports in the chosen time block; other views: the whole list
    const hist = renderHistory(list); // always runs, so it can hide itself when leaving Arrived or Cancelled
    renderList(board || hist || list);
    renderPrep(inbound);
    for (const r of rows) seen.add(r.id);
    if (loadState === 'ok') firstLoad = false;
    if (focusKey) restoreFocus(focusKey);
  }

  function renderNav() {
    for (const k of ['inbound', 'arrived', 'cancelled'])
      $('t-' + k).textContent = num(rows.filter((r) => r.status === k).length);
    $('t-all').textContent = num(rows.length);
    document.querySelectorAll('.vtab').forEach((b) => {
      const on = b.dataset.f === view;
      b.setAttribute('aria-selected', String(on));
      b.tabIndex = on ? 0 : -1; // roving tabindex: arrow keys move between tabs
    });
    if (view !== 'settings') $('view-panel').setAttribute('aria-labelledby', 'tab-' + view);
    document.querySelector('.app').dataset.view = view;
    $('view-title').textContent = VIEW_TITLE[view];
  }

  // One sentence that says exactly what is on screen: the status tab, the category and any search.
  function renderSummary(inbound, list) {
    const s = $('sline');
    if (loadState === 'loading') { s.textContent = 'Loading reports'; return; }
    if (view === 'inbound' && !query.trim()) {
      const total = patients(inbound), need = patients(inbound.filter((r) => category(r) === 'Immediate'));
      s.textContent = total
        ? `${plural(total, 'patient')} on the way, ${num(need)} ${need === 1 ? 'needs' : 'need'} care right away`
        : 'No one is on the way';
      return;
    }
    const q = query.trim();
    if (isHistory()) {
      const bits = [];
      if (cat) bits.push(LABEL[cat]);
      if (q) bits.push(`matching “${q.length > 24 ? q.slice(0, 23) + '…' : q}”`);
      const verb = view === 'arrived' ? 'arrived' : 'were cancelled';
      s.textContent = list.length
        ? `${plural(patients(list), 'patient')} in ${plural(list.length, 'report')} ${verb}${bits.length ? ', ' + bits.join(', ') : ''}`
        : bits.length ? `No reports match: ${bits.join(', ')}` : view === 'arrived' ? 'No one has arrived yet' : 'Nothing has been cancelled';
      return;
    }
    const bits = [VIEW_TITLE[view]];
    if (cat && view !== 'inbound') bits.push(LABEL[cat]);
    if (q) bits.push(`matching “${q.length > 24 ? q.slice(0, 23) + '…' : q}”`);
    s.textContent = `Showing ${bits.join(', ')}: ${plural(list.length, 'report')}, ${plural(patients(list), 'patient')}`;
  }

  function renderCats() {
    const box = $('cats');
    box.replaceChildren();
    const list = inView();
    const mk = (label, count, value) => {
      const b = el('button', `tab${value ? ' cat ' + value : ''}${count === 0 ? ' zero' : ''}`);
      b.type = 'button';
      b.dataset.fk = 'cat:' + label;
      b.setAttribute('aria-pressed', String(cat === value));
      if (value) b.append(shape(value));
      b.append(document.createTextNode(label), el('span', 'n', num(count)));
      b.onclick = () => setCat(cat === value ? null : value);
      return b;
    };
    $('cat-clear').hidden = !cat;
    box.append(mk('All categories', patients(list), null));
    for (const t of TRIAGE) box.append(mk(LABEL[t], patients(list.filter((r) => category(r) === t)), t));
  }

  function renderFilters() {
    const filters = $('filters');
    filters.replaceChildren();
    const chip = (label, onRemove, full) => {
      const b = el('button', 'fchip', label);
      b.type = 'button';
      b.dataset.fk = 'chip:' + label;
      b.title = full || label;
      const x = el('span', '', '×');
      x.setAttribute('aria-hidden', 'true');
      b.append(x, el('span', 'sr-only', ', remove filter'));
      b.onclick = onRemove;
      filters.append(b);
    };
    if (query.trim()) {
      const q = query.trim();
      chip(`“${q.length > 28 ? q.slice(0, 27) + '…' : q}”`, () => { setQuery(''); }, q);
    }
    $('qx').hidden = !query;
  }

  function renderAlert() {
    const alertBox = $('alert');
    alertBox.replaceChildren();
    if (loadState !== 'error') return;
    const a = el('div', 'alert', 'Cannot reach the hub. Showing the last data and retrying every 10 seconds.');
    a.setAttribute('role', 'alert');
    const retry = el('button', 'btn', 'Retry now');
    retry.type = 'button';
    retry.dataset.fk = 'retry';
    if (retrying) { retry.disabled = true; retry.classList.add('loading'); }
    retry.onclick = async () => { retrying = true; render(); await load(); retrying = false; render(); };
    a.append(retry);
    alertBox.append(a);
  }

  // time to arrival, as a compact block for the list
  function timeBlock(r, base) {
    const box = el('div', base);
    if (r.status !== 'inbound') { box.classList.add('plain'); box.textContent = r.status.charAt(0).toUpperCase() + r.status.slice(1); return box; }
    const m = minsLeft(r);
    if (m === null) { box.append('Unknown', el('small', '', 'no time given')); return box; }
    if (m > 10) box.append(fmtDur(m), el('small', '', 'until arrival'));
    else if (m > 1) { box.classList.add('soon'); box.append(`${m} min`, el('small', '', 'arriving soon')); }
    else if (m >= -2) { box.classList.add('soon'); box.append('Now', el('small', '', 'arriving')); }
    else { box.classList.add('late'); box.append(`+${fmtDur(-m)}`, el('small', '', 'past ETA')); }
    return box;
  }

  function actionBtn(r, label, status, kind, scope = 'row') {
    const b = el('button', `btn ${kind || ''}`, label);
    b.type = 'button';
    b.dataset.fk = `act:${scope}:${r.id}:${status}`;
    b.setAttribute('aria-label', `${label}: ${LABEL[category(r)]}, ${noun(r)}, ${r.injuries}, from ${r.location}`);
    b.onclick = () => setStatus(r, status, b);
    return b;
  }

  // Everything one patient needs, opened from their row: counts, readiness checklist, notes and actions.
  function renderDetail(r) {
    const box = el('div', 'detail');
    const stats = el('div', 'stats');
    const stat = (k, v) => { const d = el('div', 'stat'); d.append(el('small', '', k), el('b', '', v)); return d; };
    stats.append(stat('Patients', r.patient_count_known === false ? 'Unknown' : '×' + num(r.patient_count)), stat('Age', r.age_group === 'Unspecified' ? 'Unknown' : r.age_group), stat('Category', LABEL[category(r)]));
    box.append(stats);
    box.append(el('p', 'note', `Provisional · verify clinically · source category: ${r.triage}`));
    if (r.risk_reason) box.append(el('p', 'note', `${r.rule_version}: ${r.risk_reason}`));
    if (r.clinician_override) box.append(el('p', 'note', `Operator override: ${r.clinician_override} · computed: ${r.computed_triage} · identity unverified`));
    for (const uncertainty of r.uncertainties || []) box.append(el('p', 'warn', uncertainty));
    if (r.current_transcript !== r.raw_text) box.append(el('p', 'r-raw', 'Current corrected transcript: ' + r.current_transcript));

    // readiness checklist (kept in this browser only)
    const items = r.status === 'inbound' && category(r) !== 'Deceased' ? readyItems(r) : [];
    if (items.length) {
      const prep = el('div', 'prep');
      const head = el('p', 'prep-h', 'Get ready');
      const cnt = el('span', '');
      head.append(cnt);
      prep.append(head);
      if (usesDraft(r)) prep.append(el('p', 'note', 'Some setups are an unreviewed draft, not clinician-approved. Check them against your protocols.'));
      const done = new Set(ready[r.id] || []);
      const note = el('p', 'note');
      note.setAttribute('aria-live', 'polite');
      const upd = () => {
        const k = items.filter((x) => done.has(x)).length;
        cnt.textContent = `${k} of ${items.length} ready`;
        note.textContent = k < items.length ? `${items.length - k} not ready yet. You can still mark arrival.` : '';
      };
      for (const it of items) {
        const lab = el('label', 'ck');
        const cb = document.createElement('input');
        cb.type = 'checkbox';
        cb.checked = done.has(it);
        cb.onchange = () => {
          if (cb.checked) done.add(it); else done.delete(it);
          ready[r.id] = [...done];
          saveReady();
          upd();
        };
        lab.append(cb, el('span', '', it));
        prep.append(lab);
      }
      prep.append(note);
      upd();
      box.append(prep);
    }
    const suggested = r.status === 'inbound' && category(r) !== 'Deceased' ? suggestedOf(r) : [];
    if (suggested.length) {
      const sug = el('div', 'prep');
      sug.append(el('p', 'prep-h', 'Suggested setups (draft)'),
        el('p', 'note', 'From the saved terms only. Not part of the readiness count. Unreviewed: check against your protocols.'),
        ...suggested.map((s) => el('p', '', `${s.setup} \u2014 because: ${s.because.join(', ')}`)));
      box.append(sug);
    }
    const unmapped = r.injuries.split(',').map((x) => x.trim()).filter((x) => x && x !== 'Unspecified' && (r.source_findings_current === false ? !PREP[x] : !prepFor(x).length));
    if (category(r) !== 'Deceased' && r.status === 'inbound' && (unmapped.length || r.injuries === 'Unspecified')) {
      box.append(el('p', 'warn', r.injuries === 'Unspecified'
        ? 'No findings were understood. Read the note first.'
        : suggested.length
          ? `No hospital-approved preparation is mapped for ${unmapped.join(', ')}; see the draft suggestion above. Read the note.`
          : `No preparation mapped for ${unmapped.join(', ')}. Read the note.`));
    }
    if (r.raw_text) {
      const d = el('details', 'rnote');
      d.append(el('summary', '', 'Rescuer note'), el('p', 'r-raw', '“' + r.raw_text + '”'));
      box.append(d);
    }
    box.append(el('p', 'r-meta', badClock(r)
      ? `${r.watch_id}, watch clock looks wrong, received ${ago(r.received_at)} (${fmt(r.received_at)})`
      : `${r.watch_id}, reported ${ago(r.created_at)} (${fmt(r.created_at)}), received ${fmt(r.received_at)}`));

    const act = el('div', 'dact');
    if (r.status === 'inbound') act.append(actionBtn(r, 'Mark arrived', 'arrived', 'primary'), actionBtn(r, 'Cancel report', 'cancelled', 'quiet'));
    else act.append(actionBtn(r, 'Reopen', 'inbound', ''));
    box.append(act);
    const evidence = el('button', 'btn quiet', 'Evidence and corrections');
    evidence.type = 'button';
    evidence.onclick = () => openEvidence(r);
    box.append(evidence);
    return box;
  }

  function newUUID() {
    const bytes = crypto.getRandomValues(new Uint8Array(16)); bytes[6] = (bytes[6] & 15) | 64; bytes[8] = (bytes[8] & 63) | 128;
    const hex = [...bytes].map(byte => byte.toString(16).padStart(2, '0')).join('');
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  }

  async function openEvidence(r) {
    const dialog = el('dialog', 'evidence-dialog');
    dialog.setAttribute('aria-label', 'Report evidence and corrections');
    const close = el('button', 'btn quiet', 'Close');
    close.type = 'button'; close.onclick = () => dialog.close();
    const content = el('div', '', 'Loading evidence…');
    dialog.append(close, content);
    dialog.addEventListener('close', () => dialog.remove());
    document.body.append(dialog); dialog.showModal();
    try {
      const response = await fetch(`/api/triage/${r.id}`);
      if (!response.ok) throw new Error('Could not load evidence');
      const detail = await response.json();
      content.replaceChildren(el('h2', '', 'Original evidence'), el('pre', '', detail.raw_text));
      content.append(el('p', 'note', `Encounter: ${detail.encounter_id} · hospital receipt recorded · clinical verification required`));
      const extract = el('button', 'btn primary', 'Extract this report with Qwen'); extract.type = 'button';
      const aiState = el('p', 'note'); aiState.setAttribute('role', 'status');
      const requestId = newUUID();
      extract.onclick = async () => {
        extract.disabled = true; aiState.textContent = 'Extracting locally; original report is already stored…';
        try {
          const response = await fetch(`/api/triage/${r.id}/ai-extract`, { method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ requestId, baseRevision: detail.revision }) });
          const data = await response.json();
          if (!response.ok) throw new Error(data.message || data.error || 'Inference failed');
          dialog.close(); await load(); await openEvidence(data.report);
        } catch (error) { aiState.textContent = error.message + '. Original remains stored; retry or reload after a correction.'; }
        finally { extract.disabled = false; }
      };
      content.append(extract, aiState);
      for (const revision of detail.history) {
        const item = el('details', 'rnote');
        item.append(el('summary', '', `Revision ${revision.revision} · ${revision.kind} · ${revision.actor} · ${fmt(revision.created_at)}`),
          el('p', '', revision.reason), el('pre', '', revision.state.transcript),
          el('p', 'note', `${revision.assessment.rule_version}: ${revision.assessment.risk_reason}`));
        if (revision.state.processing) item.append(el('pre', '', JSON.stringify(revision.state.processing, null, 2)));
        content.append(item);
      }
      const form = el('form');
      const field = (title, control) => { const label = el('label', '', title); label.append(control); form.append(label); return control; };
      const kind = field('Change', el('select'));
      for (const [value, title] of [['correction', 'Correct transcript'], ['override', 'Set or clear provisional priority']]) {
        const option = el('option', '', title); option.value = value; kind.append(option);
      }
      const transcript = field('Corrected transcript', el('textarea')); transcript.rows = 5; transcript.maxLength = 16000; transcript.value = detail.current_transcript;
      const priority = field('Provisional priority', el('select'));
      for (const value of ['', 'Immediate', 'Unassessed', 'Delayed', 'Minor']) {
        const option = el('option', '', value || 'Use computed priority'); option.value = value; priority.append(option);
      }
      priority.value = detail.clinician_override || '';
      const actor = field('Your name or operator label', el('input')); actor.required = true; actor.maxLength = 100;
      const reason = field('Reason for change', el('textarea')); reason.required = true; reason.maxLength = 500;
      const toggle = () => { transcript.parentElement.hidden = kind.value !== 'correction'; priority.parentElement.hidden = kind.value !== 'override'; };
      kind.onchange = toggle; toggle();
      form.append(el('p', 'note', 'Corrections preserve the original and clear stale extraction and overrides. Operator labels are not authenticated.'));
      const status = el('p', 'warn'); status.setAttribute('role', 'status');
      const save = el('button', 'btn primary', 'Save revision'); save.type = 'submit';
      form.append(save, status); content.append(form);
      let attempt;
      form.onsubmit = async (event) => {
        event.preventDefault();
        const change = { baseRevision: detail.revision, kind: kind.value, actor: actor.value, reason: reason.value,
          ...(kind.value === 'correction' ? { transcript: transcript.value } : { override: priority.value || null }) };
        // Keep the same request ID after a lost response; changing the edit starts another request.
        const signature = JSON.stringify(change);
        if (!attempt || attempt.signature !== signature) {
          const bytes = crypto.getRandomValues(new Uint8Array(16)); bytes[6] = (bytes[6] & 15) | 64; bytes[8] = (bytes[8] & 63) | 128;
          const hex = [...bytes].map((byte) => byte.toString(16).padStart(2, '0')).join('');
          attempt = { signature, requestId: `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}` };
        }
        save.disabled = true;
        try {
          const response = await fetch(`/api/triage/${r.id}/revisions`, { method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ ...change, requestId: attempt.requestId }) });
          const result = await response.json();
          if (!response.ok) throw new Error(result.error || 'Could not save revision');
          dialog.close(); await load();
        } catch (error) { status.textContent = error.message + '. Your edit is retained; retry or close and reload current evidence.'; }
        finally { save.disabled = false; }
      };
    } catch (_) { content.textContent = 'Could not load evidence. Check the hub connection and reopen.'; }
  }

  // ---------- On the way board ----------
  // One row per level, one column per time block, one block per patient. Choosing a column lists
  // its reports below. Reports with no ETA, or later than the look-ahead, get their own columns
  // so nothing falls off the board. Display only: priority and categories are untouched.
  const URGENT = ['Immediate', 'Unassessed'];
  const BLOCKS = 8; // patients drawn per cell before "+N"
  const unit = () => (range === 60 ? 10 : 0.5);
  const unitName = () => (range === 60 ? 'min' : 'h');
  // 10-minute blocks read as "10 to 20 min"; 30-minute blocks as "30 min to 1 h"
  const phrase = (i) => (range === 60 ? `${num(i * 10)} to ${num((i + 1) * 10)} min` : `${i ? fmtDur(i * 30) : '0'} to ${fmtDur((i + 1) * 30)}`);
  const joinAnd = (a) => (a.length < 2 ? a.join('') : `${a.slice(0, -1).join(', ')} and ${a[a.length - 1]}`);
  let boardTitle = '';
  let boardEmpty = { t: 'No one is on the way', p: 'Reports appear here as soon as a rescue watch reaches this network.' };
  let boardKeys = [], boardCur;

  function colOf(r) {
    const m = minsLeft(r);
    if (m === null) return 'noeta';
    if (m >= range) return 'later';
    return Math.max(0, Math.min(5, Math.floor(m / (range / 6)))); // anyone due or past ETA counts in the first block
  }
  const colLabel = (k) => (k === 'later' ? 'Later' : k === 'noeta' ? 'No ETA' : `${num(k * unit())}–${num((k + 1) * unit())}`);
  const colPhrase = (k) => (k === 'later' ? `later than ${range === 60 ? '1 hour' : '3 hours'}` : k === 'noeta' ? 'with no ETA' : `in ${phrase(k)}`);
  function nextText(list) {
    const m = list.map((r) => minsLeft(r)).filter((x) => x !== null);
    if (!m.length) return '';
    const n = Math.min(...m);
    return n > 1 ? `next in ${fmtDur(n)}` : n >= -2 ? 'next now' : `${fmtDur(-n)} past ETA`;
  }
  function selectCol(k) { bsel = k; limit = PAGE; render(); }

  const hasUnknown = (rs) => rs.some((r) => r.patient_count_known === false);
  function blocksInto(cell, rs, c) {
    let left = BLOCKS;
    for (const r of rs) {
      if (r.patient_count_known === false) { // the rescuer gave no count: show one "?" block, not a guess
        const q = el('span', `blk unknown ${c}`, '?');
        cell.append(q);
        continue;
      }
      for (let i = 0; i < r.patient_count && left > 0; i++, left--) {
        const b = el('span', `blk ${c}`);
        b.append(shape(c));
        cell.append(b);
      }
    }
    const more = patients(rs) - BLOCKS;
    if (more > 0) cell.append(el('span', 'plus', `+${num(more)}`));
  }

  // Returns the reports in the chosen column for the list below, or null outside On the way.
  function renderBoard(list) {
    const sec = $('board-sec');
    sec.hidden = view !== 'inbound';
    if (sec.hidden) return null;
    document.querySelectorAll('[data-s]').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.s === show)));
    document.querySelectorAll('[data-r]').forEach((b) => b.setAttribute('aria-pressed', String(Number(b.dataset.r) === range)));
    const insight = $('insight'), board = $('board'), fold = $('fold');
    board.replaceChildren();
    fold.hidden = true;
    $('bnote').textContent = '';
    if (loadState === 'loading') {
      insight.hidden = false;
      insight.replaceChildren(el('span', '', 'Loading reports'));
      board.append(el('div', 'skel'));
      return [];
    }

    const levels = show === 'urgent' ? URGENT : TRIAGE;
    const shown = list.filter((r) => levels.includes(category(r)));
    const hidden = list.filter((r) => !levels.includes(category(r)));
    const by = new Map([0, 1, 2, 3, 4, 5].map((k) => [k, []]));
    for (const r of shown) {
      const k = colOf(r);
      if (!by.has(k)) by.set(k, []);
      by.get(k).push(r);
    }
    boardKeys = [0, 1, 2, 3, 4, 5, 'later', 'noeta'].filter((k) => by.has(k));
    const filled = (k) => (by.get(k) || []).length > 0;
    const pp = priorityPatient(shown);
    const ppCol = pp ? colOf(pp) : undefined; // open on the block that holds the priority patient until the user picks one
    boardCur = boardKeys.includes(bsel) && filled(bsel) ? bsel : ppCol !== undefined && filled(ppCol) ? ppCol : boardKeys.find(filled);

    // one sentence: where the busiest block is
    let bi = null, bt = 0;
    for (let k = 0; k < 6; k++) { const t = patients(by.get(k)); if (t > bt) { bt = t; bi = k; } }
    insight.replaceChildren();
    insight.hidden = !shown.length;
    if (shown.length) {
      if (bi === null) {
        insight.append(el('b', '', `No arrivals in the next ${range === 60 ? 'hour' : '3 hours'}`));
        insight.append(el('small', '', 'Select to see the rest'));
        insight.onclick = () => selectCol(boardCur);
      } else {
        const imm = patients(by.get(bi).filter((r) => category(r) === 'Immediate'));
        insight.append('Busiest: ', el('b', '', phrase(bi)), `, ${plural(bt, 'patient')}`);
        if (imm) insight.append(`, ${num(imm)} ${imm === 1 ? 'needs' : 'need'} care right away`);
        insight.append(el('small', '', 'Select to jump there'));
        insight.onclick = () => selectCol(bi);
      }
    }

    // empty states
    if (!list.length) boardEmpty = { t: 'No one is on the way', p: 'Reports appear here as soon as a rescue watch reaches this network.' };
    else if (!shown.length) boardEmpty = { t: 'No one needs attention right now', p: `${joinAnd(TRIAGE.filter((t) => !levels.includes(t)).map((t) => LABEL[t]))} reports are hidden. Choose Everyone to see them.` };
    if (!shown.length) {
      boardTitle = '';
      if (hidden.length) showFold(fold, hidden, levels);
      return [];
    }

    // header row
    board.style.setProperty('--cols', String(boardKeys.length));
    board.append(el('span', 'hu', unitName() === 'min' ? 'minutes' : 'hours'));
    for (const k of boardKeys) {
      const h = el('button', 'hc', colLabel(k));
      h.type = 'button';
      h.dataset.fk = `hc:${k}`;
      h.dataset.row = 'hc';
      h.dataset.col = String(k);
      h.setAttribute('aria-pressed', String(k === boardCur));
      h.onclick = () => selectCol(k);
      board.append(h);
    }
    // one row per level
    const cell = (rs, k, rowKey, label, c) => {
      const n = patients(rs), unknown = hasUnknown(rs);
      const b = el('button', `bcell ${c || 't'}${n || unknown ? '' : ' z'}`);
      b.type = 'button';
      b.dataset.fk = `cell:${rowKey}:${k}`;
      b.dataset.row = rowKey;
      b.dataset.col = String(k);
      b.tabIndex = c && k === boardCur ? 0 : -1; // roving: only the chosen block's cells are tab stops
      b.setAttribute('aria-pressed', String(k === boardCur));
      b.setAttribute('aria-label', `${k === 'later' || k === 'noeta' ? colLabel(k) : phrase(k)}, ${label}: ${plural(n, 'patient')}${unknown ? ', plus reports with an unknown patient count' : ''}`);
      if (c) { if (n || unknown) blocksInto(b, rs, c); else b.append(el('span', '', '–')); } else b.textContent = n ? num(n) + (unknown ? '+' : '') : unknown ? '?' : '–';
      b.onclick = () => selectCol(k);
      return b;
    };
    for (const lv of levels) {
      const all = list.filter((r) => category(r) === lv);
      const lab = el('div', `rlab ${lv}`);
      const r1 = el('span', 'r');
      r1.append(shape(lv), document.createTextNode(LABEL[lv]));
      lab.append(r1, el('small', '', [`${num(patients(all))} in total`, nextText(all)].filter(Boolean).join(' · ')));
      board.append(lab);
      for (const k of boardKeys) board.append(cell(by.get(k).filter((r) => category(r) === lv), k, lv, LABEL[lv], lv));
    }
    const totLab = el('div', 'rlab tot');
    totLab.append(el('span', 'r', show === 'all' ? 'Everyone' : 'Shown'), el('small', '', 'patients per block'));
    board.append(totLab);
    for (const k of boardKeys) board.append(cell(by.get(k), k, 'tot', 'everyone shown', null));

    if (hidden.length) showFold(fold, hidden, levels);
    const past = patients(shown.filter((r) => { const m = minsLeft(r); return m !== null && m <= 0; }));
    const unknownReports = shown.filter((r) => r.patient_count_known === false).length;
    $('bnote').textContent = [
      past ? `${plural(past, 'patient')} past ETA, counted in the first block` : '',
      unknownReports ? `${plural(unknownReports, 'report')} with an unknown patient count shown as ?` : '',
    ].filter(Boolean).join(' · ');

    // the reports of the chosen column
    const rs = by.get(boardCur).slice().sort((a, b) => RANK[category(a)] - RANK[category(b)] || (etaAt(a) ?? Infinity) - (etaAt(b) ?? Infinity));
    boardTitle = colPhrase(boardCur).replace(/^./, (c) => c.toUpperCase());
    return rs;
  }
  function showFold(fold, hidden, levels) {
    fold.hidden = false;
    fold.replaceChildren(el('span', '', `${joinAnd(TRIAGE.filter((t) => !levels.includes(t)).map((t) => LABEL[t]))} hidden: ${plural(patients(hidden), 'patient')} on the way`));
    const b = el('button', 'link', 'Show them');
    b.type = 'button';
    b.dataset.fk = 'fold';
    b.onclick = () => setShow('all');
    fold.append(b);
  }
  function setShow(v) { show = v; try { localStorage.setItem('show', v); } catch (_) {} limit = PAGE; render(); }
  // Arrow keys move between time blocks without leaving the row you are on.
  $('board').addEventListener('keydown', (e) => {
    if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(e.key) || !e.target.dataset.row) return;
    const i = boardKeys.findIndex((k) => String(k) === e.target.dataset.col);
    const n = e.key === 'Home' ? 0 : e.key === 'End' ? boardKeys.length - 1 : Math.max(0, Math.min(boardKeys.length - 1, i + (e.key === 'ArrowRight' ? 1 : -1)));
    e.preventDefault();
    const row = e.target.dataset.row;
    bsel = boardKeys[n];
    limit = PAGE;
    render();
    restoreFocus(row === 'hc' ? `hc:${bsel}` : `cell:${row}:${bsel}`);
  });

  // ---------- Arrived and Cancelled ----------
  // Totals by level (one block per patient, also the level filter) and a "Check these first" group for
  // cancelled urgent reports. The hub does not record when a report was marked, so times are when it was received.
  const HISTORY = ['arrived', 'cancelled'];
  const isHistory = () => HISTORY.includes(view);
  const URGENT_CHECK = ['Immediate', 'Unassessed'];
  let histTitle = '', histQuiet = false;
  // Rows for these views: filtered by search and level, newest first.
  function historyRows() {
    return inboundList().filter((r) => !cat || category(r) === cat)
      .sort((a, b) => Date.parse(b.received_at) - Date.parse(a.received_at));
  }
  // Returns the reports for the main list (the urgent cancelled ones move up into the check group).
  function renderHistory(list) {
    const sec = $('hist-sec');
    const base = isHistory() && loadState !== 'loading' ? inboundList() : [];
    sec.hidden = !base.length;
    histQuiet = false;
    histTitle = 'Newest first';
    if (sec.hidden) return isHistory() ? list : null;

    // level tiles: totals, one block per patient, and the level filter
    const scope = base;
    const tiles = $('tiles');
    tiles.replaceChildren();
    for (const t of TRIAGE) {
      const rs = scope.filter((r) => category(r) === t), n = patients(rs);
      if (t === 'Deceased' && !rs.length && cat !== t) continue;
      const b = el('button', `tile ${t}`);
      b.type = 'button';
      b.dataset.fk = `tile:${t}`;
      b.setAttribute('aria-pressed', String(cat === t));
      const th = el('span', 'th');
      th.append(shape(t), document.createTextNode(LABEL[t]));
      const blks = el('span', 'tblks');
      blks.setAttribute('aria-hidden', 'true');
      let left = 24;
      for (const r of rs) for (let i = 0; i < countOf(r) && left > 0; i++, left--) blks.append(el('i', 'tb'));
      if (n > 24) blks.append(el('span', 'plus', `+${num(n - 24)}`));
      if (hasUnknown(rs)) blks.append(el('span', 'plus', '+?')); // reports with no stated count
      b.append(th, el('b', '', num(n)), blks);
      b.onclick = () => setCat(cat === t ? null : t);
      tiles.append(b);
    }

    // cancelled Immediate or Unassessed reports come first, with a one-tap Reopen
    const check = $('check');
    check.replaceChildren();
    const urgent = view === 'cancelled' && !cat ? list.filter((r) => URGENT_CHECK.includes(category(r))).sort((x, y) => RANK[category(x)] - RANK[category(y)]) : []; // Immediate first, then newest
    check.hidden = !urgent.length;
    if (urgent.length) {
      check.append(el('h3', '', 'Check these first'),
        el('p', '', `${plural(urgent.length, 'cancelled report')} ${urgent.length === 1 ? 'was' : 'were'} Immediate or Unassessed. Reopen any that were cancelled by mistake.`));
      for (const r of urgent) check.append(entryEl(r, { quick: true }));
      histTitle = 'Other cancelled';
      histQuiet = true;
    }
    return urgent.length ? list.filter((r) => !urgent.includes(r)) : list;
  }
  // One patient row: a button that opens that patient's needs; history rows show when the hub received the report.
  function entryEl(r, opts = {}) {
    const isNew = !firstLoad && !seen.has(r.id);
    const open = isOpen(r);
    const entry = el('div', `entry${open ? ' open' : ''}`);
    const head = el('div', 'ehead');
    const it = el('button', `item${isNew ? ' fresh' : ''}`);
    it.type = 'button';
    it.dataset.fk = `item:${r.id}`;
    it.setAttribute('aria-expanded', String(open));
    if (open) it.setAttribute('aria-controls', `d-${r.id}`);
    const chip = el('span', `chip ${category(r)}`);
    chip.append(shape(category(r)), document.createTextNode(LABEL[category(r)]));
    const who = el('span', 'iw', `${noun(r)}, ${r.source_findings_current === false ? 'Original: ' : ''}${r.injuries}`);
    who.append(el('small', '', `From ${r.location}${r.id === autoId ? ' · Priority patient' : ''}`));
    let tm;
    if (isHistory()) { tm = el('div', 'tm', fmt(r.received_at)); tm.append(el('small', '', `received ${ago(r.received_at)}`)); }
    else tm = timeBlock(r, 'tm');
    it.append(chip, who, tm, el('i', 'chev'));
    it.onclick = () => { expanded[r.id] = !isOpen(r); render(); };
    head.append(it);
    if (opts.quick) head.append(actionBtn(r, 'Reopen', 'inbound', '', 'check')); // one tap, no need to open the row
    entry.append(head);
    if (open) { const d = renderDetail(r); d.id = `d-${r.id}`; entry.append(d); }
    return entry;
  }

  function renderList(list) {
    const out = $('list');
    out.replaceChildren();

    if (loadState === 'loading') {
      for (let i = 0; i < 3; i++) {
        const s = el('div', 'skel-row');
        const a = el('div', 'skel'), b = el('div', 'skel');
        a.style.width = '35%'; b.style.width = '75%';
        s.append(a, b); out.append(s);
      }
      return;
    }

    if (!list.length && histQuiet) return; // the Check these first group already holds every report
    if (!list.length) {
      const e = el('div', 'empty');
      const filtered = (view !== 'inbound' && cat) || query.trim();
      if (filtered) {
        e.append(el('b', '', 'No reports match'), el('p', '', 'Nothing in this view fits the current filters.'));
        const b = el('button', 'btn', 'Clear filters'); b.type = 'button'; b.dataset.fk = 'clear';
        b.onclick = () => { cat = null; setQuery(''); writeUrl(true); };
        e.append(b);
      } else if (view === 'inbound') {
        e.append(el('b', '', boardEmpty.t), el('p', '', boardEmpty.p));
      } else {
        e.append(el('b', '', `No ${view === 'all' ? '' : VIEW_TITLE[view].toLowerCase() + ' '}reports yet`), el('p', '', 'Patients you mark on the On the way view show up here.'));
      }
      out.append(e);
      return;
    }

    const rest = list;
    const page = rest.slice(0, limit);
    const groups = view === 'inbound'
      ? [[boardTitle || 'Patients', () => true]]
      : [[isHistory() ? histTitle : VIEW_TITLE[view], () => true]];

    for (const [name, test] of groups) {
      const part = page.filter(test);
      if (!part.length) continue;
      const head = el('div', 'grp');
      head.append(el('b', '', name), el('span', '', plural(patients(part), 'patient')));
      out.append(head);
      for (const r of part) out.append(entryEl(r));
    }
    if (rest.length > limit) {
      const more = el('button', 'btn more', `Show ${Math.min(PAGE, rest.length - limit)} more (${num(rest.length - limit)} not shown)`);
      more.type = 'button';
      more.dataset.fk = 'more';
      more.onclick = () => { limit += PAGE; render(); };
      out.append(more);
    }
  }

  function renderPrep(inbound) {
    const box = $('prep');
    box.replaceChildren(el('h2', '', 'Teams to alert'));
    if (loadState === 'loading') { box.append(el('div', 'skel')); return; }
    const needs = {};
    for (const r of inbound) {
      if (category(r) === 'Deceased') continue;
      for (const n of readyItems(r)) needs[n] = (needs[n] || 0) + countOf(r);
    }
    const sorted = Object.entries(needs).sort((a, b) => b[1] - a[1]);
    if (!sorted.length) { box.append(el('p', 'hint', 'No teams needed right now.')); return; }
    box.append(el('p', 'hint', 'Known patient counts for everyone still on the way; unknown counts are excluded.'));
    box.lastChild.style.marginBottom = '12px';
    const max = sorted[0][1];
    const wrap = el('div', 'mini-rows');
    for (const [name, n] of sorted) {
      const m = el('div', 'mini');
      m.append(el('span', 'name', name), el('span', 'v', num(n)));
      const track = el('div', 'track'), fill = el('i');
      fill.style.width = `${Math.round((n / max) * 100)}%`;
      track.append(fill); m.append(track); wrap.append(m);
    }
    box.append(wrap);
  }

  // ---------- controls ----------
  // Where you are (status tab, category, search) lives in the URL, so refresh and the Back button keep it.
  const VIEWS = ['inbound', 'arrived', 'cancelled', 'all', 'settings'];
  const qInput = $('q');
  function readUrl() {
    const p = new URLSearchParams(location.search);
    view = VIEWS.includes(p.get('view')) ? p.get('view') : 'inbound';
    cat = TRIAGE.includes(p.get('cat')) ? p.get('cat') : null;
    query = p.get('q') || '';
    qInput.value = query;
  }
  function writeUrl(push) {
    const p = new URLSearchParams();
    if (view !== 'inbound') p.set('view', view);
    if (cat) p.set('cat', cat);
    if (query.trim()) p.set('q', query.trim());
    const url = location.pathname + (p.toString() ? '?' + p : '');
    if (url !== location.pathname + location.search) {
      try { history[push ? 'pushState' : 'replaceState'](null, '', url); } catch (_) {}
    }
  }
  function setView(v) { view = v; limit = PAGE; writeUrl(true); render(); }
  function setCat(c) { cat = c; limit = PAGE; writeUrl(true); render(); }
  window.addEventListener('popstate', () => { readUrl(); limit = PAGE; render(); });

  document.querySelectorAll('.vtab').forEach((b, i, all) => {
    b.onclick = () => setView(b.dataset.f);
    b.onkeydown = (e) => {
      let n = null;
      if (e.key === 'ArrowRight' || e.key === 'ArrowDown') n = (i + 1) % all.length;
      else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') n = (i - 1 + all.length) % all.length;
      else if (e.key === 'Home') n = 0;
      else if (e.key === 'End') n = all.length - 1;
      if (n === null) return;
      e.preventDefault();
      all[n].focus();
      setView(all[n].dataset.f);
    };
  });
  $('cat-clear').onclick = () => setCat(null);
  document.querySelectorAll('.rb[data-r]').forEach((b) => { b.onclick = () => { range = Number(b.dataset.r); bsel = null; render(); }; });
  document.querySelectorAll('.rb[data-s]').forEach((b) => { b.onclick = () => setShow(b.dataset.s); });

  function setQuery(v) { query = v; qInput.value = v; limit = PAGE; writeUrl(false); render(); }
  qInput.addEventListener('input', () => { query = qInput.value; limit = PAGE; writeUrl(false); render(); });
  $('qx').onclick = () => { setQuery(''); qInput.focus(); };

  const soundBtn = $('sound');
  function paintSound() {
    soundBtn.setAttribute('aria-checked', String(soundOn));
    soundBtn.querySelector('.state').textContent = soundOn ? 'On' : 'Off';
  }
  soundBtn.onclick = () => {
    soundOn = !soundOn;
    try { localStorage.setItem('sound', soundOn ? '1' : '0'); } catch (_) {}
    paintSound();
    if (soundOn) beep(); // the click also unlocks audio in the browser
  };
  paintSound();

  // Toasts must never hide the control a keyboard user is on: Escape clears them, and so does moving focus beneath them.
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') $('toasts').replaceChildren(); });
  document.addEventListener('focusin', (e) => {
    const box = $('toasts');
    if (!box.children.length || box.contains(e.target) || !e.target.getBoundingClientRect) return;
    const a = e.target.getBoundingClientRect(), b = box.getBoundingClientRect();
    if (a.right > b.left && a.left < b.right && a.bottom > b.top && a.top < b.bottom) box.replaceChildren();
  });

  function tick() { $('clock').textContent = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }); }
  tick();
  setInterval(tick, 10000);

  fetch('/api/config').then((r) => r.json()).then((c) => {
    $('hospital').textContent = c.hospital;
    document.title = c.hospital + ' · Pre-Arrival Board';
  }).catch(() => {});

  // Live push; the poll is a safety net if the stream drops.
  function connect() {
    const es = new EventSource('/api/events');
    es.onopen = () => { $('conn').textContent = 'Live'; $('conn').className = 'conn live'; };
    es.addEventListener('triage', () => load());
    es.addEventListener('cloud', (e) => { try { renderCloud(JSON.parse(e.data)); } catch { /* keep last state */ } });
    es.onerror = () => { $('conn').textContent = 'Reconnecting'; $('conn').className = 'conn down'; };
  }
  // Supabase backup status from the hub; the board never talks to Supabase directly.
  function cloudLabel(s) {
    if (!s.configured) return 'Cloud off';
    if (s.state === 'syncing') return 'Cloud syncing';
    const queued = (s.pending ? ` · ${s.pending} queued` : '') + (s.rejected ? ` · ${s.rejected} rejected` : '');
    if (s.state === 'error') return `Cloud offline${queued}`;
    return queued ? `Cloud${queued}` : 'Cloud synced';
  }
  function renderCloud(s) {
    const el = $('cloud-conn'), btn = $('cloud-sync');
    el.textContent = cloudLabel(s);
    el.className = 'conn ' + (s.configured && s.state !== 'error' && !s.rejected ? 'live' : 'down');
    el.title = s.message || (s.lastSuccessAt ? `Last cloud sync ${new Date(s.lastSuccessAt).toLocaleTimeString()}` : 'Supabase cloud backup');
    btn.hidden = !s.configured;
    btn.disabled = s.state === 'syncing';
  }
  function loadCloud() {
    fetch('/api/cloud/status').then((r) => r.json()).then(renderCloud)
      .catch(() => { $('cloud-conn').textContent = 'Cloud: unknown'; $('cloud-conn').className = 'conn down'; });
  }
  $('cloud-sync').addEventListener('click', () => {
    $('cloud-sync').disabled = true;
    fetch('/api/cloud/sync', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ retryRejected: true }) })
      .then((r) => r.json()).then(renderCloud).catch(loadCloud);
  });

  readUrl();
  render();
  // Draft setups are optional: the board works without them.
  fetch('/setups.json').then((res) => (res.ok ? res.json() : null))
    .then((data) => { if (data && data.setups) Object.assign(PREP_DRAFT, data.setups); })
    .catch(() => {}).finally(load);
  loadCloud();
  connect();
  setInterval(load, 10000);
  setInterval(loadCloud, 30000);
  setInterval(render, 15000); // keep ETA countdowns and "x min ago" fresh between polls

  // Local AI triage assistant: talks to the hub's Qwen endpoints, never to Ollama directly.
  // All rendering uses textContent (safe). The board keeps working when the AI is down.
  (function () {
    'use strict';
    var panel = document.getElementById('ai-panel');
    if (!panel) return;
    function $(id) { return document.getElementById(id); }
    var textEl = $('ai-text'), stateEl = $('ai-state'), resultEl = $('ai-result'), reviewEl = $('ai-review');
    var extractBtn = $('ai-extract'), assistBtn = $('ai-assist'), saveBtn = $('ai-save');
    var saveStateEl = $('ai-save-state'), connEl = $('ai-conn');
    var busy = false, lastExtraction = null, saveAttempt = null;
    var OBS_LABEL = { breathing: 'Breathing', consciousness: 'Consciousness', severeBleeding: 'Severe bleeding', walking: 'Walking' };
    function setConn(available, label) { connEl.textContent = label; connEl.className = 'conn ' + (available ? 'live' : 'down'); }
    async function refreshStatus() {
      try {
        var s = await (await fetch('/api/ai/health')).json();
        if (s && s.inference_available) { setConn(true, 'AI ready'); return; }
        setConn(false, 'AI unavailable');
        stateEl.textContent = (s && s.error === 'model-missing')
          ? 'Qwen model is missing on the hospital computer. The board still works.'
          : 'Local AI is unreachable. The board still works without it.';
      } catch (e) { setConn(false, 'AI unavailable'); }
    }
    function errText(data, res) {
      var map = {
        'ollama-unreachable': 'Local AI is unreachable; is Ollama running on the hospital computer?',
        'ollama-timeout': 'Local AI timed out; try a shorter transcript.',
        'model-missing': 'Qwen model is missing on the hospital computer.',
        'invalid-model-json': 'Qwen returned an unusable reply; nothing was saved.',
        'invalid-model-schema': 'Qwen returned an unusable reply; nothing was saved.',
        'invalid-transcript': 'Type a transcript first.',
        'transcript-too-long': 'Transcript is too long; shorten it.'
      };
      if (data && data.error && map[data.error]) return map[data.error];
      return 'Local AI failed' + (res ? ' (HTTP ' + res.status + ')' : '') + '; nothing was saved.';
    }
    function rowOf(box, k, v, cls) {
      var d = document.createElement('div');
      var a = document.createElement('span'); a.textContent = k;
      var b = document.createElement('b'); b.textContent = v;
      if (cls) b.className = cls;
      d.append(a, b); box.append(d);
    }
    function renderResult(data) {
      resultEl.replaceChildren();
      var t = document.createElement('div'); t.className = 'ai-table';
      var obs = data.processing.observations;
      Object.keys(OBS_LABEL).forEach(function (k) { rowOf(t, OBS_LABEL[k], obs[k]); });
      resultEl.append(t);
      var ev = document.createElement('p'); ev.className = 'ai-ev';
      var quotes = Object.keys(OBS_LABEL).map(function (k) {
        return OBS_LABEL[k] + ': ' + (data.evidence && data.evidence[k] ? '\u201C' + data.evidence[k] + '\u201D' : 'not stated');
      }).join(' · ');
      ev.textContent = 'Evidence — ' + quotes;
      resultEl.append(ev);
      (data.processing.uncertainties || []).forEach(function (u) {
        var p = document.createElement('p'); p.className = 'ai-ev'; p.textContent = 'Unknown: ' + u; resultEl.append(p);
      });
      (data.warnings || []).forEach(function (w) {
        var p = document.createElement('p'); p.className = 'ai-warn'; p.textContent = 'Warning: ' + w; resultEl.append(p);
      });
      var terms = (data.retrieval && data.retrieval.matches) || [];
      if (terms.length) {
        var tp = document.createElement('p'); tp.className = 'ai-ev';
        tp.textContent = 'Reference terms (' + data.retrieval.reviewStatus + ' glossary, meanings only) — ' +
          terms.map(function (m) { return m.matched + ' = ' + m.english + (m.negated ? ' (denied in report)' : ''); }).join(' · ');
        resultEl.append(tp);
      }
      // The rules score only four findings. When none fired, say which reported
      // terms were therefore left unscored, so they are not mistaken for "understood".
      var unscored = terms.filter(function (m) {
        return !m.negated && ['injury', 'condition', 'mechanism', 'symptom'].indexOf(m.category) !== -1;
      });
      if (unscored.length && data.provisional.triage === 'Unassessed') {
        var up = document.createElement('p'); up.className = 'ai-warn';
        up.textContent = 'Reported but not scored: ' + unscored.map(function (m) { return m.english; }).join(', ') +
          '. The rules score only breathing, consciousness, severe bleeding and walking, so a qualified clinician must assess these.';
        resultEl.append(up);
      }
      var pr = document.createElement('p');
      pr.textContent = 'Provisional (deterministic rules, advisory only): ' + data.provisional.triage + ' — ' + data.provisional.reason + '. Verify clinically.';
      resultEl.append(pr);
      if (data.draft) {
        var dr = document.createElement('p'); dr.className = 'ai-ev';
        dr.textContent = 'Draft report: ' + data.draft.injuries + ' · ' + data.draft.triage + ' (provisional)';
        resultEl.append(dr);
      }
      resultEl.hidden = false;
      $('ai-obs-breathing').value = obs.breathing;
      $('ai-obs-consciousness').value = obs.consciousness;
      $('ai-obs-bleeding').value = obs.severeBleeding;
      $('ai-obs-walking').value = obs.walking;
      fillFields(data);
      reviewEl.hidden = false;
    }
    // Prefill the report fields from what the transcript states. Each value came from
    // a quote shown in the note below; blanks stay blank, and everything is editable.
    function fillFields(data) {
      var f = data.fields || {}, ev = data.fieldEvidence || {}, notes = [];
      $('ai-location').value = f.location || '';
      $('ai-count').value = f.patientCount == null ? '' : f.patientCount;
      $('ai-age').value = f.ageGroup || 'Unspecified';
      $('ai-eta').value = f.etaMinutes == null ? '' : f.etaMinutes;
      $('ai-injuries').value = f.injuries && f.injuries !== 'Unspecified' ? f.injuries : '';
      if (f.location) notes.push('Location \u201C' + f.location + '\u201D from \u201C' + ev.location + '\u201D' + (data.locationBasis === 'inferred' ? ' (guessed — check it is the pickup place)' : ''));
      if (f.patientCount != null) notes.push('Patients ' + f.patientCount + ' from \u201C' + ev.patientCount + '\u201D');
      if (ev.ageGroup) notes.push('Age group from \u201C' + ev.ageGroup + '\u201D');
      if (f.etaMinutes != null) notes.push('ETA ' + f.etaMinutes + ' min from \u201C' + ev.etaMinutes + '\u201D');
      (data.fieldNotes || []).forEach(function (n) { notes.push(n); });
      $('ai-fields-note').textContent = notes.length
        ? 'Filled from the transcript — check every field before saving. ' + notes.join(' · ')
        : 'Nothing could be filled from the transcript; enter the fields yourself.';
      if (data.legacy && data.legacy.triage !== 'Unassessed') {
        $('ai-fields-note').textContent += ' · Hospital finding rules on these injury terms: ' + data.legacy.triage + ' (' + data.legacy.reason + ').';
      }
    }
    async function run(kind) {
      if (busy) return;
      var transcript = textEl.value;
      if (!transcript.trim()) { stateEl.textContent = 'Type a transcript first.'; return; }
      lastExtraction = null; saveAttempt = null; reviewEl.hidden = true;
      busy = true; extractBtn.disabled = true; assistBtn.disabled = true;
      stateEl.textContent = 'Working — asking local Qwen…';
      try {
        var res = await fetch('/api/ai/' + kind, {
          method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ transcript: transcript, device: 'hospital-browser', sttEngine: 'typed/hub-form', sttRuntime: 'hub-ai-v1' })
        });
        var data = await res.json().catch(function () { return null; });
        if (!res.ok || !data || data.ok !== true) { stateEl.textContent = errText(data, res); return; }
        lastExtraction = data;
        setConn(true, 'AI ready');
        stateEl.textContent = 'Ready — review the extraction below before saving.';
        renderResult(data);
      } catch (e) { stateEl.textContent = 'Could not reach the hub; the board still works.'; }
      finally { busy = false; extractBtn.disabled = false; assistBtn.disabled = false; }
    }
    extractBtn.onclick = function () { run('extract'); };
    assistBtn.onclick = function () { run('triage-assist'); };
    saveBtn.onclick = async function () {
      if (!lastExtraction || lastExtraction.processing.originalTranscript !== textEl.value) { saveStateEl.textContent = 'Transcript changed; extract it again before saving.'; return; }
      var loc = $('ai-location').value.trim();
      if (!loc) { saveStateEl.textContent = 'Enter a pickup location first.'; return; }
      var pc = $('ai-count').value === '' ? null : Number($('ai-count').value);
      if (pc !== null && (!Number.isInteger(pc) || pc < 1 || pc > 99)) { saveStateEl.textContent = 'Patients must be 1–99 or unknown.'; return; }
      var ages = ['Infant', 'Child', 'Adult', 'Elderly', 'Unspecified'];
      var ag = $('ai-age').value; if (ages.indexOf(ag) === -1) ag = 'Unspecified';
      var etaRaw = $('ai-eta').value.trim();
      var eta = etaRaw === '' ? null : parseInt(etaRaw, 10);
      if (eta !== null && (!Number.isInteger(eta) || eta < 1 || eta > 720)) { saveStateEl.textContent = 'ETA must be 1–720 minutes or blank.'; return; }
      var prov = { triage: 'Unassessed' };
      var injuries = $('ai-injuries').value.trim() || 'Unspecified';
      var report = { location: loc, injuries: injuries, triage: prov.triage, patientCount: pc, ageGroup: ag, etaMinutes: eta,
        rawText: lastExtraction.processing.originalTranscript, processing: lastExtraction.processing };
      var signature = JSON.stringify(report);
      if (!saveAttempt || saveAttempt.signature !== signature) saveAttempt = { signature: signature, report: Object.assign(report, { localId: Date.now(), createdAt: new Date().toISOString(), reportId: newUUID(), encounterId: newUUID() }) };
      saveBtn.disabled = true; saveStateEl.textContent = 'Saving…';
      try {
        var res = await fetch('/api/sync-triage', {
          method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ watchId: 'HUB-AI', reports: [saveAttempt.report] })
        });
        var data = await res.json().catch(function () { return null; });
        if (!res.ok || !data || data.ok !== true) { saveStateEl.textContent = 'Save failed; nothing was stored.'; return; }
        if (data.rejected && data.rejected.length) { saveStateEl.textContent = 'Hub refused the report: ' + data.rejected[0].reason; return; }
        saveStateEl.textContent = 'Saved as inbound (' + prov.triage + ', provisional) — verify clinically.';
        if (!data.ackLocalIds || data.ackLocalIds.indexOf(saveAttempt.report.localId) === -1) throw new Error('No explicit receipt');
        if (typeof toast === 'function') toast('AI report saved', prov.triage + ' · verify clinically', prov.triage);
        if (typeof load === 'function') load();
      } catch (e) { saveStateEl.textContent = 'Receipt unavailable; retain this form and retry the same report.'; }
      finally { saveBtn.disabled = false; }
    };
    ['ai-obs-breathing', 'ai-obs-consciousness', 'ai-obs-bleeding', 'ai-obs-walking'].forEach(function (id) { $(id).disabled = true; });
    refreshStatus();
  })();
