/**
 * workspace-direct-push.cjs - The workspace repo's `git.directPush.paths` (decision: plans go
 * straight to main, docs and the system map go through a pull request).
 *
 * `planDirectPush` computes the before and after for `init` and writes the proposal into the
 * workspace's .claude/config/adf-config.json only when asked. A paths list the project already set
 * is its own choice and is never replaced. Every other key of the file is kept, with 2-space
 * indentation. `directPushWarnings` is what `check` says about paths that let docs or the manifest
 * skip review.
 *
 * @module workspace-direct-push
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { GIT_DEFAULTS, matchesAny } = require('../../../../hooks/lib/git-flow-config.cjs');
const { MANIFEST_FILE } = require('../../../../hooks/lib/workspace-manifest.cjs');
const { isObject } = require('../../../../hooks/lib/workspace-manifest-validate.cjs');

const CONFIG_REL = '.claude/config/adf-config.json';
const PROPOSED_PATHS = ['plans/**', 'README.md', 'CHANGELOG.md', '.github/**'];

const isPaths = (v) => Array.isArray(v) && v.every((p) => typeof p === 'string');

/** @returns {{ config: object, error?: string }} the parsed file ({} when absent) */
function readConfig(root) {
  let text;
  try { text = fs.readFileSync(path.join(root, CONFIG_REL), 'utf8'); } catch (err) {
    return err && err.code === 'ENOENT' ? { config: {} } : { config: {}, error: `${CONFIG_REL} cannot be read; git.directPush.paths left unchanged` };
  }
  try {
    const parsed = JSON.parse(text);
    if (isObject(parsed) && (parsed.git === undefined || isObject(parsed.git))) return { config: parsed };
  } catch { /* reported below */ }
  return { config: {}, error: `${CONFIG_REL} is not a JSON object with an object "git" section; git.directPush.paths left unchanged` };
}

/** The direct-push paths in effect: the configured list, else the built-in default. */
function effectivePaths(root) {
  const { config } = readConfig(root);
  const configured = config.git && config.git.directPush && config.git.directPush.paths;
  // An explicit empty list means "nothing goes direct" (same rule as git-flow-config), so it counts as configured
  return isPaths(configured) ? { paths: configured, configured: true } : { paths: GIT_DEFAULTS.directPush.paths, configured: false };
}

/**
 * @param {string} root Workspace root
 * @param {{ dry: boolean }} opts
 * @returns {{ file: string, before: string[], after: string[], configured: boolean, status: 'written'|'would-write'|'kept'|'failed', error?: string }}
 */
function planDirectPush(root, { dry }) {
  const base = { file: CONFIG_REL, after: PROPOSED_PATHS };
  const { config, error } = readConfig(root);
  if (error) return { ...base, before: [], configured: false, status: 'failed', error };
  const { paths: before, configured } = effectivePaths(root);
  // A list the project set itself is its decision; the proposal only fills the gap
  if (configured) return { ...base, before, configured, status: 'kept' };
  if (dry) return { ...base, before, configured, status: 'would-write' };
  try {
    const git = config.git || {};
    const next = { ...config, git: { ...git, directPush: { ...(isObject(git.directPush) ? git.directPush : {}), paths: PROPOSED_PATHS } } };
    fs.mkdirSync(path.join(root, path.dirname(CONFIG_REL)), { recursive: true });
    fs.writeFileSync(path.join(root, CONFIG_REL), `${JSON.stringify(next, null, 2)}\n`);
    return { ...base, before, configured, status: 'written' };
  } catch (err) {
    return { ...base, before, configured, status: 'failed', error: `cannot write ${CONFIG_REL} (${err && err.code ? err.code : 'error'})` };
  }
}

/** Warnings for `check`: direct-push paths that cover the docs folder or the manifest. */
function directPushWarnings(root, docsRel) {
  const { paths, configured } = effectivePaths(root);
  const hits = [];
  if (matchesAny(`${docsRel}/architecture/system-map.json`, paths)) hits.push(`${docsRel}/**`);
  if (matchesAny(MANIFEST_FILE, paths)) hits.push(MANIFEST_FILE);
  if (hits.length === 0) return [];
  const source = configured ? 'git.directPush.paths' : 'the built-in git.directPush.paths default';
  const advice = configured ? 'edit git.directPush.paths in .claude/config/adf-config.json' : 'run /workspace init to propose plans/**, README.md, CHANGELOG.md, .github/**';
  return [`${source} lets ${hits.join(' and ')} go straight to the main branch without a pull request (${advice})`];
}

module.exports = { planDirectPush, directPushWarnings };
