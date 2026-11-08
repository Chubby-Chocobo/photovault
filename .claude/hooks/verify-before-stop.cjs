#!/usr/bin/env node
/**
 * Asks Claude to verify code it edited before it ends the turn.
 *
 * - PostToolUse Edit|Write|NotebookEdit: a code file was edited → mark the session "unverified".
 * - PostToolUse Bash: a test, lint, typecheck or build command ran → clear the mark.
 * - Stop: still unverified → block once with a reason telling Claude to run the narrowest check
 *   or say why none applies. `stop_hook_active` (the retry after a block) always lets it stop,
 *   so this never loops.
 *
 * Docs, config and data files do not count as code. State lives in the OS temp dir per session;
 * the transcript is not parsed (its format is internal to Claude Code).
 * Extra verification commands: `verifyBeforeStop.commands` (regex strings) in adf-config.json.
 * Toggle: hooks.verify-before-stop=false. Fail-open on any error.
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { isHookEnabled, readProjectSection, getProjectRoot } = require('./lib/adf-config-utils.cjs');

const NON_CODE_EXTENSIONS = new Set([
  '.md', '.mdx', '.txt', '.rst', '.adoc', '.json', '.jsonc', '.yml', '.yaml', '.toml', '.ini', '.cfg',
  '.conf', '.lock', '.csv', '.tsv', '.svg', '.png', '.jpg', '.jpeg', '.gif', '.webp', '.ico', '.pdf', '.log',
]);
const NON_CODE_DIRS = ['plans', 'docs'];

// Where a command word may start: line start, after a separator, or after a runner prefix,
// optionally behind env assignments (`CI=1 npm test`)
const AT_COMMAND = String.raw`(?:^\s*|[;&|(]\s*|\b(?:npx|bunx|uv\s+run|poetry\s+run|bundle\s+exec|python3?\s+-m)\s+)(?:\w+=\S*\s+)*(?:[\w./-]*/)?`;
const VERIFY_COMMANDS = [
  new RegExp(`${AT_COMMAND}(?:npm|pnpm|yarn|bun)\\s+(?:run\\s+)?(?:t|test|tests|lint|build|typecheck|type-check|check|verify)\\b`),
  new RegExp(`${AT_COMMAND}(?:jest|vitest|mocha|ava|playwright|cypress|tsc|eslint|biome|ruff|mypy|pyright|flake8|pytest|unittest|tox|nox|rspec|phpunit|ctest|golangci-lint|shellcheck)\\b`),
  // make/mvn/gradle only with no target or a check-like target (not clean, install, deploy)
  new RegExp(`${AT_COMMAND}(?:make|mvnw?|gradlew?)(?:\\s+(?:-\\S+\\s+)*(?:test|check|lint|build|all|verify|compile|package)\\b|\\s*$|\\s*[;&|])`),
  /\b(?:go\s+(?:test|vet|build)|cargo\s+(?:test|check|build|clippy)|dotnet\s+(?:test|build)|swift\s+(?:test|build))\b|\bnode\s+--test\b/,
];

const MAX_FILES = 20;
const LOCK_WAIT_MS = 500;
const LOCK_STALE_MS = 5000; // a hook killed while holding the lock

function statePath(sessionId) {
  return path.join(os.tmpdir(), `adf-verify-${String(sessionId).replace(/[^\w-]/g, '')}.json`);
}

function readState(sessionId) {
  try { return JSON.parse(fs.readFileSync(statePath(sessionId), 'utf8')); } catch { return { files: [] }; }
}

function writeState(sessionId, state) {
  const file = statePath(sessionId);
  if (!state.files.length) { fs.rmSync(file, { force: true }); return; }
  // Write then rename so a concurrent hook run never reads a half-written file
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(state), { mode: 0o600 });
  fs.renameSync(tmp, file);
}

/**
 * Runs fn holding a per-session lock, so parallel PostToolUse hooks do not overwrite each other's
 * read-modify-write. Fail-open: if the lock cannot be taken in time (or at all), fn still runs.
 */
function withStateLock(sessionId, fn) {
  const lock = `${statePath(sessionId)}.lock`;
  const deadline = Date.now() + LOCK_WAIT_MS;
  let fd = null;
  while (fd === null) {
    try {
      fd = fs.openSync(lock, 'wx', 0o600);
    } catch (error) {
      if (error?.code !== 'EEXIST' || Date.now() >= deadline) return fn();
      try { if (Date.now() - fs.statSync(lock).mtimeMs > LOCK_STALE_MS) fs.unlinkSync(lock); } catch { /* gone */ }
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5);
    }
  }
  try {
    return fn();
  } finally {
    try { fs.closeSync(fd); } catch { /* ignore */ }
    try { fs.unlinkSync(lock); } catch { /* ignore */ }
  }
}

function isCodeFile(file, cwd) {
  if (!file) return false;
  const base = path.basename(file);
  const ext = path.extname(base).toLowerCase();
  // No extension (Dockerfile, .gitignore, LICENSE) or a non-code one: not something a test covers
  if (!ext || base.startsWith('.env') || NON_CODE_EXTENSIONS.has(ext)) return false;
  const rel = path.relative(getProjectRoot(cwd), path.resolve(cwd, file));
  if (!rel || rel.startsWith('..') || path.isAbsolute(rel)) return false; // outside the project (scratch files)
  return !NON_CODE_DIRS.includes(rel.split(path.sep)[0]);
}

function isVerifyCommand(command, extra) {
  // Quoted text (commit messages, echo arguments, grep patterns) is not a command
  const bare = command.replace(/'[^']*'|"(?:[^"\\]|\\.)*"/g, "''");
  return [...VERIFY_COMMANDS, ...extra].some((re) => re.test(bare));
}

function extraPatterns(cwd) {
  const list = readProjectSection(cwd, 'verifyBeforeStop').commands;
  if (!Array.isArray(list)) return [];
  return list.flatMap((source) => { try { return [new RegExp(source)]; } catch { return []; } });
}

function onPostToolUse(payload, cwd) {
  const sessionId = payload.session_id;
  const input = payload.tool_input || {};
  if (payload.tool_name === 'Bash') {
    if (isVerifyCommand(String(input.command || ''), extraPatterns(cwd))) writeState(sessionId, { files: [] });
    return;
  }
  const file = input.file_path || input.notebook_path;
  if (!isCodeFile(file, cwd)) return;
  const rel = path.relative(cwd, path.resolve(cwd, file)) || file;
  withStateLock(sessionId, () => {
    const state = readState(sessionId);
    if (!state.files.includes(rel)) state.files = [...state.files, rel].slice(-MAX_FILES);
    state.reminded = false; // new edits after a reminder earn a new one
    writeState(sessionId, state);
  });
}

function onStop(payload) {
  const sessionId = payload.session_id;
  const state = readState(sessionId);
  if (!state.files.length) return;
  // One reminder per batch of edits. The list stays until a check runs, so the statusline keeps
  // showing code that no test, lint, typecheck or build has covered
  if (payload.stop_hook_active || state.reminded) return;
  writeState(sessionId, { ...state, reminded: true });
  const shown = state.files.slice(0, 5).join(', ') + (state.files.length > 5 ? `, +${state.files.length - 5} more` : '');
  console.log(JSON.stringify({
    decision: 'block',
    reason: `You edited code (${shown}) and no test, lint, typecheck or build ran after the last edit. `
      + 'Run the narrowest check that covers the change and report its result. '
      + 'If no check applies (no test setup, behavior cannot be exercised here), say so in one line and stop.',
  }));
}

function main() {
  if (!isHookEnabled('verify-before-stop')) return;
  const stdin = fs.readFileSync(0, 'utf8').trim();
  if (!stdin) return;
  const payload = JSON.parse(stdin);
  if (!payload.session_id) return;
  const cwd = payload.cwd || process.cwd();
  if (payload.hook_event_name === 'PostToolUse') onPostToolUse(payload, cwd);
  else if (payload.hook_event_name === 'Stop') onStop(payload);
}

if (require.main === module) {
  try {
    main();
  } catch {
    // Fail-open: never trap Claude because the reminder itself failed
  }
  process.exit(0);
}

// The statusline reads the same state to show edited code that no check has covered yet
module.exports = { readState, statePath };
