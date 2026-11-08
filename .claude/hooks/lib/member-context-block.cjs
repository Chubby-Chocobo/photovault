/**
 * member-context-block.cjs - The generated "system context" block in a component's CLAUDE.md and
 * AGENTS.md: what to write (derived lines, hash, rendered body), what state a file's block is in,
 * which of the two files holds it, and where each component's instruction files live.
 *
 * Pure apart from reading instruction files: no process is spawned, nothing is written. The
 * block text is built only from values that pass the system-map text rules again here, so a map
 * that skipped `check` cannot put markup or instructions into an instruction file. Block
 * mechanics (find, replace, append) stay in managed-text-block.cjs.
 *
 * @module member-context-block
 */

'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { readBlock, withoutBlock } = require('./managed-text-block.cjs');
const { VIA, callersOf } = require('./system-map.cjs');
const { safeText } = require('./system-map-validate.cjs');
const { NAME_RE } = require('./workspace-manifest-validate.cjs');
const { canonicalUrl } = require('./git-remote-url.cjs');
const { memberPath: memberDirOf } = require('./workspace-manifest.cjs');
const { relativePosix, insideRoot } = require('./path-containment.cjs');
const { MARKER_FILE, renderMarker, readMarker } = require('./member-link.cjs');

const VERSION = 2;
const BEGIN = '<!-- adf:system-context begin -->';
const END = '<!-- adf:system-context end -->';
const MARKERS = { begin: BEGIN, end: END };
const STAMP_RE = /^<!-- adf:system-context v=(\d+) source=(\S+) hash=([0-9a-f]{16}) -->$/;
// Lines a rendered block may hold besides the stamp; anything else inside the markers was added by hand
const OWN_LINES = [/^$/, /^## System context$/, /^- /, /^Generated from .+ by \/workspace sync/, /^Workspace repo: `[^`]+`$/];
// ADF's installer block in AGENTS.md (scripts/lib/install-agents-md.cjs); matched as text so this module does not need the installer
const INSTALLER_MARKERS = {
  begin: '<!-- >>> ADF (managed by install.sh: replaced on update, removed on uninstall) >>> -->',
  end: '<!-- <<< ADF <<< -->',
};
const MAX_INSTRUCTION_BYTES = 1024 * 1024;
const IMPORT_SCAN_LINES = 200;
const IMPORT_LINES = new Set(['@AGENTS.md', '@./AGENTS.md']);
// Same safety answer as the root AGENTS.md (the .env.example exception included); hashed with the block
const FIXED_LINES = [
  '- Safety: never read or print `.env*` files (templates such as `.env.example` are fine), keys or credentials; ask before destructive commands; never use `--no-verify` unless the user says so; when a hook refuses a commit or push, stop and tell the user.',
  '- Git: stage files by name (never `git add -A`, `git add .` or `git commit -a`); never force-push the main branch or a `release/*` branch.',
];
const SOURCE_RE = /^(?:[0-9a-f]{12}(?:-dirty)?|unknown)$/;

/** @returns {string} `value` in backticks, or throws (without echoing the value) when `ok` rejects it */
function ticked(label, value, ok, source = 'system map') {
  if (!ok(value)) throw new Error(`the ${source} ${label} is not safe to write into an instruction file; run workspace.cjs check`);
  return `\`${value}\``;
}
const textOf = (label, value) => ticked(label, value, safeText);
const nameOf = (label, value) => ticked(label, value, (v) => typeof v === 'string' && NAME_RE.test(v));
const edgeOf = (to, via, topic) => `${nameOf('component name', to)} (${ticked('transport', via, (v) => VIA.includes(v))}${topic === undefined ? '' : `, topic ${textOf('topic', topic)}`})`;

// Same characters the manifest allows in a member path, without safeText's length cap (a path may be 132 characters)
const MEMBER_PATH_RE = /^[A-Za-z0-9][A-Za-z0-9._/-]*$/;
const memberPathText = (value) => { ticked('member path', value, (v) => typeof v === 'string' && MEMBER_PATH_RE.test(v) && !v.includes('--'), 'workspace manifest'); return value; };

/**
 * The lines for one component, in a stable order: the map-derived bullets (every value in
 * backticks), then fixed bullets for safety, git, the PR base and where the rules live, so a
 * hand edit of any of them reads as an edit. Throws when any value fails the text rules.
 * @param {{ map: object, component: object, docs: string, workspace: ({ memberPath: string }|null) }} args
 *   `docs` = docs dir (posix, relative to the workspace or monorepo root); `workspace` is null in a monorepo,
 *   else `memberPath` = the member's folder inside the workspace repo
 * @returns {string[]}
 */
function deriveLines({ map, component, docs, workspace }) {
  if (workspace === undefined) throw new Error('deriveLines needs workspace: an object in a workspace, null in a monorepo');
  const lines = [];
  if (map.product !== undefined) lines.push(`- Product: ${textOf('product', map.product)}`);
  if (map.client !== undefined) lines.push(`- Client: ${textOf('client', map.client)}`);
  const facts = [['role', component.role], ['stack', component.stack]].filter(([, v]) => v !== undefined).map(([k, v]) => `${k} ${textOf(k, v)}`);
  lines.push(`- Component: ${nameOf('component name', component.name)}${facts.length > 0 ? ` (${facts.join(', ')})` : ''}`);
  const add = (label, items) => { if (items.length > 0) lines.push(`- ${label}: ${[...items].sort().join(', ')}`); };
  add('Called by (derived)', callersOf(map, component.name).map((c) => edgeOf(c.component.name, c.via, c.topic)));
  add('Calls', (component.calls || []).map((c) => edgeOf(c.to, c.via, c.topic)));
  add('Consumes', (component.consumes || []).map((id) => nameOf('contract id', id)));
  add('Produces', (component.produces || []).map((id) => nameOf('contract id', id)));
  lines.push(`- System doc: ${textOf('docs path', `${docs}/architecture/services/${component.name}.md`)}`);
  lines.push(...FIXED_LINES);
  const gitDoc = textOf('docs path', `${docs}/conventions/git-workflow.md`);
  const status = 'node .claude/skills/git/scripts/git-flow.cjs status';
  if (workspace) {
    lines.push(`- PR base: run \`${status} --cwd ${memberPathText(workspace.memberPath)}\` from the workspace repo, or read this member's row under Members in its ${gitDoc}.`);
    lines.push("- Rules: the workspace repo's `AGENTS.md`.");
  } else {
    lines.push(`- PR base: \`${status}\` at the repo root, or ${gitDoc}.`);
    lines.push('- Rules: the root `AGENTS.md`.');
  }
  return lines;
}

/** First 16 hex digits of the SHA-256 of the lines (carriage returns removed). */
function hashLines(lines) {
  return crypto.createHash('sha256').update(lines.join('\n').replace(/\r/g, '')).digest('hex').slice(0, 16);
}

/**
 * The lines between the markers: stamp, heading, a generated-from sentence, the bullets and,
 * in a workspace that names its repo, the workspace URL. Only the bullets feed the hash.
 * @param {{ map: object, component: object, docs: string, source: string, workspace: ({ memberPath: string, url?: string }|null) }} args
 *   `workspace` is null in a monorepo; `source` is a 12-character commit id (`-dirty` suffix allowed) or `unknown`
 * @returns {string[]}
 */
function renderBlockBody({ map, component, docs, source, workspace }) {
  if (!SOURCE_RE.test(String(source))) throw new Error('the block source must be a 12-character commit id or "unknown"');
  const lines = deriveLines({ map, component, docs, workspace });
  const mapFile = textOf('docs path', `${docs}/architecture/system-map.json`);
  const origin = workspace
    ? `Generated from the workspace's ${mapFile} by /workspace sync; paths are relative to the workspace root. Edits between the markers are replaced.`
    : `Generated from ${mapFile} by /workspace sync. Edits between the markers are replaced.`;
  const body = [`<!-- adf:system-context v=${VERSION} source=${source} hash=${hashLines(lines)} -->`, '## System context', '', origin, '', ...lines];
  if (workspace && workspace.url !== undefined) {
    if (canonicalUrl(workspace.url) !== workspace.url) throw new Error('the workspace URL must be a canonical https URL');
    body.push('', `Workspace repo: \`${workspace.url}\``);
  }
  return body;
}

/**
 * @param {string} text Content of a CLAUDE.md or AGENTS.md
 * @param {string[]} freshLines deriveLines() of the component now
 * @returns {'missing'|'current'|'stale'|'edited'|'outdated'}
 *   `edited`: the derived lines differ from their stamped hash, a line was added that the renderer does
 *   not produce, the stamp is unreadable, or the markers are damaged (more than one begin or end). `outdated`: a stamp version other than this one.
 */
function blockState(text, freshLines) {
  const found = readBlock(text, MARKERS);
  if (found.state === 'absent') return 'missing';
  if (found.state === 'malformed') return 'edited';
  const lines = found.body.replace(/\r/g, '').split('\n');
  const stamp = STAMP_RE.exec(lines[0]);
  if (!stamp) return 'edited';
  if (Number(stamp[1]) !== VERSION) return 'outdated';
  const rest = lines.slice(1);
  if (rest.some((l) => !OWN_LINES.some((re) => re.test(l)))) return 'edited';
  if (['Generated from ', 'Workspace repo: '].some((p) => rest.filter((l) => l.startsWith(p)).length > 1)) return 'edited';
  if (hashLines(rest.filter((l) => l.startsWith('- '))) !== stamp[3]) return 'edited';
  return stamp[3] === hashLines(freshLines) ? 'current' : 'stale';
}

/**
 * One instruction file as found on disk. `state`: `absent`, `file` (a regular file within the size
 * limit, `text` set), `symlink`, `not-regular` (a directory, a device, a file over 1 MB) or
 * `outside` (the folder resolves outside `memberDir`).
 */
function readInstructionFile(file, memberDir) {
  let stat;
  try { stat = fs.lstatSync(file); } catch { return { state: 'absent' }; }
  if (stat.isSymbolicLink()) return { state: 'symlink' };
  if (!stat.isFile() || stat.size > MAX_INSTRUCTION_BYTES) return { state: 'not-regular' };
  try {
    if (memberDir) {
      const rel = relativePosix(fs.realpathSync(memberDir), fs.realpathSync(path.dirname(file)));
      if (rel !== '' && !insideRoot(rel)) return { state: 'outside' };
    }
    return { state: 'file', text: fs.readFileSync(file, 'utf8') };
  } catch { return { state: 'absent' }; }
}

/** Whether the first lines of a CLAUDE.md hold a line that imports AGENTS.md; a line inside a fenced code block is an example, not an import. */
function importsAgents(text) {
  let fence = null;
  for (const raw of text.split('\n', IMPORT_SCAN_LINES)) {
    const line = raw.replace(/\s+$/, '');
    const opening = /^ {0,3}(`{3,}|~{3,})/.exec(line);
    if (fence) {
      if (opening && opening[1][0] === fence[0] && opening[1].length >= fence.length) fence = null;
    } else if (opening) {
      fence = opening[1];
    } else if (IMPORT_LINES.has(line)) {
      return true;
    }
  }
  return false;
}

/**
 * The two instruction files of a component folder and what decides which one holds the block.
 * @param {string} dir The component folder
 * @param {{ memberDir?: string }} [opts] When set, a folder that resolves outside `memberDir` reads `outside`
 * @returns {{ claudeMd: string, agentsMd: string, claude: object, agents: object, claudeImportsAgents: boolean,
 *   agentsHasInstallerBlock: boolean, agentsOnlyInstallerBlock: boolean }}
 *   `claude` and `agents` are `readInstructionFile` results; `claudeImportsAgents` is true only when both are regular files;
 *   `agentsOnlyInstallerBlock`: ADF's installer block is all the AGENTS.md holds
 */
function instructionFilesOf(dir, { memberDir } = {}) {
  const claudeMd = path.join(dir, 'CLAUDE.md');
  const agentsMd = path.join(dir, 'AGENTS.md');
  const claude = readInstructionFile(claudeMd, memberDir);
  const agents = readInstructionFile(agentsMd, memberDir);
  const hasInstaller = agents.state === 'file' && readBlock(agents.text, INSTALLER_MARKERS).state !== 'absent';
  return {
    claudeMd,
    agentsMd,
    claude,
    agents,
    claudeImportsAgents: claude.state === 'file' && agents.state === 'file' && importsAgents(claude.text),
    agentsHasInstallerBlock: hasInstaller,
    agentsOnlyInstallerBlock: hasInstaller && withoutBlock(agents.text, INSTALLER_MARKERS).trim() === '',
  };
}

const NEEDS_SYNC_STATES = new Set(['missing', 'stale', 'edited']);

/**
 * The block state of each file and whether the component is out of date.
 * When the CLAUDE.md imports AGENTS.md the block lives there: `claude` is `current` unless a block was left in the
 * CLAUDE.md that is stale, edited or damaged (Claude still loads it, so it is reported like any other block and sync
 * removes it); null when the file is not usable. `agents` is null for a file that is absent or not usable.
 * `outOfDate`: a CLAUDE.md block is missing (not when it imports AGENTS.md), stale or edited; an AGENTS.md block is stale or edited; or an AGENTS.md
 * block is missing in a component that has no CLAUDE.md of its own to carry it (CLAUDE.md absent or importing),
 * unless the AGENTS.md holds nothing but ADF's installer block.
 * @param {ReturnType<typeof instructionFilesOf>} files
 * @param {string[]} freshLines deriveLines() of the component now
 * @returns {{ claude: string|null, agents: string|null, viaAgents: boolean, outOfDate: boolean }}
 */
function blockStatesOf(files, freshLines) {
  const viaAgents = files.claudeImportsAgents;
  const claudeState = files.claude.state === 'file' ? blockState(files.claude.text, freshLines) : null;
  const claude = viaAgents && claudeState === 'missing' ? 'current' : claudeState;
  const agents = files.agents.state === 'file' ? blockState(files.agents.text, freshLines) : null;
  const carriesBlock = viaAgents || files.claude.state === 'absent';
  const agentsOut = agents === 'stale' || agents === 'edited' || (agents === 'missing' && carriesBlock && !files.agentsOnlyInstallerBlock);
  return { claude, agents, viaAgents, outOfDate: NEEDS_SYNC_STATES.has(claude) || agentsOut };
}

/**
 * Where each map component's CLAUDE.md lives (its AGENTS.md sits next to it). In a workspace the component sits in a member
 * (`sub` = its subpath inside the member, '' for the member root); in a monorepo `memberDir` is the
 * project root and `sub` the component path.
 * @returns {{ component: object, member: object|null, memberDir: string, sub: string, claudeMd: string }[]}
 */
function targetsOf({ root, manifest, map }) {
  const members = new Map((manifest ? manifest.members : []).map((m) => [m.name, m]));
  return (map.components || []).flatMap((component) => {
    const member = manifest ? members.get(component.member) : null;
    if (manifest && !member) return [];
    const memberDir = member ? memberDirOf(root, member) : root;
    const sub = member ? (component.subpath && component.subpath !== '.' ? component.subpath : '') : component.path;
    return [{ component, member: member || null, memberDir, sub, claudeMd: path.join(memberDir, ...sub.split('/').filter(Boolean), 'CLAUDE.md') }];
  });
}

module.exports = {
  VERSION, BEGIN, END, MARKERS, STAMP_RE, MARKER_FILE, INSTALLER_MARKERS, deriveLines, hashLines, renderBlockBody, blockState,
  instructionFilesOf, blockStatesOf, renderMarker, readMarker, targetsOf,
};
