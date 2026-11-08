/**
 * contract-kind-scan.cjs - Guess the kind of a contract directory from the files inside it.
 *
 * Bounded walk: depth at most 3, at most 200 entries, no symlinks, no .git or node_modules.
 * `.proto` is proto, a `*.schema.json` is json-schema, a YAML or JSON file whose top-level key is
 * `openapi` or `asyncapi` is that kind. When several kinds are present the first in KIND_PRIORITY wins.
 *
 * @module contract-kind-scan
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { readTextCapped } = require('../../../../hooks/lib/read-text-capped.cjs');

const MAX_DEPTH = 3;
const MAX_ENTRIES = 200;
const MAX_FILE_BYTES = 256 * 1024;
const KIND_PRIORITY = ['proto', 'openapi', 'asyncapi', 'json-schema'];
const SKIP_DIRS = new Set(['.git', 'node_modules']);

/** Top-level spec key of a YAML or JSON document, or null. */
function specKind(file) {
  const text = readTextCapped(file, MAX_FILE_BYTES);
  if (text === null) return null;
  if (file.endsWith('.json')) {
    try {
      const doc = JSON.parse(text);
      if (doc && typeof doc === 'object') return doc.openapi !== undefined ? 'openapi' : doc.asyncapi !== undefined ? 'asyncapi' : null;
    } catch { return null; }
    return null;
  }
  if (/^openapi\s*:/m.test(text)) return 'openapi';
  return /^asyncapi\s*:/m.test(text) ? 'asyncapi' : null;
}

function kindOfFile(file) {
  const name = path.basename(file).toLowerCase();
  if (name.endsWith('.proto')) return 'proto';
  if (name.endsWith('.schema.json')) return 'json-schema';
  return /\.(ya?ml|json)$/.test(name) ? specKind(file) : null;
}

/**
 * @param {string} dir Contract directory
 * @returns {'proto'|'openapi'|'asyncapi'|'json-schema'|'other'}
 */
function scanContractKind(dir) {
  const found = new Set();
  let seen = 0;
  const walk = (current, depth) => {
    let entries;
    try { entries = fs.readdirSync(current, { withFileTypes: true }); } catch { return; }
    for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
      if (++seen > MAX_ENTRIES) return;
      if (entry.isSymbolicLink()) continue;
      const abs = path.join(current, entry.name);
      if (entry.isDirectory()) {
        if (depth < MAX_DEPTH && !SKIP_DIRS.has(entry.name)) walk(abs, depth + 1);
      } else if (entry.isFile()) {
        const kind = kindOfFile(abs);
        if (kind) found.add(kind);
      }
    }
  };
  walk(dir, 1);
  return KIND_PRIORITY.find((k) => found.has(k)) || 'other';
}

module.exports = { scanContractKind, MAX_ENTRIES };
