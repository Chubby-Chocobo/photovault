#!/usr/bin/env node
'use strict';

/**
 * Claude Code statusline renderer — reads JSON from stdin, writes ANSI lines to stdout.
 * Rendering is config-driven via statuslineLayout in adf-config.json.
 * When statuslineLayout is absent, output is IDENTICAL to pre-refactor behavior.
 */

const { stdin, env } = require('process');
const os = require('os');
const fs = require('fs');
const path = require('path');

const { setColorEnabled } = require('./hooks/lib/colors.cjs');
const { loadConfig, readSessionState } = require('./hooks/lib/adf-config-utils.cjs');
const { getGitInfo } = require('./hooks/lib/git-info-cache.cjs');
const { readActivitySnapshot } = require('./hooks/lib/statusline-session-cache.cjs');
const { resolveLayout } = require('./hooks/lib/statusline-section-registry.cjs');
const { render, renderCompact, renderMinimal } = require('./hooks/lib/statusline-render-modes.cjs');
const { formatCountdown } = require('./hooks/lib/statusline-string-utils.cjs');

const AUTOCOMPACT_BUFFER = 40000;

// ============================================================================
// UTILITIES
// ============================================================================

function expandHome(filePath) {
  const homeDir = os.homedir();
  return filePath.startsWith(homeDir) ? filePath.replace(homeDir, '~') : filePath;
}

// Read stdin with optional inactivity timeout (ADF_STATUSLINE_STDIN_TIMEOUT_MS)
async function readStdin() {
  return new Promise((resolve, reject) => {
    const chunks = [];
    stdin.setEncoding('utf8');
    const parsedTimeout = Number.parseInt(env.ADF_STATUSLINE_STDIN_TIMEOUT_MS || '', 10);
    const timeoutMs = Number.isFinite(parsedTimeout) && parsedTimeout > 0 ? parsedTimeout : 0;
    let timer = null;
    const clearTimer = () => { if (timer) { clearTimeout(timer); timer = null; } };
    const armTimer = () => {
      if (!timeoutMs) return;
      clearTimer();
      timer = setTimeout(() => reject(new Error(`stdin timeout after ${timeoutMs}ms`)), timeoutMs);
    };
    armTimer();
    stdin.on('data', chunk => { chunks.push(chunk); armTimer(); });
    stdin.on('end', () => { clearTimer(); resolve(chunks.join('')); });
    stdin.on('error', err => { clearTimer(); reject(err); });
  });
}

// Build usage window strings from stdin rate_limits (e.g. ["5h 20% (1h30m)", "wk 45% (4d)"]).
// rate_limits only exists for claude.ai subscribers after the first API response; each window may be absent.
function buildUsageWindows(rateLimits) {
  if (!rateLimits || typeof rateLimits !== 'object') return [];
  const now = Date.now();
  return [
    { label: '5h', window: rateLimits.five_hour },
    { label: 'wk', window: rateLimits.seven_day }
  ].map(({ label, window }) => {
    const percent = window?.used_percentage;
    if (typeof percent !== 'number' || !Number.isFinite(percent)) return null;
    let countdown = '';
    // resets_at is Unix epoch seconds
    if (typeof window.resets_at === 'number') {
      const cd = formatCountdown(window.resets_at * 1000 - now);
      if (cd) countdown = ` (${cd})`;
    }
    return `${label} ${Math.round(percent)}%${countdown}`;
  }).filter(Boolean);
}

function extractActivePlanLabel(planPath) {
  if (!planPath || typeof planPath !== 'string') return '';
  const normalizedPath = planPath.trim().replace(/\\/g, '/');
  const match = normalizedPath.match(/(?:^|\/)plans\/\d+-\d+-(.+?)(?:\/|$)/);
  if (match) return match[1];
  return normalizedPath.split('/').filter(Boolean).pop() || normalizedPath;
}

// ============================================================================
// MAIN
// ============================================================================

async function main() {
  try {
    const input = await readStdin();
    if (!input.trim()) { console.error('No input provided'); process.exit(1); }

    const data = JSON.parse(input);

    // Directory
    let currentDir = data.workspace?.current_dir || data.cwd || 'unknown';
    currentDir = expandHome(currentDir);

    const modelName = data.model?.display_name || 'Claude';

    // Git info
    const gitInfo = getGitInfo(data.workspace?.current_dir || data.cwd || process.cwd());
    const gitBranch   = gitInfo?.branch   || '';
    const gitUnstaged = gitInfo?.unstaged || 0;
    const gitStaged   = gitInfo?.staged   || 0;
    const gitAhead    = gitInfo?.ahead    || 0;
    const gitBehind   = gitInfo?.behind   || 0;

    // Session state (active plan + activity snapshot)
    let activePlan = '';
    let transcript = { agents: [], todos: [], sessionStart: null };
    try {
      const sessionId = data.session_id;
      if (sessionId) {
        const session = readSessionState(sessionId);
        const planPath = session?.activePlan?.trim();
        if (planPath) activePlan = extractActivePlanLabel(planPath);
        transcript = readActivitySnapshot(sessionId, readSessionState) || transcript;
      }
    } catch {}

    // Context window percentage
    const usage = data.context_window?.current_usage || {};
    const contextSize = data.context_window?.context_window_size || 0;
    let contextPercent = 0;
    let totalTokens = 0;
    if (contextSize > 0) {
      totalTokens = (usage.input_tokens ?? 0) + (usage.cache_creation_input_tokens ?? 0) + (usage.cache_read_input_tokens ?? 0);
      const preCalc = data.context_window?.used_percentage;
      if (typeof preCalc === 'number' && preCalc >= 0) {
        contextPercent = Math.round(preCalc);
      } else if (contextSize > AUTOCOMPACT_BUFFER) {
        contextPercent = Math.min(100, Math.round(((totalTokens + AUTOCOMPACT_BUFFER) / contextSize) * 100));
      }
    }

    // Persist context data for hooks
    const sessionId = data.session_id;
    if (sessionId && contextSize > 0) {
      try {
        const contextDataPath = path.join(os.tmpdir(), `adf-context-${sessionId}.json`);
        fs.writeFileSync(contextDataPath, JSON.stringify({
          percent: contextPercent,
          remaining: data.context_window?.remaining_percentage ?? (100 - contextPercent),
          tokens: totalTokens,
          size: contextSize,
          usage,
          timestamp: Date.now()
        }));
      } catch {}
    }

    // Config
    const config = loadConfig({ includeProject: false, includeAssertions: false, includeLocale: false });
    const statuslineMode = config.statuslineLayout?.baseMode || config.statusline || 'full';
    const usageWindows = config.statuslineQuota === false ? [] : buildUsageWindows(data.rate_limits);

    // Cost + lines changed
    const billingMode = env.CLAUDE_BILLING_MODE || 'api';
    const costUSD = data.cost?.total_cost_usd;
    const costText = billingMode === 'api' && costUSD && /^\d+(\.\d+)?$/.test(String(costUSD))
      ? `$${parseFloat(costUSD).toFixed(4)}`
      : null;
    const linesAdded   = data.cost?.total_lines_added   || 0;
    const linesRemoved = data.cost?.total_lines_removed || 0;

    // Session signals: effort, fast mode, prompt cache, the branch's PR (stdin), edits no check covered yet (verify-before-stop)
    const effortLevel = ['low', 'medium', 'high', 'xhigh', 'max'].includes(data.effort?.level) ? data.effort.level : '';
    const fastMode = data.fast_mode === true;
    const promptCache = data.prompt_cache && typeof data.prompt_cache === 'object' ? data.prompt_cache : null;
    const pr = data.pr && typeof data.pr === 'object' ? data.pr : null;
    const contextTokens = Number(data.context_window?.total_input_tokens) || totalTokens;
    let unverifiedCount = 0;
    try {
      if (sessionId) unverifiedCount = require('./hooks/verify-before-stop.cjs').readState(sessionId).files.length;
    } catch {}

    // Render context
    const ctx = {
      modelName, currentDir,
      gitBranch, gitUnstaged, gitStaged, gitAhead, gitBehind,
      activePlan, contextPercent, contextSize, contextTokens, usageWindows,
      costText, linesAdded, linesRemoved,
      effortLevel, fastMode, promptCache, pr, unverifiedCount,
      transcript
    };

    // Color config (NO_COLOR env var checked inside isColorEnabled() and always wins)
    if (config.statuslineColors === false) setColorEnabled(false);

    // Resolve layout — uses statuslineLayout from config when present, else defaults
    const layout = resolveLayout(config.statuslineLayout);

    // Dispatch to render mode
    switch (statuslineMode) {
      case 'none':    console.log(''); break;
      case 'minimal': renderMinimal(ctx, layout); break;
      case 'compact': renderCompact(ctx, layout); break;
      case 'full':
      default:        render(ctx, layout, false); break;
    }

  } catch {
    console.log('📁 ' + (process.cwd() || 'unknown'));
  }
}

main().catch(() => { console.log('📁 error'); process.exit(1); });
