#!/usr/bin/env node
/**
 * Tests for member-attach.cjs: plan, apply and the settings diff
 * Run: node --test .claude/skills/workspace/scripts/tests/member-attach.test.cjs
 */

'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { git } = require('./workspace-test-helpers.cjs');
const { tmp, URL, SETTINGS, write, serveWorkspace, standaloneMember, attachTo, settings, attach } = require('./member-attach-helpers.cjs');

describe('attach: plan and apply', () => {
  it('without --yes prints the settings diff and neither clones nor writes', (t) => {
    serveWorkspace(t);
    const m = standaloneMember(t);
    const r = attachTo(m.root, URL);
    assert.strictEqual(r.code, 0, r.text);
    assert.ok(r.text.includes(`+ permissions.additionalDirectories: ${JSON.stringify([m.workspaceDir])}`), r.text);
    assert.match(r.text, /additionalDirectories lets Claude read and edit files in the workspace\. It does not load the workspace CLAUDE\.md or skills/);
    assert.match(r.text, /--add-dir .* and CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1/);
    assert.ok(!fs.existsSync(m.workspaceDir));
    assert.ok(!fs.existsSync(path.join(m.root, SETTINGS)));
    assert.strictEqual(attachTo(m.root, URL, { 'dry-run': true, yes: true }).result.applied, false, '--dry-run wins over --yes');
    assert.ok(!fs.existsSync(m.workspaceDir));
  });

  it('with --yes clones next to the member and grants the folder, keeping the other settings', (t) => {
    serveWorkspace(t);
    const m = standaloneMember(t);
    write(path.join(m.root, SETTINGS), { permissions: { allow: ['Bash(ls)'], additionalDirectories: ['/other'] }, env: { A: '1' } });
    const r = attachTo(m.root, URL, { yes: true });
    assert.strictEqual(r.code, 0, r.text);
    assert.strictEqual(r.result.workspace.clone, 'cloned');
    assert.ok(fs.existsSync(path.join(m.workspaceDir, 'adf-workspace.json')));
    assert.deepStrictEqual(settings(m.root), { permissions: { allow: ['Bash(ls)'], additionalDirectories: ['/other', m.workspaceDir] }, env: { A: '1' } });
  });

  it('creates .claude/ when missing, and a second run reuses the clone and changes nothing', (t) => {
    serveWorkspace(t);
    const m = standaloneMember(t);
    attachTo(m.root, URL, { yes: true });
    assert.deepStrictEqual(settings(m.root), { permissions: { additionalDirectories: [m.workspaceDir] } });
    const before = fs.readFileSync(path.join(m.root, SETTINGS), 'utf8');
    const again = attachTo(m.root, URL, { yes: true });
    assert.strictEqual(again.code, 0, again.text);
    assert.strictEqual(again.result.workspace.clone, 'reused');
    assert.strictEqual(again.result.settings.changed, false);
    assert.match(again.text, /already grants the workspace/);
    assert.strictEqual(fs.readFileSync(path.join(m.root, SETTINGS), 'utf8'), before);
  });

  it('clones where --dir says, outside the member only', (t) => {
    serveWorkspace(t);
    const m = standaloneMember(t);
    const elsewhere = path.join(tmp(t, 'adf-attach-elsewhere-'), 'ws');
    assert.strictEqual(attachTo(m.root, URL, { yes: true, dir: elsewhere }).code, 0);
    assert.deepStrictEqual(settings(m.root).permissions.additionalDirectories, [elsewhere]);
    for (const dir of [path.join(m.root, 'ws'), m.root, '.']) {
      const r = attachTo(m.root, URL, { yes: true, dir });
      assert.strictEqual(r.code, 1);
      assert.match(r.text, /outside this repo/);
    }
  });

  it('warns when settings.local.json is not git-ignored, and stays quiet when it is', (t) => {
    serveWorkspace(t);
    const m = standaloneMember(t);
    git(m.root, 'config', 'core.excludesFile', os.devNull); // a developer's global ignore file may already cover it
    const warned = attachTo(m.root, URL, { 'dry-run': true });
    assert.deepStrictEqual(warned.result.warnings.length, 1);
    assert.match(warned.text, /Warning: .claude\/settings.local.json is not git-ignored/);
    write(path.join(m.root, '.gitignore'), '.claude/settings.local.json\n');
    assert.deepStrictEqual(attachTo(m.root, URL, { 'dry-run': true }).result.warnings, []);
    assert.strictEqual(fs.readFileSync(path.join(m.root, '.gitignore'), 'utf8'), '.claude/settings.local.json\n', 'the member .gitignore is never edited');
  });
});
