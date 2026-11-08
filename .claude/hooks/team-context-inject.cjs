#!/usr/bin/env node
/**
 * SubagentStart Hook - Injects team context for Agent Team teammates
 *
 * Fires: When a subagent is started (SubagentStart event)
 * Purpose: If the spawned agent is a teammate, inject its name, the lead, peers and task summary.
 *          Reports, plans and naming come from subagent-init.cjs, which runs for teammates too.
 * Design: Non-blocking, fail-open (exit 0 always), no external deps
 */

// Crash wrapper
try {
  const fs = require('fs');
  const path = require('path');
  const os = require('os');
  const { isHookEnabled } = require('./lib/adf-config-utils.cjs');
  const { findTeamForMember } = require('./lib/agent-team-name.cjs');

  if (!isHookEnabled('team-context-inject')) {
    process.exit(0);
  }

const TASKS_DIR = path.join(os.homedir(), '.claude', 'tasks');

/**
 * Read and parse JSON file safely
 */
function readJson(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf-8'));
  } catch {
    return null;
  }
}

const MAX_PEERS = 15;

function describeMember(m) {
  return m.agentType ? `${m.name} (${m.agentType})` : m.name;
}

function describePeers(peers) {
  if (peers.length === 0) return 'none';
  const shown = peers.slice(0, MAX_PEERS).map(describeMember).join(', ');
  return peers.length > MAX_PEERS ? `${shown} and ${peers.length - MAX_PEERS} more` : shown;
}

/**
 * Summarize tasks from team task directory
 */
function summarizeTasks(teamName) {
  const taskDir = path.join(TASKS_DIR, teamName);
  try {
    if (!fs.existsSync(taskDir)) return null;
    const files = fs.readdirSync(taskDir).filter(f => f.endsWith('.json'));
    if (files.length === 0) return null;
    let pending = 0, inProgress = 0, completed = 0;
    for (const file of files) {
      const task = readJson(path.join(taskDir, file));
      if (!task?.status) continue;
      if (task.status === 'pending') pending++;
      else if (task.status === 'in_progress') inProgress++;
      else if (task.status === 'completed') completed++;
    }
    return { pending, inProgress, completed, total: files.length };
  } catch {
    return null;
  }
}

/**
 * Main hook execution
 */
function main() {
  try {
    const stdin = fs.readFileSync(0, 'utf-8').trim();
    if (!stdin) process.exit(0);

    const payload = JSON.parse(stdin);
    // For a teammate, agent_type carries the name the lead gave it; an ordinary
    // subagent reports its agent type, which matches no member name
    const found = findTeamForMember({ sessionId: payload.session_id, cwd: payload.cwd, name: payload.agent_type });
    if (!found) process.exit(0); // An ordinary subagent, or agent teams are off

    const { teamName, config, member: self } = found;
    const lead = config.members.find(m => m.agentType === 'team-lead');
    const peers = config.members.filter(m => m !== self && m !== lead);
    const tasks = summarizeTasks(teamName);

    const lines = [];
    lines.push(`## Team Context`);
    lines.push(`Team: ${config.name || teamName}`);
    lines.push(`You: ${describeMember(self)}`);
    lines.push(`Lead: ${lead?.name || 'team-lead'}`);
    lines.push(`Peers so far: ${describePeers(peers)}`);
    if (tasks) {
      lines.push(`Task summary: ${tasks.pending} pending, ${tasks.inProgress} in progress, ${tasks.completed} completed`);
    }
    lines.push('');
    lines.push('Message the lead and peers by name with SendMessage. Keep to the files your spawn prompt assigns you.');

    const output = {
      hookSpecificOutput: {
        hookEventName: "SubagentStart",
        additionalContext: lines.join('\n')
      }
    };

    console.log(JSON.stringify(output));
    process.exit(0);
  } catch (error) {
    // Fail-open: log to stderr, exit cleanly
    if (process.env.ADF_DEBUG) {
      console.error(`[team-context-inject] Error: ${error.message}`);
    }
    process.exit(0);
  }
  }

  main();
} catch (e) {
  // Minimal crash logging (zero deps — only Node builtins)
  try {
    const fs = require('fs');
    const p = require('path');
    const logDir = p.join(__dirname, '.logs');
    if (!fs.existsSync(logDir)) fs.mkdirSync(logDir, { recursive: true });
    fs.appendFileSync(p.join(logDir, 'hook-log.jsonl'),
      JSON.stringify({ ts: new Date().toISOString(), hook: p.basename(__filename, '.cjs'), status: 'crash', error: e.message }) + '\n');
  } catch (_) {}
  process.exit(0); // fail-open
}
