/**
 * settings-local-writer.cjs - The only place ADF writes Claude Code settings: a fixed allowlist
 * of keys in <root>/.claude/settings.local.json. Permissions, hooks and every other key are out
 * of reach, and settings.json is never opened.
 *
 * A patch is a nested object using only allowlisted keys; `null` removes a key. Arrays and
 * objects given for a key replace what was there. Other keys in the file are kept as they are.
 *
 * @module settings-local-writer
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { isObject } = require('./workspace-manifest-validate.cjs');

const SETTINGS_REL = '.claude/settings.local.json';
const MAX_BYTES = 1024 * 1024;

/** Allowlisted dotted keys and the shape each value must have. */
const ALLOWED = {
  'permissions.additionalDirectories': 'strings',
  // Written by /adf-mode only: auto sets bypassPermissions, strict removes it
  'permissions.defaultMode': 'string',
  'worktree.sparsePaths': 'strings',
  claudeMdExcludes: 'strings',
  adfScope: 'object',
};
const KIND_NAMES = { strings: 'an array of strings', string: 'a string', object: 'an object' };
const hasKind = (kind, value) => (kind === 'strings' ? Array.isArray(value) && value.every((v) => typeof v === 'string') : kind === 'string' ? typeof value === 'string' : isObject(value));

const prefixes = Object.keys(ALLOWED).filter((k) => k.includes('.')).map((k) => k.split('.')[0]);

/** @returns {Map<string, unknown>} dotted key to value; throws for any key that is not allowlisted or has the wrong value type */
function flatten(patch, prefix = '', out = new Map()) {
  if (!isObject(patch)) throw new Error('settings patch must be an object');
  for (const [key, value] of Object.entries(patch)) {
    const dotted = prefix ? `${prefix}.${key}` : key;
    if (Object.hasOwn(ALLOWED, dotted)) {
      const kind = ALLOWED[dotted];
      if (value !== null && !hasKind(kind, value)) throw new Error(`settings key ${dotted} must be ${KIND_NAMES[kind]} or null`);
      out.set(dotted, value);
    } else if (!prefix && prefixes.includes(key) && isObject(value)) {
      flatten(value, dotted, out);
    } else {
      throw new Error(`settings key not allowed: ${dotted}`);
    }
  }
  return out;
}

function getAt(obj, dotted) {
  return dotted.split('.').reduce((cur, part) => (isObject(cur) ? cur[part] : undefined), obj);
}

function setAt(obj, dotted, value) {
  const parts = dotted.split('.');
  const chain = [obj];
  for (const part of parts.slice(0, -1)) {
    if (value === null && !isObject(chain[chain.length - 1][part])) return;
    if (chain[chain.length - 1][part] === undefined) chain[chain.length - 1][part] = {};
    if (!isObject(chain[chain.length - 1][part])) throw new Error(`settings key ${part} is not an object; fix ${SETTINGS_REL} first`);
    chain.push(chain[chain.length - 1][part]);
  }
  const leaf = parts[parts.length - 1];
  if (value === null) {
    delete chain[chain.length - 1][leaf];
    for (let i = chain.length - 1; i > 0 && Object.keys(chain[i]).length === 0; i -= 1) delete chain[i - 1][parts[i - 1]];
  } else {
    chain[chain.length - 1][leaf] = value;
  }
}

function readSettings(root) {
  const file = path.join(root, ...SETTINGS_REL.split('/'));
  let stat;
  try { stat = fs.lstatSync(file); } catch (err) {
    if (err && err.code === 'ENOENT') return { file, data: {} };
    throw new Error(`${SETTINGS_REL} cannot be read`);
  }
  if (stat.isSymbolicLink() || !stat.isFile()) throw new Error(`${SETTINGS_REL} is not a regular file`);
  if (stat.size > MAX_BYTES) throw new Error(`${SETTINGS_REL} is larger than 1 MB`);
  let data;
  try { data = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { throw new Error(`${SETTINGS_REL} is not valid JSON; fix it first`); }
  if (!isObject(data)) throw new Error(`${SETTINGS_REL} must hold a JSON object`);
  return { file, data };
}

/** `+ key: value`, `- key: value` and both for a change, over the allowlisted keys only. */
function describeDiff(before, after) {
  const lines = [];
  for (const key of Object.keys(ALLOWED)) {
    const was = getAt(before, key);
    const now = getAt(after, key);
    if (JSON.stringify(was) === JSON.stringify(now)) continue;
    if (was !== undefined) lines.push(`- ${key}: ${JSON.stringify(was)}`);
    if (now !== undefined) lines.push(`+ ${key}: ${JSON.stringify(now)}`);
  }
  return lines;
}

/**
 * @param {string} root Project root
 * @param {object} patch Nested object of allowlisted keys; null removes a key
 * @param {{ dryRun?: boolean }} [opts] dryRun computes the diff and writes nothing
 * @returns {{ file: string, changed: boolean, diff: string[], written: boolean }}
 * @throws {Error} for a key outside the allowlist, a wrong value type, or a settings file that is not a JSON object
 */
function mergeSettingsLocal(root, patch, { dryRun = false } = {}) {
  const changes = flatten(patch);
  const { file, data } = readSettings(root);
  const next = JSON.parse(JSON.stringify(data));
  for (const [key, value] of changes) setAt(next, key, value);
  const diff = describeDiff(data, next);
  if (diff.length === 0 || dryRun) return { file, changed: diff.length > 0, diff, written: false };
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, `${JSON.stringify(next, null, 2)}\n`);
  fs.renameSync(tmp, file);
  return { file, changed: true, diff, written: true };
}

module.exports = { SETTINGS_REL, ALLOWED, mergeSettingsLocal };
