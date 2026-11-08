'use strict';

// Workspace and monorepo projects for the scope tests: an initialized TCX workspace whose map
// has a producer for the proto contract, and a small monorepo with a map. Both carry a .claude
// directory so getProjectRoot finds them.

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { makePolyglotMonorepo } = require('../../__tests__/fixtures/workspace-fixtures.cjs');
const { initializedWorkspace } = require('../../../skills/workspace/scripts/tests/workspace-test-helpers.cjs');

const MAP = 'docs/architecture/system-map.json';

function writeFile(root, rel, content) {
  fs.mkdirSync(path.dirname(path.join(root, rel)), { recursive: true });
  fs.writeFileSync(path.join(root, rel), content);
}

const readMap = (root) => JSON.parse(fs.readFileSync(path.join(root, MAP), 'utf8'));
const writeMap = (root, map) => writeFile(root, MAP, `${JSON.stringify(map, null, 2)}\n`);

/** Plan folder `plans/<slug>/plan.md` with the given front matter lines. */
function writePlan(root, slug, frontMatterLines = []) {
  writeFile(root, `plans/${slug}/plan.md`, `---\ntitle: ${slug}\nstatus: pending\n${frontMatterLines.join('\n')}${frontMatterLines.length ? '\n' : ''}---\n\n# ${slug}\n`);
  return path.join(root, 'plans', slug);
}

function setBranch(dir, branch) {
  const r = spawnSync('git', ['checkout', '--quiet', '-B', branch], { cwd: dir, encoding: 'utf8' });
  if (r.status !== 0) throw new Error(`git checkout ${branch}: ${r.stderr}`);
}

/**
 * The initialized TCX workspace: manifest, map (7 components, contract tcx-proto consumed by
 * core, gateway and order, produced by matching-engine), ignore blocks, and a .claude dir.
 */
function scopeWorkspace(t) {
  const ws = initializedWorkspace(t);
  const map = readMap(ws.root);
  map.components.find((c) => c.name === 'matching-engine').produces = ['tcx-proto'];
  writeMap(ws.root, map);
  fs.mkdirSync(path.join(ws.root, '.claude'), { recursive: true });
  return ws;
}

/** A monorepo: services order and gateway, contract proto at contracts/proto, libs/, a map with `path` fields. */
function scopeMonorepo(t) {
  const { root } = makePolyglotMonorepo(t, { omit: ['go.work', 'Cargo.toml [workspace]', 'pyproject.toml [tool.uv.workspace]', 'nx.json', 'turbo.json', 'MODULE.bazel'] });
  fs.rmSync(path.join(root, 'services/billing'), { recursive: true, force: true });
  fs.rmSync(path.join(root, 'services/ranker'), { recursive: true, force: true });
  writeFile(root, 'services/order/package.json', '{"name":"order"}\n');
  writeMap(root, {
    version: 1,
    components: [
      { name: 'gateway', path: 'services/gateway', role: 'backend', consumes: ['proto'] },
      { name: 'order', path: 'services/order', role: 'backend', consumes: ['proto'] },
      { name: 'admin-web', path: 'apps/admin-web', role: 'frontend' },
    ],
    contracts: [{ id: 'proto', kind: 'proto', path: 'contracts/proto' }],
  });
  fs.mkdirSync(path.join(root, '.claude'), { recursive: true });
  return { root };
}

module.exports = { MAP, readMap, writeMap, writeFile, writePlan, setBranch, scopeWorkspace, scopeMonorepo };
