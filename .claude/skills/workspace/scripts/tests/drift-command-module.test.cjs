'use strict';

// The drift command's report, JSON and exit-code logic, called without the CLI wiring, plus one CLI smoke test.

const { describe, it, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { run } = require('../lib/drift-command.cjs');
const { initializedWorkspace, editManifest, git } = require('./workspace-test-helpers.cjs');

// A complete run refreshes the session cache in os.tmpdir(); keep this file's entries in a folder of its own
let tmp;
const originalTmp = process.env.TMPDIR;
before(() => { tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'adf-drift-module-tmp-')); process.env.TMPDIR = tmp; });
after(() => { process.env.TMPDIR = originalTmp; fs.rmSync(tmp, { recursive: true, force: true }); });

const go = (root, opts = {}) => run({ root, docsRel: 'docs', opts });

/** Resolve every finding: one pin everywhere, nothing unpinned. */
function resolveAll(ws) {
  for (const name of ['order', 'gateway', 'core']) {
    git(ws.members[name], 'update-index', '--cacheinfo', `160000,${ws.protoCommits[3]},src/protos`);
    git(ws.members[name], 'commit', '--quiet', '-m', 'bump');
  }
  fs.writeFileSync(path.join(ws.members['admin-web'], 'package.json'), JSON.stringify({ name: 'admin-web' }));
  fs.writeFileSync(path.join(ws.members.trading, 'Cargo.toml'), '[dependencies]\nv = { git = "https://github.com/acme/vdax-libs", tag = "v1.0.110.2" }\n');
}

describe('drift command module', () => {
  it('prints the consumer table, exits 0 by default and carries path, repo and pinFile in the JSON', (t) => {
    const ws = initializedWorkspace(t);
    const { code, text, result } = go(ws.root);
    assert.equal(code, 0);
    assert.match(text, /component\s+\| source\s+\| ref\s+\| pinned\s+\| at local HEAD/);
    assert.match(text, /core\s+\| submodule\s+\| \w{10}\s+\| yes\s+\| no/);
    assert.match(text, /findings: differs, not-at-local-head x3/);
    assert.match(text, /vdax-libs[\s\S]*v1\.0\.110\.2[\s\S]*v1\.0\.109\.1/);
    assert.match(text, /wormhole-sdk[\s\S]*no \(branch\)/);
    assert.match(text, /ui-kit[\s\S]*no \(none\)/);
    assert.deepEqual(
      [result.contracts[0].path, result.contracts[0].repo, result.contracts[0].consumers[0].pinFile],
      ['contracts/tcx-proto', 'https://github.com/acme/tcx-proto.git', 'services/core/.gitmodules'],
    );
    assert.equal(result.ok, true);
  });

  it('--fail-on exits 1 on a listed finding and 0 when none is listed', (t) => {
    const ws = initializedWorkspace(t);
    assert.equal(go(ws.root, { 'fail-on': 'unpinned' }).code, 1);
    assert.match(go(ws.root, { 'fail-on': 'unpinned,differs' }).text, /fail-on: found unpinned, differs \(exit 1\)/);
    assert.equal(go(ws.root, { 'fail-on': 'credential-in-url' }).code, 0);
    assert.equal(go(ws.root, { 'fail-on': 'bogus' }).code, 2);
  });

  it('a missing member fails --fail-on even when the listed findings are resolved, unless --allow-missing', (t) => {
    const ws = initializedWorkspace(t);
    resolveAll(ws);
    editManifest(ws.root, (m) => m.members.push({ name: 'mobile', path: 'apps/mobile', branch: 'main', git: { flow: 'off', enforcement: 'ask', mainBranch: 'main' } }));
    assert.equal(go(ws.root).code, 0);
    const strict = go(ws.root, { 'fail-on': 'differs' });
    assert.equal(strict.code, 1);
    assert.deepEqual(strict.result.failing, ['member-missing']);
    assert.match(strict.text, /member-missing \(not cloned, pins not read\): mobile \(apps\/mobile\)/);
    assert.equal(go(ws.root, { 'fail-on': 'differs', 'allow-missing': true }).code, 0);
  });

  it('is clean once every finding is resolved', (t) => {
    const ws = initializedWorkspace(t);
    resolveAll(ws);
    const { code, result } = go(ws.root, { 'fail-on': 'unpinned,differs,not-at-local-head' });
    assert.equal(code, 0);
    assert.deepEqual(result.failing, []);
  });

  it('reports a symlinked member by its reason', (t) => {
    const ws = initializedWorkspace(t);
    editManifest(ws.root, (m) => m.members.push({ name: 'linked', path: 'apps/linked', branch: 'main', git: { flow: 'off', enforcement: 'ask', mainBranch: 'main' } }));
    fs.symlinkSync(ws.members.core, path.join(ws.root, 'apps/linked'));
    const { text, result } = go(ws.root, { 'fail-on': 'differs', 'allow-missing': true });
    assert.match(text, /member-missing \(not a plain clone \(symlink\), pins not read\): linked \(apps\/linked\)/);
    assert.equal(result.missingMembers[0].reason, 'not a plain clone (symlink)');
  });

  it('never prints the runtime token, in text or JSON', (t) => {
    const ws = initializedWorkspace(t, { credentialUrl: true });
    const { text, result } = go(ws.root, { 'fail-on': 'credential-in-url' });
    assert.equal(result.failing[0], 'credential-in-url');
    assert.equal(text.includes(ws.token) || JSON.stringify(result).includes(ws.token), false);
    assert.equal(text.includes('ghp_') || JSON.stringify(result).includes('ghp_'), false);
  });

  it('fails clearly without a manifest or map, and with a broken manifest', (t) => {
    const ws = initializedWorkspace(t);
    fs.writeFileSync(path.join(ws.root, 'adf-workspace.json'), '{ nope');
    const broken = go(ws.root);
    assert.equal(broken.code, 1);
    assert.match(broken.text, /workspace\.cjs check/);
    fs.rmSync(path.join(ws.root, 'adf-workspace.json'));
    fs.rmSync(path.join(ws.root, 'docs/architecture/system-map.json'));
    assert.match(go(ws.root).text, /nothing to compare/);
  });
});

describe('drift command through the CLI', () => {
  it('prints exactly one JSON object, exits 0 and never prints the runtime token', (t) => {
    const ws = initializedWorkspace(t, { credentialUrl: true });
    editManifest(ws.root, (m) => m.members.push({ name: 'mobile', path: 'apps/mobile', branch: 'main', git: { flow: 'off', enforcement: 'ask', mainBranch: 'main' } }));
    const r = spawnSync(process.execPath, [path.join(__dirname, '..', 'workspace.cjs'), 'drift', '--json', '--cwd', ws.root], { encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.stdout.trim().split('\n').length, 1);
    assert.deepEqual(JSON.parse(r.stdout).missingMembers, [{ name: 'mobile', path: 'apps/mobile', reason: 'not cloned' }]);
    assert.equal(r.stdout.includes(ws.token) || r.stderr.includes(ws.token), false);
  });
});
