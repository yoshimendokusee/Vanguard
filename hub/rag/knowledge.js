/**
 * Local retrieval over a versioned medical-terminology pack (offline RAG).
 *
 * The pack is a read-only JSON file indexed into an in-memory SQLite FTS5 table.
 * No network, no embeddings and no change to the persistent hub database. The
 * pack only translates vocabulary: entries may not carry urgency, triage or
 * guideline fields, and retrieved text is passed to the model as reference only.
 * Observations still need transcript evidence and triage stays in `risk.js`.
 */

const fs = require('node:fs');
const path = require('node:path');
const Database = require('better-sqlite3');

const DEFAULT_FILE = path.join(__dirname, 'medical_terms.json');
const ENTRY_KEYS = ['id', 'phrases', 'filipino', 'english', 'medicalTerm', 'category'];
const CATEGORIES = ['symptom', 'sign', 'injury', 'mechanism', 'condition', 'anatomy', 'history'];
const MAX_ENTRIES = 5000;
const MAX_PHRASES = 24;
const MAX_TEXT = 120;
const MAX_QUERY_TOKENS = 200;
// Words that, directly before a matched phrase, deny it ("no severe bleeding", "hindi nahihilo").
const NEGATORS = new Set(['no', 'not', 'without', 'denies', 'denied', 'never', 'wala', 'walang', 'hindi', 'di', 'hindi po', 'walang po']);

// Tagalog clitics, linkers and politeness particles may sit inside a reported
// phrase without changing its claim: "nahihirapan siyang huminga" is still
// "nahihirapan huminga". Negators and content words are deliberately excluded,
// so a gap can never absorb a denial or an unrelated word.
const CLITICS = ['po', 'ho', 'opo', 'oho', 'na', 'ng', 'nang', 'pa', 'ba', 'nga', 'naman', 'lang', 'lamang',
  'din', 'rin', 'daw', 'raw', 'talaga', 'muna', 'pala', 'yata', 'ulit', 'sana', 'ay', 'yung', 'eh',
  'ako', 'akong', 'ka', 'kang', 'ko', 'kong', 'mo', 'mong', 'siya', 'siyang', 'niya', 'niyang',
  'kami', 'kaming', 'tayo', 'tayong', 'kayo', 'kayong', 'sila', 'silang', 'namin', 'nating', 'natin',
  'nila', 'nilang', 'kaniya', 'kanya', 'kanyang', 'akin', 'atin', 'ating'];
const MAX_CLITIC_GAP = 4;
// Regex fragment: required whitespace plus up to MAX_CLITIC_GAP particles.
const CLITIC_GAP = `\\s+(?:(?:${CLITICS.join('|')})\\s+){0,${MAX_CLITIC_GAP}}`;

const phrasePatterns = new Map();
function phrasePattern(phrase) {
  let re = phrasePatterns.get(phrase);
  if (!re) {
    // "ang" and its spoken forms "yung"/"yong" are interchangeable ("masakit ang dibdib" = "masakit yung dibdib").
    const escaped = phrase.split(/\s+/).map((word) => (word === 'ang'
      ? '(?:ang|yung|yong)'
      : word.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
    re = new RegExp(`\\b${escaped.join(CLITIC_GAP)}\\b`, 'i');
    phrasePatterns.set(phrase, re);
  }
  return re;
}

/**
 * Span of `phrase` inside `text`, tolerating clitic particles between its words.
 * The returned quote is always a verbatim transcript substring.
 */
function findPhraseSpan(text, phrase) {
  const m = phrasePattern(phrase).exec(text);
  return m ? { quote: m[0], start: m.index, end: m.index + m[0].length } : null;
}

class KnowledgeError extends Error {}

function normalize(text) {
  return String(text)
    .normalize('NFKC').normalize('NFD').replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, ' ')
    .trim();
}

function shortText(value, label) {
  if (typeof value !== 'string' || !value.trim() || value.length > MAX_TEXT) {
    throw new KnowledgeError(`${label} must be a non-empty string up to ${MAX_TEXT} characters`);
  }
  return value.trim();
}

function validatePack(pack) {
  if (!pack || typeof pack !== 'object' || !Array.isArray(pack.entries)) throw new KnowledgeError('Knowledge pack needs an entries array');
  const packId = shortText(pack.packId, 'packId');
  const packVersion = shortText(pack.packVersion, 'packVersion');
  if (!['unreviewed-draft', 'clinician-reviewed'].includes(pack.reviewStatus)) {
    throw new KnowledgeError('reviewStatus must be unreviewed-draft or clinician-reviewed');
  }
  if (pack.entries.length > MAX_ENTRIES) throw new KnowledgeError('Knowledge pack is too large');
  const seen = new Set();
  const entries = pack.entries.map((entry, index) => {
    const label = `entries[${index}]`;
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) throw new KnowledgeError(`${label} must be an object`);
    const extra = Object.keys(entry).filter((key) => !ENTRY_KEYS.includes(key));
    if (extra.length) throw new KnowledgeError(`${label} has unsupported fields: ${extra.join(', ')}`);
    const id = shortText(entry.id, `${label}.id`);
    if (seen.has(id)) throw new KnowledgeError(`Duplicate entry id ${id}`);
    seen.add(id);
    if (!Array.isArray(entry.phrases) || !entry.phrases.length || entry.phrases.length > MAX_PHRASES) {
      throw new KnowledgeError(`${label}.phrases must list 1-${MAX_PHRASES} phrases`);
    }
    const phrases = [...new Set(entry.phrases.map((p) => normalize(shortText(p, `${label}.phrases`))).filter(Boolean))];
    if (!phrases.length) throw new KnowledgeError(`${label}.phrases has no usable phrase`);
    if (!CATEGORIES.includes(entry.category)) throw new KnowledgeError(`${label}.category must be one of ${CATEGORIES.join(', ')}`);
    return {
      id, phrases,
      filipino: shortText(entry.filipino, `${label}.filipino`),
      english: shortText(entry.english, `${label}.english`),
      medicalTerm: shortText(entry.medicalTerm, `${label}.medicalTerm`),
      category: entry.category,
    };
  });
  return {
    packId, packVersion, reviewStatus: pack.reviewStatus,
    reviewNote: typeof pack.reviewNote === 'string' ? pack.reviewNote.slice(0, 600) : '',
    entries,
  };
}

function buildIndex(pack) {
  const valid = validatePack(pack);
  const db = new Database(':memory:');
  db.exec(`CREATE VIRTUAL TABLE phrases USING fts5(phrase, entry_id UNINDEXED, tokenize = 'unicode61 remove_diacritics 2')`);
  const insert = db.prepare('INSERT INTO phrases (phrase, entry_id) VALUES (?, ?)');
  const byId = new Map();
  db.transaction(() => {
    for (const entry of valid.entries) {
      byId.set(entry.id, entry);
      for (const phrase of entry.phrases) insert.run(phrase, entry.id);
    }
  })();
  const candidates = db.prepare('SELECT phrase, entry_id FROM phrases WHERE phrases MATCH ?');
  return { ...valid, entries: undefined, entryCount: valid.entries.length, db, byId, candidates };
}

function loadKnowledge(file = process.env.RAG_KNOWLEDGE_FILE || DEFAULT_FILE) {
  let pack;
  try { pack = JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch { throw new KnowledgeError('Knowledge pack is missing or is not valid JSON'); }
  return buildIndex(pack);
}

/**
 * Entries whose phrase occurs in the text as whole words, tolerating Tagalog
 * clitic particles between them ("nahihirapan siyang huminga"). FTS5 narrows the
 * candidates; the phrase-span check keeps "dizzy" from matching inside other words.
 */
function retrieve(index, text, { limit = 5 } = {}) {
  if (!index || typeof text !== 'string') return [];
  const normalized = normalize(text);
  if (!normalized) return [];
  const tokens = [...new Set(normalized.split(' '))].slice(0, MAX_QUERY_TOKENS);
  const query = tokens.map((token) => `"${token.replace(/"/g, '""')}"`).join(' OR ');
  const padded = ` ${normalized} `;
  const best = new Map();
  for (const row of index.candidates.all(query)) {
    const hit = findPhraseSpan(padded, row.phrase);
    if (!hit) continue;
    const previous = best.get(row.entry_id);
    if (!previous || hit.end - hit.start > previous.end - previous.start) {
      best.set(row.entry_id, { matched: row.phrase, start: hit.start, end: hit.end });
    }
  }
  // Longest matched spans first; a phrase inside an already accepted longer phrase
  // ("dibdib" inside "sumasakit ang dibdib") is the same words, not a new finding.
  const accepted = [];
  const ranked = [...best.entries()]
    .sort((a, b) => (b[1].end - b[1].start) - (a[1].end - a[1].start) || a[0].localeCompare(b[0]));
  for (const [id, hit] of ranked) {
    // Only a strictly longer span hides this one; entries sharing the same phrase are all kept.
    if (accepted.some((a) => hit.start >= a.start && hit.end <= a.end && a.end - a.start > hit.end - hit.start)) continue;
    accepted.push({ id, matched: hit.matched, start: hit.start, end: hit.end });
  }
  return accepted
    .slice(0, Math.max(0, Math.min(limit, 20)))
    .map(({ id, matched, start }) => {
      const entry = index.byId.get(id);
      const before = padded.slice(0, start).trim().split(' ');
      const negated = NEGATORS.has(before[before.length - 1]) && !NEGATORS.has(matched.split(' ')[0]);
      return { id, matched, filipino: entry.filipino, english: entry.english, medicalTerm: entry.medicalTerm, category: entry.category, negated };
    });
}

function packInfo(index) {
  return index
    ? { packId: index.packId, packVersion: index.packVersion, reviewStatus: index.reviewStatus, entryCount: index.entryCount }
    : null;
}

module.exports = { KnowledgeError, normalize, validatePack, buildIndex, loadKnowledge, retrieve, packInfo, findPhraseSpan, CLITIC_GAP };
