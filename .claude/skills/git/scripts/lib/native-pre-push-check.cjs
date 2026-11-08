'use strict';

// The rules of the native pre-push hook: what a push may do to protected branches and release tags.

const { gitTry } = require('./git-exec.cjs');
const { isProtectedBranch } = require('../../../../hooks/lib/git-flow-config.cjs');
const { checkPush } = require('./branch-guards.cjs');
const { isVersion } = require('./semver.cjs');

const ZERO = /^0+$/;

/**
 * Problems with the refs a push updates. `lines` are git's pre-push stdin lines:
 * "<local ref> <local sha> <remote ref> <remote sha>".
 */
function checkPushUpdates(config, { lines, cwd, remote, allowTags = false }) {
  const problems = [];
  for (const line of lines.filter((l) => l.trim())) {
    const [, localSha, remoteRef, remoteSha] = line.trim().split(/\s+/);
    if (remoteRef.startsWith('refs/tags/')) {
      const name = remoteRef.slice('refs/tags/'.length);
      if (!allowTags && config.enabled && name.startsWith(config.tagPrefix) && isVersion(name.slice(config.tagPrefix.length))) {
        problems.push(`${name} is a release tag; CI creates release tags when a release merges`);
      }
      continue;
    }
    if (!remoteRef.startsWith('refs/heads/')) continue;
    const branch = remoteRef.slice('refs/heads/'.length);
    if (!isProtectedBranch(config, branch)) continue;
    if (ZERO.test(localSha)) { problems.push(`deleting ${branch} is not allowed`); continue; }
    if (!ZERO.test(remoteSha) && gitTry(['cat-file', '-e', `${remoteSha}^{commit}`], { cwd }).status !== 0) {
      problems.push(`${branch} on the remote has commits you have not fetched; fetch and merge first`);
      continue;
    }
    if (!ZERO.test(remoteSha) && gitTry(['merge-base', '--is-ancestor', remoteSha, localSha], { cwd }).status !== 0) {
      problems.push(`force-pushing ${branch} is not allowed`);
      continue;
    }
    if (branch === config.mainBranch) {
      const r = checkPush(config, { from: remoteSha, to: localSha, cwd, remote });
      problems.push(...r.problems);
    }
  }
  return problems;
}

module.exports = { checkPushUpdates };
