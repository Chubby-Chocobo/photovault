'use strict';

// Shared by the workspace command tests: run a command in-process, run git, build an
// initialized TCX workspace. Requiring the fixtures file also points git at an empty global config.

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { makeTcxWorkspace } = require('../../../../hooks/__tests__/fixtures/workspace-fixtures.cjs');
const { main } = require('../workspace.cjs');

const WRITING = new Set(['init', 'bootstrap', 'scaffold']);

/**
 * Run `workspace.cjs <argv> --cwd <root>` in-process. init, bootstrap and scaffold get `--yes` unless
 * `raw` is set, so tests of the confirmation gate can leave it out.
 */
function cli(root, argv, { raw = false } = {}) {
  const out = [];
  const err = [];
  const gated = !raw && WRITING.has(argv[0]) && !argv.includes('--dry-run');
  const code = main([...argv, ...(gated ? ['--yes'] : []), '--cwd', root], { out: (s) => out.push(s), err: (s) => err.push(s) });
  return { code, out: out.join('\n'), err: err.join('\n') };
}

/** Same, with --json: the single printed object is parsed. */
function cliJson(root, argv, opts) {
  const r = cli(root, [...argv, '--json'], opts);
  return { code: r.code, json: r.out ? JSON.parse(r.out) : null, err: r.err };
}

function git(cwd, ...args) {
  const r = spawnSync('git', args, { cwd, encoding: 'utf8' });
  if (r.status !== 0) throw new Error(`git ${args.join(' ')}: ${r.stderr}`);
  return r.stdout.trim();
}

/** The TCX workspace after a real `init`. */
function initializedWorkspace(t, opts) {
  const ws = makeTcxWorkspace(t, opts);
  const init = cliJson(ws.root, ['init']);
  if (init.code !== 0) throw new Error(`init failed: ${JSON.stringify(init.json)}`);
  return ws;
}

const readJson = (root, rel) => JSON.parse(fs.readFileSync(path.join(root, rel), 'utf8'));
function writeJson(root, rel, value) {
  fs.mkdirSync(path.dirname(path.join(root, rel)), { recursive: true });
  fs.writeFileSync(path.join(root, rel), `${JSON.stringify(value, null, 2)}\n`);
}

/** Edit adf-workspace.json in place. */
function editManifest(root, edit) {
  const manifest = readJson(root, 'adf-workspace.json');
  edit(manifest);
  writeJson(root, 'adf-workspace.json', manifest);
  return manifest;
}

/** SHA-256 of every file git tracks in `dir`, by relative path. */
function trackedHashes(dir) {
  // Gitlinks (submodule paths) are directories on disk, not file content
  const isFile = (f) => { try { return fs.lstatSync(path.join(dir, f)).isFile(); } catch { return false; } };
  const files = git(dir, 'ls-files').split('\n').filter((f) => f && isFile(f));
  return Object.fromEntries(files.map((f) => [f, crypto.createHash('sha256').update(fs.readFileSync(path.join(dir, f))).digest('hex')]));
}

/** A bare mirror of the repo at `dir`, returned as a file:// URL. */
function mirrorOf(t, dir, name) {
  const base = fs.realpathSync(fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'adf-mirror-')));
  t.after(() => fs.rmSync(base, { recursive: true, force: true }));
  const bare = path.join(base, `${name}.git`);
  git(base, 'clone', '--quiet', '--bare', dir, bare);
  return { bare, url: `file://${bare}` };
}

const MAP = 'docs/architecture/system-map.json';

/** The initialized TCX workspace plus an uncloned apps/mobile member, one call edge and a produced contract. */
function scaffoldWorkspace(t) {
  const ws = initializedWorkspace(t);
  editManifest(ws.root, (m) => {
    m.members.push({ name: 'mobile', path: 'apps/mobile', repo: 'https://github.com/acme/tcx-mobile.git', branch: 'main', git: { flow: 'off', enforcement: 'ask', mainBranch: 'main' } });
  });
  const map = readJson(ws.root, MAP);
  const component = (name) => map.components.find((c) => c.name === name);
  map.components.push({ name: 'mobile', member: 'mobile', role: 'mobile', stack: 'react-native' });
  component('order').calls = [{ to: 'matching-engine', via: 'grpc' }, { to: 'market', via: 'kafka', topic: 'orders' }];
  component('gateway').calls = [{ to: 'order', via: 'rest' }];
  component('order').produces = ['tcx-proto'];
  writeJson(ws.root, MAP, map);
  return ws;
}

/** An empty directory outside any workspace, for symlink targets. */
function outsideDir(t) {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'adf-outside-')));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

module.exports = { cli, cliJson, git, initializedWorkspace, readJson, writeJson, editManifest, trackedHashes, mirrorOf, outsideDir, scaffoldWorkspace, MAP };
