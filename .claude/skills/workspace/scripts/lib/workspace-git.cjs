/**
 * workspace-git.cjs - The few git calls the workspace commands make.
 *
 * Every call is spawnSync with an argument array (no shell). Values that become positional
 * arguments are rejected when they start with "-". With no TTY on stdin git never prompts for
 * credentials. Anything git prints is redacted before it can reach a message.
 *
 * @module workspace-git
 */

'use strict';

const { spawnSync } = require('child_process');
const { stripCredentials, originUrl } = require('../../../../hooks/lib/git-remote-url.cjs');

const DEFAULT_TIMEOUT_MS = 10 * 60 * 1000;

/** Hide userinfo in any URL inside a text git printed. */
const redact = (text) => String(text || '').replace(/(:\/\/)[^\s/@]+@/g, '$1***@').trim();

/**
 * @param {string[]} args
 * @param {{ cwd?: string, timeout?: number }} [opts]
 * @returns {{ status: number|null, stdout: string, stderr: string }} stderr is redacted
 */
function git(args, { cwd, timeout = DEFAULT_TIMEOUT_MS } = {}) {
  const env = { ...process.env };
  if (!process.stdin.isTTY) env.GIT_TERMINAL_PROMPT = '0';
  const r = spawnSync('git', args, { cwd, env, encoding: 'utf8', timeout, stdio: ['ignore', 'pipe', 'pipe'] });
  const status = r.error ? null : r.status;
  return { status, stdout: String(r.stdout || '').trim(), stderr: redact(r.error ? r.error.message : r.stderr) };
}

const out = (dir, args) => {
  const r = git(['-C', dir, ...args], { timeout: 5000 });
  return r.status === 0 && r.stdout ? r.stdout : null;
};

/** Raw origin URL (may hold credentials: strip before printing), or null. */
const originOf = (dir) => originUrl(dir, { timeoutMs: 5000 });

/** Checked-out branch, or null when detached or unborn. */
const branchOf = (dir) => out(dir, ['symbolic-ref', '--short', '-q', 'HEAD']);

/** The branch origin/HEAD points to, or null. */
function defaultBranchOf(dir) {
  const ref = out(dir, ['symbolic-ref', '--short', '-q', 'refs/remotes/origin/HEAD']);
  return ref && ref.startsWith('origin/') ? ref.slice('origin/'.length) : null;
}

/** @returns {'ignored'|'not-ignored'|'unknown'} whether the workspace repo ignores `rel` (unknown: not a git repo) */
function ignoreStatus(root, rel) {
  const r = git(['-C', root, 'check-ignore', '-q', '--', rel], { timeout: 5000 });
  if (r.status === 0) return 'ignored';
  return r.status === 1 ? 'not-ignored' : 'unknown';
}

/**
 * The credential-free URL of a remote whose URL carried credentials, else null.
 * @param {string|null} origin
 */
const strippedWhenCredentialed = (origin) => {
  if (!origin) return null;
  const stripped = stripCredentials(origin);
  return stripped !== origin ? stripped : null;
};

/** @returns {{ ok: boolean, error?: string }} */
function setOrigin(dir, url) {
  if (typeof url !== 'string' || !url || url.startsWith('-')) return { ok: false, error: 'unsafe url' };
  const r = git(['-C', dir, 'remote', 'set-url', 'origin', '--', url], { timeout: 5000 });
  return r.status === 0 ? { ok: true } : { ok: false, error: r.stderr || 'git remote set-url failed' };
}

/** The command a user can run to drop credentials from a member's origin. */
const setUrlCommand = (relPath, url) => `git -C ${relPath} remote set-url origin ${url}`;

module.exports = { redact, git, originOf, branchOf, defaultBranchOf, ignoreStatus, strippedWhenCredentialed, setOrigin, setUrlCommand };
