'use strict';

// The mega workspace at the two states the walkthrough reaches: right after the first `init`
// (59 members under the default role dirs) and after the manifest repair (bots and sdks listed, ten
// manifest-only members, fraud cloned from its mirror, the symlinked member dropped, the map merged
// and edited). Building it costs a few seconds, so each test file builds once in `before((t) => ...)`;
// the hook's context registers the cleanup, which node:test runs even when the hook throws.

const fs = require('node:fs');
const path = require('node:path');
const { makeMegaWorkspace } = require('../../../../hooks/__tests__/fixtures/mega-workspace-fixture.cjs');
const { detectRepoShape } = require('../../../../hooks/lib/repo-shape-detector.cjs');
const { cliJson, readJson, writeJson, editManifest, MAP } = require('./workspace-test-helpers.cjs');
const steps = require('./mega-workspace-steps.cjs');

const ORGS = ['acme', 'nova-client'];
const INIT_ARGS = ['init', '--workspace', '--client', 'nova', '--product', 'nova', '--org', ORGS.join(','), '--archetype', 'exchange'];

const run = (root, argv, what) => {
  const r = cliJson(root, argv);
  if (r.code !== 0) throw new Error(`${what} failed: ${JSON.stringify(r.json)}`);
  return r.json;
};

/** Build the fixture and run the first init; `shapeBefore` is the detector's answer before the manifest existed. */
function megaAfterInit(t) {
  const ws = makeMegaWorkspace(t);
  const shapeBefore = detectRepoShape(ws.root, { orgs: ORGS });
  return { ...ws, init: run(ws.root, INIT_ARGS, 'init'), shapeBefore };
}

/** Repair the manifest, then re-run init so the ignore blocks follow the new role dirs. */
function repairManifest(ws, opts) {
  editManifest(ws.root, (m) => steps.repairManifest(m, ws, opts));
  run(ws.root, ['init'], 'second init');
}

function dropSymlinkedMember(ws) {
  editManifest(ws.root, (m) => { m.members = m.members.filter((x) => x.name !== ws.symlinked.name); });
}

/** The repaired workspace: 74 members, 65 cloned (fraud from its mirror), map merged and edited. */
function megaWorkspace(t) {
  const ws = megaAfterInit(t);
  repairManifest(ws);
  run(ws.root, ['bootstrap', '--only', 'fraud', '--allow-local'], 'bootstrap');
  ws.members.fraud = fs.realpathSync(path.join(ws.root, 'services', 'fraud'));
  run(ws.root, ['seed-map', '--merge'], 'seed-map');
  ws.map = steps.editMap(readJson(ws.root, MAP));
  writeJson(ws.root, MAP, ws.map);
  return ws;
}

/** A throwaway TMPDIR for the drift cache the session context writes; restored when the test file ends. */
function isolateTmpdir(t) {
  const original = process.env.TMPDIR;
  const tmp = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'adf-mega-tmp-'));
  process.env.TMPDIR = tmp;
  t.after(() => {
    if (original === undefined) delete process.env.TMPDIR; else process.env.TMPDIR = original;
    fs.rmSync(tmp, { recursive: true, force: true });
  });
}

const commitMemberFiles = (ws, message) => steps.commitMemberFiles(Object.values(ws.members), message);
const writeScopedPlan = (ws, scope) => steps.writePlanFile(ws.root, scope);

/** What the session hook passes once a plan is matched by the branch. */
const suggestedPlan = (ws, slug = steps.PLAN_SLUG) => ({ path: path.join(ws.root, 'plans', slug), resolvedBy: 'branch' });

module.exports = { ORGS, PLAN_SLUG: steps.PLAN_SLUG, megaAfterInit, repairManifest, dropSymlinkedMember, megaWorkspace, isolateTmpdir, commitMemberFiles, writeScopedPlan, suggestedPlan, cliJson, readJson, editManifest, MAP };
