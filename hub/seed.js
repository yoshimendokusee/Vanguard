#!/usr/bin/env node
'use strict';

// WristCue sample data: one synthetic flood-drill shift, loaded into a running hub.
//
// This script stands in for the rescue teams, not for a rescue watch. It posts the
// same batches a watch posts (POST /api/sync-triage) and then does what an ED
// operator does on the board (PATCH /api/triage/:id, POST /api/triage/:id/revisions),
// so the hub's own validation, duplicate protection, provisional assessment and
// clinical history all run exactly as they do in a live demo. It never opens,
// edits or deletes the database file itself.
//
// Usage:
//   node seed.js                              # hub on http://127.0.0.1:3000
//   node seed.js --url http://127.0.0.1:3301  # isolated QA hospital
//   node seed.js --dry-run                    # validate the scenario, send nothing
//   node seed.js --force                      # load a second wave on purpose
//
// Synthetic patients only. Never point this at a hub that holds real reports.

const { randomUUID } = require('node:crypto');
const { validateReport } = require('./sync');

const MINUTE = 60000;
const DEFAULT_URL = 'http://127.0.0.1:3000';
const SAMPLE_TAG = 'wristcue-flood-drill';
const OPERATOR = 'ED triage nurse (drill shift)';
const LOCATION = (place) => `Barangay ${place}`;
const RANK = { Immediate: 0, Unassessed: 1, Delayed: 2, Minor: 3, Deceased: 4 };
const TRIAGE = ['Immediate', 'Unassessed', 'Delayed', 'Minor', 'Deceased'];

// ---------------------------------------------------------------------------
// One structured intake, as a watch with the Filipino speech model sends it:
// sentences plus the findings and excerpts behind them. Evidence and corrections
// shows these excerpts, and the hub honours an observation only when an excerpt
// supports it, so this report is assessed from consciousness alone.
// ---------------------------------------------------------------------------
const HEAD_INJURY_NOTE =
  'Dalawang lalaki po, nabagok ang ulo sa gumuhong pader, walang malay ngayon, ' +
  'sa Barangay Navarro, mga tatlumpung minuto pa papunta sa ospital.';

const HEAD_INJURY_PROCESSING = {
  version: 1,
  originalTranscript: HEAD_INJURY_NOTE,
  observations: {
    breathing: 'unknown',
    consciousness: 'unresponsive',
    severeBleeding: 'unknown',
    walking: 'unknown',
  },
  uncertainties: [
    'Breathing was not reported for this group; confirm airway on arrival',
    'Patient count comes from rescuer speech; confirm identities at handover',
  ],
  provenance: {
    device: 'apple-watch',
    sttEngine: 'vosk-model-tl-ph-generic-0.6',
    sttRuntime: 'vosk on-device (watchOS)',
    extraction: null,
  },
  evidence: {
    consciousness: { source: 'observed', excerpt: 'walang malay', contradictory: false },
  },
  findings: [
    { id: 'f-01', kind: 'incident', name: 'Head injury', value: null, unit: null, source: 'reported', excerpt: 'nabagok ang ulo', contradictory: false },
    { id: 'f-02', kind: 'observation', name: 'consciousness', value: null, unit: null, source: 'observed', excerpt: 'walang malay', contradictory: false },
    { id: 'f-03', kind: 'patient', name: 'Patient count', value: 2, unit: 'patients', source: 'reported', excerpt: 'Dalawang lalaki', contradictory: false },
  ],
};

// ---------------------------------------------------------------------------
// The scenario: 24 reports from 4 rescue teams during one typhoon shift.
//
//   place       pickup barangay (one of the four in the watch locations map)
//   findings    comma-separated canonical findings, exactly as the parser names them
//   triage      the category the watch computed (worst finding wins)
//   count       patients in this report; null = the rescuer never said how many
//   ageGroup    Infant | Child | Adult | Elderly | Unspecified
//   arrivesIn   minutes from now until this group reaches the ED (negative = late)
//   reportedAgo minutes since the rescuer spoke, i.e. how long the watch queued it
//               (eta_minutes is measured from then, so spoken ETA = arrivesIn + reportedAgo)
//   note        what the rescuer said (kept verbatim as the original evidence)
//   status      optional board action: arrived | cancelled
//   edit        optional operator action, applied through the revisions API
//
// Edit the numbers and notes freely; the ETAs are relative to the moment you run it.
// ---------------------------------------------------------------------------
const WATCHES = [
  {
    watchId: 'W-4A1B',
    team: 'Arnaldo rescue boat',
    reports: [
      {
        place: 'Arnaldo', findings: 'Drowning, Unconscious', triage: 'Immediate', count: 3, ageGroup: 'Child',
        arrivesIn: 4, reportedAgo: 3,
        note: 'Tatlong bata po, nalunod sa baha, wala pong malay, sa Barangay Arnaldo, mga pitong minuto pa papunta sa ospital.',
      },
      {
        place: 'Arnaldo', findings: 'Fracture, Laceration', triage: 'Delayed', count: 2, ageGroup: 'Adult',
        arrivesIn: 18, reportedAgo: 9,
        note: 'Dalawang lalaki po, nabali ang binti at may malalim na sugat, galing sa gumuhong bahay sa Barangay Arnaldo, mga tatlumpung minuto pa.',
      },
      {
        place: 'Arnaldo', findings: 'Burn, Wound', triage: 'Delayed', count: 1, ageGroup: 'Child',
        arrivesIn: 43, reportedAgo: 16,
        note: 'Isang bata po, napaso sa nasusunog na kusina, may mga sugat din sa braso, sa Barangay Arnaldo, mga isang oras pa.',
      },
      {
        place: 'Arnaldo', findings: 'Weak / dehydrated, Wound', triage: 'Delayed', count: 4, ageGroup: 'Adult',
        arrivesIn: 33, reportedAgo: 11,
        note: 'Apat na pasyente po, nanghihina sa tatlong araw na walang tubig, may mga sugat sa paa, sa Barangay Arnaldo, mga apatnapung minuto pa.',
      },
    ],
  },
  {
    watchId: 'W-6F5E',
    team: 'Navarro health workers',
    reports: [
      {
        place: 'Navarro', findings: 'Severe bleeding, Fracture', triage: 'Immediate', count: 1, ageGroup: 'Adult',
        arrivesIn: 12, reportedAgo: 6,
        note: 'Isang lalaki po, malakas ang pagdurugo ng binti at may bali, sa Barangay Navarro, mga dalawampung minuto pa.',
      },
      {
        place: 'Navarro', findings: 'Head injury, Unconscious', triage: 'Immediate', count: 2, ageGroup: 'Adult',
        arrivesIn: 18, reportedAgo: 12, note: HEAD_INJURY_NOTE, processing: HEAD_INJURY_PROCESSING,
      },
      {
        place: 'Navarro', findings: 'Hypothermia, Weak / dehydrated', triage: 'Delayed', count: 3, ageGroup: 'Elderly',
        arrivesIn: 14, reportedAgo: 5, status: 'arrived',
        note: 'Tatlong matanda po, nilalamig at nanghihina matapos mahulog sa tubig, sa Barangay Navarro, mga dalawampung minuto pa.',
      },
      {
        place: 'Navarro', findings: 'Snakebite', triage: 'Delayed', count: 1, ageGroup: 'Child',
        arrivesIn: 72, reportedAgo: 20,
        note: 'Isang bata po, tinuklaw ng ahas habang naglilikas, sa Barangay Navarro, mga isang oras at kalahati pa.',
      },
      {
        place: 'Navarro', findings: 'Abrasion, Ambulatory', triage: 'Minor', count: 5, ageGroup: 'Adult',
        arrivesIn: 18, reportedAgo: 7,
        note: 'Limang pasyente po, nakakalakad naman, puro gasgas at galos lang, sa Barangay Navarro, mga dalawampung minuto pa.',
      },
    ],
  },
  {
    watchId: 'W-3C2D',
    team: 'Santiago fire volunteers',
    reports: [
      {
        place: 'Santiago', findings: 'Electrocution', triage: 'Immediate', count: 1, ageGroup: 'Adult',
        arrivesIn: 2, reportedAgo: 9, status: 'arrived',
        note: 'Isang lalaki po, nakuryente sa nahulog na kable, sa Barangay Santiago, mga sampung minuto pa.',
      },
      {
        place: 'Santiago', findings: 'Bleeding', triage: 'Delayed', count: 2, ageGroup: 'Adult',
        arrivesIn: 55, reportedAgo: 6,
        note: 'Dalawang pasyente po, dumudugo ang binti, nagagamot naman ng first aid, sa Barangay Santiago, mga isang oras pa.',
      },
      {
        place: 'Santiago', findings: 'Chest pain, Difficulty breathing', triage: 'Immediate', count: 1, ageGroup: 'Elderly',
        arrivesIn: -6, reportedAgo: 20, status: 'arrived',
        note: 'Isang lolo po, masakit ang dibdib at hirap huminga, sa Barangay Santiago, mga labinlimang minuto pa.',
      },
      {
        place: 'Santiago', findings: 'Unconscious', triage: 'Immediate', count: 1, ageGroup: 'Adult',
        arrivesIn: null, reportedAgo: 8, status: 'cancelled',
        note: 'Isang lalaki po, walang malay, hindi pa namin alam kung gaano katagal bago makarating, sa Barangay Santiago.',
      },
      {
        place: 'Santiago', findings: 'Deceased', triage: 'Deceased', count: 1, ageGroup: 'Elderly',
        arrivesIn: 8, reportedAgo: 12, status: 'arrived',
        note: 'Isang matanda po, wala nang buhay nang mahanap sa rumaragasang tubig, dinadala na po namin, sa Barangay Santiago, mga dalawampung minuto pa.',
      },
      {
        place: 'Santiago', findings: 'Abrasion, Ambulatory', triage: 'Minor', count: 2, ageGroup: 'Child',
        arrivesIn: 42, reportedAgo: 13,
        note: 'Dalawang bata po, gasgas lang sa tuhod at nakakalakad naman, sa Barangay Santiago, mga isang oras pa.',
      },
      {
        place: 'Santiago', findings: 'Difficulty breathing', triage: 'Immediate', count: 1, ageGroup: 'Child',
        arrivesIn: 6, reportedAgo: 2,
        note: 'Isang bata po, hirap huminga at hinihingal, sa Barangay Santiago, mga walong minuto pa.',
      },
      {
        place: 'Santiago', findings: 'Not breathing', triage: 'Immediate', count: 1, ageGroup: 'Adult',
        arrivesIn: 39, reportedAgo: 18,
        note: 'Isang lalaki po, hindi na humihinga, may CPR na ginagawa habang dinadala, sa Barangay Santiago, mga isang oras pa.',
      },
    ],
  },
  {
    watchId: 'W-7G8H',
    team: 'Pasong Kawayan rescue',
    reports: [
      {
        place: 'Pasong Kawayan', findings: 'Pregnant / labor, Severe bleeding', triage: 'Immediate', count: 1, ageGroup: 'Adult',
        arrivesIn: 16, reportedAgo: 4,
        note: 'Isang buntis po, manganganak na at malakas ang pagdurugo, sa Barangay Pasong Kawayan, mga dalawampung minuto pa.',
      },
      {
        place: 'Pasong Kawayan', findings: 'Difficulty breathing, Weak / dehydrated', triage: 'Immediate', count: 2, ageGroup: 'Elderly',
        arrivesIn: 48, reportedAgo: 15,
        note: 'Dalawang matanda po, hirap huminga at nanghihina, sa Barangay Pasong Kawayan, mga isang oras pa.',
      },
      {
        place: 'Pasong Kawayan', findings: 'Fracture', triage: 'Delayed', count: 1, ageGroup: 'Elderly',
        arrivesIn: null, reportedAgo: 25,
        note: 'Isang lola po, nabali ang balakang, wala pang tiyak na oras ng dating, sa Barangay Pasong Kawayan.',
      },
      {
        place: 'Pasong Kawayan', findings: 'Laceration, Bleeding', triage: 'Delayed', count: 1, ageGroup: 'Adult',
        arrivesIn: 28, reportedAgo: 10,
        note: 'Isang lalaki po, malalim na sugat sa hita at dumudugo pa rin, sa Barangay Pasong Kawayan, mga apatnapung minuto pa.',
        edit: { kind: 'override', override: 'Immediate', reason: 'Bleeding not controlled by first aid; nurse upgrades to Immediate pending surgeon review' },
      },
      {
        place: 'Pasong Kawayan', findings: 'Ambulatory, Abrasion', triage: 'Minor', count: 3, ageGroup: 'Adult',
        arrivesIn: 88, reportedAgo: 30, status: 'cancelled',
        note: 'Tatlong pasyente po, nakakalakad at gasgas lang, sa Barangay Pasong Kawayan, mga dalawang oras pa.',
      },
      {
        place: 'Pasong Kawayan', findings: 'Unspecified', triage: 'Unassessed', count: null, ageGroup: 'Unspecified',
        arrivesIn: 35, reportedAgo: 12,
        note: 'May nadaanan po kaming tao sa gilid ng tulay, hindi po namin sigurado ang kalagayan, sa Barangay Pasong Kawayan, mga tatlumpung minuto pa.',
        edit: {
          kind: 'correction',
          transcript: 'Isang lalaki po ito, may sugat sa binti, gising at nakakalakad, sa Barangay Pasong Kawayan, mga tatlumpung minuto pa.',
          reason: 'Rescuer re-sent the note with clearer details after a second look',
        },
      },
      {
        place: 'Pasong Kawayan', findings: 'Wound, Hypothermia', triage: 'Delayed', count: 2, ageGroup: 'Adult',
        arrivesIn: 52, reportedAgo: 8,
        note: 'Dalawang pasyente po, may mga sugat at nilalamig, sa Barangay Pasong Kawayan, mga isang oras pa.',
      },
    ],
  },
];

// Build the wire reports for one wave, anchored on the current minute.
function buildReports(anchorMs) {
  const entries = [];
  const identities = new Map();
  for (const { watchId, team, reports } of WATCHES) {
    reports.forEach((spec, index) => {
      const createdAt = new Date(anchorMs - spec.reportedAgo * MINUTE).toISOString();
      const key = `${watchId}|${createdAt}`;
      if (identities.has(key)) {
        throw new Error(`${watchId} has two reports with the same watch time (${createdAt}); the hub would treat them as one`);
      }
      identities.set(key, spec);
      let etaMinutes = null;
      if (spec.arrivesIn !== null) {
        etaMinutes = spec.arrivesIn + spec.reportedAgo;
        if (!Number.isInteger(etaMinutes) || etaMinutes < 1 || etaMinutes > 720) {
          throw new Error(`${watchId} · ${spec.findings}: arrivesIn ${spec.arrivesIn} + reportedAgo ${spec.reportedAgo} gives an ETA outside the 1-720 minute the hub accepts`);
        }
      }
      entries.push({
        watchId,
        team,
        key,
        spec,
        report: {
          localId: index + 1,
          location: LOCATION(spec.place),
          injuries: spec.findings,
          triage: spec.triage,
          patientCount: spec.count === null ? undefined : spec.count,
          ageGroup: spec.ageGroup,
          etaMinutes,
          rawText: spec.note,
          createdAt,
          ...(spec.processing ? { processing: spec.processing } : {}),
          // Extra fields are kept in the original submission snapshot and never drive clinical logic.
          sampleData: SAMPLE_TAG,
        },
      });
    });
  }
  return entries;
}

// Run every report through the hub's own validator before sending anything.
function findProblems(entries) {
  const problems = [];
  for (const entry of entries) {
    const { error } = validateReport(entry.report);
    if (error) problems.push(`${entry.watchId} · ${entry.spec.findings} (localId ${entry.report.localId}): ${error}`);
  }
  return problems;
}

async function call(url, options = {}) {
  let response;
  try {
    response = await fetch(url, { ...options, signal: AbortSignal.timeout(20000) });
  } catch (error) {
    throw new Error(`Cannot reach ${url} (${error.message}). Start the hub first: docker compose up --build, or cd hub && npm start`);
  }
  const body = await response.text();
  let json = null;
  try { json = JSON.parse(body); } catch { /* not JSON: keep the text */ }
  return { response, json, body };
}

const getJson = async (url) => {
  const { response, json } = await call(url);
  if (!response.ok || json === null) throw new Error(`GET ${url} failed (${response.status})`);
  return json;
};

async function postJson(url, payload) {
  const { response, json, body } = await call(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  });
  if (!response.ok || json === null) throw new Error(`POST ${url} failed (${response.status}): ${body.slice(0, 200)}`);
  return json;
}

async function patchJson(url, payload) {
  const { response, json, body } = await call(url, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  });
  if (!response.ok || json === null) throw new Error(`PATCH ${url} failed (${response.status}): ${body.slice(0, 200)}`);
  return json;
}

const pad = (text, width) => String(text).padEnd(width);
const patients = (rows) => rows.reduce((sum, r) => sum + (r.patient_count_known ? r.patient_count : 0), 0);
const category = (r) => r.effective_triage || r.triage;
const etaAtMs = (r) => (r.eta_minutes ? Date.parse(r.created_at) + r.eta_minutes * MINUTE : null);
const minsLeft = (r) => { const at = etaAtMs(r); return at === null ? null : Math.round((at - Date.now()) / MINUTE); };

function timedText(r) {
  const m = minsLeft(r);
  if (m === null) return 'no ETA given';
  if (m > 1) return `arriving in ${m} min`;
  if (m >= -2) return 'arriving now';
  return `${-m} min past ETA`;
}

// A wave already loaded recently would double the board, so ask before adding one.
async function recentWave(url) {
  const ids = new Set(WATCHES.map((w) => w.watchId));
  const rows = await getJson(`${url}/api/triage`);
  const cutoff = Date.now() - 6 * 60 * MINUTE;
  return rows.filter((r) => ids.has(r.watch_id) && Date.parse(r.received_at) >= cutoff);
}

function describeScenario(entries) {
  const counts = entries.reduce((sum, e) => sum + (e.spec.count ?? 0), 0);
  const unknown = entries.filter((e) => e.spec.count === null).length;
  const lines = [
    `${entries.length} reports from ${WATCHES.length} rescue teams, ${counts} patients`
      + (unknown ? `, plus ${unknown} report with no stated patient count` : ''),
    `Planned board actions: ${entries.filter((e) => e.spec.status === 'arrived').length} arrived, `
      + `${entries.filter((e) => e.spec.status === 'cancelled').length} cancelled, `
      + `${entries.filter((e) => e.spec.edit).length} operator edits`,
  ];
  return lines;
}

async function main(argv) {
  const args = parseArgs(argv);
  if (args.help) { printHelp(); return 0; }
  const url = args.url;

  const anchorMs = Math.floor(Date.now() / MINUTE) * MINUTE;
  const entries = buildReports(anchorMs);
  const problems = findProblems(entries);
  if (problems.length) {
    console.log('The scenario does not match the hub contract:');
    for (const problem of problems) console.log(`  - ${problem}`);
    return 1;
  }
  console.log(`WristCue sample data -> ${url}`);
  for (const line of describeScenario(entries)) console.log(`  ${line}`);

  if (args.dryRun) {
    console.log('\nDry run: every report passed the hub validator, nothing was sent.');
    return 0;
  }

  const health = await getJson(`${url}/api/health`);
  if (!health.ok) throw new Error(`${url} did not report a healthy hub`);
  const config = await getJson(`${url}/api/config`);
  console.log(`Hospital: ${config.hospital}`);

  const existing = await recentWave(url);
  if (existing.length && !args.force) {
    console.log(`\nStopped: ${existing.length} report(s) from this same sample scenario are already on the board (loaded within the last 6 hours).`);
    console.log('Loading another wave would double the patients. Re-run with --force if that is what you want.');
    return 1;
  }

  // --- one batch per rescue team, exactly as a watch syncs its queue --------
  console.log('');
  const byKey = new Map();
  for (const { watchId, team, reports } of WATCHES) {
    const mine = entries.filter((e) => e.watchId === watchId);
    const result = await postJson(`${url}/api/sync-triage`, {
      watchId,
      reports: mine.map((e) => e.report),
    });
    for (const entry of mine) byKey.set(entry.key, null);
    console.log(`  ${pad(watchId, 8)}${pad(team, 26)}${mine.length} reports -> `
      + `${result.inserted} new, ${result.duplicates} duplicate, ${result.rejected.length} rejected`);
    for (const rejected of result.rejected) console.log(`      rejected localId ${rejected.localId}: ${rejected.reason}`);
  }

  // Re-sending a batch is the flaky-Wi-Fi case the hub protects against.
  const first = WATCHES[0];
  const again = await postJson(`${url}/api/sync-triage`, {
    watchId: first.watchId,
    reports: entries.filter((e) => e.watchId === first.watchId).map((e) => e.report),
  });
  console.log(`\n  Duplicate protection: re-sent ${first.watchId}'s batch -> `
    + `${again.inserted} new, ${again.duplicates} duplicate (nothing counted twice)`);

  // --- map this run's reports to hub IDs -----------------------------------
  const rows = await getJson(`${url}/api/triage`);
  const byIdentity = new Map(rows.map((r) => [`${r.watch_id}|${r.created_at}`, r.id]));
  for (const entry of entries) {
    const id = byIdentity.get(entry.key);
    if (!id) throw new Error(`The hub did not store ${entry.watchId} · ${entry.spec.findings} (${entry.key})`);
    byKey.set(entry.key, id);
  }

  // --- board actions an ED operator would take -----------------------------
  const moved = { arrived: 0, cancelled: 0 };
  for (const entry of entries) {
    if (!entry.spec.status) continue;
    await patchJson(`${url}/api/triage/${byKey.get(entry.key)}`, { status: entry.spec.status });
    moved[entry.spec.status] += 1;
  }
  if (moved.arrived || moved.cancelled) {
    console.log(`  Board actions: ${moved.arrived} marked arrived, ${moved.cancelled} cancelled`);
  }

  // --- operator edits, through the same revisions API the dialog uses ------
  const edits = [];
  for (const entry of entries) {
    const edit = entry.spec.edit;
    if (!edit) continue;
    const id = byKey.get(entry.key);
    const detail = await getJson(`${url}/api/triage/${id}`);
    const body = { requestId: randomUUID(), baseRevision: detail.revision, actor: OPERATOR, reason: edit.reason, kind: edit.kind };
    if (edit.kind === 'correction') body.transcript = edit.transcript;
    if (edit.kind === 'override') body.override = edit.override;
    const updated = await postJson(`${url}/api/triage/${id}/revisions`, body);
    edits.push({ edit, revision: updated.revision, findings: entry.spec.findings });
  }
  for (const item of edits) {
    const what = item.edit.kind === 'correction'
      ? 'corrected transcript (original kept, extraction invalidated)'
      : `priority override -> ${item.edit.override} (computed value still shown)`;
    console.log(`  Operator edit on report ${item.findings}: ${what} · now revision ${item.revision}`);
  }

  // --- what the board now shows -------------------------------------------
  const after = await getJson(`${url}/api/triage`);
  const mine = after.filter((r) => byIdentity.has(`${r.watch_id}|${r.created_at}`));
  const unknownCount = mine.filter((r) => !r.patient_count_known).length;
  console.log(`\nSample data loaded. Board total: ${after.length} reports, ${patients(after)} patients`
    + (unknownCount ? ` (this shift has ${unknownCount} report with no stated patient count, shown as ?)` : ''));
  for (const status of ['inbound', 'arrived', 'cancelled']) {
    const group = mine.filter((r) => r.status === status);
    const per = TRIAGE.map((t) => `${t} ${patients(group.filter((r) => category(r) === t))}`).filter((line) => !line.endsWith(' 0'));
    console.log(`  ${pad(status === 'inbound' ? 'On the way' : status === 'arrived' ? 'Arrived' : 'Cancelled', 12)}`
      + `${pad(`${group.length} reports, ${patients(group)} patients`, 26)}${per.join(', ')}`);
  }
  const inbound = mine.filter((r) => r.status === 'inbound')
    .sort((a, b) => RANK[category(a)] - RANK[category(b)] || (etaAtMs(a) ?? Infinity) - (etaAtMs(b) ?? Infinity));
  console.log('\nTop of the board:');
  inbound.slice(0, 5).forEach((r, index) => {
    console.log(`  ${index + 1}. ${pad(category(r), 11)}${pad(`x${r.patient_count_known ? r.patient_count : '?'}`, 5)}`
      + `${pad(r.injuries, 34)}${pad(r.location, 24)}${timedText(r)}`);
  });
  console.log(`\nOpen the board: ${url}`);
  console.log('  On the way   the time board, Teams to alert, and the priority patient with its Get ready list');
  console.log('  Arrived      level totals, and cancelled urgent reports waiting to be reopened');
  console.log('  A row\'s "Evidence and corrections" shows the stored original note and the revision history');
  return 0;
}

function parseArgs(argv) {
  const args = { url: DEFAULT_URL, dryRun: false, force: false, help: false };
  for (let i = 0; i < argv.length; i += 1) {
    const item = argv[i];
    if (item === '--url') {
      const value = argv[i + 1];
      if (!value) throw new Error('--url needs an address, for example --url http://127.0.0.1:3000');
      args.url = value.replace(/\/+$/, '');
      i += 1;
    } else if (item === '--dry-run') args.dryRun = true;
    else if (item === '--force') args.force = true;
    else if (item === '--help' || item === '-h') args.help = true;
    else throw new Error(`Unknown argument: ${item} (try --help)`);
  }
  if (!/^https?:\/\/[^\s]+$/.test(args.url)) throw new Error(`--url must look like http://host:port (got "${args.url}")`);
  return args;
}

function printHelp() {
  console.log('WristCue sample data: loads one synthetic flood-drill shift into a running hub.');
  console.log('');
  console.log('  node seed.js                              hub on http://127.0.0.1:3000');
  console.log('  node seed.js --url http://127.0.0.1:3301  a different hospital (for example the QA hospital)');
  console.log('  node seed.js --dry-run                    validate the scenario and send nothing');
  console.log('  node seed.js --force                      load another wave even if one is already on the board');
  console.log('');
  console.log('Synthetic patients only. Never point this at a hub that holds real reports.');
}

if (require.main === module) {
  main(process.argv.slice(2)).then((code) => { process.exitCode = code; }).catch((error) => {
    console.log(`\nSeed failed: ${error.message}`);
    process.exitCode = 1;
  });
}

module.exports = { buildReports, findProblems, WATCHES };
