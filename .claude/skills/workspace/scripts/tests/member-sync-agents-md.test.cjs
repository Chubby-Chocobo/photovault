#!/usr/bin/env node
/**
 * Tests for member-sync.cjs with AGENTS.md: which file holds the block, the --check rule and the JSON rows
 * Run: node --test .claude/skills/workspace/scripts/tests/member-sync-agents-md.test.cjs
 */

'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { MARKERS, INSTALLER_MARKERS } = require('../../../../hooks/lib/member-context-block.cjs');
const { readBlock } = require('../../../../hooks/lib/managed-text-block.cjs');
const { readJson, writeJson, MAP } = require('./workspace-test-helpers.cjs');
const { buildWorkspaceContext } = require('../../../../hooks/lib/workspace-session-context.cjs');
const { commitFiles, preparedWorkspace, read, exists, runSync, rowOf, writtenNames } = require('./member-test-helpers.cjs');

const build = (root) => buildWorkspaceContext({ baseDir: root, config: { paths: { docs: 'docs', plans: 'plans' } }, shapeType: 'workspace', resolvedPlan: { path: null, resolvedBy: null }, cwd: root }).lines;
const contextLine = (lines) => lines.find((l) => l.startsWith('System context'));

const INSTALLER = `${INSTALLER_MARKERS.begin}\nADF rules\n${INSTALLER_MARKERS.end}\n`;
const hasBlock = (text) => readBlock(text, MARKERS).state === 'ok';
const FILES = ['CLAUDE.md', 'AGENTS.md', '.adf-workspace.json'];

/** Write a file in a member and commit it, so the next sync sees a clean tree. */
function put(dir, name, text) {
  fs.writeFileSync(path.join(dir, name), text);
  commitFiles(dir, FILES);
}

/** The prepared workspace after one sync, committed: every CLAUDE.md holds a current block. */
function syncedWorkspace(t) {
  const ws = preparedWorkspace(t);
  runSync(ws.root);
  for (const dir of Object.values(ws.members)) commitFiles(dir, FILES);
  return ws;
}

describe('sync --json rows', () => {
  const V124_KEYS = ['action', 'block', 'component', 'files', 'marker', 'member', 'path', 'reason'];
  const V124_BLOCKS = new Set([null, 'missing', 'current', 'stale', 'edited', 'outdated']);

  it('keeps every 1.2.4 key with its 1.2.4 value, adds only paths and agentsBlock, and never gives block a new value', (t) => {
    const ws = syncedWorkspace(t);
    put(ws.members.order, 'AGENTS.md', '# order\n');
    put(ws.members.order, 'CLAUDE.md', `@AGENTS.md\n\n${read(ws.members.order, 'CLAUDE.md')}`);
    put(ws.members.core, 'AGENTS.md', '# core\n');
    fs.rmSync(path.join(ws.members.gateway, 'CLAUDE.md'));
    put(ws.members.gateway, 'AGENTS.md', `${INSTALLER}`);
    const r = runSync(ws.root, { check: true });
    assert.deepStrictEqual(Object.keys(r.result).sort(), ['check', 'counts', 'dryRun', 'mode', 'ok', 'rows', 'source']);
    for (const row of r.result.rows) {
      const own = Object.keys(row).filter((k) => !['paths', 'agentsBlock'].includes(k)).sort();
      assert.deepStrictEqual(own, V124_KEYS, row.component);
      assert.ok(V124_BLOCKS.has(row.block), `${row.component}: ${row.block}`);
    }
    const order = rowOf(r, 'order');
    assert.strictEqual(order.path, 'services/order/CLAUDE.md', 'path is still the CLAUDE.md');
    assert.deepStrictEqual(order.paths, { claude: 'services/order/CLAUDE.md', agents: 'services/order/AGENTS.md' });
    assert.deepStrictEqual([order.block, order.agentsBlock], ['current', 'missing'], 'an import stub reports block current and the AGENTS.md state apart');
    assert.deepStrictEqual([rowOf(r, 'market').block, rowOf(r, 'market').agentsBlock], ['current', 'n/a']);
    assert.strictEqual(rowOf(r, 'mobile').agentsBlock, null);
  });
});

describe('sync: which file holds the block', () => {
  it('writes both blocks into a component that has both files, and never creates an AGENTS.md', (t) => {
    const ws = preparedWorkspace(t);
    put(ws.members.core, 'AGENTS.md', '# core\n');
    const r = runSync(ws.root);
    assert.deepStrictEqual(rowOf(r, 'core').files, ['services/core/CLAUDE.md', 'services/core/AGENTS.md', 'services/core/.adf-workspace.json']);
    assert.ok(hasBlock(read(ws.members.core, 'CLAUDE.md')) && hasBlock(read(ws.members.core, 'AGENTS.md')));
    assert.ok(read(ws.members.core, 'AGENTS.md').startsWith('# core\n'));
    assert.ok(!exists(ws.members.order, 'AGENTS.md'));
    assert.strictEqual(rowOf(r, 'order').agentsBlock, 'n/a');
    assert.strictEqual(runSync(ws.root, { check: true }).code, 0);
  });

  it('puts the block only in AGENTS.md when CLAUDE.md imports it, and removes one an earlier sync left in CLAUDE.md', (t) => {
    const ws = syncedWorkspace(t);
    const claude = read(ws.members.order, 'CLAUDE.md');
    put(ws.members.order, 'AGENTS.md', '# order\n');
    put(ws.members.order, 'CLAUDE.md', `@AGENTS.md\n\n${claude}`);
    const r = runSync(ws.root, { member: 'order' });
    assert.deepStrictEqual(rowOf(r, 'order').files, ['services/order/CLAUDE.md', 'services/order/AGENTS.md']);
    const after = read(ws.members.order, 'CLAUDE.md');
    assert.ok(!hasBlock(after), 'the old block is gone');
    assert.ok(after.startsWith('@AGENTS.md\n\n# order'), 'text outside the block is kept');
    assert.ok(hasBlock(read(ws.members.order, 'AGENTS.md')));
    commitFiles(ws.members.order, FILES);
    const check = runSync(ws.root, { check: true });
    assert.strictEqual(check.code, 0, check.text);
    assert.deepStrictEqual([rowOf(check, 'order').block, rowOf(check, 'order').agentsBlock], ['current', 'current']);
    assert.match(check.text, /current via AGENTS\.md/);
    assert.strictEqual(runSync(ws.root, { member: 'order' }).result.counts.unchanged, 1);
  });

  it('leaves a hand-edited block in an importing CLAUDE.md unless --force', (t) => {
    const ws = syncedWorkspace(t);
    const edited = read(ws.members.order, 'CLAUDE.md').replace('- Git:', '- Git: anything goes;');
    put(ws.members.order, 'AGENTS.md', '# order\n');
    put(ws.members.order, 'CLAUDE.md', `@AGENTS.md\n\n${edited}`);
    const skipped = runSync(ws.root, { member: 'order' });
    assert.strictEqual(rowOf(skipped, 'order').action, 'written', 'the AGENTS.md block is still written');
    assert.match(rowOf(skipped, 'order').reason, /edited by hand/);
    assert.ok(hasBlock(read(ws.members.order, 'CLAUDE.md')));
    commitFiles(ws.members.order, FILES);
    runSync(ws.root, { member: 'order', force: true });
    assert.ok(!hasBlock(read(ws.members.order, 'CLAUDE.md')));
  });

  it('reports a hand-edited or damaged block left in an importing CLAUDE.md as edited and fails --check, like 1.2.4 did without the import', (t) => {
    const ws = syncedWorkspace(t);
    const original = read(ws.members.order, 'CLAUDE.md');
    put(ws.members.order, 'AGENTS.md', '# order\n');
    runSync(ws.root, { member: 'order' });
    for (const [name, claude] of [
      ['edited', original.replace('- Safety: never', '- Safety: you may')],
      ['damaged', `${original}\n${MARKERS.end}\n`],
    ]) {
      put(ws.members.order, 'CLAUDE.md', `@AGENTS.md\n\n${claude}`);
      const check = runSync(ws.root, { check: true, member: 'order' });
      assert.strictEqual(check.code, 1, `${name}: ${check.text}`);
      assert.deepStrictEqual([rowOf(check, 'order').block, rowOf(check, 'order').agentsBlock], ['edited', 'current'], name);
      assert.strictEqual(contextLine(build(ws.root)), 'System context: 1 member block stale (order); run workspace.cjs sync', name);
      const skipped = runSync(ws.root, { member: 'order' });
      assert.strictEqual(rowOf(skipped, 'order').action, 'skipped', name);
      assert.ok(read(ws.members.order, 'CLAUDE.md').includes(claude.split('\n')[0]), 'nothing was removed without --force');
    }
    put(ws.members.order, 'CLAUDE.md', `@AGENTS.md\n\n${original.replace('- Safety: never', '- Safety: you may')}`);
    runSync(ws.root, { member: 'order', force: true });
    assert.ok(!hasBlock(read(ws.members.order, 'CLAUDE.md')));
    commitFiles(ws.members.order, FILES);
    assert.strictEqual(runSync(ws.root, { check: true, member: 'order' }).code, 0);
  });

  it('reports a stale block left in an importing CLAUDE.md and removes it', (t) => {
    const ws = syncedWorkspace(t);
    put(ws.members.order, 'AGENTS.md', '# order\n');
    runSync(ws.root, { member: 'order' });
    put(ws.members.order, 'CLAUDE.md', `@AGENTS.md\n\n${read(ws.members.order, 'CLAUDE.md')}`);
    const map = readJson(ws.root, MAP);
    map.components.find((c) => c.name === 'order').calls.push({ to: 'trading', via: 'rest' });
    writeJson(ws.root, MAP, map);
    assert.deepStrictEqual([rowOf(runSync(ws.root, { check: true, member: 'order' }), 'order').block, runSync(ws.root, { check: true, member: 'order' }).code], ['stale', 1]);
    runSync(ws.root, { member: 'order' });
    assert.ok(!hasBlock(read(ws.members.order, 'CLAUDE.md')));
    assert.ok(hasBlock(read(ws.members.order, 'AGENTS.md')));
  });

  it('does not read @AGENTS.md in a fenced code block as an import: both files keep their own block', (t) => {
    const ws = preparedWorkspace(t);
    put(ws.members.core, 'AGENTS.md', '# core\n');
    put(ws.members.core, 'CLAUDE.md', `${read(ws.members.core, 'CLAUDE.md')}\n\`\`\`\n@AGENTS.md\n\`\`\`\n`);
    runSync(ws.root, { member: 'core' });
    assert.ok(hasBlock(read(ws.members.core, 'CLAUDE.md')) && hasBlock(read(ws.members.core, 'AGENTS.md')));
  });

  it('reads @./AGENTS.md as an import too', (t) => {
    const ws = preparedWorkspace(t);
    put(ws.members.core, 'AGENTS.md', '# core\n');
    put(ws.members.core, 'CLAUDE.md', '@./AGENTS.md\n');
    runSync(ws.root, { member: 'core' });
    assert.ok(!hasBlock(read(ws.members.core, 'CLAUDE.md')));
    assert.ok(hasBlock(read(ws.members.core, 'AGENTS.md')));
  });

  it('gives a component that has only an AGENTS.md its block there, and --check fails until then', (t) => {
    const ws = syncedWorkspace(t);
    fs.rmSync(path.join(ws.members.gateway, 'CLAUDE.md'));
    put(ws.members.gateway, 'AGENTS.md', '# gateway\n');
    const check = runSync(ws.root, { check: true });
    assert.strictEqual(check.code, 1, check.text);
    assert.deepStrictEqual([rowOf(check, 'gateway').block, rowOf(check, 'gateway').agentsBlock], [null, 'missing']);
    runSync(ws.root, { member: 'gateway' });
    assert.ok(!exists(ws.members.gateway, 'CLAUDE.md'));
    assert.ok(hasBlock(read(ws.members.gateway, 'AGENTS.md')));
    commitFiles(ws.members.gateway, FILES);
    assert.strictEqual(runSync(ws.root, { check: true }).code, 0);
  });

  it('skips an AGENTS.md that is a symlink, reports it in agentsBlock and the text, and still gives the block to CLAUDE.md', (t) => {
    const ws = preparedWorkspace(t);
    fs.symlinkSync('CLAUDE.md', path.join(ws.members.core, 'AGENTS.md'));
    const r = runSync(ws.root, { member: 'core' });
    const row = rowOf(r, 'core');
    assert.deepStrictEqual([row.action, row.reason, row.agentsBlock], ['written', null, 'symlink']);
    assert.match(r.text, /AGENTS\.md is a symlink, skipped/);
    assert.strictEqual(read(ws.members.core, 'CLAUDE.md').split(MARKERS.begin).length, 2, 'one block, written once');
    assert.ok(fs.lstatSync(path.join(ws.members.core, 'AGENTS.md')).isSymbolicLink());
  });

  it('keeps a row unchanged, without a reason, when AGENTS.md is a symlink to a CLAUDE.md that is current; --check stays green', (t) => {
    const ws = syncedWorkspace(t);
    const before = runSync(ws.root, { check: true });
    fs.symlinkSync('CLAUDE.md', path.join(ws.members.core, 'AGENTS.md'));
    for (const flags of [{ check: true }, {}]) {
      const r = runSync(ws.root, flags);
      const row = rowOf(r, 'core');
      assert.deepStrictEqual([row.action, row.reason, row.block], ['unchanged', null, 'current'], JSON.stringify(flags));
      assert.strictEqual(row.agentsBlock, 'symlink');
      assert.strictEqual(r.code, 0, r.text);
      assert.deepStrictEqual(r.result.counts, before.result.counts);
    }
    const others = (r) => r.result.rows.filter((x) => x.component !== 'core').map(({ paths, agentsBlock, ...x }) => x);
    assert.deepStrictEqual(others(runSync(ws.root, { check: true })), others(before));
  });

  it('skips the row when AGENTS.md is a directory or too large', (t) => {
    const ws = preparedWorkspace(t);
    fs.mkdirSync(path.join(ws.members.core, 'AGENTS.md'));
    fs.writeFileSync(path.join(ws.members.order, 'AGENTS.md'), 'x'.repeat(1024 * 1024 + 1));
    const r = runSync(ws.root);
    for (const name of ['core', 'order']) {
      assert.deepStrictEqual([rowOf(r, name).action, rowOf(r, name).reason], ['skipped', 'AGENTS.md is not a regular file'], name);
    }
    assert.ok(!hasBlock(read(ws.members.core, 'CLAUDE.md')));
  });
});

describe('sync: text output and --from', () => {
  it('names the AGENTS.md state in the table, and says when --check left a block uncounted', (t) => {
    const ws = syncedWorkspace(t);
    fs.rmSync(path.join(ws.members.gateway, 'CLAUDE.md'));
    put(ws.members.gateway, 'AGENTS.md', `${INSTALLER}`);
    const r = runSync(ws.root, { check: true });
    assert.match(r.text, /^gateway +AGENTS\.md missing /m, 'no leading dash for a component without a CLAUDE.md');
    assert.strictEqual(r.code, 0, r.text);
    assert.match(r.text, /all blocks are current \(1 AGENTS\.md without a block are not counted/);
  });

  it('--from updates both files of the member that contains the project, and an importing CLAUDE.md gets none', (t) => {
    const ws = preparedWorkspace(t);
    put(ws.members.order, 'AGENTS.md', '# order\n');
    put(ws.members.core, 'AGENTS.md', '# core\n');
    put(ws.members.core, 'CLAUDE.md', `@AGENTS.md\n\n${read(ws.members.core, 'CLAUDE.md')}`);
    const order = runSync(ws.members.order, { from: ws.root });
    assert.strictEqual(order.code, 0, order.text);
    assert.deepStrictEqual(rowOf(order, 'order').files, ['CLAUDE.md', 'AGENTS.md', '.adf-workspace.json']);
    assert.ok(hasBlock(read(ws.members.order, 'CLAUDE.md')) && hasBlock(read(ws.members.order, 'AGENTS.md')));
    const core = runSync(ws.members.core, { from: ws.root });
    assert.deepStrictEqual(rowOf(core, 'core').files, ['AGENTS.md', '.adf-workspace.json']);
    assert.ok(!hasBlock(read(ws.members.core, 'CLAUDE.md')) && hasBlock(read(ws.members.core, 'AGENTS.md')));
    commitFiles(ws.members.core, FILES);
    assert.strictEqual(runSync(ws.members.core, { from: ws.root, check: true }).code, 0);
  });
});

describe('sync: dirty files and edited blocks', () => {
  it('skips the whole row when AGENTS.md has uncommitted changes, so CLAUDE.md is not written either', (t) => {
    const ws = preparedWorkspace(t);
    put(ws.members.core, 'AGENTS.md', '# core\n');
    fs.appendFileSync(path.join(ws.members.core, 'AGENTS.md'), 'unsaved\n');
    const r = runSync(ws.root, { member: 'core' });
    assert.deepStrictEqual([rowOf(r, 'core').action, rowOf(r, 'core').reason], ['skipped', 'uncommitted changes']);
    assert.ok(!hasBlock(read(ws.members.core, 'CLAUDE.md')));
    assert.deepStrictEqual(writtenNames(runSync(ws.root, { member: 'core', force: true })), ['core']);
    assert.ok(hasBlock(read(ws.members.core, 'AGENTS.md')) && read(ws.members.core, 'AGENTS.md').includes('unsaved'));
  });

  it('skips the whole row when CLAUDE.md has uncommitted changes and AGENTS.md would be written', (t) => {
    const ws = preparedWorkspace(t);
    put(ws.members.core, 'AGENTS.md', '# core\n');
    fs.appendFileSync(path.join(ws.members.core, 'CLAUDE.md'), 'unsaved\n');
    const r = runSync(ws.root, { member: 'core' });
    assert.strictEqual(rowOf(r, 'core').reason, 'uncommitted changes');
    assert.ok(!hasBlock(read(ws.members.core, 'AGENTS.md')));
  });

  it('a hand-edited AGENTS.md block fails --check, is skipped by sync and replaced by --force', (t) => {
    const ws = preparedWorkspace(t);
    put(ws.members.core, 'AGENTS.md', '# core\n');
    runSync(ws.root, { member: 'core' });
    commitFiles(ws.members.core, FILES);
    const edited = read(ws.members.core, 'AGENTS.md').replace('- Safety:', '- Safety: nothing is secret;');
    put(ws.members.core, 'AGENTS.md', edited);
    const check = runSync(ws.root, { check: true, member: 'core' });
    assert.strictEqual(check.code, 1);
    assert.strictEqual(rowOf(check, 'core').agentsBlock, 'edited');
    const skipped = runSync(ws.root, { member: 'core' });
    assert.strictEqual(rowOf(skipped, 'core').action, 'skipped');
    assert.match(rowOf(skipped, 'core').reason, /edited by hand/);
    assert.strictEqual(read(ws.members.core, 'AGENTS.md'), edited);
    runSync(ws.root, { member: 'core', force: true });
    assert.ok(!read(ws.members.core, 'AGENTS.md').includes('nothing is secret'));
  });

  it('a block of the previous version in AGENTS.md is outdated: --check passes, sync rewrites it', (t) => {
    const ws = preparedWorkspace(t);
    put(ws.members.core, 'AGENTS.md', '# core\n');
    runSync(ws.root, { member: 'core' });
    put(ws.members.core, 'AGENTS.md', read(ws.members.core, 'AGENTS.md').replace('v=2', 'v=1'));
    const check = runSync(ws.root, { check: true, member: 'core' });
    assert.strictEqual(rowOf(check, 'core').agentsBlock, 'outdated');
    assert.strictEqual(check.code, 0, check.text);
    runSync(ws.root, { member: 'core' });
    assert.match(read(ws.members.core, 'AGENTS.md'), /adf:system-context v=2 /);
  });
});

describe('sync --check: an AGENTS.md that holds only ADF installer block', () => {
  it('does not fail --check for a missing block, whether CLAUDE.md is absent, importing or standalone', (t) => {
    const ws = syncedWorkspace(t);
    put(ws.members.core, 'AGENTS.md', INSTALLER);
    assert.strictEqual(runSync(ws.root, { check: true }).code, 0, 'standalone CLAUDE.md with its own block');
    put(ws.members.core, 'CLAUDE.md', `@AGENTS.md\n\n${read(ws.members.core, 'CLAUDE.md')}`);
    put(ws.members.core, 'CLAUDE.md', read(ws.members.core, 'CLAUDE.md').replace(/<!-- adf:system-context begin -->[\s\S]*<!-- adf:system-context end -->\n?/, ''));
    const importing = runSync(ws.root, { check: true });
    assert.strictEqual(importing.code, 0, importing.text);
    assert.strictEqual(rowOf(importing, 'core').agentsBlock, 'missing');
    fs.rmSync(path.join(ws.members.core, 'CLAUDE.md'));
    assert.strictEqual(runSync(ws.root, { check: true }).code, 0, 'no CLAUDE.md');
  });

  it('is written like any other AGENTS.md by sync, next to the installer block, which stays as it was', (t) => {
    const ws = preparedWorkspace(t);
    put(ws.members.core, 'AGENTS.md', INSTALLER);
    runSync(ws.root, { member: 'core' });
    const text = read(ws.members.core, 'AGENTS.md');
    assert.ok(text.startsWith(INSTALLER));
    assert.ok(hasBlock(text));
    commitFiles(ws.members.core, FILES);
    assert.strictEqual(runSync(ws.root, { check: true, member: 'core' }).code, 0);
  });
});

describe('sync in a monorepo with AGENTS.md', () => {
  it('writes the monorepo wording of the bullets and keeps the installer block next to its own', (t) => {
    const { scopeMonorepo, writeFile } = require('../../../../hooks/lib/__tests__/scope-test-fixtures.cjs');
    const { git } = require('./workspace-test-helpers.cjs');
    const { root } = scopeMonorepo(t);
    writeFile(root, 'services/order/AGENTS.md', `# order\n\n${INSTALLER}`);
    git(root, 'add', '--all');
    git(root, 'commit', '--quiet', '-m', 'docs: agents');
    const r = runSync(root);
    assert.strictEqual(r.code, 0, r.text);
    const text = fs.readFileSync(path.join(root, 'services/order/AGENTS.md'), 'utf8');
    assert.match(text, /- PR base: `node .claude\/skills\/git\/scripts\/git-flow.cjs status` at the repo root/);
    assert.match(text, /- Rules: the root `AGENTS.md`\./);
    assert.ok(!text.includes('Workspace repo'));
    assert.ok(text.startsWith(`# order\n\n${INSTALLER}`), 'the installer block is untouched');
    assert.ok(hasBlock(text));
    assert.strictEqual(runSync(root, { check: true }).code, 0);
  });
});
