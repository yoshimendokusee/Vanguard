const { createHash, timingSafeEqual } = require('node:crypto');
const { existsSync } = require('node:fs');

function hubAccess(raw = process.env.HUB_USERS || '', db = null) {
  let users;
  try { users = raw ? JSON.parse(raw) : []; } catch { throw Error('HUB_USERS must be valid JSON; credential values are not logged'); }
  if (!Array.isArray(users) || users.some(user => !user || !/^[A-Za-z0-9_-]{1,64}$/.test(user.id || '')
    || !['operator', 'device'].includes(user.role) || typeof user.token !== 'string' || user.token.length < 32
    || (user.role === 'device' && (!Array.isArray(user.watchIds) || !user.watchIds.length
      || user.watchIds.some(id => typeof id !== 'string' || !id.trim() || id.length > 64))))
    || new Set(users.map(user => user.id)).size !== users.length || new Set(users.map(user => user.token)).size !== users.length) {
    throw Error('HUB_USERS requires unique IDs/tokens (32+ characters), operator/device roles and device watchIds');
  }
  const hash = value => createHash('sha256').update(value).digest();
  const identities = users.map(({ token, ...user }) => ({ ...user, digest: hash(token) }));
  return (req, res, next) => {
    const dynamic = db ? db.prepare('SELECT id, watch_id, token_digest FROM enrolled_devices').all()
      .map(({ id, watch_id, token_digest }) => ({ id, role: 'device', watchIds: [watch_id], digest: Buffer.from(token_digest, 'hex') })) : [];
    if ((!identities.length && !dynamic.length) || req.path === '/health'
      || (req.method === 'POST' && req.path === '/enrollment/redeem')) return next();
    const token = /^Bearer (\S+)$/.exec(req.get('authorization') || '')?.[1];
    const digest = token && hash(token);
    const user = token && [...identities, ...dynamic].find(identity => identity.digest.length === digest.length && timingSafeEqual(identity.digest, digest));
    if (!user) return res.status(401).json({ ok: false, contractVersion: 1, requestId: req.requestId, error: 'authentication-required', message: 'Use your assigned hub access token' });
    req.user = user;
    if (user.role === 'operator' || ['/config', '/ai/health', '/ai/status', '/ai/extract', '/ai/triage-assist'].includes(req.path)) return next();
    if (req.path === '/sync-triage' && req.method === 'POST' && user.watchIds.includes(req.body?.watchId)) return next();
    // Ownership and correction-only writes are checked by the report routes before accessing data.
    if ((req.method === 'GET' && /^\/triage\/source\/[a-f0-9-]{36}$/i.test(req.path))
      || (req.method === 'POST' && /^\/triage\/[1-9]\d*\/revisions$/.test(req.path))) return next();
    return res.status(403).json({ ok: false, contractVersion: 1, requestId: req.requestId, error: 'access-denied', message: 'This credential cannot access that device or hospital record' });
  };
}

function validateLanAccess() {
  hubAccess();
  // Container publishing and a native process's listening address are different boundaries.
  const bind = existsSync('/.dockerenv') ? process.env.HUB_BIND_ADDRESS || '127.0.0.1' : process.env.HOST || '127.0.0.1';
  if (!['127.0.0.1', 'localhost', '::1'].includes(bind) && !JSON.parse(process.env.HUB_USERS || '[]').length) {
    throw Error('LAN binding requires HUB_USERS credentials; keep loopback binding for an anonymous synthetic demo');
  }
}
module.exports = { hubAccess, validateLanAccess };
