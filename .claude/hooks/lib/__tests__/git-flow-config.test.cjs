'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { getGitConfig, normalizeGit, globToRegExp, matchesAny, isProtectedBranch, branchKind, DEFAULT_TYPES } = require('../git-flow-config.cjs');
const { memberGitWorkspace, setManifestMember, writeAdfConfig, withProjectDir } = require('../../__tests__/fixtures/member-git-fixtures.cjs');

function project(t, files = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'adf-git-config-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  fs.mkdirSync(path.join(dir, '.git'));
  for (const [rel, content] of Object.entries(files)) {
    fs.mkdirSync(path.join(dir, path.dirname(rel)), { recursive: true });
    fs.writeFileSync(path.join(dir, rel), typeof content === 'string' ? content : JSON.stringify(content));
  }
  return dir;
}
const config = (t, adf, extra = {}) => getGitConfig(project(t, { '.claude/config/adf-config.json': adf, ...extra }));

describe('git-flow-config', () => {
  it('defaults to release-train with ask, main, package.json and the fixed branch model', (t) => {
    const c = getGitConfig(project(t));
    assert.equal(c.flow, 'release-train');
    assert.equal(c.enabled, true);
    assert.equal(c.enforcement, 'ask');
    assert.equal(c.mainBranch, 'main');
    assert.deepEqual(c.versionFiles, [{ path: 'package.json', json: 'version' }]);
    assert.equal(c.versionFilesConfigured, false);
    assert.equal(c.tagPrefix, 'v');
    assert.deepEqual(c.protectedBranches, ['main', 'release/*']);
    assert.deepEqual(c.merge, { featureToRelease: 'squash', releaseToMain: 'merge', hotfixToMain: 'squash' });
    assert.deepEqual(c.directPush.types, ['chore']);
    assert.deepEqual(c.commit.types, DEFAULT_TYPES);
    assert.equal(c.commit.subjectMax, 72);
    assert.equal(c.commit.formatLevel, 'ask');
  });

  it('applies project values and derives the merge rules from the flow', (t) => {
    const c = config(t, { git: {
      flow: 'trunk', enforcement: 'deny', mainBranch: 'master', tagPrefix: '',
      versionFiles: [{ path: 'pyproject.toml', regex: '^version = "(.*)"' }],
      directPush: { paths: ['docs/**'] }, commit: { pathTypes: { '.claude/': ['feat', 'fix', 'perf'] } },
    } });
    assert.equal(c.flow, 'trunk');
    assert.equal(c.enforcement, 'deny');
    assert.deepEqual(c.protectedBranches, ['master', 'release/*']);
    assert.deepEqual(c.merge, { featureToMain: 'squash', releaseToMain: 'squash', hotfixToMain: 'squash' });
    assert.equal(c.versionFilesConfigured, true);
    assert.equal(c.tagPrefix, '');
    assert.deepEqual(c.directPush.paths, ['docs/**']);
    assert.deepEqual(c.commit.pathTypes, { '.claude/': ['feat', 'fix', 'perf'] });
    assert.equal(c.commit.formatLevel, 'deny');
  });

  it('flow off disables the branch model but keeps the commit format check', (t) => {
    const c = config(t, { git: { flow: 'off' } });
    assert.equal(c.enabled, false);
    assert.deepEqual(c.merge, {});
    assert.equal(c.commit.formatLevel, 'ask');
  });

  it('falls back to defaults on invalid values', (t) => {
    const c = config(t, { git: {
      flow: 'gitflow', enforcement: 'block', mainBranch: '../main', tagPrefix: 'v 1',
      versionFiles: [{ path: '../package.json', json: 'version' }, { path: 'x.toml', regex: '(' }],
      directPush: { paths: 'docs/**' },
    } });
    assert.equal(c.flow, 'release-train');
    assert.equal(c.enforcement, 'ask');
    assert.equal(c.mainBranch, 'main');
    assert.equal(c.tagPrefix, 'v');
    assert.equal(c.versionFilesConfigured, false);
    assert.deepEqual(c.directPush.paths.slice(0, 1), ['docs/**']);
    assert.equal(config(t, { git: { versionFiles: [{ path: 'v.txt', regex: '^(?:v)' }] } }).versionFilesConfigured, false, 'a regex without a capture group');
  });

  it('pins what every key resolves to, valid and invalid', (t) => {
    const D = getGitConfig(project(t));
    const pick = (c) => ({
      flow: c.flow, enforcement: c.enforcement, mainBranch: c.mainBranch, tagPrefix: c.tagPrefix, versionFiles: c.versionFiles,
      versionFilesConfigured: c.versionFilesConfigured, paths: c.directPush.paths, pathTypes: c.commit.pathTypes,
    });
    const defaults = pick(D);
    const rows = [
      [{}, {}],
      [{ flow: 'trunk' }, { flow: 'trunk' }],
      [{ flow: 'off' }, { flow: 'off' }],
      [{ flow: 'Trunk' }, {}],
      [{ flow: 7 }, {}],
      [{ enforcement: 'deny' }, { enforcement: 'deny' }],
      [{ enforcement: 'off' }, { enforcement: 'off' }],
      [{ enforcement: 'DENY' }, {}],
      [{ mainBranch: 'release/next' }, { mainBranch: 'release/next' }],
      [{ mainBranch: 'a b' }, {}],
      [{ mainBranch: 'a..b' }, {}],
      [{ mainBranch: '/main' }, {}],
      [{ mainBranch: 'main/' }, {}],
      [{ mainBranch: '' }, {}],
      [{ mainBranch: 5 }, {}],
      [{ tagPrefix: '' }, { tagPrefix: '' }],
      [{ tagPrefix: 'app-' }, { tagPrefix: 'app-' }],
      [{ tagPrefix: 'v/1' }, {}],
      [{ tagPrefix: 3 }, {}],
      [{ versionFiles: [{ path: '.claude/metadata.json', json: 'version' }] }, { versionFiles: [{ path: '.claude/metadata.json', json: 'version' }], versionFilesConfigured: true }],
      [{ versionFiles: [{ path: 'v.txt', regex: '^(\\d+)' }] }, { versionFiles: [{ path: 'v.txt', regex: '^(\\d+)' }], versionFilesConfigured: true }],
      [{ versionFiles: [] }, {}],
      [{ versionFiles: 'package.json' }, {}],
      [{ versionFiles: [{ path: 'a.json', json: 'version' }, { path: 'b.json' }] }, {}],
      [{ versionFiles: [{ path: '/abs.json', json: 'version' }] }, {}],
      [{ versionFiles: [{ path: 'a/../b.json', json: 'version' }] }, {}],
      [{ versionFiles: [{ path: ' ', json: 'version' }] }, {}],
      [{ versionFiles: [{ path: 'a.json', json: ' ' }] }, {}],
      [{ versionFiles: [{ path: 'a.json', regex: '(' }] }, {}],
      [{ versionFiles: [null] }, {}],
      [{ directPush: { paths: ['docs/**', 'x?y z'] } }, { paths: ['docs/**', 'x?y z'] }],
      [{ directPush: { paths: [] } }, { paths: [] }],
      [{ directPush: { paths: ['docs/**', 4] } }, {}],
      [{ directPush: { paths: ['docs/**', ' '] } }, {}],
      [{ directPush: { paths: 'docs/**' } }, {}],
      [{ directPush: null }, {}],
      [{ commit: { pathTypes: { 'src/': ['feat'], 'lib/': 'fix', 'x/': ['a', 3], 'y/': [] } } }, { pathTypes: { 'src/': ['feat'], 'y/': [] } }],
      [{ commit: null }, {}],
    ];
    for (const [git, expected] of rows) {
      assert.deepEqual(pick(config(t, { git })), { ...defaults, ...expected }, JSON.stringify(git));
    }
  });

  it('normalizeGit applies the same per-key rules, without mode relaxation or member resolution', (t) => {
    const raw = { flow: 'trunk', enforcement: 'ask', mainBranch: 'dev', tagPrefix: 'app-', directPush: { paths: ['docs/**'] }, commit: { pathTypes: { 'src/': ['feat'], 'lib/': 'fix' } } };
    const n = normalizeGit(raw);
    assert.deepEqual(n, {
      flow: 'trunk', enforcement: 'ask', mainBranch: 'dev', tagPrefix: 'app-', directPushPaths: ['docs/**'], pathTypes: { 'src/': ['feat'] },
      versionFiles: [{ path: 'package.json', json: 'version' }], versionFilesConfigured: false,
    });
    const c = config(t, { git: raw });
    assert.deepEqual([c.flow, c.enforcement, c.mainBranch, c.tagPrefix, c.directPush.paths, c.commit.pathTypes], [n.flow, n.enforcement, n.mainBranch, n.tagPrefix, n.directPushPaths, n.pathTypes]);
    assert.equal(normalizeGit({ enforcement: 'ask' }).enforcement, 'ask', 'auto mode would run an ask as off; the pure half keeps it');
    for (const junk of [undefined, null, 'trunk', 7, ['trunk']]) assert.deepEqual(normalizeGit(junk), normalizeGit({}), String(junk));
  });

  it('honours the older commitGuard.messageFormat and types', (t) => {
    assert.equal(config(t, { commitGuard: { messageFormat: true } }).commit.formatLevel, 'deny');
    assert.equal(config(t, { commitGuard: { messageFormat: false }, git: { enforcement: 'deny' } }).commit.formatLevel, 'off');
    assert.deepEqual(config(t, { commitGuard: { types: ['feat', 'fix'] } }).commit.types, ['feat', 'fix']);
  });

  it('reads commit types from the JSON commitlint config, never running JS configs', (t) => {
    const rc = { rules: { 'type-enum': [2, 'always', ['feat', 'fix', 'chore']] } };
    assert.deepEqual(config(t, {}, { '.commitlintrc.json': rc }).commit.types, ['feat', 'fix', 'chore']);
    assert.deepEqual(config(t, {}, { 'package.json': { commitlint: rc } }).commit.types, ['feat', 'fix', 'chore']);
    assert.deepEqual(config(t, {}, { 'commitlint.config.js': 'throw new Error("must not run")' }).commit.types, DEFAULT_TYPES);
  });

  it('matches globs and classifies branches', (t) => {
    assert.ok(globToRegExp('docs/**').test('docs/a/b.md'));
    assert.ok(globToRegExp('**/*.md').test('README.md') && globToRegExp('**/*.md').test('a/b/c.md'));
    assert.ok(!globToRegExp('docs/*').test('docs/a/b.md'));
    assert.ok(globToRegExp('.github/').test('.github/workflows/x.yml'));
    assert.ok(matchesAny('./docs/x.md', ['README.md', 'docs/**']));
    assert.ok(!matchesAny('src/a.ts', ['README.md', 'docs/**']));
    const c = getGitConfig(project(t));
    assert.ok(isProtectedBranch(c, 'main') && isProtectedBranch(c, 'release/1.2.0'));
    assert.ok(!isProtectedBranch(c, 'feat/x'));
    assert.deepEqual(['main', 'release/1.0.0', 'feat/a', 'fix/b', 'hotfix/c', 'chore/d'].map((b) => branchKind(c, b)), ['main', 'release', 'feature', 'fix', 'hotfix', 'other']);
  });
});

describe('git-flow-config inside a workspace member', () => {
  const setOriginHead = (dir, branch) => {
    const file = path.join(dir, '.git', 'refs', 'remotes', 'origin', 'HEAD');
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, `ref: refs/remotes/origin/${branch}\n`);
  };

  it('without member config or manifest git: flow off, ask, origin/HEAD branch, member root', (t) => {
    const ws = memberGitWorkspace(t);
    const order = ws.members.order;
    setManifestMember(ws.root, 'order', { git: null, branch: null });
    setOriginHead(order, 'develop');
    writeAdfConfig(ws.root, { git: { flow: 'trunk', enforcement: 'deny', mainBranch: 'workspace-main' } });
    for (const projectDir of [ws.root, order]) {
      fs.mkdirSync(path.join(order, '.claude'), { recursive: true });
      const c = withProjectDir(projectDir, () => getGitConfig(path.join(order, 'src')));
      assert.equal(c.flow, 'off');
      assert.equal(c.enabled, false);
      assert.equal(c.enforcement, 'ask');
      assert.equal(c.mainBranch, 'develop');
      assert.deepEqual(c.protectedBranches, ['develop', 'release/*']);
      assert.equal(c.root, order);
    }
  });

  it('takes the manifest branch before origin/HEAD, and main when neither exists', (t) => {
    const ws = memberGitWorkspace(t);
    setManifestMember(ws.root, 'order', { git: null, branch: 'staging' });
    setOriginHead(ws.members.order, 'develop');
    assert.equal(getGitConfig(ws.members.order).mainBranch, 'staging');
    setManifestMember(ws.root, 'gateway', { git: null, branch: null });
    assert.equal(getGitConfig(ws.members.gateway).mainBranch, 'main');
  });

  it('uses members[].git from the manifest', (t) => {
    const ws = memberGitWorkspace(t);
    setManifestMember(ws.root, 'order', { git: { flow: 'trunk', enforcement: 'deny', mainBranch: 'develop' } });
    for (const projectDir of [ws.root, ws.members.order]) {
      const c = withProjectDir(projectDir, () => getGitConfig(ws.members.order));
      assert.deepEqual([c.flow, c.enforcement, c.mainBranch, c.root], ['trunk', 'deny', 'develop', ws.members.order]);
    }
  });

  it("lets the member's own config override the manifest, commitGuard included", (t) => {
    const ws = memberGitWorkspace(t);
    setManifestMember(ws.root, 'order', { git: { flow: 'trunk', enforcement: 'deny', mainBranch: 'develop' } });
    writeAdfConfig(ws.members.order, { git: { flow: 'release-train', mainBranch: 'main', directPush: { paths: ['notes/**'] } }, commitGuard: { types: ['feat', 'fix'] } });
    const c = getGitConfig(ws.members.order);
    assert.deepEqual([c.flow, c.mainBranch, c.directPush.paths, c.commit.types], ['release-train', 'main', ['notes/**'], ['feat', 'fix']]);
  });

  it('reads commitlint types from the member, not the workspace', (t) => {
    const ws = memberGitWorkspace(t);
    fs.writeFileSync(path.join(ws.members.order, '.commitlintrc.json'), JSON.stringify({ rules: { 'type-enum': [2, 'always', ['feat', 'ops']] } }));
    assert.deepEqual(getGitConfig(ws.members.order).commit.types, ['feat', 'ops']);
    assert.deepEqual(getGitConfig(ws.members.gateway).commit.types, DEFAULT_TYPES);
  });

  it('still resolves the member when the manifest fails validation', (t) => {
    const ws = memberGitWorkspace(t);
    writeAdfConfig(ws.root, { git: { flow: 'trunk', enforcement: 'deny', mainBranch: 'workspace-main' } });
    fs.writeFileSync(path.join(ws.root, 'adf-workspace.json'), JSON.stringify({ version: 1, members: [{ name: 'order', path: 'services/order' }, { name: 42 }] }));
    setOriginHead(ws.members.order, 'develop');
    const c = getGitConfig(ws.members.order);
    assert.deepEqual([c.flow, c.enforcement, c.mainBranch], ['off', 'ask', 'develop']);
  });

  it('keeps the workspace config at the workspace root and outside members', (t) => {
    const ws = memberGitWorkspace(t);
    writeAdfConfig(ws.root, { git: { flow: 'trunk', enforcement: 'deny', mainBranch: 'trunk-main' } });
    for (const dir of [ws.root, path.join(ws.root, 'docs'), path.join(ws.root, 'services')]) {
      const c = withProjectDir(ws.root, () => getGitConfig(dir));
      assert.deepEqual([c.flow, c.mainBranch, c.root], ['trunk', 'trunk-main', ws.root]);
    }
  });

  it('resolves a member worktree that lives outside the workspace through --git-common-dir', (t) => {
    const ws = memberGitWorkspace(t);
    setManifestMember(ws.root, 'order', { git: { flow: 'trunk', enforcement: 'deny', mainBranch: 'develop' } });
    const parent = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'adf-member-worktree-')));
    t.after(() => fs.rmSync(parent, { recursive: true, force: true }));
    const wt = path.join(parent, 'order-login');
    const r = spawnSync('git', ['worktree', 'add', '--quiet', '-b', 'feat/login', wt], { cwd: ws.members.order, encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
    const c = getGitConfig(wt);
    assert.deepEqual([c.flow, c.enforcement, c.mainBranch, c.root], ['trunk', 'deny', 'develop', fs.realpathSync(wt)]);
    // The same worktree under <workspace>/worktrees/ resolves the same way
    const inside = path.join(ws.root, 'worktrees', 'order-fix');
    assert.equal(spawnSync('git', ['worktree', 'add', '--quiet', '-b', 'fix/x', inside], { cwd: ws.members.order, encoding: 'utf8' }).status, 0);
    assert.equal(getGitConfig(inside).mainBranch, 'develop');
  });

  it('returns the same object as before outside workspaces', (t) => {
    const dir = project(t, { '.claude/config/adf-config.json': { git: { flow: 'trunk', mainBranch: 'dev' } } });
    const root = withProjectDir('', () => getGitConfig(dir));
    assert.deepEqual(root, {
      root: dir, flow: 'trunk', enabled: true, enforcement: 'ask', mainBranch: 'dev',
      versionFiles: [{ path: 'package.json', json: 'version' }], versionFilesConfigured: false, tagPrefix: 'v',
      branches: { release: 'release/', feature: 'feat/', fix: 'fix/', hotfix: 'hotfix/' },
      merge: { featureToMain: 'squash', releaseToMain: 'squash', hotfixToMain: 'squash' },
      protectedBranches: ['dev', 'release/*'],
      directPush: { types: ['chore'], paths: ['docs/**', '.github/**', 'README.md', 'CHANGELOG.md', 'CLAUDE.md', 'AGENTS.md'] },
      commit: { types: DEFAULT_TYPES, subjectMax: 72, pathTypes: {}, formatLevel: 'ask', secrets: true, allowSecretFiles: [] },
    });
  });

  it('takes commitGuard.secrets from the member, never from the workspace', (t) => {
    const ws = memberGitWorkspace(t);
    writeAdfConfig(ws.root, { commitGuard: { secrets: false } });
    assert.equal(withProjectDir(ws.root, () => getGitConfig(ws.members.order)).commit.secrets, true);
    assert.equal(getGitConfig(ws.root).commit.secrets, false);
    writeAdfConfig(ws.members.order, { commitGuard: { secrets: false } });
    assert.equal(getGitConfig(ws.members.order).commit.secrets, false);
  });

  it('reads commitGuard.allowSecretFiles as a string array, else none', (t) => {
    assert.deepEqual(config(t, {}).commit.allowSecretFiles, []);
    assert.deepEqual(config(t, { commitGuard: { allowSecretFiles: ['test/fixtures/**', 'keys/dev.pem'] } }).commit.allowSecretFiles, ['test/fixtures/**', 'keys/dev.pem']);
    for (const bad of ['test/**', [1], [''], { a: 1 }, null]) {
      assert.deepEqual(config(t, { commitGuard: { allowSecretFiles: bad } }).commit.allowSecretFiles, [], JSON.stringify(bad));
    }
  });

  it('takes commitGuard.allowSecretFiles from the member, never from the workspace', (t) => {
    const ws = memberGitWorkspace(t);
    writeAdfConfig(ws.root, { commitGuard: { allowSecretFiles: ['fixtures/**'] } });
    assert.deepEqual(withProjectDir(ws.root, () => getGitConfig(ws.members.order)).commit.allowSecretFiles, []);
    assert.deepEqual(getGitConfig(ws.root).commit.allowSecretFiles, ['fixtures/**']);
    writeAdfConfig(ws.members.order, { commitGuard: { allowSecretFiles: ['member/**'] } });
    assert.deepEqual(getGitConfig(ws.members.order).commit.allowSecretFiles, ['member/**']);
  });

  it("reads a linked worktree's own config before the main checkout's", (t) => {
    const ws = memberGitWorkspace(t);
    writeAdfConfig(ws.members.order, { git: { flow: 'trunk', mainBranch: 'main' } });
    const wt = path.join(ws.root, 'worktrees', 'order-x');
    assert.equal(spawnSync('git', ['worktree', 'add', '--quiet', '-b', 'feat/x', wt], { cwd: ws.members.order, encoding: 'utf8' }).status, 0);
    assert.equal(getGitConfig(wt).flow, 'trunk', 'falls back to the main checkout when the worktree has no config');
    writeAdfConfig(wt, { git: { flow: 'release-train', mainBranch: 'main' } });
    assert.equal(getGitConfig(wt).flow, 'release-train');
    assert.equal(getGitConfig(ws.members.order).flow, 'trunk');
  });

  it('asks git for nothing in a linked worktree or submodule of a project that is not a workspace', (t) => {
    const dir = project(t);
    const run = (cwd, args) => assert.equal(spawnSync('git', args, { cwd, encoding: 'utf8' }).status, 0, args.join(' '));
    run(dir, ['init', '--quiet']);
    run(dir, ['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '--quiet', '--allow-empty', '-m', 'init']);
    const wt = path.join(dir, '..', `${path.basename(dir)}-wt`);
    t.after(() => fs.rmSync(wt, { recursive: true, force: true }));
    run(dir, ['worktree', 'add', '--quiet', '-b', 'feat/x', wt]);
    const sub = path.join(dir, 'vendor-sub');
    fs.mkdirSync(path.join(sub, '..'), { recursive: true });
    fs.mkdirSync(sub);
    fs.writeFileSync(path.join(sub, '.git'), 'gitdir: ../.git/modules/vendor-sub\n');
    const preload = path.join(dir, 'preload.cjs');
    fs.writeFileSync(preload, `const cp = require('child_process'), fs = require('fs'), seen = [];
for (const fn of ['spawn', 'spawnSync', 'execFile', 'execFileSync', 'exec', 'execSync']) {
  const orig = cp[fn];
  cp[fn] = function (file, ...rest) { seen.push(String(file)); return orig.call(this, file, ...rest); };
}
process.on('exit', () => fs.writeFileSync(process.env.SPAWN_LOG, JSON.stringify(seen)));
`);
    const log = path.join(dir, 'spawned.json');
    const driver = `const { getGitConfig } = require(${JSON.stringify(path.join(__dirname, '..', 'git-flow-config.cjs'))}); getGitConfig(${JSON.stringify(wt)}); getGitConfig(${JSON.stringify(sub)});`;
    const r = spawnSync(process.execPath, ['--require', preload, '-e', driver], { env: { ...process.env, SPAWN_LOG: log }, encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
    assert.deepEqual(JSON.parse(fs.readFileSync(log, 'utf8')), []);
  });
});
