#!/usr/bin/env node
/**
 * Tests for ask-gate.cjs (PreToolUse on AskUserQuestion) and the privacy hook's auto-mode allow.
 * Both hooks are spawned with CLAUDE_PROJECT_DIR pointing at a throwaway project, so the result
 * does not depend on this checkout's own config.
 * Run: node --test .claude/hooks/__tests__/ask-gate.test.cjs
 */

'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ASK_GATE = path.join(__dirname, '..', 'ask-gate.cjs');
const PRIVACY = path.join(__dirname, '..', 'privacy-block.cjs');

function project(t, config) {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'adf-ask-gate-')));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  fs.mkdirSync(path.join(root, '.claude', 'config'), { recursive: true });
  fs.writeFileSync(path.join(root, '.claude', 'config', 'adf-config.json'), JSON.stringify(config));
  return root;
}

function hook(script, root, payload, env = {}) {
  const r = spawnSync(process.execPath, [script], {
    cwd: root, encoding: 'utf8', input: payload === null ? '' : JSON.stringify({ cwd: root, ...payload }),
    env: { ...process.env, CLAUDE_PROJECT_DIR: root, ADF_MODE: '', ADF_HOOK_LOG_DIR: path.join(root, 'logs'), ...env },
  });
  return { code: r.status, out: r.stdout.trim(), err: r.stderr.trim() };
}

const question = { tool_name: 'AskUserQuestion', tool_input: { questions: [{ question: 'Which mode?', options: [{ label: 'A (Recommended)' }, { label: 'B' }] }] } };

describe('ask-gate', () => {
  it('refuses the question in auto mode with the decide-and-record instruction', (t) => {
    const root = project(t, { mode: 'auto' });
    const { code, out } = hook(ASK_GATE, root, question);
    assert.equal(code, 0);
    const output = JSON.parse(out).hookSpecificOutput;
    assert.equal(output.permissionDecision, 'deny');
    assert.match(output.permissionDecisionReason, /^ADF auto mode: do not ask the user\./);
    assert.match(output.permissionDecisionReason, /recommended option/);
    assert.match(output.permissionDecisionReason, /Decisions/);
    assert.match(output.permissionDecisionReason, /principles/);
    assert.match(output.permissionDecisionReason, /adf-mode\.cjs strict/);
  });

  it('is silent in strict mode, when the hook is disabled, for other tools and on bad input', (t) => {
    assert.equal(hook(ASK_GATE, project(t, {}), question).out, '');
    assert.equal(hook(ASK_GATE, project(t, { mode: 'auto', hooks: { 'ask-gate': false } }), question).out, '');
    assert.equal(hook(ASK_GATE, project(t, { mode: 'auto' }), { tool_name: 'Bash', tool_input: { command: 'ls' } }).out, '');
    const bad = spawnSync(process.execPath, [ASK_GATE], { encoding: 'utf8', input: '{nope' });
    assert.equal(bad.status, 0);
    assert.equal(bad.stdout.trim(), '');
    assert.equal(hook(ASK_GATE, project(t, { mode: 'auto' }), null).out, '', 'empty stdin');
  });

  it('follows the ADF_MODE override in both directions', (t) => {
    assert.equal(JSON.parse(hook(ASK_GATE, project(t, {}), question, { ADF_MODE: 'auto' }).out).hookSpecificOutput.permissionDecision, 'deny');
    assert.equal(hook(ASK_GATE, project(t, { mode: 'auto' }), question, { ADF_MODE: 'strict' }).out, '');
  });
});

describe('commit-guard in auto mode', () => {
  const COMMIT_GUARD = path.join(__dirname, '..', 'commit-guard.cjs');

  it('refuses a commit that would record a secret file where strict mode asked', (t) => {
    const repo = (config) => {
      const root = project(t, { ...config, git: { flow: 'off', enforcement: 'ask', mainBranch: 'main' } });
      spawnSync('git', ['init', '-q', root]);
      fs.writeFileSync(path.join(root, '.env'), 'DB_PASSWORD=placeholder\n');
      spawnSync('git', ['-C', root, 'add', '-f', '.env']);
      return root;
    };
    const commit = (root) => hook(COMMIT_GUARD, root, { tool_name: 'Bash', tool_input: { command: 'git commit -m "chore: add env"' } });
    const strict = commit(repo({}));
    assert.equal(JSON.parse(strict.out).hookSpecificOutput.permissionDecision, 'ask');
    const auto = JSON.parse(commit(repo({ mode: 'auto' })).out).hookSpecificOutput;
    assert.equal(auto.permissionDecision, 'deny', 'nobody can approve in auto, so the commit is refused');
    assert.match(auto.permissionDecisionReason, /would record secrets/);
  });
});

describe('privacy-block in auto mode', () => {
  const read = (root) => ({ tool_name: 'Read', tool_input: { file_path: path.join(root, 'config', 'credentials.json') } });

  it('asks in strict mode and lets the same read through in auto mode', (t) => {
    const strict = project(t, {});
    const asked = hook(PRIVACY, strict, read(strict));
    assert.equal(asked.code, 0);
    assert.equal(JSON.parse(asked.out).hookSpecificOutput.permissionDecision, 'ask');
    const auto = project(t, { mode: 'auto' });
    const allowed = hook(PRIVACY, auto, read(auto));
    assert.equal(allowed.code, 0);
    assert.equal(allowed.out, '', 'no decision: the call proceeds; permissions.deny rules are Claude Code\'s own and still apply');
  });
});
