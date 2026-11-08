#!/usr/bin/env node
/**
 * SubagentStart Hook - Injects context to subagents (Optimized)
 *
 * Fires: When a subagent (Task tool call) is started
 * Purpose: Inject minimal context using env vars from SessionStart
 * Target: ~200 tokens (down from ~350)
 *
 * Exit Codes:
 *   0 - Success (non-blocking, allows continuation)
 */

// Crash wrapper
try {
  const fs = require('fs');
  const path = require('path');
  const {
    loadConfig,
    resolveNamingPattern,
    getGitBranch,
    getGitRoot,
    resolvePlanPath,
    getReportsPath,
    normalizePath,
    extractTaskListId,
    isHookEnabled,
    getProjectRoot
  } = require('./lib/adf-config-utils.cjs');
  const { resolveSkillsVenv } = require('./lib/context-builder.cjs');
  const { findTeamForMember } = require('./lib/agent-team-name.cjs');
  const { createHookTimer, logHookCrash } = require('./lib/hook-logger.cjs');

  // Early exit if hook disabled in config
  if (!isHookEnabled('subagent-init')) {
    process.exit(0);
  }

// Agent types that interact with plan status updates or save plan-scoped reports
const PLAN_AWARE_AGENTS = new Set([
  'planner', 'project-manager', 'code-simplifier',
  'fullstack-developer'
]);

/**
 * Build plan status update guidance for plan-aware agents (~50 tokens)
 * Keeps manual plan.md status edits in the canonical format
 */
function buildPlanStatusSection(agentType) {
  if (!PLAN_AWARE_AGENTS.has(agentType)) return [];
  return [
    ``,
    `## Plan Status Updates`,
    `Edit the plan.md phases table Status cell directly. Keep the canonical | Phase | Name | Status | table.`,
    `Status values: Pending | In Progress | Completed. Do not reformat other columns.`
  ];
}

/**
 * Build trust verification section if enabled
 */
function buildTrustVerification(config) {
  if (!config.trust?.enabled || !config.trust?.passphrase) return [];
  return [
    ``,
    `## Trust Verification`,
    `Passphrase: "${config.trust.passphrase}"`
  ];
}

/**
 * Main hook execution
 */
async function main() {
  const timer = createHookTimer('subagent-init', { event: 'SubagentStart' });
  let agentType = 'unknown';
  try {
    const stdin = fs.readFileSync(0, 'utf-8').trim();
    if (!stdin) {
      timer.end({ status: 'skip', exit: 0, note: 'empty-input' });
      process.exit(0);
    }

    const payload = JSON.parse(stdin);
    agentType = payload.agent_type || 'unknown';
    const agentId = payload.agent_id || 'unknown';
    // A teammate reports the name the lead gave it as agent_type; per-agent config, plan
    // guidance and report names need its agent definition, which the team config records
    const teammate = findTeamForMember({ sessionId: payload.session_id, cwd: payload.cwd, name: payload.agent_type });
    const teammateName = teammate?.member?.agentType ? agentType : null;
    if (teammateName) agentType = teammate.member.agentType;

    // Load config for trust verification, naming, and agent-specific context
    const config = loadConfig({ includeProject: false, includeAssertions: false });

    // Use payload.cwd if provided for git operations (monorepo support)
    // This ensures subagent resolves paths relative to its own CWD, not process.cwd()
    // Issue #327: Use trim() to handle empty string edge case
    const effectiveCwd = payload.cwd?.trim() || process.cwd();

    // Compute naming pattern directly (don't rely on env vars which may not propagate)
    // Pass effectiveCwd to git commands to support monorepo/submodule scenarios
    const gitBranch = getGitBranch(effectiveCwd);
    const gitRoot = getGitRoot(effectiveCwd);
    // Base for plans/reports/docs: the project root (see getProjectRoot), so a subagent spawned
    // after a `cd` into a subfolder still writes into <project>/plans
    const baseDir = getProjectRoot(effectiveCwd);

    // Debug logging for path resolution troubleshooting
    if (process.env.ADF_DEBUG) {
      console.error(`[subagent-init] effectiveCwd=${effectiveCwd}, gitRoot=${gitRoot}, baseDir=${baseDir}`);
    }
    const namePattern = resolveNamingPattern(config.plan, gitBranch);

    // Resolve plan and reports path - use absolute paths based on CWD (Issue #327)
    // Use session_id from payload to resolve active plan context (Issue #321)
    const sessionId = payload.session_id || process.env.ADF_SESSION_ID || null;
    const resolved = resolvePlanPath(sessionId, config);
    const reportsPath = getReportsPath(resolved.path, resolved.resolvedBy, config.plan, config.paths, baseDir);
    const activePlan = resolved.resolvedBy === 'session' ? resolved.path : '';
    const suggestedPlan = resolved.resolvedBy === 'branch' ? resolved.path : '';

    // Extract task list ID for Claude Code Tasks coordination (shared helper, DRY)
    const taskListId = extractTaskListId(resolved);
    const plansPath = path.join(baseDir, normalizePath(config.paths?.plans) || 'plans');
    const docsPath = path.join(baseDir, normalizePath(config.paths?.docs) || 'docs');
    const thinkingLanguage = config.locale?.thinkingLanguage || '';
    const responseLanguage = config.locale?.responseLanguage || '';
    // Auto-default thinkingLanguage to 'en' when only responseLanguage is set
    const effectiveThinking = thinkingLanguage || (responseLanguage ? 'en' : '');

    // Build compact context (~200 tokens)
    const lines = [];

    // Subagent identification
    lines.push(teammateName ? `## Subagent: ${agentType} (teammate ${teammateName})` : `## Subagent: ${agentType}`);
    lines.push(`ID: ${agentId} | CWD: ${effectiveCwd}`);
    lines.push(``);

    // Plan context (from env vars)
    lines.push(`## Context`);
    if (activePlan) {
      lines.push(`- Plan: ${activePlan}`);
      if (taskListId) {
        lines.push(`- Task List: ${taskListId} (shared with session)`);
      }
    } else if (suggestedPlan) {
      lines.push(`- Plan: none | Suggested: ${suggestedPlan}`);
    } else {
      lines.push(`- Plan: none`);
    }
    lines.push(`- Reports: ${reportsPath}`);
    lines.push(`- Paths: ${plansPath}/ | ${docsPath}/`);
    try {
      const { loadScopeContext, agentScopePaths } = require('./lib/scope-context.cjs');
      const scopePaths = agentScopePaths(loadScopeContext({ baseDir, config, resolvedPlan: resolved, cwd: effectiveCwd }));
      if (scopePaths.length > 0) lines.push(`- Scope: ${scopePaths.slice(0, 12).join(', ')} (search here first; pass these as Grep/Glob paths)`);
    } catch (_) { /* scope is advice; never block the subagent */ }
    lines.push(``);

    // Language (thinking + response, if configured)
    const hasThinking = effectiveThinking && effectiveThinking !== responseLanguage;
    if (hasThinking || responseLanguage) {
      lines.push(`## Language`);
      if (hasThinking) {
        lines.push(`- Thinking: Use ${effectiveThinking} for reasoning (logic, precision).`);
      }
      if (responseLanguage) {
        lines.push(`- Response: Respond in ${responseLanguage} (natural, fluent).`);
      }
      lines.push(``);
    }

    // Resolve Python venv path for subagent instructions
    const skillsVenv = resolveSkillsVenv();

    // Core rules (minimal)
    lines.push(`## Rules`);
    lines.push(`- Reports → ${reportsPath}`);
    lines.push(`- YAGNI / KISS / DRY`);
    lines.push(`- Concise, list unresolved Qs at end`);
    // Python venv rules (if venv exists)
    if (skillsVenv) {
      lines.push(`- Python scripts in .claude/skills/: Use \`${skillsVenv}\``);
      lines.push(`- Never use global pip install`);
    }

    // Naming templates (computed directly for reliable injection)
    lines.push(``);
    lines.push(`## Naming`);
    lines.push(`- Report: ${path.join(reportsPath, `${agentType}-${namePattern}-report.md`)}`);
    lines.push(`- For workflow reports, insert a descriptive purpose before -report, e.g. ${agentType}-${namePattern}-audit-plan-review-report.md`);
    lines.push(`- Avoid generic report names like audit-review.md, review.md, report.md, or notes.md`);
    lines.push(`- Plan dir: ${path.join(plansPath, namePattern)}/`);

    // Plan status guidance for plan-aware agents (Issue #540)
    lines.push(...buildPlanStatusSection(agentType));

    // Trust verification (if enabled)
    lines.push(...buildTrustVerification(config));

    // CRITICAL: SubagentStart requires hookSpecificOutput.additionalContext format
    const output = {
      hookSpecificOutput: {
        hookEventName: "SubagentStart",
        additionalContext: lines.join('\n')
      }
    };

    console.log(JSON.stringify(output));
    timer.end({ status: 'ok', exit: 0, target: agentType, note: 'context-injected' });
    process.exit(0);
  } catch (error) {
    console.error(`SubagentStart hook error: ${error.message}`);
    logHookCrash('subagent-init', error, { event: 'SubagentStart', target: agentType });
    process.exit(0); // Fail-open
  }
  }

  main();
} catch (e) {
  try {
    const { logHookCrash } = require('./lib/hook-logger.cjs');
    logHookCrash('subagent-init', e, { event: 'SubagentStart' });
  } catch (_) {}
  process.exit(0); // fail-open
}
