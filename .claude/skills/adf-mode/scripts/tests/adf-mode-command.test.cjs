#!/usr/bin/env node
/**
 * Tests for the adf-mode command: auto writes the mode and the permission mode, strict removes
 * both without touching anything else, status reports every knob, bad arguments exit 2.
 * Run: node --test .claude/skills/adf-mode/scripts/tests/adf-mode-command.test.cjs
 */

'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { main } = require('../adf-mode.cjs');

const CONFIG = '.claude/config/adf-config.json';
const SETTINGS = '.claude/settings.local.json';

function project(t, { config, settings } = {}) {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'adf-mode-cmd-')));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  fs.mkdirSync(path.join(root, '.claude', 'config'), { recursive: true });
  if (config) fs.writeFileSync(path.join(root, CONFIG), `${JSON.stringify(config, null, 2)}\n`);
  if (settings) fs.writeFileSync(path.join(root, SETTINGS), `${JSON.stringify(settings, null, 2)}\n`);
  return root;
}

const readJson = (root, rel) => JSON.parse(fs.readFileSync(path.join(root, rel), 'utf8'));

function run(root, argv) {
  const out = [];
  const err = [];
  const saved = { mode: process.env.ADF_MODE, dir: process.env.CLAUDE_PROJECT_DIR };
  delete process.env.ADF_MODE;
  process.env.CLAUDE_PROJECT_DIR = root;
  let code;
  try { code = main([...argv, '--cwd', root], (s) => out.push(s), (s) => err.push(s)); } finally {
    if (saved.mode === undefined) delete process.env.ADF_MODE; else process.env.ADF_MODE = saved.mode;
    if (saved.dir === undefined) delete process.env.CLAUDE_PROJECT_DIR; else process.env.CLAUDE_PROJECT_DIR = saved.dir;
  }
  return { code, out: out.join('\n'), err: err.join('\n') };
}
const runJson = (root, argv) => { const r = run(root, [...argv, '--json']); return { ...r, json: r.out ? JSON.parse(r.out) : null }; };

describe('adf-mode command', () => {
  it('auto writes mode and bypassPermissions, keeps every other key, and status shows the effect', (t) => {
    const root = project(t, { config: { git: { flow: 'trunk', enforcement: 'ask', mainBranch: 'main' }, hooks: {} }, settings: { permissions: { additionalDirectories: ['/x'] } } });
    const { code, json } = runJson(root, ['auto']);
    assert.equal(code, 0);
    assert.deepEqual(readJson(root, CONFIG), { git: { flow: 'trunk', enforcement: 'ask', mainBranch: 'main' }, hooks: {}, mode: 'auto' });
    assert.deepEqual(readJson(root, SETTINGS), { permissions: { additionalDirectories: ['/x'], defaultMode: 'bypassPermissions' } });
    assert.equal(json.mode, 'auto');
    assert.deepEqual(json.knobs.gitEnforcement, { configured: 'ask', effective: 'off' });
    assert.equal(json.knobs.privacyBlock, 'allows (deny rules still apply)');
    assert.equal(json.knobs.askGate, 'refuses AskUserQuestion');
    assert.equal(json.knobs.permissionsDefaultMode, 'bypassPermissions');
    assert.ok(json.knobs.kept.some((k) => k.startsWith('permissions.ask rules')) && json.knobs.kept.some((k) => k.startsWith('commit secret scan')));
    assert.deepEqual(json.changes, [`${CONFIG}: mode = auto`, `${SETTINGS}: + permissions.defaultMode: "bypassPermissions"`]);
  });

  it('strict removes the mode and the permission mode auto wrote, but not one set by hand', (t) => {
    const root = project(t, { config: { mode: 'auto', privacyBlock: true }, settings: { permissions: { defaultMode: 'bypassPermissions' } } });
    const first = runJson(root, ['strict']);
    assert.equal(first.code, 0);
    assert.deepEqual(readJson(root, CONFIG), { privacyBlock: true });
    assert.ok(!fs.existsSync(path.join(root, SETTINGS)), 'a settings file with nothing left in it is removed');
    assert.ok(first.json.changes.includes(`${SETTINGS}: removed (nothing left in it)`), first.json.changes.join('\n'));
    assert.equal(first.json.mode, 'strict');
    assert.deepEqual(first.json.knobs.gitEnforcement, { configured: 'ask', effective: 'ask' });
    assert.equal(first.json.knobs.privacyBlock, 'asks');
    const manual = project(t, { config: { mode: 'auto' }, settings: { permissions: { defaultMode: 'acceptEdits' } } });
    runJson(manual, ['strict']);
    assert.deepEqual(readJson(manual, SETTINGS), { permissions: { defaultMode: 'acceptEdits' } }, 'a mode auto did not write is left alone');
  });

  it('auto remembers a permission mode that was already set and strict puts it back', (t) => {
    const root = project(t, { config: {}, settings: { permissions: { defaultMode: 'acceptEdits' } } });
    const on = runJson(root, ['auto']);
    assert.deepEqual(readJson(root, CONFIG), { mode: 'auto', modeRestore: { permissionsDefaultMode: 'acceptEdits' } });
    assert.equal(readJson(root, SETTINGS).permissions.defaultMode, 'bypassPermissions');
    assert.match(on.json.changes[0], /remembering permissions\.defaultMode acceptEdits/);
    const off = runJson(root, ['strict']);
    assert.deepEqual(readJson(root, CONFIG), {});
    assert.deepEqual(readJson(root, SETTINGS), { permissions: { defaultMode: 'acceptEdits' } });
    assert.ok(off.json.changes.some((c) => c.includes('+ permissions.defaultMode: "acceptEdits"')), off.json.changes.join('\n'));
  });

  it('creates the config file when a project has none, and refuses to touch one that is not valid JSON', (t) => {
    const root = project(t);
    assert.equal(runJson(root, ['status']).json.mode, 'strict');
    assert.equal(run(root, ['auto']).code, 0);
    assert.deepEqual(readJson(root, CONFIG), { mode: 'auto' });
    const broken = project(t);
    fs.writeFileSync(path.join(broken, CONFIG), '{ "git": { "enforcement": "deny" }, // a comment\n}\n');
    const before = fs.readFileSync(path.join(broken, CONFIG), 'utf8');
    const r = run(broken, ['auto']);
    assert.equal(r.code, 1);
    assert.match(r.err, /not valid JSON; fix it first/);
    assert.equal(fs.readFileSync(path.join(broken, CONFIG), 'utf8'), before, 'the broken file is left exactly as it was');
    assert.ok(!fs.existsSync(path.join(broken, SETTINGS)), 'and the permission mode is not written either');
    const list = project(t);
    fs.writeFileSync(path.join(list, CONFIG), '[]\n');
    assert.match(run(list, ['strict']).err, /not a JSON object/);
  });

  it('leaves the config untouched when settings.local.json is broken, and never restores a remembered bypassPermissions', (t) => {
    const root = project(t, { config: { mode: 'auto', modeRestore: { permissionsDefaultMode: 'acceptEdits' } } });
    fs.writeFileSync(path.join(root, SETTINGS), '{ not json');
    const r = run(root, ['strict']);
    assert.equal(r.code, 1);
    assert.match(r.err, /settings\.local\.json is not a JSON object/);
    assert.deepEqual(readJson(root, CONFIG), { mode: 'auto', modeRestore: { permissionsDefaultMode: 'acceptEdits' } }, 'modeRestore survives because nothing was written');
    assert.equal(run(root, ['auto']).code, 1, 'auto refuses the same way instead of half-applying');
    assert.match(runJson(root, ['status']).json.knobs.permissionsDefaultMode, /^unreadable/);
    const committed = project(t, { config: { mode: 'auto', modeRestore: { permissionsDefaultMode: 'bypassPermissions' } }, settings: { permissions: { defaultMode: 'bypassPermissions' } } });
    assert.equal(run(committed, ['strict']).code, 0);
    assert.ok(!fs.existsSync(path.join(committed, SETTINGS)), 'a remembered bypassPermissions (for example from a committed config) is dropped, not restored');
    assert.deepEqual(readJson(committed, CONFIG), {});
    const shared = project(t, { config: { mode: 'auto' }, settings: { permissions: { defaultMode: 'bypassPermissions', additionalDirectories: ['/x'] } } });
    run(shared, ['strict']);
    assert.deepEqual(readJson(shared, SETTINGS), { permissions: { additionalDirectories: ['/x'] } }, 'a file with other settings in it stays');
  });

  it('refuses a directory that is not an ADF project instead of scaffolding .claude/ into it', (t) => {
    const bare = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'adf-mode-bare-')));
    t.after(() => fs.rmSync(bare, { recursive: true, force: true }));
    const saved = process.env.CLAUDE_PROJECT_DIR;
    delete process.env.CLAUDE_PROJECT_DIR;
    try {
      const err = [];
      assert.equal(main(['auto', '--cwd', bare], () => {}, (s) => err.push(s)), 1);
      assert.match(err.join('\n'), /has no \.claude\/ directory/);
    } finally { if (saved === undefined) delete process.env.CLAUDE_PROJECT_DIR; else process.env.CLAUDE_PROJECT_DIR = saved; }
    assert.ok(!fs.existsSync(path.join(bare, '.claude')));
  });

  it('reports a disabled privacy hook and ask gate, and the env override, in status', (t) => {
    const root = project(t, { config: { mode: 'auto', privacyBlock: false, hooks: { 'ask-gate': false } } });
    const { json } = runJson(root, ['status']);
    assert.equal(json.knobs.privacyBlock, 'disabled');
    assert.equal(json.knobs.askGate, 'disabled');
    process.env.ADF_MODE = 'strict';
    try {
      const out = [];
      main(['status', '--cwd', root, '--json'], (s) => out.push(s), () => {});
      const s = JSON.parse(out.join(''));
      assert.deepEqual([s.mode, s.source, s.envOverride], ['strict', 'env', 'strict']);
    } finally { delete process.env.ADF_MODE; }
  });

  it('rejects a missing or unknown command and an unknown flag with exit 2 and a usage line', (t) => {
    const root = project(t);
    for (const argv of [[], ['bogus'], ['status', '--what']]) {
      const r = run(root, argv);
      assert.equal(r.code, 2, argv.join(' '));
      assert.match(r.err, /usage: adf-mode\.cjs auto\|strict\|status|unknown argument/);
    }
    assert.ok(!fs.existsSync(path.join(root, CONFIG)), 'nothing written on a usage error');
  });
});
