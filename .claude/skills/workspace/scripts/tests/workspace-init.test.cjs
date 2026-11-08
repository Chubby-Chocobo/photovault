#!/usr/bin/env node
/**
 * Tests for `workspace init`
 * Run: node --test .claude/skills/workspace/scripts/tests/workspace-init.test.cjs
 */

'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { makeTcxWorkspace, makePolyglotMonorepo } = require('../../../../hooks/__tests__/fixtures/workspace-fixtures.cjs');
const { loadManifest } = require('../../../../hooks/lib/workspace-manifest.cjs');
const { loadSystemMap } = require('../../../../hooks/lib/system-map.cjs');
const { cli, cliJson, git, readJson, editManifest, trackedHashes } = require('./workspace-test-helpers.cjs');

const statusOf = (json, rel) => json.outputs.find((o) => o.path === rel).status;
const ROLE_DIRS = ['services', 'apps', 'contracts', 'infra'];

describe('workspace init: workspace mode', () => {
  it('--dry-run writes nothing and lists the planned files and the seeded org', (t) => {
    const { root } = makeTcxWorkspace(t);
    const before = git(root, 'status', '--porcelain');
    const { code, json } = cliJson(root, ['init', '--dry-run']);
    assert.strictEqual(code, 0);
    assert.strictEqual(json.dryRun, true);
    assert.deepStrictEqual(json.outputs.map((o) => o.path), ['adf-workspace.json', '.gitignore', '.ignore', 'bootstrap.sh', 'docs/architecture/system-map.json', 'docs/conventions/contracts.md']);
    assert.deepStrictEqual(json.org, { list: ['acme'], seeded: true, members: [{ owner: 'acme', members: 8 }] });
    assert.strictEqual(git(root, 'status', '--porcelain'), before);
    for (const rel of ['adf-workspace.json', '.ignore', 'bootstrap.sh', 'docs']) assert.ok(!fs.existsSync(path.join(root, rel)), `${rel} must not exist`);
    assert.match(cli(root, ['init', '--dry-run']).out, /org: acme \(from origins: acme 8 members; confirm or pass --org\)/);
  });

  it('seeds org from the umbrella and every distinct member owner', (t) => {
    const { root } = makeTcxWorkspace(t);
    git(path.join(root, 'services/order'), 'remote', 'set-url', 'origin', 'https://github.com/tcx-client/x');
    const { json } = cliJson(root, ['init', '--dry-run']);
    assert.deepStrictEqual(json.org.list, ['acme', 'tcx-client']);
    assert.deepStrictEqual(json.org.members, [{ owner: 'acme', members: 7 }, { owner: 'tcx-client', members: 1 }], 'an owner with one repo stands out');
    assert.match(cli(root, ['init', '--dry-run']).out, /from origins: acme 7 members, tcx-client 1 member;/);
  });

  it('names the members whose owner is not in --org, in the dry run and on a re-run', (t) => {
    const { root } = makeTcxWorkspace(t);
    git(path.join(root, 'services/order'), 'remote', 'set-url', 'origin', 'https://github.com/vendorx/order');
    const NOTE = 'owner not in org, so not trusted: order (vendorx); add an owner to org only if the team trusts it';
    const dry = cliJson(root, ['init', '--dry-run', '--org', 'acme']);
    assert.ok(dry.json.notes.includes(NOTE), dry.json.notes.join('\n'));
    assert.match(cli(root, ['init', '--dry-run', '--org', 'acme']).out, /note: owner not in org, so not trusted: order \(vendorx\)/);
    assert.strictEqual(cli(root, ['init', '--org', 'acme']).code, 0);
    assert.ok(cliJson(root, ['init', '--dry-run']).json.notes.includes(NOTE), 'an existing manifest is checked too');
  });

  it('--org overrides the seeding', (t) => {
    const { root } = makeTcxWorkspace(t);
    git(path.join(root, 'services/order'), 'remote', 'set-url', 'origin', 'https://github.com/tcx-client/x');
    const { json } = cliJson(root, ['init', '--dry-run', '--org', 'acme']);
    assert.deepStrictEqual(json.org, { list: ['acme'], seeded: false });
    assert.doesNotMatch(cli(root, ['init', '--dry-run', '--org', 'acme']).out, /from origins/);
  });

  it('writes a valid manifest, both blocks, an executable bootstrap.sh and a seeded map', (t) => {
    const { root, token } = makeTcxWorkspace(t, { credentialUrl: true });
    const result = cli(root, ['init']);
    assert.strictEqual(result.code, 0, result.out);

    const { manifest, errors } = loadManifest(root);
    assert.deepStrictEqual(errors, []);
    assert.strictEqual(manifest.repo, 'https://github.com/acme/tcx-workspace');
    assert.deepStrictEqual(manifest.roleDirs, ROLE_DIRS);
    assert.deepStrictEqual(manifest.org, ['acme']);
    assert.deepStrictEqual(manifest.members.map((m) => m.name).sort(), ['admin-web', 'core', 'gateway', 'market', 'matching-engine', 'order', 'tcx-proto', 'trading']);
    for (const m of manifest.members) assert.deepStrictEqual(Object.keys(m.git), ['flow', 'enforcement', 'mainBranch']);
    const order = manifest.members.find((m) => m.name === 'order');
    assert.deepStrictEqual({ repo: order.repo, branch: order.branch, git: order.git }, { repo: 'https://github.com/acme/tcx-order.git', branch: 'main', git: { flow: 'off', enforcement: 'ask', mainBranch: 'main' } });

    const ignore = fs.readFileSync(path.join(root, '.gitignore'), 'utf8');
    const search = fs.readFileSync(path.join(root, '.ignore'), 'utf8');
    for (const dir of ROLE_DIRS) {
      assert.match(ignore, new RegExp(`^/${dir}/$`, 'm'));
      assert.match(search, new RegExp(`^!/${dir}/$`, 'm'));
    }
    assert.match(ignore, /^worktrees\/$/m);
    assert.ok(fs.statSync(path.join(root, 'bootstrap.sh')).mode & 0o100, 'bootstrap.sh is executable');
    assert.match(fs.readFileSync(path.join(root, 'bootstrap.sh'), 'utf8'), /^#!\/usr\/bin\/env sh\nexec node ".*workspace\.cjs" bootstrap --cwd "\$\(dirname "\$0"\)" "\$@"\n$/);

    const loaded = loadSystemMap(root, 'docs', { manifest });
    assert.deepStrictEqual(loaded.errors, []);
    const byName = Object.fromEntries(loaded.map.components.map((c) => [c.name, c]));
    assert.deepStrictEqual([byName.order.role, byName.order.stack], ['backend', 'nestjs']);
    assert.deepStrictEqual([byName['matching-engine'].role, byName['matching-engine'].stack], ['engine', 'maven']);
    assert.deepStrictEqual([byName['admin-web'].role, byName['admin-web'].stack], ['frontend', 'vue']);
    assert.deepStrictEqual(loaded.map.contracts.map((c) => [c.id, c.kind]), [['tcx-proto', 'proto']]);
    for (const consumer of ['order', 'gateway', 'core']) assert.deepStrictEqual(byName[consumer].consumes, ['tcx-proto'], consumer);
    assert.strictEqual(byName.order.path, 'services/order');

    assert.ok(!result.out.includes(token), 'stdout holds no token');
    for (const rel of ['adf-workspace.json', 'docs/architecture/system-map.json', '.gitignore', '.ignore']) {
      assert.ok(!fs.readFileSync(path.join(root, rel), 'utf8').includes(token), `${rel} holds no token`);
    }
    assert.match(result.out, /git -C services\/market remote set-url origin https:\/\/github\.com\/acme\/tcx-market\.git/);
    assert.match(result.out, /git\.directPush\.paths in \.claude\/config\/adf-config\.json: written/);
  });

  it('never writes a tracked file inside a member', (t) => {
    const { root } = makeTcxWorkspace(t);
    const core = path.join(root, 'services/core');
    const before = { hashes: trackedHashes(core), status: git(core, 'status', '--porcelain') };
    cli(root, ['init']);
    cli(root, ['init']);
    assert.deepStrictEqual({ hashes: trackedHashes(core), status: git(core, 'status', '--porcelain') }, before);
  });

  it('reports everything kept on the second run', (t) => {
    const { root } = makeTcxWorkspace(t);
    assert.strictEqual(cliJson(root, ['init']).code, 0);
    const second = cliJson(root, ['init']);
    assert.ok(second.json.outputs.every((o) => o.status === 'kept'), JSON.stringify(second.json.outputs));
    assert.strictEqual(second.json.org, null);
  });

  it('updates both blocks when the manifest gains a role dir', (t) => {
    const { root } = makeTcxWorkspace(t);
    cli(root, ['init']);
    editManifest(root, (m) => m.roleDirs.push('bots'));
    fs.mkdirSync(path.join(root, 'bots/telegram'), { recursive: true });
    git(path.join(root, 'bots/telegram'), 'init', '--quiet');
    const { json } = cliJson(root, ['init']);
    assert.strictEqual(statusOf(json, '.gitignore'), 'updated');
    assert.strictEqual(statusOf(json, '.ignore'), 'updated');
    assert.strictEqual(statusOf(json, 'adf-workspace.json'), 'kept');
    for (const dir of [...ROLE_DIRS, 'bots']) {
      assert.match(fs.readFileSync(path.join(root, '.gitignore'), 'utf8'), new RegExp(`^/${dir}/$`, 'm'));
      assert.match(fs.readFileSync(path.join(root, '.ignore'), 'utf8'), new RegExp(`^!/${dir}/$`, 'm'));
    }
    assert.ok(json.notes.some((n) => n.includes('bots/telegram')), 'the unlisted nested repo is mentioned');
    assert.ok(cliJson(root, ['init']).json.outputs.every((o) => o.status === 'kept'));
  });

  it('leaves a block with damaged markers untouched', (t) => {
    const { root } = makeTcxWorkspace(t);
    cli(root, ['init']);
    const file = path.join(root, '.ignore');
    const damaged = `${fs.readFileSync(file, 'utf8')}# >>> ADF workspace search (managed by /workspace init) >>>\n`;
    fs.writeFileSync(file, damaged);
    const { json } = cliJson(root, ['init']);
    assert.strictEqual(statusOf(json, '.ignore'), 'malformed');
    assert.strictEqual(fs.readFileSync(file, 'utf8'), damaged);
  });

  it('completes on a re-run after a write failed behind the manifest', (t) => {
    if (typeof process.getuid === 'function' && process.getuid() === 0) return t.skip('root ignores directory permissions');
    const { root } = makeTcxWorkspace(t);
    const docs = path.join(root, 'docs');
    fs.mkdirSync(docs);
    fs.chmodSync(docs, 0o555);
    try {
      const first = cliJson(root, ['init']);
      assert.strictEqual(first.code, 1);
      assert.strictEqual(statusOf(first.json, 'adf-workspace.json'), 'written');
      assert.strictEqual(statusOf(first.json, 'docs/architecture/system-map.json'), 'failed');
    } finally {
      fs.chmodSync(docs, 0o755);
    }
    const second = cliJson(root, ['init']);
    assert.strictEqual(second.code, 0);
    assert.strictEqual(statusOf(second.json, 'adf-workspace.json'), 'kept');
    assert.strictEqual(statusOf(second.json, 'docs/architecture/system-map.json'), 'written');
  });

  it('--fix-remotes rewrites an origin that held credentials', (t) => {
    const { root, token } = makeTcxWorkspace(t, { credentialUrl: true });
    const market = path.join(root, 'services/market');
    assert.ok(git(market, 'config', '--get', 'remote.origin.url').includes(token));
    const { code, json } = cliJson(root, ['init', '--fix-remotes']);
    assert.strictEqual(code, 0);
    assert.strictEqual(git(market, 'config', '--get', 'remote.origin.url'), 'https://github.com/acme/tcx-market.git');
    assert.deepStrictEqual(json.remoteFixes.map((f) => [f.path, f.applied]), [['services/market', true]]);
  });

  it('refuses an invalid existing manifest and bad flags', (t) => {
    const { root } = makeTcxWorkspace(t);
    fs.writeFileSync(path.join(root, 'adf-workspace.json'), '{ "version": 2 }');
    assert.strictEqual(cli(root, ['init']).code, 1);
    fs.rmSync(path.join(root, 'adf-workspace.json'));
    assert.strictEqual(cli(root, ['init', '--client', 'Not Valid']).code, 2);
  });

  it('skips a nested repo whose directory cannot become a member name', (t) => {
    const { root } = makeTcxWorkspace(t);
    fs.mkdirSync(path.join(root, 'services/bad name'), { recursive: true });
    git(path.join(root, 'services/bad name'), 'init', '--quiet');
    const { code, json } = cliJson(root, ['init']);
    assert.strictEqual(code, 0);
    assert.ok(json.notes.some((n) => n.startsWith('services/bad name')));
    assert.ok(!readJson(root, 'adf-workspace.json').members.some((m) => m.path.includes(' ')));
  });
});

describe('workspace init: monorepo mode', () => {
  it('writes only the seeded map and the contracts policy', (t) => {
    const { root } = makePolyglotMonorepo(t);
    const { code, json } = cliJson(root, ['init']);
    assert.strictEqual(code, 0);
    assert.strictEqual(json.mode, 'monorepo');
    assert.deepStrictEqual(json.outputs, [{ path: 'docs/architecture/system-map.json', status: 'written' }, { path: 'docs/conventions/contracts.md', status: 'written' }]);
    for (const rel of ['adf-workspace.json', '.gitignore', '.ignore', 'bootstrap.sh']) assert.ok(!fs.existsSync(path.join(root, rel)), rel);
    assert.deepStrictEqual(git(root, 'status', '--porcelain'), '?? docs/');
    assert.deepStrictEqual(cliJson(root, ['init']).json.outputs, [{ path: 'docs/architecture/system-map.json', status: 'kept' }, { path: 'docs/conventions/contracts.md', status: 'kept' }]);
  });
});
