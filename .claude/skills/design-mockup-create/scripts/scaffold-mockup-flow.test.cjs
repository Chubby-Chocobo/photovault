'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const SCRIPT = path.join(__dirname, 'scaffold-mockup-flow.cjs');

function run(projectDir, extraEnv = {}) {
  const env = { ...process.env, CLAUDE_PROJECT_DIR: projectDir, ...extraEnv };
  delete env.ADF_DOCS_PATH;
  Object.assign(env, extraEnv);
  return spawnSync(process.execPath, [SCRIPT, '--name', 'auth-flow', '--pages', 'login'], { cwd: projectDir, env, encoding: 'utf8' });
}

test('writes under docs/design/mockups by default', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mockup-'));
  const r = run(dir);
  assert.strictEqual(r.status, 0, r.stderr);
  assert.ok(fs.existsSync(path.join(dir, 'docs', 'design', 'mockups', 'auth-flow', 'mockup.json')));
});

test('honours paths.docs from config', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mockup-'));
  fs.mkdirSync(path.join(dir, '.claude', 'config'), { recursive: true });
  fs.writeFileSync(path.join(dir, '.claude', 'config', 'adf-config.json'), JSON.stringify({ paths: { docs: 'manuals' } }));
  const r = run(dir);
  assert.strictEqual(r.status, 0, r.stderr);
  assert.ok(fs.existsSync(path.join(dir, 'manuals', 'design', 'mockups', 'auth-flow', 'index.html')));
});

test('honours ADF_DOCS_PATH over config', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mockup-'));
  const docs = path.join(dir, 'envdocs');
  const r = run(dir, { ADF_DOCS_PATH: docs });
  assert.strictEqual(r.status, 0, r.stderr);
  assert.ok(fs.existsSync(path.join(docs, 'design', 'mockups', 'auth-flow', 'mockup.json')));
});
