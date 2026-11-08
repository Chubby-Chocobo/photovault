'use strict';

// A large workspace shaped like an exchange product ("nova"): 64 member repos under six role dirs,
// built so that every ADF limit and special case has a concrete example. Nothing is fetched.
//
// What it contains, and what each case exercises:
// - 45 services, 5 contracts, 6 apps, 3 infra, 2 bots, 3 sdks: more members than the session hook
//   checks (50) or lists (8); `bots/` and `sdks/` are not default role dirs, so `init` misses them
//   until the manifest lists them.
// - nova-proto has 5 revisions; gateway, auth, order and settlement pin it as a gitlink at four
//   different ones, trading and market pin Cargo tags, notification pins an npm branch (unpinned),
//   analytics and webhook pin nova-events by tag and by commit: every drift finding.
// - market: a token in its origin and in a Cargo dependency URL (credential redaction, fix-remotes).
// - platform: a member that is itself a polyglot monorepo. legacy-core: a superproject with one
//   vendored and one sibling submodule. identity: a member with its own ADF copy and git rules.
// - compliance lives on gitlab.com under the client org; support belongs to an untrusted owner;
//   scheduler has no origin at all.
// - services/shared-kernel is a symlink to a repo outside the workspace.
// - `missing` lists ten members that exist only in the manifest; fraud has a local bare mirror so
//   `bootstrap` can clone it offline.

const fs = require('node:fs');
const path = require('node:path');
const { helpers } = require('./workspace-fixtures.cjs');

const { ORG_URL, git, write, json, tempDir, initRepo, commit, commitAll, addGitlink, gitmodulesText } = helpers;

const TOKEN = `${'ghp_'}${'B'.repeat(36)}`;
const PROTO_REVISIONS = 5;

const nest = (name, extra = {}) => json({ name, dependencies: { '@nestjs/core': '^10.0.0', ...extra } });
const vue = (name, dep = 'vue') => json({ name, dependencies: { [dep]: '^3.4.0' } });
const goMod = (name) => `module github.com/acme/nova-${name}\n\ngo 1.22\n`;
const pyproject = (name) => `[project]\nname = "${name}"\nversion = "0.1.0"\n`;
const cargo = (name, url, tag) => `[package]\nname = "${name}"\nversion = "0.1.0"\n\n[dependencies]\nnova_proto = { git = "${url}", tag = "${tag}" }\n`;

const PLAIN_SERVICES = ['kyc', 'pricing', 'custody', 'reporting', 'fees', 'referral', 'audit', 'search', 'email', 'sms', 'rate-limiter',
  'feature-flags', 'config', 'session', 'otc', 'staking', 'lending', 'margin', 'futures', 'options', 'treasury', 'payments', 'fiat-gateway'];
const GO_SERVICES = ['wallet', 'ledger', 'deposit', 'withdrawal', 'blockchain-indexer'];
const APPS = { web: vue('web'), 'admin-web': vue('admin-web'), kiosk: vue('kiosk'), 'partner-portal': vue('partner-portal', 'nuxt'),
  mobile: json({ name: 'mobile', dependencies: { 'react-native': '^0.74.0' } }), desktop: json({ name: 'desktop', dependencies: { electron: '^30.0.0' } }) };
const SIMPLE = { 'infra/terraform-infra': ['main.tf', 'terraform {}\n'], 'infra/k8s-deploy': ['kustomization.yaml', 'resources: []\n'],
  'infra/helm-devops': ['Chart.yaml', 'apiVersion: v2\nname: nova\n'], 'bots/market-maker-bot': ['package.json', nest('market-maker-bot')],
  'bots/liquidator-bot': ['pyproject.toml', pyproject('liquidator-bot')], 'sdks/ts-sdk': ['package.json', json({ name: '@nova/sdk', main: 'index.js' })],
  'sdks/py-sdk': ['pyproject.toml', pyproject('nova-sdk')], 'sdks/go-sdk': ['go.mod', goMod('sdk')] };

/** Members that exist only in the manifest. `repo` of fraud is filled in with the local mirror. */
const MISSING = ['apps/android-wallet', 'apps/ios-wallet', 'infra/observability', 'infra/secrets-vault', 'services/chat', 'services/fraud',
  'services/insurance', 'services/loyalty', 'services/tax', 'services/voice'];

/**
 * Build the workspace under `base` (an empty directory). The workspace root is `<base>/nova-workspace`;
 * the symlink target and the bare mirror live beside it.
 * @returns {{ root: string, base: string, members: Record<string, string>, protoCommits: string[], eventsHead: string, token: string,
 *   missing: { name: string, path: string, repo: string, branch: string, git: object }[], symlinked: { name: string, path: string } }}
 */
function buildMegaWorkspace(base) {
  const root = path.join(base, 'nova-workspace');
  const members = {};
  const repoName = (name) => (name.startsWith('nova-') ? name : `nova-${name}`);
  const member = (rel, { origin = `${ORG_URL}/${repoName(path.basename(rel))}.git` } = {}) => {
    const dir = path.join(root, rel);
    initRepo(dir, origin);
    members[path.basename(rel)] = dir;
    return dir;
  };
  const simple = (rel, file, content, opts) => { const d = member(rel, opts); write(d, file, content); commitAll(d, 'chore: initial commit'); return d; };

  initRepo(root, `${ORG_URL}/nova-workspace.git`);
  write(root, '.gitignore', 'services/\napps/\ncontracts/\ninfra/\nbots/\nsdks/\nworktrees/\n');
  write(root, 'README.md', '# nova workspace\n');
  fs.mkdirSync(path.join(root, '.claude'), { recursive: true });
  write(root, '.claude/config/adf-config.json', json({ paths: { docs: 'docs', plans: 'plans' } }));
  commitAll(root, 'chore: initial commit');

  // Contracts
  const proto = member('contracts/nova-proto');
  write(proto, 'buf.yaml', 'version: v1\n');
  const protoCommits = [];
  for (let i = 0; i < PROTO_REVISIONS; i += 1) {
    write(proto, 'order/order.proto', `syntax = "proto3";\npackage order;\n\nmessage Order {\n  string id = 1;\n  int32 revision = ${i + 1};\n}\n`);
    protoCommits.push(commitAll(proto, `feat: order revision ${i + 1}`));
  }
  simple('contracts/nova-openapi', 'gateway.yaml', 'openapi: 3.0.0\ninfo:\n  title: gateway\n  version: 1.0.0\npaths: {}\n');
  const events = simple('contracts/nova-events', 'order-filled.schema.json', json({ $schema: 'http://json-schema.org/draft-07/schema#', title: 'OrderFilled', type: 'object' }));
  const eventsHead = git(events, 'rev-parse', 'HEAD');
  simple('contracts/nova-streams', 'orders.yaml', 'asyncapi: 2.6.0\ninfo:\n  title: orders\n  version: 1.0.0\nchannels: {}\n');
  simple('contracts/nova-abi', 'foundry.toml', '[profile.default]\nsrc = "src"\n');

  // Services that pin the proto as a submodule gitlink, at four different revisions
  for (const [name, pin] of [['gateway', 1], ['auth', 2], ['order', PROTO_REVISIONS - 1], ['settlement', 0]]) {
    const dir = member(`services/${name}`);
    write(dir, 'package.json', nest(name));
    write(dir, '.gitmodules', gitmodulesText([{ path: 'src/protos', url: `${ORG_URL}/nova-proto.git` }]));
    git(dir, 'add', '--all');
    addGitlink(dir, 'src/protos', protoCommits[pin]);
    commit(dir, 'chore: initial commit');
  }
  simple('services/trading', 'Cargo.toml', cargo('trading', `${ORG_URL}/nova-proto`, 'v2.0.0'));
  simple('services/market', 'Cargo.toml', cargo('market', `https://${TOKEN}@github.com/acme/nova-proto`, 'v2.1.0'), { origin: `https://${TOKEN}@github.com/acme/nova-market.git` });
  simple('services/matching-engine', 'pom.xml', '<project>\n  <artifactId>matching-engine</artifactId>\n</project>\n');
  for (const name of GO_SERVICES) simple(`services/${name}`, 'go.mod', goMod(name));
  simple('services/risk', 'pyproject.toml', pyproject('risk'));
  simple('services/notification', 'package.json', nest('notification', { 'nova-proto': `git+${ORG_URL}/nova-proto.git#main` }));
  simple('services/analytics', 'package.json', nest('analytics', { 'nova-events': 'github:acme/nova-events#v1.0.0' }));
  simple('services/webhook', 'package.json', nest('webhook', { 'nova-events': `git+${ORG_URL}/nova-events.git#${eventsHead}` }));
  for (const name of PLAIN_SERVICES) simple(`services/${name}`, 'package.json', nest(name));

  // A member that is itself a polyglot monorepo
  const platform = member('services/platform');
  write(platform, 'go.work', 'go 1.22\n\nuse ./services/billing\n');
  write(platform, 'nx.json', json({ targetDefaults: {} }));
  write(platform, 'services/billing/go.mod', goMod('platform-billing'));
  write(platform, 'apps/console/package.json', vue('console'));
  commitAll(platform, 'chore: initial commit');

  // A superproject: one vendored submodule, one sibling from the trusted org
  const legacy = member('services/legacy-core');
  write(legacy, 'pom.xml', '<project>\n  <artifactId>legacy-core</artifactId>\n</project>\n');
  write(legacy, '.gitmodules', gitmodulesText([{ path: 'lib/forge-std', url: 'https://github.com/vendorx/forge-std.git' }, { path: 'deps/nova-proto', url: `${ORG_URL}/nova-proto.git` }]));
  git(legacy, 'add', '--all');
  addGitlink(legacy, 'lib/forge-std', helpers.fakeSha('forge-std'));
  addGitlink(legacy, 'deps/nova-proto', protoCommits[2]);
  commit(legacy, 'chore: initial commit');

  // A member with its own ADF copy and its own git rules
  const identity = member('services/identity');
  write(identity, 'package.json', nest('identity'));
  write(identity, 'CLAUDE.md', '# identity\n\nHand-written notes for the identity service.\n');
  write(identity, '.claude/CLAUDE.md', '# ADF\n');
  write(identity, '.claude/config/adf-config.json', json({ git: { flow: 'trunk', enforcement: 'deny', mainBranch: 'master' } }));
  write(identity, '.cursor/rules.md', '# identity rules\n');
  write(identity, 'plans/README.md', '# identity plans\n');
  commitAll(identity, 'chore: initial commit');

  simple('services/compliance', 'package.json', nest('compliance'), { origin: 'https://gitlab.com/nova-client/nova-compliance.git' });
  simple('services/support', 'package.json', nest('support'), { origin: 'https://github.com/vendorx/nova-support.git' });
  simple('services/scheduler', 'package.json', nest('scheduler'), { origin: null });

  for (const [name, pkg] of Object.entries(APPS)) simple(`apps/${name}`, 'package.json', pkg);
  for (const [rel, [file, content]] of Object.entries(SIMPLE)) simple(rel, file, content);

  // A symlinked member path and a bare mirror for one missing member
  const outside = path.join(base, 'outside', 'shared-kernel');
  initRepo(outside, `${ORG_URL}/nova-shared-kernel.git`);
  write(outside, 'package.json', nest('shared-kernel'));
  commitAll(outside, 'chore: initial commit');
  fs.symlinkSync(outside, path.join(root, 'services', 'shared-kernel'), 'dir');
  const fraudSource = path.join(base, 'outside', 'fraud');
  initRepo(fraudSource, `${ORG_URL}/nova-fraud.git`);
  write(fraudSource, 'package.json', nest('fraud'));
  commitAll(fraudSource, 'chore: initial commit');
  const mirror = path.join(base, 'mirrors', 'nova-fraud.git');
  fs.mkdirSync(path.dirname(mirror), { recursive: true });
  git(base, 'clone', '--quiet', '--bare', fraudSource, mirror);

  const gitRules = { flow: 'off', enforcement: 'ask', mainBranch: 'main' };
  const missing = MISSING.map((rel) => {
    const name = path.basename(rel);
    const repo = name === 'fraud' ? `file://${mirror}` : `${ORG_URL}/nova-${name}.git`;
    return { name, path: rel, repo, branch: 'main', git: gitRules };
  });
  return { root, base, members, protoCommits, eventsHead, token: TOKEN, missing, symlinked: { name: 'shared-kernel', path: 'services/shared-kernel' } };
}

/** The mega workspace in a temp dir that the test removes afterwards; every path is realpath'd. */
function makeMegaWorkspace(t) {
  const base = tempDir(t, 'adf-mega-');
  const built = buildMegaWorkspace(base);
  const real = (p) => fs.realpathSync(p);
  return { ...built, root: real(built.root), members: Object.fromEntries(Object.entries(built.members).map(([k, v]) => [k, real(v)])) };
}

module.exports = { buildMegaWorkspace, makeMegaWorkspace };
