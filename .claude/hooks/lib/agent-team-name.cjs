const fs = require('fs');
const os = require('os');
const path = require('path');

/**
 * Agent team lookup shared by the team hooks.
 *
 * Claude Code gives every session one team, named "session-" + the first eight
 * characters of the session id it started with, with its config in
 * ~/.claude/teams/<name>/config.json and its task list in ~/.claude/tasks/<name>/.
 * A resumed session gets a new session id but keeps the team of the session it
 * resumed, so the name cannot always be derived from the current session id.
 */

const SAFE_TEAM_NAME = /^[0-9a-zA-Z_-]+$/;

function teamsDir() {
  return path.join(os.homedir(), '.claude', 'teams');
}

/**
 * Team name for a session id, or null when the id is not a plain session id
 * (guards the path joins against traversal).
 * @param {unknown} sessionId
 * @returns {string|null}
 */
function teamNameForSession(sessionId) {
  if (typeof sessionId !== 'string' || !/^[0-9a-zA-Z-]{8,}$/.test(sessionId)) return null;
  return `session-${sessionId.slice(0, 8)}`;
}

function readTeamConfig(teamName) {
  try {
    return JSON.parse(fs.readFileSync(path.join(teamsDir(), teamName, 'config.json'), 'utf-8'));
  } catch {
    return null;
  }
}

function findMember(config, name) {
  if (!name || !Array.isArray(config?.members)) return null;
  return config.members.find(m => m.name === name && m.agentType !== 'team-lead') || null;
}

/**
 * Find the team that has a teammate with this name.
 * Tries the team named after sessionId first. Otherwise (a resumed lead) it takes the
 * team whose lead runs in `cwd` and has that member, the most recently updated one
 * when several match.
 * @param {{sessionId?: unknown, cwd?: unknown, name?: unknown}} query
 * @returns {{teamName: string, config: object, member: object}|null}
 */
function findTeamForMember({ sessionId, cwd, name }) {
  if (typeof name !== 'string' || !name) return null;

  const direct = teamNameForSession(sessionId);
  if (direct) {
    const config = readTeamConfig(direct);
    const member = findMember(config, name);
    if (member) return { teamName: direct, config, member };
  }

  if (typeof cwd !== 'string' || !cwd) return null;
  let entries;
  try {
    entries = fs.readdirSync(teamsDir(), { withFileTypes: true });
  } catch {
    return null;
  }
  let best = null;
  for (const entry of entries) {
    if (!entry.isDirectory() || !SAFE_TEAM_NAME.test(entry.name) || entry.name === direct) continue;
    const config = readTeamConfig(entry.name);
    const member = findMember(config, name);
    if (!member) continue;
    const lead = config.members.find(m => m.agentType === 'team-lead');
    if (lead?.cwd !== cwd) continue;
    let mtime = 0;
    try { mtime = fs.statSync(path.join(teamsDir(), entry.name, 'config.json')).mtimeMs; } catch { /* keep 0 */ }
    if (!best || mtime > best.mtime) best = { teamName: entry.name, config, member, mtime };
  }
  return best ? { teamName: best.teamName, config: best.config, member: best.member } : null;
}

/**
 * Team name from a TeammateIdle or TaskCompleted payload: the deprecated team_name
 * field while Claude Code still sends it, else the team of the teammate named in
 * teammate_name. Null when the payload names no teammate (a solo session with agent
 * teams enabled still has a one-member team, which must not count).
 * @param {{team_name?: unknown, teammate_name?: unknown, session_id?: unknown, cwd?: unknown}} payload
 * @returns {string|null}
 */
function teamNameFromPayload(payload) {
  if (typeof payload?.teammate_name !== 'string' || !payload.teammate_name) return null;
  const name = payload.team_name;
  if (typeof name === 'string' && SAFE_TEAM_NAME.test(name)) return name;
  const found = findTeamForMember({ sessionId: payload.session_id, cwd: payload.cwd, name: payload.teammate_name });
  return found ? found.teamName : null;
}

module.exports = { teamNameForSession, findTeamForMember, teamNameFromPayload };
