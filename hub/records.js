const { text } = require('./processing');

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const isId = (value) => typeof value === 'string' && UUID.test(value);
const object = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);

function fail(status, message) {
  const error = new Error(message);
  error.status = status;
  throw error;
}

// Only validated JSON reaches storage; key order must not change replay identity.
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (object(value)) return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonical(value[key])]));
  return value;
}
const encode = (value) => JSON.stringify(canonical(value));

function validateEdit(input) {
  if (!object(input) || !isId(input.requestId) || !text(input.actor, 100) || !text(input.reason, 500)
    || !Number.isSafeInteger(input.baseRevision) || input.baseRevision < 0) fail(400, 'Expected requestId, actor, reason and baseRevision');
}

function getRecord(db, kind, id) {
  id = id.toLowerCase();
  const patient = kind === 'patient';
  const table = patient ? 'patient_revisions' : 'encounter_revisions';
  const key = patient ? 'patient_id' : 'encounter_id';
  const history = db.prepare(`SELECT * FROM ${table} WHERE ${key} = ? ORDER BY revision`).all(id);
  if (!history.length) fail(404, `${kind} not found`);
  return { id, ...history.at(-1), history };
}

function saveRecord(db, kind, id, input, creating = false) {
  if (!isId(id) || !object(input)) fail(400, 'Invalid record ID or body');
  id = id.toLowerCase();
  validateEdit({ ...input, baseRevision: creating ? 0 : input.baseRevision });
  const patient = kind === 'patient';
  const table = patient ? 'patient_revisions' : 'encounter_revisions';
  const key = patient ? 'patient_id' : 'encounter_id';
  const allowed = ['requestId', 'actor', 'reason', ...(creating ? [] : ['baseRevision']),
    ...(patient ? ['identityStatus', 'name', ...(creating ? ['patientId'] : [])] : ['patientId', 'incident', ...(creating ? ['encounterId'] : [])])];
  if (Object.keys(input).some((key) => !allowed.includes(key))) fail(400, 'Unsupported record field');
  if (patient) {
    if (!['unknown', 'reported'].includes(input.identityStatus)
      || !(input.name === null || text(input.name, 200))
      || (input.identityStatus === 'unknown' && input.name !== null)) fail(400, 'Invalid patient identity');
  } else if (!(input.patientId === null || isId(input.patientId))
    || !(input.incident === null || text(input.incident, 1000))) fail(400, 'Invalid encounter');
  const payload = encode(input);
  const requestId = input.requestId.toLowerCase();
  const patientId = patient ? null : input.patientId?.toLowerCase() ?? null;
  return db.transaction(() => {
    const replay = db.prepare(`SELECT payload_json FROM ${table} WHERE ${key} = ? AND request_id = ?`).get(id, requestId);
    if (replay) {
      if (replay.payload_json !== payload) fail(409, 'Request ID conflict');
      return getRecord(db, kind, id);
    }
    const latest = db.prepare(`SELECT revision FROM ${table} WHERE ${key} = ? ORDER BY revision DESC LIMIT 1`).get(id);
    if (creating && latest) fail(409, `${kind} already exists; append a revision`);
    if (!creating && !latest) fail(404, `${kind} not found`);
    if (!creating && latest.revision !== input.baseRevision) fail(409, 'Stale base revision');
    if (!patient && patientId !== null && !db.prepare('SELECT 1 FROM patients WHERE id = ?').get(patientId)) {
      fail(400, 'Patient not found');
    }
    const now = new Date().toISOString();
    if (creating) db.prepare(`INSERT INTO ${patient ? 'patients' : 'encounters'} (id, created_at) VALUES (?, ?)`).run(id, now);
    const revision = creating ? 0 : latest.revision + 1;
    const fields = patient ? 'identity_status, name' : 'patient_id, incident';
    db.prepare(`INSERT INTO ${table} (${key}, revision, request_id, actor, reason, ${fields}, payload_json, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(id, revision, requestId, input.actor, input.reason,
      patient ? input.identityStatus : patientId, patient ? input.name : input.incident, payload, now);
    return getRecord(db, kind, id);
  }).immediate();
}

module.exports = { isId, object, fail, encode, validateEdit, getRecord, saveRecord };
