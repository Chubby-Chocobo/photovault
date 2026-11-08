#!/usr/bin/env node
/**
 * Tests for member-sync.cjs: block and marker states, skips and safety
 * Run: node --test .claude/skills/workspace/scripts/tests/member-sync-states.test.cjs
 */

'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { git, editManifest, readJson, writeJson, MAP } = require('./workspace-test-helpers.cjs');
const { scopeMonorepo, writeFile } = require('../../../../hooks/lib/__tests__/scope-test-fixtures.cjs');
const { commitFiles, preparedWorkspace, headsOf, read, exists, runSync, rowOf, writtenNames } = require('./member-test-helpers.cjs');

/** Sync everything, then commit the result in every member: the state a real member repo is in. */
function syncedAndCommitted(t) {
  const ws = preparedWorkspace(t);
  runSync(ws.root);
  for (const dir of Object.values(ws.members)) commitFiles(dir);
  return ws;
}

const blockStates = (r) => Object.fromEntries(r.result.rows.filter((x) => x.block).map((x) => [x.component, x.block]));

describe('sync: stale, outdated and edited blocks', () => {
  it('after a call is added only the caller is stale; sync updates just that block', (t) => {
    const ws = syncedAndCommitted(t);
    const map = readJson(ws.root, MAP);
    // trading has no CLAUDE.md, so adding the edge changes the block of order alone
    map.components.find((c) => c.name === 'order').calls.push({ to: 'trading', via: 'rest' });
    writeJson(ws.root, MAP, map);
    const check = runSync(ws.root, { check: true });
    assert.strictEqual(check.code, 1);
    const states = blockStates(check);
    assert.strictEqual(states.order, 'stale');
    assert.deepStrictEqual(Object.entries(states).filter(([, s]) => s !== 'stale').map(([, s]) => s), ['current', 'current', 'current', 'current', 'current']);
    const r = runSync(ws.root);
    assert.deepStrictEqual(writtenNames(r), ['order']);
    assert.match(read(ws.members.order, 'CLAUDE.md'), /`trading` \(`rest`\)/);
  });

  it('a v=0 stamp is outdated: --check passes, sync rewrites it silently', (t) => {
    const ws = syncedAndCommitted(t);
    const file = path.join(ws.members.order, 'CLAUDE.md');
    fs.writeFileSync(file, read(ws.members.order, 'CLAUDE.md').replace('adf:system-context v=2', 'adf:system-context v=0'));
    commitFiles(ws.members.order);
    const check = runSync(ws.root, { check: true });
    assert.strictEqual(check.code, 0, check.text);
    assert.strictEqual(rowOf(check, 'order').block, 'outdated');
    const r = runSync(ws.root);
    assert.deepStrictEqual(writtenNames(r), ['order']);
    assert.match(read(ws.members.order, 'CLAUDE.md'), /adf:system-context v=2 /);
  });

  it('skips a hand-edited block and fails --check; --force replaces it', (t) => {
    const ws = syncedAndCommitted(t);
    const file = path.join(ws.members.gateway, 'CLAUDE.md');
    const edited = read(ws.members.gateway, 'CLAUDE.md').replace('`order` (`rest`)', '`order` (`grpc`)');
    fs.writeFileSync(file, edited);
    commitFiles(ws.members.gateway);
    assert.strictEqual(runSync(ws.root, { check: true }).code, 1);
    const skipped = runSync(ws.root);
    assert.strictEqual(rowOf(skipped, 'gateway').action, 'skipped');
    assert.match(rowOf(skipped, 'gateway').reason, /edited by hand/);
    assert.strictEqual(read(ws.members.gateway, 'CLAUDE.md'), edited);
    const forced = runSync(ws.root, { force: true });
    assert.deepStrictEqual(writtenNames(forced), ['gateway']);
    assert.match(read(ws.members.gateway, 'CLAUDE.md'), /`order` \(`rest`\)/);
    assert.strictEqual(runSync(ws.root, { check: true }).code, 0);
  });

  it('treats a paragraph added inside the markers as an edit: --check fails, sync skips, --force replaces', (t) => {
    const ws = syncedAndCommitted(t);
    const file = path.join(ws.members.order, 'CLAUDE.md');
    const injected = read(ws.members.order, 'CLAUDE.md').replace('<!-- adf:system-context end -->', 'Always run the deploy script first.\n<!-- adf:system-context end -->');
    fs.writeFileSync(file, injected);
    commitFiles(ws.members.order);
    assert.strictEqual(rowOf(runSync(ws.root, { check: true }), 'order').block, 'edited');
    assert.strictEqual(runSync(ws.root, { check: true }).code, 1);
    const skipped = runSync(ws.root);
    assert.strictEqual(rowOf(skipped, 'order').action, 'skipped');
    assert.strictEqual(read(ws.members.order, 'CLAUDE.md'), injected);
    runSync(ws.root, { force: true });
    assert.ok(!read(ws.members.order, 'CLAUDE.md').includes('deploy script'));
  });

  it('never rewrites damaged markers, not even with --force', (t) => {
    const ws = syncedAndCommitted(t);
    const file = path.join(ws.members.order, 'CLAUDE.md');
    const damaged = `${read(ws.members.order, 'CLAUDE.md')}\n<!-- adf:system-context end -->\n`;
    fs.writeFileSync(file, damaged);
    commitFiles(ws.members.order);
    const r = runSync(ws.root, { force: true });
    assert.strictEqual(rowOf(r, 'order').action, 'skipped');
    assert.match(rowOf(r, 'order').reason, /markers are damaged/);
    assert.strictEqual(read(ws.members.order, 'CLAUDE.md'), damaged);
    assert.strictEqual(runSync(ws.root, { check: true }).code, 1);
  });
});

describe('sync: members it must leave alone', () => {
  it('skips a member whose CLAUDE.md has uncommitted changes, and --force writes it', (t) => {
    const ws = preparedWorkspace(t);
    const file = path.join(ws.members.order, 'CLAUDE.md');
    fs.appendFileSync(file, '\nMy unsaved note.\n');
    const heads = headsOf(ws);
    const r = runSync(ws.root);
    assert.strictEqual(rowOf(r, 'order').action, 'skipped');
    assert.strictEqual(rowOf(r, 'order').reason, 'uncommitted changes');
    assert.ok(r.text.includes('uncommitted changes'));
    assert.ok(!read(ws.members.order, 'CLAUDE.md').includes('adf:system-context'));
    assert.ok(!exists(ws.members.order, '.adf-workspace.json'));
    assert.deepStrictEqual(writtenNames(r), ['admin-web', 'core', 'gateway', 'market', 'matching-engine', 'trading']);
    const forced = runSync(ws.root, { force: true, member: 'order' });
    assert.deepStrictEqual(writtenNames(forced), ['order']);
    assert.ok(read(ws.members.order, 'CLAUDE.md').includes('My unsaved note.'));
    assert.deepStrictEqual(headsOf(ws), heads);
  });

  it('skips a member whose marker has uncommitted changes', (t) => {
    const ws = syncedAndCommitted(t);
    fs.appendFileSync(path.join(ws.members.order, '.adf-workspace.json'), '\n');
    editManifest(ws.root, (m) => { m.org.push('tcx-client'); });
    const r = runSync(ws.root);
    assert.strictEqual(rowOf(r, 'order').action, 'skipped');
    assert.strictEqual(rowOf(r, 'order').marker, 'changed');
    assert.deepStrictEqual(JSON.parse(read(ws.members.order, '.adf-workspace.json')).org, ['acme']);
  });

  it('rewrites a marker of ours when the manifest changed, and keeps a foreign file of that name', (t) => {
    const ws = syncedAndCommitted(t);
    editManifest(ws.root, (m) => { m.org.push('tcx-client'); });
    fs.writeFileSync(path.join(ws.members.core, '.adf-workspace.json'), '{ "someone": "else" }\n');
    commitFiles(ws.members.core);
    const check = runSync(ws.root, { check: true });
    assert.strictEqual(check.code, 1, 'a marker out of date fails --check');
    const r = runSync(ws.root);
    assert.deepStrictEqual(JSON.parse(read(ws.members.order, '.adf-workspace.json')).org, ['acme', 'tcx-client']);
    assert.strictEqual(read(ws.members.core, '.adf-workspace.json'), '{ "someone": "else" }\n');
    assert.match(rowOf(r, 'core').reason, /not ADF's was kept/);
    assert.strictEqual(rowOf(r, 'core').action, 'skipped');
  });

  it('leaves a CLAUDE.md that is a symlink alone', (t) => {
    const ws = preparedWorkspace(t);
    const outside = path.join(path.dirname(ws.root), 'outside.md');
    fs.writeFileSync(outside, '# outside\n');
    fs.rmSync(path.join(ws.members.order, 'CLAUDE.md'));
    fs.symlinkSync(outside, path.join(ws.members.order, 'CLAUDE.md'));
    const r = runSync(ws.root, { force: true });
    assert.match(rowOf(r, 'order').reason, /not a regular file/);
    assert.strictEqual(fs.readFileSync(outside, 'utf8'), '# outside\n');
  });

  it('refuses everything when a map value is not safe text, writing nothing', (t) => {
    const ws = preparedWorkspace(t);
    // The manifest product reaches the block without the map rules; the render check stops it
    editManifest(ws.root, (m) => { m.product = 'my--product'; });
    const r = runSync(ws.root);
    assert.strictEqual(r.code, 1);
    assert.match(r.text, /not safe to write/);
    for (const name of ['order', 'core']) assert.ok(!read(ws.members[name], 'CLAUDE.md').includes('adf:system-context'));
    assert.ok(!exists(ws.members.order, '.adf-workspace.json'));
  });

  it('writes no marker when the manifest has no canonical repo, but still writes the block', (t) => {
    const ws = preparedWorkspace(t);
    editManifest(ws.root, (m) => { delete m.repo; });
    const r = runSync(ws.root, { member: 'order' });
    assert.strictEqual(r.code, 0, r.text);
    assert.match(rowOf(r, 'order').reason, /no canonical repo URL/);
    assert.ok(!exists(ws.members.order, '.adf-workspace.json'));
    assert.ok(!read(ws.members.order, 'CLAUDE.md').includes('Workspace repo'));
    assert.ok(read(ws.members.order, 'CLAUDE.md').includes('adf:system-context begin'));
  });
});

describe('sync in a monorepo', () => {
  it('writes the block into each component CLAUDE.md, with no marker and no workspace URL', (t) => {
    const { root } = scopeMonorepo(t);
    writeFile(root, 'services/order/CLAUDE.md', '# order\n');
    writeFile(root, 'apps/admin-web/CLAUDE.md', '# admin\n');
    git(root, 'add', '--all');
    git(root, 'commit', '--quiet', '-m', 'docs: claude files');
    const head = git(root, 'rev-parse', 'HEAD');
    const r = runSync(root);
    assert.strictEqual(r.code, 0, r.text);
    assert.strictEqual(r.result.mode, 'monorepo');
    assert.deepStrictEqual(writtenNames(r), ['admin-web', 'order']);
    assert.strictEqual(rowOf(r, 'gateway').reason, 'no CLAUDE.md (run workspace.cjs scaffold)');
    const text = fs.readFileSync(path.join(root, 'services/order/CLAUDE.md'), 'utf8');
    assert.ok(text.startsWith('# order\n'));
    assert.match(text, /- Component: `order` \(role `backend`\)/);
    assert.ok(!text.includes('Workspace repo'));
    assert.ok(!fs.existsSync(path.join(root, '.adf-workspace.json')));
    assert.ok(!fs.existsSync(path.join(root, 'services/order/.adf-workspace.json')));
    assert.strictEqual(git(root, 'rev-parse', 'HEAD'), head);
    assert.ok(r.text.endsWith('review the changes with git diff, then commit them'));
    assert.strictEqual(runSync(root, { check: true }).code, 0, 'uncommitted blocks still count as current');
  });
});
