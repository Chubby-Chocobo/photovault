#!/usr/bin/env node
/**
 * SessionStart Hook - Initializes session environment with project detection
 *
 * Fires: Once per session (startup, resume, clear, compact)
 * Purpose: Load config, detect project info, persist to env vars, output context
 *
 * Exit Codes:
 *   0 - Success (non-blocking, allows continuation)
 *
 * Core detection logic extracted to lib/project-detector.cjs for reuse.
 */

// Crash wrapper
try {
  const fs = require('fs');
  const path = require('path');
  const os = require('os');
  const {
    loadConfig,
    readSessionState,
    writeEnv,
    updateSessionState,
    resolvePlanPath,
    getReportsPath,
    resolveNamingPattern,
    extractTaskListId,
    isHookEnabled,
    getProjectRoot
  } = require('./lib/adf-config-utils.cjs');
  const { createHookTimer, logHookCrash } = require('./lib/hook-logger.cjs');
  const { loadState, refreshStatuslineSnapshot } = require('./lib/session-state-manager.cjs');
  const { createEmptyActivitySnapshot } = require('./lib/statusline-session-cache.cjs');
  const { listConventions, formatConventionsIndex, detectLegacyLayout, formatLegacyNotice, detectDocSite } = require('./lib/docs-layout.cjs');

  // Early exit if hook disabled in config
  if (!isHookEnabled('session-init')) {
    process.exit(0);
  }

  // Import shared project detection logic
  const {
    detectPackageManager,
    detectFramework,
    getGitBranch,
    getGitRoot,
    buildContextOutput
  } = require('./lib/project-detector.cjs');
  const { detectRepoShape } = require('./lib/repo-shape-detector.cjs');

/**
 * One-time cleanup for orphaned .shadowed/ directories from skill-dedup hook (Issue #422)
 * The hook is disabled, but existing orphaned skills still need recovery on startup.
 */
function cleanupOrphanedShadowedSkills() {
  const shadowedDir = path.join(process.cwd(), '.claude', 'skills', '.shadowed');
  if (!fs.existsSync(shadowedDir)) return { restored: [], skipped: [], kept: [] };

  const skillsDir = path.join(process.cwd(), '.claude', 'skills');
  const restored = [];
  const skipped = [];
  const kept = [];

  try {
    const entries = fs.readdirSync(shadowedDir, { withFileTypes: true });
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      const src = path.join(shadowedDir, entry.name);
      const dest = path.join(skillsDir, entry.name);

      try {
        if (!fs.existsSync(dest)) {
          fs.renameSync(src, dest);
          restored.push(entry.name);
          continue;
        }

        const orphanedSkill = path.join(src, 'SKILL.md');
        const localSkill = path.join(dest, 'SKILL.md');
        if (fs.existsSync(orphanedSkill) && fs.existsSync(localSkill)) {
          const orphanedContent = fs.readFileSync(orphanedSkill, 'utf8');
          const localContent = fs.readFileSync(localSkill, 'utf8');
          if (orphanedContent === localContent) {
            fs.rmSync(src, { recursive: true, force: true });
            skipped.push(entry.name);
          } else {
            kept.push(entry.name);
          }
        } else {
          fs.rmSync(src, { recursive: true, force: true });
          skipped.push(entry.name);
        }
      } catch (error) {
        process.stderr.write(`[session-init] Failed to process "${entry.name}": ${error.message}\n`);
      }
    }

    const manifestFile = path.join(shadowedDir, '.dedup-manifest.json');
    if (fs.existsSync(manifestFile)) fs.unlinkSync(manifestFile);
    if (fs.existsSync(shadowedDir) && fs.readdirSync(shadowedDir).length === 0) {
      fs.rmdirSync(shadowedDir);
    }

    return { restored, skipped, kept };
  } catch (error) {
    process.stderr.write(`[session-init] Shadowed cleanup error: ${error.message}\n`);
    return { restored, skipped, kept };
  }
}

function shouldWarmStatuslineCache(source, snapshot) {
  if (!['startup', 'resume', 'compact'].includes(source)) return false;
  return !snapshot || snapshot.warmed !== true;
}

/**
 * Main hook execution
 */
async function main() {
  const timer = createHookTimer('session-init', { event: 'SessionStart' });
  try {
    const shadowedCleanup = cleanupOrphanedShadowedSkills();
    const stdin = fs.readFileSync(0, 'utf-8').trim();
    const data = stdin ? JSON.parse(stdin) : {};
    const envFile = process.env.CLAUDE_ENV_FILE;
    const source = data.source || 'unknown';
    const sessionId = data.session_id || null;
    const existingSession = sessionId ? readSessionState(sessionId) : null;

    const config = loadConfig();
    const sessionStateEnabled = config.hooks?.['session-state'] !== false;

    // Base for absolute plans/reports/docs paths and for shape detection: the project root (see getProjectRoot)
    const baseDir = getProjectRoot();

    const override = config.project?.type;
    const shape = detectRepoShape(baseDir, {});
    const detections = {
      type: override && override !== 'auto' ? override : shape.type,
      pm: detectPackageManager(config.project?.packageManager),
      framework: detectFramework(config.project?.framework)
    };

    // Resolve with the session id so a plan saved by set-active-plan survives compact and resume (/clear starts a new session id and so a fresh plan)
    const resolved = resolvePlanPath(sessionId, config);

    if (sessionId) {
      updateSessionState(sessionId, prev => ({
        ...prev,
        sessionOrigin: process.cwd(),
        activePlan: resolved.resolvedBy === 'session' ? resolved.path : null,
        suggestedPlan: resolved.resolvedBy === 'branch' ? resolved.path : null,
        timestamp: Date.now(),
        source,
        statusline: prev.statusline || createEmptyActivitySnapshot()
      }));
    }

    if (sessionStateEnabled && sessionId && shouldWarmStatuslineCache(source, existingSession?.statusline)) {
      await refreshStatuslineSnapshot(data);
    }

    // Reports path only uses active plans, not suggested ones
    const reportsPath = getReportsPath(resolved.path, resolved.resolvedBy, config.plan, config.paths);

    // Extract task list ID for Claude Code Tasks coordination (shared helper)
    const taskListId = extractTaskListId(resolved);

    // Keep startup metadata cheap. Expensive enrichment is intentionally deferred.
    const staticEnv = {
      nodeVersion: process.version,
      osPlatform: process.platform,
      gitBranch: getGitBranch(),
      gitRoot: getGitRoot(),
      user: process.env.USERNAME || process.env.USER || process.env.LOGNAME || os.userInfo().username,
      locale: process.env.LANG || '',
      timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
      claudeSettingsDir: path.resolve(__dirname, '..')
    };

    // Compute resolved naming pattern (date + issue resolved, {slug} kept as placeholder)
    const namePattern = resolveNamingPattern(config.plan, staticEnv.gitBranch);

    if (envFile) {
      // Session & plan config
      writeEnv(envFile, 'ADF_SESSION_ID', sessionId || '');
      writeEnv(envFile, 'ADF_PLAN_NAMING_FORMAT', config.plan.namingFormat);
      writeEnv(envFile, 'ADF_PLAN_DATE_FORMAT', config.plan.dateFormat);
      writeEnv(envFile, 'ADF_PLAN_ISSUE_PREFIX', config.plan.issuePrefix || '');
      writeEnv(envFile, 'ADF_PLAN_REPORTS_DIR', config.plan.reportsDir);

      // NEW: Resolved naming pattern for DRY file naming in agents
      // Example: "251212-1830-GH-88-{slug}" or "251212-1830-{slug}"
      // Agents use: `{agent-type}-$ADF_NAME_PATTERN.md` and substitute {slug}
      writeEnv(envFile, 'ADF_NAME_PATTERN', namePattern);

      // Plan resolution
      writeEnv(envFile, 'ADF_ACTIVE_PLAN', resolved.resolvedBy === 'session' ? resolved.path : '');
      writeEnv(envFile, 'ADF_SUGGESTED_PLAN', resolved.resolvedBy === 'branch' ? resolved.path : '');

      // Claude Code Tasks integration - enables multi-session/subagent coordination
      // Task list ID = plan directory name (shared across all sessions working on same plan)
      if (taskListId) {
        writeEnv(envFile, 'CLAUDE_CODE_TASK_LIST_ID', taskListId);
      }

      // Paths - use absolute paths based on CWD for subdirectory workflow support (Issue #327)
      writeEnv(envFile, 'ADF_GIT_ROOT', staticEnv.gitRoot || '');
      writeEnv(envFile, 'ADF_REPORTS_PATH', path.isAbsolute(reportsPath) ? reportsPath : path.join(baseDir, reportsPath));
      writeEnv(envFile, 'ADF_DOCS_PATH', path.join(baseDir, config.paths.docs));
      writeEnv(envFile, 'ADF_PLANS_PATH', path.join(baseDir, config.paths.plans));
      writeEnv(envFile, 'ADF_PROJECT_ROOT', baseDir);

      // Project detection
      writeEnv(envFile, 'ADF_PROJECT_TYPE', detections.type || '');
      writeEnv(envFile, 'ADF_PACKAGE_MANAGER', detections.pm || '');
      writeEnv(envFile, 'ADF_FRAMEWORK', detections.framework || '');

      // NEW: Static environment info (so other hooks don't need to recompute)
      writeEnv(envFile, 'ADF_NODE_VERSION', staticEnv.nodeVersion);
      writeEnv(envFile, 'ADF_OS_PLATFORM', staticEnv.osPlatform);
      writeEnv(envFile, 'ADF_GIT_BRANCH', staticEnv.gitBranch || '');
      writeEnv(envFile, 'ADF_USER', staticEnv.user);
      writeEnv(envFile, 'ADF_LOCALE', staticEnv.locale);
      writeEnv(envFile, 'ADF_TIMEZONE', staticEnv.timezone);
      writeEnv(envFile, 'ADF_CLAUDE_SETTINGS_DIR', staticEnv.claudeSettingsDir);

      // Locale config
      if (config.locale?.thinkingLanguage) {
        writeEnv(envFile, 'ADF_THINKING_LANGUAGE', config.locale.thinkingLanguage);
      }
      if (config.locale?.responseLanguage) {
        writeEnv(envFile, 'ADF_RESPONSE_LANGUAGE', config.locale.responseLanguage);
      }

      // Plan validation config (for /adf-plan validate, /adf-plan --hard, /adf-plan --parallel)
      const validation = config.plan?.validation || {};
      writeEnv(envFile, 'ADF_VALIDATION_MODE', validation.mode || 'prompt');
      writeEnv(envFile, 'ADF_VALIDATION_MIN_QUESTIONS', validation.minQuestions || 3);
      writeEnv(envFile, 'ADF_VALIDATION_MAX_QUESTIONS', validation.maxQuestions || 8);
      writeEnv(envFile, 'ADF_VALIDATION_FOCUS_AREAS', (validation.focusAreas || ['assumptions', 'risks', 'tradeoffs', 'architecture']).join(','));


    }

    console.log(`Session ${source}. ${buildContextOutput(config, detections, resolved, staticEnv.gitRoot, shape)}`);

    // Workspace or monorepo: members, search reach, system map and the scope to work in, and contract drift (best effort; the drift line may spawn git once on a cache miss, within its time budget)
    try {
      const { buildWorkspaceContext } = require('./lib/workspace-session-context.cjs');
      const { lines } = buildWorkspaceContext({ baseDir, config, shapeType: detections.type, resolvedPlan: resolved, cwd: process.cwd() });
      if (lines.length > 0) console.log(lines.join('\n'));
    } catch (_) { /* workspace hints are best effort */ }

    // A member repo that carries the marker: where its workspace lives, or that the workspace's system-context block moved on (file reads only)
    try {
      if (detections.type !== 'workspace' && fs.existsSync(path.join(baseDir, '.adf-workspace.json'))) {
        const { memberContextLines } = require('./lib/workspace-session-context.cjs');
        const memberLines = memberContextLines({ baseDir });
        if (memberLines.length > 0) console.log(memberLines.join('\n'));
      }
    } catch (_) { /* member hints are best effort */ }

    // Project conventions as an index (the agent reads a file when a task needs it), and the old docs layout if still present
    try {
      const showLegacy = config.docs?.legacyLayoutNotice !== false;
      const legacy = showLegacy ? detectLegacyLayout(baseDir, { docs: config.paths.docs, plans: config.paths.plans }) : [];
      const docSite = legacy.length > 0 && config.paths.docs === 'docs' ? detectDocSite(baseDir) : null;
      const docsLines = [
        ...formatConventionsIndex(listConventions(path.join(baseDir, config.paths.docs)), config.paths.docs),
        ...formatLegacyNotice(legacy, { docSite }),
      ];
      if (docsLines.length > 0) console.log(`\n${docsLines.join('\n')}`);
    } catch (_) { /* docs hints are best effort */ }

    // Auto mode is never silent: one line says that asks become allows and how to get them back
    try {
      const modeLine = require('./lib/adf-mode.cjs').modeLine(baseDir);
      if (modeLine) console.log(`\n${modeLine}`);
    } catch (_) { /* best effort */ }

    // The git workflow in one line, so branch, PR and release steps start from the project's rules
    try {
      const { getGitConfig } = require('./lib/git-flow-config.cjs');
      const { resolveMemberGitSource, findWorkspaceRoot } = require('./lib/workspace-manifest.cjs');
      const sessionDir = process.cwd();
      const member = resolveMemberGitSource(sessionDir);
      const gitFlow = getGitConfig(member ? sessionDir : baseDir);
      const rules = `${gitFlow.flow} (main: ${gitFlow.mainBranch}, enforcement: ${gitFlow.enforcement}`;
      const steps = `Before branch, PR, merge or release steps, read ${config.paths.docs}/conventions/git-workflow.md if present and run "node .claude/skills/git/scripts/git-flow.cjs status". Stage files by name.`;
      if (member) {
        // Inside a member: its own rules, and where they come from
        console.log(`\nGit workflow: ${rules}, source: ${member.source}) for member ${member.member}. ${steps}`);
      } else if (gitFlow.enabled) {
        const workspace = findWorkspaceRoot(sessionDir) ? ' (workspace repo: plans, docs, map). Members use their own rules; run workspace.cjs repos.' : '.';
        console.log(`\nGit workflow: ${rules})${workspace} ${steps}`);
      }
    } catch (_) { /* best effort */ }

    const hasCleanup =
      shadowedCleanup.restored.length > 0 ||
      shadowedCleanup.skipped.length > 0 ||
      shadowedCleanup.kept.length > 0;
    if (hasCleanup) {
      console.log(`\n[!] SKILL-DEDUP CLEANUP (Issue #422):`);
      console.log(`Recovered orphaned .shadowed/ directory from disabled skill-dedup hook.`);
      if (shadowedCleanup.restored.length > 0) {
        console.log(`Restored ${shadowedCleanup.restored.length} skill(s): ${shadowedCleanup.restored.join(', ')}`);
      }
      if (shadowedCleanup.skipped.length > 0) {
        console.log(`Removed ${shadowedCleanup.skipped.length} duplicate(s): ${shadowedCleanup.skipped.join(', ')}`);
      }
      if (shadowedCleanup.kept.length > 0) {
        console.log(`[!] Kept ${shadowedCleanup.kept.length} skill(s) for manual review (content differs): ${shadowedCleanup.kept.join(', ')}`);
        console.log(`    Review .claude/skills/.shadowed/ and merge changes manually.`);
      }
    }

    if (sessionStateEnabled && (source === 'startup' || source === 'compact')) {
      // Compact recovery reads this session's own file; the folder-wide latest.md is only the startup carry-over
      const previousState = source === 'compact'
        ? (sessionId ? loadState(process.cwd(), sessionId) : null)
        : loadState(process.cwd());
      if (previousState) {
        if (source === 'compact') {
          console.log('\n--- Session State (Post-Compaction Recovery) ---');
          console.log(previousState);
          console.log('--- End Session State ---\n');
          console.log('Context was compacted. Above is your last saved progress. Resume from where you left off.');
          console.log('IMPORTANT: Re-read active plan files and todo list. Do NOT re-do completed work.');
        } else {
          console.log('\n--- Previous Session State ---');
          console.log(previousState);
          console.log('--- End Session State ---\n');
          console.log('Review above state from your last session. Continue where you left off or start fresh.');
        }
      }
    }

    // Info: Show git root when running from subdirectory (Issue #327: now supported)
    if (staticEnv.gitRoot && staticEnv.gitRoot !== process.cwd()) {
      console.log(`📁 Subdirectory mode: Plans/docs will be created in current directory`);
      console.log(`   Git root: ${staticEnv.gitRoot}`);
    }

    // MITIGATION: Issue #277 - Auto-compact can bypass AskUserQuestion approval gates
    // When context is compacted mid-workflow, the summarization may lose "pending approval" state.
    // This warning reminds Claude to verify if user approval was pending before proceeding.
    // Upstream bug: Claude Code CLI should preserve pending interactive state during compaction.
    if (source === 'compact') {
      console.log(`\n⚠️ CONTEXT COMPACTED - APPROVAL STATE CHECK:`);
      console.log(`If you were waiting for user approval via AskUserQuestion (e.g., Step 4 review gate),`);
      console.log(`you MUST re-confirm with the user before proceeding. Do NOT assume approval was given.`);
      console.log(`Use AskUserQuestion to verify: "Context was compacted. Please confirm approval to continue."`);
    }


    if (config.assertions?.length > 0) {
      console.log(`\nUser Assertions:`);
      config.assertions.forEach((assertion, i) => {
        console.log(`  ${i + 1}. ${assertion}`);
      });
    }

    timer.end({ status: 'ok', exit: 0, note: source || 'session-start' });
    process.exit(0);
  } catch (error) {
    console.error(`SessionStart hook error: ${error.message}`);
    logHookCrash('session-init', error, { event: 'SessionStart' });
    process.exit(0);
  }
  }

  main();
} catch (e) {
  try {
    const { logHookCrash } = require('./lib/hook-logger.cjs');
    logHookCrash('session-init', e, { event: 'SessionStart' });
  } catch (_) {}
  process.exit(0); // fail-open
}
