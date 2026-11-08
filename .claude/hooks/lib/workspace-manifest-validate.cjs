/**
 * workspace-manifest-validate.cjs - Pure validation of adf-workspace.json content.
 *
 * Returns messages only, never the offending value, so a URL with a token cannot leak through
 * an error line. Also holds the regexes and helpers that system-map validation shares.
 *
 * @module workspace-manifest-validate
 */

'use strict';

const path = require('path');
const { DEFAULT_ROLE_DIRS } = require('./repo-shape-detector.cjs');
const { parseRemoteUrl, canonicalUrl, stripCredentials } = require('./git-remote-url.cjs');

const NAME_RE = /^[a-z0-9][a-z0-9-]{0,62}$/;
const ROLE_DIR_RE = /^[a-z][a-z0-9-]{0,30}$/;
// Key names echoed in messages: anything else could carry markup or a secret into a printed line
const SAFE_KEY_RE = /^[A-Za-z0-9_.-]{1,40}$/;
const DIR_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/;
const OWNER_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/;
const REF_RE = /^[A-Za-z0-9][A-Za-z0-9._/-]{0,199}$/;
// A role dir named docs would gitignore the system map itself; worktrees/ is already a managed ignore line
const RESERVED_ROLE_DIRS = ['worktrees', 'docs', 'plans'];
const FLOWS = ['release-train', 'trunk', 'off'];
const ENFORCEMENTS = ['off', 'ask', 'deny'];
const TOP_KEYS = ['version', 'client', 'product', 'org', 'repo', 'roleDirs', 'members'];
const MEMBER_KEYS = ['name', 'path', 'repo', 'branch', 'git'];
const GIT_KEYS = ['flow', 'enforcement', 'mainBranch'];

const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

/** Role dirs of a manifest: its own valid list, else the four defaults. */
function roleDirsOf(manifest) {
  const list = manifest && manifest.roleDirs;
  return Array.isArray(list) && list.length > 0 ? list.filter((d) => typeof d === 'string') : [...DEFAULT_ROLE_DIRS];
}

/** A git ref name that is safe to pass as an argument: no leading "-", no "..", "//", "@{" or ".lock". */
function isRefName(v) {
  return typeof v === 'string' && REF_RE.test(v) && !/\.\.|\/\/|@\{|\/\.|\.lock$|[./]$/.test(v);
}

/** Userinfo in an http(s) URL, a password in an ssh:// URL, or user:secret@ before an scp-style host. */
function hasCredentials(url) {
  return stripCredentials(url) !== url || /^[^/@\s]*:[^/@\s]*@/.test(url);
}

/** @returns {string|null} A message when `repo` is not a clean remote URL, file:// URL or absolute path. */
function repoError(label, repo) {
  if (typeof repo !== 'string' || !repo.trim()) return `${label} must be a non-empty string`;
  if (repo.startsWith('-')) return `${label} must not start with "-"`;
  if (/[\u0000-\u001f\u007f\s]/.test(repo)) return `${label} must not contain whitespace or control characters`;
  if (hasCredentials(repo)) return `${label} must not contain credentials`;
  if (/^file:\/\/./i.test(repo) || path.posix.isAbsolute(repo) || path.win32.isAbsolute(repo)) return null;
  return parseRemoteUrl(repo) ? null : `${label} must be a remote git URL, a file:// URL or an absolute path`;
}

/** @returns {string[]} Errors for a non-empty array of unique owner names (shared with the system map). */
function validateOrg(org, label = 'org') {
  if (!Array.isArray(org) || org.length === 0) return [`${label} must be a non-empty array of owner names`];
  const errors = [];
  const seen = new Set();
  org.forEach((owner, i) => {
    if (typeof owner !== 'string' || !OWNER_RE.test(owner)) return errors.push(`${label}[${i}] must be an owner name (letters, digits, ".", "_", "-")`);
    if (seen.has(owner.toLowerCase())) errors.push(`${label}[${i}] duplicates an earlier owner`);
    seen.add(owner.toLowerCase());
  });
  return errors;
}

/**
 * JSON.parse that never leaks file content: Node's SyntaxError message quotes an excerpt of the
 * input, which could hold a token, so only the line number is reported.
 * @returns {{ value?: unknown, error?: string }}
 */
function parseJson(text, label) {
  try { return { value: JSON.parse(text) }; } catch (err) {
    const at = /position (\d+)/.exec(String(err && err.message));
    const line = at ? ` (line ${text.slice(0, Number(at[1])).split('\n').length})` : '';
    return { error: `${label} is not valid JSON${line}` };
  }
}

function warnUnknownKeys(obj, known, label, warnings) {
  for (const key of Object.keys(obj)) {
    if (!known.includes(key)) warnings.push(`${label}: unknown key ${SAFE_KEY_RE.test(key) ? JSON.stringify(key) : '(name not shown)'}`);
  }
}

function validateRoleDirs(roleDirs, errors) {
  if (roleDirs === undefined) return;
  if (!Array.isArray(roleDirs) || roleDirs.length === 0) return errors.push('roleDirs must be a non-empty array of directory names');
  const seen = new Set();
  roleDirs.forEach((dir, i) => {
    if (typeof dir !== 'string' || !ROLE_DIR_RE.test(dir)) return errors.push(`roleDirs[${i}] must match ${ROLE_DIR_RE}`);
    if (RESERVED_ROLE_DIRS.includes(dir)) errors.push(`roleDirs[${i}] uses a reserved name (${RESERVED_ROLE_DIRS.join(', ')})`);
    if (seen.has(dir)) errors.push(`roleDirs[${i}] duplicates an earlier role dir`);
    seen.add(dir);
  });
}

/** @returns {string|null} A message when `p` is not exactly `<roleDir>/<dir>`. */
function memberPathError(label, p, roleDirs) {
  if (typeof p !== 'string' || !p) return `${label}.path must be a non-empty string`;
  if (p.includes('\\') || p.startsWith('/') || p.includes('--')) return `${label}.path must be a relative posix path without "--"`;
  const parts = p.split('/');
  if (parts.some((s) => s === '' || s === '.' || s === '..')) return `${label}.path must not contain empty, "." or ".." segments`;
  if (parts.length !== 2) return `${label}.path must be exactly <roleDir>/<dir>`;
  if (!roleDirs.includes(parts[0])) return `${label}.path must start with one of roleDirs (${roleDirs.filter((d) => ROLE_DIR_RE.test(d)).join(', ')})`;
  return DIR_RE.test(parts[1]) ? null : `${label}.path directory name has unsupported characters`;
}

function validateGit(label, git, errors, warnings) {
  if (!isObject(git)) return errors.push(`${label}.git is required: { flow, enforcement, mainBranch }`);
  warnUnknownKeys(git, GIT_KEYS, `${label}.git`, warnings);
  if (!FLOWS.includes(git.flow)) errors.push(`${label}.git.flow must be one of ${FLOWS.join('|')}`);
  if (!ENFORCEMENTS.includes(git.enforcement)) errors.push(`${label}.git.enforcement must be one of ${ENFORCEMENTS.join('|')}`);
  if (!isRefName(git.mainBranch)) errors.push(`${label}.git.mainBranch must be a branch name`);
}

function validateMember(m, i, roleDirs, seen, errors, warnings) {
  const label = isObject(m) && typeof m.name === 'string' && NAME_RE.test(m.name) ? `members[${i}] (${m.name})` : `members[${i}]`;
  if (!isObject(m)) return errors.push(`${label} must be an object`);
  warnUnknownKeys(m, MEMBER_KEYS, label, warnings);
  if (typeof m.name !== 'string' || !NAME_RE.test(m.name)) errors.push(`${label}.name must match ${NAME_RE}`);
  else if (seen.names.has(m.name)) errors.push(`${label}.name duplicates an earlier member`);
  else seen.names.add(m.name);
  const pathError = memberPathError(label, m.path, roleDirs);
  if (pathError) errors.push(pathError);
  else if (seen.paths.has(m.path.toLowerCase())) errors.push(`${label}.path duplicates an earlier member`);
  else seen.paths.add(m.path.toLowerCase());
  if (m.repo === undefined) warnings.push(`${label} has no repo; bootstrap cannot clone it`);
  else {
    const repoMessage = repoError(`${label}.repo`, m.repo);
    if (repoMessage) errors.push(repoMessage);
    else if (parseRemoteUrl(m.repo) === null) warnings.push(`${label}.repo is local; other machines cannot clone it`);
  }
  if (m.branch !== undefined && !isRefName(m.branch)) errors.push(`${label}.branch must be a branch name`);
  validateGit(label, m.git, errors, warnings);
}

/**
 * @param {unknown} obj Parsed adf-workspace.json
 * @returns {{ errors: string[], warnings: string[] }}
 */
function validateManifest(obj) {
  const errors = [];
  const warnings = [];
  if (!isObject(obj)) return { errors: ['manifest must be a JSON object'], warnings };
  warnUnknownKeys(obj, TOP_KEYS, 'manifest', warnings);
  if (obj.version !== 1) errors.push('version must be 1');
  for (const key of ['client', 'product']) {
    if (obj[key] !== undefined && (typeof obj[key] !== 'string' || !NAME_RE.test(obj[key]))) errors.push(`${key} must match ${NAME_RE}`);
  }
  errors.push(...validateOrg(obj.org));
  if (obj.repo !== undefined && (typeof obj.repo !== 'string' || canonicalUrl(obj.repo) !== obj.repo)) {
    errors.push('repo must be a canonical https URL without credentials (https://host/owner/name)');
  }
  validateRoleDirs(obj.roleDirs, errors);
  if (!Array.isArray(obj.members)) errors.push('members must be an array');
  else {
    const roleDirs = roleDirsOf(obj);
    const seen = { names: new Set(), paths: new Set() };
    obj.members.forEach((m, i) => validateMember(m, i, roleDirs, seen, errors, warnings));
  }
  return { errors, warnings };
}

module.exports = {
  NAME_RE,
  REF_RE,
  isObject,
  isRefName,
  hasCredentials,
  repoError,
  roleDirsOf,
  validateOrg,
  parseJson,
  warnUnknownKeys,
  validateManifest,
};
