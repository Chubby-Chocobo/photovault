'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { sh, flow, makeRepo, write, commit, mergeInto } = require('./git-flow-test-repo.cjs');
const { bumpMinor, bumpPatch } = require('../lib/semver.cjs');

/** Sets the version in package.json (null removes it), commits and pushes to main. */
function setMainVersion(work, version) {
  write(work, 'package.json', `${JSON.stringify(version ? { name: 'demo', version } : { name: 'demo' }, null, 2)}\n`);
  commit(work, 'chore: set version');
  sh(work, 'git', 'push', '--quiet', 'origin', 'main');
}

const dry = (work, ...args) => flow(work, 'cut-release', '--next', ...args, '--dry-run');

describe('semver bumps', () => {
  it('bumps minor and patch', () => {
    assert.equal(bumpMinor('1.3.9'), '1.4.0');
    assert.equal(bumpPatch('1.3.9'), '1.3.10');
    assert.equal(bumpMinor('x'), null);
  });
});

describe('cut-release --next', () => {
  it('is 0.1.0 when there is no tag and no version in the version files', (t) => {
    const { work } = makeRepo(t, { tag: null });
    setMainVersion(work, null);
    for (const bump of ['minor', 'patch']) assert.equal(dry(work, bump).out, '0.1.0');
    assert.equal(dry(work, 'minor', '--json').json.version, '0.1.0');
  });

  it('bumps the newest tag under a non-v tagPrefix and ignores tags with another prefix', (t) => {
    const { work } = makeRepo(t, { git: { tagPrefix: 'rel-' }, tag: 'rel-1.2.0' });
    sh(work, 'git', 'tag', 'v9.0.0');
    sh(work, 'git', 'push', '--quiet', 'origin', 'v9.0.0');
    assert.equal(dry(work, 'minor').out, '1.3.0');
    assert.equal(dry(work, 'patch').out, '1.2.1');
  });

  it('uses a patch bump of the default-prefix tag', (t) => {
    const { work } = makeRepo(t, { tag: 'v1.3.1' });
    assert.equal(dry(work, 'patch').out, '1.3.2');
    assert.equal(dry(work, 'minor').out, '1.4.0');
  });

  it('starts from the version files on origin/main when a release shipped without a tag', (t) => {
    const { work } = makeRepo(t, { version: '1.3.1', tag: 'v1.3.1' });
    setMainVersion(work, '1.4.0');
    const r = dry(work, 'minor', '--json');
    assert.equal(r.json.version, '1.5.0');
    assert.equal(r.json.branch, 'release/1.5.0');
    assert.equal(dry(work, 'minor').out, '1.5.0');
    assert.equal(dry(work, 'patch').out, '1.4.1');
  });

  it('reads origin/main, not the working tree', (t) => {
    const { work } = makeRepo(t, { version: '1.3.1', tag: 'v1.3.1' });
    write(work, 'package.json', `${JSON.stringify({ name: 'demo', version: '7.0.0' })}\n`);
    assert.equal(dry(work, 'minor').out, '1.4.0');
  });

  it('cuts the release it names, then refuses another while it is open', (t) => {
    const { work } = makeRepo(t, { tag: 'v1.3.1' });
    let r = flow(work, 'cut-release', '--next', 'minor', '--json');
    assert.equal(r.code, 0, r.err);
    assert.deepEqual([r.json.version, r.json.branch, r.json.created, r.json.committed], ['1.4.0', 'release/1.4.0', true, true]);
    sh(work, 'git', 'fetch', '--quiet');
    assert.equal(JSON.parse(sh(work, 'git', 'show', 'origin/release/1.4.0:package.json')).version, '1.4.0');
    r = flow(work, 'cut-release', '--next', 'patch', '--dry-run', '--json');
    assert.equal(r.code, 1);
    assert.equal(r.json.code, 'release_open');
    assert.match(r.json.error, /release\/1\.4\.0 is still open/);
  });
});

describe('cut-release refusals carry a code with --json', () => {
  const refused = (r, code) => {
    assert.equal(r.code, 1, r.out);
    assert.equal(r.json.code, code, r.out);
    assert.equal(typeof r.json.error, 'string');
  };

  it('--next with a version, with a bad bump or without a version', (t) => {
    const { work } = makeRepo(t);
    refused(flow(work, 'cut-release', '1.1.0', '--next', 'minor', '--json'), 'invalid_args');
    refused(flow(work, 'cut-release', '--next', 'major', '--json'), 'invalid_args');
    refused(flow(work, 'cut-release', '--json'), 'invalid_version');
    refused(flow(work, 'cut-release', 'one', '--json'), 'invalid_version');
    assert.equal(flow(work, 'cut-release', '--next').code, 2, '--next needs a value');
  });

  it('tag_exists, not_newer and release_open', (t) => {
    const { work } = makeRepo(t);
    refused(flow(work, 'cut-release', '1.0.0', '--json'), 'tag_exists');
    refused(flow(work, 'cut-release', '0.9.0', '--json'), 'not_newer');
    assert.equal(flow(work, 'cut-release', '1.1.0').code, 0);
    refused(flow(work, 'cut-release', '1.2.0', '--json'), 'release_open');
  });

  it('no_remote', (t) => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'adf-git-flow-solo-'));
    t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
    sh(dir, 'git', 'init', '--quiet');
    write(dir, '.claude/config/adf-config.json', '{}');
    write(dir, 'package.json', '{"name":"demo","version":"1.0.0"}\n');
    commit(dir, 'chore: initial commit');
    refused(flow(dir, 'cut-release', '1.1.0', '--json'), 'no_remote');
    refused(flow(dir, 'cut-release', '--next', 'minor', '--json'), 'no_remote');
  });

  it('other failures print code "error" and text mode is unchanged', (t) => {
    const { work } = makeRepo(t);
    const r = flow(work, 'bump-version', '--check', '--json');
    assert.deepEqual(r.json, { error: 'bump-version --check needs a version: --check x.y.z', code: 'error' });
    assert.match(flow(work, 'cut-release', '1.0.0').err, /^v1\.0\.0 already exists$/);
  });

  it('already_shipped: a release merged into main but not tagged', (t) => {
    const { work } = makeRepo(t);
    assert.equal(flow(work, 'cut-release', '1.1.0').code, 0);
    sh(work, 'git', 'fetch', '--quiet');
    mergeInto(work, 'main', 'origin/release/1.1.0', 'Merge pull request #1 from acme/release/1.1.0');
    refused(flow(work, 'cut-release', '1.1.0', '--json'), 'already_shipped');
    refused(flow(work, 'cut-release', '1.1.0', '--dry-run', '--json'), 'already_shipped');
  });

  it('already_shipped: the main branch already holds the version of a squash-merged release', (t) => {
    const { work } = makeRepo(t);
    assert.equal(flow(work, 'cut-release', '1.1.0').code, 0);
    setMainVersion(work, '1.1.0');
    refused(flow(work, 'cut-release', '1.1.0', '--json'), 'already_shipped');
  });
});

describe('cut-release on a half-cut release', () => {
  it('completes a branch that has no bump yet, even after main moved on', (t) => {
    const { work } = makeRepo(t);
    sh(work, 'git', 'push', '--quiet', 'origin', 'main:refs/heads/release/1.1.0');
    write(work, 'src/app.js', 'module.exports = 4;\n');
    commit(work, 'feat: moves main on');
    sh(work, 'git', 'push', '--quiet', 'origin', 'main');
    const r = flow(work, 'cut-release', '1.1.0', '--json');
    assert.equal(r.code, 0, r.err);
    assert.deepEqual([r.json.created, r.json.committed], [false, true]);
    sh(work, 'git', 'fetch', '--quiet');
    assert.equal(JSON.parse(sh(work, 'git', 'show', 'origin/release/1.1.0:package.json')).version, '1.1.0');
  });
});

describe('active-release --json', () => {
  it('lists two open releases in open[] and exits 0; text mode still refuses', (t) => {
    const { work } = makeRepo(t);
    sh(work, 'git', 'push', '--quiet', 'origin', 'main:refs/heads/release/1.1.0', 'main:refs/heads/release/1.2.0', 'main:refs/heads/release/next');
    const r = flow(work, 'active-release', '--json');
    assert.equal(r.code, 0, r.err);
    assert.deepEqual(r.json, { activeRelease: null, open: ['release/1.1.0', 'release/1.2.0'], malformed: ['release/next'] });
    const text = flow(work, 'active-release');
    assert.equal(text.code, 1);
    assert.match(text.err, /more than one open release: release\/1\.1\.0, release\/1\.2\.0/);
  });

  it('names the single open release in activeRelease and open', (t) => {
    const { work } = makeRepo(t);
    assert.deepEqual(flow(work, 'active-release', '--json').json, { activeRelease: null, open: [], malformed: [] });
    assert.equal(flow(work, 'cut-release', '1.1.0').code, 0);
    assert.deepEqual(flow(work, 'active-release', '--json').json, { activeRelease: 'release/1.1.0', open: ['release/1.1.0'], malformed: [] });
  });
});

describe('cut-release reruns and failures', () => {
  it('rerunning is safe when main already held the version before the cut', (t) => {
    const { work, remote } = makeRepo(t);
    setMainVersion(work, '1.1.0');
    const first = flow(work, 'cut-release', '1.1.0', '--json');
    assert.equal(first.code, 0, first.err);
    assert.deepEqual([first.json.created, first.json.committed], [true, false]);
    const again = flow(work, 'cut-release', '1.1.0', '--json');
    assert.equal(again.code, 0, again.out);
    assert.deepEqual([again.json.created, again.json.committed], [false, false]);
    // once main moves on, the untouched branch is still not shipped
    write(work, 'src/app.js', 'module.exports = 5;\n');
    commit(work, 'feat: moves main on');
    sh(work, 'git', 'push', '--quiet', 'origin', 'main');
    assert.equal(flow(work, 'cut-release', '1.1.0').code, 0);
    assert.match(sh(remote, 'git', 'branch', '--list', 'release/*'), /release\/1\.1\.0/);
  });

  it('prints code "error", not a system error code, and leaves no release branch behind', (t) => {
    const { work, remote } = makeRepo(t);
    const r = flow(work, 'cut-release', '1.1.0', '--json', { env: { TMPDIR: '/nonexistent-adf-tmp' } });
    assert.equal(r.code, 1);
    assert.equal(r.json.code, 'error');
    assert.match(r.json.error, /ENOENT/);
    assert.equal(sh(remote, 'git', 'branch', '--list', 'release/*'), '', 'a local failure must not push the branch');
  });

  it('--next still sees a shipped version when the clone only tracks other branches', (t) => {
    const { work } = makeRepo(t, { version: '1.3.1', tag: 'v1.3.1' });
    setMainVersion(work, '1.4.0');
    sh(work, 'git', 'config', 'remote.origin.fetch', '+refs/heads/none:refs/remotes/origin/none');
    sh(work, 'git', 'update-ref', '-d', 'refs/remotes/origin/main');
    assert.equal(dry(work, 'minor').out, '1.5.0');
  });

  it('--next and an explicit version read the same (remote) tags', (t) => {
    const { work } = makeRepo(t);
    sh(work, 'git', 'tag', 'v1.1.0'); // local only
    assert.equal(dry(work, 'minor').out, '1.1.0');
    const r = flow(work, 'cut-release', '1.1.0', '--dry-run');
    assert.equal(r.code, 0, r.err);
  });
});
