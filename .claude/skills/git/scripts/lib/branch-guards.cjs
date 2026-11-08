'use strict';

// The flow rules for a pull request (check-pr) and for a direct push to the main branch (check-push).
// Both return {ok, problems}; callers decide whether a problem asks, denies or fails CI.

const { gitTry, refExists, showFile } = require('./git-exec.cjs');
const { resolveReleaseVersion, versionOfReleaseBranch, tagFor, listTags, openReleases } = require('./release-version.cjs');
const { readVersions, checkVersions } = require('./version-files.cjs');
const { branchKind, matchesAny } = require('../../../../hooks/lib/git-flow-config.cjs');
const { sectionPattern } = require('./changelog-section.cjs');

const ZERO = /^0+$/;

/** The ref to inspect for a branch name: the remote-tracking one when it exists, else the local one. */
function refOf(name, cwd, remote) {
  if (remote && refExists(`refs/remotes/${remote}/${name}`, cwd)) return `refs/remotes/${remote}/${name}`;
  return refExists(`refs/heads/${name}`, cwd) ? `refs/heads/${name}` : null;
}

/** The merge strategy the flow expects for head -> base, or null when the flow does not say. */
function expectedStrategy(config, base, head) {
  const headKind = branchKind(config, head);
  const baseKind = branchKind(config, base);
  if (config.flow === 'release-train') {
    if (baseKind === 'release' && headKind !== 'main') return config.merge.featureToRelease;
    if (baseKind === 'main' && headKind === 'release') return config.merge.releaseToMain;
    if (baseKind === 'main' && headKind === 'hotfix') return config.merge.hotfixToMain;
  }
  if (config.flow === 'trunk' && baseKind === 'main') return headKind === 'release' ? config.merge.releaseToMain : headKind === 'hotfix' ? config.merge.hotfixToMain : config.merge.featureToMain;
  return null;
}

/** Problems with the committed version of a release or hotfix head, or [] for other heads. */
function versionProblems(config, head, headRef, cwd, tags) {
  const version = resolveReleaseVersion(config, head, { tags });
  if (!version) return { version: null, problems: [] };
  const problems = [];
  if (tags.includes(tagFor(config, version))) problems.push(`${tagFor(config, version)} already exists; ${head} would release a version that is out`);
  if (headRef) problems.push(...checkVersions(readVersions(config.versionFiles, (p) => showFile(headRef, p, cwd)), version).map((p) => `${p} on ${head} (run bump-version --branch)`));
  // A release ships its changelog section; the GitHub release notes are read from it
  const changelog = headRef && head.startsWith(config.branches.release) ? showFile(headRef, 'CHANGELOG.md', cwd) : null;
  if (changelog !== null && !sectionPattern(version).test(changelog)) problems.push(`CHANGELOG.md on ${head} has no section for ${version}; run git-flow.cjs changelog --write and commit it`);
  return { version, problems };
}

/** tags and branches may be passed in (the hooks use the local view and skip the network). */
function checkPr(config, { base, head, cwd, remote, tags = listTags(cwd, remote), branches }) {
  const problems = [];
  const strategy = expectedStrategy(config, base, head);
  if (!config.enabled) return { ok: true, problems, version: null, strategy };
  const baseKind = branchKind(config, base);
  const headKind = branchKind(config, head);

  if (config.flow === 'release-train') {
    if (baseKind === 'main' && headKind !== 'release' && headKind !== 'hotfix') {
      const { open } = openReleases(config, { cwd, remote, tags, ...(branches ? { branches } : {}) });
      problems.push(`only ${config.branches.release}x.y.z and ${config.branches.hotfix}* merge into ${config.mainBranch}; open this PR into ${open[0] || 'the active release (cut one with cut-release)'}`);
    }
    if (baseKind === 'release' && (headKind === 'release' || headKind === 'hotfix')) problems.push(`${head} merges into ${config.mainBranch}, not into ${base}`);
    if (baseKind === 'release' && !versionOfReleaseBranch(config, base)) problems.push(`${base} is not a release branch name; use ${config.branches.release}x.y.z`);
  }
  if (baseKind === 'main' && headKind === 'release') {
    if (!versionOfReleaseBranch(config, head)) problems.push(`${head} is not a release branch name; use ${config.branches.release}x.y.z`);
    const headRef = refOf(head, cwd, remote);
    const baseRef = refOf(base, cwd, remote);
    if (headRef && baseRef && gitTry(['merge-base', '--is-ancestor', baseRef, headRef], { cwd }).status !== 0) {
      problems.push(`${head} is behind ${base}; merge ${base} into it first (back-merge)`);
    }
  }
  let version = null;
  if (baseKind === 'main' && (headKind === 'release' || headKind === 'hotfix')) {
    try {
      const v = versionProblems(config, head, refOf(head, cwd, remote), cwd, tags);
      version = v.version;
      problems.push(...v.problems);
    } catch (err) {
      problems.push(err.message);
    }
  }
  return { ok: problems.length === 0, problems, version, strategy };
}

/** Commits and files of a push range; a zero start means everything not yet on the remote. */
function readRange(cwd, from, to, remote) {
  const revs = !from || ZERO.test(from) ? [to, '--not', `--remotes=${remote || '*'}`] : [`${from}..${to}`];
  const log = gitTry(['log', '--no-merges', '--format=%h%x1f%s', ...revs], { cwd });
  const files = gitTry(['log', '--no-merges', '--name-only', '--format=', ...revs], { cwd });
  if (log.status !== 0 || files.status !== 0) throw new Error(`cannot read ${from}..${to}; fetch first`);
  return {
    commits: log.stdout.split('\n').filter(Boolean).map((l) => { const [sha, subject] = l.split('\x1f'); return { sha, subject }; }),
    files: [...new Set(files.stdout.split('\n').filter(Boolean))].sort(),
  };
}

/** A direct push to the main branch may only carry allowed commit types touching allow-listed paths. */
function checkPush(config, { from, to, cwd, remote }) {
  if (!config.enabled) return { ok: true, problems: [] };
  const { commits, files } = readRange(cwd, from, to, remote);
  const problems = [];
  for (const f of files) if (!matchesAny(f, config.directPush.paths)) problems.push(`${f} is not in git.directPush.paths; change it through a PR`);
  for (const c of commits) {
    const type = (/^(\w+)(?:\([^)]*\))?!?:/.exec(c.subject) || [])[1];
    if (!config.directPush.types.includes(type)) problems.push(`${c.sha} "${c.subject}" is not a ${config.directPush.types.join('/')} commit; only those push straight to ${config.mainBranch}`);
  }
  return { ok: problems.length === 0, problems, commits: commits.length, files };
}

module.exports = { refOf, expectedStrategy, checkPr, checkPush, readRange };
