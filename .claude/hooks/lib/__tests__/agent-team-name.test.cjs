#!/usr/bin/env node
/**
 * Tests for agent-team-name.cjs
 * Run: node --test .claude/hooks/lib/__tests__/agent-team-name.test.cjs
 */

const { describe, it, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert');
const { spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const LIB = path.join(__dirname, '..', 'agent-team-name.cjs');
const { teamNameForSession } = require(LIB);

const SESSION_ID = '24e0831d-d97c-4084-949b-68220c5e408f';
const CWD = '/work/booking-api';

// The lookups read ~/.claude/teams, so run them in a child with HOME pointed at a temp dir
function callWithHome(home, fn, arg) {
  const code = `process.stdout.write(JSON.stringify(require(${JSON.stringify(LIB)}).${fn}(${JSON.stringify(arg)})))`;
  const res = spawnSync(process.execPath, ['-e', code], { env: { ...process.env, HOME: home }, encoding: 'utf8' });
  return JSON.parse(res.stdout);
}

function writeTeam(home, teamName, members, leadCwd = CWD) {
  const dir = path.join(home, '.claude', 'teams', teamName);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'config.json'), JSON.stringify({
    name: teamName,
    members: [{ name: 'team-lead', agentType: 'team-lead', cwd: leadCwd }, ...members],
  }));
  return path.join(dir, 'config.json');
}

describe('teamNameForSession', () => {
  it('names the team session- plus the first eight characters of the session id', () => {
    assert.strictEqual(teamNameForSession(SESSION_ID), 'session-24e0831d');
  });

  it('rejects ids that are short, not strings, or contain path characters', () => {
    for (const id of ['short', '', null, undefined, 42, '../../etc/passwd', 'abc/defgh-123', '..\\..\\x1234']) {
      assert.strictEqual(teamNameForSession(id), null, String(id));
    }
  });
});

describe('findTeamForMember', () => {
  let home;
  beforeEach(() => { home = fs.mkdtempSync(path.join(os.tmpdir(), 'team-name-')); });
  afterEach(() => { fs.rmSync(home, { recursive: true, force: true }); });

  it('finds the teammate in the team named after the session', () => {
    writeTeam(home, 'session-24e0831d', [{ name: 'dev-1', agentType: 'fullstack-developer' }]);
    const found = callWithHome(home, 'findTeamForMember', { sessionId: SESSION_ID, cwd: CWD, name: 'dev-1' });
    assert.strictEqual(found.teamName, 'session-24e0831d');
    assert.strictEqual(found.member.agentType, 'fullstack-developer');
  });

  it('finds the team of a resumed lead by working directory and member name', () => {
    // The lead resumed: its session id is new, its team keeps the startup name
    writeTeam(home, 'session-18aa9960', [{ name: 'team-docs', agentType: 'docs-manager' }]);
    const found = callWithHome(home, 'findTeamForMember', { sessionId: '0373d0ee-44cd-4e8b', cwd: CWD, name: 'team-docs' });
    assert.strictEqual(found.teamName, 'session-18aa9960');
  });

  it('prefers the most recently updated team when several match', () => {
    const old = writeTeam(home, 'session-aaaaaaaa', [{ name: 'dev-1' }]);
    writeTeam(home, 'session-bbbbbbbb', [{ name: 'dev-1' }]);
    const past = new Date(Date.now() - 3600_000);
    fs.utimesSync(old, past, past);
    const found = callWithHome(home, 'findTeamForMember', { sessionId: '0373d0ee-44cd-4e8b', cwd: CWD, name: 'dev-1' });
    assert.strictEqual(found.teamName, 'session-bbbbbbbb');
  });

  it('ignores teams whose lead runs in another directory', () => {
    writeTeam(home, 'session-18aa9960', [{ name: 'dev-1' }], '/other/project');
    assert.strictEqual(callWithHome(home, 'findTeamForMember', { sessionId: '0373d0ee-44cd-4e8b', cwd: CWD, name: 'dev-1' }), null);
  });

  it('never treats the lead as a teammate, and needs a name', () => {
    writeTeam(home, 'session-24e0831d', []);
    assert.strictEqual(callWithHome(home, 'findTeamForMember', { sessionId: SESSION_ID, cwd: CWD, name: 'team-lead' }), null);
    assert.strictEqual(callWithHome(home, 'findTeamForMember', { sessionId: SESSION_ID, cwd: CWD, name: '' }), null);
  });
});

describe('teamNameFromPayload', () => {
  let home;
  beforeEach(() => { home = fs.mkdtempSync(path.join(os.tmpdir(), 'team-name-')); });
  afterEach(() => { fs.rmSync(home, { recursive: true, force: true }); });

  it('uses team_name while Claude Code still sends it', () => {
    assert.strictEqual(callWithHome(home, 'teamNameFromPayload', { team_name: 'session-24e0831d', teammate_name: 'dev-1' }), 'session-24e0831d');
  });

  it('looks the team up from teammate_name when team_name is absent', () => {
    writeTeam(home, 'session-24e0831d', [{ name: 'dev-1' }]);
    const payload = { teammate_name: 'dev-1', session_id: SESSION_ID, cwd: CWD };
    assert.strictEqual(callWithHome(home, 'teamNameFromPayload', payload), 'session-24e0831d');
  });

  it('returns null without a teammate name (a solo session still has a one-member team)', () => {
    writeTeam(home, 'session-24e0831d', []);
    assert.strictEqual(callWithHome(home, 'teamNameFromPayload', { team_name: 'session-24e0831d' }), null);
    assert.strictEqual(callWithHome(home, 'teamNameFromPayload', { session_id: SESSION_ID, cwd: CWD }), null);
  });

  it('ignores a team_name with path characters', () => {
    assert.strictEqual(callWithHome(home, 'teamNameFromPayload', { team_name: '../../etc', teammate_name: 'dev-1' }), null);
  });
});
