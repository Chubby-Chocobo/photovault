#!/usr/bin/env node
/**
 * Tests for contract-drift.cjs
 * Run: node --test .claude/hooks/lib/__tests__/contract-drift.test.cjs
 */

'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { initializedWorkspace, editManifest, git } = require('../../../skills/workspace/scripts/tests/workspace-test-helpers.cjs');
const { loadManifest } = require('../workspace-manifest.cjs');
const { loadSystemMap } = require('../system-map.cjs');
const { computeDrift, summarizeDrift, countFindings } = require('../contract-drift.cjs');
const { readMap, writeMap, writeFile, scopeMonorepo } = require('./scope-test-fixtures.cjs');

function drift(root, opts = {}) {
  const { manifest } = loadManifest(root);
  const { map } = loadSystemMap(root, 'docs', { manifest });
  return computeDrift({ root, map, manifest, ...opts });
}
const types = (findings) => findings.map((f) => f.type);
const other = (result, name) => result.otherGitDeps.find((g) => g.repo.endsWith(`/${name}`));

describe('workspace drift', () => {
  it('reports three distinct tcx-proto pins, none at the local HEAD, each with the HEAD date', (t) => {
    const ws = initializedWorkspace(t);
    const [proto] = drift(ws.root).contracts;
    assert.strictEqual(proto.id, 'tcx-proto');
    assert.strictEqual(proto.path, 'contracts/tcx-proto');
    assert.deepStrictEqual(proto.consumers.map((c) => [c.component, c.ref, c.pinFile]), [
      ['core', ws.protoCommits[0], 'services/core/.gitmodules'],
      ['gateway', ws.protoCommits[2], 'services/gateway/.gitmodules'],
      ['order', ws.protoCommits[1], 'services/order/.gitmodules'],
    ]);
    assert.strictEqual(proto.head.sha, ws.protoCommits[3]);
    assert.strictEqual(types(proto.findings).filter((f) => f === 'differs').length, 1);
    const stale = proto.findings.filter((f) => f.type === 'not-at-local-head');
    assert.strictEqual(stale.length, 3);
    assert.ok(stale.every((f) => f.headSha === ws.protoCommits[3] && /^\d{4}-\d\d-\d\dT/.test(f.headDate)));
  });

  it('finds the Cargo tag spread as differs and both unpinned npm deps in otherGitDeps', (t) => {
    const result = drift(initializedWorkspace(t).root);
    const vdax = other(result, 'vdax-libs');
    assert.deepStrictEqual(vdax.consumers.map((c) => [c.component, c.ref]), [['market', 'v1.0.110.2'], ['trading', 'v1.0.109.1']]);
    assert.deepStrictEqual(types(vdax.findings), ['differs']);
    assert.deepStrictEqual(other(result, 'wormhole-sdk').findings, [{ type: 'unpinned', component: 'admin-web', reason: 'branch' }]);
    assert.deepStrictEqual(other(result, 'ui-kit').findings, [{ type: 'unpinned', component: 'admin-web', reason: 'none' }]);
    assert.deepStrictEqual(other(result, 'charts').findings, []);
    assert.strictEqual(countFindings(result, 'unpinned'), 2);
    assert.strictEqual(result.truncated, false);
  });

  it('flags a pin the map does not list as unmapped-consumer', (t) => {
    const ws = initializedWorkspace(t);
    const map = readMap(ws.root);
    map.components.find((c) => c.name === 'gateway').consumes = [];
    writeMap(ws.root, map);
    const [proto] = drift(ws.root).contracts;
    assert.deepStrictEqual(proto.findings.filter((f) => f.type === 'unmapped-consumer'), [{ type: 'unmapped-consumer', component: 'gateway' }]);
    assert.strictEqual(proto.consumers.length, 3);
  });

  it('reports a manifest member that is not cloned as member-missing and its consumer as not cloned', (t) => {
    const ws = initializedWorkspace(t);
    editManifest(ws.root, (m) => m.members.push({ name: 'mobile', path: 'apps/mobile', branch: 'main', git: { flow: 'off', enforcement: 'ask', mainBranch: 'main' } }));
    const map = readMap(ws.root);
    map.components.push({ name: 'mobile', member: 'mobile', role: 'mobile', consumes: ['tcx-proto'] });
    writeMap(ws.root, map);
    const result = drift(ws.root);
    assert.deepStrictEqual(result.missingMembers, [{ name: 'mobile', path: 'apps/mobile', reason: 'not cloned' }]);
    const row = result.contracts[0].consumers.find((c) => c.component === 'mobile');
    assert.deepStrictEqual([row.note, row.pinFile, row.ref], ['member not cloned', null, null]);
  });

  it('says a symlinked member is not a plain clone, and a plain directory is not a repository', (t) => {
    const ws = initializedWorkspace(t);
    editManifest(ws.root, (m) => m.members.push(
      { name: 'linked', path: 'apps/linked', branch: 'main', git: { flow: 'off', enforcement: 'ask', mainBranch: 'main' } },
      { name: 'plain', path: 'apps/plain', branch: 'main', git: { flow: 'off', enforcement: 'ask', mainBranch: 'main' } },
    ));
    fs.symlinkSync(ws.members.core, path.join(ws.root, 'apps/linked'));
    fs.mkdirSync(path.join(ws.root, 'apps/plain'));
    const map = readMap(ws.root);
    map.components.push({ name: 'linked', member: 'linked', role: 'frontend', consumes: ['tcx-proto'] });
    writeMap(ws.root, map);
    const result = drift(ws.root);
    assert.deepStrictEqual(result.missingMembers.map((m) => [m.name, m.reason]), [['linked', 'not a plain clone (symlink)'], ['plain', 'not a git repository']]);
    assert.strictEqual(result.contracts[0].consumers.find((c) => c.component === 'linked').note, 'member not a plain clone (symlink)');
    assert.ok(!result.contracts[0].consumers.some((c) => c.pinFile && c.pinFile.startsWith('apps/linked')));
  });

  it('derives the contract repo from the manifest, so changing it there changes the report', (t) => {
    const ws = initializedWorkspace(t);
    assert.strictEqual(drift(ws.root).contracts[0].repo, 'https://github.com/acme/tcx-proto.git');
    editManifest(ws.root, (m) => { m.members.find((x) => x.name === 'tcx-proto').repo = 'https://github.com/acme/renamed-proto.git'; });
    const [proto] = drift(ws.root).contracts;
    assert.strictEqual(proto.repo, 'https://github.com/acme/renamed-proto.git');
    assert.ok(proto.consumers.every((c) => c.note === 'no pin found'));
    assert.ok(!fs.readFileSync(path.join(ws.root, 'docs/architecture/system-map.json'), 'utf8').includes('renamed-proto'));
  });

  it('never lets the runtime token into the result, and flags the credential', (t) => {
    const ws = initializedWorkspace(t, { credentialUrl: true });
    const result = drift(ws.root);
    assert.ok(ws.token);
    assert.ok(!JSON.stringify(result).includes(ws.token));
    assert.ok(!JSON.stringify(result).includes('ghp_'));
    assert.deepStrictEqual(other(result, 'vdax-libs').findings.filter((f) => f.type === 'credential-in-url'), [{ type: 'credential-in-url', component: 'market', source: 'cargo' }]);
    assert.ok(!summarizeDrift(result).includes('ghp_'));
  });

  it('stops reading at the budget and says so', (t) => {
    const ws = initializedWorkspace(t);
    const result = drift(ws.root, { budgetMs: 0 });
    assert.strictEqual(result.truncated, true);
    assert.deepStrictEqual(result.otherGitDeps, []);
    assert.ok(result.contracts[0].consumers.every((c) => c.note === 'not read (over budget)'));
  });

  it('lists a malformed Cargo.toml as unreadable by file and line, not content', (t) => {
    const ws = initializedWorkspace(t);
    fs.writeFileSync(path.join(ws.members.trading, 'Cargo.toml'), '[dependencies]\nfoo = { git = "https://github.com/acme/foo"\n');
    const result = drift(ws.root);
    assert.deepStrictEqual(result.unreadable, [{ path: 'services/trading/Cargo.toml', line: 2 }]);
    assert.strictEqual(other(result, 'vdax-libs').consumers.length, 1);
  });

  it('works without a system map: members are read, nothing is a declared contract', (t) => {
    const ws = initializedWorkspace(t);
    fs.rmSync(path.join(ws.root, 'docs/architecture/system-map.json'));
    const result = drift(ws.root);
    assert.deepStrictEqual(result.contracts, []);
    assert.ok(other(result, 'tcx-proto').consumers.length === 3);
  });
});

describe('summary line', () => {
  it('names the split contract, the unpinned count and nothing else', (t) => {
    const line = summarizeDrift(drift(initializedWorkspace(t).root));
    assert.strictEqual(line, 'Contract drift: tcx-proto pinned at 3 commits across 3 consumers (none at local HEAD); 2 unpinned git dependencies. Details: /adf-brief or workspace.cjs drift');
  });

  it('is null when every consumer shares one pinned ref', (t) => {
    const ws = initializedWorkspace(t);
    for (const name of ['order', 'gateway', 'core']) {
      git(ws.members[name], 'update-index', '--cacheinfo', `160000,${ws.protoCommits[3]},src/protos`);
      git(ws.members[name], 'commit', '--quiet', '-m', 'bump');
    }
    fs.writeFileSync(path.join(ws.members['admin-web'], 'package.json'), JSON.stringify({ name: 'admin-web', dependencies: { charts: 'github:acme/charts#v1.2.0' } }));
    fs.writeFileSync(path.join(ws.members.trading, 'Cargo.toml'), '[dependencies]\nv = { git = "https://github.com/acme/vdax-libs", tag = "v1.0.110.2" }\n');
    const result = drift(ws.root);
    assert.deepStrictEqual(types(result.contracts[0].findings), []);
    assert.strictEqual(summarizeDrift(result), null);
  });
});

describe('monorepo drift', () => {
  it('reports no entries for an in-tree contract without a repo', (t) => {
    const { root } = scopeMonorepo(t);
    const { map } = loadSystemMap(root, 'docs');
    assert.deepStrictEqual(computeDrift({ root, map, manifest: null }), { contracts: [], otherGitDeps: [], missingMembers: [], unreadable: [], truncated: false });
  });

  it('compares pins of a contract with a repo and counts only in-org git dependencies', (t) => {
    const { root } = scopeMonorepo(t);
    const map = readMap(root);
    map.org = ['acme'];
    map.contracts[0].repo = 'https://github.com/acme/proto.git';
    writeMap(root, map);
    writeFile(root, 'services/order/package.json', JSON.stringify({ dependencies: { proto: 'github:acme/proto#main', kit: 'github:acme/kit', ext: 'github:elsewhere/ext' } }));
    writeFile(root, 'services/gateway/package.json', JSON.stringify({ dependencies: { proto: 'github:acme/proto#v1.0.0' } }));
    const result = computeDrift({ root, map: loadSystemMap(root, 'docs').map, manifest: null });
    const [proto] = result.contracts;
    assert.deepStrictEqual(types(proto.findings).sort(), ['differs', 'unpinned']);
    assert.deepStrictEqual(result.otherGitDeps.map((g) => g.repo), ['https://github.com/acme/kit']);
  });
});
