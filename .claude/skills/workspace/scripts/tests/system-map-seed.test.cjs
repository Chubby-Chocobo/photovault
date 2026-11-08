#!/usr/bin/env node
/**
 * Tests for the system map seeding (`workspace seed-map`, seedMap, contract kind scan)
 * Run: node --test .claude/skills/workspace/scripts/tests/system-map-seed.test.cjs
 */

'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { makePolyglotMonorepo } = require('../../../../hooks/__tests__/fixtures/workspace-fixtures.cjs');
const { validateSystemMap } = require('../../../../hooks/lib/system-map.cjs');
const { seedMap, slugName } = require('../lib/system-map-seed.cjs');
const { scanContractKind } = require('../lib/contract-kind-scan.cjs');
const { cli, cliJson, readJson, writeJson } = require('./workspace-test-helpers.cjs');

const MAP = 'docs/architecture/system-map.json';

function tmp(t) {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'adf-kind-')));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function put(dir, files) {
  for (const [rel, content] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true });
    fs.writeFileSync(path.join(dir, rel), content);
  }
}

describe('seedMap: monorepo', () => {
  it('seeds one contract per kind and components with role and stack', (t) => {
    const { root } = makePolyglotMonorepo(t);
    const { map, added } = seedMap({ root });
    assert.deepStrictEqual(validateSystemMap(map), { errors: [], warnings: [] });
    assert.deepStrictEqual(Object.fromEntries(map.contracts.map((c) => [c.id, c.kind])), { async: 'asyncapi', events: 'json-schema', openapi: 'openapi', proto: 'proto' });
    assert.deepStrictEqual(map.contracts.map((c) => c.path).sort(), ['contracts/async', 'contracts/events', 'contracts/openapi', 'contracts/proto']);
    const byName = Object.fromEntries(map.components.map((c) => [c.name, c]));
    assert.deepStrictEqual(Object.keys(byName).sort(), ['admin-web', 'billing', 'gateway', 'ranker']);
    assert.deepStrictEqual([byName.gateway.role, byName.gateway.stack, byName.gateway.path], ['backend', 'nestjs', 'services/gateway']);
    assert.deepStrictEqual([byName['admin-web'].role, byName['admin-web'].stack], ['frontend', 'vue']);
    assert.deepStrictEqual([byName.ranker.role, byName.ranker.stack], ['backend', 'python']);
    assert.strictEqual(byName.billing.stack, undefined);
    assert.strictEqual(added.length, 8);
    assert.ok(map.roles.frontend.includes('web'), 'DEFAULT_ROLES are seeded');
  });
});

describe('workspace seed-map', () => {
  it('writes the map, refuses to replace it, and --merge adds only what is missing', (t) => {
    const { root } = makePolyglotMonorepo(t);
    const first = cliJson(root, ['seed-map']);
    assert.strictEqual(first.code, 0);
    assert.strictEqual(first.json.added.length, 8);

    const refused = cli(root, ['seed-map']);
    assert.strictEqual(refused.code, 1);
    assert.match(refused.out, /--merge/);

    const map = readJson(root, MAP);
    map.components.find((c) => c.name === 'gateway').role = 'edge';
    map.components.find((c) => c.name === 'gateway').calls = [{ to: 'billing', via: 'grpc', topic: 'invoices.new' }];
    map.contracts = map.contracts.filter((c) => c.id !== 'async');
    writeJson(root, MAP, map);
    put(root, { 'services/newsvc/package.json': '{"name":"newsvc"}' });

    const merged = cliJson(root, ['seed-map', '--merge']);
    assert.strictEqual(merged.code, 0);
    assert.deepStrictEqual(merged.json.added.sort(), ['component:newsvc', 'contract:async']);
    const after = readJson(root, MAP);
    const gateway = after.components.find((c) => c.name === 'gateway');
    assert.deepStrictEqual([gateway.role, gateway.calls[0].topic], ['edge', 'invoices.new']);
    assert.strictEqual(after.components.length, 5);
    assert.strictEqual(after.contracts.length, 4);

    const again = cliJson(root, ['seed-map', '--merge']);
    assert.deepStrictEqual(again.json.added, []);
    assert.deepStrictEqual(readJson(root, MAP), after);
  });

  it('--dry-run writes nothing', (t) => {
    const { root } = makePolyglotMonorepo(t);
    const { json } = cliJson(root, ['seed-map', '--dry-run']);
    assert.strictEqual(json.dryRun, true);
    assert.ok(json.added.length > 0);
    assert.ok(!fs.existsSync(path.join(root, MAP)));
  });

  it('refuses to merge into an invalid map', (t) => {
    const { root } = makePolyglotMonorepo(t);
    writeJson(root, MAP, { version: 1, components: [{ name: 'Bad Name', path: 'services/x' }] });
    assert.strictEqual(cli(root, ['seed-map', '--merge']).code, 1);
  });
});

describe('scanContractKind', () => {
  it('classifies by file content and name', (t) => {
    const dir = tmp(t);
    const kind = (files) => {
      const sub = fs.mkdtempSync(path.join(dir, 'c-'));
      put(sub, files);
      return scanContractKind(sub);
    };
    assert.strictEqual(kind({ 'a/b.proto': 'syntax = "proto3";' }), 'proto');
    assert.strictEqual(kind({ 'api.yml': 'openapi: 3.1.0\n' }), 'openapi');
    assert.strictEqual(kind({ 'api.json': '{"openapi":"3.0.0"}' }), 'openapi');
    assert.strictEqual(kind({ 'events.yaml': 'asyncapi: 2.6.0\n' }), 'asyncapi');
    assert.strictEqual(kind({ 'order.schema.json': '{}' }), 'json-schema');
    assert.strictEqual(kind({ 'notes.yaml': 'title: nothing\n', 'readme.md': '# x' }), 'other');
    assert.strictEqual(kind({}), 'other');
  });

  it('stops at depth 3 and at 200 entries and ignores symlinks', (t) => {
    const dir = tmp(t);
    put(dir, { 'a/b/x.proto': '', 'deep/1/2/3/y.proto': '' });
    assert.strictEqual(scanContractKind(path.join(dir, 'a')), 'proto');
    assert.strictEqual(scanContractKind(path.join(dir, 'deep')), 'other');

    const many = path.join(dir, 'many');
    fs.mkdirSync(many);
    for (let i = 0; i < 205; i += 1) fs.writeFileSync(path.join(many, `f${String(i).padStart(3, '0')}.txt`), '');
    fs.writeFileSync(path.join(many, 'zzz.proto'), '');
    assert.strictEqual(scanContractKind(many), 'other');

    const linked = path.join(dir, 'linked');
    fs.mkdirSync(linked);
    fs.symlinkSync(path.join(dir, 'a'), path.join(linked, 'inner'));
    assert.strictEqual(scanContractKind(linked), 'other');
  });
});

describe('slugName', () => {
  it('lowercases and replaces unsupported characters', () => {
    assert.strictEqual(slugName('Admin_Web'), 'admin-web');
    assert.strictEqual(slugName('tcx-order'), 'tcx-order');
    assert.strictEqual(slugName('___'), null);
  });
});
