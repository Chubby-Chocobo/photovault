#!/usr/bin/env node
/**
 * TaskCompleted Hook - Logs task completions and injects progress context
 *
 * Fires: When any agent marks a task as completed (TaskUpdate with status: completed),
 *        or when a teammate finishes its turn with in-progress tasks.
 * Official docs: https://code.claude.com/docs/en/hooks#taskcompleted
 * Decision control: Exit code only (exit 2 blocks completion, stderr fed as feedback)
 * Note: additionalContext output is informational — may be ignored by CC for this event.
 * Input: { task_id, task_subject, task_description, teammate_name, team_name (deprecated; looked up
 *         from teammate_name when absent), session_id, ... }
 * Output: additionalContext with progress summary for lead
 * Design: Non-blocking, fail-open (exit 0 always), no external deps
 */

// Crash wrapper
try {
  const fs = require('fs');
  const path = require('path');
  const os = require('os');
  const { isHookEnabled, loadConfig, resolvePlanPath, getReportsPath, getProjectRoot } = require('./lib/adf-config-utils.cjs');
  const { teamNameFromPayload } = require('./lib/agent-team-name.cjs');

  if (!isHookEnabled('task-completed-handler')) {
    process.exit(0);
  }

const TASKS_DIR = path.join(os.homedir(), '.claude', 'tasks');

function readJson(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf-8'));
  } catch { return null; }
}

function countTasks(teamName) {
  const taskDir = path.join(TASKS_DIR, teamName);
  try {
    if (!fs.existsSync(taskDir)) return null;
    const files = fs.readdirSync(taskDir).filter(f => f.endsWith('.json'));
    let pending = 0, inProgress = 0, completed = 0;
    for (const file of files) {
      const task = readJson(path.join(taskDir, file));
      if (!task?.status) continue;
      if (task.status === 'pending') pending++;
      else if (task.status === 'in_progress') inProgress++;
      else if (task.status === 'completed') completed++;
    }
    return { pending, inProgress, completed, total: pending + inProgress + completed };
  } catch { return null; }
}

/** Reports folder for the session: the active plan's reports/, else plans/reports/ under the project root */
function resolveReportsDir(sessionId) {
  const config = loadConfig();
  const resolved = resolvePlanPath(sessionId, config);
  return getReportsPath(resolved.path, resolved.resolvedBy, config.plan, config.paths, getProjectRoot());
}

function logCompletion(teamName, taskId, taskSubject, teammateName, sessionId) {
  try {
    const logFile = path.join(resolveReportsDir(sessionId), `team-${teamName}-completions.md`);
    fs.mkdirSync(path.dirname(logFile), { recursive: true });
    const timestamp = new Date().toISOString().slice(0, 19).replace('T', ' ');
    const line = `- [${timestamp}] Task #${taskId} "${taskSubject}" completed by ${teammateName}\n`;
    fs.appendFileSync(logFile, line);
  } catch { /* fail-open */ }
}

function main() {
  try {
    const stdin = fs.readFileSync(0, 'utf-8').trim();
    if (!stdin) process.exit(0);

    const payload = JSON.parse(stdin);
    const { task_id, task_subject, teammate_name } = payload;
    const team_name = teamNameFromPayload(payload);
    if (!team_name) process.exit(0);

    // Log completion to report file
    logCompletion(team_name, task_id, task_subject, teammate_name, payload.session_id);

    // Count task progress
    const counts = countTasks(team_name);
    const lines = [];
    lines.push(`## Task Completed`);
    lines.push(`Task #${task_id} "${task_subject}" completed by ${teammate_name}.`);

    if (counts) {
      const remaining = counts.pending + counts.inProgress;
      lines.push(`Progress: ${counts.completed}/${counts.total} done. ${counts.pending} pending, ${counts.inProgress} in progress.`);
      if (remaining === 0) {
        lines.push('');
        lines.push('**All tasks completed.** Consider shutting down teammates and synthesizing results.');
      }
    }

    const output = {
      hookSpecificOutput: {
        hookEventName: 'TaskCompleted',
        additionalContext: lines.join('\n')
      }
    };
    console.log(JSON.stringify(output));
    process.exit(0);
  } catch (error) {
    if (process.env.ADF_DEBUG) {
      console.error(`[task-completed-handler] Error: ${error.message}`);
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
