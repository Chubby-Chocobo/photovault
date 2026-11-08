/**
 * workspace-members.cjs - Read the nested repos of a directory into manifest members, and seed `org`.
 *
 * Nothing here writes. A member's `repo` is its origin URL without credentials, in https form when
 * the URL can be rewritten safely; the credential-free URL is also what the `remote set-url` hint
 * prints, so no command output ever holds a token.
 *
 * @module workspace-members
 */

'use strict';

const path = require('path');
const { nestedRepos } = require('../../../../hooks/lib/repo-shape-detector.cjs');
const { memberPath, memberState } = require('../../../../hooks/lib/workspace-manifest.cjs');
const { stripCredentials, toProtocol, canonicalUrl, ownerOf } = require('../../../../hooks/lib/git-remote-url.cjs');
const { isRefName, repoError } = require('../../../../hooks/lib/workspace-manifest-validate.cjs');
const { slugName } = require('./system-map-seed.cjs');
const { originOf, branchOf, defaultBranchOf, strippedWhenCredentialed } = require('./workspace-git.cjs');

const DIR_NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/;

/** The URL a manifest stores for an origin: https when it can be rewritten, else as written. */
const manifestRepo = (stripped) => (repoError('repo', stripped) ? undefined : toProtocol(stripped, 'https') || stripped);

/**
 * @param {string} root
 * @param {string[]} roleDirs
 * @returns {{ members: object[], notes: string[], origins: string[] }}
 *   origins: credential-free origin URL of every member found, for owner seeding
 */
function readMembers(root, roleDirs) {
  const members = [];
  const notes = [];
  const origins = [];
  const names = new Set();
  for (const rel of nestedRepos(root, roleDirs).sort()) {
    const dirName = path.posix.basename(rel);
    const name = slugName(dirName);
    if (!DIR_NAME_RE.test(dirName) || !name || names.has(name)) {
      notes.push(`${rel}: skipped, the directory name cannot become a unique member name`);
      continue;
    }
    names.add(name);
    const dir = path.join(root, rel);
    const origin = originOf(dir);
    const stripped = origin ? stripCredentials(origin) : null;
    const repo = stripped ? manifestRepo(stripped) : undefined;
    if (stripped && !repo) notes.push(`${rel}: origin is not a usable URL, member written without repo`);
    if (!origin) notes.push(`${rel}: no origin remote, member written without repo`);
    if (stripped) origins.push(stripped);
    const branch = branchOf(dir);
    const current = branch && isRefName(branch) ? branch : undefined;
    const main = defaultBranchOf(dir);
    members.push({
      name, path: rel, ...(repo ? { repo } : {}), ...(current ? { branch: current } : {}),
      git: { flow: 'off', enforcement: 'ask', mainBranch: main && isRefName(main) ? main : current || 'main' },
    });
  }
  return { members, notes, origins };
}

/**
 * Origins that carry credentials, as the credential-free URL to set instead. Only repos that are
 * really inside the workspace are looked at; the umbrella repo itself is path ".".
 * @returns {{ path: string, url: string }[]}
 */
function remoteFixes(root, members) {
  const fixes = [];
  const umbrella = strippedWhenCredentialed(originOf(root));
  if (umbrella) fixes.push({ path: '.', url: umbrella });
  for (const m of members) {
    if (memberState(root, m) !== 'cloned') continue;
    const url = strippedWhenCredentialed(originOf(memberPath(root, m)));
    if (url) fixes.push({ path: m.path, url });
  }
  return fixes;
}

/** Distinct owners (first spelling wins) of the umbrella origin followed by every member origin. */
function seedOrg(umbrellaOrigin, memberOrigins) {
  const seen = new Set();
  const owners = [];
  for (const url of [umbrellaOrigin, ...memberOrigins]) {
    const owner = url ? ownerOf(url) : null;
    if (owner && !seen.has(owner.toLowerCase())) {
      seen.add(owner.toLowerCase());
      owners.push(owner);
    }
  }
  return owners;
}

/** Canonical https URL of the umbrella origin, or undefined when it is not a remote. */
const umbrellaRepo = (stripped) => (stripped ? canonicalUrl(stripped) || undefined : undefined);

/** The owner of a member's repo when it is not in org (compared without case), else null; init notes it and check warns. */
function ownerOutsideOrg(member, org) {
  const owner = member.repo ? ownerOf(member.repo) : null;
  return owner && !org.some((o) => o.toLowerCase() === owner.toLowerCase()) ? owner : null;
}

module.exports = { readMembers, remoteFixes, seedOrg, umbrellaRepo, ownerOutsideOrg };
