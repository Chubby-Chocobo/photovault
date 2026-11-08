#!/usr/bin/env node
/**
 * Tests for the contract drift line of workspace-session-context.cjs
 * Run: node --test .claude/hooks/lib/__tests__/workspace-session-drift.test.cjs
 */

'use strict';

const { describe, it, before, after } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { git } = require('../../../skills/workspace/scripts/tests/workspace-test-helpers.cjs');
const { buildWorkspaceContext } = require('../workspace-session-context.cjs');
const driftCache = require('../drift-cache.cjs');
const { scopeWorkspace, scopeMonorepo, readMap, writeMap } = require('./scope-test-fixtures.cjs');

const CONFIG = { paths: { docs: 'docs', plans: 'plans' } };
const NO_PLAN = { path: null, resolvedBy: null };
const LINE = 'Contract drift: tcx-proto pinned at 3 commits across 3 consumers (none at local HEAD); 2 unpinned git dependencies. Details: /adf-brief or workspace.cjs drift';

// The real 2 s budget makes a complete line depend on machine load; only the truncation test uses a tiny one
const GENEROUS_BUDGET_MS = 10 * 60 * 1000;

let tmp;
const originalTmp = process.env.TMPDIR;
const originalBudget = driftCache.SESSION_DRIFT_BUDGET_MS;
before(() => {
  tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'adf-session-drift-tmp-'));
  process.env.TMPDIR = tmp;
  driftCache.SESSION_DRIFT_BUDGET_MS = GENEROUS_BUDGET_MS;
});
after(() => {
  driftCache.SESSION_DRIFT_BUDGET_MS = originalBudget;
  process.env.TMPDIR = originalTmp;
  fs.rmSync(tmp, { recursive: true, force: true });
});

const drift = (root, shapeType = 'workspace') => buildWorkspaceContext({ baseDir: root, config: CONFIG, shapeType, resolvedPlan: NO_PLAN, cwd: root }).lines.filter((l) => l.startsWith('Contract drift'));

describe('drift line', () => {
  it('summarizes the TCX workspace in one line', (t) => {
    const { root } = scopeWorkspace(t);
    assert.deepStrictEqual(drift(root), [LINE]);
  });

  it('is served from the cache on the second call, without spawning git', (t) => {
    const { root } = scopeWorkspace(t);
    const script = `
      const cp = require('node:child_process');
      let spawned = 0;
      for (const name of ['spawn', 'spawnSync', 'exec', 'execSync', 'execFile', 'execFileSync', 'fork']) {
        const original = cp[name];
        cp[name] = (...args) => { spawned += 1; return original(...args); };
      }
      require(${JSON.stringify(path.join(__dirname, '..', 'drift-cache.cjs'))}).SESSION_DRIFT_BUDGET_MS = ${GENEROUS_BUDGET_MS};
      const { buildWorkspaceContext } = require(${JSON.stringify(path.join(__dirname, '..', 'workspace-session-context.cjs'))});
      const args = { baseDir: ${JSON.stringify(root)}, config: { paths: { docs: 'docs' } }, shapeType: 'workspace', resolvedPlan: { path: null, resolvedBy: null }, cwd: ${JSON.stringify(root)} };
      const first = buildWorkspaceContext(args).lines.find((l) => l.startsWith('Contract drift'));
      const afterFirst = spawned;
      const second = buildWorkspaceContext(args).lines.find((l) => l.startsWith('Contract drift'));
      process.stdout.write(JSON.stringify({ first, second, firstSpawned: afterFirst, secondSpawned: spawned - afterFirst }));
    `;
    const r = spawnSync(process.execPath, ['-e', script], { encoding: 'utf8', env: { ...process.env, TMPDIR: tmp } });
    const out = JSON.parse(r.stdout);
    assert.ok(out.firstSpawned > 0, 'a miss computes with git');
    assert.strictEqual(out.secondSpawned, 0);
    assert.strictEqual(out.second, out.first);
    assert.strictEqual(out.first, LINE);
  });

  it('recomputes when a pin file changes', (t) => {
    const { root, members } = scopeWorkspace(t);
    assert.deepStrictEqual(drift(root), [LINE]);
    fs.writeFileSync(path.join(members['admin-web'], 'package.json'), JSON.stringify({ name: 'admin-web', dependencies: { 'ui-kit': 'github:acme/ui-kit' } }));
    assert.deepStrictEqual(drift(root), [LINE.replace('2 unpinned git dependencies', '1 unpinned git dependency')]);
  });

  it('is absent when every consumer shares one pinned ref and nothing is unpinned', (t) => {
    const { root, members, protoCommits } = scopeWorkspace(t);
    for (const name of ['order', 'gateway', 'core']) {
      git(members[name], 'update-index', '--cacheinfo', `160000,${protoCommits[3]},src/protos`);
      git(members[name], 'commit', '--quiet', '-m', 'bump');
    }
    fs.writeFileSync(path.join(members['admin-web'], 'package.json'), JSON.stringify({ name: 'admin-web' }));
    assert.deepStrictEqual(drift(root), []);
  });

  it('says it was skipped when the budget runs out, and caches that answer', (t) => {
    const { root } = scopeWorkspace(t);
    const saved = driftCache.SESSION_DRIFT_BUDGET_MS;
    driftCache.SESSION_DRIFT_BUDGET_MS = 0;
    try {
      assert.deepStrictEqual(drift(root), ['Contract drift: skipped (slow); run workspace.cjs drift']);
    } finally { driftCache.SESSION_DRIFT_BUDGET_MS = saved; }
    assert.deepStrictEqual(drift(root), ['Contract drift: skipped (slow); run workspace.cjs drift']);
  });

  it('keeps the skipped answer only for the short TTL, and a complete drift run replaces it', (t) => {
    const { root } = scopeWorkspace(t);
    const saved = driftCache.SESSION_DRIFT_BUDGET_MS;
    driftCache.SESSION_DRIFT_BUDGET_MS = 0;
    try { drift(root); } finally { driftCache.SESSION_DRIFT_BUDGET_MS = saved; }
    const entries = fs.readdirSync(tmp).filter((f) => /^adf-drift-cache-.*\.json$/.test(f)).map((f) => JSON.parse(fs.readFileSync(path.join(tmp, f), 'utf8')));
    // Other tests cache entries whose line is null (nothing to report), so only string lines are inspected
    assert.ok(entries.some((e) => e.data && typeof e.data.line === 'string' && e.data.line.includes('skipped') && e.ttlMs === driftCache.TRUNCATED_DRIFT_TTL_MS));
    const outcome = require('../../../skills/workspace/scripts/lib/drift-command.cjs').run({ root, docsRel: 'docs', opts: {} });
    assert.strictEqual(outcome.code, 0);
    assert.deepStrictEqual(drift(root), [LINE]);
  });

  it('shows no line in a monorepo whose contracts live in the tree, or without a map', (t) => {
    const { root } = scopeMonorepo(t);
    assert.deepStrictEqual(drift(root, 'monorepo'), []);
    fs.rmSync(path.join(root, 'docs/architecture/system-map.json'));
    assert.deepStrictEqual(drift(root, 'monorepo'), []);
  });

  it('works in a monorepo whose contract has a repo', (t) => {
    const { root } = scopeMonorepo(t);
    const map = readMap(root);
    map.org = ['acme'];
    map.contracts[0].repo = 'https://github.com/acme/proto.git';
    writeMap(root, map);
    fs.writeFileSync(path.join(root, 'services/order/package.json'), JSON.stringify({ dependencies: { proto: 'github:acme/proto#main' } }));
    fs.writeFileSync(path.join(root, 'services/gateway/package.json'), JSON.stringify({ dependencies: { proto: 'github:acme/proto#v1.0.0' } }));
    assert.deepStrictEqual(drift(root, 'monorepo'), ['Contract drift: proto pinned at 2 versions across 2 consumers; 1 unpinned git dependency. Details: /adf-brief or workspace.cjs drift']);
  });

  it('shows nothing for a broken manifest', (t) => {
    const { root } = scopeWorkspace(t);
    fs.writeFileSync(path.join(root, 'adf-workspace.json'), '{ nope');
    assert.deepStrictEqual(drift(root), []);
  });
});
