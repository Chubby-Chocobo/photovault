'use strict';

// An initialized TCX workspace for the tests of per-member git rules: the manifest gives every
// member { flow: off, enforcement: ask, mainBranch: main }; helpers change one member's rules.

const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawnSync } = require('node:child_process');
const { initializedWorkspace, editManifest } = require('../../../skills/workspace/scripts/tests/workspace-test-helpers.cjs');

/** Replace (or, with null, remove) members[name].git in the manifest; extra keys are merged into the member. */
function setManifestMember(root, name, { git, ...rest }) {
  editManifest(root, (manifest) => {
    const member = manifest.members.find((m) => m.name === name);
    if (git === null) delete member.git;
    else if (git) member.git = git;
    Object.assign(member, rest);
    for (const key of Object.keys(rest)) if (rest[key] === null) delete member[key];
  });
}

/** Write <dir>/.claude/config/adf-config.json. */
function writeAdfConfig(dir, config) {
  const file = path.join(dir, '.claude', 'config', 'adf-config.json');
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(config, null, 2)}\n`);
}

/** Run fn with $CLAUDE_PROJECT_DIR set, then restore it. */
function withProjectDir(dir, fn) {
  const before = process.env.CLAUDE_PROJECT_DIR;
  process.env.CLAUDE_PROJECT_DIR = dir;
  try { return fn(); } finally { process.env.CLAUDE_PROJECT_DIR = before; }
}

/** The TCX workspace after `init`, with a .claude dir at its root (as a real ADF project has). */
function memberGitWorkspace(t) {
  const ws = initializedWorkspace(t);
  fs.mkdirSync(path.join(ws.root, '.claude'), { recursive: true });
  return ws;
}

/** Point `dir`'s origin at a new local bare repo that already holds its current branch, so ls-remote and push work offline. Returns the bare path. */
function localOrigin(t, dir) {
  const bare = path.join(fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'adf-member-origin-'))), 'origin.git');
  t.after(() => fs.rmSync(path.dirname(bare), { recursive: true, force: true }));
  const run = (cwd, ...args) => {
    const r = spawnSync('git', args, { cwd, encoding: 'utf8' });
    if (r.status !== 0) throw new Error(`git ${args.join(' ')}: ${r.stderr}`);
  };
  run(dir, 'init', '--quiet', '--bare', bare);
  run(dir, 'remote', 'set-url', 'origin', bare);
  run(dir, 'push', '--quiet', 'origin', 'HEAD');
  run(dir, 'fetch', '--quiet', 'origin');
  return bare;
}

module.exports = { localOrigin, memberGitWorkspace, setManifestMember, writeAdfConfig, withProjectDir };
