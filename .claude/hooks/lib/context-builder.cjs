#!/usr/bin/env node
/**
 * context-builder.cjs - Context/reminder building for session injection
 *
 * Extracted from dev-rules-reminder.cjs for reuse in Claude hooks.
 * Builds session context, rules, paths, and plan information.
 *
 * @module context-builder
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execSync } = require('child_process');

const RECENT_INJECTION_TTL_MS = 5 * 60 * 1000;
// How much of the transcript's end is scanned for an earlier injection
const TRANSCRIPT_TAIL_BYTES = 1024 * 1024;

// First line of every reminder; also how a transcript scan recognises an earlier injection
const REMINDER_MARKER = '## ADF Session Context';
const PENDING_INJECTION_TTL_MS = 30 * 1000;
const {
  loadConfig,
  resolvePlanPath,
  getReportsPath,
  resolveNamingPattern,
  normalizePath,
  getGitBranch,
  readSessionState,
  updateSessionState,
  getProjectRoot
} = require('./adf-config-utils.cjs');

function execSafe(cmd) {
  try {
    return execSync(cmd, { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }).trim();
  } catch {
    return null;
  }
}

/**
 * Resolve rules file path (local or global) with backward compat
 * @param {string} filename - Rules filename
 * @param {string} [configDirName='.claude'] - Config directory name
 * @returns {string|null} Resolved path or null
 */
function resolveRulesPath(filename, configDirName = '.claude') {
  // Try rules/ first (new location)
  const localRulesPath = path.join(getProjectRoot(), configDirName, 'rules', filename);
  const globalRulesPath = path.join(os.homedir(), '.claude', 'rules', filename);

  if (fs.existsSync(localRulesPath)) return `${configDirName}/rules/${filename}`;
  if (fs.existsSync(globalRulesPath)) return `~/.claude/rules/${filename}`;

  // Backward compat: try workflows/ (legacy location)
  const localWorkflowsPath = path.join(getProjectRoot(), configDirName, 'workflows', filename);
  const globalWorkflowsPath = path.join(os.homedir(), '.claude', 'workflows', filename);

  if (fs.existsSync(localWorkflowsPath)) return `${configDirName}/workflows/${filename}`;
  if (fs.existsSync(globalWorkflowsPath)) return `~/.claude/workflows/${filename}`;

  return null;
}

/**
 * Resolve script file path (local or global)
 * @param {string} filename - Script filename
 * @param {string} [configDirName='.claude'] - Config directory name
 * @returns {string|null} Resolved path or null
 */
function resolveScriptPath(filename, configDirName = '.claude') {
  const localPath = path.join(getProjectRoot(), configDirName, 'scripts', filename);
  const globalPath = path.join(os.homedir(), '.claude', 'scripts', filename);
  if (fs.existsSync(localPath)) return `${configDirName}/scripts/${filename}`;
  if (fs.existsSync(globalPath)) return `~/.claude/scripts/${filename}`;
  return null;
}

/**
 * Resolve skills venv Python path (local or global)
 * @param {string} [configDirName='.claude'] - Config directory name
 * @returns {string|null} Resolved venv Python path or null
 */
function resolveSkillsVenv(configDirName = '.claude') {
  const isWindows = process.platform === 'win32';
  const venvBin = isWindows ? 'Scripts' : 'bin';
  const pythonExe = isWindows ? 'python.exe' : 'python3';

  const localVenv = path.join(getProjectRoot(), configDirName, 'skills', '.venv', venvBin, pythonExe);
  const globalVenv = path.join(os.homedir(), '.claude', 'skills', '.venv', venvBin, pythonExe);

  if (fs.existsSync(localVenv)) {
    return isWindows
      ? `${configDirName}\\skills\\.venv\\Scripts\\python.exe`
      : `${configDirName}/skills/.venv/bin/python3`;
  }
  if (fs.existsSync(globalVenv)) {
    return isWindows
      ? '~\\.claude\\skills\\.venv\\Scripts\\python.exe'
      : '~/.claude/skills/.venv/bin/python3';
  }
  return null;
}

/**
 * Build plan context from config and git info
 * @param {string|null} sessionId - Session ID
 * @param {Object} config - Loaded config
 * @returns {Object} Plan context object
 */
function buildPlanContext(sessionId, config) {
  const { plan, paths } = config;
  const gitBranch = getGitBranch();
  const resolved = resolvePlanPath(sessionId, config);
  const reportsPath = getReportsPath(resolved.path, resolved.resolvedBy, plan, paths);

  // Compute naming pattern directly for reliable injection
  const namePattern = resolveNamingPattern(plan, gitBranch);

  const planLine = resolved.resolvedBy === 'session'
    ? `- Plan: ${resolved.path}`
    : resolved.resolvedBy === 'branch'
      ? `- Plan: none | Suggested: ${resolved.path}`
      : `- Plan: none`;

  // Validation config (injected so LLM can reference it)
  const validation = plan.validation || {};
  const validationMode = validation.mode || 'prompt';
  const validationMin = validation.minQuestions || 3;
  const validationMax = validation.maxQuestions || 8;

  return { reportsPath, gitBranch, planLine, namePattern, validationMode, validationMin, validationMax };
}

/**
 * Build a scope key for reminder dedup so cwd-sensitive output can re-inject when needed.
 * @param {Object} params
 * @param {string} [params.baseDir] - Working directory for the hook invocation
 * @returns {string} Stable scope key
 */
function buildInjectionScopeKey({ baseDir } = {}) {
  const cwdKey = normalizePath(path.resolve(baseDir || process.cwd())) || process.cwd();
  return cwdKey;
}

function parseTimestamp(value) {
  if (typeof value === 'number') return value;
  if (typeof value === 'string') return Date.parse(value);
  return NaN;
}

function getReminderScopeState(reminderState, scopeKey) {
  const scopes = reminderState?.scopes;
  if (!scopes || typeof scopes !== 'object') return null;
  const scopeState = scopes[scopeKey];
  return scopeState && typeof scopeState === 'object' ? scopeState : null;
}

function hasRecentInjection(scopeState, now = Date.now()) {
  const injectedTs = parseTimestamp(scopeState?.lastInjectedAt);
  return Number.isFinite(injectedTs) && now - injectedTs < RECENT_INJECTION_TTL_MS;
}

function hasPendingInjection(scopeState, now = Date.now()) {
  const pendingTs = parseTimestamp(scopeState?.pendingAt);
  return Number.isFinite(pendingTs) && now - pendingTs < PENDING_INJECTION_TTL_MS;
}

function pruneReminderScopes(scopes, now = Date.now()) {
  const nextScopes = {};
  for (const [scopeKey, scopeState] of Object.entries(scopes || {})) {
    if (!scopeState || typeof scopeState !== 'object') continue;
    if (hasRecentInjection(scopeState, now) || hasPendingInjection(scopeState, now)) {
      nextScopes[scopeKey] = scopeState;
    }
  }
  return nextScopes;
}

/**
 * The last `count` lines of a file, reading only its final TRANSCRIPT_TAIL_BYTES. A line cut by the
 * start of that window is dropped.
 */
function readTailLines(file, count) {
  const fd = fs.openSync(file, 'r');
  try {
    const { size } = fs.fstatSync(fd);
    const start = Math.max(0, size - TRANSCRIPT_TAIL_BYTES);
    const buffer = Buffer.alloc(size - start);
    let read = 0;
    while (read < buffer.length) {
      const n = fs.readSync(fd, buffer, read, buffer.length - read, start + read);
      if (n === 0) break;
      read += n;
    }
    const lines = buffer.toString('utf-8', 0, read).split('\n');
    if (start > 0) lines.shift();
    return lines.slice(-count);
  } finally {
    fs.closeSync(fd);
  }
}

function wasTranscriptRecentlyInjected(transcriptPath, scopeKey = null) {
  try {
    if (!transcriptPath || !fs.existsSync(transcriptPath)) return false;
    const tail = readTailLines(transcriptPath, 150);
    const hasReminderMarker = tail.some(line => line.includes(REMINDER_MARKER));
    if (!hasReminderMarker) return false;
    if (!scopeKey) return true;

    // The reminder output is cwd-sensitive; only treat transcript fallback as a match
    // when the same cwd-specific session lines were already injected recently.
    return tail.some(line => line === `- CWD: ${scopeKey}`);
  } catch {
    return false;
  }
}

/**
 * Check if context was recently injected (prevent duplicate injection).
 * Uses session-scoped markers when a session ID is available, otherwise falls back to transcript scan.
 * @param {string} transcriptPath - Path to transcript file
 * @param {string|null} [sessionId] - Session identifier for temp-state dedup
 * @param {string|null} [scopeKey='session'] - Scope key for cwd/transcript-aware dedup
 * @returns {boolean} true if recently injected
 */
function wasRecentlyInjected(transcriptPath, sessionId = null, scopeKey = 'session') {
  try {
    if (sessionId) {
      const reminderState = readSessionState(sessionId)?.devRulesReminder;
      if (hasRecentInjection(getReminderScopeState(reminderState, scopeKey))) {
        return true;
      }
    }

    return wasTranscriptRecentlyInjected(transcriptPath, scopeKey);
  } catch {
    return false;
  }
}

/**
 * Reserve an injection slot atomically so concurrent hooks do not double-inject.
 * @param {string|null} sessionId - Session identifier
 * @param {string|null} [scopeKey='session'] - Scope key for cwd/transcript-aware dedup
 * @param {string|null} [transcriptPath] - Transcript path for legacy fallback when no session ID exists
 * @returns {{ shouldInject: boolean, reserved: boolean }} Whether to inject and whether a pending reservation was written
 */
function reserveInjectionScope(sessionId, scopeKey = 'session', transcriptPath = null) {
  const transcriptAlreadyInjected = wasTranscriptRecentlyInjected(transcriptPath, scopeKey);

  if (!sessionId) {
    return {
      shouldInject: !transcriptAlreadyInjected,
      reserved: false
    };
  }

  try {
    let shouldInject = false;
    const now = Date.now();
    const updated = updateSessionState(sessionId, (state) => {
      const reminderState = state.devRulesReminder && typeof state.devRulesReminder === 'object'
        ? state.devRulesReminder
        : {};
      const scopes = pruneReminderScopes(reminderState.scopes, now);
      const scopeState = getReminderScopeState({ scopes }, scopeKey) || {};

      if (hasRecentInjection(scopeState, now) || hasPendingInjection(scopeState, now)) {
        return state;
      }

      if (transcriptAlreadyInjected) {
        scopes[scopeKey] = {
          ...scopeState,
          lastInjectedAt: new Date(now).toISOString()
        };

        return {
          ...state,
          devRulesReminder: {
            ...reminderState,
            scopes
          }
        };
      }

      shouldInject = true;
      scopes[scopeKey] = {
        ...scopeState,
        pendingAt: new Date(now).toISOString()
      };

      return {
        ...state,
        devRulesReminder: {
          ...reminderState,
          scopes
        }
      };
    });

    if (!updated) {
      return {
        shouldInject: !transcriptAlreadyInjected,
        reserved: false
      };
    }

    return { shouldInject, reserved: shouldInject };
  } catch {
    return {
      shouldInject: !transcriptAlreadyInjected,
      reserved: false
    };
  }
}

/**
 * Persist a recent injection marker for the current session and clear the pending reservation.
 * @param {string|null} sessionId - Session identifier
 * @param {string|null} [scopeKey='session'] - Scope key for cwd/transcript-aware dedup
 * @returns {boolean} true when the marker is written
 */
function markRecentlyInjected(sessionId, scopeKey = 'session') {
  if (!sessionId) return false;

  try {
    return updateSessionState(sessionId, (state) => {
      const reminderState = state.devRulesReminder && typeof state.devRulesReminder === 'object'
        ? state.devRulesReminder
        : {};
      const scopes = pruneReminderScopes(reminderState.scopes);
      const scopeState = getReminderScopeState({ scopes }, scopeKey) || {};

      scopes[scopeKey] = {
        ...scopeState,
        lastInjectedAt: new Date().toISOString()
      };
      delete scopes[scopeKey].pendingAt;

      return {
        ...state,
        devRulesReminder: {
          ...reminderState,
          scopes
        }
      };
    });
  } catch {
    return false;
  }
}

/**
 * Clear a pending reservation when the hook fails after reserving a slot.
 * @param {string|null} sessionId - Session identifier
 * @param {string|null} [scopeKey='session'] - Scope key for cwd/transcript-aware dedup
 * @returns {boolean} true when cleanup succeeds
 */
function clearPendingInjection(sessionId, scopeKey = 'session') {
  if (!sessionId) return false;

  try {
    return updateSessionState(sessionId, (state) => {
      const reminderState = state.devRulesReminder && typeof state.devRulesReminder === 'object'
        ? state.devRulesReminder
        : {};
      const scopes = pruneReminderScopes(reminderState.scopes);
      const scopeState = getReminderScopeState({ scopes }, scopeKey);

      if (!scopeState || !scopeState.pendingAt) {
        return state;
      }

      const nextScopeState = { ...scopeState };
      delete nextScopeState.pendingAt;

      if (Object.keys(nextScopeState).length === 0) {
        delete scopes[scopeKey];
      } else {
        scopes[scopeKey] = nextScopeState;
      }

      return {
        ...state,
        devRulesReminder: {
          ...reminderState,
          scopes
        }
      };
    });
  } catch {
    return false;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// SECTION BUILDERS
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Build language section
 * @param {Object} params
 * @param {string} [params.thinkingLanguage] - Language for thinking
 * @param {string} [params.responseLanguage] - Language for response
 * @returns {string[]} Lines for language section
 */
function buildLanguageSection({ thinkingLanguage, responseLanguage }) {
  // Auto-default thinkingLanguage to 'en' when only responseLanguage is set
  const effectiveThinking = thinkingLanguage || (responseLanguage ? 'en' : null);
  const hasThinking = effectiveThinking && effectiveThinking !== responseLanguage;
  const hasResponse = responseLanguage;
  const lines = [];

  if (hasThinking || hasResponse) {
    lines.push(`## Language`);
    if (hasThinking) {
      lines.push(`- Thinking: Use ${effectiveThinking} for reasoning (logic, precision).`);
    }
    if (hasResponse) {
      lines.push(`- Response: Respond in ${responseLanguage} (natural, fluent).`);
    }
    lines.push(``);
  }

  return lines;
}

/**
 * Build session section: the reminder marker, the cwd the paths below are relative to,
 * and the delegation boundary. Date, OS and similar facts already come from Claude Code.
 * @param {Object} [staticEnv] - Pre-computed static environment info
 * @returns {string[]} Lines for session section
 */
function buildSessionSection(staticEnv = {}) {
  return [
    REMINDER_MARKER,
    `- CWD: ${staticEnv.cwd || process.cwd()}`,
    `- Delegate to subagents only when the current user request authorizes subagent or parallel work. Advisory subagents report findings and do not mutate plan/code unless explicitly tasked.`,
    ``
  ];
}

/**
 * Build rules section
 * @param {Object} params
 * @param {string} [params.skillsVenv] - Path to skills venv
 * @param {string} [params.plansPath] - Absolute plans path (Issue #476: prevents wrong subdirectory creation)
 * @param {string} [params.docsPath] - Absolute docs path
 * @returns {string[]} Lines for rules section
 */
function buildRulesSection({ skillsVenv, plansPath, docsPath }) {
  // Issue #476: Use absolute paths to prevent LLM confusion in multi-CLAUDE.md projects
  const plansRef = plansPath || 'plans';
  const docsRef = docsPath || 'docs';
  const lines = [
    `## Rules`,
    `- Create markdown files only under "${plansRef}" or "${docsRef}" unless the user asks for another location.`,
    `- "docs/" in skills and agents means "${docsRef}"; before writing code, follow "${docsRef}/conventions/code-standards.md" when it exists.`
  ];

  if (skillsVenv) {
    lines.push(`- Python scripts in .claude/skills/: use \`${skillsVenv}\``);
  }

  lines.push(`- When a skill script fails, report the failure; fix skill code and rerun only when the current task explicitly authorizes fixing it.`);
  lines.push(`- Advisory/report-only tasks should report modularization or refactor recommendations instead of applying them.`);
  lines.push(``);

  return lines;
}

/**
 * Build paths section
 * @param {Object} params
 * @param {string} params.reportsPath - Reports path
 * @param {string} params.plansPath - Plans path
 * @param {string} params.docsPath - Docs path
 * @param {number} [params.docsMaxLoc=800] - Max lines of code for docs
 * @returns {string[]} Lines for paths section
 */
function buildPathsSection({ reportsPath, plansPath, docsPath, docsMaxLoc = 800 }) {
  return [
    `## Paths`,
    `Reports: ${reportsPath} | Plans: ${plansPath}/ | Docs: ${docsPath}/ | docs.maxLoc: ${docsMaxLoc}`,
    ``
  ];
}

/**
 * Build plan context section
 * @param {Object} params
 * @param {string} params.planLine - Plan status line
 * @param {string} params.reportsPath - Reports path
 * @param {string} [params.gitBranch] - Git branch
 * @param {string} params.validationMode - Validation mode
 * @param {number} params.validationMin - Min questions
 * @param {number} params.validationMax - Max questions
 * @returns {string[]} Lines for plan context section
 */
function buildPlanContextSection({ planLine, reportsPath, gitBranch, validationMode, validationMin, validationMax }) {
  const lines = [
    `## Plan Context`,
    planLine,
    `- Reports: ${reportsPath}`
  ];

  if (gitBranch) {
    lines.push(`- Branch: ${gitBranch}`);
  }

  lines.push(`- Validation: mode=${validationMode}, questions=${validationMin}-${validationMax}`);
  lines.push(``);

  return lines;
}

/**
 * Build naming section
 * @param {Object} params
 * @param {string} params.reportsPath - Reports path
 * @param {string} params.plansPath - Plans path
 * @param {string} params.namePattern - Naming pattern
 * @returns {string[]} Lines for naming section
 */
function buildNamingSection({ reportsPath, plansPath, namePattern }) {
  return [
    `## Naming`,
    `- Report: \`${reportsPath}{type}-${namePattern}-report.md\``,
    `- Plan dir: \`${plansPath}/${namePattern}/\``,
    `- Replace \`{type}\` with: descriptive kebab-case purpose, agent handoff, or workflow context`,
    `- Example type: \`from-code-reviewer-to-planner-audit-plan-review\``,
    `- Avoid generic report names like \`audit-review.md\`, \`review.md\`, \`report.md\`, or \`notes.md\``,
    `- Replace \`{slug}\` in pattern with: descriptive-kebab-slug`
  ];
}

// ═══════════════════════════════════════════════════════════════════════════
// MAIN ENTRY POINTS
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Build full reminder content from all sections
 * @param {Object} params - All parameters for building reminder
 * @returns {string[]} Array of lines
 */
function buildReminder(params) {
  const {
    sessionId,
    thinkingLanguage,
    responseLanguage,
    skillsVenv,
    reportsPath,
    plansPath,
    docsPath,
    docsMaxLoc,
    planLine,
    gitBranch,
    namePattern,
    validationMode,
    validationMin,
    validationMax,
    staticEnv,
    hooks
  } = params;


  return [
    ...buildLanguageSection({ thinkingLanguage, responseLanguage }),
    ...buildSessionSection(staticEnv),
    ...buildRulesSection({ skillsVenv, plansPath, docsPath }),
    ...buildPathsSection({ reportsPath, plansPath, docsPath, docsMaxLoc }),
    ...buildPlanContextSection({ planLine, reportsPath, gitBranch, validationMode, validationMin, validationMax }),
    ...buildNamingSection({ reportsPath, plansPath, namePattern })
  ];
}

/**
 * Build complete reminder context (unified entry point for plugins)
 *
 * @param {Object} [params]
 * @param {string} [params.sessionId] - Session ID
 * @param {Object} [params.config] - ADF config (auto-loaded if not provided)
 * @param {Object} [params.staticEnv] - Pre-computed static environment info
 * @param {string} [params.configDirName='.claude'] - Config directory name
 * @param {string} [params.baseDir] - Base directory for absolute path resolution (Issue #327)
 * @returns {{
 *   content: string,
 *   lines: string[],
 *   sections: Object
 * }}
 */
function buildReminderContext({ sessionId, config, staticEnv, configDirName = '.claude', baseDir } = {}) {
  // Load config if not provided
  const cfg = config || loadConfig({ includeProject: false, includeAssertions: false });

  // Resolve paths
  const skillsVenv = resolveSkillsVenv(configDirName);

  // Build plan context
  const planCtx = buildPlanContext(sessionId, cfg);

  // Issue #327: Use baseDir for absolute path resolution (subdirectory workflow support)
  // If baseDir provided, resolve paths as absolute; otherwise use relative paths
  const effectiveBaseDir = baseDir || null;
  const plansPathRel = normalizePath(cfg.paths?.plans) || 'plans';
  const docsPathRel = normalizePath(cfg.paths?.docs) || 'docs';

  // Build all parameters with absolute paths if baseDir provided
  const params = {
    sessionId,
    thinkingLanguage: cfg.locale?.thinkingLanguage,
    responseLanguage: cfg.locale?.responseLanguage,
    skillsVenv,
    // An active plan outside the project yields an absolute reports path; don't prefix it again.
    reportsPath: effectiveBaseDir && !path.isAbsolute(planCtx.reportsPath)
      ? path.join(effectiveBaseDir, planCtx.reportsPath)
      : planCtx.reportsPath,
    plansPath: effectiveBaseDir ? path.join(effectiveBaseDir, plansPathRel) : plansPathRel,
    docsPath: effectiveBaseDir ? path.join(effectiveBaseDir, docsPathRel) : docsPathRel,
    docsMaxLoc: Math.max(1, parseInt(cfg.docs?.maxLoc, 10) || 800),
    planLine: planCtx.planLine,
    gitBranch: planCtx.gitBranch,
    namePattern: planCtx.namePattern,
    validationMode: planCtx.validationMode,
    validationMin: planCtx.validationMin,
    validationMax: planCtx.validationMax,
    staticEnv,
    hooks: cfg.hooks
  };

  const lines = buildReminder(params);


  return {
    content: lines.join('\n'),
    lines,
    sections: {
      language: buildLanguageSection({ thinkingLanguage: params.thinkingLanguage, responseLanguage: params.responseLanguage }),
      session: buildSessionSection(staticEnv),
      rules: buildRulesSection({ skillsVenv, plansPath: params.plansPath, docsPath: params.docsPath }),
      paths: buildPathsSection({ reportsPath: params.reportsPath, plansPath: params.plansPath, docsPath: params.docsPath, docsMaxLoc: params.docsMaxLoc }),
      planContext: buildPlanContextSection(planCtx),
      naming: buildNamingSection({ reportsPath: params.reportsPath, plansPath: params.plansPath, namePattern: params.namePattern })
    }
  };
}

// ═══════════════════════════════════════════════════════════════════════════
// EXPORTS
// ═══════════════════════════════════════════════════════════════════════════

module.exports = {
  // Main entry points
  buildReminderContext,
  buildReminder,

  // Section builders
  buildLanguageSection,
  buildSessionSection,
  buildRulesSection,
  buildPathsSection,
  buildPlanContextSection,
  buildNamingSection,
  REMINDER_MARKER,

  // Helpers
  execSafe,
  resolveRulesPath,
  resolveScriptPath,
  resolveSkillsVenv,
  buildPlanContext,
  buildInjectionScopeKey,
  wasRecentlyInjected,
  reserveInjectionScope,
  markRecentlyInjected,
  clearPendingInjection,

  // Backward compat alias
  resolveWorkflowPath: resolveRulesPath
};
