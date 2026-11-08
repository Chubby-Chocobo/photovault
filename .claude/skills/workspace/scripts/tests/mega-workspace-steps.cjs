'use strict';

// The hand steps of the mega workspace walkthrough, shared by the tests and by
// scripts/demo-mega-workspace.cjs: the manifest repair, the map edits, the per-member commit and
// the scoped plan. Pure file and git work; no workspace command runs here.

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const RULES = { flow: 'off', enforcement: 'ask', mainBranch: 'main' };
const EXTRA_ROLE_DIRS = ['bots', 'sdks'];
const EXTRA_MEMBERS = ['bots/market-maker-bot', 'bots/liquidator-bot', 'sdks/ts-sdk', 'sdks/py-sdk', 'sdks/go-sdk'];
const PLAN_SLUG = '261029-0114-order-settlement-flow';

const manifestMember = (rel) => ({ name: path.basename(rel), path: rel, repo: `https://github.com/acme/nova-${path.basename(rel)}.git`, branch: 'main', git: RULES });

/** Add the extra role dirs and their members, the manifest-only members and, if asked, the symlinked one. Mutates and returns `manifest`. */
function repairManifest(manifest, ws, { withSymlink = false } = {}) {
  manifest.roleDirs.push(...EXTRA_ROLE_DIRS);
  manifest.members.push(...EXTRA_MEMBERS.map(manifestMember), ...ws.missing);
  if (withSymlink) manifest.members.push(manifestMember(ws.symlinked.path));
  manifest.members.sort((a, b) => a.path.localeCompare(b.path));
  return manifest;
}

/** The calls and the producer a team would add by hand. Mutates and returns `map`. */
function editMap(map) {
  const component = (name) => map.components.find((c) => c.name === name);
  component('gateway').calls = [{ to: 'order', via: 'rest' }, { to: 'auth', via: 'grpc' }];
  component('order').calls = [{ to: 'matching-engine', via: 'grpc' }, { to: 'settlement', via: 'kafka', topic: 'orders.filled' }];
  component('matching-engine').produces = ['nova-proto'];
  return map;
}

/**
 * Commit the CLAUDE.md, the AGENTS.md and the marker of every repo in `dirs`, staged by name as git-manager does
 * (never `add --all`: that would drop the uncloned gitlinks). Returns how many repos had a commit.
 */
function commitMemberFiles(dirs, message = 'docs: add the AGENTS.md starter') {
  let committed = 0;
  for (const dir of dirs) {
    const files = ['CLAUDE.md', 'AGENTS.md', '.adf-workspace.json'].filter((f) => fs.existsSync(path.join(dir, f)));
    if (files.length === 0 || !fs.existsSync(path.join(dir, '.git'))) continue;
    spawnSync('git', ['add', '--', ...files], { cwd: dir });
    if (spawnSync('git', ['commit', '--quiet', '-m', message], { cwd: dir }).status === 0) committed += 1;
  }
  return committed;
}

/** The order-settlement plan with the given scope; returns the plan dir relative to the root. */
function writePlanFile(root, scope = '[services/order, nova-proto]', slug = PLAN_SLUG) {
  const dir = path.join(root, 'plans', slug);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'plan.md'), `---\ntitle: Order settlement flow\nstatus: in-progress\nbranch: feat/order-settlement\nscope: ${scope}\n---\n\n# Order settlement flow\n`);
  return `plans/${slug}`;
}

module.exports = { PLAN_SLUG, repairManifest, editMap, commitMemberFiles, writePlanFile };
