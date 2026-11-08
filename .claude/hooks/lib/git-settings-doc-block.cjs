/**
 * git-settings-doc-block.cjs - The "settings" block in <docs>/conventions/git-workflow.md: the
 * project's own git values (flow, main branch, enforcement, tags, direct-push paths, version files)
 * written as plain text, so an agent that cannot run hooks or node still knows them.
 *
 * Pure: text in, text out. Nothing is read from the disk, no process is spawned, and no mode or clone
 * state is looked at, so the same config renders the same bytes on every machine. Values go through
 * normalizeGit (the same rules the hooks enforce, so an invalid value renders the default the hooks
 * use) and then through renderableText; a value that cannot be written safely is an error that names
 * the key, never the value. Block mechanics (find, replace) stay in managed-text-block.cjs.
 *
 * @module git-settings-doc-block
 */

'use strict';

const crypto = require('crypto');
const { readBlock, withBlock } = require('./managed-text-block.cjs');
const { normalizeGit, isRefName } = require('./git-flow-config.cjs');
const { renderableText } = require('./docs-layout.cjs');

const VERSION = 1;
const BEGIN = '<!-- adf:git-settings begin -->';
const END = '<!-- adf:git-settings end -->';
const MARKERS = { begin: BEGIN, end: END };
const STAMP_RE = /^<!-- adf:git-settings v=(\d+) hash=([0-9a-f]{16}) -->$/;

const HEADING = "## This project's settings";
const INTRO = 'Written by the ADF installer from the `git` section of `.claude/config/adf-config.json`. Re-run the installer after you change the `git` settings or the workspace members. If you edit the lines between the markers, the installer stops refreshing them.';
const MEMBERS_HEADING = '### Members';
const OVERRIDE = "A cloned member's own config can override its row; to see the rules in force there, run `node .claude/skills/git/scripts/git-flow.cjs status --cwd <member path>` from this repo.";
// Lines before the derived lines (heading, blank, intro, blank) and after them in a workspace (blank, override)
const FIXED_HEAD = 4;
const FIXED_TAIL = 2;
const DEFAULT_BRANCH_TEXT = "the clone's default branch (`git remote show origin`)";

/** @returns {string} `value` in backticks, or throws (without echoing the value) when it cannot be written safely */
function ticked(key, value) {
  if (!renderableText(value)) throw new Error(`${key} cannot be written into git-workflow.md (it is empty, or holds a backtick, "$", a control character or marker text)`);
  return `\`${value}\``;
}
const tickedList = (key, values) => values.map((v) => ticked(key, v)).join(', ');

const FLOW_LINE = {
  'release-train': 'pull requests and merges: its table under "Branch model"',
  trunk: 'pull requests and merges: its list under "Branch model"',
  off: 'no branch-model checks; commit-message, staging and secret checks still apply',
};

/** Where a member's pull requests go, in words. `main` is already rendered (backticked or the default-branch text). */
function pullRequestText(flow, main) {
  if (flow === 'release-train') return `feature and fix pull requests go to the active release, release and hotfix pull requests to ${main}`;
  if (flow === 'trunk') return `pull requests go to ${main}`;
  return 'no branch model: ask the user where a pull request goes';
}

/** The bullets for the project's own git section. */
function projectLines(rawGit) {
  const g = normalizeGit(rawGit);
  const prefix = g.tagPrefix;
  const tag = ticked('git.tagPrefix', `${prefix}x.y.z`);
  const lines = [
    `- Flow: ${ticked('git.flow', g.flow)} (${FLOW_LINE[g.flow]})`,
    `- Main branch: ${ticked('git.mainBranch', g.mainBranch)}`,
    `- Enforcement: ${ticked('git.enforcement', g.enforcement)}`,
    `- Release tags: ${tag}${prefix === '' ? ' (no prefix)' : ''}`,
  ];
  if (g.flow === 'release-train') {
    lines.push(`- Active release without node: the \`release/*\` branch on your remote (usually \`origin\`; \`git remote\` lists them) with no matching ${tag} tag: \`git ls-remote --heads <remote> 'release/*'\`, then \`git tag -l '${prefix}*'\``);
  }
  if (g.flow !== 'off') {
    const paths = g.directPushPaths.length > 0 ? `only ${tickedList('git.directPush.paths', g.directPushPaths)}` : 'nothing (git.directPush.paths is empty)';
    lines.push(`- Direct pushes to ${ticked('git.mainBranch', g.mainBranch)}: \`chore\` commits touching ${paths}`);
  }
  lines.push(`- Version files: ${g.versionFiles.map((f) => ticked('git.versionFiles', f.path)).join(', ')}`);
  const byFolder = Object.entries(g.pathTypes).map(([folder, types]) => `${ticked('git.commit.pathTypes', folder)} allows ${tickedList('git.commit.pathTypes', types)}`);
  if (byFolder.length > 0) lines.push(`- Commit types by folder: ${byFolder.join('; ')}`);
  return lines;
}

/** One bullet for a workspace member: its rules from the manifest, never from the clone. */
function memberLine(entry, index) {
  const member = entry !== null && typeof entry === 'object' ? entry : {};
  const at = `adf-workspace.json members[${index}]`;
  const hasGit = member.git !== null && typeof member.git === 'object' && !Array.isArray(member.git);
  const g = hasGit ? normalizeGit(member.git) : { flow: 'off', enforcement: 'ask' };
  // With a `git` entry the hooks enforce normalizeGit's main branch. Without one a member's default comes from its
  // clone, which the block must not read: the manifest's branch, else a pointer to where the clone says
  const named = hasGit ? g.mainBranch : [member.branch].find(isRefName);
  const main = named === undefined ? DEFAULT_BRANCH_TEXT : ticked(`${at}.${hasGit ? 'git.mainBranch' : 'branch'}`, named);
  const source = hasGit ? 'its `git` entry in `adf-workspace.json`' : 'the default member rules (no `git` entry in `adf-workspace.json`)';
  return `- ${ticked(`${at}.name`, member.name)} (${ticked(`${at}.path`, member.path)}): flow ${ticked(`${at}.git.flow`, g.flow)}, main branch ${main}, enforcement ${ticked(`${at}.git.enforcement`, g.enforcement)}; ${pullRequestText(g.flow, main)}; rules from ${source}`;
}

/**
 * The derived lines: bullets for the project's git section and, when `members` is an array (the
 * workspace's members), a "Members" part with one bullet per member. Throws an Error naming the key
 * of the first value that cannot be written safely.
 * @param {object} rawGit the `git` section as written in .claude/config/adf-config.json
 * @param {{ members?: object[] }} [opts] `members` only in a workspace root
 * @returns {string[]}
 */
function deriveLines(rawGit, { members } = {}) {
  const lines = projectLines(rawGit);
  if (Array.isArray(members) && members.length > 0) lines.push('', MEMBERS_HEADING, '', ...members.map(memberLine));
  return lines;
}

const bullets = (lines) => lines.filter((l) => l.startsWith('- '));

/** First 16 hex digits of the SHA-256 of the bullet lines (carriage returns removed). */
function hashLines(lines) {
  return crypto.createHash('sha256').update(bullets(lines).join('\n').replace(/\r/g, '')).digest('hex').slice(0, 16);
}

/**
 * The lines between the markers: stamp, heading, intro, the derived lines and, in a workspace, the
 * override sentence. Only the bullets feed the hash, so rewording the fixed text marks nothing stale
 * (a version bump does).
 * @param {string[]} lines deriveLines() output
 * @returns {string[]}
 */
function renderBlock(lines) {
  const body = [`<!-- adf:git-settings v=${VERSION} hash=${hashLines(lines)} -->`, HEADING, '', INTRO, '', ...lines];
  if (lines.includes(MEMBERS_HEADING)) body.push('', OVERRIDE);
  return body;
}

/**
 * @param {string} text Content of git-workflow.md
 * @param {string[]} freshLines deriveLines() now
 * @returns {'missing'|'current'|'stale'|'edited'}
 *   `missing`: no markers, or nothing between them (a deleted block, or a render error when the file was seeded).
 *   `edited`: the bullets differ from their stamped hash, any other line differs from what the renderer
 *   writes (reworded, appended to, added), the stamp is unreadable, or the markers are damaged. `stale`: unedited but not what the
 *   config renders now, or written by another block version.
 */
function blockState(text, freshLines) {
  const found = readBlock(text, MARKERS);
  if (found.state === 'absent') return 'missing';
  if (found.state === 'malformed') return 'edited';
  if (found.body.trim() === '') return 'missing';
  const lines = found.body.replace(/\r/g, '').split('\n');
  const stamp = STAMP_RE.exec(lines[0]);
  if (!stamp) return 'edited';
  const rest = lines.slice(1);
  if (hashLines(rest) !== stamp[2]) return 'edited';
  // Every fixed line must be exactly what the renderer writes; the wording of another version is not known
  if (Number(stamp[1]) !== VERSION) return 'stale';
  const derived = rest.slice(FIXED_HEAD, rest.includes(MEMBERS_HEADING) ? -FIXED_TAIL : undefined);
  const split = derived.indexOf(MEMBERS_HEADING);
  const own = split === -1 ? derived : derived.slice(0, Math.max(split - 1, 0));
  const members = split === -1 ? [] : derived.slice(split + 2);
  const onlyBullets = (ls) => ls.length > 0 && ls.every((l) => l.startsWith('- '));
  if (!onlyBullets(own) || (split !== -1 && (derived[split - 1] !== '' || derived[split + 1] !== '' || !onlyBullets(members)))) return 'edited';
  const expected = renderBlock(derived).slice(1);
  if (rest.length !== expected.length || rest.some((l, i) => l !== expected[i])) return 'edited';
  return stamp[2] === hashLines(freshLines) ? 'current' : 'stale';
}

/** `text` with the block holding `lines` (replaced in place, or appended when absent); broken markers: text unchanged. */
const withSettingsBlock = (text, lines) => withBlock(text, MARKERS, renderBlock(lines));

/** `text` with the markers and nothing between them: what a seed holds when its values cannot be rendered. */
const withEmptyBlock = (text) => withBlock(text, MARKERS, []);

module.exports = { VERSION, BEGIN, END, MARKERS, deriveLines, hashLines, renderBlock, blockState, withSettingsBlock, withEmptyBlock };
