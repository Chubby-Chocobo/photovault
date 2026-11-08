'use strict';

// Shared by the attach tests: a workspace served from a local bare repo under its https URL, and a
// standalone member clone that carries the marker.

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { git, readJson } = require('./workspace-test-helpers.cjs');
const attach = require('../lib/member-attach.cjs');
const { renderMarker } = require('../../../../hooks/lib/member-link.cjs');

const URL = 'https://github.com/acme/tcx-workspace';
const SETTINGS = '.claude/settings.local.json';
const GIT = { flow: 'off', enforcement: 'ask', mainBranch: 'main' };

const tmp = (t, prefix) => {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), prefix)));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
};
const write = (file, content) => { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, typeof content === 'string' ? content : `${JSON.stringify(content, null, 2)}\n`); };

/** A workspace repo that lists the `order` member, served as `https://github.com/acme/tcx-workspace` from a local bare repo. */
function serveWorkspace(t, { members = [{ name: 'order', path: 'services/order', repo: 'https://github.com/tcx-client/order', git: GIT }], components = [{ name: 'order', member: 'order' }] } = {}) {
  const base = tmp(t, 'adf-attach-ws-');
  const src = path.join(base, 'src');
  fs.mkdirSync(src);
  git(src, 'init', '--quiet');
  const manifest = { version: 1, client: 'tcx', product: 'tcx', org: ['acme', 'tcx-client'], repo: URL, roleDirs: ['services'], members };
  write(path.join(src, 'adf-workspace.json'), manifest);
  write(path.join(src, 'docs/architecture/system-map.json'), { version: 1, components });
  git(src, 'add', '--all');
  git(src, 'commit', '--quiet', '-m', 'chore: init');
  const bare = path.join(base, 'tcx-workspace.git');
  git(base, 'clone', '--quiet', '--bare', src, bare);
  const key = `url.file://${bare}.insteadOf`;
  git(base, 'config', '--global', key, URL);
  t.after(() => spawnSync('git', ['config', '--global', '--remove-section', `url.file://${bare}`]));
  return { manifest };
}

/** A standalone clone of `order` with the marker, next to where the workspace will be cloned. */
function standaloneMember(t, { origin = 'https://github.com/tcx-client/order', marker = {}, withMarker = true } = {}) {
  const parent = tmp(t, 'adf-attach-member-');
  const root = path.join(parent, 'order');
  fs.mkdirSync(root);
  git(root, 'init', '--quiet');
  git(root, 'remote', 'add', 'origin', origin);
  const manifest = { org: ['acme', 'tcx-client'], client: 'tcx', product: 'tcx', repo: URL };
  if (withMarker) write(path.join(root, '.adf-workspace.json'), { ...JSON.parse(renderMarker({ manifest, component: 'order' })), ...marker });
  return { root, parent, workspaceDir: path.join(parent, 'tcx-workspace') };
}

const attachTo = (root, url, flags = {}) => attach.run({ root, docsRel: 'docs', opts: { _: ['attach', url], ...flags } });
const settings = (root) => readJson(root, SETTINGS);

module.exports = { tmp, URL, SETTINGS, write, serveWorkspace, standaloneMember, attachTo, settings, attach };
