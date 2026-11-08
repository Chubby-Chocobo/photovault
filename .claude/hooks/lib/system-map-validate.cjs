/**
 * system-map-validate.cjs - Pure validation of docs/architecture/system-map.json.
 *
 * Every string that later phases print or render (role, stack, topic, subpath, path, client,
 * product, role aliases) must match SAFE_TEXT and contain no "--", so a map cannot smuggle markup,
 * comment terminators or control characters into generated text. Messages never echo values.
 *
 * @module system-map-validate
 */

'use strict';

const { NAME_RE, isObject, validateOrg, warnUnknownKeys, repoError } = require('./workspace-manifest-validate.cjs');

const SAFE_TEXT = /^[A-Za-z0-9][A-Za-z0-9 ._/:@-]{0,120}$/;
const VIA = ['grpc', 'rest', 'kafka', 'amqp', 'websocket', 'db', 'other'];
const KINDS = ['proto', 'openapi', 'asyncapi', 'json-schema', 'abi', 'graphql', 'other'];
const TOP_KEYS = ['version', 'client', 'product', 'org', 'archetype', 'roles', 'components', 'contracts'];
const COMPONENT_KEYS = ['name', 'member', 'subpath', 'path', 'repo', 'role', 'stack', 'calls', 'consumes', 'produces'];
const CONTRACT_KEYS = ['id', 'kind', 'member', 'subpath', 'path', 'repo'];
const CALL_KEYS = ['to', 'via', 'topic'];

const safeText = (v) => typeof v === 'string' && SAFE_TEXT.test(v) && !v.includes('--');
/** A relative posix path inside its base: safe text, no empty, "." or ".." segment. */
const safePath = (v) => safeText(v) && v.split('/').every((s) => s !== '' && s !== '.' && s !== '..');

function checkText(errors, label, value, check = safeText) {
  if (value !== undefined && !check(value)) errors.push(`${label} must match ${SAFE_TEXT} and contain no "--"${check === safePath ? ' or ".." segments' : ''}`);
}

function validateRoles(roles, errors) {
  if (roles === undefined) return;
  if (!isObject(roles)) return errors.push('roles must be an object of role -> aliases');
  for (const [role, aliases] of Object.entries(roles)) {
    if (!safeText(role)) errors.push('roles has a key that is not safe text');
    if (!Array.isArray(aliases) || !aliases.every(safeText)) errors.push(`roles.${safeText(role) ? role : '(key)'} must be an array of safe text aliases`);
  }
}

/** Placement fields: `member` (+ `subpath`) in a workspace, `path` (+ contract `repo`) in a monorepo. */
function validatePlacement(label, item, manifest, errors, warnings) {
  if (manifest) {
    const names = new Set(manifest.members.map((m) => m.name));
    if (typeof item.member !== 'string' || !names.has(item.member)) errors.push(`${label}.member must name a manifest member`);
    checkText(errors, `${label}.subpath`, item.subpath, safePath);
    for (const key of ['path', 'repo']) {
      if (item[key] !== undefined) warnings.push(`${label}.${key} is derived from the manifest and ignored`);
    }
    return;
  }
  if (item.member !== undefined || item.subpath !== undefined) errors.push(`${label}.member and subpath need adf-workspace.json; use path`);
  if (!safePath(item.path)) errors.push(`${label}.path is required: a relative safe path without ".." segments`);
  if (item.repo !== undefined) {
    const message = repoError(`${label}.repo`, item.repo);
    if (message) errors.push(message);
  }
}

function checkId(label, value, seen, errors) {
  if (typeof value !== 'string' || !NAME_RE.test(value)) errors.push(`${label} must match ${NAME_RE}`);
  else if (seen.has(value)) errors.push(`${label} duplicates an earlier entry`);
  else seen.add(value);
}

function validateComponent(c, i, ctx) {
  const { errors, warnings, manifest, componentNames, contractIds } = ctx;
  if (!isObject(c)) return errors.push(`components[${i}] must be an object`);
  const label = `components[${i}]${typeof c.name === 'string' && NAME_RE.test(c.name) ? ` (${c.name})` : ''}`;
  warnUnknownKeys(c, COMPONENT_KEYS, label, warnings);
  checkId(`${label}.name`, c.name, ctx.seenNames, errors);
  validatePlacement(label, c, manifest, errors, warnings);
  checkText(errors, `${label}.role`, c.role);
  checkText(errors, `${label}.stack`, c.stack);
  if (c.calls !== undefined && !Array.isArray(c.calls)) errors.push(`${label}.calls must be an array`);
  (Array.isArray(c.calls) ? c.calls : []).forEach((call, j) => {
    const callLabel = `${label}.calls[${j}]`;
    if (!isObject(call)) return errors.push(`${callLabel} must be an object`);
    warnUnknownKeys(call, CALL_KEYS, callLabel, warnings);
    if (typeof call.to !== 'string' || !componentNames.has(call.to)) errors.push(`${callLabel}.to must name a component`);
    if (!VIA.includes(call.via)) errors.push(`${callLabel}.via must be one of ${VIA.join('|')}`);
    checkText(errors, `${callLabel}.topic`, call.topic);
  });
  for (const key of ['consumes', 'produces']) {
    if (c[key] === undefined) continue;
    if (!Array.isArray(c[key])) errors.push(`${label}.${key} must be an array of contract ids`);
    else if (!c[key].every((id) => typeof id === 'string' && contractIds.has(id))) errors.push(`${label}.${key} must name contract ids`);
  }
}

function validateContract(c, i, ctx) {
  const { errors, warnings, manifest } = ctx;
  if (!isObject(c)) return errors.push(`contracts[${i}] must be an object`);
  const label = `contracts[${i}]${typeof c.id === 'string' && NAME_RE.test(c.id) ? ` (${c.id})` : ''}`;
  warnUnknownKeys(c, CONTRACT_KEYS, label, warnings);
  checkId(`${label}.id`, c.id, ctx.seenIds, errors);
  if (!KINDS.includes(c.kind)) errors.push(`${label}.kind must be one of ${KINDS.join('|')}`);
  validatePlacement(label, c, manifest, errors, warnings);
}

const namesOf = (list, key) => new Set((Array.isArray(list) ? list : []).map((x) => isObject(x) && x[key]).filter((v) => typeof v === 'string'));

/**
 * @param {unknown} map Parsed system-map.json
 * @param {{ manifest?: object|null }} [opts] A valid manifest switches to the workspace join (member) rules
 * @returns {{ errors: string[], warnings: string[] }}
 */
function validateSystemMap(map, { manifest = null } = {}) {
  const errors = [];
  const warnings = [];
  if (!isObject(map)) return { errors: ['system map must be a JSON object'], warnings };
  warnUnknownKeys(map, TOP_KEYS, 'system map', warnings);
  if (map.version !== 1) errors.push('version must be 1');
  checkText(errors, 'client', map.client);
  checkText(errors, 'product', map.product);
  if (map.archetype !== undefined && !(typeof map.archetype === 'string' && NAME_RE.test(map.archetype))) errors.push(`archetype must match ${NAME_RE}`);
  if (map.org !== undefined && manifest) warnings.push('org is read from the manifest; the map org is ignored');
  else if (map.org !== undefined) errors.push(...validateOrg(map.org));
  validateRoles(map.roles, errors);
  for (const key of ['components', 'contracts']) {
    if (map[key] !== undefined && !Array.isArray(map[key])) errors.push(`${key} must be an array`);
  }
  const ctx = {
    errors, warnings, manifest,
    seenNames: new Set(), seenIds: new Set(),
    componentNames: namesOf(map.components, 'name'), contractIds: namesOf(map.contracts, 'id'),
  };
  (Array.isArray(map.components) ? map.components : []).forEach((c, i) => validateComponent(c, i, ctx));
  (Array.isArray(map.contracts) ? map.contracts : []).forEach((c, i) => validateContract(c, i, ctx));
  return { errors, warnings };
}

module.exports = { SAFE_TEXT, VIA, KINDS, safeText, validateSystemMap };
