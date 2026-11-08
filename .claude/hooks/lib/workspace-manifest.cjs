/**
 * workspace-manifest.cjs - Loader for adf-workspace.json (membership and repos of a workspace).
 *
 * No cache and no throws: every call reads the file again and reports problems as messages, so a
 * broken manifest can never take a hook down. Messages never contain the offending value.
 *
 * @module workspace-manifest
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const { sameRepo, originUrl } = require('./git-remote-url.cjs');
const { NAME_RE, roleDirsOf, parseJson, validateManifest, isObject } = require('./workspace-manifest-validate.cjs');
const { MANIFEST_FILE } = require('./repo-shape-detector.cjs');
const { realpathLoose, relativePosix, insideRoot } = require('./path-containment.cjs');
const { readTextCapped } = require('./read-text-capped.cjs');

const MAX_MANIFEST_BYTES = 1024 * 1024;

const isFile = (p) => { try { return fs.statSync(p).isFile(); } catch { return false; } };

/**
 * Nearest ancestor of `start` (itself included) that holds adf-workspace.json. Stops before
 * $HOME, the same rule as getProjectRoot, so a stray file in the home directory is never a root.
 * @param {string} [start]
 * @returns {string|null}
 */
function findWorkspaceRoot(start = process.cwd()) {
  const home = path.resolve(os.homedir());
  let current = path.resolve(start);
  while (current !== home) {
    if (isFile(path.join(current, MANIFEST_FILE))) return current;
    const parent = path.dirname(current);
    if (parent === current) break;
    current = parent;
  }
  return null;
}

/**
 * @param {string} root Workspace root
 * @returns {{ manifest: object|null, errors: string[], warnings: string[] }} manifest is null when the file is absent or invalid
 */
function loadManifest(root) {
  const file = path.join(root, MANIFEST_FILE);
  let text;
  try {
    if (fs.statSync(file).size > MAX_MANIFEST_BYTES) return { manifest: null, errors: [`${MANIFEST_FILE} is larger than 1 MB`], warnings: [] };
    text = fs.readFileSync(file, 'utf8');
  } catch (err) {
    if (err && err.code === 'ENOENT') return { manifest: null, errors: [], warnings: [] };
    return { manifest: null, errors: [`${MANIFEST_FILE} cannot be read (${err && err.code ? err.code : 'error'})`], warnings: [] };
  }
  const { value: parsed, error } = parseJson(text, MANIFEST_FILE);
  if (error) return { manifest: null, errors: [error], warnings: [] };
  const { errors, warnings } = validateManifest(parsed);
  return { manifest: errors.length === 0 ? parsed : null, errors, warnings };
}

/** Absolute path of a member directory (not resolved through symlinks). */
function memberPath(root, member) {
  return path.join(root, ...String(member.path).split('/'));
}

/**
 * The member that contains `abs` (longest path match), or null. Both sides are realpath'd, so
 * macOS /private/var and Windows backslashes match.
 * @param {string} root
 * @param {{ members: { path: string }[] }} manifest
 * @param {string} abs
 */
function memberForPath(root, manifest, abs) {
  if (!manifest || !Array.isArray(manifest.members) || typeof abs !== 'string') return null;
  const rel = relativePosix(realpathLoose(path.resolve(root)), realpathLoose(path.resolve(abs)));
  if (!insideRoot(rel)) return null;
  let best = null;
  for (const m of manifest.members) {
    if (typeof m.path !== 'string') continue;
    if ((rel === m.path || rel.startsWith(`${m.path}/`)) && (!best || m.path.length > best.path.length)) best = m;
  }
  return best;
}

const bare = (s) => s.replace(/\/+$/, '').replace(/\.git$/, '');

const ORIGIN_TIMEOUT_MS = 5000;

/**
 * @param {string} root
 * @param {{ path: string, repo?: string }} member
 * @param {{ git?: boolean }} [opts] `git: false` checks the file system only (no process is spawned,
 *   the remote is not compared): the answer is never 'remote-mismatch'
 * @returns {'cloned'|'missing'|'not-a-repo'|'remote-mismatch'|'symlink'}
 */
function memberState(root, member, { git = true } = {}) {
  const dir = memberPath(root, member);
  let stat;
  try { stat = fs.lstatSync(dir); } catch { return 'missing'; }
  if (stat.isSymbolicLink()) return 'symlink';
  let real;
  try { real = fs.realpathSync(dir); } catch { return 'missing'; }
  if (!insideRoot(relativePosix(realpathLoose(path.resolve(root)), real))) return 'symlink';
  if (!stat.isDirectory() || !fs.existsSync(path.join(dir, '.git'))) return 'not-a-repo';
  if (!git || !member.repo) return 'cloned';
  const origin = originUrl(dir, { timeoutMs: ORIGIN_TIMEOUT_MS });
  if (!origin) return 'remote-mismatch';
  const same = sameRepo(origin, member.repo) || bare(origin) === bare(String(member.repo));
  return same ? 'cloned' : 'remote-mismatch';
}

const GIT_TIMEOUT_MS = 1000;

/** The manifest, or, when it fails validation, its raw member list: a broken manifest must not hand a member the workspace's rules. */
function loadMembersLoose(root) {
  const { manifest } = loadManifest(root);
  if (manifest) return manifest;
  try {
    const text = readTextCapped(path.join(root, MANIFEST_FILE), MAX_MANIFEST_BYTES);
    if (text === null) return null;
    const raw = JSON.parse(text);
    const members = Array.isArray(raw && raw.members) ? raw.members.filter((m) => m && typeof m.path === 'string' && !m.path.split('/').includes('..')) : null;
    return members ? { ...raw, members } : null;
  } catch { return null; }
}

/** The directory holding the nearest `.git` at or above `start`, and its `gitdir:` target when `.git` is a file (a linked worktree or submodule). */
function nearestGit(start) {
  let current = path.resolve(start);
  for (;;) {
    const dotGit = path.join(current, '.git');
    try {
      const stat = fs.statSync(dotGit);
      if (!stat.isFile()) return { dir: current, gitdir: null };
      const pointer = /^gitdir:\s*(.+?)\s*$/m.exec(fs.readFileSync(dotGit, 'utf8').slice(0, 2048));
      return { dir: current, gitdir: pointer ? path.resolve(current, pointer[1]) : '' };
    } catch (err) {
      if (err && err.code !== 'ENOENT' && err.code !== 'ENOTDIR') return null;
    }
    const parent = path.dirname(current);
    if (parent === current) return null;
    current = parent;
  }
}

/** Main checkout of the repo a linked worktree at `dir` belongs to: one git spawn, 1 s timeout. */
function mainCheckoutBySpawn(dir) {
  try {
    const out = execFileSync('git', ['-C', dir, 'rev-parse', '--git-common-dir'], { encoding: 'utf8', timeout: GIT_TIMEOUT_MS, stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    const common = path.resolve(dir, out);
    return path.basename(common) === '.git' ? path.dirname(common) : null;
  } catch { return null; }
}

/**
 * Main checkout of a linked worktree, read from its `.git` file (`gitdir: <main>/.git/worktrees/<name>`)
 * without a spawn. A submodule's gitdir (`.../.git/modules/...`) is not a worktree: null. Only a gitdir
 * that is a worktree but not under `<main>/.git` (a separate git dir) falls back to asking git.
 */
function mainCheckoutOf({ dir, gitdir }) {
  if (!gitdir) return null;
  const posix = gitdir.split(path.sep).join('/');
  if (!posix.includes('/worktrees/')) return null;
  const at = posix.lastIndexOf('/.git/worktrees/');
  return at > 0 ? path.normalize(posix.slice(0, at)) : mainCheckoutBySpawn(dir);
}

function lookup(dir) {
  const workspaceRoot = findWorkspaceRoot(dir);
  if (!workspaceRoot) return null;
  const manifest = loadMembersLoose(workspaceRoot);
  const member = manifest && memberForPath(workspaceRoot, manifest, dir);
  return member ? { workspaceRoot, manifest, member, dir: memberPath(workspaceRoot, member) } : null;
}

/**
 * The workspace member whose tree contains `dir`, found by walking up to adf-workspace.json
 * (independent of $CLAUDE_PROJECT_DIR and of .claude/ dirs). A linked worktree of a member that
 * lives elsewhere (worktrees/ or outside the workspace) is traced to its main checkout.
 * Fail-open: any error is a miss.
 * @param {string} [dir]
 * @returns {{ workspaceRoot: string, manifest: object, member: object, dir: string, worktreeRoot?: string }|null}
 */
function memberForDir(dir = process.cwd()) {
  try {
    const direct = lookup(dir);
    if (direct) return direct;
    const git = nearestGit(dir);
    const main = git && mainCheckoutOf(git);
    const found = main && lookup(main);
    return found ? { ...found, worktreeRoot: git.dir } : null;
  } catch { return null; }
}

/** The parsed .claude/config/adf-config.json of the first of `dirs` that has one, else {}. */
function readMemberConfig(...dirs) {
  for (const dir of dirs) {
    try {
      const parsed = JSON.parse(fs.readFileSync(path.join(dir, '.claude', 'config', 'adf-config.json'), 'utf8'));
      return isObject(parsed) ? parsed : {};
    } catch { /* absent or unreadable: try the next */ }
  }
  return {};
}

/** The branch refs/remotes/origin/HEAD names in a clone, read from the file (no spawn), or null. */
function originHeadBranch(memberDir) {
  try {
    const m = /^ref: refs\/remotes\/origin\/(\S+)\s*$/m.exec(fs.readFileSync(path.join(memberDir, '.git', 'refs', 'remotes', 'origin', 'HEAD'), 'utf8'));
    return m ? m[1] : null;
  } catch { return null; }
}

/**
 * Where the git rules for work in `cwd` come from when `cwd` is inside a workspace member
 * (decision D4): the member's own .claude/config/adf-config.json `git`/`commitGuard`, else the
 * manifest's members[].git, else { flow: off, enforcement: ask, mainBranch: manifest branch ||
 * origin/HEAD || main }, so bulk adds still ask and the real trunk stays protected. Never the
 * workspace's own `git` section. Returns null outside members (callers keep their own behavior).
 * @param {string} [cwd]
 * @returns {{ root: string, git: object, commitGuard: object, source: 'member config'|'manifest'|'default', member: string, workspaceRoot: string }|null}
 */
function resolveMemberGitSource(cwd = process.cwd()) {
  try {
    const found = memberForDir(cwd);
    if (!found) return null;
    // A linked worktree reads its own checkout first (a branch may change the config), then the main checkout
    const config = readMemberConfig(...(found.worktreeRoot ? [found.worktreeRoot, found.dir] : [found.dir]));
    const commitGuard = isObject(config.commitGuard) ? config.commitGuard : {};
    const base = { root: found.worktreeRoot || found.dir, commitGuard, member: found.member.name, workspaceRoot: found.workspaceRoot };
    if (isObject(config.git)) return { ...base, git: config.git, source: 'member config' };
    if (isObject(found.member.git)) return { ...base, git: found.member.git, source: 'manifest' };
    const mainBranch = found.member.branch || originHeadBranch(found.dir) || 'main';
    return { ...base, git: { flow: 'off', enforcement: 'ask', mainBranch }, source: 'default' };
  } catch { return null; }
}

/** Whether a member is a real git clone on disk, even if its origin no longer matches the manifest. */
function isCloned(root, member) {
  const state = memberState(root, member);
  return state === 'cloned' || state === 'remote-mismatch';
}

module.exports = {
  MANIFEST_FILE,
  NAME_RE,
  roleDirsOf,
  findWorkspaceRoot,
  loadManifest,
  validateManifest,
  memberForPath,
  memberForDir,
  resolveMemberGitSource,
  memberState,
  isCloned,
  memberPath,
};
