#!/usr/bin/env node
/**
 * Tests for `workspace check`
 * Run: node --test .claude/skills/workspace/scripts/tests/workspace-check.test.cjs
 */

'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { makeTcxWorkspace } = require('../../../../hooks/__tests__/fixtures/workspace-fixtures.cjs');
const { cliJson, git, initializedWorkspace, readJson, writeJson, editManifest } = require('./workspace-test-helpers.cjs');

const MAP = 'docs/architecture/system-map.json';
const has = (list, fragment) => list.some((m) => m.includes(fragment));

describe('workspace check', () => {
  it('passes on an initialized workspace and summarizes members and the map', (t) => {
    const { root } = initializedWorkspace(t);
    const { code, json } = cliJson(root, ['check']);
    assert.strictEqual(code, 0, JSON.stringify(json));
    assert.deepStrictEqual(json.errors, []);
    assert.strictEqual(json.members.length, 8);
    assert.ok(json.members.every((m) => m.state === 'cloned' && m.branch === 'main'));
    assert.deepStrictEqual(json.map, { components: 7, contracts: 1 });
  });

  it('fails with the error list on a broken map', (t) => {
    const { root } = initializedWorkspace(t);
    const map = readJson(root, MAP);
    map.components[0].member = 'ghost';
    map.components[1].calls = [{ to: 'nowhere', via: 'rest' }];
    writeJson(root, MAP, map);
    const { code, json } = cliJson(root, ['check']);
    assert.strictEqual(code, 1);
    assert.ok(has(json.errors, '.member must name a manifest member'), json.errors.join('\n'));
    assert.ok(has(json.errors, '.calls[0].to must name a component'));
  });

  it('fails when a member has no git section', (t) => {
    const { root } = initializedWorkspace(t);
    editManifest(root, (m) => { delete m.members[0].git; });
    const { code, json } = cliJson(root, ['check']);
    assert.strictEqual(code, 1);
    assert.ok(has(json.errors, '.git is required'));
  });

  it('fails on org given as a string or an empty array', (t) => {
    const { root } = initializedWorkspace(t);
    for (const bad of ['acme', []]) {
      editManifest(root, (m) => { m.org = bad; });
      const { code, json } = cliJson(root, ['check']);
      assert.strictEqual(code, 1);
      assert.ok(has(json.errors, 'org must be a non-empty array'));
    }
  });

  it('fails on a symlinked member and on a member the workspace repo does not ignore', (t) => {
    const { root } = initializedWorkspace(t);
    const order = path.join(root, 'services/order');
    const outside = fs.mkdtempSync(path.join(path.dirname(root), 'outside-'));
    fs.rmSync(order, { recursive: true, force: true });
    fs.symlinkSync(outside, order);
    const symlinked = cliJson(root, ['check']);
    assert.strictEqual(symlinked.code, 1);
    assert.ok(has(symlinked.json.errors, 'member order') && has(symlinked.json.errors, 'symlink'));
    fs.unlinkSync(order);

    fs.writeFileSync(path.join(root, '.gitignore'), '');
    const open = cliJson(root, ['check']);
    assert.strictEqual(open.code, 1);
    assert.ok(has(open.json.errors, 'member core: services/core is not ignored'));
    assert.ok(has(open.json.warnings, '.gitignore has no managed block'));
  });

  it('warns, without failing, on a member that is not cloned', (t) => {
    const { root } = initializedWorkspace(t);
    fs.rmSync(path.join(root, 'services/order'), { recursive: true, force: true });
    const { code, json } = cliJson(root, ['check']);
    assert.strictEqual(code, 0);
    assert.ok(has(json.warnings, 'member order is not cloned'));
  });

  it('warns on a missing .ignore and on a block that lacks a role dir', (t) => {
    const { root } = initializedWorkspace(t);
    const ignore = path.join(root, '.ignore');
    const text = fs.readFileSync(ignore, 'utf8');
    fs.writeFileSync(ignore, text.replace('!/infra/\n', ''));
    const outdated = cliJson(root, ['check']);
    assert.strictEqual(outdated.code, 0);
    assert.ok(has(outdated.json.warnings, '.ignore managed block is out of date (run /workspace init)'));
    fs.rmSync(ignore);
    assert.ok(has(cliJson(root, ['check']).json.warnings, '.ignore has no managed block'));
  });

  it('warns on a nested repo under a role dir that is not a member', (t) => {
    const { root } = initializedWorkspace(t);
    fs.mkdirSync(path.join(root, 'services/extra'));
    git(path.join(root, 'services/extra'), 'init', '--quiet');
    const { code, json } = cliJson(root, ['check']);
    assert.strictEqual(code, 0);
    assert.ok(has(json.warnings, 'services/extra is a git repo under a role dir but not a manifest member'));
  });

  it('warns on a member owner outside org, not on one inside a second listed org', (t) => {
    const { root } = initializedWorkspace(t);
    const url = 'https://github.com/other/tcx-order.git';
    editManifest(root, (m) => { m.members.find((x) => x.name === 'order').repo = url; });
    git(path.join(root, 'services/order'), 'remote', 'set-url', 'origin', url);
    assert.ok(has(cliJson(root, ['check']).json.warnings, 'member order: owner other is not in org'));
    editManifest(root, (m) => { m.org = ['acme', 'other']; });
    assert.ok(!has(cliJson(root, ['check']).json.warnings, 'is not in org'));
  });

  it('warns on a local repo and on a member whose origin differs', (t) => {
    const { root } = initializedWorkspace(t);
    editManifest(root, (m) => { m.members.find((x) => x.name === 'core').repo = 'file:///srv/git/core.git'; });
    const { json } = cliJson(root, ['check']);
    assert.ok(has(json.warnings, '.repo is local'));
    assert.ok(has(json.warnings, 'member core: origin differs from the manifest repo'));
  });

  it('reports a monorepo map on its own and an empty directory as an error', (t) => {
    const { root } = makeTcxWorkspace(t);
    assert.strictEqual(cliJson(root, ['check']).code, 1);
    writeJson(root, MAP, { version: 1, components: [{ name: 'api', path: 'services/api' }] });
    const { code, json } = cliJson(root, ['check']);
    assert.strictEqual(code, 0, JSON.stringify(json));
    assert.deepStrictEqual(json.map, { components: 1, contracts: 0 });
  });
});
