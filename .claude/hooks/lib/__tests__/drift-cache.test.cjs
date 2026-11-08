#!/usr/bin/env node
/**
 * Tests for drift-cache.cjs
 * Run: node --test .claude/hooks/lib/__tests__/drift-cache.test.cjs
 */

'use strict';

const { describe, it, before, after } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { git } = require('../../../skills/workspace/scripts/tests/workspace-test-helpers.cjs');
const { loadManifest } = require('../workspace-manifest.cjs');
const { loadSystemMap } = require('../system-map.cjs');
const { driftTargets, watchedFiles } = require('../drift-targets.cjs');
const cache = require('../drift-cache.cjs');
const { scopeWorkspace } = require('./scope-test-fixtures.cjs');

let tmp;
const originalTmp = process.env.TMPDIR;
before(() => { tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'adf-drift-cache-test-')); process.env.TMPDIR = tmp; });
after(() => { process.env.TMPDIR = originalTmp; fs.rmSync(tmp, { recursive: true, force: true }); });

function keyOf(root) {
  const { manifest } = loadManifest(root);
  const { map } = loadSystemMap(root, 'docs', { manifest });
  return cache.driftCacheKey(watchedFiles({ root, docsRel: 'docs', targets: driftTargets({ root, map, manifest }) }));
}

describe('constants', () => {
  it('holds the validated TTL and budgets', () => {
    assert.strictEqual(cache.DRIFT_CACHE_TTL_MS, 600000);
    assert.strictEqual(cache.TRUNCATED_DRIFT_TTL_MS, 60000);
    assert.strictEqual(cache.SESSION_DRIFT_BUDGET_MS, 2000);
    assert.strictEqual(cache.BRIEF_DRIFT_BUDGET_MS, 5000);
  });

  it('is the only file in hooks, skills and agents that spells them out', () => {
    const claude = path.join(__dirname, '..', '..', '..');
    const hits = require('node:child_process').spawnSync('grep', ['-rlE', '--include=*.cjs', '--exclude=*.test.cjs', '--exclude-dir=node_modules', '--exclude-dir=.venv', '\\b(600000|600_000)\\b', path.join(claude, 'hooks', 'lib'), path.join(claude, 'skills', 'workspace'), path.join(claude, 'skills', 'adf-brief')], { encoding: 'utf8' }).stdout.trim().split('\n').filter(Boolean);
    assert.deepStrictEqual(hits.map((h) => path.basename(h)), ['drift-cache.cjs']);
  });
});

describe('cache', () => {
  it('serves a hit within the TTL and a miss for another key or root', (t) => {
    const { root } = scopeWorkspace(t);
    const key = keyOf(root);
    assert.strictEqual(cache.readCachedDrift(root, key), null);
    cache.writeCachedDrift(root, key, { line: 'x' });
    assert.deepStrictEqual(cache.readCachedDrift(root, key), { line: 'x' });
    assert.strictEqual(cache.readCachedDrift(root, 'other-key'), null);
    assert.strictEqual(cache.readCachedDrift(`${root}-2`, key), null);
  });

  it('expires after the TTL', (t) => {
    const { root } = scopeWorkspace(t);
    const key = keyOf(root);
    const now = Date.now();
    cache.writeCachedDrift(root, key, { line: null }, { now });
    assert.deepStrictEqual(cache.readCachedDrift(root, key, { now: now + cache.DRIFT_CACHE_TTL_MS - 1 }), { line: null });
    assert.strictEqual(cache.readCachedDrift(root, key, { now: now + cache.DRIFT_CACHE_TTL_MS }), null);
  });

  it('keeps a truncated result for its shorter TTL only, and never longer than the default', (t) => {
    const { root } = scopeWorkspace(t);
    const key = keyOf(root);
    const now = Date.now();
    cache.writeCachedDrift(root, key, { line: 'skipped' }, { now, ttlMs: cache.TRUNCATED_DRIFT_TTL_MS });
    assert.deepStrictEqual(cache.readCachedDrift(root, key, { now: now + cache.TRUNCATED_DRIFT_TTL_MS - 1 }), { line: 'skipped' });
    assert.strictEqual(cache.readCachedDrift(root, key, { now: now + cache.TRUNCATED_DRIFT_TTL_MS }), null);
    cache.writeCachedDrift(root, key, { line: 'long' }, { now, ttlMs: cache.DRIFT_CACHE_TTL_MS * 10 });
    assert.strictEqual(cache.readCachedDrift(root, key, { now: now + cache.DRIFT_CACHE_TTL_MS }), null);
  });

  it('changes the key when a member Cargo.toml, package.json, .gitmodules or .git/index changes', (t) => {
    const { root, members } = scopeWorkspace(t);
    const stat = (file, ms) => fs.utimesSync(file, new Date(ms), new Date(ms));
    const base = keyOf(root);
    assert.strictEqual(keyOf(root), base);
    const cargo = path.join(members.trading, 'Cargo.toml');
    stat(cargo, Date.now() + 5000);
    const afterCargo = keyOf(root);
    assert.notStrictEqual(afterCargo, base);
    stat(path.join(members.core, '.gitmodules'), Date.now() + 6000);
    const afterModules = keyOf(root);
    assert.notStrictEqual(afterModules, afterCargo);
    stat(path.join(members['admin-web'], 'package.json'), Date.now() + 7000);
    const afterPackage = keyOf(root);
    assert.notStrictEqual(afterPackage, afterModules);
    git(members.order, 'commit', '--quiet', '--allow-empty', '-m', 'touch index');
    fs.writeFileSync(path.join(members.order, 'x.txt'), 'x');
    git(members.order, 'add', 'x.txt');
    assert.notStrictEqual(keyOf(root), afterPackage);
  });

  it('changes the key when a member is cloned or removed', (t) => {
    const { root, members } = scopeWorkspace(t);
    const base = keyOf(root);
    fs.rmSync(members.trading, { recursive: true, force: true });
    assert.notStrictEqual(keyOf(root), base);
  });

  it('is fail-open: an unwritable or missing tmpdir and a corrupt entry never throw', (t) => {
    const { root } = scopeWorkspace(t);
    const key = keyOf(root);
    const saved = process.env.TMPDIR;
    process.env.TMPDIR = path.join(tmp, 'no', 'such', 'dir');
    try {
      assert.doesNotThrow(() => cache.writeCachedDrift(root, key, { line: 'x' }));
      assert.strictEqual(cache.readCachedDrift(root, key), null);
    } finally { process.env.TMPDIR = saved; }
    cache.writeCachedDrift(root, key, { line: 'x' });
    const overwrite = (text) => {
      for (const f of fs.readdirSync(tmp).filter((name) => /^adf-drift-cache-.*\.json$/.test(name))) fs.writeFileSync(path.join(tmp, f), text);
    };
    overwrite('{ broken');
    assert.strictEqual(cache.readCachedDrift(root, key), null);
    overwrite(JSON.stringify({ timestamp: Date.now(), key, data: 'text' }));
    assert.strictEqual(cache.readCachedDrift(root, key), null);
  });
});
