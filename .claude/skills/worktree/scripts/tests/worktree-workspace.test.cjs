'use strict';

// worktree.cjs in a workspace: members are the projects, worktrees live under <workspace>/worktrees/,
// and create-scope / remove-scope act on every member a plan's scope names.

const { describe, it, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { memberGitWorkspace, setManifestMember, localOrigin } = require('../../../../hooks/__tests__/fixtures/member-git-fixtures.cjs');
const { writePlan } = require('../../../../hooks/lib/__tests__/scope-test-fixtures.cjs');
const { git } = require('../../../workspace/scripts/tests/workspace-test-helpers.cjs');

const SCRIPT = path.join(__dirname, '..', 'worktree.cjs');

function worktree(cwd, ...args) {
  const r = spawnSync(process.execPath, [SCRIPT, ...args, '--json'], { cwd, encoding: 'utf8', input: '' });
  let json = null;
  try { json = JSON.parse(r.stdout); } catch { /* not JSON */ }
  return { code: r.status, json, stderr: r.stderr };
}

const branches = (dir) => git(dir, 'branch', '--format=%(refname:short)').split('\n');

// Submodule clones from a local path are refused by default since git 2.38.1
const saved = {};
before(() => {
  for (const [k, v] of Object.entries({ GIT_CONFIG_COUNT: '1', GIT_CONFIG_KEY_0: 'protocol.file.allow', GIT_CONFIG_VALUE_0: 'always' })) { saved[k] = process.env[k]; process.env[k] = v; }
});
after(() => {
  for (const [k, v] of Object.entries(saved)) { if (v === undefined) delete process.env[k]; else process.env[k] = v; }
});

describe('worktree info in a workspace', () => {
  it('reports repoType workspace with cloned members and sibling submodules, not vendored ones', (t) => {
    const ws = memberGitWorkspace(t);
    fs.rmSync(ws.members.market, { recursive: true });
    fs.writeFileSync(path.join(ws.root, '.gitmodules'), '[submodule "lib/forge-std"]\n\tpath = lib/forge-std\n\turl = https://github.com/foundry-rs/forge-std\n[submodule "libs/shared"]\n\tpath = libs/shared\n\turl = ./shared\n');
    git(ws.root, 'update-index', '--add', '--cacheinfo', `160000,${ws.protoCommits[0]},lib/forge-std`);
    git(ws.root, 'update-index', '--add', '--cacheinfo', `160000,${ws.protoCommits[1]},libs/shared`);
    const r = worktree(ws.root, 'info');
    assert.equal(r.code, 0, r.stderr);
    assert.equal(r.json.repoType, 'workspace');
    const byName = Object.fromEntries(r.json.projects.map((p) => [p.name, p]));
    assert.deepEqual(byName.order, { name: 'order', path: 'services/order', kind: 'member' });
    assert.equal(byName.shared.kind, 'submodule');
    assert.ok(byName.gateway && byName['tcx-proto'], 'cloned members are listed');
    assert.ok(!byName.market, 'a member that is not cloned is not a project');
    assert.ok(!byName['forge-std'], 'vendored submodules are not projects');
    assert.equal(r.json.worktreeRoot, path.join(ws.root, 'worktrees'));
  });

  it('keeps standalone repos standalone', (t) => {
    const ws = memberGitWorkspace(t);
    const r = worktree(ws.members['matching-engine'], 'info');
    assert.equal(r.json.repoType, 'standalone');
    assert.deepEqual(r.json.projects, []);
  });
});

describe('worktree create in a workspace', () => {
  it('branches inside the member, places the worktree under <workspace>/worktrees and reports the member dirty state', (t) => {
    const ws = memberGitWorkspace(t);
    fs.writeFileSync(path.join(ws.members.order, 'notes.txt'), 'wip\n');
    const r = worktree(ws.root, 'create', 'order', 'login-fix');
    assert.equal(r.code, 0, JSON.stringify(r.json));
    const expected = path.join(ws.root, 'worktrees', 'order-login-fix');
    assert.equal(r.json.worktreePath, expected);
    assert.equal(r.json.project, 'order');
    assert.equal(r.json.branch, 'feat/login-fix');
    assert.ok(fs.existsSync(path.join(expected, 'package.json')));
    assert.ok(branches(ws.members.order).includes('feat/login-fix'));
    assert.ok(!branches(ws.root).includes('feat/login-fix'), 'the workspace repo gets no branch');
    assert.match(r.json.warnings.join('\n'), /Uncommitted changes: .* 1 untracked/);
    assert.ok(!branches(ws.members.gateway).includes('feat/login-fix'), 'other members are untouched');
  });

  it("bases the branch on the member's open release when its manifest flow is release-train", (t) => {
    const ws = memberGitWorkspace(t);
    const order = ws.members.order;
    setManifestMember(ws.root, 'order', { git: { flow: 'release-train', enforcement: 'ask', mainBranch: 'main' } });
    localOrigin(t, order);
    git(order, 'push', '--quiet', 'origin', 'HEAD:refs/heads/release/1.2.0');
    git(order, 'fetch', '--quiet', 'origin');
    const r = worktree(ws.root, 'create', 'order', 'login-fix');
    assert.equal(r.code, 0, JSON.stringify(r.json));
    assert.equal(r.json.baseBranch, 'origin/release/1.2.0');
    assert.equal(r.json.baseBranchSource, 'git-workflow');
  });

  it('resolves a worktree it made back to the member rules', (t) => {
    const ws = memberGitWorkspace(t);
    setManifestMember(ws.root, 'order', { git: { flow: 'trunk', enforcement: 'deny', mainBranch: 'main' } });
    const wt = worktree(ws.root, 'create', 'order', 'login-fix').json.worktreePath;
    const { getGitConfig } = require('../../../../hooks/lib/git-flow-config.cjs');
    const c = getGitConfig(wt);
    assert.deepEqual([c.flow, c.enforcement, c.root], ['trunk', 'deny', wt]);
  });
});

describe('worktree create-scope and remove-scope', () => {
  /** Workspace whose order and gateway carry a submodule that can be cloned offline, and a plan scoped to both. */
  function scoped(t) {
    const ws = memberGitWorkspace(t);
    const protoUrl = `file://${ws.members['tcx-proto']}`;
    for (const name of ['order', 'gateway']) {
      const dir = ws.members[name];
      fs.writeFileSync(path.join(dir, '.gitmodules'), `[submodule "src/protos"]\n\tpath = src/protos\n\turl = ${protoUrl}\n`);
      git(dir, 'add', '.gitmodules');
      git(dir, 'commit', '--quiet', '-m', 'chore: local proto url');
    }
    const plan = writePlan(ws.root, '261028-1138-login-fix', ['scope: [services/order, services/gateway]']);
    return { ws, plan: path.relative(ws.root, plan) };
  }

  it('creates one worktree per member in scope with the same branch and submodules checked out', (t) => {
    const { ws, plan } = scoped(t);
    const r = worktree(ws.root, 'create-scope', 'login-fix', '--plan', plan);
    assert.equal(r.code, 0, JSON.stringify(r.json));
    assert.deepEqual(r.json.results.map((x) => [x.member, x.status, x.branch]), [['gateway', 'created', 'feat/login-fix'], ['order', 'created', 'feat/login-fix']]);
    for (const name of ['order', 'gateway']) {
      const wt = path.join(ws.root, 'worktrees', `${name}-login-fix`);
      assert.ok(fs.existsSync(path.join(wt, 'src', 'protos', 'order', 'order.proto')), `${name}: submodule checked out`);
      assert.ok(branches(ws.members[name]).includes('feat/login-fix'));
    }
    assert.ok(!branches(ws.members.core).includes('feat/login-fix'), 'members outside the scope are untouched');
  });

  it('is idempotent: a second run reports existing', (t) => {
    const { ws, plan } = scoped(t);
    worktree(ws.root, 'create-scope', 'login-fix', '--plan', plan);
    const again = worktree(ws.root, 'create-scope', 'login-fix', '--plan', plan);
    assert.equal(again.code, 0, JSON.stringify(again.json));
    assert.deepEqual(again.json.results.map((x) => x.status), ['existing', 'existing']);
  });

  it('reports a member that is not cloned as failed and still creates the other', (t) => {
    const { ws, plan } = scoped(t);
    fs.rmSync(path.join(ws.members.gateway, '.git'), { recursive: true });
    const r = worktree(ws.root, 'create-scope', 'login-fix', '--plan', plan);
    assert.equal(r.code, 1);
    const byMember = Object.fromEntries(r.json.results.map((x) => [x.member, x]));
    assert.equal(byMember.gateway.status, 'failed');
    assert.match(byMember.gateway.error, /not cloned/);
    assert.equal(byMember.order.status, 'created');
    assert.ok(fs.existsSync(byMember.order.worktreePath));
  });

  it('create-scope --dry-run creates nothing', (t) => {
    const { ws, plan } = scoped(t);
    const r = worktree(ws.root, 'create-scope', 'login-fix', '--plan', plan, '--dry-run');
    assert.equal(r.code, 0, JSON.stringify(r.json));
    assert.equal(r.json.dryRun, true);
    assert.deepEqual(r.json.results.map((x) => x.status), ['created', 'created']);
    assert.ok(!fs.existsSync(path.join(ws.root, 'worktrees', 'order-login-fix')));
  });

  it('remove-scope --dry-run lists both, remove-scope removes both and keeps the branches', (t) => {
    const { ws, plan } = scoped(t);
    worktree(ws.root, 'create-scope', 'login-fix', '--plan', plan);
    const dry = worktree(ws.root, 'remove-scope', 'login-fix', '--plan', plan, '--dry-run');
    assert.equal(dry.code, 0, JSON.stringify(dry.json));
    assert.deepEqual(dry.json.results.map((x) => [x.member, x.status]), [['gateway', 'removed'], ['order', 'removed']]);
    assert.ok(fs.existsSync(path.join(ws.root, 'worktrees', 'order-login-fix')), 'dry run removes nothing');
    const real = worktree(ws.root, 'remove-scope', 'login-fix', '--plan', plan);
    assert.equal(real.code, 0, JSON.stringify(real.json));
    for (const name of ['order', 'gateway']) {
      assert.ok(!fs.existsSync(path.join(ws.root, 'worktrees', `${name}-login-fix`)));
      assert.ok(branches(ws.members[name]).includes('feat/login-fix'), 'branch kept');
    }
    const missing = worktree(ws.root, 'remove-scope', 'login-fix', '--plan', plan);
    assert.equal(missing.code, 1);
    assert.deepEqual(missing.json.results.map((x) => x.status), ['failed', 'failed']);
  });

  it('refuses outside a workspace, without --plan, and for a plan that names no member', (t) => {
    const { ws } = scoped(t);
    assert.equal(worktree(ws.members.order, 'create-scope', 'x', '--plan', 'plans/p').json.error.code, 'NOT_A_WORKSPACE');
    assert.equal(worktree(ws.root, 'create-scope', 'x').json.error.code, 'MISSING_ARGS');
    writePlan(ws.root, 'empty', ['scope: [docs]']);
    assert.match(worktree(ws.root, 'create-scope', 'x', '--plan', 'plans/empty').json.error.message, /names no workspace member/);
    assert.match(worktree(ws.root, 'create-scope', 'x', '--plan', '../outside').json.error.message, /--plan must be a folder/);
  });

  it('remove-scope refuses a modified submodule even when .gitmodules says ignore = dirty', (t) => {
    const { ws, plan } = scoped(t);
    const order = ws.members.order;
    fs.appendFileSync(path.join(order, '.gitmodules'), '\tignore = dirty\n');
    git(order, 'add', '.gitmodules');
    git(order, 'commit', '--quiet', '-m', 'chore: hide submodule changes');
    const made = worktree(ws.root, 'create-scope', 'login-fix', '--plan', plan);
    assert.equal(made.code, 0, JSON.stringify(made.json));
    const wt = path.join(ws.root, 'worktrees', 'order-login-fix');
    fs.appendFileSync(path.join(wt, 'src', 'protos', 'order', 'order.proto'), '// local edit\n');
    assert.equal(git(wt, 'status', '--porcelain'), '', 'git status alone does not show the edit');
    const r = worktree(ws.root, 'remove-scope', 'login-fix', '--plan', plan);
    assert.equal(r.code, 1);
    const byMember = Object.fromEntries(r.json.results.map((x) => [x.member, x]));
    assert.equal(byMember.order.status, 'failed');
    assert.match(byMember.order.error, /uncommitted or untracked changes/);
    assert.equal(byMember.gateway.status, 'removed');
    assert.ok(fs.existsSync(path.join(wt, 'src', 'protos', 'order', 'order.proto')), 'the edit is still there');
  });

  it('reports existing only for a worktree on the same branch', (t) => {
    const { ws, plan } = scoped(t);
    worktree(ws.root, 'create-scope', 'login-fix', '--plan', plan);
    git(path.join(ws.root, 'worktrees', 'order-login-fix'), 'switch', '--quiet', '-c', 'feat/other');
    fs.mkdirSync(path.join(ws.root, 'worktrees', 'gateway-login-fix'), { recursive: true, force: true });
    fs.rmSync(path.join(ws.root, 'worktrees', 'gateway-login-fix'), { recursive: true });
    git(ws.members.gateway, 'worktree', 'prune');
    fs.mkdirSync(path.join(ws.root, 'worktrees', 'gateway-login-fix'));
    const r = worktree(ws.root, 'create-scope', 'login-fix', '--plan', plan);
    assert.equal(r.code, 1);
    const byMember = Object.fromEntries(r.json.results.map((x) => [x.member, x]));
    assert.match(byMember.order.error, /is a worktree on feat\/other, not feat\/login-fix/);
    assert.match(byMember.gateway.error, /exists but is not a worktree of gateway/);
  });

  it('stops on an invalid manifest', (t) => {
    const { ws, plan } = scoped(t);
    fs.writeFileSync(path.join(ws.root, 'adf-workspace.json'), '{ "version": 1 }');
    const r = worktree(ws.root, 'create-scope', 'login-fix', '--plan', plan);
    assert.equal(r.code, 1);
    assert.match(r.json.error.message, /run workspace\.cjs check/);
    assert.ok(!fs.existsSync(path.join(ws.root, 'worktrees', 'order-login-fix')));
  });
});
