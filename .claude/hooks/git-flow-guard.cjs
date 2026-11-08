#!/usr/bin/env node
/**
 * PreToolUse hook (Bash): holds git and gh commands to the project's git workflow
 * (`git` in .claude/config/adf-config.json; the process is docs/conventions/git-workflow.md).
 *
 * Run as `git-flow-guard.cjs git` for git commands and `git-flow-guard.cjs gh` for gh commands,
 * each registered with its own `if` filter, so a chain is judged once per tool.
 *
 * - git add -A / --all / . / :/ : stage explicit paths instead (left to commit-guard when a commit in
 *   the same directory follows, so the secret scan and this rule share one reason)
 * - git push: force or delete of a protected branch is always denied; a direct push to the main
 *   branch must pass check-push; a hand-pushed release tag is flagged (CI owns tags)
 * - git tag <release tag>: flagged (CI owns tags)
 * - gh pr create: the base must fit the flow (check-pr)
 * - gh pr merge: the strategy must fit the flow, checks must be green, --auto needs branch protection
 *
 * Findings use git.enforcement (off / ask / deny); flow "off" keeps only the safety rules. Each
 * reason names where its rules came from: the project's workflow doc, or for a workspace member its
 * own config, its manifest entry or the default member rules.
 * Lookups that fail or time out ask, never deny. Fail-open on internal errors.
 * Toggle: hooks.git-flow-guard=false.
 */

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { isHookEnabled } = require('./lib/adf-config-utils.cjs');
const { isAuto } = require('./lib/adf-mode.cjs');
const { PROJECT_RULES, getGitConfig, isProtectedBranch, branchKind } = require('./lib/git-flow-config.cjs');
const { parseCommands, parsePush, optionValue, hasFlag, firstOperand, isBulkAdd, bulkAddReason } = require('./lib/git-command-parser.cjs');

const GIT_LIB = path.join(__dirname, '..', 'skills', 'git', 'scripts', 'lib');
const LOOKUP_MS = 3000;
const RANK = { allow: 0, ask: 1, deny: 2 };

function run(cmd, args, cwd, timeout = LOOKUP_MS) {
  const r = spawnSync(cmd, args, { cwd, encoding: 'utf8', timeout });
  return { ok: !r.error && r.status === 0, out: (r.stdout || '').trim(), err: (r.stderr || '').trim(), timedOut: r.error?.code === 'ETIMEDOUT' };
}

class Findings {
  /** @param {{ relaxAsk?: boolean }} [opts] relaxAsk (auto mode) turns an ask into context Claude reads; a deny is never relaxed */
  constructor({ relaxAsk = false } = {}) { this.items = []; this.context = []; this.relaxAsk = relaxAsk; this.source = PROJECT_RULES; }
  /** level: off | ask | deny; the finding is tagged with the rules of the segment being judged */
  add(level, reason) {
    if (level === 'off') return;
    if (level === 'ask' && this.relaxAsk) { this.note(reason); return; }
    this.items.push({ decision: level, reason, source: this.source });
  }
  note(text) { this.context.push(text); }
  decision() { return this.items.reduce((d, f) => (RANK[f.decision] > RANK[d] ? f.decision : d), 'allow'); }
}

const currentBranch = (cwd) => { const r = run('git', ['symbolic-ref', '--quiet', '--short', 'HEAD'], cwd); return r.ok ? r.out : null; };
const refExists = (ref, cwd) => run('git', ['rev-parse', '--verify', '--quiet', ref], cwd).ok;

function upstreamOf(branch, cwd) {
  const r = run('git', ['rev-parse', '--abbrev-ref', `${branch}@{upstream}`], cwd);
  return r.ok && r.out.includes('/') ? r.out.slice(r.out.indexOf('/') + 1) : branch;
}

function remoteOf(cwd, given) {
  if (given && !given.includes('/') && !given.includes(':')) return given;
  const r = run('git', ['remote'], cwd);
  const remotes = r.out.split('\n').filter(Boolean);
  return remotes.includes('origin') ? 'origin' : remotes[0] || null;
}

/**
 * A bulk add that a commit in the same directory follows is left to commit-guard, which reports it in
 * one reason with what that commit would record (secrets included): when two hooks ask about one
 * command, Claude Code passes on only one reason. commit-guard is registered with the same `if` as
 * this hook, so it runs whenever this one does.
 */
function checkAdd(seg, config, findings, later) {
  if (!isBulkAdd(seg.args)) return;
  if (isHookEnabled('commit-guard') && later.some((s) => s.tool === 'git' && s.sub === 'commit' && s.cwd === seg.cwd)) return;
  findings.add(config.enforcement, bulkAddReason(seg.args));
}

function checkTag(seg, config, findings) {
  const listing = seg.args.length === 0 || hasFlag(seg.args, '-l', '--list', '-d', '--delete', '-v', '--verify', '--contains', '--points-at');
  const name = firstOperand(seg.args, new Set(['-m', '--message', '-F', '--file', '-u', '--local-user', '--cleanup']));
  const { isVersion } = require(path.join(GIT_LIB, 'semver.cjs'));
  if (!listing && config.enabled && name && name.startsWith(config.tagPrefix) && isVersion(name.slice(config.tagPrefix.length))) {
    findings.add(config.enforcement, `${name} is a release tag. CI creates release tags when a release or hotfix merges into ${config.mainBranch} (git-flow.cjs tag-release); tag by hand only to repair a missed release.`);
  }
}

function checkPushCommand(seg, config, findings) {
  const push = parsePush(seg.args);
  const remote = remoteOf(seg.cwd, push.remote);
  const branch = currentBranch(seg.cwd);
  if (push.tags && config.enabled) findings.add(config.enforcement, `"git push --tags" pushes every local tag, release tags included. CI creates release tags; push the one tag you mean.`);
  if (push.all && push.force) findings.add('deny', `"git push --all/--mirror --force" would force-push ${config.mainBranch} and release branches, which is never allowed.`);
  for (const u of push.updates) {
    if (u.tag) {
      checkTag({ args: [u.dst.replace(/^refs\/tags\//, '')] }, config, findings);
      continue;
    }
    const src = u.src === 'HEAD' ? branch : u.src;
    const dst = u.dst === 'HEAD' ? branch : u.dst ?? (src ? upstreamOf(src, seg.cwd) : null);
    if (!dst) continue;
    if (isProtectedBranch(config, dst)) {
      if (u.force) { findings.add('deny', `Force-pushing ${dst} is never allowed: it rewrites history others have built on. Push a new commit, or revert.`); continue; }
      if (u.delete) { findings.add(dst === config.mainBranch ? 'deny' : 'ask', `This deletes ${dst} on ${remote}.`); continue; }
    }
    if (u.delete || !config.enabled) continue;
    if (dst === config.mainBranch) checkDirectPush(seg.cwd, config, remote, src, findings);
    const kind = branchKind(config, dst);
    if (['feature', 'fix', 'hotfix'].includes(kind) && remote && !refExists(`refs/remotes/${remote}/${dst}`, seg.cwd)) {
      findings.note(`${dst} is new on ${remote}: open its pull request now (draft is fine), so the team sees the work early. Run git-flow.cjs status for the target branch.`);
    }
  }
}

function checkDirectPush(cwd, config, remote, src, findings) {
  const base = `refs/remotes/${remote}/${config.mainBranch}`;
  if (!refExists(base, cwd)) { findings.add('ask', `${remote}/${config.mainBranch} is not fetched, so this direct push to ${config.mainBranch} cannot be checked. Fetch first.`); return; }
  const { checkPush } = require(path.join(GIT_LIB, 'branch-guards.cjs'));
  const r = checkPush(config, { from: base, to: src || 'HEAD', cwd, remote });
  if (!r.ok) findings.add(config.enforcement, `A direct push to ${config.mainBranch} only carries chore commits on git.directPush.paths:\n- ${r.problems.join('\n- ')}\nOpen a pull request instead.`);
}

/** Local view of tags and release branches, so the hook needs no network. */
function localState(config, cwd, remote) {
  const tags = run('git', ['tag', '--list'], cwd).out.split('\n').filter(Boolean);
  const [refs, strip] = remote ? [`refs/remotes/${remote}/${config.branches.release}`, 3] : [`refs/heads/${config.branches.release}`, 2];
  const branches = run('git', ['for-each-ref', `--format=%(refname:lstrip=${strip})`, refs], cwd).out.split('\n').filter(Boolean);
  return { tags, branches };
}

function checkPrCreate(seg, config, findings) {
  if (!config.enabled) return;
  const head = optionValue(seg.args, '--head', '-H') || currentBranch(seg.cwd);
  const base = optionValue(seg.args, '--base', '-B') || config.mainBranch;
  if (!head) return;
  const remote = remoteOf(seg.cwd);
  const { checkPr } = require(path.join(GIT_LIB, 'branch-guards.cjs'));
  const r = checkPr(config, { base, head, cwd: seg.cwd, remote, ...localState(config, seg.cwd, remote) });
  if (!r.ok) findings.add(config.enforcement, `This pull request breaks the ${config.flow} flow:\n- ${r.problems.join('\n- ')}`);
}

/**
 * True only when GitHub says the branch cannot block a merge: the plan offers no protection (private
 * repos on GitHub Free), or the branch has neither classic protection nor a ruleset. A 403 for lack
 * of admin rights, a timeout or anything else is not proof, so the caller asks instead.
 */
function hasNoProtection(cwd, branch) {
  const prot = run('gh', ['api', `repos/{owner}/{repo}/branches/${branch}/protection`, '--silent'], cwd);
  if (prot.ok) return false;
  if (/Upgrade to GitHub Pro|make this repository public/i.test(prot.err)) return true;
  if (!/Branch not protected/i.test(prot.err)) return false;
  const rules = run('gh', ['api', `repos/{owner}/{repo}/rules/branches/${branch}`], cwd);
  try { return rules.ok && JSON.parse(rules.out).length === 0; } catch { return false; }
}

function checkPrMerge(seg, config, findings) {
  if (!config.enabled) return;
  const target = firstOperand(seg.args, new Set(['-t', '--subject', '-b', '--body', '-F', '--body-file', '--match-head-commit', '-A', '--author-email', '-R', '--repo']));
  const view = run('gh', ['pr', 'view', ...(target ? [target] : []), '--json', 'number,baseRefName,headRefName'], seg.cwd);
  if (!view.ok) { findings.add('ask', `Could not look up the pull request (${view.timedOut ? 'timed out' : view.err.split('\n')[0] || 'gh failed'}), so its merge rules were not checked.`); return; }
  const pr = JSON.parse(view.out);
  const { expectedStrategy } = require(path.join(GIT_LIB, 'branch-guards.cjs'));
  const strategy = expectedStrategy(config, pr.baseRefName, pr.headRefName);
  const given = hasFlag(seg.args, '--squash', '-s') ? 'squash' : hasFlag(seg.args, '--merge', '-m') ? 'merge' : hasFlag(seg.args, '--rebase', '-r') ? 'rebase' : null;
  if (strategy && given !== strategy) {
    findings.add(config.enforcement, `${pr.headRefName} -> ${pr.baseRefName} must use a ${strategy} merge in the ${config.flow} flow; run gh pr merge ${pr.number} --${strategy}.`);
  }
  checkPrCreate({ ...seg, args: ['--base', pr.baseRefName, '--head', pr.headRefName] }, config, findings);

  const checks = run('gh', ['pr', 'checks', String(pr.number), '--json', 'name,bucket'], seg.cwd, LOOKUP_MS * 2);
  if (checks.timedOut || (!checks.ok && !checks.out)) {
    if (!/no checks reported/i.test(checks.err)) findings.add('ask', `Could not read the checks of #${pr.number}; confirm they passed.`);
  } else {
    const list = JSON.parse(checks.out || '[]');
    const bad = list.filter((c) => c.bucket === 'fail' || c.bucket === 'cancel');
    const pending = list.filter((c) => c.bucket === 'pending');
    if (bad.length) findings.add(config.enforcement, `Checks failed on #${pr.number}: ${bad.map((c) => c.name).join(', ')}. Fix them before merging.`);
    else if (pending.length) findings.add(config.enforcement === 'off' ? 'off' : 'ask', `Checks still running on #${pr.number}: ${pending.map((c) => c.name).join(', ')}.`);
  }

  if (hasFlag(seg.args, '--auto')) {
    if (hasNoProtection(seg.cwd, pr.baseRefName)) findings.add('deny', `${pr.baseRefName} has no branch protection here (plan or settings), so --auto would merge at once, red checks or not. Wait for green checks and merge without --auto.`);
    else findings.add('ask', `--auto merges #${pr.number} as soon as GitHub allows it.`);
  }
  if (hasFlag(seg.args, '--delete-branch', '-d')) {
    const children = run('gh', ['pr', 'list', '--base', pr.headRefName, '--json', 'number', '--jq', '.[].number'], seg.cwd);
    if (children.ok && children.out) findings.add('ask', `Deleting ${pr.headRefName} closes the open pull requests based on it: #${children.out.split('\n').join(', #')}.`);
  }
}

function evaluate(command, cwd, tool) {
  const findings = new Findings({ relaxAsk: isAuto(cwd) });
  const segments = parseCommands(command, cwd);
  segments.forEach((seg, index) => {
    if (seg.tool !== tool) return;
    const config = getGitConfig(seg.cwd);
    findings.source = config.rulesFrom || PROJECT_RULES;
    if (tool === 'git' && seg.sub === 'add') checkAdd(seg, config, findings, segments.slice(index + 1));
    else if (tool === 'git' && seg.sub === 'push') checkPushCommand(seg, config, findings);
    else if (tool === 'git' && seg.sub === 'tag') checkTag(seg, config, findings);
    else if (tool === 'gh' && seg.sub === 'pr create') checkPrCreate(seg, config, findings);
    else if (tool === 'gh' && seg.sub === 'pr merge') checkPrMerge(seg, config, findings);
  });
  return findings;
}

/** One header when every finding has the same rules, else each finding names its own. */
function reasonText(items) {
  const sources = [...new Set(items.map((f) => f.source))];
  if (sources.length === 1) return `Git workflow (${sources[0]}):\n${items.map((f) => f.reason).join('\n\n')}`;
  return `Git workflow:\n${items.map((f) => `(${f.source}) ${f.reason}`).join('\n\n')}`;
}

function main() {
  if (!isHookEnabled('git-flow-guard')) return;
  const tool = process.argv[2] === 'gh' ? 'gh' : 'git';
  const stdin = fs.readFileSync(0, 'utf8').trim();
  if (!stdin) return;
  const payload = JSON.parse(stdin);
  if (payload.tool_name !== 'Bash') return;
  const findings = evaluate(String(payload.tool_input?.command || ''), payload.cwd || process.cwd(), tool);
  const decision = findings.decision();
  const output = { hookEventName: 'PreToolUse' };
  if (decision !== 'allow') {
    output.permissionDecision = decision;
    output.permissionDecisionReason = reasonText(findings.items);
  }
  if (findings.context.length) output.additionalContext = findings.context.join('\n');
  if (output.permissionDecision || output.additionalContext) console.log(JSON.stringify({ hookSpecificOutput: output }));
}

if (require.main === module) {
  try {
    main();
  } catch {
    // Fail-open: a broken guard must not stop git (not a repo, gh missing, bad JSON)
  }
  process.exit(0);
}

module.exports = { evaluate };
