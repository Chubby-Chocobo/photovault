/**
 * scaffold-values.cjs - What a component directory is, and the template values for its
 * CLAUDE.md, its AGENTS.md and its service doc.
 *
 * Every value comes from the system map (validated as safe text), from fixed command names, or
 * from submodule paths that passed the same safe-text rule.
 *
 * @module scaffold-values
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { memberState } = require('../../../../hooks/lib/workspace-manifest.cjs');
const { relativePosix, insideRoot } = require('../../../../hooks/lib/path-containment.cjs');
const { callersOf } = require('../../../../hooks/lib/system-map.cjs');
const { detectStack, STACKS } = require('./component-stack.cjs');
const { commandsFor } = require('./component-commands.cjs');

const CLAUDE_MD_STACKS = new Set(STACKS.filter((s) => s !== 'unknown'));
const SKIP_REASONS = { missing: 'not cloned', 'not-a-repo': 'not cloned', symlink: 'symlink', 'remote-mismatch': 'remote mismatch' };

/**
 * Where a component lives and whether it is safe to read or write there.
 * `skip` is null for a real directory inside the project, else why it is left alone.
 * @returns {{ dir: string, skip: string|null }}
 */
function componentDir(root, manifest, component) {
  const dir = path.join(root, ...component.path.split('/'));
  const absent = 'not found';
  if (manifest) {
    const member = manifest.members.find((m) => m.name === component.member);
    const state = member ? memberState(root, member) : 'missing';
    if (state !== 'cloned') return { dir, skip: SKIP_REASONS[state] || 'not cloned' };
  }
  let stat;
  try { stat = fs.lstatSync(dir); } catch { return { dir, skip: absent }; }
  if (stat.isSymbolicLink()) return { dir, skip: 'symlink' };
  if (!stat.isDirectory()) return { dir, skip: absent };
  try {
    if (!insideRoot(relativePosix(fs.realpathSync(root), fs.realpathSync(dir)))) return { dir, skip: 'symlink' };
  } catch { return { dir, skip: absent }; }
  return { dir, skip: null };
}

/**
 * Why service docs cannot be written under `<docsDir>/architecture/services`: a symlink or a file
 * on that path. Directories that do not exist yet are fine, they are created under checked ones.
 * @returns {string|null}
 */
function servicesDirSkip(root, docsDir) {
  let current = root;
  for (const segment of [...docsDir.split(/[\\/]/).filter((s) => s && s !== '.'), 'architecture', 'services']) {
    current = path.join(current, segment);
    let stat;
    try { stat = fs.lstatSync(current); } catch { return null; }
    if (stat.isSymbolicLink()) return 'symlink';
    if (!stat.isDirectory()) return 'not a directory';
  }
  return null;
}

/** Stack from the map, else from the files in a safe directory, else `unknown`. */
const stackOf = (component, where) => component.stack || (where.skip ? 'unknown' : detectStack(where.dir));

const inCode = (items) => items.map((item) => `\`${item}\``);

/** @returns {{ template: string, values: object }} template name (under templates/) and its values */
function claudeMdPlan({ map, component, where, docs }) {
  const stack = stackOf(component, where);
  const cmds = commandsFor(where.dir, stack, { orgs: map.org });
  const commands = [['Run', cmds.run], ['Build', cmds.build], ['Test', cmds.test], ['Lint', cmds.lint]]
    .filter(([, command]) => command)
    .map(([label, command]) => `${label}: \`${command}\``);
  if (commands.length === 0) commands.push('none detected (add the run, test and lint commands)');
  return {
    template: `claude-md/${CLAUDE_MD_STACKS.has(stack) ? stack : 'generic'}`,
    values: {
      name: component.name,
      role: component.role || 'unknown',
      stack,
      product: map.product || 'this system',
      docs,
      commands,
      generatedDirs: inCode(cmds.generatedDirs),
      vendoredDirs: inCode(cmds.vendoredDirs),
    },
  };
}

/** @returns {{ template: string, values: object }} the CLAUDE.md that imports the component's AGENTS.md */
const importStubPlan = () => ({ template: 'claude-md-import-stub', values: {} });

/** @returns {{ template: string, values: object }} the AGENTS.md that points at the component's CLAUDE.md */
const pointerStubPlan = ({ component }) => ({ template: 'agents-md-pointer-stub', values: { name: component.name } });

/** @returns {{ template: string, values: object }} */
function serviceDocPlan({ map, component, where, docs }) {
  const kinds = new Map((map.contracts || []).map((c) => [c.id, c.kind]));
  const contract = (id) => `\`${id}\`${kinds.has(id) ? ` (${kinds.get(id)})` : ''}`;
  const edge = (name, via, topic) => `\`${name}\` (${via}${topic ? `, topic ${topic}` : ''})`;
  return {
    template: 'service-doc',
    values: {
      name: component.name,
      role: component.role || 'unknown',
      stack: stackOf(component, where),
      product: map.product || 'this system',
      docs,
      path: component.path,
      calls: (component.calls || []).map((call) => edge(call.to, call.via, call.topic)),
      calledBy: callersOf(map, component.name).map((c) => edge(c.component.name, c.via, c.topic)),
      consumes: (component.consumes || []).map(contract),
      produces: (component.produces || []).map(contract),
    },
  };
}

module.exports = { componentDir, servicesDirSkip, claudeMdPlan, importStubPlan, pointerStubPlan, serviceDocPlan };
