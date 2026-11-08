#!/usr/bin/env node
'use strict';
/**
 * Resolve the absolute path of an ADF hook script for skills that must call a
 * hook by file path: <project root>/.claude/hooks/<hook>, where the project root is
 * $CLAUDE_PROJECT_DIR, else the nearest ancestor of cwd that has `.claude/hooks`, else the
 * git top level.
 *
 * Usage: node resolve-adf-hook-path.cjs <hook-name.cjs>
 * Prints the absolute path on stdout. Exit 1 + stderr message when the name is
 * invalid or the hook does not exist in the project.
 * Only ever resolves inside a `.claude/hooks` directory; the name must match
 * ^[\w.-]+\.cjs$, so no path separators or traversal are possible.
 */
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const HOOK_NAME_RE = /^[\w.-]+\.cjs$/;

const hasHooksDir = (dir) => {
  try { return fs.statSync(path.join(dir, '.claude', 'hooks')).isDirectory(); } catch (_) { return false; }
};

const isInside = (dir, root) => dir === root || dir.startsWith(root + path.sep);

function realOrSelf(p) {
  try { return fs.realpathSync(p); } catch (_) { return path.resolve(p); }
}

/**
 * Project root, in order:
 *   1. $CLAUDE_PROJECT_DIR, only if it is absolute, has `.claude/hooks`, and cwd is inside it;
 *   2. the nearest ancestor of cwd with `.claude/hooks`, never reaching $HOME (an old global
 *      install keeps hooks in ~/.claude/hooks, which is not a project);
 *   3. the git top level, else cwd.
 */
function projectRoot(cwd, env, home) {
  const here = realOrSelf(cwd);
  const envDir = env.CLAUDE_PROJECT_DIR;
  if (envDir && path.isAbsolute(envDir) && hasHooksDir(envDir) && isInside(here, realOrSelf(envDir))) return envDir;
  const homeReal = home ? realOrSelf(home) : null;
  for (let dir = here; ; dir = path.dirname(dir)) {
    if (homeReal && dir === homeReal) break;
    if (hasHooksDir(dir)) return dir;
    if (path.dirname(dir) === dir) break;
  }
  try {
    const top = execFileSync('git', ['rev-parse', '--show-toplevel'], {
      cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
    return top && !(homeReal && realOrSelf(top) === homeReal) ? top : cwd;
  } catch (_) {
    return cwd;
  }
}

/** Returns the absolute hook path, or throws an Error with a user-facing message. */
function resolveHookPath(hook, { cwd = process.cwd(), env = process.env, home = os.homedir() } = {}) {
  if (typeof hook !== 'string' || !HOOK_NAME_RE.test(hook) || hook.includes('..')) {
    throw new Error(`invalid hook name "${hook}" (expected ${HOOK_NAME_RE})`);
  }
  const candidate = path.join(projectRoot(cwd, env, home), '.claude', 'hooks', hook);
  try {
    if (fs.statSync(candidate).isFile()) return candidate;
  } catch (_) { /* fall through to the error below */ }
  throw new Error(`hook "${hook}" not found at ${candidate}`);
}

if (require.main === module) {
  try {
    process.stdout.write(resolveHookPath(process.argv[2]) + '\n');
  } catch (err) {
    process.stderr.write(`resolve-adf-hook-path: ${err.message}\n`);
    process.exit(1);
  }
}

module.exports = { resolveHookPath, HOOK_NAME_RE };
