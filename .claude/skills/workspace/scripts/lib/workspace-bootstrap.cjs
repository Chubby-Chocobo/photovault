/**
 * workspace-bootstrap.cjs - `workspace bootstrap`: clone the members that are not on disk yet.
 *
 * A member is cloned only when its path is under a role dir, not a symlink, ignored by the
 * workspace repo, and (without --allow-local) a remote URL. A path that already holds a repo is
 * skipped when it has the same remote (either protocol) and reported, never touched, when it has
 * another remote or is not a repo. Git runs with argument arrays and `--` before the URL.
 *
 * @module workspace-bootstrap
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { loadManifest, memberState, memberPath, roleDirsOf } = require('../../../../hooks/lib/workspace-manifest.cjs');
const { parseRemoteUrl, toProtocol } = require('../../../../hooks/lib/git-remote-url.cjs');
const { isRefName } = require('../../../../hooks/lib/workspace-manifest-validate.cjs');
const { git, originOf, ignoreStatus, strippedWhenCredentialed, setOrigin, setUrlCommand } = require('./workspace-git.cjs');
const { list, fail, usageError } = require('./workspace-util.cjs');
const { renderBootstrap } = require('./workspace-bootstrap-report.cjs');

const PROTOCOLS = ['ssh', 'https', 'auto'];
const FAILED = ['refused', 'conflict', 'failed'];

/** 'ssh' or 'https' for `--protocol`; auto takes the scheme of the workspace repo's origin, null when it has none. */
function resolveProtocol(root, flag) {
  if (flag === 'ssh' || flag === 'https') return flag;
  const origin = originOf(root);
  if (!origin || !parseRemoteUrl(origin)) return null;
  if (/^(?:git\+)?https?:\/\//i.test(origin) || /^(?:github|gitlab|bitbucket):/i.test(origin)) return 'https';
  return /^git:\/\//i.test(origin) ? null : 'ssh';
}

const isLocal = (repo) => parseRemoteUrl(repo) === null;
const cloneUrl = (repo, protocol) => (protocol && !isLocal(repo) ? toProtocol(repo, protocol) || repo : repo);

/** The reason a missing member must not be cloned, or null. */
function cloneRefusal(root, manifest, m, { allowLocal }) {
  if (!m.repo) return 'the manifest has no repo for it';
  const [roleDir] = m.path.split('/');
  if (!roleDirsOf(manifest).includes(roleDir)) return 'path is outside roleDirs';
  try {
    if (fs.lstatSync(path.join(root, roleDir)).isSymbolicLink()) return `${roleDir}/ is a symlink`;
  } catch { /* the role dir does not exist yet: git clone creates it */ }
  const ignored = ignoreStatus(root, m.path);
  if (ignored === 'not-ignored') return 'path is not ignored by the workspace repo; run /workspace init first';
  if (ignored === 'unknown') return 'cannot tell whether the path is ignored (not a git repository)';
  if (isLocal(m.repo) && !allowLocal) return 'repo is local; pass --allow-local to clone it';
  if (m.repo.startsWith('-') || (m.branch !== undefined && !isRefName(m.branch))) return 'repo or branch looks like an option';
  return null;
}

function plan(root, manifest, m, opts, protocol) {
  const base = { name: m.name, path: m.path };
  const state = memberState(root, m);
  if (state === 'symlink') return { ...base, status: 'refused', reason: 'path is a symlink or leaves the workspace' };
  if (state === 'not-a-repo') return { ...base, status: 'conflict', reason: 'path exists but is not a git repo; left untouched' };
  if (state === 'remote-mismatch') return { ...base, status: 'conflict', reason: 'origin is another repo than the manifest says; left untouched' };
  if (state === 'cloned') return opts.pull ? { ...base, status: 'would-pull' } : { ...base, status: 'skipped', reason: 'already cloned' };
  const reason = cloneRefusal(root, manifest, m, { allowLocal: Boolean(opts['allow-local']) });
  if (reason) return { ...base, status: 'refused', reason };
  const url = cloneUrl(m.repo, protocol);
  const args = ['clone', ...(m.branch ? ['--branch', m.branch] : []), '--', url, memberPath(root, m)];
  return { ...base, status: 'would-clone', url, args };
}

function execute(root, step) {
  if (step.status === 'would-clone') {
    const r = git(step.args, { cwd: root });
    delete step.args;
    return r.status === 0 ? { ...step, status: 'cloned' } : { ...step, status: 'failed', reason: `git clone failed: ${r.stderr.split('\n').pop() || `exit ${r.status}`}` };
  }
  if (step.status === 'would-pull') {
    const r = git(['-C', memberPath(root, step), 'pull', '--ff-only']);
    return r.status === 0 ? { ...step, status: 'pulled' } : { ...step, status: 'failed', reason: `git pull --ff-only failed: ${r.stderr.split('\n').pop() || `exit ${r.status}`}` };
  }
  return step;
}

/** Credentialed origins of cloned members: the command (and with --fix-remotes, the rewrite) that drops them. */
function remoteFixes(root, members, opts, protocol) {
  const fixes = [];
  for (const m of members) {
    if (memberState(root, m) !== 'cloned') continue;
    const stripped = strippedWhenCredentialed(originOf(memberPath(root, m)));
    if (!stripped) continue;
    const url = (protocol && toProtocol(stripped, protocol)) || stripped;
    const run = Boolean(opts['fix-remotes']) && !opts['dry-run'];
    const done = run ? setOrigin(memberPath(root, m), url) : { ok: false };
    fixes.push({ path: m.path, command: setUrlCommand(m.path, url), applied: done.ok, ...(run && !done.ok ? { error: done.error } : {}) });
  }
  return fixes;
}

/** @param {{ root: string, opts: object }} ctx */
function run({ root, opts }) {
  const flag = typeof opts.protocol === 'string' ? opts.protocol : 'auto';
  if (!PROTOCOLS.includes(flag)) return usageError(`--protocol must be one of ${PROTOCOLS.join('|')}`);
  const { manifest, errors } = loadManifest(root);
  if (errors.length > 0) return fail(errors);
  if (!manifest) return fail(['no adf-workspace.json here; run /workspace init first']);

  const only = list(opts.only);
  const unknown = only.filter((n) => !manifest.members.some((m) => m.name === n));
  if (unknown.length > 0) return fail([`--only names unknown members: ${unknown.join(', ')}`]);
  const selected = manifest.members.filter((m) => only.length === 0 || only.includes(m.name));

  const protocol = resolveProtocol(root, flag);
  const dry = Boolean(opts['dry-run']);
  const steps = selected.map((m) => plan(root, manifest, m, opts, protocol)).map((s) => (dry ? { ...s, args: undefined } : execute(root, s)));
  const fixes = remoteFixes(root, selected, opts, protocol);
  const problems = [...steps.filter((s) => FAILED.includes(s.status)).map((s) => `${s.name}: ${s.reason}`), ...fixes.filter((f) => f.error).map((f) => `${f.command} failed: ${f.error}`)];
  const result = { ok: problems.length === 0, dryRun: dry, protocol: flag === 'auto' ? protocol || 'as-written' : flag, members: steps.map(({ args, ...s }) => s), remoteFixes: fixes, errors: problems };
  return { code: problems.length > 0 ? 1 : 0, result, text: renderBootstrap(result) };
}

module.exports = { run };
