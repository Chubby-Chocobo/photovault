#!/usr/bin/env node
/**
 * Tests for `workspace scaffold`: refused input, unsafe directories and the monorepo shape
 * Run: node --test .claude/skills/workspace/scripts/tests/scaffold-edge-cases.test.cjs
 */

'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { makePolyglotMonorepo } = require('../../../../hooks/__tests__/fixtures/workspace-fixtures.cjs');
const { cli, cliJson, scaffoldWorkspace, outsideDir, readJson, writeJson, MAP } = require('./workspace-test-helpers.cjs');
const scaffold = require('../lib/scaffold-command.cjs');

const read = (root, rel) => fs.readFileSync(path.join(root, rel), 'utf8');
const statusOf = (json, file) => json.files.find((f) => f.path === file).status;

describe('scaffold: refused input and unsafe directories', () => {
  it('rejects a bad --only, an unknown component and extra arguments with exit 2', (t) => {
    const { root } = scaffoldWorkspace(t);
    for (const argv of [['scaffold', '--only', 'everything'], ['scaffold', 'nope'], ['scaffold', 'a', 'b']]) {
      const r = cliJson(root, argv);
      assert.strictEqual(r.code, 2, argv.join(' '));
      assert.strictEqual(r.json.ok, false);
    }
  });

  it('skips a symlinked component directory and writes nothing through it', (t) => {
    const { root } = scaffoldWorkspace(t);
    const outside = outsideDir(t);
    fs.rmSync(path.join(root, 'services/trading'), { recursive: true, force: true });
    fs.symlinkSync(outside, path.join(root, 'services/trading'));
    const r = cliJson(root, ['scaffold']);
    assert.deepStrictEqual([statusOf(r.json, 'services/trading/CLAUDE.md'), r.json.files.find((f) => f.path === 'services/trading/CLAUDE.md').reason], ['skipped', 'symlink']);
    assert.deepStrictEqual(fs.readdirSync(outside), []);
  });

  it('does not follow a symlinked CLAUDE.md', (t) => {
    const { root } = scaffoldWorkspace(t);
    const outside = outsideDir(t);
    const target = path.join(outside, 'victim.md');
    fs.symlinkSync(target, path.join(root, 'services/order/CLAUDE.md'));
    const r = cliJson(root, ['scaffold']);
    assert.strictEqual(statusOf(r.json, 'services/order/CLAUDE.md'), 'kept');
    assert.ok(!fs.existsSync(target));
  });

  it('fails with a pointer to seed-map when there is no system map', (t) => {
    const { root } = scaffoldWorkspace(t);
    fs.rmSync(path.join(root, MAP));
    const r = cliJson(root, ['scaffold']);
    assert.strictEqual(r.code, 1);
    assert.match(r.json.errors[0], /seed-map/);
  });
});

describe('scaffold: a monorepo', () => {
  it('writes component files at the monorepo root docs and nothing inside components but AGENTS.md and CLAUDE.md', (t) => {
    const { root } = makePolyglotMonorepo(t);
    assert.strictEqual(cli(root, ['seed-map']).code, 0);
    const r = cliJson(root, ['scaffold']);
    assert.strictEqual(r.code, 0, JSON.stringify(r.json));
    assert.match(read(root, 'services/gateway/AGENTS.md'), /## NestJS notes/);
    assert.match(read(root, 'apps/admin-web/AGENTS.md'), /## Vue notes/);
    assert.match(read(root, 'services/ranker/AGENTS.md'), /- Test: `pytest`/);
    assert.match(read(root, 'services/billing/AGENTS.md'), /## Stack notes/);
    assert.ok(fs.existsSync(path.join(root, 'docs/architecture/services/gateway.md')));
    assert.deepStrictEqual(fs.readdirSync(path.join(root, 'services/gateway')).sort(), ['AGENTS.md', 'CLAUDE.md', 'package.json']);
  });
});

describe('scaffold: the docs directory', () => {
  /** Runs scaffold with a given `paths.docs`, after moving the docs dir there. */
  function inDocsDir(t, name, opts = {}) {
    const { root } = scaffoldWorkspace(t);
    fs.renameSync(path.join(root, 'docs'), path.join(root, name));
    return { root, outcome: scaffold.run({ root, docsRel: name, opts: { _: ['scaffold'], ...opts } }) };
  }

  it('finds the map and writes service docs in a docs dir that contains a space', (t) => {
    const { root, outcome } = inDocsDir(t, 'my docs');
    assert.strictEqual(outcome.code, 0, outcome.text);
    assert.ok(fs.existsSync(path.join(root, 'my docs/architecture/services/order.md')));
    assert.ok(!fs.existsSync(path.join(root, 'docs')), 'no docs dir is invented');
    assert.match(read(root, 'services/order/AGENTS.md'), /`my docs\/architecture\/services\/order\.md`/);
  });

  it('fails loudly when the docs dir is not plain text and CLAUDE.md files are requested', (t) => {
    const { root, outcome } = inDocsDir(t, 'documentation (v2)');
    assert.strictEqual(outcome.code, 1);
    assert.match(outcome.text, /paths\.docs must be plain text/);
    assert.ok(!fs.existsSync(path.join(root, 'services/order/CLAUDE.md')));
    assert.ok(!fs.existsSync(path.join(root, 'docs')));
  });

  it('still writes service docs in such a dir with --only service-docs', (t) => {
    const { root, outcome } = inDocsDir(t, 'documentation (v2)', { only: 'service-docs' });
    assert.strictEqual(outcome.code, 0, outcome.text);
    assert.ok(fs.existsSync(path.join(root, 'documentation (v2)/architecture/services/order.md')));
  });

  for (const linked of ['docs/architecture/services', 'docs/architecture']) {
    it(`writes nothing through a symlinked ${linked}`, (t) => {
      const { root } = scaffoldWorkspace(t);
      const outside = outsideDir(t);
      const link = path.join(root, linked);
      if (linked.endsWith('services')) fs.symlinkSync(outside, link);
      else {
        fs.cpSync(link, path.join(outside, 'architecture'), { recursive: true });
        fs.rmSync(link, { recursive: true });
        fs.symlinkSync(path.join(outside, 'architecture'), link);
      }
      const before = fs.readdirSync(linked.endsWith('services') ? outside : path.join(outside, 'architecture'));
      const r = cliJson(root, ['scaffold']);
      assert.strictEqual(r.code, 0, JSON.stringify(r.json));
      const docs = r.json.files.filter((f) => f.kind === 'service-doc');
      assert.ok(docs.length > 0 && docs.every((f) => f.status === 'skipped' && f.reason === 'symlink'));
      assert.deepStrictEqual(fs.readdirSync(linked.endsWith('services') ? outside : path.join(outside, 'architecture')), before);
      assert.strictEqual(statusOf(r.json, 'services/order/CLAUDE.md'), 'written', 'component files are unaffected');
    });
  }
});

describe('scaffold: a missing subpath', () => {
  it('reports not found, not not cloned, for a subpath inside a cloned member', (t) => {
    const { root } = scaffoldWorkspace(t);
    const map = readJson(root, MAP);
    map.components.push({ name: 'order-api', member: 'order', subpath: 'api', role: 'backend' });
    writeJson(root, MAP, map);
    const r = cliJson(root, ['scaffold']);
    const file = r.json.files.find((f) => f.path === 'services/order/api/CLAUDE.md');
    assert.deepStrictEqual([file.status, file.reason], ['skipped', 'not found']);
    assert.ok(!fs.existsSync(path.join(root, 'services/order/api')));
  });
});
