/**
 * drift-git.cjs - The few local git reads the contract drift report makes.
 *
 * execFileSync with an argument array (no shell), a 1 s timeout per call, no network and no
 * prompt. Output is never echoed into messages, so a failure reveals nothing but "no answer".
 *
 * @module drift-git
 */

'use strict';

const { execFileSync } = require('child_process');
const { ownerOf, originUrl } = require('./git-remote-url.cjs');

const GIT_TIMEOUT_MS = 1000;

/** @returns {string|null} trimmed stdout of `git -C dir <args>`, or null on any failure */
function gitOut(dir, args, { timeoutMs = GIT_TIMEOUT_MS, raw = false } = {}) {
  try {
    const out = execFileSync('git', ['-C', dir, ...args], {
      encoding: 'utf8', timeout: timeoutMs, windowsHide: true, stdio: ['ignore', 'pipe', 'ignore'],
      env: { ...process.env, GIT_TERMINAL_PROMPT: '0' },
    });
    return raw ? out : out.trim();
  } catch { return null; }
}

/** @returns {{ sha: string, date: string }|null} HEAD commit of the clone at `dir` */
function localHead(dir) {
  const out = gitOut(dir, ['log', '-1', '--format=%H%x09%cI']);
  const [sha, date] = out ? out.split('\t') : [];
  return /^[0-9a-f]{40,64}$/i.test(sha || '') ? { sha, date: date || '' } : null;
}

/** @returns {string|null} owner of the origin remote at `dir` */
function originOwnerOf(dir) {
  const url = originUrl(dir, { timeoutMs: GIT_TIMEOUT_MS });
  return url ? ownerOf(url) : null;
}

module.exports = { GIT_TIMEOUT_MS, gitOut, localHead, originOwnerOf };
