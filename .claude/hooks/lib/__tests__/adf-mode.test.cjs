#!/usr/bin/env node
/**
 * Tests for adf-mode.cjs: resolution order (env > config > default), the ask-to-off relaxation,
 * the session line, and what the git config and guards do in each mode.
 * Run: node --test .claude/hooks/lib/__tests__/adf-mode.test.cjs
 */

'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { getMode, isAuto, relaxLevel, modeLine, ENV_VAR } = require('../adf-mode.cjs');
const { getGitConfig } = require('../git-flow-config.cjs');

const GUARD = path.join(__dirname, '..', '..', 'git-flow-guard.cjs');

/** A project root with the given adf-config.json; cleaned up after the test. */
function project(t, config) {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'adf-mode-')));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  fs.mkdirSync(path.join(root, '.claude', 'config'), { recursive: true });
  if (config !== undefined) fs.writeFileSync(path.join(root, '.claude', 'config', 'adf-config.json'), typeof config === 'string' ? config : JSON.stringify(config));
  return root;
}

/** Run fn with ADF_MODE and CLAUDE_PROJECT_DIR set, then restore both. */
function withEnv(vars, fn) {
  const saved = Object.fromEntries(Object.keys(vars).map((k) => [k, process.env[k]]));
  for (const [k, v] of Object.entries(vars)) { if (v === undefined) delete process.env[k]; else process.env[k] = v; }
  try { return fn(); } finally {
    for (const [k, v] of Object.entries(saved)) { if (v === undefined) delete process.env[k]; else process.env[k] = v; }
  }
}

describe('getMode', () => {
  it('is strict by default, reads the config, and lets the environment win', (t) => {
    const root = project(t, { mode: 'auto' });
    withEnv({ [ENV_VAR]: undefined, CLAUDE_PROJECT_DIR: root }, () => {
      assert.deepEqual(getMode(root), { mode: 'auto', source: 'config', root });
      assert.equal(isAuto(root), true);
    });
    withEnv({ [ENV_VAR]: 'strict', CLAUDE_PROJECT_DIR: root }, () => assert.deepEqual(getMode(root), { mode: 'strict', source: 'env', root }));
    withEnv({ [ENV_VAR]: ' AUTO ', CLAUDE_PROJECT_DIR: root }, () => assert.equal(getMode(root).source, 'env', 'case and spaces are tolerated'));
    const plain = project(t, {});
    withEnv({ [ENV_VAR]: undefined, CLAUDE_PROJECT_DIR: plain }, () => assert.deepEqual(getMode(plain), { mode: 'strict', source: 'default', root: plain }));
  });

  it('follows the launched project, not the directory a hook happens to run in', (t) => {
    const launched = project(t, {});
    const elsewhere = project(t, { mode: 'auto' });
    withEnv({ [ENV_VAR]: undefined, CLAUDE_PROJECT_DIR: launched }, () => {
      assert.deepEqual(getMode(elsewhere), { mode: 'strict', source: 'default', root: launched }, 'a clone that ships mode: auto cannot flip a session started elsewhere');
      assert.equal(getMode(elsewhere, { root: elsewhere }).mode, 'auto', 'an explicit root (the command\'s --cwd) is honoured');
    });
    withEnv({ [ENV_VAR]: undefined, CLAUDE_PROJECT_DIR: undefined }, () => assert.equal(getMode(elsewhere).mode, 'auto', 'without a launched project the nearest .claude/ above cwd decides'));
  });

  it('falls back to strict on an unknown value, a broken file or no file', (t) => {
    for (const config of [{ mode: 'yolo' }, { mode: 1 }, '{not json', undefined]) {
      const root = project(t, config);
      withEnv({ [ENV_VAR]: 'turbo', CLAUDE_PROJECT_DIR: root }, () => assert.equal(getMode(root).mode, 'strict', JSON.stringify(config)));
    }
  });

  it('relaxes ask to off in auto only, never touches off or deny, and prints the line only in auto', (t) => {
    const auto = project(t, { mode: 'auto' });
    const strict = project(t, {});
    withEnv({ [ENV_VAR]: undefined, CLAUDE_PROJECT_DIR: auto }, () => {
      assert.deepEqual(['off', 'ask', 'deny'].map((l) => relaxLevel(l, auto)), ['off', 'off', 'deny']);
      assert.match(modeLine(auto), /^Mode: auto \(asks become allows, denies stay;.*adf-mode\.cjs strict/);
    });
    withEnv({ [ENV_VAR]: 'auto', CLAUDE_PROJECT_DIR: strict }, () => assert.match(modeLine(strict), /^Mode: auto from ADF_MODE /));
    withEnv({ [ENV_VAR]: undefined, CLAUDE_PROJECT_DIR: strict }, () => {
      assert.deepEqual(['off', 'ask', 'deny'].map((l) => relaxLevel(l, strict)), ['off', 'ask', 'deny']);
      assert.equal(modeLine(strict), null);
    });
  });
});

describe('git config and guard in auto mode', () => {
  it('getGitConfig reports enforcement off for a configured ask and keeps a configured deny', (t) => {
    const ask = project(t, { mode: 'auto', git: { flow: 'trunk', enforcement: 'ask', mainBranch: 'main' } });
    withEnv({ [ENV_VAR]: undefined, CLAUDE_PROJECT_DIR: ask }, () => {
      assert.equal(getGitConfig(ask).enforcement, 'off');
      assert.equal(getGitConfig(ask).commit.formatLevel, 'off', 'the message check follows the enforcement');
    });
    const deny = project(t, { mode: 'auto', git: { flow: 'trunk', enforcement: 'deny', mainBranch: 'main' } });
    withEnv({ [ENV_VAR]: undefined, CLAUDE_PROJECT_DIR: deny }, () => assert.equal(getGitConfig(deny).enforcement, 'deny'));
    withEnv({ [ENV_VAR]: 'strict', CLAUDE_PROJECT_DIR: ask }, () => assert.equal(getGitConfig(ask).enforcement, 'ask', 'the env override restores the ask'));
  });

  it('git-flow-guard stops asking in auto and still denies a force push of main in both modes', (t) => {
    const root = project(t, { git: { flow: 'trunk', enforcement: 'ask', mainBranch: 'main' } });
    spawnSync('git', ['init', '-q', root]);
    spawnSync('git', ['-C', root, 'remote', 'add', 'origin', 'https://github.com/acme/x.git']);
    const run = (command, mode) => {
      const r = spawnSync(process.execPath, [GUARD, 'git'], { cwd: root, encoding: 'utf8', input: JSON.stringify({ tool_name: 'Bash', tool_input: { command }, cwd: root }), env: { ...process.env, CLAUDE_PROJECT_DIR: root, [ENV_VAR]: mode } });
      return r.stdout.trim() ? JSON.parse(r.stdout).hookSpecificOutput : {};
    };
    assert.equal(run('git push --tags', 'strict').permissionDecision, 'ask');
    assert.equal(run('git add -A', 'strict').permissionDecision, 'ask');
    assert.equal(run('git push --tags', 'auto').permissionDecision, undefined, 'the ask follows enforcement, which auto runs as off');
    assert.equal(run('git add -A', 'auto').permissionDecision, undefined);
    assert.equal(run('git push --force origin main', 'strict').permissionDecision, 'deny');
    assert.equal(run('git push --force origin main', 'auto').permissionDecision, 'deny', 'a deny is never relaxed');
  });

  it('session-init prints the Mode line in auto and nothing about modes in strict', (t) => {
    const home = fs.mkdtempSync(path.join(os.tmpdir(), 'adf-mode-home-'));
    t.after(() => fs.rmSync(home, { recursive: true, force: true }));
    const session = (root, env) => spawnSync(process.execPath, [path.join(__dirname, '..', '..', 'session-init.cjs')], {
      cwd: root, encoding: 'utf8', input: JSON.stringify({ source: 'startup' }),
      env: { ...process.env, HOME: home, CLAUDE_PROJECT_DIR: root, CLAUDE_ENV_FILE: '', ADF_SESSION_ID: '', ADF_REPORTS_PATH: '', [ENV_VAR]: '', ...env },
    }).stdout;
    const auto = project(t, { mode: 'auto' });
    assert.match(session(auto), /^Mode: auto \(asks become allows, denies stay;/m);
    const strict = project(t, {});
    assert.doesNotMatch(session(strict), /^Mode:/m);
    assert.match(session(strict, { [ENV_VAR]: 'auto' }), /^Mode: auto from ADF_MODE/m);
  });
});
