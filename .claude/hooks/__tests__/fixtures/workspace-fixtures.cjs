'use strict';

// Throwaway repos for the monorepo and workspace tests. Git runs with an empty global config,
// so a developer's hooks, signing and aliases never leak in. Every returned path is realpath'd
// (macOS maps /var to /private/var). Nothing is ever fetched or cloned.

const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const home = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'adf-workspace-fixtures-home-')));
const globalConfig = path.join(home, 'gitconfig');
fs.writeFileSync(globalConfig, '[user]\n\tname = Test\n\temail = test@example.com\n[init]\n\tdefaultBranch = main\n[commit]\n\tgpgsign = false\n[tag]\n\tgpgsign = false\n');
Object.assign(process.env, { GIT_CONFIG_GLOBAL: globalConfig, GIT_CONFIG_NOSYSTEM: '1', CLAUDE_PROJECT_DIR: '' });
process.on('exit', () => fs.rmSync(home, { recursive: true, force: true }));

const ORG_URL = 'https://github.com/acme';
const GITIGNORED_ROLE_DIRS = ['services/', 'apps/', 'contracts/', 'infra/', 'worktrees/'];

function git(cwd, ...args) {
  const r = spawnSync('git', args, { cwd, encoding: 'utf8' });
  if (r.status !== 0) throw new Error(`git ${args.join(' ')}: ${r.stderr || r.stdout}`);
  return r.stdout.trim();
}

function write(root, rel, content) {
  fs.mkdirSync(path.dirname(path.join(root, rel)), { recursive: true });
  fs.writeFileSync(path.join(root, rel), content);
}

const json = (value) => `${JSON.stringify(value, null, 2)}\n`;

function tempDir(t, prefix) {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), prefix)));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function initRepo(dir, originUrl) {
  fs.mkdirSync(dir, { recursive: true });
  git(dir, 'init', '--quiet');
  if (originUrl) git(dir, 'remote', 'add', 'origin', originUrl);
}

/** Commits what is staged and returns the new HEAD. */
function commit(dir, message) {
  git(dir, 'commit', '--quiet', '--allow-empty', '-m', message);
  return git(dir, 'rev-parse', 'HEAD');
}

function commitAll(dir, message) {
  git(dir, 'add', '--all');
  return commit(dir, message);
}

/** Stages a gitlink at `subPath` without a clone: the index entry needs only a sha. Commit it with commit(), since add --all would drop it. */
function addGitlink(dir, subPath, sha) {
  git(dir, 'update-index', '--add', '--cacheinfo', `160000,${sha},${subPath}`);
}

/** A stable fake commit id for gitlinks that point at nothing. */
const fakeSha = (seed) => crypto.createHash('sha1').update(seed).digest('hex');

function gitmodulesText(entries) {
  return entries.map(({ path: p, url }) => `[submodule "${p}"]\n\tpath = ${p}\n\turl = ${url}\n`).join('');
}

/**
 * One git repo carrying every polyglot monorepo signal. `omit` removes signals by the names the
 * detector reports, so a test can isolate one: 'go.work', 'Cargo.toml [workspace]',
 * 'pyproject.toml [tool.uv.workspace]', 'nx.json', 'turbo.json', 'MODULE.bazel', 'services/+apps/'.
 * @param {object} t node:test context, for cleanup
 * @param {{ omit?: string[] }} [opts]
 * @returns {{ root: string }}
 */
function makePolyglotMonorepo(t, { omit = [] } = {}) {
  const root = tempDir(t, 'adf-polyglot-');
  initRepo(root);
  const signals = {
    'go.work': ['go.work', 'go 1.22\n\nuse ./services/billing\n'],
    'Cargo.toml [workspace]': ['Cargo.toml', '[workspace]\nmembers = []\n'],
    'pyproject.toml [tool.uv.workspace]': ['pyproject.toml', '[tool.uv.workspace]\nmembers = ["services/ranker"]\n'],
    'nx.json': ['nx.json', json({ targetDefaults: {} })],
    'turbo.json': ['turbo.json', json({ tasks: {} })],
    'MODULE.bazel': ['MODULE.bazel', 'module(name = "polyglot")\n'],
  };
  for (const [name, [file, content]] of Object.entries(signals)) {
    if (!omit.includes(name)) write(root, file, content);
  }
  if (!omit.includes('services/+apps/')) {
    write(root, 'services/billing/go.mod', 'module example.com/billing\n\ngo 1.22\n');
    write(root, 'services/ranker/pyproject.toml', '[project]\nname = "ranker"\nversion = "0.1.0"\n');
    write(root, 'services/gateway/package.json', json({ name: 'gateway', dependencies: { '@nestjs/core': '^10.0.0' } }));
    write(root, 'apps/admin-web/package.json', json({ name: 'admin-web', dependencies: { vue: '^3.4.0' } }));
  }
  write(root, 'contracts/proto/order.proto', 'syntax = "proto3";\npackage orders;\n\nmessage Order {\n  string id = 1;\n}\n');
  write(root, 'contracts/openapi/gateway.yaml', 'openapi: 3.0.0\ninfo:\n  title: gateway\n  version: 1.0.0\npaths: {}\n');
  write(root, 'contracts/events/order-filled.schema.json', json({ $schema: 'http://json-schema.org/draft-07/schema#', title: 'OrderFilled', type: 'object' }));
  write(root, 'contracts/async/orders.yaml', 'asyncapi: 2.6.0\ninfo:\n  title: orders\n  version: 1.0.0\nchannels: {}\n');
  write(root, 'libs/ts/package.json', json({ name: '@polyglot/ts', version: '0.1.0' }));
  commitAll(root, 'chore: initial commit');
  return { root };
}

/**
 * A git repo with a `.gitmodules` and a gitlink per submodule.
 * @param {object} t node:test context, for cleanup
 * @param {{ submodules?: { path: string, url: string }[], originUrl?: string }} [opts]
 * @returns {{ root: string }}
 */
function makeSuperproject(t, { submodules = [], originUrl } = {}) {
  const root = tempDir(t, 'adf-superproject-');
  initRepo(root, originUrl);
  write(root, 'README.md', '# superproject\n');
  if (submodules.length > 0) write(root, '.gitmodules', gitmodulesText(submodules));
  git(root, 'add', '--all');
  for (const sub of submodules) addGitlink(root, sub.path, fakeSha(sub.path));
  commit(root, 'chore: initial commit');
  return { root };
}

/**
 * An umbrella repo with independent member repos under gitignored role dirs, shaped like a
 * trading platform: three consumers pinned to three commits of one proto repo, Cargo git tags,
 * npm git URLs, one member that already carries its own agent files.
 * @param {object} t node:test context, for cleanup
 * @param {{ manifest?: object, map?: object, credentialUrl?: boolean }} [opts] manifest and map are written only when passed
 * @returns {{ root: string, members: Record<string, string>, protoCommits: string[], token: string }}
 */
function makeTcxWorkspace(t, { manifest, map, credentialUrl = false } = {}) {
  const base = tempDir(t, 'adf-tcx-');
  const root = path.join(base, 'tcx-workspace');
  const token = `${'ghp_'}${'A'.repeat(36)}`;
  const members = {};
  const originFor = (name) => `${ORG_URL}/${name.startsWith('tcx-') ? name : `tcx-${name}`}.git`;
  const member = (rel, { origin = originFor(path.basename(rel)) } = {}) => {
    const dir = path.join(root, rel);
    initRepo(dir, origin);
    members[path.basename(rel)] = fs.realpathSync(dir);
    return dir;
  };

  initRepo(root, `${ORG_URL}/tcx-workspace.git`);
  write(root, '.gitignore', `${GITIGNORED_ROLE_DIRS.join('\n')}\n`);
  write(root, 'README.md', '# tcx workspace\n');
  if (manifest) write(root, 'adf-workspace.json', json(manifest));
  if (map) write(root, 'docs/architecture/system-map.json', json(map));
  commitAll(root, 'chore: initial commit');

  const proto = member('contracts/tcx-proto');
  write(proto, 'buf.yaml', 'version: v1\n');
  const protoCommits = [];
  for (let i = 0; i < 4; i += 1) {
    write(proto, 'order/order.proto', `syntax = "proto3";\npackage order;\n\nmessage Order {\n  string id = 1;\n  int32 revision = ${i + 2};\n}\n`);
    protoCommits.push(commitAll(proto, `feat: order revision ${i}`));
  }

  [['order', 1], ['gateway', 2], ['core', 0]].forEach(([name, pin]) => {
    const dir = member(`services/${name}`);
    write(dir, 'package.json', json({ name, dependencies: { '@nestjs/core': '^10.0.0' } }));
    write(dir, '.gitmodules', gitmodulesText([{ path: 'src/protos', url: `${ORG_URL}/tcx-proto.git` }]));
    if (name === 'core') {
      write(dir, 'CLAUDE.md', '# core\n\nHand-written notes for the core service.\n');
      write(dir, '.claude/settings.json', json({ permissions: { allow: [] } }));
      write(dir, '.cursor/rules.md', '# core rules\n');
      write(dir, 'plans/README.md', '# core plans\n');
    }
    git(dir, 'add', '--all');
    addGitlink(dir, 'src/protos', protoCommits[pin]);
    commit(dir, 'chore: initial commit');
  });

  const engine = member('services/matching-engine');
  write(engine, 'pom.xml', '<project>\n  <artifactId>matching-engine</artifactId>\n</project>\n');
  commitAll(engine, 'chore: initial commit');

  const trading = member('services/trading');
  write(trading, 'Cargo.toml', `[package]\nname = "trading"\nversion = "0.1.0"\n\n[dependencies]\nvdax_libs = { git = "${ORG_URL}/vdax-libs", tag = "v1.0.109.1" }\n`);
  commitAll(trading, 'chore: initial commit');

  const market = member('services/market', { origin: credentialUrl ? `https://${token}@github.com/acme/tcx-market.git` : undefined });
  const vdaxUrl = credentialUrl ? `https://${token}@github.com/acme/vdax-libs` : `${ORG_URL}/vdax-libs`;
  write(market, 'Cargo.toml', `[package]\nname = "market"\nversion = "0.1.0"\n\n[dependencies.vdax_libs]\ngit = "${vdaxUrl}"\ntag = "v1.0.110.2"\n`);
  commitAll(market, 'chore: initial commit');

  const admin = member('apps/admin-web');
  write(admin, 'package.json', json({
    name: 'admin-web',
    dependencies: {
      vue: '^3.4.0',
      'wormhole-sdk': `git+${ORG_URL}/wormhole-sdk.git#master`,
      'ui-kit': 'github:acme/ui-kit',
      charts: `git+${ORG_URL}/charts.git#v1.2.0`,
    },
  }));
  commitAll(admin, 'chore: initial commit');

  return { root: fs.realpathSync(root), members, protoCommits, token };
}

/** The repo-building primitives, for fixtures in other files (the mega workspace). */
const helpers = { ORG_URL, git, write, json, tempDir, initRepo, commit, commitAll, addGitlink, fakeSha, gitmodulesText };

module.exports = { makePolyglotMonorepo, makeSuperproject, makeTcxWorkspace, helpers };
