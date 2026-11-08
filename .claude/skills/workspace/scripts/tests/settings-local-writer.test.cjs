#!/usr/bin/env node
/**
 * Tests for settings-local-writer.cjs
 * Run: node --test .claude/skills/workspace/scripts/tests/settings-local-writer.test.cjs
 */

'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { mergeSettingsLocal } = require('../lib/settings-local-writer.cjs');

const LOCAL = '.claude/settings.local.json';

function project(t, files = {}) {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'adf-settings-local-')));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  for (const [rel, content] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(root, rel)), { recursive: true });
    fs.writeFileSync(path.join(root, rel), typeof content === 'string' ? content : JSON.stringify(content));
  }
  return root;
}
const read = (root) => JSON.parse(fs.readFileSync(path.join(root, LOCAL), 'utf8'));
const sha = (file) => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');

describe('mergeSettingsLocal allowlist', () => {
  it('writes the four allowed keys into a new file', (t) => {
    const root = project(t);
    const r = mergeSettingsLocal(root, {
      permissions: { additionalDirectories: ['/work/other'] },
      worktree: { sparsePaths: ['services/order', '.claude'] },
      claudeMdExcludes: ['**/services/core/CLAUDE.md'],
      adfScope: { plan: 'p', paths: ['services/order'] },
    });
    assert.strictEqual(r.written, true);
    assert.deepStrictEqual(read(root), {
      permissions: { additionalDirectories: ['/work/other'] },
      worktree: { sparsePaths: ['services/order', '.claude'] },
      claudeMdExcludes: ['**/services/core/CLAUDE.md'],
      adfScope: { plan: 'p', paths: ['services/order'] },
    });
  });

  it('throws for permissions.allow, permissions.deny and any other key, and writes nothing', (t) => {
    const root = project(t);
    const bad = [
      { permissions: { allow: ['Bash(*)'] } },
      { permissions: { deny: [] } },
      { permissions: { additionalDirectories: ['/x'], allow: ['Bash(*)'] } },
      { hooks: {} },
      { env: { A: '1' } },
      { worktree: { symlinkDirectories: ['node_modules'] } },
      { 'permissions.allow': [] },
      { adfScope: { paths: [] }, enableAllProjectMcpServers: true },
      { __proto__: null, constructor: {} },
    ];
    for (const patch of bad) {
      assert.throws(() => mergeSettingsLocal(root, patch), /not allowed/, JSON.stringify(patch));
    }
    assert.strictEqual(fs.existsSync(path.join(root, LOCAL)), false);
  });

  it('throws for a wrong value type', (t) => {
    const root = project(t);
    assert.throws(() => mergeSettingsLocal(root, { claudeMdExcludes: 'x' }), /array of strings/);
    assert.throws(() => mergeSettingsLocal(root, { worktree: { sparsePaths: [1] } }), /array of strings/);
    assert.throws(() => mergeSettingsLocal(root, { adfScope: [] }), /an object/);
    assert.throws(() => mergeSettingsLocal(root, { permissions: { defaultMode: ['bypassPermissions'] } }), /a string/);
    assert.throws(() => mergeSettingsLocal(root, null), /must be an object/);
  });

  it('accepts permissions.defaultMode as a string, for /adf-mode, and removes it with null', (t) => {
    const root = project(t);
    assert.deepStrictEqual(mergeSettingsLocal(root, { permissions: { defaultMode: 'bypassPermissions' } }).diff, ['+ permissions.defaultMode: "bypassPermissions"']);
    assert.deepStrictEqual(JSON.parse(fs.readFileSync(path.join(root, LOCAL), 'utf8')), { permissions: { defaultMode: 'bypassPermissions' } });
    mergeSettingsLocal(root, { permissions: { defaultMode: null } });
    assert.deepStrictEqual(JSON.parse(fs.readFileSync(path.join(root, LOCAL), 'utf8')), {});
  });
});

describe('mergeSettingsLocal merge and removal', () => {
  it('keeps unrelated keys and replaces the managed ones', (t) => {
    const root = project(t, { [LOCAL]: { permissions: { allow: ['Bash(ls)'] }, claudeMdExcludes: ['old'], theme: 'dark' } });
    mergeSettingsLocal(root, { claudeMdExcludes: ['new'], adfScope: { plan: null, paths: ['a'] } });
    assert.deepStrictEqual(read(root), { permissions: { allow: ['Bash(ls)'] }, claudeMdExcludes: ['new'], theme: 'dark', adfScope: { plan: null, paths: ['a'] } });
  });

  it('removes keys given as null, prunes emptied parents and keeps siblings', (t) => {
    const root = project(t, { [LOCAL]: { worktree: { sparsePaths: ['a'] }, permissions: { allow: ['x'], additionalDirectories: ['/y'] }, adfScope: {} } });
    const r = mergeSettingsLocal(root, { worktree: { sparsePaths: null }, permissions: { additionalDirectories: null }, adfScope: null, claudeMdExcludes: null });
    assert.deepStrictEqual(read(root), { permissions: { allow: ['x'] } });
    assert.strictEqual(r.changed, true);
  });

  it('reports no change and does not rewrite the file when nothing differs', (t) => {
    const root = project(t, { [LOCAL]: { claudeMdExcludes: ['a'] } });
    const before = fs.statSync(path.join(root, LOCAL)).mtimeMs;
    const r = mergeSettingsLocal(root, { claudeMdExcludes: ['a'], adfScope: null });
    assert.deepStrictEqual({ changed: r.changed, written: r.written, diff: r.diff }, { changed: false, written: false, diff: [] });
    assert.strictEqual(fs.statSync(path.join(root, LOCAL)).mtimeMs, before);
  });

  it('dryRun returns the diff and leaves the file as it was', (t) => {
    const root = project(t, { [LOCAL]: { claudeMdExcludes: ['old'] } });
    const r = mergeSettingsLocal(root, { claudeMdExcludes: ['new'] }, { dryRun: true });
    assert.deepStrictEqual(r.diff, ['- claudeMdExcludes: ["old"]', '+ claudeMdExcludes: ["new"]']);
    assert.strictEqual(r.written, false);
    assert.deepStrictEqual(read(root), { claudeMdExcludes: ['old'] });
  });

  it('never touches settings.json', (t) => {
    const root = project(t, { '.claude/settings.json': { permissions: { deny: ['Read(.env)'] } } });
    const file = path.join(root, '.claude/settings.json');
    const before = sha(file);
    mergeSettingsLocal(root, { adfScope: { plan: 'p', paths: ['a'] } });
    mergeSettingsLocal(root, { adfScope: null });
    assert.strictEqual(sha(file), before);
  });
});

describe('mergeSettingsLocal refuses unsafe targets', () => {
  it('rejects a settings file that is not valid JSON or not an object, without touching it', (t) => {
    const root = project(t, { [LOCAL]: '{ broken' });
    assert.throws(() => mergeSettingsLocal(root, { adfScope: { paths: [] } }), /not valid JSON/);
    assert.strictEqual(fs.readFileSync(path.join(root, LOCAL), 'utf8'), '{ broken');
    fs.writeFileSync(path.join(root, LOCAL), '[1]');
    assert.throws(() => mergeSettingsLocal(root, { adfScope: { paths: [] } }), /JSON object/);
  });

  it('rejects a symlinked settings file and a managed parent that is not an object', (t) => {
    const root = project(t, { 'elsewhere.json': '{}' });
    fs.mkdirSync(path.join(root, '.claude'));
    fs.symlinkSync(path.join(root, 'elsewhere.json'), path.join(root, LOCAL));
    assert.throws(() => mergeSettingsLocal(root, { adfScope: { paths: [] } }), /not a regular file/);
    assert.strictEqual(fs.readFileSync(path.join(root, 'elsewhere.json'), 'utf8'), '{}');
    const other = project(t, { [LOCAL]: { worktree: 'yes' } });
    assert.throws(() => mergeSettingsLocal(other, { worktree: { sparsePaths: ['a'] } }), /not an object/);
  });
});
