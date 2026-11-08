#!/usr/bin/env node
/**
 * Tests for the git.directPush.paths proposal of `workspace init` and the matching `check` warning
 * Run: node --test .claude/skills/workspace/scripts/tests/workspace-init-direct-push.test.cjs
 */

'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { makeTcxWorkspace } = require('../../../../hooks/__tests__/fixtures/workspace-fixtures.cjs');
const { cli, cliJson, readJson, writeJson } = require('./workspace-test-helpers.cjs');

const CONFIG = '.claude/config/adf-config.json';
const PROPOSED = ['plans/**', 'README.md', 'CHANGELOG.md', '.github/**'];
const DEFAULT_PATHS = ['docs/**', '.github/**', 'README.md', 'CHANGELOG.md', 'CLAUDE.md', 'AGENTS.md'];
const exists = (root) => fs.existsSync(path.join(root, CONFIG));

describe('workspace init: git.directPush.paths proposal', () => {
  it('prints before and after and writes nothing without --yes', (t) => {
    const { root } = makeTcxWorkspace(t);
    const raw = cli(root, ['init'], { raw: true });
    assert.strictEqual(raw.code, 2, 'init only plans without --yes');
    assert.match(raw.out, /git\.directPush\.paths in \.claude\/config\/adf-config\.json: proposal, not written/);
    assert.match(raw.out, /before: \["docs\/\*\*",/);
    assert.match(raw.out, /after:  \["plans\/\*\*","README\.md","CHANGELOG\.md","\.github\/\*\*"\]/);
    assert.ok(!exists(root));
    const dry = cliJson(root, ['init', '--dry-run'], { raw: true });
    assert.deepStrictEqual(dry.json.directPush, { file: CONFIG, after: PROPOSED, before: DEFAULT_PATHS, configured: false, status: 'would-write' });
    assert.ok(!exists(root));
  });

  it('writes the proposal with --yes and keeps every other key', (t) => {
    const { root } = makeTcxWorkspace(t);
    writeJson(root, CONFIG, { plan: { namingFormat: 'x' }, git: { flow: 'trunk', mainBranch: 'develop', directPush: { extra: 1 } }, hooks: { 'commit-guard': true } });
    const { code, json } = cliJson(root, ['init']);
    assert.strictEqual(code, 0);
    assert.strictEqual(json.directPush.status, 'written');
    assert.deepStrictEqual(readJson(root, CONFIG), {
      plan: { namingFormat: 'x' },
      git: { flow: 'trunk', mainBranch: 'develop', directPush: { extra: 1, paths: PROPOSED } },
      hooks: { 'commit-guard': true },
    });
    assert.ok(fs.readFileSync(path.join(root, CONFIG), 'utf8').startsWith('{\n  "plan": {\n    "namingFormat"'), '2-space indentation');
  });

  it('creates the file when it is absent, and a second run keeps it', (t) => {
    const { root } = makeTcxWorkspace(t);
    assert.strictEqual(cliJson(root, ['init']).code, 0);
    assert.deepStrictEqual(readJson(root, CONFIG), { git: { directPush: { paths: PROPOSED } } });
    const again = cliJson(root, ['init']);
    assert.strictEqual(again.json.directPush.status, 'kept');
    assert.deepStrictEqual(readJson(root, CONFIG), { git: { directPush: { paths: PROPOSED } } });
  });

  it('leaves a paths list the project set itself, and says so', (t) => {
    const { root } = makeTcxWorkspace(t);
    writeJson(root, CONFIG, { git: { directPush: { paths: ['docs/**', 'notes/**'] } } });
    const r = cliJson(root, ['init']);
    assert.strictEqual(r.json.directPush.status, 'kept');
    assert.deepStrictEqual(r.json.directPush.before, ['docs/**', 'notes/**']);
    assert.deepStrictEqual(readJson(root, CONFIG).git.directPush.paths, ['docs/**', 'notes/**']);
    assert.match(cli(root, ['init']).out, /already set in the project/);
  });

  it('treats an explicit empty list as configured: nothing goes direct, and init keeps it', (t) => {
    const { root } = makeTcxWorkspace(t);
    writeJson(root, CONFIG, { git: { directPush: { paths: [] } } });
    const r = cliJson(root, ['init']);
    assert.strictEqual(r.json.directPush.status, 'kept');
    assert.deepStrictEqual(r.json.directPush.before, []);
    assert.deepStrictEqual(readJson(root, CONFIG).git.directPush.paths, []);
    const check = cli(root, ['check']);
    assert.doesNotMatch(check.out, /go straight to the main branch/);
    writeJson(root, CONFIG, { git: { directPush: { paths: ['docs/**'] } } });
    assert.match(cli(root, ['check']).out, /edit git\.directPush\.paths/);
  });

  it('fails without touching a config file that is not valid JSON', (t) => {
    const { root } = makeTcxWorkspace(t);
    fs.mkdirSync(path.join(root, '.claude/config'), { recursive: true });
    fs.writeFileSync(path.join(root, CONFIG), '{ not json');
    const r = cliJson(root, ['init']);
    assert.strictEqual(r.code, 1);
    assert.strictEqual(r.json.directPush.status, 'failed');
    assert.strictEqual(fs.readFileSync(path.join(root, CONFIG), 'utf8'), '{ not json');
  });
});

describe('workspace check: direct-push paths', () => {
  const warnings = (root) => cliJson(root, ['check']).json.warnings.filter((w) => /git\.directPush\.paths/.test(w));

  it('warns when docs or the manifest can go straight to main, by default and by configuration', (t) => {
    const { root } = makeTcxWorkspace(t);
    cli(root, ['init']);
    fs.rmSync(path.join(root, CONFIG));
    assert.match(warnings(root)[0], /built-in git\.directPush\.paths default lets docs\/\*\* go straight to the main branch/);
    writeJson(root, CONFIG, { git: { directPush: { paths: ['plans/**', 'docs/**', 'adf-workspace.json'] } } });
    assert.match(warnings(root)[0], /^git\.directPush\.paths lets docs\/\*\* and adf-workspace\.json go straight/);
  });

  it('is quiet after init has written the proposal', (t) => {
    const { root } = makeTcxWorkspace(t);
    cli(root, ['init']);
    assert.deepStrictEqual(warnings(root), []);
  });
});
