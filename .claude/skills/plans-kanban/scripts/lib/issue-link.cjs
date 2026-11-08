/**
 * Resolve the GitHub issues base URL of the project that owns the plans,
 * from `git remote get-url origin`. Returns null when there is no GitHub remote.
 */
const { execFileSync } = require('child_process');

const GITHUB_REMOTE = /^(?:https?:\/\/(?:[^@/]+@)?|ssh:\/\/git@|git@)github\.com[/:]([\w.-]+)\/([\w.-]+?)(?:\.git)?\/?$/;

function issueBaseFromRemote(remoteUrl) {
  const m = GITHUB_REMOTE.exec(String(remoteUrl || '').trim());
  return m ? `https://github.com/${m[1]}/${m[2]}/issues` : null;
}

function resolveIssueBase(dir) {
  if (!dir) return null;
  try {
    const out = execFileSync('git', ['remote', 'get-url', 'origin'], {
      cwd: dir,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
      timeout: 3000
    });
    return issueBaseFromRemote(out);
  } catch {
    return null;
  }
}

module.exports = { issueBaseFromRemote, resolveIssueBase };
