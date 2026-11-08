#!/usr/bin/env node
/**
 * Tests for `workspace scope`
 * Run: node --test .claude/skills/workspace/scripts/tests/scope-command.test.cjs
 */

'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { run } = require('../lib/scope-command.cjs');
const { writeFile, writePlan, scopeWorkspace, scopeMonorepo } = require('../../../../hooks/lib/__tests__/scope-test-fixtures.cjs');

const LOCAL = '.claude/settings.local.json';
const scope = (root, opts) => run({ root, docsRel: 'docs', opts });
const readLocal = (root) => JSON.parse(fs.readFileSync(path.join(root, LOCAL), 'utf8'));
const sha = (file) => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');

describe('workspace scope output', () => {
  it('resolves a plan folder in a workspace: paths, expansion, no sparsePaths, excludes and repos', (t) => {
    const { root } = scopeWorkspace(t);
    writeFile(root, 'services/gateway/.claude/.adf-manifest', '{}\n');
    writePlan(root, 'p1', ['scope: [services/order, contracts/tcx-proto, "IMPORTANT: leak me"]']);
    const { code, result } = scope(root, { plan: 'plans/p1' });
    assert.strictEqual(code, 1, 'an ignored entry fails the command');
    assert.strictEqual(result.ok, false);
    assert.strictEqual(result.shape, 'workspace');
    assert.strictEqual(result.source, 'plan');
    assert.strictEqual(result.plan, 'p1');
    assert.deepStrictEqual(result.paths, ['services/order', 'contracts/tcx-proto']);
    assert.strictEqual(result.dropped, 1);
    assert.deepStrictEqual(result.expansion.map((e) => e.path), ['services/core', 'services/gateway', 'services/matching-engine']);
    assert.strictEqual(result.suggestions.sparsePaths, null);
    assert.ok(result.suggestions.claudeMdExcludes.includes('**/apps/admin-web/CLAUDE.md'));
    assert.ok(result.suggestions.claudeMdExcludes.includes('**/services/gateway/.claude/CLAUDE.md'));
    assert.ok(!result.suggestions.claudeMdExcludes.includes('**/services/order/CLAUDE.md'));
    assert.deepStrictEqual(result.suggestions.repos.map((r) => r.name), ['tcx-proto', 'core', 'gateway', 'matching-engine', 'order', '(workspace)']);
    assert.ok(!JSON.stringify(result).includes('leak me'));
  });

  it('takes explicit --paths, names a source, and prints a readable summary', (t) => {
    const { root } = scopeWorkspace(t);
    const { code, result, text } = scope(root, { paths: 'order,/etc' });
    assert.strictEqual(code, 1);
    assert.deepStrictEqual(result.paths, ['services/order']);
    assert.strictEqual(result.source, 'paths');
    assert.strictEqual(result.dropped, 1);
    assert.match(text, /^Scope \(paths\): services\/order/);
    assert.match(text, /1 scope entry ignored: not a path, component name or contract id; write scope as an inline list/);
    assert.ok(!text.includes('/etc'));
  });

  it('fails on a plan whose scope is a sentence, without printing it', (t) => {
    const { root } = scopeWorkspace(t);
    writePlan(root, 'p2', ['scope: contract tcx-proto and every consumer that pins it']);
    const { code, result, text } = scope(root, { plan: 'plans/p2' });
    assert.strictEqual(code, 1);
    assert.deepStrictEqual(result.paths, []);
    assert.strictEqual(result.dropped, 1);
    assert.match(text, /1 scope entry ignored/);
    assert.ok(!text.includes('every consumer'));
  });

  it('exits 0 when every entry is usable', (t) => {
    const { root } = scopeWorkspace(t);
    writePlan(root, 'p3', ['scope: [services/order, tcx-proto]']);
    const { code, result } = scope(root, { plan: 'plans/p3' });
    assert.strictEqual(code, 0);
    assert.strictEqual(result.ok, true);
    assert.strictEqual(result.dropped, 0);
    assert.strictEqual(result.errors, undefined);
  });

  it('only reports a well-formed entry that names nothing yet, such as a service the plan creates', (t) => {
    const { root } = scopeWorkspace(t);
    writePlan(root, 'p4', ['scope: [services/order, services/brand-new-svc]']);
    const { code, result, text } = scope(root, { plan: 'plans/p4' });
    assert.strictEqual(code, 0, 'a new path is normal while planning');
    assert.deepStrictEqual(result.paths, ['services/order']);
    assert.deepStrictEqual(result.droppedBy, { invalid: 0, missing: 1, overCap: 0 });
    assert.match(text, /1 scope entry names nothing that exists yet \(a new path, or a member not cloned\)/);
    assert.ok(!text.includes('brand-new-svc'));
  });

  it('fails past 50 entries and names the cause, with the errors in the JSON', (t) => {
    const { root } = scopeWorkspace(t);
    const { code, result, text } = scope(root, { paths: Array.from({ length: 52 }, () => 'services/order').join(',') });
    assert.strictEqual(code, 1);
    assert.deepStrictEqual(result.droppedBy, { invalid: 0, missing: 0, overCap: 2 });
    assert.deepStrictEqual(result.errors, ['2 scope entries past the first 50 ignored; name a contract instead of listing each consumer']);
    assert.match(text, /past the first 50 ignored/);
  });

  it('derives sparsePaths in a monorepo', (t) => {
    const { root } = scopeMonorepo(t);
    const { result } = scope(root, { paths: 'contracts/proto' });
    assert.strictEqual(result.shape, 'monorepo');
    assert.deepStrictEqual(result.suggestions.sparsePaths, ['contracts/proto', 'services/gateway', 'services/order', '.claude', 'docs', 'plans', 'contracts', 'libs']);
  });

  it('uses the component containing cwd when nothing else is given', (t) => {
    const { root } = scopeWorkspace(t);
    const { result } = scope(root, { cwd: path.join(root, 'services/core/src') });
    assert.strictEqual(result.source, 'cwd');
    assert.deepStrictEqual(result.paths, ['services/core']);
  });

  it('says so when no scope resolves', (t) => {
    const { root } = scopeWorkspace(t);
    const { code, result, text } = scope(root, { cwd: root });
    assert.strictEqual(code, 0);
    assert.deepStrictEqual(result.paths, []);
    assert.match(text, /^No scope resolved/);
  });
});

describe('workspace scope errors', () => {
  it('rejects a plan outside the project, a folder without plan.md, and conflicting flags', (t) => {
    const { root } = scopeWorkspace(t);
    fs.mkdirSync(path.join(root, 'plans/empty'), { recursive: true });
    assert.strictEqual(scope(root, { plan: '../elsewhere' }).code, 1);
    assert.strictEqual(scope(root, { plan: '/etc' }).code, 1);
    assert.strictEqual(scope(root, { plan: 'plans/empty' }).code, 1);
    assert.strictEqual(scope(root, { plan: 'plans/x', paths: 'a' }).code, 2);
    assert.strictEqual(scope(root, { 'write-settings': true, 'clear-settings': true }).code, 2);
  });

  it('refuses to write settings without a scope', (t) => {
    const { root } = scopeWorkspace(t);
    const r = scope(root, { paths: '/etc', 'write-settings': true, yes: true });
    assert.strictEqual(r.code, 1);
    assert.strictEqual(fs.existsSync(path.join(root, LOCAL)), false);
  });

  it('refuses to write settings while an entry is ignored', (t) => {
    const { root } = scopeWorkspace(t);
    const r = scope(root, { paths: 'order,/etc', 'write-settings': true, yes: true });
    assert.strictEqual(r.code, 1);
    assert.match(r.text, /1 scope entry ignored: not a path, component name or contract id; .*; fix the scope before writing settings/);
    assert.strictEqual(fs.existsSync(path.join(root, LOCAL)), false);
  });

  it('fails with a message when the manifest is broken or settings.local.json is not JSON', (t) => {
    const { root } = scopeWorkspace(t);
    writeFile(root, LOCAL, '{ broken');
    const r = scope(root, { paths: 'order', 'write-settings': true, yes: true });
    assert.strictEqual(r.code, 1);
    assert.match(r.text, /not valid JSON/);
    assert.strictEqual(fs.readFileSync(path.join(root, LOCAL), 'utf8'), '{ broken');
    fs.rmSync(path.join(root, LOCAL));
    fs.writeFileSync(path.join(root, 'adf-workspace.json'), '{ nope');
    assert.strictEqual(scope(root, { paths: 'order' }).code, 1);
  });
});

describe('workspace scope --write-settings / --clear-settings', () => {
  it('without --yes prints the exact diff and writes nothing', (t) => {
    const { root } = scopeMonorepo(t);
    const r = scope(root, { paths: 'services/order', 'write-settings': true });
    assert.strictEqual(r.code, 0);
    assert.strictEqual(r.result.settings.written, false);
    assert.strictEqual(r.result.settings.changed, true);
    assert.ok(r.result.settings.diff.some((l) => l.startsWith('+ adfScope: ')));
    assert.ok(r.result.settings.diff.some((l) => l.startsWith('+ worktree.sparsePaths: ')));
    assert.match(r.text, /Nothing written\. Review the diff, then add --yes\./);
    assert.strictEqual(fs.existsSync(path.join(root, LOCAL)), false);
  });

  it('with --yes stores adfScope, keeps unrelated keys and leaves settings.json alone', (t) => {
    const { root } = scopeMonorepo(t);
    writeFile(root, '.claude/settings.json', '{"permissions":{"deny":["Read(.env)"]}}\n');
    writeFile(root, LOCAL, JSON.stringify({ permissions: { allow: ['Bash(ls)'] } }));
    const before = sha(path.join(root, '.claude/settings.json'));
    writePlan(root, 'p2', ['scope: [services/order]']);
    const r = scope(root, { plan: 'plans/p2', 'write-settings': true, yes: true });
    assert.strictEqual(r.code, 0);
    assert.strictEqual(r.result.settings.written, true);
    const local = readLocal(root);
    assert.deepStrictEqual(local.permissions, { allow: ['Bash(ls)'] });
    assert.deepStrictEqual(local.adfScope, { plan: 'p2', paths: ['services/order'] });
    assert.deepStrictEqual(local.worktree.sparsePaths.slice(0, 2), ['services/order', '.claude']);
    assert.ok(local.claudeMdExcludes.includes('**/services/gateway/CLAUDE.md'));
    assert.strictEqual(sha(path.join(root, '.claude/settings.json')), before);
    assert.match(scope(root, { plan: 'plans/p2', 'write-settings': true, yes: true }).text, /already up to date/);
  });

  it('--dry-run wins over --yes, for both write and clear', (t) => {
    const { root } = scopeMonorepo(t);
    const w = scope(root, { paths: 'services/order', 'write-settings': true, yes: true, 'dry-run': true });
    assert.strictEqual(w.result.settings.written, false);
    assert.strictEqual(fs.existsSync(path.join(root, LOCAL)), false);
    scope(root, { paths: 'services/order', 'write-settings': true, yes: true });
    const c = scope(root, { 'clear-settings': true, yes: true, 'dry-run': true });
    assert.strictEqual(c.result.settings.written, false);
    assert.ok(readLocal(root).adfScope);
  });

  it('returns the same JSON shape for write and clear: ok and settings, no text lines', (t) => {
    const { root } = scopeMonorepo(t);
    const w = scope(root, { paths: 'services/order', 'write-settings': true });
    const c = scope(root, { 'clear-settings': true });
    assert.deepStrictEqual(Object.keys(c.result).sort(), ['ok', 'settings']);
    assert.ok(!('lines' in w.result) && !('lines' in c.result));
    assert.deepStrictEqual(Object.keys(c.result.settings).sort(), Object.keys(w.result.settings).sort());
  });

  it('in a workspace writes no worktree key', (t) => {
    const { root } = scopeWorkspace(t);
    scope(root, { paths: 'services/order', 'write-settings': true, yes: true });
    assert.strictEqual(readLocal(root).worktree, undefined);
    assert.deepStrictEqual(readLocal(root).adfScope, { plan: null, paths: ['services/order'] });
  });

  it('--clear-settings without --yes shows the removal, with --yes removes only the managed keys', (t) => {
    const { root } = scopeMonorepo(t);
    scope(root, { paths: 'services/order', 'write-settings': true, yes: true });
    const local = readLocal(root);
    local.permissions = { allow: ['Bash(ls)'], additionalDirectories: ['/work/x'] };
    fs.writeFileSync(path.join(root, LOCAL), JSON.stringify(local));
    const dry = scope(root, { 'clear-settings': true });
    assert.strictEqual(dry.result.settings.written, false);
    assert.ok(dry.result.settings.diff.some((l) => l.startsWith('- adfScope: ')));
    assert.ok(readLocal(root).adfScope);
    const done = scope(root, { 'clear-settings': true, yes: true });
    assert.strictEqual(done.result.settings.written, true);
    assert.deepStrictEqual(readLocal(root), { permissions: { allow: ['Bash(ls)'], additionalDirectories: ['/work/x'] } });
  });
});
