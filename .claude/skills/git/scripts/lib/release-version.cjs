'use strict';

// Which version a branch releases, and which release branches are open. resolveReleaseVersion is the
// single answer used by bump-version, check-pr and the tagger, so the three can never disagree.

const { git, gitTry, showFile } = require('./git-exec.cjs');
const { isVersion, bumpPatch, bumpMinor, newestVersion, compare } = require('./semver.cjs');
const { readVersions, checkVersions } = require('./version-files.cjs');

/** A refusal: an Error marked `refusal` with a machine-readable `code`, which `--json` output prints next to the message. */
function refusal(code, message) {
  return Object.assign(new Error(message), { code, refusal: true });
}

/** Tags of the repo: from the remote when one is given (no fetch needed), else local. */
function listTags(cwd, remote) {
  if (remote) {
    const r = gitTry(['ls-remote', '--tags', '--refs', remote], { cwd, timeout: 20000 });
    if (r.status === 0) return r.stdout.split('\n').filter(Boolean).map((l) => l.split('\trefs/tags/')[1]).filter(Boolean);
  }
  return git(['tag', '--list'], { cwd }).split('\n').filter(Boolean);
}

/** release/* branch names on the remote, or local ones when there is no remote. */
function listReleaseBranches(config, cwd, remote) {
  const prefix = config.branches.release;
  if (remote) {
    const out = git(['ls-remote', '--heads', remote, `${prefix}*`], { cwd, timeout: 20000 });
    return out.split('\n').filter(Boolean).map((l) => l.split('\trefs/heads/')[1]).filter(Boolean);
  }
  return git(['for-each-ref', '--format=%(refname:short)', `refs/heads/${prefix}`], { cwd }).split('\n').filter(Boolean);
}

/** The version a release branch name carries, or null when it is not release/x.y.z. */
function versionOfReleaseBranch(config, branch) {
  if (!branch || !branch.startsWith(config.branches.release)) return null;
  const v = branch.slice(config.branches.release.length);
  return isVersion(v) ? v : null;
}

const tagFor = (config, version) => `${config.tagPrefix}${version}`;

/**
 * Release branches that have no tag yet. A malformed release/* name is reported, not counted.
 * @returns {{open: string[], malformed: string[]}}
 */
function openReleases(config, { cwd, remote, tags = listTags(cwd, remote), branches = listReleaseBranches(config, cwd, remote) } = {}) {
  const tagSet = new Set(tags);
  const open = [];
  const malformed = [];
  for (const b of branches) {
    const v = versionOfReleaseBranch(config, b);
    if (!v) malformed.push(b);
    else if (!tagSet.has(tagFor(config, v))) open.push(b);
  }
  open.sort((a, b) => compare(versionOfReleaseBranch(config, a), versionOfReleaseBranch(config, b)));
  return { open, malformed };
}

/**
 * The version that merging `head` into the main branch releases: x.y.z for release/x.y.z, the newest
 * tag's patch + 1 for hotfix/*, and null for any other branch (it releases nothing).
 * @param {{tags: string[], excludeTag?: string}} ctx excludeTag ignores the tag a merge already got
 */
function resolveReleaseVersion(config, head, { tags, excludeTag } = {}) {
  if (head && head.startsWith(config.branches.release)) {
    const v = versionOfReleaseBranch(config, head);
    if (!v) throw new Error(`${head} is not a release branch name; use ${config.branches.release}x.y.z`);
    return v;
  }
  if (head && head.startsWith(config.branches.hotfix)) {
    const newest = newestVersion(tags.filter((t) => t !== excludeTag), config.tagPrefix);
    if (!newest) throw new Error(`no ${config.tagPrefix}x.y.z tag yet, so a hotfix has nothing to patch; release first`);
    return bumpPatch(newest);
  }
  return null;
}

/** The version in the version files on <remote>/<main> (the newest when they differ), or null. */
function versionOnMain(config, { cwd, remote, files }) {
  const found = mainVersions(config, { cwd, remote, files });
  return found.map((f) => f.version).filter(isVersion).sort(compare).at(-1) || null;
}

function mainVersions(config, { cwd, remote, files }) {
  const ref = `refs/remotes/${remote}/${config.mainBranch}`;
  return readVersions(files, (p) => showFile(ref, `./${p}`, config.root));
}

/**
 * The next release version: `bump` (minor or patch) applied to the newest of the remote tags with
 * the configured prefix and the version in the files on the main branch. The files matter when a
 * release was merged but is not tagged yet, or its branch is gone. 0.1.0 when neither has a version.
 */
function nextVersion(config, { bump, tags, mainVersion }) {
  const base = [newestVersion(tags, config.tagPrefix), mainVersion].filter(Boolean).sort(compare).at(-1);
  if (!base) return '0.1.0';
  return bump === 'minor' ? bumpMinor(base) : bumpPatch(base);
}

/**
 * Whether the release branch already went into the main branch. Two signals, both about the version
 * arriving after the branch was cut, so a main that held the version beforehand never counts:
 * the branch head is an ancestor of main and one of its commits is the cut's own bump commit (a merge
 * commit), or the version files hold the version on main but not at the merge base (a squash merge).
 * A half-cut branch (created, bump not committed) is neither, so cutting it again completes it.
 */
function isShipped(config, { cwd, remote, branch, version, files }) {
  const main = `refs/remotes/${remote}/${config.mainBranch}`;
  const ref = `refs/remotes/${remote}/${branch}`;
  const holds = (at) => checkVersions(readVersions(files, (p) => showFile(at, `./${p}`, config.root)), version).length === 0;
  if (gitTry(['merge-base', '--is-ancestor', ref, main], { cwd }).status === 0) {
    const bump = git(['log', '-1', '--format=%H', `--grep=^chore(release): ${version.replace(/\./g, '\\.')}$`, ref], { cwd });
    return bump !== '' && holds(ref);
  }
  const base = gitTry(['merge-base', ref, main], { cwd });
  return base.status === 0 && holds(main) && !holds(base.stdout);
}

module.exports = { refusal, versionOnMain, nextVersion, isShipped, listTags, listReleaseBranches, versionOfReleaseBranch, tagFor, openReleases, resolveReleaseVersion };
