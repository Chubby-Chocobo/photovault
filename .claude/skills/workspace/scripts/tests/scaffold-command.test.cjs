#!/usr/bin/env node
/**
 * Tests for `workspace scaffold`
 * Run: node --test .claude/skills/workspace/scripts/tests/scaffold-command.test.cjs
 */

'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { cli, cliJson, scaffoldWorkspace, trackedHashes } = require('./workspace-test-helpers.cjs');
const { withoutBlock } = require('../../../../hooks/lib/managed-text-block.cjs');
const { MARKERS, INSTALLER_MARKERS } = require('../../../../hooks/lib/member-context-block.cjs');
const { git } = require('./workspace-test-helpers.cjs');
const { commitFiles, preparedWorkspace, headsOf, runSync, rowOf } = require('./member-test-helpers.cjs');

const read = (root, rel) => fs.readFileSync(path.join(root, rel), 'utf8');
const lines = (text) => text.replace(/\n$/, '').split('\n').length;
const withoutSystemBlock = (text) => withoutBlock(text, MARKERS);
const statusOf = (json, file) => json.files.find((f) => f.path === file).status;

describe('scaffold: the TCX workspace', () => {
  it('writes services/order/AGENTS.md for its stack, 30-80 lines before the block, no placeholder left', (t) => {
    const { root } = scaffoldWorkspace(t);
    const r = cliJson(root, ['scaffold']);
    assert.strictEqual(r.code, 0, JSON.stringify(r.json));
    assert.strictEqual(statusOf(r.json, 'services/order/AGENTS.md'), 'written');
    const text = withoutSystemBlock(read(root, 'services/order/AGENTS.md'));
    assert.ok(lines(text) >= 30 && lines(text) <= 80, `${lines(text)} lines`);
    assert.ok(!text.includes('{{'));
    assert.match(text, /^# order$/m);
    assert.match(text, /## NestJS notes/);
    assert.match(text, /^- none detected \(add the run, test and lint commands\)$/m);
    assert.match(text, /`docs\/architecture\/services\/order\.md`/);
    assert.match(text, /start from a plan in the workspace/);
    assert.ok(!/\]\(/.test(text), 'inline code paths, not links');
  });

  it('writes services/order/CLAUDE.md as a stub that imports AGENTS.md', (t) => {
    const { root } = scaffoldWorkspace(t);
    const r = cliJson(root, ['scaffold']);
    assert.strictEqual(statusOf(r.json, 'services/order/CLAUDE.md'), 'written');
    const text = read(root, 'services/order/CLAUDE.md');
    assert.strictEqual(text.split('\n')[0], '@AGENTS.md');
    assert.match(text, /Claude Code-only notes go below/);
    assert.ok(lines(text) <= 5 && !text.includes('{{'));
  });

  it('keeps the hand-written services/core/CLAUDE.md byte-identical', (t) => {
    const { root } = scaffoldWorkspace(t);
    const before = trackedHashes(path.join(root, 'services/core'));
    const r = cliJson(root, ['scaffold']);
    assert.strictEqual(statusOf(r.json, 'services/core/CLAUDE.md'), 'kept');
    assert.deepStrictEqual(trackedHashes(path.join(root, 'services/core')), before);
    assert.strictEqual(read(root, 'services/core/CLAUDE.md'), '# core\n\nHand-written notes for the core service.\n');
  });

  it('skips apps/mobile as not cloned but still writes its service doc', (t) => {
    const { root } = scaffoldWorkspace(t);
    const r = cliJson(root, ['scaffold']);
    const skipped = r.json.files.find((f) => f.path === 'apps/mobile/CLAUDE.md');
    assert.deepStrictEqual([skipped.status, skipped.reason], ['skipped', 'not cloned']);
    assert.ok(!fs.existsSync(path.join(root, 'apps/mobile')), 'the missing member dir is not created');
    assert.match(read(root, 'docs/architecture/services/mobile.md'), /Stack: react-native/);
  });

  it('writes docs/architecture/services/order.md with calls, callers and contracts', (t) => {
    const { root } = scaffoldWorkspace(t);
    cli(root, ['scaffold']);
    const doc = read(root, 'docs/architecture/services/order.md');
    assert.ok(!doc.includes('{{'));
    const section = (heading) => new RegExp(`${heading}:\\n\\n((?:- .*\\n?)+)`).exec(doc)[1];
    assert.match(section('Calls'), /`matching-engine` \(grpc\)/);
    assert.match(section('Calls'), /`market` \(kafka, topic orders\)/);
    assert.match(section('Called by'), /`gateway` \(rest\)/);
    assert.match(section('Contracts consumed'), /`tcx-proto` \(proto\)/);
    assert.match(section('Contracts produced'), /`tcx-proto` \(proto\)/);
    for (const heading of ['Purpose', 'Role and stack', 'Interfaces', 'Data stores', 'Run and deploy', 'Owners', 'Decisions']) assert.match(doc, new RegExp(`^## ${heading}$`, 'm'));
    assert.match(read(root, 'docs/architecture/services/matching-engine.md'), /Called by:\n\n- `order` \(grpc\)/);
    assert.match(read(root, 'docs/architecture/services/gateway.md'), /Contracts produced:\n\n- none/);
  });

  it('puts the right commands in each stack template', (t) => {
    const { root } = scaffoldWorkspace(t);
    fs.writeFileSync(path.join(root, 'services/order/pnpm-lock.yaml'), '');
    fs.writeFileSync(path.join(root, 'services/order/package.json'), JSON.stringify({ name: 'order', dependencies: { '@nestjs/core': '1' }, scripts: { 'start:dev': 'x', test: 'x' } }));
    cli(root, ['scaffold']);
    const order = read(root, 'services/order/AGENTS.md');
    assert.match(order, /- Run: `pnpm run start:dev`/);
    assert.match(order, /- Test: `pnpm run test`/);
    assert.match(order, /- `dist\/`/);
    assert.match(read(root, 'services/matching-engine/AGENTS.md'), /- Test: `mvn test`[\s\S]*- `target\/`/);
    assert.match(read(root, 'services/matching-engine/AGENTS.md'), /## Maven notes/);
    assert.match(read(root, 'apps/admin-web/AGENTS.md'), /## Vue notes/);
  });

  it('renders the generic template for an unknown stack', (t) => {
    const { root } = scaffoldWorkspace(t);
    cli(root, ['scaffold']);
    const text = read(root, 'services/trading/AGENTS.md');
    assert.match(text, /## Stack notes/);
    assert.match(text, /stack: unknown/);
    assert.ok(lines(withoutSystemBlock(text)) >= 30 && lines(withoutSystemBlock(text)) <= 80);
    assert.doesNotMatch(text, /NestJS|Maven/);
  });

  it('--dry-run writes nothing and shows paths with the first lines', (t) => {
    const { root } = scaffoldWorkspace(t);
    const before = trackedHashes(root);
    const r = cliJson(root, ['scaffold', '--dry-run']);
    assert.strictEqual(r.code, 0);
    assert.strictEqual(r.json.dryRun, true);
    const order = r.json.files.find((f) => f.path === 'services/order/AGENTS.md');
    assert.strictEqual(order.status, 'would-write');
    assert.strictEqual(order.preview[0], '# order');
    assert.strictEqual(order.content, undefined);
    assert.strictEqual(order.abs, undefined);
    assert.ok(!fs.existsSync(path.join(root, 'services/order/AGENTS.md')));
    assert.ok(!fs.existsSync(path.join(root, 'services/order/CLAUDE.md')));
    assert.ok(!fs.existsSync(path.join(root, 'docs/architecture/services')));
    assert.deepStrictEqual(trackedHashes(root), before);
    const text = cli(root, ['scaffold', '--dry-run']).out;
    assert.match(text, /would-write services\/order\/AGENTS\.md\n {4}# order/);
  });

  it('without --yes it only plans and exits 2', (t) => {
    const { root } = scaffoldWorkspace(t);
    const r = cliJson(root, ['scaffold'], { raw: true });
    assert.strictEqual(r.code, 2);
    assert.strictEqual(r.json.needsYes, true);
    assert.ok(r.json.planned.files.some((f) => f.status === 'would-write'));
    assert.ok(!fs.existsSync(path.join(root, 'services/order/CLAUDE.md')));
    assert.ok(!fs.existsSync(path.join(root, 'services/order/AGENTS.md')));
  });

  it('a second run reports everything kept and changes nothing', (t) => {
    const { root } = scaffoldWorkspace(t);
    cli(root, ['scaffold']);
    const after = Object.fromEntries(['services/order/CLAUDE.md', 'services/order/AGENTS.md', 'docs/architecture/services/order.md'].map((f) => [f, read(root, f)]));
    const again = cliJson(root, ['scaffold']);
    assert.strictEqual(again.code, 0);
    assert.deepStrictEqual([...new Set(again.json.files.filter((f) => f.status !== 'skipped').map((f) => f.status))], ['kept']);
    for (const [f, text] of Object.entries(after)) assert.strictEqual(read(root, f), text);
  });

  it('never edits a service doc people have changed, and creates no docs/ inside a member', (t) => {
    const { root } = scaffoldWorkspace(t);
    fs.mkdirSync(path.join(root, 'docs/architecture/services'), { recursive: true });
    fs.writeFileSync(path.join(root, 'docs/architecture/services/order.md'), 'mine\n');
    const r = cliJson(root, ['scaffold']);
    assert.strictEqual(statusOf(r.json, 'docs/architecture/services/order.md'), 'kept');
    assert.strictEqual(read(root, 'docs/architecture/services/order.md'), 'mine\n');
    for (const dir of ['order', 'core', 'gateway', 'matching-engine', 'market', 'trading'].map((n) => path.join(root, 'services', n))) {
      assert.ok(!fs.existsSync(path.join(dir, 'docs')), `${dir} got a docs folder`);
    }
  });

  it('--only and a component name narrow the run', (t) => {
    const { root } = scaffoldWorkspace(t);
    const only = cliJson(root, ['scaffold', 'order', '--only', 'claude-md']);
    assert.deepStrictEqual(only.json.files.map((f) => f.path), ['services/order/CLAUDE.md']);
    assert.ok(!fs.existsSync(path.join(root, 'docs/architecture/services')));
    const docs = cliJson(root, ['scaffold', '--only', 'service-docs']);
    assert.ok(docs.json.files.every((f) => f.kind === 'service-doc'));
    assert.ok(!fs.existsSync(path.join(root, 'services/gateway/CLAUDE.md')));
  });
});

describe('scaffold: AGENTS.md and the system-context block', () => {
  const blockIn = (text) => /<!-- adf:system-context v=2 source=\S+ hash=[0-9a-f]{16} -->/.test(text);

  it('a component with no instruction file gets the starter and the block in AGENTS.md, and CLAUDE.md imports it', (t) => {
    const { root } = scaffoldWorkspace(t);
    cli(root, ['scaffold']);
    const agents = read(root, 'services/order/AGENTS.md');
    assert.match(agents, /^# order$/m);
    assert.ok(blockIn(agents));
    assert.match(agents, /- PR base: run `node .claude\/skills\/git\/scripts\/git-flow.cjs status --cwd services\/order` from the workspace repo/);
    assert.match(agents, /Workspace repo: `https:\/\/github.com\/acme\/tcx-workspace`/);
    assert.ok(read(root, 'services/order/CLAUDE.md').startsWith('@AGENTS.md\n'));
    assert.ok(!blockIn(read(root, 'services/order/CLAUDE.md')), 'the import stub holds no second block');
  });

  it('every block is current right after scaffold: sync writes only the marker (no "uncommitted changes" skip) and --check passes once it is committed', (t) => {
    const ws = scaffoldWorkspace(t);
    cli(ws.root, ['scaffold']);
    const heads = headsOf({ members: { order: ws.members.order } });
    const check = runSync(ws.root, { check: true, member: 'order' });
    const row = rowOf(check, 'order');
    assert.deepStrictEqual([row.block, row.agentsBlock], ['current', 'current']);
    assert.deepStrictEqual(row.files, ['services/order/.adf-workspace.json'], 'only the marker is missing');
    const synced = runSync(ws.root, { member: 'order' });
    assert.strictEqual(rowOf(synced, 'order').action, 'written');
    assert.deepStrictEqual(headsOf({ members: { order: ws.members.order } }), heads, 'neither scaffold nor sync commits');
    commitFiles(ws.members.order, ['CLAUDE.md', 'AGENTS.md', '.adf-workspace.json']);
    assert.strictEqual(runSync(ws.root, { check: true, member: 'order' }).code, 0);
  });

  it('--only agents-md on a component with only a CLAUDE.md writes a pointer stub with a current block and leaves CLAUDE.md alone', (t) => {
    const ws = preparedWorkspace(t);
    runSync(ws.root);
    for (const dir of Object.values(ws.members)) commitFiles(dir);
    // The state of a 1.2.4 workspace: blocks of the previous version, no AGENTS.md
    for (const name of ['order', 'gateway']) {
      const file = path.join(ws.members[name], 'CLAUDE.md');
      fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replace('adf:system-context v=2', 'adf:system-context v=1'));
      commitFiles(ws.members[name]);
    }
    const claudeBefore = read(ws.members.order, 'CLAUDE.md');
    const r = cliJson(ws.root, ['scaffold', '--only', 'agents-md']);
    assert.strictEqual(r.code, 0, JSON.stringify(r.json));
    assert.deepStrictEqual([...new Set(r.json.files.map((f) => f.kind))], ['agents-md']);
    assert.strictEqual(statusOf(r.json, 'services/order/AGENTS.md'), 'written');
    const stub = read(ws.members.order, 'AGENTS.md');
    assert.match(stub, /^# order\n\nComponent notes are in `CLAUDE.md` in this folder \(plain Markdown\)\.\n/);
    assert.ok(blockIn(stub));
    assert.strictEqual(read(ws.members.order, 'CLAUDE.md'), claudeBefore);
    const check = runSync(ws.root, { check: true });
    assert.strictEqual(check.code, 0, check.text);
    const row = rowOf(check, 'order');
    assert.deepStrictEqual([row.block, row.agentsBlock], ['outdated', 'current']);
    assert.ok(check.result.rows.every((x) => x.reason !== 'uncommitted changes'), 'a new untracked AGENTS.md is not a reason to skip');
  });

  it('--only agents-md on a component with neither file writes the starter and the block, and no CLAUDE.md', (t) => {
    const { root } = scaffoldWorkspace(t);
    const r = cliJson(root, ['scaffold', 'order', '--only', 'agents-md']);
    assert.deepStrictEqual(r.json.files.map((f) => f.path), ['services/order/AGENTS.md']);
    assert.match(read(root, 'services/order/AGENTS.md'), /## NestJS notes/);
    assert.ok(!fs.existsSync(path.join(root, 'services/order/CLAUDE.md')));
  });

  it('--only claude-md imports an AGENTS.md without installer markers, and writes the full starter otherwise', (t) => {
    const { root } = scaffoldWorkspace(t);
    fs.writeFileSync(path.join(root, 'services/order/AGENTS.md'), '# order rules\n');
    fs.writeFileSync(path.join(root, 'services/gateway/AGENTS.md'), `# gateway\n\n${INSTALLER_MARKERS.begin}\nADF rules\n${INSTALLER_MARKERS.end}\n`);
    cli(root, ['scaffold', '--only', 'claude-md']);
    assert.ok(read(root, 'services/order/CLAUDE.md').startsWith('@AGENTS.md\n'));
    const gateway = read(root, 'services/gateway/CLAUDE.md');
    assert.ok(!gateway.includes('@AGENTS.md') && /## NestJS notes/.test(gateway), 'a full starter, so Claude does not import the installer block');
    assert.match(read(root, 'services/market/CLAUDE.md'), /^# market$/m, 'no AGENTS.md at all: the full starter, as before');
    assert.strictEqual(read(root, 'services/order/AGENTS.md'), '# order rules\n', 'AGENTS.md is never touched');
  });

  it('keeps an AGENTS.md and a CLAUDE.md that exist, byte for byte', (t) => {
    const { root } = scaffoldWorkspace(t);
    fs.writeFileSync(path.join(root, 'services/order/AGENTS.md'), '# mine\n');
    fs.writeFileSync(path.join(root, 'services/order/CLAUDE.md'), '# also mine\n');
    const r = cliJson(root, ['scaffold']);
    assert.deepStrictEqual([statusOf(r.json, 'services/order/AGENTS.md'), statusOf(r.json, 'services/order/CLAUDE.md')], ['kept', 'kept']);
    assert.deepStrictEqual([read(root, 'services/order/AGENTS.md'), read(root, 'services/order/CLAUDE.md')], ['# mine\n', '# also mine\n']);
  });
});
