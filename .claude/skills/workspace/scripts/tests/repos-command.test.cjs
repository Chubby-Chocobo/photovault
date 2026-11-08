'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { memberGitWorkspace, setManifestMember, writeAdfConfig, localOrigin } = require('../../../../hooks/__tests__/fixtures/member-git-fixtures.cjs');
const { writePlan } = require('../../../../hooks/lib/__tests__/scope-test-fixtures.cjs');
const { git } = require('./workspace-test-helpers.cjs');
const { run, countStatus } = require('../lib/repos-command.cjs');

/** A workspace whose own flow is off, so prBase never asks a remote. */
function workspace(t) {
  const ws = memberGitWorkspace(t);
  writeAdfConfig(ws.root, { git: { flow: 'off' } });
  return ws;
}

const repos = (ws, opts = {}) => run({ root: ws.root, docsRel: 'docs', opts });
const byName = (outcome) => Object.fromEntries(outcome.result.repos.map((r) => [r.name, r]));

describe('repos-command', () => {
  it('lists the members in a plan scope plus the workspace, with dirty counts', (t) => {
    const ws = workspace(t);
    const plan = writePlan(ws.root, '261028-1138-login-fix', ['scope: [services/order, services/gateway]']);
    const order = ws.members.order;
    fs.appendFileSync(path.join(order, 'package.json'), '\n');
    fs.writeFileSync(path.join(order, 'staged.txt'), 'a\n');
    git(order, 'add', 'staged.txt');
    fs.writeFileSync(path.join(order, 'new.txt'), 'b\n');

    const outcome = repos(ws, { plan: path.relative(ws.root, plan) });
    assert.equal(outcome.code, 0);
    assert.deepEqual(outcome.result.repos.map((r) => r.name), ['gateway', 'order', 'workspace']);
    const row = byName(outcome).order;
    assert.deepEqual(Object.keys(row), ['name', 'path', 'branch', 'staged', 'unstaged', 'untracked', 'upstream', 'ahead', 'behind', 'prBase', 'hasOwnAdf']);
    // order's gitlink directory is not checked out, which git reports as one more unstaged entry
    assert.deepEqual([row.path, row.branch, row.staged, row.unstaged, row.untracked, row.upstream], ['services/order', 'main', 1, 2, 1, null]);
    assert.equal(byName(outcome).workspace.path, '.');
    assert.match(outcome.text, /order \(services\/order\): main, staged 1/);
  });

  it('--paths selects members the same way, and names members that are not cloned', (t) => {
    const ws = workspace(t);
    fs.rmSync(path.join(ws.members.gateway, '.git'), { recursive: true });
    const outcome = repos(ws, { paths: 'services/order,services/gateway,docs' });
    assert.deepEqual(outcome.result.repos.map((r) => r.name), ['order', 'workspace']);
    assert.deepEqual(outcome.result.notCloned, ['gateway']);
    assert.match(outcome.text, /not cloned: gateway/);
  });

  it('--changed lists what sync leaves behind, an untracked marker and a modified CLAUDE.md, and omits clean members', (t) => {
    const ws = workspace(t);
    const engine = ws.members['matching-engine'];
    fs.writeFileSync(path.join(engine, 'CLAUDE.md'), '# engine\n');
    git(engine, 'add', 'CLAUDE.md');
    git(engine, 'commit', '--quiet', '-m', 'docs: add CLAUDE.md');
    fs.appendFileSync(path.join(engine, 'CLAUDE.md'), '\nsystem context block\n');
    fs.writeFileSync(path.join(engine, '.adf-workspace.json'), '{}\n');

    const rows = byName(repos(ws, { changed: true }));
    assert.deepEqual([rows['matching-engine'].unstaged, rows['matching-engine'].untracked], [1, 1]);
    for (const clean of ['trading', 'market', 'admin-web', 'tcx-proto']) assert.ok(!rows[clean], `${clean} has no changes`);
    assert.ok(rows.workspace, 'the workspace row is always there');
  });

  it('reports upstream, ahead and behind', (t) => {
    const ws = workspace(t);
    const order = ws.members.order;
    localOrigin(t, order);
    git(order, 'branch', '--set-upstream-to=origin/main', 'main');
    git(order, 'commit', '--quiet', '--allow-empty', '-m', 'chore: local');
    const row = byName(repos(ws, { paths: 'services/order' })).order;
    assert.deepEqual([row.upstream, row.ahead, row.behind], ['origin/main', 1, 0]);
  });

  it('prBase: the member flow target, else the manifest branch, else origin/HEAD', (t) => {
    const ws = workspace(t);
    setManifestMember(ws.root, 'order', { git: { flow: 'trunk', enforcement: 'ask', mainBranch: 'develop' } });
    localOrigin(t, ws.members.order);
    setManifestMember(ws.root, 'gateway', { branch: 'staging' });
    fs.mkdirSync(path.join(ws.members.core, '.git', 'refs', 'remotes', 'origin'), { recursive: true });
    fs.writeFileSync(path.join(ws.members.core, '.git', 'refs', 'remotes', 'origin', 'HEAD'), 'ref: refs/remotes/origin/trunk\n');
    git(ws.members.core, 'update-ref', 'refs/remotes/origin/trunk', 'HEAD');
    setManifestMember(ws.root, 'core', { branch: null });
    const rows = byName(repos(ws, { paths: 'services/order,services/gateway,services/core' }));
    assert.equal(rows.order.prBase, 'develop');
    assert.equal(rows.gateway.prBase, 'staging', 'flow off: the manifest branch');
    assert.equal(rows.core.prBase, 'trunk', 'flow off, no manifest branch: origin/HEAD');
    assert.equal(rows.core.hasOwnAdf, true);
    assert.equal(rows.order.hasOwnAdf, false);
  });

  it('prBase finds the open release from remote-tracking branches without asking the remote', (t) => {
    const ws = workspace(t);
    const order = ws.members.order;
    setManifestMember(ws.root, 'order', { git: { flow: 'release-train', enforcement: 'ask', mainBranch: 'main' } });
    localOrigin(t, order);
    git(order, 'push', '--quiet', 'origin', 'HEAD:refs/heads/release/1.2.0');
    git(order, 'fetch', '--quiet', 'origin');
    git(order, 'switch', '--quiet', '-c', 'feat/login-fix');
    assert.equal(byName(repos(ws, { paths: 'services/order' })).order.prBase, 'release/1.2.0');
    git(order, 'tag', '-a', 'v1.2.0', '-m', 'v1.2.0');
    assert.equal(byName(repos(ws, { paths: 'services/order' })).order.prBase, 'main', 'a released version is no longer open');
  });

  it('falls back when git-flow cannot tell (release-train, no open release)', (t) => {
    const ws = workspace(t);
    setManifestMember(ws.root, 'order', { git: { flow: 'release-train', enforcement: 'ask', mainBranch: 'main' }, branch: 'main' });
    localOrigin(t, ws.members.order);
    assert.equal(byName(repos(ws, { paths: 'services/order' })).order.prBase, 'main');
  });

  it('refuses outside a workspace and for conflicting or bad flags', (t) => {
    const ws = workspace(t);
    assert.equal(repos(ws, { plan: 'x', changed: true }).code, 2);
    assert.equal(repos(ws, { plan: 'plans/missing' }).code, 1);
    assert.equal(run({ root: ws.members.order, docsRel: 'docs', opts: {} }).code, 1);
  });

  it('counts staged, unstaged, untracked and renamed entries from porcelain -z output', () => {
    const out = ['M  a', ' M b', 'MM c', 'R  new', 'old', '?? d', '?? e', 'A  f', ' D g'].join('\0') + '\0';
    assert.deepEqual(countStatus(out), { staged: 4, unstaged: 3, untracked: 2 });
    assert.deepEqual(countStatus(''), { staged: 0, unstaged: 0, untracked: 0 });
  });

  it('runs in this process: no node child and no ls-remote', (t) => {
    const ws = workspace(t);
    setManifestMember(ws.root, 'order', { git: { flow: 'release-train', enforcement: 'ask', mainBranch: 'main' } });
    localOrigin(t, ws.members.order);
    const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'adf-repos-spawn-')));
    t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
    const log = path.join(dir, 'spawned.json');
    const preload = path.join(dir, 'preload.cjs');
    fs.writeFileSync(preload, `const cp = require('child_process'), fs = require('fs'), seen = [];
for (const fn of ['spawn', 'spawnSync', 'execFile', 'execFileSync', 'exec', 'execSync', 'fork']) {
  const orig = cp[fn];
  cp[fn] = function (file, ...rest) { seen.push([String(file), ...(Array.isArray(rest[0]) ? rest[0] : [])].join(' ')); return orig.call(this, file, ...rest); };
}
process.on('exit', () => fs.writeFileSync(process.env.SPAWN_LOG, JSON.stringify(seen)));
`);
    const driver = `const { run } = require(${JSON.stringify(path.join(__dirname, '..', 'lib', 'repos-command.cjs'))});
const r = run({ root: process.env.WS_ROOT, docsRel: 'docs', opts: { paths: 'services/order' } });
if (r.code !== 0) process.exit(9);`;
    const r = spawnSync(process.execPath, ['--require', preload, '-e', driver], { env: { ...process.env, SPAWN_LOG: log, WS_ROOT: ws.root }, encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
    const spawned = JSON.parse(fs.readFileSync(log, 'utf8'));
    assert.ok(spawned.length > 0 && spawned.every((c) => c.startsWith('git ')), `only git was spawned: ${spawned.join(', ')}`);
    assert.ok(!spawned.some((c) => c.includes('ls-remote')), 'the remote is never asked');
  });
});
