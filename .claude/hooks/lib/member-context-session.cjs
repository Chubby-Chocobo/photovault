/**
 * member-context-session.cjs - Session-start lines about the generated system-context blocks.
 *
 * `staleBlocksLine` runs in a workspace or monorepo session and names the components whose block, in
 * CLAUDE.md or AGENTS.md, is stale, missing or edited. `memberContextLines` runs in a member repo that
 * carries the marker and says whether the attached workspace has a newer block, or where the workspace
 * lives. File reads and hashing only: no git, no process. Both return `[]` rather than throw.
 *
 * @module member-context-session
 */

'use strict';

const path = require('path');
const { loadSystemMap } = require('./system-map.cjs');
const { memberState } = require('./workspace-manifest.cjs');
const { deriveLines, instructionFilesOf, blockStatesOf, targetsOf } = require('./member-context-block.cjs');
const { readMarkerFile, docsPosix, docsRelOf, attachedWorkspace } = require('./member-link.cjs');

const MAX_COMPONENTS_CHECKED = 200;
const MAX_LISTED = 8;

/**
 * `System context: 2 member blocks stale (order, gateway); run workspace.cjs sync`. Components
 * without an instruction file or outside a cloned member are not counted: sync cannot help them.
 * @param {{ root: string, shapeType: string, manifest: object|null, manifestErrors: string[], map: object|null, config?: object }} ctx
 */
function staleBlocksLine(ctx) {
  const inWorkspace = ctx.shapeType === 'workspace';
  if (ctx.manifestErrors.length > 0 || !ctx.map || (inWorkspace && !ctx.manifest)) return [];
  const docs = docsPosix(ctx.config && ctx.config.paths && ctx.config.paths.docs);
  const names = [];
  const targets = targetsOf({ root: ctx.root, manifest: inWorkspace ? ctx.manifest : null, map: ctx.map });
  for (const t of targets.slice(0, MAX_COMPONENTS_CHECKED)) {
    if (inWorkspace && t.member && memberState(ctx.root, t.member, { git: false }) !== 'cloned') continue;
    const files = instructionFilesOf(path.dirname(t.claudeMd));
    const workspace = t.member ? { memberPath: t.member.path } : null;
    if (blockStatesOf(files, deriveLines({ map: ctx.map, component: t.component, docs, workspace })).outOfDate) names.push(t.component.name);
  }
  // Each block costs a file read and a hash (about 0.1 ms), so past the cap the line says what was left unchecked
  const capped = targets.length > MAX_COMPONENTS_CHECKED;
  const partial = capped ? `, only the first ${MAX_COMPONENTS_CHECKED} of ${targets.length} checked` : '';
  if (names.length === 0) return capped ? [`System context: no stale block in the first ${MAX_COMPONENTS_CHECKED} of ${targets.length}; run workspace.cjs sync --check for the rest`] : [];
  const listed = names.length > MAX_LISTED ? `${names.slice(0, MAX_LISTED).join(', ')} +${names.length - MAX_LISTED} more` : names.join(', ');
  return [`System context: ${names.length} ${inWorkspace ? 'member' : 'component'} ${names.length === 1 ? 'block' : 'blocks'} stale (${listed}${partial}); run workspace.cjs sync`];
}

/**
 * Lines for a session inside a member repo that holds `.adf-workspace.json`.
 * Attached workspace (an additionalDirectories entry with the marker's product): a warning when this
 * member's block is stale or missing. Not attached: the workspace URL only, never a command, because
 * the marker is data the member repo carries.
 * @param {{ baseDir: string }} args
 * @returns {string[]}
 */
function memberContextLines({ baseDir }) {
  try {
    const found = readMarkerFile(baseDir);
    if (found.kind !== 'ours' || !found.marker) return [];
    const marker = found.marker;
    const attached = attachedWorkspace(baseDir, marker);
    if (!attached) {
      const label = marker.product || path.posix.basename(marker.workspace);
      return [`Member "${marker.component}" of workspace ${label}: ${marker.workspace}`];
    }
    const docsRel = docsRelOf(attached.dir);
    const { map } = loadSystemMap(attached.dir, docsRel, { manifest: attached.manifest });
    const component = map && (map.components || []).find((c) => c.name === marker.component);
    if (!component) return [];
    const sub = component.subpath && component.subpath !== '.' ? component.subpath.split('/') : [];
    const member = (attached.manifest.members || []).find((m) => m.name === component.member);
    if (!member) return [];
    const files = instructionFilesOf(path.join(baseDir, ...sub));
    const fresh = deriveLines({ map, component, docs: docsPosix(docsRel), workspace: { memberPath: member.path } });
    const states = blockStatesOf(files, fresh);
    return states.outOfDate && ![states.claude, states.agents].includes('edited') ? [`System context block is stale; run /workspace sync in the workspace at ${attached.dir}`] : [];
  } catch { return []; }
}

module.exports = { staleBlocksLine, memberContextLines };
