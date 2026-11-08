/**
 * repos-command.cjs - `workspace repos [--plan <dir> | --paths a,b | --changed]`: where each repo of a
 * workspace stands, so git-manager can commit, push and open one pull request per member.
 *
 * One row per member in scope (every cloned member without a flag) plus the workspace repo itself:
 * branch, staged / unstaged / untracked counts, upstream with ahead and behind, the branch a
 * pull request from the current branch targets (`prBase`), and whether the member has its own
 * .claude/. Read-only. `prBase` is computed in this process through git-flow's pr-target.
 *
 * @module repos-command
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { getGitConfig } = require('../../../../hooks/lib/git-flow-config.cjs');
const { loadManifest, memberPath, isCloned } = require('../../../../hooks/lib/workspace-manifest.cjs');
const { planDirInside, scopePaths, membersForPaths } = require('../../../../hooks/lib/scope-members.cjs');
const { COMMANDS: GIT_FLOW } = require('../../../git/scripts/git-flow.cjs');
const { defaultRemote } = require('../../../git/scripts/lib/git-exec.cjs');
const { branchOf, defaultBranchOf } = require('./workspace-git.cjs');
const { list, fail, usageError } = require('./workspace-util.cjs');

const GIT_TIMEOUT_MS = 15000;

/** Raw stdout of a git call in `dir` (not trimmed: porcelain lines start with a space), or null on failure. */
function gitOut(dir, args) {
  const r = spawnSync('git', ['--no-optional-locks', '-C', dir, ...args], { encoding: 'utf8', timeout: GIT_TIMEOUT_MS, stdio: ['ignore', 'pipe', 'ignore'], env: { ...process.env, GIT_TERMINAL_PROMPT: '0' } });
  return r.error || r.status !== 0 ? null : r.stdout;
}

/** Counts from `git status --porcelain=v1 -z` output: staged, unstaged, untracked entries. */
function countStatus(out) {
  const counts = { staged: 0, unstaged: 0, untracked: 0 };
  const entries = String(out || '').split('\0');
  for (let i = 0; i < entries.length; i += 1) {
    const e = entries[i];
    if (e.length < 3) continue;
    const [x, y] = e;
    if (x === '?') counts.untracked += 1;
    else {
      if (x !== ' ' && x !== '!') counts.staged += 1;
      if (y !== ' ' && y !== '!') counts.unstaged += 1;
    }
    if (x === 'R' || x === 'C' || y === 'R' || y === 'C') i += 1; // the original path follows as its own entry
  }
  return counts;
}

/** Upstream name and ahead / behind counts, or nulls when the branch tracks nothing. */
function upstreamOf(dir) {
  const name = (gitOut(dir, ['rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}']) || '').trim();
  if (!name) return { upstream: null, ahead: null, behind: null };
  const [behind, ahead] = (gitOut(dir, ['rev-list', '--left-right', '--count', '@{u}...HEAD']) || '').trim().split(/\s+/).map(Number);
  return Number.isInteger(ahead) && Number.isInteger(behind) ? { upstream: name, ahead, behind } : { upstream: name, ahead: null, behind: null };
}

/**
 * The branch a pull request from the current branch of `dir` targets: git-flow's answer under an
 * active flow, worked out from local tags and remote-tracking release branches (no network call,
 * so a slow or unreachable remote never blocks the table; run `git fetch` first for fresh data).
 * When the flow is off or git-flow cannot tell (no open release), the manifest branch, else
 * origin/HEAD, else the configured main branch.
 */
function prBaseOf(dir, manifestBranch) {
  const config = getGitConfig(dir);
  if (config.enabled) {
    try {
      const remote = defaultRemote(dir);
      const lines = (args) => (gitOut(dir, args) || '').split('\n').filter(Boolean);
      const { result, text } = GIT_FLOW['pr-target'](config, {
        cwd: dir,
        remote,
        tags: lines(['tag', '--list']),
        branches: remote
          ? lines(['for-each-ref', '--format=%(refname:lstrip=3)', `refs/remotes/${remote}/${config.branches.release}`])
          : lines(['for-each-ref', '--format=%(refname:lstrip=2)', `refs/heads/${config.branches.release}`]),
      }, {});
      return result.target || text;
    } catch { /* fall through to the fallbacks */ }
  }
  return manifestBranch || defaultBranchOf(dir) || config.mainBranch;
}

function rowFor(name, relPath, dir, manifestBranch) {
  const hasOwnAdf = fs.existsSync(path.join(dir, '.claude'));
  return {
    name,
    path: relPath,
    branch: branchOf(dir) || '(detached)',
    ...countStatus(gitOut(dir, ['status', '--porcelain=v1', '-z'])),
    ...upstreamOf(dir),
    prBase: prBaseOf(dir, manifestBranch),
    hasOwnAdf,
  };
}

const changed = (row) => row.staged + row.unstaged + row.untracked > 0;

function renderRow(r) {
  const track = r.upstream ? `${r.upstream} ahead ${r.ahead} behind ${r.behind}` : 'no upstream';
  return `${r.name} (${r.path}): ${r.branch}, staged ${r.staged}, unstaged ${r.unstaged}, untracked ${r.untracked}, ${track}, PR base ${r.prBase}${r.hasOwnAdf ? ', own .claude/' : ''}`;
}

/**
 * @param {{ root: string, docsRel: string, opts: object }} ctx
 * @returns {{ code: number, result: object, text: string }}
 */
function run({ root, docsRel, opts }) {
  const modes = ['plan', 'paths', 'changed'].filter((k) => opts[k] !== undefined);
  if (modes.length > 1) return usageError('use one of --plan, --paths or --changed');
  const { manifest, errors } = loadManifest(root);
  if (errors.length > 0) return fail(errors.map((e) => `${e}; run workspace.cjs check`));
  if (!manifest) return fail('no adf-workspace.json here: repos works in a workspace');

  let source = 'all';
  let members = manifest.members;
  let dropped = 0;
  if (modes[0] === 'plan' || modes[0] === 'paths') {
    const planDir = modes[0] === 'plan' ? planDirInside(root, opts.plan) : null;
    if (modes[0] === 'plan' && !planDir) return fail('--plan must be a folder inside the workspace that holds plan.md');
    const scope = scopePaths(root, planDir ? { planDir } : { entries: list(opts.paths) }, { manifest, docsRel });
    members = membersForPaths(root, manifest, scope.paths);
    dropped = scope.dropped;
    source = modes[0];
  } else if (modes[0] === 'changed') source = 'changed';

  const notCloned = members.filter((m) => !isCloned(root, m)).map((m) => m.name);
  let rows = members.filter((m) => !notCloned.includes(m.name)).map((m) => rowFor(m.name, m.path, memberPath(root, m), m.branch));
  if (source === 'changed') rows = rows.filter(changed);
  rows.push(rowFor('workspace', '.', root, undefined));

  const lines = rows.map(renderRow);
  if (notCloned.length > 0) lines.push(`not cloned: ${notCloned.join(', ')}`);
  if (dropped > 0) lines.push(`${dropped} scope ${dropped === 1 ? 'entry' : 'entries'} ignored`);
  return { code: 0, result: { ok: true, source, repos: rows, notCloned, dropped }, text: lines.join('\n') };
}

module.exports = { run, countStatus };
