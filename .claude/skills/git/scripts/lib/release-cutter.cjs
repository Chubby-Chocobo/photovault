'use strict';

// cut-release and back-merge: the two commands that create or update a release branch.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { git, gitTry } = require('./git-exec.cjs');
const { isVersion, compare, newestVersion } = require('./semver.cjs');
const { refusal, versionOnMain, nextVersion, isShipped, listTags, openReleases, tagFor, versionOfReleaseBranch } = require('./release-version.cjs');
const { effectiveVersionFiles, writeVersions, writeVersionToText } = require('./version-files.cjs');
const { lastReleaseTag, readCommits, formatSection, writeChangelog } = require('./changelog-section.cjs');

const BUMPS = ['minor', 'patch'];

/**
 * Creates release/<version> from the remote main branch (server side) and commits the version bump,
 * plus the changelog section when there are changes, in a throwaway worktree. Running it again on an
 * existing branch only adds what is missing, unless that branch already shipped. `next` ("minor" or
 * "patch") picks the version instead of `version`. Refusals carry a `code`.
 */
function cutRelease(config, { version, next, cwd, remote, dryRun = false }) {
  if (version !== undefined && next) throw refusal('invalid_args', 'give a version or --next, not both');
  if (next && !BUMPS.includes(next)) throw refusal('invalid_args', `--next takes ${BUMPS.join(' or ')}, not "${next}"`);
  if (!next && !isVersion(version)) throw refusal('invalid_version', `"${version}" is not x.y.z`);
  if (!remote) throw refusal('no_remote', 'no git remote; cut-release creates the branch on the remote');
  const files = effectiveVersionFiles(config, config.root);
  git(['fetch', '--quiet', '--tags', remote, `+refs/heads/${config.mainBranch}:refs/remotes/${remote}/${config.mainBranch}`], { cwd, timeout: 60000 });
  const tags = listTags(cwd, remote);
  let open;
  if (next) {
    ({ open } = openReleases(config, { cwd, remote, tags }));
    if (open.length > 0) throw refusal('release_open', `${open.join(', ')} is still open; release it first (one release at a time)`);
    version = nextVersion(config, { bump: next, tags, mainVersion: versionOnMain(config, { cwd, remote, files }) });
  }
  const branch = `${config.branches.release}${version}`;
  const tag = tagFor(config, version);
  if (tags.includes(tag)) throw refusal('tag_exists', `${tag} already exists`);
  const newest = newestVersion(tags, config.tagPrefix);
  if (newest && compare(version, newest) <= 0) throw refusal('not_newer', `${version} is not newer than the latest release ${newest}`);
  if (!open) ({ open } = openReleases(config, { cwd, remote, tags }));
  const others = open.filter((b) => b !== branch);
  if (others.length > 0) throw refusal('release_open', `${others.join(', ')} is still open; release it first (one release at a time)`);
  const exists = open.includes(branch);
  if (exists) {
    git(['fetch', '--quiet', remote, `refs/heads/${branch}:refs/remotes/${remote}/${branch}`], { cwd, timeout: 60000 });
    if (isShipped(config, { cwd, remote, branch, version, files })) throw refusal('already_shipped', `${branch} already went into ${config.mainBranch}; it only needs its tag, so check the tagger`);
  }
  const steps = [exists ? `${branch} exists on ${remote}; checking its version commit` : `create ${branch} from ${remote}/${config.mainBranch}`, `set ${files.map((f) => f.path).join(', ')} to ${version}`];
  if (dryRun) return { version, branch, created: false, committed: false, steps };

  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'adf-cut-release-')); // before the push: a local failure must not leave a half-cut release
  try {
    if (!exists) {
      git(['push', '--quiet', remote, `refs/remotes/${remote}/${config.mainBranch}:refs/heads/${branch}`], { cwd, timeout: 60000 });
      git(['fetch', '--quiet', remote, `refs/heads/${branch}:refs/remotes/${remote}/${branch}`], { cwd, timeout: 60000 });
    }
    git(['worktree', 'add', '--quiet', '--detach', dir, `refs/remotes/${remote}/${branch}`], { cwd });
    const touched = writeVersions(files, dir, version);
    const commits = readCommits(dir, lastReleaseTag(config, dir));
    if (config.flow === 'trunk' || commits.some((c) => ['feat', 'fix', 'perf', 'revert'].includes(c.type) || c.breaking)) {
      if (writeChangelog(dir, version, formatSection(version, commits))) touched.push('CHANGELOG.md');
    }
    if (touched.length === 0) return { version, branch, created: !exists, committed: false, steps };
    git(['add', '--', ...touched], { cwd: dir });
    git(['commit', '--quiet', '-m', `chore(release): ${version}`], { cwd: dir });
    git(['push', '--quiet', remote, `HEAD:refs/heads/${branch}`], { cwd: dir, timeout: 60000 });
    return { version, branch, created: !exists, committed: true, touched, steps };
  } finally {
    gitTry(['worktree', 'remove', '--force', dir], { cwd });
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

/** Three-way merge of the index stages of `rel`, each passed through `normalize` first. */
function mergeStages(top, rel, { union = false, normalize = (t) => t } = {}) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'adf-back-merge-'));
  try {
    const files = [2, 1, 3].map((n) => {
      const r = gitTry(['show', `:${n}:${rel}`], { cwd: top });
      const file = path.join(tmp, String(n));
      fs.writeFileSync(file, normalize(r.status === 0 ? `${r.stdout}\n` : ''));
      return file;
    });
    const r = gitTry(['merge-file', '-p', ...(union ? ['--union'] : []), '-L', 'release', '-L', 'base', '-L', 'main', ...files], { cwd: top });
    if (r.status < 0 || r.status === null || r.status > 127) throw new Error(`git merge-file failed on ${rel}: ${r.stderr}`);
    return { text: `${r.stdout}\n`, clean: r.status === 0 };
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

/**
 * Merges the remote main branch into the checked-out active release after a hotfix. Version files merge
 * like any file, except that their version is the release's on every side, so a hotfix's other changes
 * to them (a dependency, say) are kept. CHANGELOG.md keeps both sides. Any other conflict stops the
 * merge with the list. Nothing is pushed.
 */
function backMerge(config, { cwd, remote }) {
  const current = git(['symbolic-ref', '--quiet', '--short', 'HEAD'], { cwd });
  const top = git(['rev-parse', '--show-toplevel'], { cwd });
  const { open } = openReleases(config, { cwd, remote });
  if (open.length === 0) throw new Error('no open release to back-merge into');
  if (current !== open[0]) throw new Error(`switch to ${open[0]} first (now on ${current})`);
  const version = versionOfReleaseBranch(config, current);
  if (git(['status', '--porcelain', '--untracked-files=no'], { cwd: top })) throw new Error('commit or stash your changes first');
  if (remote) git(['fetch', '--quiet', remote, config.mainBranch], { cwd: top, timeout: 60000 });
  const source = remote ? `${remote}/${config.mainBranch}` : config.mainBranch;
  if (gitTry(['merge-base', '--is-ancestor', source, 'HEAD'], { cwd: top }).status === 0) return { merged: false, source, conflicts: [] };

  const unmerged = () => git(['diff', '--name-only', '--diff-filter=U'], { cwd: top }).split('\n').filter(Boolean);
  const merge = gitTry(['merge', '--no-ff', '--no-commit', source], { cwd: top });
  if (merge.status !== 0 && unmerged().length === 0) throw new Error(`git merge ${source} failed: ${merge.stderr || merge.stdout}`);

  for (const entry of config.versionFiles) {
    const file = path.join(top, entry.path);
    const setVersion = (text) => { try { return writeVersionToText(entry, text, version); } catch { return text; } };
    if (unmerged().includes(entry.path)) {
      const r = mergeStages(top, entry.path, { normalize: setVersion });
      fs.writeFileSync(file, r.text);
      if (r.clean) git(['add', '--', entry.path], { cwd: top });
    } else if (fs.existsSync(file)) {
      const text = fs.readFileSync(file, 'utf8');
      const next = setVersion(text);
      if (next !== text) { fs.writeFileSync(file, next); git(['add', '--', entry.path], { cwd: top }); }
    }
  }
  if (unmerged().includes('CHANGELOG.md')) {
    fs.writeFileSync(path.join(top, 'CHANGELOG.md'), mergeStages(top, 'CHANGELOG.md', { union: true }).text);
    git(['add', '--', 'CHANGELOG.md'], { cwd: top });
  }
  const conflicts = unmerged();
  if (conflicts.length > 0) return { merged: false, source, conflicts };
  git(['commit', '--quiet', '--no-edit', '-m', `Merge ${config.mainBranch} into ${current}`], { cwd: top });
  return { merged: true, source, conflicts: [] };
}

module.exports = { cutRelease, backMerge };
