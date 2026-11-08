#!/usr/bin/env node
/**
 * Tests for member-sync.cjs: what sync writes and where
 * Run: node --test .claude/skills/workspace/scripts/tests/member-sync.test.cjs
 */

'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { git, trackedHashes, readJson } = require('./workspace-test-helpers.cjs');
const { run: reposRun } = require('../lib/repos-command.cjs');
const { runConfirmed } = require('../lib/member-sync.cjs');
const { withoutBlock } = require('../../../../hooks/lib/managed-text-block.cjs');
const { MARKERS } = require('../../../../hooks/lib/member-context-block.cjs');
const { commitFiles, preparedWorkspace, headsOf, read, exists, runSync, rowOf, writtenNames } = require('./member-test-helpers.cjs');

// Members with a CLAUDE.md get a block and a marker; trading has none and gets only its marker
const SYNCED = ['admin-web', 'core', 'gateway', 'market', 'matching-engine', 'order'];
const WRITTEN = [...SYNCED, 'trading'];

describe('sync in the TCX workspace', () => {
  it('writes a marker and a block into every cloned member that has a CLAUDE.md, and commits nothing', (t) => {
    const ws = preparedWorkspace(t);
    const before = headsOf(ws);
    const r = runSync(ws.root);
    assert.strictEqual(r.code, 0, r.text);
    assert.deepStrictEqual(writtenNames(r), WRITTEN);
    assert.deepStrictEqual(headsOf(ws), before, 'no member got a new commit');
    for (const name of SYNCED) {
      const dir = ws.members[name];
      assert.match(read(dir, 'CLAUDE.md'), /<!-- adf:system-context v=2 source=[0-9a-f]{12}(-dirty)? hash=[0-9a-f]{16} -->/);
      const marker = JSON.parse(read(dir, '.adf-workspace.json'));
      assert.strictEqual(marker.adf, 1);
      assert.strictEqual(marker.component, name);
      assert.strictEqual(marker.workspace, 'https://github.com/acme/tcx-workspace');
      assert.strictEqual(marker.host, 'github.com');
      assert.deepStrictEqual(marker.org, readJson(ws.root, 'adf-workspace.json').org, 'the marker org is the manifest org');
      assert.strictEqual(marker.product, 'tcx');
    }
    const order = read(ws.members.order, 'CLAUDE.md');
    assert.match(order, /- Calls: `market` \(`kafka`, topic `orders`\), `matching-engine` \(`grpc`\)/);
    assert.match(order, /- Called by \(derived\): `gateway` \(`rest`\)/);
    assert.match(order, /Workspace repo: `https:\/\/github.com\/acme\/tcx-workspace`/);
    assert.strictEqual(JSON.parse(read(ws.members.trading, '.adf-workspace.json')).component, 'trading', 'a member without CLAUDE.md still gets its marker');
    assert.ok(!exists(ws.members.trading, 'CLAUDE.md'));
  });

  it('ends with the repos --changed hint, and repos --changed lists exactly the members sync wrote', (t) => {
    const ws = preparedWorkspace(t);
    const r = runSync(ws.root);
    assert.ok(r.text.endsWith('run "node .claude/skills/workspace/scripts/workspace.cjs repos --changed" to see members to commit'), r.text);
    const changed = reposRun({ root: ws.root, docsRel: 'docs', opts: { _: ['repos'], changed: true } });
    assert.deepStrictEqual(changed.result.repos.map((x) => x.name).filter((n) => n !== 'workspace').sort(), WRITTEN);
  });

  it('lists every member in the table with the reason for each one it left alone', (t) => {
    const ws = preparedWorkspace(t);
    const r = runSync(ws.root);
    const manifest = readJson(ws.root, 'adf-workspace.json');
    for (const m of manifest.members) assert.ok(r.result.rows.some((x) => x.member === m.name), `${m.name} has a row`);
    assert.strictEqual(rowOf(r, 'mobile').reason, 'not cloned');
    assert.strictEqual(rowOf(r, 'trading').reason, 'no CLAUDE.md (run workspace.cjs scaffold)');
    assert.strictEqual(rowOf(r, 'tcx-proto').reason, 'no component in the system map');
    assert.ok(!exists(ws.members.trading, 'CLAUDE.md'), 'a missing CLAUDE.md is never created');
    for (const name of ['mobile', 'trading', 'tcx-proto', 'order']) assert.ok(r.text.includes(name), name);
  });

  it('keeps text outside the block, and every other file of services/core, byte-identical', (t) => {
    const ws = preparedWorkspace(t);
    const core = ws.members.core;
    const before = trackedHashes(core);
    const original = read(core, 'CLAUDE.md');
    runSync(ws.root);
    const after = trackedHashes(core);
    const { 'CLAUDE.md': changed, ...others } = after;
    const { 'CLAUDE.md': was, ...othersBefore } = before;
    assert.notStrictEqual(changed, was);
    assert.deepStrictEqual(others, othersBefore, '.cursor, plans and .claude/settings.json are untouched');
    assert.ok(read(core, 'CLAUDE.md').startsWith(original));
    assert.strictEqual(withoutBlock(read(core, 'CLAUDE.md'), MARKERS), original);
  });

  it('a second run changes nothing, committed or not', (t) => {
    const ws = preparedWorkspace(t);
    runSync(ws.root);
    const again = runSync(ws.root);
    assert.deepStrictEqual(writtenNames(again), []);
    assert.strictEqual(again.result.counts.unchanged, SYNCED.length);
    assert.ok(!again.text.includes('repos --changed'));
    for (const dir of Object.values(ws.members)) commitFiles(dir);
    assert.strictEqual(runSync(ws.root).result.counts.written, 0);
  });

  it('keeps CRLF line ends when the CLAUDE.md has them', (t) => {
    const ws = preparedWorkspace(t);
    const file = path.join(ws.members.order, 'CLAUDE.md');
    fs.writeFileSync(file, read(ws.members.order, 'CLAUDE.md').replace(/\n/g, '\r\n'));
    commitFiles(ws.members.order);
    runSync(ws.root, { member: 'order' });
    const text = fs.readFileSync(file, 'utf8');
    assert.ok(text.includes('adf:system-context begin'));
    assert.ok(!/(?<!\r)\n/.test(text), 'every line end is CRLF');
  });

  it('stamps the workspace commit as the source, with -dirty while the map has uncommitted changes', (t) => {
    const ws = preparedWorkspace(t);
    const dirty = runSync(ws.root, { 'dry-run': true });
    assert.match(dirty.result.source, /^[0-9a-f]{12}-dirty$/);
    git(ws.root, 'add', '--all');
    git(ws.root, 'commit', '--quiet', '-m', 'chore: init workspace');
    const clean = runSync(ws.root);
    assert.strictEqual(clean.result.source, git(ws.root, 'rev-parse', '--short=12', 'HEAD'));
    assert.match(read(ws.members.order, 'CLAUDE.md'), new RegExp(`source=${clean.result.source} `));
  });
});

describe('sync options', () => {
  it('--dry-run writes nothing, --check writes nothing and fails until the blocks exist', (t) => {
    const ws = preparedWorkspace(t);
    const hashes = Object.fromEntries(Object.entries(ws.members).map(([n, d]) => [n, trackedHashes(d)]));
    const dry = runSync(ws.root, { 'dry-run': true });
    assert.strictEqual(dry.code, 0);
    assert.strictEqual(dry.result.counts.wouldWrite, WRITTEN.length);
    assert.strictEqual(rowOf(dry, 'order').action, 'would-write');
    const check = runSync(ws.root, { check: true });
    assert.strictEqual(check.code, 1);
    for (const [n, d] of Object.entries(ws.members)) {
      assert.deepStrictEqual(trackedHashes(d), hashes[n]);
      assert.ok(!exists(d, '.adf-workspace.json'));
    }
    assert.strictEqual(runSync(ws.root).code, 0);
    const after = runSync(ws.root, { check: true });
    assert.strictEqual(after.code, 0, after.text);
  });

  it('--member limits the run to one member and rejects an unknown name', (t) => {
    const ws = preparedWorkspace(t);
    const r = runSync(ws.root, { member: 'gateway' });
    assert.deepStrictEqual(writtenNames(r), ['gateway']);
    assert.strictEqual(r.result.rows.length, 1);
    assert.ok(!exists(ws.members.order, '.adf-workspace.json'));
    const unknown = runSync(ws.root, { member: 'nope' });
    assert.strictEqual(unknown.code, 2);
    assert.match(unknown.text, /known: .*order/);
  });

  it('--from updates only the member that contains the project, found by its origin', (t) => {
    const ws = preparedWorkspace(t);
    const r = runSync(ws.members.order, { from: ws.root });
    assert.strictEqual(r.code, 0, r.text);
    assert.deepStrictEqual(writtenNames(r), ['order']);
    assert.strictEqual(JSON.parse(read(ws.members.order, '.adf-workspace.json')).component, 'order');
    assert.match(read(ws.members.order, 'CLAUDE.md'), /adf:system-context begin/);
    assert.ok(!exists(ws.members.gateway, '.adf-workspace.json'));
    commitFiles(ws.members.order);
    const again = runSync(ws.members.order, { from: ws.root });
    assert.strictEqual(again.result.counts.unchanged, 1, 'found by the marker the second time');
    assert.strictEqual(runSync(ws.members.order, { from: ws.root, member: 'order' }).code, 2);
    assert.strictEqual(runSync(ws.members.order, { from: ws.members.order }).code, 2);
    assert.strictEqual(runSync(ws.members.trading, { from: ws.root }).code, 0, 'trading has an origin in the manifest');
  });

  it('asks for --yes before writing, but not for --check or --dry-run', (t) => {
    const ws = preparedWorkspace(t);
    const gated = runConfirmed({ root: ws.root, docsRel: 'docs', opts: { _: ['sync'] } });
    assert.strictEqual(gated.code, 2);
    assert.ok(!exists(ws.members.order, '.adf-workspace.json'));
    assert.strictEqual(runConfirmed({ root: ws.root, docsRel: 'docs', opts: { _: ['sync'], check: true } }).code, 1);
    assert.strictEqual(runConfirmed({ root: ws.root, docsRel: 'docs', opts: { _: ['sync'], 'dry-run': true } }).code, 0);
    assert.strictEqual(runConfirmed({ root: ws.root, docsRel: 'docs', opts: { _: ['sync'], yes: true } }).code, 0);
    assert.ok(exists(ws.members.order, '.adf-workspace.json'));
  });

  it('rejects positional arguments and a project without a system map', (t) => {
    const ws = preparedWorkspace(t);
    assert.strictEqual(runSync(ws.root, { _: ['sync', 'order'] }).code, 2);
    fs.rmSync(path.join(ws.root, 'docs/architecture/system-map.json'));
    const r = runSync(ws.root);
    assert.strictEqual(r.code, 1);
    assert.match(r.text, /no system map/);
  });
});
