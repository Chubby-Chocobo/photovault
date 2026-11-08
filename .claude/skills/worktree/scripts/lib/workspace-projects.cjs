/**
 * workspace-projects.cjs - Projects a worktree can be created for, and the per-member runs behind
 * `create-scope` / `remove-scope`.
 *
 * Projects are the cloned members of a workspace plus the sibling submodules of a superproject
 * (vendored submodules such as lib/forge-std are not projects). The scope runs spawn the
 * existing `create` / `remove` commands once per member, so worktree.cjs stays unchanged for them.
 *
 * @module workspace-projects
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { detectRepoShape } = require('../../../../hooks/lib/repo-shape-detector.cjs');
const { loadManifest, memberPath, isCloned, MANIFEST_FILE } = require('../../../../hooks/lib/workspace-manifest.cjs');
const { planDirInside, scopePaths, membersForPaths } = require('../../../../hooks/lib/scope-members.cjs');


/**
 * @param {string} gitRoot
 * @returns {{ repoType: 'workspace'|'monorepo'|'standalone', projects: { name: string, path: string, kind: 'member'|'submodule' }[] }}
 */
function listProjects(gitRoot) {
  const manifest = fs.existsSync(path.join(gitRoot, MANIFEST_FILE)) ? loadManifest(gitRoot).manifest : null;
  const orgs = manifest && Array.isArray(manifest.org) ? manifest.org : undefined;
  const projects = [];
  if (manifest) {
    for (const m of manifest.members) {
      if (typeof m.name === 'string' && isCloned(gitRoot, m)) projects.push({ name: m.name, path: m.path, kind: 'member' });
    }
  }
  for (const s of detectRepoShape(gitRoot, { orgs }).submodules) {
    if (s.kind === 'sibling') projects.push({ name: path.basename(s.path), path: s.path, kind: 'submodule' });
  }
  const repoType = manifest || fs.existsSync(path.join(gitRoot, MANIFEST_FILE)) ? 'workspace' : projects.length > 0 ? 'monorepo' : 'standalone';
  return { repoType, projects };
}

/** Branch checked out in the worktree at `worktreePath` of the repo at `repoDir`: its name, '' when detached, null when git lists no such worktree. */
function worktreeBranchAt(repoDir, worktreePath) {
  const r = spawnSync('git', ['-C', repoDir, 'worktree', 'list', '--porcelain'], { encoding: 'utf8', timeout: 10000, stdio: ['ignore', 'pipe', 'ignore'] });
  if (r.error || r.status !== 0) return null;
  const real = (p) => { try { return fs.realpathSync(p); } catch { return path.resolve(p); } };
  const wanted = real(worktreePath);
  for (const block of r.stdout.split(/\r?\n\r?\n/)) {
    const where = /^worktree (.+)$/m.exec(block);
    if (!where || real(where[1]) !== wanted) continue;
    const ref = /^branch refs\/heads\/(.+)$/m.exec(block);
    return ref ? ref[1] : '';
  }
  return null;
}

const runNode = (script, args, cwd) => {
  const r = spawnSync(process.execPath, [script, ...args, '--json'], { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  let json = null;
  try { json = JSON.parse(r.stdout); } catch { /* not JSON: reported through stderr below */ }
  return { ok: r.status === 0 && Boolean(json) && json.success !== false, message: (json && json.error && json.error.message) || String(r.stderr || r.error || '').trim().split('\n')[0] || 'command failed' };
};

/**
 * Run `create` (kind 'create') or `remove` (kind 'remove') for every member in a plan's scope.
 * @param {'create'|'remove'} kind
 * @param {{ gitRoot: string, script: string, plan: string, feature: string, branch: string, worktreeName: string, flags: string[], dryRun: boolean }} o
 * @returns {{ ok: boolean, error?: string, results?: object[] }}
 */
function runScope(kind, { gitRoot, script, plan, feature, branch, worktreeName, flags, dryRun }) {
  const { manifest, errors } = loadManifest(gitRoot);
  if (errors.length > 0) return { ok: false, error: `${errors[0]}; run workspace.cjs check` };
  if (!manifest) return { ok: false, error: `${MANIFEST_FILE} not found: ${kind}-scope runs at the workspace root` };
  const planDir = planDirInside(gitRoot, plan);
  if (!planDir) return { ok: false, error: '--plan must be a folder inside the workspace that holds plan.md' };
  const members = membersForPaths(gitRoot, manifest, scopePaths(gitRoot, { planDir }, { manifest }).paths);
  if (members.length === 0) return { ok: false, error: 'the plan scope names no workspace member' };
  const worktreeRoot = path.join(gitRoot, 'worktrees');
  const results = members.map((m) => {
    const base = { member: m.name, branch };
    const worktreePath = path.join(worktreeRoot, `${m.name}-${worktreeName}`);
    if (!isCloned(gitRoot, m)) return { ...base, status: 'failed', error: `${m.name} is not cloned; run bootstrap first` };
    if (kind === 'create' && fs.existsSync(worktreePath)) {
      // Only a worktree of this member on this branch counts as done
      const found = worktreeBranchAt(memberPath(gitRoot, m), worktreePath);
      if (found === branch) return { ...base, status: 'existing', worktreePath };
      return { ...base, status: 'failed', error: found === null ? `${worktreePath} exists but is not a worktree of ${m.name}` : `${worktreePath} is a worktree on ${found || '(detached HEAD)'}, not ${branch}` };
    }
    const run = kind === 'create'
      ? runNode(script, ['create', m.name, feature, '--worktree-root', worktreeRoot, '--checkout-submodules', ...flags, ...(dryRun ? ['--dry-run'] : [])], gitRoot)
      : runNode(script, ['remove', worktreePath, ...flags, ...(dryRun ? ['--dry-run'] : [])], memberPath(gitRoot, m));
    if (run.ok) return { ...base, status: kind === 'create' ? 'created' : 'removed', worktreePath };
    return { ...base, status: 'failed', error: run.message };
  });
  return { ok: results.every((r) => r.status !== 'failed'), results };
}

module.exports = { listProjects, runScope };
