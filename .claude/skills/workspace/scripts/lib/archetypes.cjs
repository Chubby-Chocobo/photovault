/**
 * archetypes.cjs - Archetype templates for `workspace init|seed-map --archetype <id>`.
 *
 * An archetype adds role aliases to the system map's `roles` and records its id as `archetype`.
 * `check` then reports the roles and contract kinds it expects but the map does not have, as
 * information: an archetype never makes a map invalid. `description` is documentation and is never printed. No throws: problems come back as messages.
 *
 * @module archetypes
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { NAME_RE, isObject } = require('../../../../hooks/lib/workspace-manifest-validate.cjs');
const { KINDS, safeText } = require('../../../../hooks/lib/system-map-validate.cjs');

const ARCHETYPE_DIR = path.join(__dirname, '..', '..', 'templates', 'archetypes');
const MAX_ARCHETYPE_BYTES = 64 * 1024;

const isTextList = (v) => Array.isArray(v) && v.every(safeText);

/** @returns {string[]} what is wrong with a parsed archetype file (messages never echo values) */
function validateArchetype(value, id) {
  if (!isObject(value)) return ['archetype must be a JSON object'];
  const errors = [];
  if (value.id !== id) errors.push('archetype id must match its file name');
  if (typeof value.description !== 'string' || value.description.length === 0 || value.description.length > 300) errors.push('description must be a string of up to 300 characters');
  if (!isObject(value.roles)) errors.push('roles must be an object of role -> aliases');
  else {
    for (const [role, aliases] of Object.entries(value.roles)) {
      if (!safeText(role) || !isTextList(aliases)) errors.push('roles must map safe-text roles to arrays of safe-text aliases');
    }
  }
  if (!isTextList(value.expectedRoles)) errors.push('expectedRoles must be an array of safe text');
  if (!Array.isArray(value.expectedContractKinds) || !value.expectedContractKinds.every((k) => KINDS.includes(k))) {
    errors.push(`expectedContractKinds must be an array of ${KINDS.join('|')}`);
  }
  return errors;
}

/** @returns {{ archetype: object|null, error: string|null }} an id with path characters is rejected before any file is read */
function loadArchetype(id) {
  if (typeof id !== 'string' || !NAME_RE.test(id)) return { archetype: null, error: `archetype id must match ${NAME_RE}` };
  const file = path.join(ARCHETYPE_DIR, `${id}.json`);
  let parsed;
  try {
    if (fs.statSync(file).size > MAX_ARCHETYPE_BYTES) return { archetype: null, error: `archetype ${id} is larger than 64 KB` };
    parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (err) {
    return { archetype: null, error: err && err.code === 'ENOENT' ? `unknown archetype ${id} (available: ${listArchetypes().join(', ') || 'none'})` : `archetype ${id} cannot be read` };
  }
  const errors = validateArchetype(parsed, id);
  return errors.length > 0 ? { archetype: null, error: `archetype ${id} is invalid: ${errors.join('; ')}` } : { archetype: parsed, error: null };
}

/** The archetype named by `--archetype`, `{ archetype: null, error: null }` when the flag is absent. */
function archetypeOption(opts) {
  if (opts.archetype === undefined) return { archetype: null, error: null };
  return loadArchetype(opts.archetype === true ? '' : opts.archetype);
}

/** Ids of the shipped archetypes, sorted. */
function listArchetypes() {
  try {
    return fs.readdirSync(ARCHETYPE_DIR).filter((f) => f.endsWith('.json')).map((f) => f.slice(0, -5)).filter((id) => NAME_RE.test(id)).sort();
  } catch { return []; }
}

/** Union of two role tables: aliases of a shared role are merged (case-insensitive), new roles are appended. */
function mergeRoles(base, extra) {
  const out = {};
  for (const [role, aliases] of Object.entries(base || {})) out[role] = [...aliases];
  for (const [role, aliases] of Object.entries(extra || {})) {
    const have = out[role] || (out[role] = []);
    for (const alias of aliases) if (!have.some((a) => String(a).toLowerCase() === alias.toLowerCase())) have.push(alias);
  }
  return out;
}

/** Copy of `map` with the archetype's roles merged in and `archetype` set; `map.roles` defaults to the built-in roles. */
function applyArchetype(map, archetype, defaultRoles = {}) {
  return { ...map, archetype: archetype.id, roles: mergeRoles(map.roles || defaultRoles, archetype.roles) };
}

/**
 * Information and warnings for the archetype a map names: expected roles with no component, and
 * a note when no contract has an expected kind. An unknown archetype id is a warning, never an error.
 * @returns {{ info: string[], warnings: string[] }}
 */
function archetypeFindings(map) {
  const none = { info: [], warnings: [] };
  if (!map || map.archetype === undefined) return none;
  const { archetype, error } = loadArchetype(map.archetype);
  if (!archetype) return { info: [], warnings: [`archetype: ${error}`] };
  const roles = new Set((map.components || []).map((c) => c.role));
  const info = archetype.expectedRoles.filter((r) => !roles.has(r)).map((r) => `archetype ${archetype.id}: no component with role ${r}`);
  const kinds = new Set((map.contracts || []).map((c) => c.kind));
  if (archetype.expectedContractKinds.length > 0 && !archetype.expectedContractKinds.some((k) => kinds.has(k))) {
    info.push(`archetype ${archetype.id}: no contract of kind ${archetype.expectedContractKinds.join(' or ')}`);
  }
  return { info, warnings: [] };
}

module.exports = { loadArchetype, archetypeOption, listArchetypes, validateArchetype, applyArchetype, archetypeFindings };
