'use strict';

// Tags a merge into the main branch. The head comes from the GitHub PR that holds the merge (or the
// merge-commit subject, or --head). Before tagging, the merge is checked again, because on plans
// without branch protection nothing stops a bad merge from reaching main.

const { git, gitTry, ghTry, showFile } = require('./git-exec.cjs');
const { resolveReleaseVersion, tagFor, listTags } = require('./release-version.cjs');
const { readVersions, checkVersions } = require('./version-files.cjs');
const { expectedStrategy } = require('./branch-guards.cjs');
const { branchKind } = require('../../../../hooks/lib/git-flow-config.cjs');

/**
 * The head branch of the PR merged into `base` whose merge produced `sha`, via gh.
 * @returns {{head: string|null, error: string|null}} error when the lookup itself failed (no gh,
 *   no auth, no permission, network), as opposed to "no such PR"
 */
function headFromGitHub(sha, cwd, base) {
  if (!/^[0-9a-f]{7,64}$/.test(sha)) return { head: null, error: `not a commit id: ${sha}` };
  const filter = `[.[] | select(.merged_at != null and .base.ref == "${base}" and .merge_commit_sha == "${sha}") | .head.ref] | first // empty`;
  const r = ghTry(['api', `repos/{owner}/{repo}/commits/${sha}/pulls`, '--jq', filter], { cwd, timeout: 20000 });
  if (r.error || r.status !== 0) return { head: null, error: (r.stderr || (r.error && r.error.message) || 'gh failed').split('\n')[0] };
  return { head: r.stdout.trim() || null, error: null };
}

/** The head branch named by a merge-commit subject ("Merge pull request #1 from owner/release/1.2.0"). */
function headFromSubject(subject) {
  const pr = /^Merge pull request #\d+ from [^/\s]+\/(\S+)/.exec(subject);
  if (pr) return pr[1];
  const local = /^Merge (?:remote-tracking )?branch '(?:[^/']+\/)?((?:release|hotfix)\/[^']+)'/.exec(subject);
  return local ? local[1] : null;
}

/**
 * @returns {{tag: string|null, version: string|null, head: string|null, problems: string[], reason: string}}
 *   problems non-empty means the merge broke the flow and nothing was tagged
 */
function planTag(config, { sha, head, cwd, remote, github = true }) {
  const result = { tag: null, version: null, head: null, problems: [], reason: '' };
  const parents = git(['rev-list', '--parents', '-n', '1', sha], { cwd }).split(' ').slice(1);
  const subject = git(['log', '-1', '--format=%s', sha], { cwd });
  if (!config.enabled) return { ...result, reason: 'git.flow is off; nothing to tag' };
  let lookup = { head: null, error: null };
  if (!head && github) lookup = headFromGitHub(sha, cwd, config.mainBranch);
  result.head = head || lookup.head || headFromSubject(subject);
  if (!result.head && lookup.error) {
    // A squash merge names no branch in its subject, so without the PR a hotfix would go untagged unseen
    result.problems.push(`could not look up the pull request of ${sha.slice(0, 7)} (${lookup.error}); give the job pull-requests: read and GH_TOKEN, or pass --head <branch>`);
    return result;
  }
  if (!result.head) return { ...result, reason: 'no PR or merge subject names a branch; a direct push releases nothing' };

  const kind = branchKind(config, result.head);
  if (kind !== 'release' && kind !== 'hotfix') {
    if (config.flow === 'release-train') result.problems.push(`${result.head} was merged straight into ${config.mainBranch}; only release and hotfix branches may be`);
    return { ...result, reason: `${result.head} releases nothing` };
  }
  const strategy = expectedStrategy(config, config.mainBranch, result.head);
  const isMerge = parents.length > 1;
  if (strategy === 'merge' && !isMerge) result.problems.push(`${result.head} must reach ${config.mainBranch} with a merge commit, but ${sha.slice(0, 7)} has one parent`);
  if (strategy === 'squash' && isMerge) result.problems.push(`${result.head} must be squash-merged, but ${sha.slice(0, 7)} is a merge commit`);

  const tags = listTags(cwd, remote);
  const atSha = gitTry(['tag', '--points-at', sha], { cwd }).stdout.split('\n').filter(Boolean);
  try {
    result.version = resolveReleaseVersion(config, result.head, { tags: tags.filter((t) => !atSha.includes(t)) });
  } catch (err) {
    result.problems.push(err.message);
    return result;
  }
  const tag = tagFor(config, result.version);
  if (atSha.includes(tag)) return { ...result, tag, alreadyTagged: true, reason: `${tag} already points at this merge` };
  if (tags.includes(tag)) result.problems.push(`${tag} already exists on another commit`);
  result.problems.push(...checkVersions(readVersions(config.versionFiles, (p) => showFile(sha, p, cwd)), result.version));
  if (result.problems.length === 0) result.tag = tag;
  return result;
}

/** Creates and pushes the annotated tag unless dryRun; returns the plan. */
function tagRelease(config, { sha, head, cwd, remote, github, dryRun = false, notes }) {
  const plan = planTag(config, { sha, head, cwd, remote, github });
  if (!plan.tag || plan.alreadyTagged || dryRun) return plan;
  git(['tag', '-a', plan.tag, '-m', notes || `Release ${plan.version}`, sha], { cwd });
  if (remote) {
    const push = gitTry(['push', remote, `refs/tags/${plan.tag}`], { cwd, timeout: 60000 });
    if (push.status !== 0) throw new Error(`created ${plan.tag} locally but could not push it: ${push.stderr}`);
  }
  plan.reason = `tagged ${plan.tag}`;
  return plan;
}

module.exports = { headFromGitHub, headFromSubject, planTag, tagRelease };
