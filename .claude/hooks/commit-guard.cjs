#!/usr/bin/env node
/**
 * PreToolUse hook (Bash): checks a `git commit` before it runs.
 *
 * - Secrets (on by default): asks the user when the commit would record a secret-looking
 *   file (.env, private keys) or an added line matching a known credential format, or holds
 *   a change the scan could not read. Files under commitGuard.allowSecretFiles are skipped.
 *   Values are never echoed, only rule names and file:line.
 * - Message format (git.enforcement, or the older commitGuard.messageFormat): a message that is
 *   not a conventional commit, runs past 72 characters, ends with a period or carries an AI
 *   attribution line; also a type that git.commit.pathTypes does not allow for the staged paths.
 * - Bulk staging (`git commit -a`, or a `git add -A` before the commit in the same directory, which
 *   git-flow-guard leaves to this hook so it shares one reason with the secret scan) and, on the
 *   main branch, a commit that could not be pushed straight there (git.directPush), at the same
 *   level; the direct-commit check at most asks.
 *
 * Registered with `if: "Bash(git *)"`, like git-flow-guard (`Bash(git commit *)` does not match
 * `git -C <dir> commit`); the command is re-checked here, so other git commands exit at once.
 * Fail-open: any error lets the command through. Toggle: hooks.commit-guard=false.
 */

const fs = require('node:fs');
const { spawnSync } = require('node:child_process');
const { isHookEnabled } = require('./lib/adf-config-utils.cjs');
const { isAuto } = require('./lib/adf-mode.cjs');
const { scanCommit, scanFailureCause } = require('./lib/commit-secret-scanner.cjs');
const { extractCommitMessage, checkCommitMessage, commitType, shellWords } = require('./lib/commit-message-parser.cjs');
const { PROJECT_RULES, getGitConfig, matchesAny } = require('./lib/git-flow-config.cjs');
const { parseCommands, isBulkAdd, bulkAddReason } = require('./lib/git-command-parser.cjs');

const RANK = { allow: 0, ask: 1, deny: 2 };
const MAX_LISTED = 10;
// Claude reads a deny reason: it names no remedy and sends the reader to the user
const STOP_LINE = "Stop and tell the user; the remedies are a person's (No staged secrets in the project's git-workflow.md).";

// git commit options whose value is the next word (`-m msg`, `--author name`)
const COMMIT_VALUE_OPTIONS = new Set(['--message', '--file', '--reuse-message', '--reedit-message', '--fixup',
  '--squash', '--author', '--date', '--cleanup', '--template', '--trailer', '--pathspec-from-file']);

/** Pathspecs given to `git commit` (`git commit a.js`, `git commit -m x -- a.js`), skipping option values. */
function commitPaths(args) {
  const paths = [];
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--') { paths.push(...args.slice(i + 1)); break; }
    if (COMMIT_VALUE_OPTIONS.has(arg) || /^-[a-zA-Z]*[mFCct]$/.test(arg)) i++;
    else if (!arg.startsWith('-')) paths.push(arg);
  }
  return paths;
}

/**
 * What the command stages on its way to each commit, as one scanCommit scope per directory a
 * commit runs in (an inline `cd` or `git -C` moves it): `git add .`/`-A` → tracked changes +
 * untracked files; `git add <paths>` and `git commit <paths>` → those paths; `git add -u` and
 * `git commit -a` → tracked changes; `git add -f` → ignored files too; otherwise only what is
 * already staged.
 * `bulkAdds` lists the args of each `git add -A`/`.` that runs before a commit in that directory.
 * @returns {Array<{cwd: string, scope: {tracked: string, untracked: boolean, ignored: boolean, commitAll: boolean, bulkAdds: string[][], paths: string[]|null}}>}
 */
function stagingScopes(command, cwd) {
  const state = new Map();
  const commitDirs = [];
  const stateFor = (dir) => {
    if (!state.has(dir)) state.set(dir, { tracked: 'cached', everything: false, untracked: false, ignored: false, paths: [], commitAll: false, bulkAdds: [], bulkAddsBeforeCommit: [] });
    return state.get(dir);
  };
  for (const { tool, cwd: dir, sub, args } of parseCommands(command, cwd)) {
    if (tool !== 'git') continue;
    const flags = args.filter((a) => a.startsWith('-'));
    const s = stateFor(dir);
    if (sub === 'add') {
      const operands = args.filter((a) => !a.startsWith('-'));
      const update = flags.includes('-u') || flags.includes('--update');
      s.tracked = 'head';
      s.ignored = s.ignored || flags.some((a) => a === '--force' || /^-[a-zA-Z]*f[a-zA-Z]*$/.test(a));
      if (isBulkAdd(args)) { s.everything = true; s.untracked = true; s.bulkAdds.push(args); }
      else if (operands.length) { s.paths.push(...operands); s.untracked = s.untracked || !update; }
      else if (update) s.everything = true;
    } else if (sub === 'commit') {
      if (!commitDirs.includes(dir)) commitDirs.push(dir);
      s.bulkAddsBeforeCommit = [...s.bulkAdds];
      const named = commitPaths(args);
      if (flags.some((a) => a === '--all' || /^-[a-zA-Z]*a[a-zA-Z]*$/.test(a))) {
        s.tracked = 'head';
        s.everything = true;
        s.commitAll = true;
      } else if (named.length) {
        // `git commit <paths>` records the working-tree content of those paths, staged or not
        s.tracked = 'head';
        s.paths.push(...named);
      }
    }
  }
  return commitDirs.map((dir) => {
    const s = state.get(dir);
    return { cwd: dir, scope: { tracked: s.tracked, untracked: s.untracked, ignored: s.ignored, commitAll: s.commitAll, bulkAdds: s.bulkAddsBeforeCommit, paths: s.everything || !s.paths.length ? null : s.paths } };
  });
}

/** Files the commit records: what is staged plus what the command stages on the way. */
function committedFiles(cwd, scope) {
  const git = (...args) => (spawnSync('git', args, { cwd, encoding: 'utf8' }).stdout || '').split('\n').filter(Boolean);
  const files = new Set(git('diff', '--cached', '--name-only'));
  if (scope.paths) for (const p of git('ls-files', '--modified', '--others', '--exclude-standard', '--', ...scope.paths)) files.add(p);
  else if (scope.tracked === 'head') for (const p of git('diff', 'HEAD', '--name-only')) files.add(p);
  if (scope.paths === null && scope.untracked) for (const p of git('ls-files', '--others', '--exclude-standard')) files.add(p);
  return [...files];
}

/** True when `cwd` is inside a git work tree; a missing directory or one outside any repo is not. */
function inWorkTree(cwd) {
  const r = spawnSync('git', ['rev-parse', '--is-inside-work-tree'], { cwd, encoding: 'utf8' });
  return r.status === 0 && r.stdout.trim() === 'true';
}

function currentBranch(cwd) {
  const r = spawnSync('git', ['symbolic-ref', '--quiet', '--short', 'HEAD'], { cwd, encoding: 'utf8' });
  return r.status === 0 ? r.stdout.trim() : null;
}

/** Workflow findings for the commit: [{level, reason}]. */
function workflowFindings(cwd, git, message, scope) {
  const out = [];
  const level = git.commit.formatLevel;
  if (level !== 'off' && message !== null) {
    const problems = checkCommitMessage(message, { types: git.commit.types, subjectMax: git.commit.subjectMax });
    if (problems.length) out.push({ level, reason: `Commit message rejected:\n- ${problems.join('\n- ')}\nRewrite the message and commit again.` });
  }
  // Only a commit that carries -a/--all itself counts, not an earlier `git add --all`
  if (git.enforcement !== 'off' && scope.commitAll) {
    out.push({ level: git.enforcement, reason: '"git commit -a" commits every tracked change. Stage the files by name (git add <path> ...), then commit.' });
  }
  if (git.enforcement !== 'off' && scope.bulkAdds.length) out.push({ level: git.enforcement, reason: bulkAddsReason(git.rulesFrom, scope.bulkAdds) });
  const type = commitType(message);
  const prefixes = Object.keys(git.commit.pathTypes);
  if (git.enforcement !== 'off' && type && prefixes.length) {
    const files = committedFiles(cwd, scope);
    for (const prefix of prefixes) {
      const hit = files.filter((f) => f.startsWith(prefix));
      if (hit.length && !git.commit.pathTypes[prefix].includes(type)) {
        out.push({ level: git.enforcement, reason: `A ${type} commit may not touch ${prefix} (allowed there: ${git.commit.pathTypes[prefix].join(', ')}): ${hit.slice(0, 5).join(', ')}` });
      }
    }
  }
  if (git.enabled && git.enforcement !== 'off' && currentBranch(cwd) === git.mainBranch) {
    const outside = committedFiles(cwd, scope).filter((f) => !matchesAny(f, git.directPush.paths));
    if (outside.length || (type && !git.directPush.types.includes(type))) {
      out.push({ level: 'ask', reason: `This commits on ${git.mainBranch}, which only takes ${git.directPush.types.join('/')} commits on git.directPush.paths${outside.length ? ` (outside: ${outside.slice(0, 5).join(', ')})` : ''}. Commit on a branch and open a pull request instead.` });
    }
  }
  return out;
}

/** The bulk adds git-flow-guard left to this hook, under its header naming where the rules came from. */
const bulkAddsReason = (rulesFrom, adds) => `Git workflow (${rulesFrom || PROJECT_RULES}):\n${adds.map(bulkAddReason).join('\n')}`;

function decide(decision, reason) {
  console.log(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: decision, permissionDecisionReason: reason },
  }));
}

/**
 * The reason for a secret finding. At `ask` the user reads it in the prompt, so it names the remedies a
 * person has; at `deny` (auto mode) Claude reads it, so it names none and sends the reader to the user.
 */
function secretReason(files, findings, unscanned, level) {
  const lines = [];
  if (files.length || findings.length) {
    lines.push('This commit would record secrets:');
    for (const file of files.slice(0, MAX_LISTED)) lines.push(`  - ${file} (secret file)`);
    for (const f of findings.slice(0, MAX_LISTED)) lines.push(`  - ${f.file}:${f.line} (${f.rule})`);
    const more = files.length + findings.length - Math.min(files.length, MAX_LISTED) - Math.min(findings.length, MAX_LISTED);
    if (more > 0) lines.push(`  … and ${more} more`);
  }
  if (unscanned.length) {
    lines.push('These changes could not be scanned for secrets:');
    for (const file of unscanned.slice(0, MAX_LISTED)) lines.push(`  - ${file}`);
    if (unscanned.length > MAX_LISTED) lines.push(`  … and ${unscanned.length - MAX_LISTED} more`);
  }
  if (level === 'deny') {
    lines.push(STOP_LINE);
    return lines.join('\n');
  }
  lines.push('Unstage them (git restore --staged <file>) and move the value to an untracked .env, or approve if these are fake values or you have checked them.');
  lines.push('Mark a known-fake line with the comment "adf-allow-secret" to skip it next time; list a fixture file in commitGuard.allowSecretFiles to skip the whole file.');
  return lines.join('\n');
}

function main() {
  if (!isHookEnabled('commit-guard')) return;
  const stdin = fs.readFileSync(0, 'utf8').trim();
  if (!stdin) return;
  const payload = JSON.parse(stdin);
  const command = String(payload.tool_input?.command || '');
  // Cheap prefilter, then the parser decides (it handles `git -C "my repo" commit` and inline cd)
  if (payload.tool_name !== 'Bash' || !/\bgit\b/.test(command) || !/\bcommit\b/.test(command)) return;
  const baseCwd = payload.cwd || process.cwd();
  if (!parseCommands(command, baseCwd).some((c) => c.tool === 'git' && c.sub === 'commit')) return;

  const findings = [];
  // The secret scan never relaxes: in auto mode nobody can approve, so a secret is refused instead of asked
  const secretLevel = isAuto(baseCwd) ? 'deny' : 'ask';
  // git-flow-guard leaves a bulk add before a commit to this hook
  const reportBulkAdds = isHookEnabled('git-flow-guard');
  const check = (cwd, scope) => {
    // The rules of the repo being committed in, a workspace member's own included
    const config = getGitConfig(cwd);
    const found = workflowFindings(cwd, config, extractCommitMessage(command, cwd), reportBulkAdds ? scope : { ...scope, bulkAdds: [] });
    if (config.commit.secrets) {
      let scan;
      try {
        scan = scanCommit(cwd, { ...scope, allowFiles: config.commit.allowSecretFiles });
      } catch (err) {
        // A repository whose scan failed is reported, never swapped for the session directory's repo
        // (in a workspace that is another repo, whose clean scan would let the member's commit through)
        if (!inWorkTree(cwd)) throw err;
        found.push(unchecked(`The staged changes in ${cwd} could not be scanned for secrets: ${scanFailureCause(err)}.`));
        return found;
      }
      const { files, findings: hits, unscanned } = scan;
      if (files.length || hits.length || unscanned.length) found.push({ level: secretLevel, reason: secretReason(files, hits, unscanned, secretLevel) });
    }
    return found;
  };
  const unchecked = (reason) => ({ level: secretLevel, reason: `${reason}\n${secretLevel === 'deny' ? STOP_LINE : 'Check the staged files, then approve.'}` });
  for (const { cwd, scope } of stagingScopes(command, baseCwd)) {
    try {
      findings.push(...check(cwd, scope));
    } catch (err) {
      if (inWorkTree(cwd)) {
        findings.push(unchecked(`The commit in ${cwd} could not be checked for secrets: ${scanFailureCause(err)}.`));
        continue;
      }
      // The commit directory is not a work tree when the hook runs (a cd the parser could not follow, or a folder
      // the same command runs git init in): scan the session directory instead, and ask when that fails too
      try {
        findings.push(...check(baseCwd, scope));
      } catch {
        findings.push(unchecked(`Could not work out which repository this commit runs in (${cwd}), so it was not scanned for secrets.`));
        if (reportBulkAdds && scope.bulkAdds.length) findings.push({ level: 'ask', reason: bulkAddsReason(null, scope.bulkAdds) });
      }
    }
  }
  const decision = findings.reduce((d, f) => (RANK[f.level] > RANK[d] ? f.level : d), 'allow');
  if (decision !== 'allow') decide(decision, findings.map((f) => f.reason).join('\n\n'));
}

if (require.main === module) {
  try {
    main();
  } catch {
    // Fail-open: a broken guard must not stop commits (not a git repo, git missing, bad JSON)
  }
  process.exit(0);
}

module.exports = { stagingScopes };
