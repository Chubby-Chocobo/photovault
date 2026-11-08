/**
 * drift-cache.cjs - Short-lived cache for the session-start drift line, in os.tmpdir() (pattern of
 * git-info-cache.cjs). The key is the mtimes of the files the report reads, so editing a pin file
 * or moving a member's HEAD or index invalidates it; the TTL bounds anything the key misses.
 * Fail-open: any fs error is a miss on read and a no-op on write.
 *
 * This file is the only place that holds the TTLs and the two time budgets.
 *
 * @module drift-cache
 */

'use strict';

const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');

const DRIFT_CACHE_TTL_MS = 600000;
// A result cut short by the budget is kept briefly: long enough not to repeat a slow run at every session start
const TRUNCATED_DRIFT_TTL_MS = 60000;
const SESSION_DRIFT_BUDGET_MS = 2000;
const BRIEF_DRIFT_BUDGET_MS = 5000;

const sha1 = (text) => crypto.createHash('sha1').update(text).digest('hex');
const cachePath = (root) => path.join(os.tmpdir(), `adf-drift-cache-${sha1(String(root)).slice(0, 12)}.json`);

function mtimeOf(file) {
  try { return String(fs.statSync(file).mtimeMs); } catch { return 'x'; }
}

/**
 * @param {string[]} files Absolute paths whose modification times decide whether the cache is current
 * @returns {string}
 */
function driftCacheKey(files) {
  return sha1([...new Set(files)].map((f) => `${f}\t${mtimeOf(f)}`).join('\n'));
}

/**
 * @param {string} root Project root the entry belongs to
 * @param {string} key From driftCacheKey
 * @param {{ now?: number }} [opts]
 * @returns {object|null} the stored data, or null on a miss, a stale key or an expired entry
 */
function readCachedDrift(root, key, { now = Date.now() } = {}) {
  try {
    const entry = JSON.parse(fs.readFileSync(cachePath(root), 'utf8'));
    // An entry may ask for a shorter life; never a longer one
    const ttl = Number.isFinite(entry.ttlMs) && entry.ttlMs > 0 ? Math.min(entry.ttlMs, DRIFT_CACHE_TTL_MS) : DRIFT_CACHE_TTL_MS;
    const fresh = entry && entry.key === key && Number.isFinite(entry.timestamp) && now - entry.timestamp < ttl;
    return fresh && entry.data && typeof entry.data === 'object' ? entry.data : null;
  } catch { return null; }
}

/** Atomic write (temp file, then rename); failures are ignored. `ttlMs` shortens the entry's life. */
function writeCachedDrift(root, key, data, { now = Date.now(), ttlMs } = {}) {
  const file = cachePath(root);
  const tmp = `${file}.${process.pid}.tmp`;
  try {
    fs.writeFileSync(tmp, JSON.stringify({ timestamp: now, key, data, ...(ttlMs ? { ttlMs } : {}) }));
    fs.renameSync(tmp, file);
  } catch {
    try { fs.unlinkSync(tmp); } catch { /* nothing to clean */ }
  }
}

module.exports = {
  DRIFT_CACHE_TTL_MS,
  TRUNCATED_DRIFT_TTL_MS,
  SESSION_DRIFT_BUDGET_MS,
  BRIEF_DRIFT_BUDGET_MS,
  driftCacheKey,
  readCachedDrift,
  writeCachedDrift,
};
