#!/usr/bin/env node
/**
 * The mega workspace through shape detection, init, check, manifest repair and bootstrap.
 * The tests run in order on one fixture, as the walkthrough does (scripts/demo-mega-workspace.cjs).
 * Run: node --test .claude/skills/workspace/scripts/tests/mega-workspace-setup.test.cjs
 */

'use strict';

const { describe, it, before } = require('node:test');
const assert = require('node:assert');
const { detectRepoShape } = require('../../../../hooks/lib/repo-shape-detector.cjs');
const { consumersOf, loadSystemMap } = require('../../../../hooks/lib/system-map.cjs');
const { loadManifest } = require('../../../../hooks/lib/workspace-manifest.cjs');
const { ORGS, megaAfterInit, repairManifest, dropSymlinkedMember, cliJson, readJson, MAP } = require('./mega-workspace-test-helpers.cjs');

const has = (list, fragment) => list.some((m) => m.includes(fragment));
let ws;
before((t) => { ws = megaAfterInit(t); });

describe('mega workspace: shapes', () => {
  it('is a workspace candidate with 59 nested repos before init and a workspace after', () => {
    assert.strictEqual(ws.shapeBefore.type, 'single-repo');
    assert.strictEqual(ws.shapeBefore.hint, 'workspace-candidate');
    assert.strictEqual(ws.shapeBefore.nestedRepos.length, 59, 'bots/ and sdks/ are not default role dirs');
    assert.strictEqual(detectRepoShape(ws.root).type, 'workspace');
  });

  it('sees the platform member as a monorepo and legacy-core as a superproject with one vendored and one sibling submodule', () => {
    const platform = detectRepoShape(ws.members.platform);
    assert.strictEqual(platform.type, 'monorepo');
    assert.deepStrictEqual(platform.signals, ['go.work', 'nx.json', 'services/+apps/']);
    const legacy = detectRepoShape(ws.members['legacy-core'], { orgs: ORGS });
    assert.strictEqual(legacy.type, 'superproject');
    assert.deepStrictEqual(legacy.submodules.map((s) => [s.path, s.kind]), [['lib/forge-std', 'vendored'], ['deps/nova-proto', 'sibling']]);
  });
});

describe('mega workspace: init', () => {
  it('lists the 59 members under the default role dirs, writes no token, and notes the member without an origin', () => {
    assert.strictEqual(ws.init.members.length, 59);
    assert.ok(!ws.init.members.includes('ts-sdk') && !ws.init.members.includes('liquidator-bot'));
    assert.deepStrictEqual(ws.init.notes, ['services/scheduler: no origin remote, member written without repo', 'owner not in org, so not trusted: support (vendorx); add an owner to org only if the team trusts it']);
    assert.deepStrictEqual(ws.init.remoteFixes.map((f) => f.command), ['git -C services/market remote set-url origin https://github.com/acme/nova-market.git']);
    assert.ok(!JSON.stringify(ws.init).includes(ws.token), 'the token never appears in the output');
    const { manifest, errors } = loadManifest(ws.root);
    assert.deepStrictEqual(errors, []);
    assert.deepStrictEqual(manifest.org, ORGS);
    assert.strictEqual(manifest.members.find((m) => m.name === 'market').repo, 'https://github.com/acme/nova-market.git');
    assert.strictEqual(manifest.members.find((m) => m.name === 'compliance').repo, 'https://gitlab.com/nova-client/nova-compliance.git');
    assert.strictEqual(manifest.members.find((m) => m.name === 'scheduler').repo, undefined);
  });

  it('check passes: the untrusted owner and the member without a repo are warnings, the archetype gap is information', () => {
    const { code, json } = cliJson(ws.root, ['check']);
    assert.strictEqual(code, 0, JSON.stringify(json.errors));
    assert.strictEqual(json.members.length, 59);
    assert.ok(json.members.every((m) => m.state === 'cloned'));
    assert.deepStrictEqual(json.map, { components: 54, contracts: 5 });
    assert.ok(has(json.warnings, 'member support: owner vendorx is not in org'), json.warnings.join('\n'));
    assert.ok(has(json.warnings, '(scheduler) has no repo'));
    assert.ok(!has(json.warnings, 'compliance'), 'a trusted owner on another host is fine');
    assert.deepStrictEqual(json.info, ['archetype exchange: no component with role admin']);
  });

  it('seeds the map: contract kinds from their files, roles from the name, then the archetype aliases, then the stack', () => {
    const map = readJson(ws.root, MAP);
    const kinds = Object.fromEntries(map.contracts.map((c) => [c.id, c.kind]));
    assert.deepStrictEqual(kinds, { 'nova-abi': 'other', 'nova-events': 'json-schema', 'nova-openapi': 'openapi', 'nova-proto': 'proto', 'nova-streams': 'asyncapi' });
    const role = (name) => { const c = map.components.find((x) => x.name === name); return [c.role, c.stack]; };
    assert.deepStrictEqual(role('gateway'), ['gateway', 'nestjs']);
    assert.deepStrictEqual(role('fiat-gateway'), ['gateway', 'nestjs'], 'the last - segment matches an archetype alias');
    assert.deepStrictEqual(role('admin-web'), ['frontend', 'vue'], 'web (last segment) wins over the admin alias');
    assert.deepStrictEqual(role('auth'), ['auth', 'nestjs']);
    assert.deepStrictEqual(role('matching-engine'), ['engine', 'maven']);
    assert.deepStrictEqual(role('mobile'), ['mobile', 'react-native']);
    assert.deepStrictEqual(role('k8s-deploy'), ['infra', undefined], 'an unknown stack is left out of the map');
    assert.deepStrictEqual(role('wallet'), ['unknown', undefined], 'Go has no stack marker and wallet no role alias');
    assert.deepStrictEqual(role('risk'), ['backend', 'python'], 'the stack fallback gives python services the backend role');
    assert.strictEqual(map.archetype, 'exchange');
  });

  it('infers consumers from the pins it can read: gitlinks, Cargo git tags and npm git URLs', () => {
    const { map } = loadSystemMap(ws.root, 'docs', { manifest: loadManifest(ws.root).manifest });
    assert.deepStrictEqual(consumersOf(map, 'nova-proto').map((c) => c.name).sort(), ['auth', 'gateway', 'legacy-core', 'market', 'notification', 'order', 'settlement', 'trading']);
    assert.deepStrictEqual(consumersOf(map, 'nova-events').map((c) => c.name).sort(), ['analytics', 'webhook']);
    assert.deepStrictEqual(consumersOf(map, 'nova-openapi'), [], 'nothing pins the OpenAPI repo');
  });
});

describe('mega workspace: manifest repair and bootstrap', () => {
  it('after the repair, check fails on the symlinked member and warns on the ten that are not cloned', () => {
    repairManifest(ws, { withSymlink: true });
    const { code, json } = cliJson(ws.root, ['check']);
    assert.strictEqual(code, 1);
    assert.deepStrictEqual(json.errors, ['member shared-kernel: services/shared-kernel is a symlink or leaves the workspace']);
    assert.strictEqual(json.members.length, 75);
    assert.strictEqual(json.members.filter((m) => m.state === 'missing').length, 10);
    assert.strictEqual(json.members.find((m) => m.name === 'shared-kernel').state, 'symlink');
    assert.ok(has(json.warnings, '(fraud).repo is local; other machines cannot clone it'));
    assert.ok(!has(json.warnings, 'managed block is out of date'), 'the second init refreshed both ignore blocks for bots and sdks');
  });

  it('without the symlink it is warnings only; bootstrap refuses the local mirror until --allow-local', () => {
    dropSymlinkedMember(ws);
    assert.strictEqual(cliJson(ws.root, ['check']).code, 0);
    const refused = cliJson(ws.root, ['bootstrap', '--only', 'fraud']);
    assert.strictEqual(refused.code, 1);
    assert.ok(JSON.stringify(refused.json).includes('pass --allow-local'), JSON.stringify(refused.json));
    const cloned = cliJson(ws.root, ['bootstrap', '--only', 'fraud', '--allow-local']);
    assert.strictEqual(cloned.code, 0, JSON.stringify(cloned.json));
    const { json } = cliJson(ws.root, ['check']);
    assert.strictEqual(json.members.filter((m) => m.state === 'missing').length, 9);
    assert.strictEqual(json.members.find((m) => m.name === 'fraud').state, 'cloned');
  });
});
