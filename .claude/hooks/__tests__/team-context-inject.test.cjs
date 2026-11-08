#!/usr/bin/env node
/**
 * Tests for team-context-inject.cjs hook - Team Agent Context Injection
 * Run: node --test .claude/hooks/__tests__/team-context-inject.test.cjs
 *
 * Payloads follow what Claude Code 2.1.299 sends on SubagentStart for an in-process
 * teammate: session_id of the lead's session, agent_type = the teammate's name, and an
 * opaque agent_id. The team is ~/.claude/teams/session-<first 8 chars of session_id>/.
 */

const { describe, it, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const HOOK_PATH = path.join(__dirname, '..', 'team-context-inject.cjs');
const SESSION_ID = '24e0831d-d97c-4084-949b-68220c5e408f';
const TEAM = 'session-24e0831d';

function runHook(input, home) {
  return new Promise((resolve, reject) => {
    const proc = spawn('node', [HOOK_PATH], { cwd: process.cwd(), env: { ...process.env, HOME: home } });
    let stdout = '';
    let stderr = '';
    proc.stdout.on('data', (d) => { stdout += d.toString(); });
    proc.stderr.on('data', (d) => { stderr += d.toString(); });
    if (input !== null) proc.stdin.write(typeof input === 'string' ? input : JSON.stringify(input));
    proc.stdin.end();
    proc.on('close', (code) => {
      let context = null;
      try { context = JSON.parse(stdout).hookSpecificOutput.additionalContext; } catch { /* no output */ }
      resolve({ exitCode: code, stdout, stderr, context });
    });
    proc.on('error', reject);
    setTimeout(() => { proc.kill('SIGTERM'); reject(new Error('Hook execution timed out')); }, 10000);
  });
}

function writeTeam(home, members, tasks, team = TEAM) {
  const teamDir = path.join(home, '.claude', 'teams', team);
  fs.mkdirSync(teamDir, { recursive: true });
  fs.writeFileSync(path.join(teamDir, 'config.json'), JSON.stringify({
    name: team,
    leadAgentId: `team-lead@${team}`,
    leadSessionId: SESSION_ID,
    members,
  }));
  if (tasks) {
    const taskDir = path.join(home, '.claude', 'tasks', team);
    fs.mkdirSync(taskDir, { recursive: true });
    for (const t of tasks) fs.writeFileSync(path.join(taskDir, `${t.id}.json`), JSON.stringify(t));
  }
}

const CWD = '/work/booking-api';
const LEAD = { agentId: `team-lead@${TEAM}`, name: 'team-lead', agentType: 'team-lead', cwd: CWD };
const R1 = { agentId: `reviewer-1@${TEAM}`, name: 'reviewer-1', agentType: 'code-reviewer' };
const R2 = { agentId: `reviewer-2@${TEAM}`, name: 'reviewer-2', agentType: 'code-reviewer' };
const teammateStart = (name) => ({
  session_id: SESSION_ID,
  cwd: CWD,
  agent_id: `a${name}-06c41150f6f90db3`,
  agent_type: name,
  hook_event_name: 'SubagentStart',
});

describe('team-context-inject.cjs', () => {
  let home;
  beforeEach(() => { home = fs.mkdtempSync(path.join(os.tmpdir(), 'team-inject-')); });
  afterEach(() => { fs.rmSync(home, { recursive: true, force: true }); });

  describe('teammate detection', () => {
    it('injects context for a teammate named in the session team', async () => {
      writeTeam(home, [LEAD, R1, R2]);
      const result = await runHook(teammateStart('reviewer-1'), home);
      assert.strictEqual(result.exitCode, 0);
      assert.ok(result.context, 'expected additionalContext');
      assert.match(result.context, /## Team Context/);
      assert.match(result.context, new RegExp(`Team: ${TEAM}`));
      assert.match(result.context, /You: reviewer-1 \(code-reviewer\)/);
      assert.match(result.context, /Lead: team-lead/);
      assert.match(result.context, /Peers so far: reviewer-2 \(code-reviewer\)/);
      assert.match(result.context, /SendMessage/);
    });

    it('outputs SubagentStart hookSpecificOutput JSON', async () => {
      writeTeam(home, [LEAD, R1]);
      const result = await runHook(teammateStart('reviewer-1'), home);
      const out = JSON.parse(result.stdout);
      assert.strictEqual(out.hookSpecificOutput.hookEventName, 'SubagentStart');
    });

    it('stays silent for an ordinary subagent (agent_type is a definition type, not a member name)', async () => {
      writeTeam(home, [LEAD, R1]);
      const result = await runHook({ session_id: SESSION_ID, agent_id: 'a6f0abfb3cbb6c52f', agent_type: 'code-reviewer' }, home);
      assert.strictEqual(result.exitCode, 0);
      assert.strictEqual(result.stdout.trim(), '');
    });

    it('does not treat the lead as a teammate', async () => {
      writeTeam(home, [LEAD, R1]);
      const result = await runHook({ session_id: SESSION_ID, agent_type: 'team-lead' }, home);
      assert.strictEqual(result.stdout.trim(), '');
    });

    it('stays silent when the session has no team (agent teams disabled)', async () => {
      const result = await runHook(teammateStart('reviewer-1'), home);
      assert.strictEqual(result.exitCode, 0);
      assert.strictEqual(result.stdout.trim(), '');
    });

    it('finds the team of a resumed lead, whose team keeps the startup session name', async () => {
      writeTeam(home, [LEAD, R1, R2], null, 'session-18aa9960');
      const result = await runHook({ ...teammateStart('reviewer-1'), session_id: '0373d0ee-44cd-4e8b-9c0f-d40602f8cdde' }, home);
      assert.ok(result.context, 'expected additionalContext');
      assert.match(result.context, /Team: session-18aa9960/);
    });

    it('does not take a team whose lead runs in another directory', async () => {
      writeTeam(home, [{ ...LEAD, cwd: '/other' }, R1], null, 'session-18aa9960');
      const result = await runHook({ ...teammateStart('reviewer-1'), session_id: '0373d0ee-44cd-4e8b-9c0f-d40602f8cdde' }, home);
      assert.strictEqual(result.stdout.trim(), '');
    });

    it('rejects session ids that are not plain ids (path traversal guard)', async () => {
      writeTeam(home, [LEAD, R1]);
      for (const session_id of ['../../../etc', '..', 'short', 42, null]) {
        const result = await runHook({ session_id, agent_type: 'reviewer-1' }, home);
        assert.strictEqual(result.exitCode, 0);
        assert.strictEqual(result.stdout.trim(), '', `no output for ${session_id}`);
      }
    });
  });

  describe('peers and tasks', () => {
    it('shows "none" when the teammate has no peers yet', async () => {
      writeTeam(home, [LEAD, R1]);
      const result = await runHook(teammateStart('reviewer-1'), home);
      assert.match(result.context, /Peers so far: none/);
    });

    it('lists at most 15 peers', async () => {
      const many = Array.from({ length: 20 }, (_, i) => ({ name: `dev-${i + 2}`, agentType: 'fullstack-developer' }));
      writeTeam(home, [LEAD, { name: 'dev-1', agentType: 'fullstack-developer' }, ...many]);
      const result = await runHook(teammateStart('dev-1'), home);
      assert.match(result.context, /dev-16 \(fullstack-developer\) and 5 more$/m);
      assert.doesNotMatch(result.context, /dev-17/);
    });

    it('names a peer without an agent type by name alone', async () => {
      writeTeam(home, [LEAD, R1, { agentId: `helper@${TEAM}`, name: 'helper' }]);
      const result = await runHook(teammateStart('reviewer-1'), home);
      assert.match(result.context, /Peers so far: helper$/m);
    });

    it('summarizes the shared task list when it has tasks', async () => {
      writeTeam(home, [LEAD, R1], [
        { id: '1', status: 'pending' },
        { id: '2', status: 'in_progress' },
        { id: '3', status: 'completed' },
        { id: '4', status: 'pending' },
      ]);
      const result = await runHook(teammateStart('reviewer-1'), home);
      assert.match(result.context, /Task summary: 2 pending, 1 in progress, 1 completed/);
    });

    it('omits the task summary when there is no task list', async () => {
      writeTeam(home, [LEAD, R1]);
      const result = await runHook(teammateStart('reviewer-1'), home);
      assert.doesNotMatch(result.context, /Task summary/);
    });

    it('ignores corrupted task files and non-JSON files', async () => {
      writeTeam(home, [LEAD, R1], [{ id: '1', status: 'completed' }]);
      const taskDir = path.join(home, '.claude', 'tasks', TEAM);
      fs.writeFileSync(path.join(taskDir, '2.json'), '{broken');
      fs.writeFileSync(path.join(taskDir, 'notes.txt'), 'x');
      const result = await runHook(teammateStart('reviewer-1'), home);
      assert.match(result.context, /Task summary: 0 pending, 0 in progress, 1 completed/);
    });
  });

  describe('fail-open', () => {
    it('exits 0 on empty stdin', async () => {
      const result = await runHook(null, home);
      assert.strictEqual(result.exitCode, 0);
      assert.strictEqual(result.stdout.trim(), '');
    });

    it('exits 0 on invalid JSON', async () => {
      const result = await runHook('not valid json{{{', home);
      assert.strictEqual(result.exitCode, 0);
      assert.strictEqual(result.stdout.trim(), '');
    });

    it('exits 0 on a corrupted team config', async () => {
      const teamDir = path.join(home, '.claude', 'teams', TEAM);
      fs.mkdirSync(teamDir, { recursive: true });
      fs.writeFileSync(path.join(teamDir, 'config.json'), '{not json');
      const result = await runHook(teammateStart('reviewer-1'), home);
      assert.strictEqual(result.exitCode, 0);
      assert.strictEqual(result.stdout.trim(), '');
    });
  });
});
