/**
 * plan-contract-rules.cjs - Single-value rules of the plan contract: ids, `touches` entries,
 * source entries and acceptance commands. Each check returns a reason string, or null when the
 * value is fine. Pure functions; the grammar is written up in references/plan-contract.md.
 *
 * @module plan-contract-rules
 */

'use strict';

const PHASE_ID_RE = /^[a-z0-9][a-z0-9-]{0,15}$/;
const BRIEF_ID_RE = /^[a-z0-9][a-z0-9-]{0,39}$/;
const SOURCE_RE = /^(tracker|spec|design|context): ([a-z][a-z0-9-]*):\S.*$/;
const MAX_TOUCH_LENGTH = 200;
const STATUSES = new Set(['pending', 'in-progress', 'completed', 'cancelled', 'in-review']);

/**
 * Why a `touches` entry is outside the grammar, or null. Segments are made of A-Z a-z 0-9 . _ @ + -
 * and `*`; `**` is a whole segment. The segment check (no empty, "." or ".." segment) is plan-scope's.
 */
function touchProblem(entry) {
  if (typeof entry !== 'string' || entry === '') return 'is empty';
  if (entry.length > MAX_TOUCH_LENGTH) return `is longer than ${MAX_TOUCH_LENGTH} characters`;
  if (entry.startsWith('/')) return 'is an absolute path';
  if (entry.includes('\\')) return 'contains a backslash';
  if (/[{}]/.test(entry)) return 'contains a brace';
  if (/[?[\]]/.test(entry)) return 'contains "?" or "[]"';
  if (/[\s\x00-\x1f\x7f]/.test(entry)) return 'contains whitespace or a control character';
  const segments = entry.replace(/\/+$/, '').split('/');
  if (segments.some((seg) => seg === '' || seg === '.' || seg === '..')) return 'has an empty, "." or ".." segment';
  if (segments.some((seg) => seg.includes('**') && seg !== '**')) return 'uses "**" inside a segment';
  if (segments.some((seg) => !/^[A-Za-z0-9._@+*-]+$/.test(seg))) return 'has a segment with a character outside A-Z a-z 0-9 . _ @ + - *';
  return null;
}

/** Segments of a `touches` entry before the first wildcard, joined by "/" ("" when none). */
function staticPrefix(entry) {
  const prefix = [];
  for (const seg of entry.replace(/\/+$/, '').split('/')) {
    if (seg.includes('*')) break;
    prefix.push(seg);
  }
  return prefix.join('/');
}

/** True when `touches` entry sits under one of the plan's `scope` entries. */
function underScope(entry, scope) {
  const prefix = staticPrefix(entry);
  return scope.some((raw) => {
    const dir = raw.replace(/\/+$/, '');
    return prefix === dir || prefix.startsWith(`${dir}/`);
  });
}

const sourceProblem = (entry) => (SOURCE_RE.test(entry) ? null : 'is not "<role>: <type>:<locator>" with role tracker, spec, design or context');

/** True when a `node --test` command is given an argument that ends in "/". */
function nodeTestDir(command) {
  const match = /\bnode\b[^|;&\n]*?\s--test(?=\s|$)([^|;&\n]*)/.exec(command);
  if (!match) return false;
  return match[1].split(/\s+/).filter((arg) => arg && !arg.startsWith('-')).some((arg) => arg.replace(/^["']|["']$/g, '').endsWith('/'));
}

/**
 * Dependency cycles in `graph` (id -> ids), each as a list of ids that starts and ends on the same id.
 * An edge to an id that is not a key is ignored.
 */
function findCycles(graph) {
  const cycles = [];
  const seen = new Set();
  const state = new Map();
  const stack = [];
  const visit = (id) => {
    state.set(id, 'open');
    stack.push(id);
    for (const next of graph.get(id) || []) {
      if (!graph.has(next)) continue;
      if (state.get(next) === 'open') {
        const cycle = [...stack.slice(stack.indexOf(next)), next];
        const key = [...cycle.slice(0, -1)].sort().join(',');
        if (!seen.has(key)) { seen.add(key); cycles.push(cycle); }
      } else if (!state.has(next)) visit(next);
    }
    stack.pop();
    state.set(id, 'done');
  };
  for (const id of graph.keys()) if (!state.has(id)) visit(id);
  return cycles;
}

/** True for an inline list that never closes (`[a, b`), which `toList` reads as no list at all. */
const malformedList = (raw) => typeof raw === 'string' && raw.trim().replace(/\s+#.*$/, '').startsWith('[') && !/^\[[^\]]*\]/.test(raw.trim());

module.exports = { STATUSES, malformedList, PHASE_ID_RE, BRIEF_ID_RE, touchProblem, staticPrefix, underScope, sourceProblem, nodeTestDir, findCycles };
