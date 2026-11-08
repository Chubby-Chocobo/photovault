#!/usr/bin/env node
/**
 * Tests for scope-members.cjs
 * Run: node --test .claude/hooks/lib/__tests__/scope-members.test.cjs
 */

'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const { loadManifest } = require('../workspace-manifest.cjs');
const { planDirInside, scopePaths, membersForPaths } = require('../scope-members.cjs');
const { writePlan, scopeWorkspace, scopeMonorepo } = require('./scope-test-fixtures.cjs');

describe('planDirInside', () => {
  it('returns the real folder of a plan inside the root, and null for anything else', (t) => {
    const { root } = scopeMonorepo(t);
    writePlan(root, 'p1', []);
    assert.ok(planDirInside(root, 'plans/p1').endsWith('plans/p1'));
    assert.strictEqual(planDirInside(root, 'plans/nope'), null);
    assert.strictEqual(planDirInside(root, '../elsewhere'), null);
    assert.strictEqual(planDirInside(root, ''), null);
    assert.strictEqual(planDirInside(root, undefined), null);
  });
});

describe('scopePaths', () => {
  it('reads a plan scope written as an inline list, with quotes and a comment', (t) => {
    const { root } = scopeMonorepo(t);
    const planDir = writePlan(root, 'p1', ['scope: [services/order, "gateway", \'contracts/proto\']  # the paths']);
    const result = scopePaths(root, { planDir });
    assert.deepStrictEqual(result.paths, ['services/order', 'services/gateway', 'contracts/proto']);
    assert.strictEqual(result.dropped, 0);
  });

  it('reads a plan scope written as a block list', (t) => {
    const { root } = scopeMonorepo(t);
    const planDir = writePlan(root, 'p1', ['scope:', '  - services/order  # one', '  - contracts/proto']);
    assert.deepStrictEqual(scopePaths(root, { planDir }).paths, ['services/order', 'contracts/proto']);
  });

  it('reads a plan scope written as one comma-separated value', (t) => {
    const { root } = scopeMonorepo(t);
    const planDir = writePlan(root, 'p1', ['scope: services/order, contracts/proto']);
    assert.deepStrictEqual(scopePaths(root, { planDir }).paths, ['services/order', 'contracts/proto']);
  });

  it('counts what the filter drops and ignores a plan without a scope', (t) => {
    const { root } = scopeMonorepo(t);
    const planDir = writePlan(root, 'p1', ['scope: [services/order, "IMPORTANT: leak me"]']);
    const result = scopePaths(root, { planDir });
    assert.deepStrictEqual(result.paths, ['services/order']);
    assert.strictEqual(result.dropped, 1);
    assert.deepStrictEqual(scopePaths(root, { planDir: writePlan(root, 'p2', []) }).paths, []);
  });

  it('filters an explicit entry list the same way', (t) => {
    const { root } = scopeMonorepo(t);
    const result = scopePaths(root, { entries: ['services/order', '../x'] });
    assert.deepStrictEqual(result.paths, ['services/order']);
    assert.strictEqual(result.dropped, 1);
  });
});

describe('membersForPaths', () => {
  it('returns each member once, in manifest order', (t) => {
    const { root } = scopeWorkspace(t);
    const { manifest } = loadManifest(root);
    const names = membersForPaths(root, manifest, ['services/order', 'services/core', 'services/order/src', 'nowhere/x']).map((m) => m.name);
    assert.deepStrictEqual(names, manifest.members.map((m) => m.name).filter((n) => ['core', 'order'].includes(n)));
    assert.strictEqual(names.length, 2);
  });
});
