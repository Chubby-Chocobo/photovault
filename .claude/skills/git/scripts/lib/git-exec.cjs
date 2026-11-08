'use strict';

// Runs git and gh without a shell, so branch names and paths are never interpreted.

const { spawnSync } = require('child_process');

function run(cmd, args, { cwd = process.cwd(), input, allowFail = false, timeout = 60000 } = {}) {
  const r = spawnSync(cmd, args, { cwd, input, encoding: 'utf8', timeout, maxBuffer: 64 * 1024 * 1024 });
  const out = { status: r.status, stdout: (r.stdout || '').replace(/\n$/, ''), stderr: (r.stderr || '').trim(), error: r.error };
  if (!allowFail && (r.error || r.status !== 0)) {
    const err = new Error(`${cmd} ${args.join(' ')} failed: ${out.stderr || (r.error && r.error.message) || `exit ${r.status}`}`);
    err.result = out;
    throw err;
  }
  return out;
}

const git = (args, opts) => run('git', args, opts).stdout;
const gitTry = (args, opts) => run('git', args, { ...opts, allowFail: true });
const gh = (args, opts) => run('gh', args, opts).stdout;
const ghTry = (args, opts) => run('gh', args, { ...opts, allowFail: true });

/** The remote to use: the current branch's upstream remote, else origin, else the only remote, else null. */
function defaultRemote(cwd) {
  const upstream = gitTry(['rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}'], { cwd });
  if (upstream.status === 0 && upstream.stdout.includes('/')) return upstream.stdout.split('/')[0];
  const remotes = gitTry(['remote'], { cwd }).stdout.split('\n').filter(Boolean);
  if (remotes.includes('origin')) return 'origin';
  return remotes.length === 1 ? remotes[0] : null;
}

function currentBranch(cwd) {
  const r = gitTry(['symbolic-ref', '--quiet', '--short', 'HEAD'], { cwd });
  return r.status === 0 ? r.stdout : null;
}

function refExists(ref, cwd) {
  return gitTry(['rev-parse', '--verify', '--quiet', `${ref}^{commit}`], { cwd }).status === 0;
}

/** File content at a commit, or null when the file is not there. */
function showFile(ref, file, cwd) {
  const r = gitTry(['show', `${ref}:${file}`], { cwd });
  return r.status === 0 ? r.stdout : null;
}

module.exports = { run, git, gitTry, gh, ghTry, defaultRemote, currentBranch, refExists, showFile };
