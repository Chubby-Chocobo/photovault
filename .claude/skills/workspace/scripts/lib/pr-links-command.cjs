/**
 * pr-links-command.cjs - `workspace pr-links --branch <b> [--write]`: the open pull requests that
 * carry one feature branch across the members of a workspace, cross-linked in their bodies.
 *
 * Per repo, `gh pr list --head <b>` is queried. A hit counts only when it is not from a fork and
 * its head repository is the repo's own origin, so a stranger's fork PR with the same branch name
 * is never edited. `--write` refuses when a repo has more than one such PR; otherwise each PR
 * body gets a managed block listing all of them (URLs and repo names only). Re-running changes
 * nothing, and text outside the block is untouched. gh is called with argument arrays; bodies go
 * in on stdin.
 *
 * @module pr-links-command
 */

'use strict';

const { spawnSync } = require('child_process');
const { sameRepo } = require('../../../../hooks/lib/git-remote-url.cjs');
const { isRefName } = require('../../../../hooks/lib/workspace-manifest-validate.cjs');
const { loadManifest, memberPath, isCloned } = require('../../../../hooks/lib/workspace-manifest.cjs');
const { withBlock, readBlock } = require('../../../../hooks/lib/managed-text-block.cjs');
const { planDirInside, scopePaths, membersForPaths } = require('../../../../hooks/lib/scope-members.cjs');
const { git, originOf, redact } = require('./workspace-git.cjs');
const { list, fail, usageError } = require('./workspace-util.cjs');

const MARKERS = { begin: '<!-- adf:related-prs begin -->', end: '<!-- adf:related-prs end -->' };
const GH_TIMEOUT_MS = 60000;
const FIELDS = 'url,number,headRepository,headRepositoryOwner,isCrossRepository';

/** gh without a shell. `missing` is true when the gh binary is not installed. */
function gh(args, { cwd, input } = {}) {
  const r = spawnSync('gh', args, { cwd, input, encoding: 'utf8', timeout: GH_TIMEOUT_MS, stdio: ['pipe', 'pipe', 'pipe'], env: { ...process.env, GH_PROMPT_DISABLED: '1' } });
  return { missing: Boolean(r.error && r.error.code === 'ENOENT'), ok: !r.error && r.status === 0, stdout: String(r.stdout || ''), stderr: redact(r.error ? r.error.message : r.stderr) };
}

/** `https://host/owner/repo` from a pull request URL, or null. */
const repoUrlOf = (prUrl) => (/^(https?:\/\/[^/]+\/[^/]+\/[^/]+)\/pull\/\d+\/?$/.exec(String(prUrl)) || [])[1] || null;

/**
 * The PRs of `dir` for `branch` that belong to the repo itself: not from a fork, head repo = origin.
 * @returns {{ prs: { url: string, number: number, repo: string }[], error?: string, missing?: boolean }}
 */
function samePrs(dir, branch) {
  const r = gh(['pr', 'list', '--head', branch, '--state', 'open', '--json', FIELDS], { cwd: dir });
  if (r.missing) return { prs: [], missing: true };
  if (!r.ok) return { prs: [], error: r.stderr.split('\n')[0] || 'gh pr list failed' };
  let found;
  try { found = JSON.parse(r.stdout); } catch { return { prs: [], error: 'gh printed no JSON' }; }
  const origin = originOf(dir);
  const prs = [];
  for (const pr of Array.isArray(found) ? found : []) {
    const repoUrl = repoUrlOf(pr.url);
    if (!repoUrl || pr.isCrossRepository !== false || !origin || !sameRepo(origin, repoUrl)) continue;
    const [owner, name] = repoUrl.split('/').slice(-2);
    const headOwner = pr.headRepositoryOwner && pr.headRepositoryOwner.login;
    const headName = pr.headRepository && pr.headRepository.name;
    if ((headOwner && headOwner.toLowerCase() !== owner.toLowerCase()) || (headName && headName.toLowerCase() !== name.toLowerCase())) continue;
    prs.push({ url: pr.url, number: pr.number, repo: name });
  }
  return { prs };
}

const hasLocalBranch = (dir, branch) => git(['-C', dir, 'show-ref', '--verify', '--quiet', `refs/heads/${branch}`], { timeout: 5000 }).status === 0;

/** The block text: a heading and one line per PR. */
const blockLines = (all) => ['**Related pull requests**', ...all.map((p) => `- ${p.repo}: ${p.url}`)];

/**
 * @param {{ root: string, docsRel: string, opts: object }} ctx
 * @returns {{ code: number, result: object, text: string }}
 */
function run({ root, docsRel, opts }) {
  const branch = opts.branch;
  if (typeof branch !== 'string' || !isRefName(branch)) return usageError('--branch <name> is required and must be a branch name');
  if (opts.plan !== undefined && opts.paths !== undefined) return usageError('use --plan or --paths, not both');
  const { manifest, errors } = loadManifest(root);
  if (errors.length > 0) return fail(errors.map((e) => `${e}; run workspace.cjs check`));
  if (!manifest) return fail('no adf-workspace.json here: pr-links works in a workspace');

  // Repos to ask: the scope given, else every repo that has the branch locally
  const explicit = opts.plan !== undefined || opts.paths !== undefined;
  let members = manifest.members;
  if (explicit) {
    const planDir = opts.plan !== undefined ? planDirInside(root, opts.plan) : null;
    if (opts.plan !== undefined && !planDir) return fail('--plan must be a folder inside the workspace that holds plan.md');
    members = membersForPaths(root, manifest, scopePaths(root, planDir ? { planDir } : { entries: list(opts.paths) }, { manifest, docsRel }).paths);
  }
  const targets = members.filter((m) => isCloned(root, m)).map((m) => ({ name: m.name, dir: memberPath(root, m) }));
  targets.push({ name: 'workspace', dir: root });
  const asked = targets.filter((t) => explicit || hasLocalBranch(t.dir, branch));

  const all = [];
  const notes = [];
  for (const target of asked) {
    const found = samePrs(target.dir, branch);
    if (found.missing) return fail('gh is not installed or not on PATH; pr-links needs the GitHub CLI (https://cli.github.com)');
    if (found.error) notes.push(`${target.name}: no PR found (${found.error})`);
    else if (found.prs.length === 0) notes.push(`${target.name}: no open PR for ${branch}`);
    for (const pr of found.prs) all.push({ ...pr, member: target.name });
  }

  const result = { ok: true, branch, prs: all, notes, written: [] };
  const lines = all.length > 0 ? [`Related pull requests for ${branch}:`, ...all.map((p) => `- ${p.member} (${p.repo}): ${p.url}`)] : [`No open pull requests for ${branch}.`];
  lines.push(...notes);
  if (opts.write !== true) return { code: 0, result, text: lines.join('\n') };

  const crowded = asked.map((t) => ({ name: t.name, prs: all.filter((p) => p.member === t.name) })).filter((t) => t.prs.length > 1);
  if (crowded.length > 0) {
    const detail = crowded.map((t) => `${t.name}: ${t.prs.map((p) => p.url).join(', ')}`);
    return fail([`nothing written: more than one open PR for ${branch} in a repo; close the extra one first`, ...detail], { branch, prs: all, notes });
  }
  if (all.length < 2) return { code: 0, result, text: [...lines, 'Fewer than two pull requests: nothing to link.'].join('\n') };

  for (const pr of all) {
    const view = gh(['pr', 'view', pr.url, '--json', 'body'], {});
    let body;
    try { body = JSON.parse(view.stdout).body; } catch { body = null; }
    if (!view.ok || typeof body !== 'string') { result.ok = false; result.written.push({ url: pr.url, status: 'failed', error: view.stderr.split('\n')[0] || 'could not read the PR body' }); continue; }
    if (readBlock(body, MARKERS).state === 'malformed') { result.ok = false; result.written.push({ url: pr.url, status: 'failed', error: 'the related-PRs markers in the body are damaged; fix them by hand' }); continue; }
    const next = withBlock(body, MARKERS, blockLines(all));
    if (next === body) { result.written.push({ url: pr.url, status: 'unchanged' }); continue; }
    const edit = gh(['pr', 'edit', pr.url, '--body-file', '-'], { input: next });
    result.written.push(edit.ok ? { url: pr.url, status: 'updated' } : { url: pr.url, status: 'failed', error: edit.stderr.split('\n')[0] || 'gh pr edit failed' });
    if (!edit.ok) result.ok = false;
  }
  lines.push(...result.written.map((w) => `${w.status}: ${w.url}${w.error ? ` (${w.error})` : ''}`));
  return { code: result.ok ? 0 : 1, result, text: lines.join('\n') };
}

module.exports = { run, MARKERS };
