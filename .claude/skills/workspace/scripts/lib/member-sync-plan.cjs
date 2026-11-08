/**
 * member-sync-plan.cjs - What `workspace sync` would do: load the map and manifest, pick the
 * components, and plan the block and marker write of each one. Plans only: nothing is written here.
 *
 * @module member-sync-plan
 */

'use strict';

const path = require('path');
const { readBlock, withBlock, withoutBlock } = require('../../../../hooks/lib/managed-text-block.cjs');
const { loadManifest, memberState } = require('../../../../hooks/lib/workspace-manifest.cjs');
const { loadSystemMap } = require('../../../../hooks/lib/system-map.cjs');
const { sameRepo } = require('../../../../hooks/lib/git-remote-url.cjs');
const { MARKERS, MARKER_FILE, deriveLines, renderBlockBody, blockState, blockStatesOf, instructionFilesOf, targetsOf } = require('../../../../hooks/lib/member-context-block.cjs');
const { canWriteMarker, renderMarker, readMarkerFile, docsPosix, docsRelOf } = require('../../../../hooks/lib/member-link.cjs');
const { git, originOf } = require('./workspace-git.cjs');
const { fail, usageError } = require('./workspace-util.cjs');

const NO_CLAUDE_MD = 'no CLAUDE.md (run workspace.cjs scaffold)';
// Why a CLAUDE.md or AGENTS.md that is not a usable regular file leaves the whole row alone
const UNUSABLE = { symlink: 'is not a regular file', 'not-regular': 'is not a regular file', outside: 'is outside the member' };
const NOT_CLONED = { missing: 'not cloned', 'not-a-repo': 'not cloned', symlink: 'symlink', 'remote-mismatch': 'remote mismatch' };

/** Member that owns the repo at `dir`: by the marker's component, else by origin URL. */
function identifyMember(dir, manifest, map) {
  const marker = readMarkerFile(dir);
  const component = marker.kind === 'ours' && marker.marker && (map.components || []).find((c) => c.name === marker.marker.component);
  if (component) return manifest.members.find((m) => m.name === component.member) || null;
  const origin = originOf(dir);
  return (origin && manifest.members.find((m) => m.repo && sameRepo(origin, m.repo))) || null;
}

/**
 * Manifest, map and the components to sync.
 * @returns {{ outcome: object }|{ plan: object }} `outcome` is a finished command result (a failure)
 */
function loadPlan({ root, docsRel, opts }) {
  const from = opts.from === undefined ? null : path.resolve(typeof opts.cwd === 'string' ? opts.cwd : process.cwd(), opts.from);
  if (from && opts.member !== undefined) return { outcome: usageError('--from and --member cannot be combined') };
  if (from && from === path.resolve(root)) return { outcome: usageError('--from must be a different folder from this project') };
  const base = from || root;
  const { manifest, errors } = loadManifest(base);
  if (errors.length > 0) return { outcome: fail(errors.map((e) => `${e}; run workspace.cjs check`)) };
  if (from && !manifest) return { outcome: fail('--from must be a workspace folder holding a valid adf-workspace.json') };
  const baseDocs = from ? docsRelOf(from) : docsRel;
  const loaded = loadSystemMap(base, baseDocs, { manifest });
  if (loaded.errors.length > 0) return { outcome: fail(loaded.errors) };
  if (!loaded.map) return { outcome: fail(['there is no system map; run `init` or `seed-map` first']) };

  const { map } = loaded;
  let targets = targetsOf({ root: base, manifest, map });
  if (from) {
    const member = identifyMember(root, manifest, map);
    if (!member) return { outcome: fail('this project is not a member of that workspace (no marker component and no member with this origin)') };
    targets = targets.filter((t) => t.member === member).map((t) => ({ ...t, memberDir: root, claudeMd: path.join(root, ...t.sub.split('/').filter(Boolean), 'CLAUDE.md') }));
  } else if (opts.member !== undefined) {
    targets = targets.filter((t) => (t.member && t.member.name === opts.member) || t.component.name === opts.member);
    if (targets.length === 0) return { outcome: usageError(`no such member or component in the system map; known: ${targetsOf({ root: base, manifest, map }).map((t) => t.component.name).join(', ') || 'none'}`) };
  }
  const docs = docsPosix(baseDocs);
  return { plan: { base, manifest, map, docs, targets, fromMode: Boolean(from), mapRel: `${docs}/architecture/system-map.json`, whole: !from && opts.member === undefined } };
}

/** Commit id of `dir` for the stamp: 12 hex digits, `-dirty` when the map file has uncommitted changes, `unknown` without git. */
function sourceOf(dir, mapRel) {
  const head = git(['-C', dir, 'rev-parse', '--short=12', 'HEAD'], { timeout: 5000 });
  if (head.status !== 0 || !/^[0-9a-f]{12,}$/.test(head.stdout)) return 'unknown';
  const status = git(['-C', dir, 'status', '--porcelain', '--', mapRel], { timeout: 15000 });
  return `${head.stdout.slice(0, 12)}${status.status === 0 && status.stdout ? '-dirty' : ''}`;
}

/** @returns {'clean'|'dirty'|'unknown'} whether git sees uncommitted changes in `rels` (untracked included) */
function dirtiness(memberDir, rels) {
  const r = git(['-C', memberDir, 'status', '--porcelain', '--', ...rels], { timeout: 15000 });
  if (r.status !== 0) return 'unknown';
  return r.stdout ? 'dirty' : 'clean';
}

/** The workspace values of a target's lines: its member's folder and the workspace URL, or null in a monorepo. */
const workspaceOf = (plan, t) => (plan.manifest ? { memberPath: t.member.path, url: plan.manifest.repo } : null);

/** The block of one instruction file: its state and, when sync should write it, the new text. */
function planBlock(plan, t, text, state, force) {
  if (state === 'current') return { state };
  if (readBlock(text, MARKERS).state === 'malformed') return { state, reason: 'block markers are damaged; repair them by hand' };
  if (state === 'edited' && !force) return { state, reason: 'block edited by hand; use --force to replace it' };
  const body = renderBlockBody({ map: plan.map, component: t.component, docs: plan.docs, source: plan.source, workspace: workspaceOf(plan, t) });
  return { state, next: withBlock(text, MARKERS, body) };
}

/** A CLAUDE.md that imports AGENTS.md carries no block: one left there by an earlier sync is removed. */
function planRemoval(text, state, force) {
  if (state === 'missing') return {};
  if (readBlock(text, MARKERS).state === 'malformed') return { reason: 'block markers are damaged; repair them by hand' };
  if (state === 'edited' && !force) return { reason: 'block edited by hand; use --force to remove it' };
  return { next: withoutBlock(text, MARKERS) };
}

/** The marker of a member, planned once from its main component (the one at the member root, else the first). */
function planMarker(plan, primary) {
  if (!plan.manifest) return { state: 'n/a' };
  if (!canWriteMarker(plan.manifest)) return { state: 'none', reason: 'the manifest has no canonical repo URL, so no marker was written' };
  const expected = renderMarker({ manifest: plan.manifest, component: primary.component.name });
  const current = readMarkerFile(primary.memberDir);
  if (current.kind === 'absent') return { state: 'missing', next: expected };
  if (current.kind === 'ours') return current.text === expected ? { state: 'current' } : { state: 'changed', next: expected };
  return { state: 'foreign', reason: `a ${MARKER_FILE} that is not ADF's was kept` };
}

/** The blocks of one component's instruction files: states, and the writes they need. */
function planInstructionFiles(plan, t, files, relOf, force) {
  const fresh = deriveLines({ map: plan.map, component: t.component, docs: plan.docs, workspace: workspaceOf(plan, t) });
  const states = blockStatesOf(files, fresh);
  const writes = [];
  const reasons = [];
  let claude = { state: states.claude };
  if (files.claude.state === 'absent') {
    // A member without a CLAUDE.md still gets its marker; the file itself is never created here
    if (files.agents.state !== 'file') claude = { state: null, reason: NO_CLAUDE_MD };
  } else if (states.viaAgents) {
    const removal = planRemoval(files.claude.text, blockState(files.claude.text, fresh), force);
    claude = { state: states.claude, ...removal };
  } else {
    claude = planBlock(plan, t, files.claude.text, states.claude, force);
  }
  if (claude.next !== undefined) writes.push({ rel: relOf('CLAUDE.md'), abs: files.claudeMd, content: claude.next });
  if (claude.reason) reasons.push(claude.reason);

  let agentsState = states.agents;
  if (files.agents.state === 'file') {
    const agents = planBlock(plan, t, files.agents.text, states.agents, force);
    if (agents.next !== undefined) writes.push({ rel: relOf('AGENTS.md'), abs: files.agentsMd, content: agents.next });
    if (agents.reason) reasons.push(agents.reason);
  } else if (files.agents.state === 'absent') {
    agentsState = 'n/a';
  } else if (files.agents.state === 'symlink') {
    // Reported in agentsBlock only: the row's action and reason stay what they were before AGENTS.md was read
    agentsState = 'symlink';
  }
  return { claudeState: claude.state, agentsState, writes, reasons, outOfDate: states.outOfDate };
}

/**
 * One row per target, in map order, plus a row for each manifest member with no component.
 * Each row: member, component, the CLAUDE.md block state (`block`) and the AGENTS.md block state
 * (`agentsBlock`), marker state, action (`would-write` / `write` / `unchanged` / `skipped`), the files
 * to write, a reason, and `writes` / `outOfDate` / `viaAgents` (never reported).
 */
function planRows(plan, { force, dryRun }) {
  const states = new Map();
  const cloneSkip = (t) => {
    if (plan.fromMode || !t.member) return null;
    if (!states.has(t.member.name)) states.set(t.member.name, memberState(plan.base, t.member));
    return states.get(t.member.name) === 'cloned' ? null : NOT_CLONED[states.get(t.member.name)] || 'not cloned';
  };
  const primaries = new Map();
  for (const t of plan.targets) {
    const key = t.memberDir;
    const have = primaries.get(key);
    if (!have || (t.sub === '' && have.sub !== '')) primaries.set(key, t);
  }
  const rows = plan.targets.map((t) => {
    const prefix = t.member && !plan.fromMode ? `${t.member.path}/` : '';
    const relOf = (name) => [...t.sub.split('/').filter(Boolean), name].join('/');
    const row = {
      member: t.member ? t.member.name : null, component: t.component.name, path: `${prefix}${relOf('CLAUDE.md')}`,
      paths: { claude: `${prefix}${relOf('CLAUDE.md')}`, agents: `${prefix}${relOf('AGENTS.md')}` },
      block: null, agentsBlock: null, marker: null, action: 'skipped', files: [], reason: null,
    };
    const skip = cloneSkip(t);
    if (skip) return { ...row, reason: skip };
    const files = instructionFilesOf(path.dirname(t.claudeMd), { memberDir: t.memberDir });
    // A symlinked AGENTS.md is only reported: the file it points to, often CLAUDE.md, gets the block
    const unusable = UNUSABLE[files.claude.state] ? `CLAUDE.md ${UNUSABLE[files.claude.state]}` : files.agents.state !== 'symlink' && UNUSABLE[files.agents.state] && `AGENTS.md ${UNUSABLE[files.agents.state]}`;
    if (unusable) return { ...row, reason: unusable };
    const primary = primaries.get(t.memberDir) === t;
    if (files.claude.state === 'absent' && files.agents.state !== 'file' && !primary) return { ...row, reason: NO_CLAUDE_MD };
    const blocks = planInstructionFiles(plan, t, files, relOf, force);
    const marker = primary ? planMarker(plan, t) : { state: 'n/a' };
    const writes = [...blocks.writes];
    if (marker.next !== undefined) writes.push({ rel: MARKER_FILE, abs: path.join(t.memberDir, MARKER_FILE), content: marker.next, create: marker.state === 'missing' });
    const reasons = [...blocks.reasons, marker.reason].filter(Boolean);
    const known = { ...row, block: blocks.claudeState, agentsBlock: blocks.agentsState, marker: marker.state, outOfDate: blocks.outOfDate, viaAgents: files.claudeImportsAgents };
    if (writes.length > 0 && !force) {
      const dirty = dirtiness(t.memberDir, writes.map((w) => w.rel));
      if (dirty !== 'clean') return { ...known, reason: dirty === 'dirty' ? 'uncommitted changes' : 'cannot read git status; use --force' };
    }
    if (writes.length === 0) return { ...known, action: reasons.length > 0 ? 'skipped' : 'unchanged', reason: reasons.join('; ') || null };
    return { ...known, action: dryRun ? 'would-write' : 'write', files: writes.map((w) => `${prefix}${w.rel}`), reason: reasons.join('; ') || null, writes };
  });
  if (plan.whole && plan.manifest) {
    const used = new Set(plan.targets.map((t) => t.member && t.member.name));
    for (const m of plan.manifest.members) {
      if (!used.has(m.name)) rows.push({ member: m.name, component: null, path: null, paths: null, block: null, agentsBlock: null, marker: null, action: 'skipped', files: [], reason: 'no component in the system map' });
    }
  }
  return rows;
}

module.exports = { loadPlan, sourceOf, planRows };
