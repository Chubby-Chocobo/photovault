#!/usr/bin/env node
/**
 * The mega workspace's contract drift, plan scope and session-start lines, including the limits
 * the session hook applies: every member checked, 8 names listed, 50 scope entries.
 * Run: node --test .claude/skills/workspace/scripts/tests/mega-workspace-drift-scope.test.cjs
 */

'use strict';

const { describe, it, before } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const driftCache = require('../../../../hooks/lib/drift-cache.cjs');
const { computeDrift, summarizeDrift, SKIPPED_LINE } = require('../../../../hooks/lib/contract-drift.cjs');
const { buildWorkspaceContext } = require('../../../../hooks/lib/workspace-session-context.cjs');
const { loadScopeContext, agentScopePaths } = require('../../../../hooks/lib/scope-context.cjs');
const { loadManifest } = require('../../../../hooks/lib/workspace-manifest.cjs');
const { loadSystemMap } = require('../../../../hooks/lib/system-map.cjs');
const { PLAN_SLUG, megaWorkspace, isolateTmpdir, writeScopedPlan, suggestedPlan, cliJson } = require('./mega-workspace-test-helpers.cjs');

const CONFIG = { paths: { docs: 'docs', plans: 'plans' } };
const NO_PLAN = { path: null, resolvedBy: null };
const GENEROUS_BUDGET_MS = 10 * 60 * 1000;
const MISSING = ['apps/android-wallet', 'apps/ios-wallet', 'infra/observability', 'infra/secrets-vault', 'services/chat', 'services/insurance', 'services/loyalty', 'services/tax', 'services/voice'];

let ws;
before((t) => {
  const originalBudget = driftCache.SESSION_DRIFT_BUDGET_MS;
  driftCache.SESSION_DRIFT_BUDGET_MS = GENEROUS_BUDGET_MS;
  t.after(() => { driftCache.SESSION_DRIFT_BUDGET_MS = originalBudget; });
  isolateTmpdir(t);
  ws = megaWorkspace(t);
});

const sessionLines = (resolvedPlan = NO_PLAN) => buildWorkspaceContext({ baseDir: ws.root, config: CONFIG, shapeType: 'workspace', resolvedPlan, cwd: ws.root }).lines;
const findingTypes = (contract) => contract.findings.map((f) => f.type).sort();

describe('mega workspace: drift', () => {
  it('reports every finding kind across gitlinks, Cargo tags and npm URLs, and the nine members it cannot read', () => {
    const { code, json } = cliJson(ws.root, ['drift']);
    assert.strictEqual(code, 0);
    const proto = json.contracts.find((c) => c.id === 'nova-proto');
    assert.deepStrictEqual(findingTypes(proto), ['credential-in-url', 'differs', 'not-at-local-head', 'not-at-local-head', 'not-at-local-head', 'not-at-local-head', 'unpinned']);
    assert.strictEqual(proto.consumers.length, 8);
    assert.strictEqual(proto.consumers.find((c) => c.component === 'order').atLocalHead, true);
    assert.strictEqual(proto.consumers.find((c) => c.component === 'notification').reason, 'branch');
    assert.strictEqual(proto.consumers.find((c) => c.component === 'market').credentialInUrl, true);
    assert.deepStrictEqual(findingTypes(json.contracts.find((c) => c.id === 'nova-events')), ['differs']);
    assert.deepStrictEqual(json.contracts.find((c) => c.id === 'nova-openapi').consumers, []);
    assert.strictEqual(json.missingMembers.length, 9);
    assert.ok(!JSON.stringify(json).includes(ws.token), 'the Cargo URL is stripped before it is reported');
  });

  it('--fail-on turns the chosen findings into exit 1, and a missing member fails unless --allow-missing', () => {
    assert.strictEqual(cliJson(ws.root, ['drift', '--fail-on', 'unpinned', '--allow-missing']).code, 1);
    assert.strictEqual(cliJson(ws.root, ['drift', '--fail-on', 'unreadable']).code, 1, 'nine members are not cloned');
    assert.strictEqual(cliJson(ws.root, ['drift', '--fail-on', 'unreadable', '--allow-missing']).code, 0);
  });

  it('the session line counts versions and consumers; a tiny budget truncates to the skipped line instead of blocking', () => {
    const manifest = loadManifest(ws.root).manifest;
    const { map } = loadSystemMap(ws.root, 'docs', { manifest });
    const full = computeDrift({ root: ws.root, map, manifest, budgetMs: GENEROUS_BUDGET_MS });
    assert.strictEqual(full.truncated, false);
    assert.strictEqual(summarizeDrift(full), 'Contract drift: nova-events pinned at 2 versions across 2 consumers; nova-proto pinned at 7 versions across 8 consumers (1 at local HEAD); 1 unpinned git dependency; 1 URL with embedded credentials. Details: /adf-brief or workspace.cjs drift');
    assert.strictEqual(computeDrift({ root: ws.root, map, manifest, budgetMs: 0 }).truncated, true);
    // The cache key follows the manifest mtime: a new mtime forces a fresh computation under each budget
    const manifestFile = path.join(ws.root, 'adf-workspace.json');
    const bumpMtime = (seconds) => fs.utimesSync(manifestFile, new Date(), new Date(Date.now() + seconds * 1000));
    driftCache.SESSION_DRIFT_BUDGET_MS = 0;
    bumpMtime(1);
    assert.ok(sessionLines().includes(SKIPPED_LINE), 'the session shows the skipped line rather than waiting');
    driftCache.SESSION_DRIFT_BUDGET_MS = GENEROUS_BUDGET_MS;
    bumpMtime(2);
    assert.ok(sessionLines().some((l) => l.startsWith('Contract drift: nova-events pinned')), 'a new key with the real budget computes the full line again');
  });
});

describe('mega workspace: session lines and their limits', () => {
  it('checks every member for the Workspace line, including the missing ones past the 50th', () => {
    const line = sessionLines().find((l) => l.startsWith('Workspace:'));
    assert.strictEqual(line, `Workspace: nova (74 members; missing: ${MISSING.slice(0, 8).join(', ')} +1 more; run "node .claude/skills/workspace/scripts/workspace.cjs bootstrap")`);
    const manifest = loadManifest(ws.root).manifest;
    assert.ok(manifest.members.findIndex((m) => m.path === 'services/voice') >= 50, 'services/voice sits past the 50th member');
  });

  it('prints the search and map lines only when something is wrong, and the drift line from the computed result', () => {
    const lines = sessionLines();
    assert.ok(!lines.some((l) => l.startsWith('Search:')), 'both ignore blocks list bots and sdks after the second init');
    assert.ok(!lines.some((l) => l.startsWith('No system map')));
    assert.ok(lines.some((l) => l.startsWith('Contract drift: nova-events pinned at 2 versions')), lines.join('\n'));
  });
});

describe('mega workspace: plan scope', () => {
  it('a contract id in the scope resolves to its directory and expands to its consumers and producer, listed up to 8', () => {
    const planDir = writeScopedPlan(ws);
    const { code, json } = cliJson(ws.root, ['scope', '--plan', planDir]);
    assert.strictEqual(code, 0, JSON.stringify(json));
    assert.deepStrictEqual(json.paths, ['services/order', 'contracts/nova-proto']);
    assert.deepStrictEqual(json.expansion.map((e) => e.path), ['services/auth', 'services/gateway', 'services/legacy-core', 'services/market', 'services/notification', 'services/settlement', 'services/trading', 'services/matching-engine']);
    assert.strictEqual(JSON.stringify(json.expansion).split('producer').length - 1, 1, 'matching-engine is the one producer');
    const line = sessionLines(suggestedPlan(ws)).find((l) => l.startsWith('Scope:'));
    assert.strictEqual(line, 'Scope: services/order, contracts/nova-proto (from suggested plan; contract change adds services/auth, services/gateway, services/legacy-core, services/market, services/notification, services/settlement, services/trading, services/matching-engine). Search and edit inside these paths first.');
    const subagent = agentScopePaths(loadScopeContext({ baseDir: ws.root, config: CONFIG, resolvedPlan: suggestedPlan(ws), cwd: ws.root }));
    assert.strictEqual(subagent.length, 10, 'two scope paths plus eight expansions reach every subagent');
  });

  it('drops entries that are neither a path nor a name, and everything past the 50th, and says how many', () => {
    const names = ws.map.components.map((c) => c.name);
    const entries = [...names.slice(0, 48), 'no-such-component', '../outside', ...names.slice(48, 55)];
    writeScopedPlan(ws, `[${entries.join(', ')}]`);
    const { json } = cliJson(ws.root, ['scope', '--plan', `plans/${PLAN_SLUG}`]);
    assert.strictEqual(json.paths.length, 48, 'the two bad entries sit inside the first 50 and resolve to nothing');
    assert.strictEqual(json.dropped, 9, 'two bad entries plus the seven past the 50th');
    assert.ok(sessionLines(suggestedPlan(ws)).find((l) => l.startsWith('Scope:')).includes('9 scope entries ignored'));
  });
});
