#!/usr/bin/env node
/**
 * Installs one of ADF's /loop templates as the project's `.claude/loop.md`, the prompt
 * Claude Code runs for a bare `/loop`.
 *
 *   list                      templates and which one is installed
 *   show <name>               print a template
 *   install <name> [--force]  write .claude/loop.md; a custom or edited file is kept unless --force
 *   remove [--force]          delete .claude/loop.md; a custom or edited file needs --force
 *   status                    what .claude/loop.md currently is
 *
 * An installed file starts with `<!-- adf-loop-template: <name> sha256:<hash> -->`, the hash of
 * the text below it, so an untouched copy of an older template is still recognised as untouched.
 * Before --force replaces or deletes a file, it is copied to .claude/backups/loop-md/ (gitignored
 * by the installer and kept on uninstall).
 *
 * Project root: $CLAUDE_PROJECT_DIR; in a git repo, the nearest directory from the current one up to
 * the top level that has .claude/, else the top level; outside git, the current directory.
 */

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');

const TEMPLATES_DIR = path.join(__dirname, '..', 'templates');
const MARKER = /^<!-- adf-loop-template: ([a-z0-9-]+)(?: sha256:([0-9a-f]{64}))? -->\r?\n/;

function projectRoot(cwd = process.cwd()) {
  if (process.env.CLAUDE_PROJECT_DIR) return process.env.CLAUDE_PROJECT_DIR;
  let top = null;
  try {
    top = execFileSync('git', ['rev-parse', '--show-toplevel'], { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch { /* not a git repo */ }
  // Outside git, look no further than cwd: walking up could reach ~/.claude, the user-level loop.md
  if (!top) return cwd;
  // Nearest .claude/ from cwd up to the git top level (a monorepo package has its own)
  const stop = fs.realpathSync(top);
  for (let dir = fs.realpathSync(cwd); ; dir = path.dirname(dir)) {
    if (fs.existsSync(path.join(dir, '.claude'))) return dir;
    if (dir === stop || path.dirname(dir) === dir) return top;
  }
}

const loopFile = (root) => path.join(root, '.claude', 'loop.md');
const templateNames = () => fs.readdirSync(TEMPLATES_DIR).filter((f) => f.endsWith('.md')).map((f) => f.slice(0, -3)).sort();
const templateBody = (name) => fs.readFileSync(path.join(TEMPLATES_DIR, `${name}.md`), 'utf8').replace(MARKER, '');
// Carriage returns are ignored so a CRLF checkout hashes like the LF original
const hash = (text) => crypto.createHash('sha256').update(text.replace(/\r/g, '')).digest('hex');
const rendered = (name) => {
  const body = templateBody(name);
  return `<!-- adf-loop-template: ${name} sha256:${hash(body)} -->\n${body}`;
};

/**
 * 'none' | 'custom' | 'symlink' | 'not-a-file' | { template, modified, outdated }.
 * modified: edited since install; outdated: an untouched copy of an older version of the template.
 */
function inspect(root) {
  const file = loopFile(root);
  let stat;
  try { stat = fs.lstatSync(file); } catch { return 'none'; }
  // A link may point at a loop.md shared by several projects; writing through it would change them all
  if (stat.isSymbolicLink()) return 'symlink';
  if (!stat.isFile()) return 'not-a-file';
  const content = fs.readFileSync(file, 'utf8');
  const match = MARKER.exec(content);
  if (!match || !templateNames().includes(match[1])) return 'custom';
  const body = content.slice(match[0].length);
  const modified = !match[2] || hash(body) !== match[2];
  return { template: match[1], modified, outdated: !modified && hash(body) !== hash(templateBody(match[1])) };
}

function describe(state) {
  if (state === 'none') return '.claude/loop.md: none (bare /loop runs the built-in maintenance prompt)';
  if (state === 'custom') return '.claude/loop.md: custom file (not an ADF template)';
  if (state === 'not-a-file') return '.claude/loop.md: not a regular file';
  if (state === 'symlink') return '.claude/loop.md: symbolic link (edit its target, or remove the link yourself)';
  const note = state.modified ? ' (edited)' : state.outdated ? ' (older version; install it again to update)' : '';
  return `.claude/loop.md: ${state.template}${note}`;
}

/** Copy the current loop.md to .claude/backups/loop-md/ and return the relative path. */
function backup(root) {
  const dir = path.join(root, '.claude', 'backups', 'loop-md');
  fs.mkdirSync(dir, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  let target = path.join(dir, `loop.md.${stamp}`);
  for (let i = 1; fs.existsSync(target); i++) target = path.join(dir, `loop.md.${stamp}-${i}`);
  fs.copyFileSync(loopFile(root), target);
  return path.relative(root, target).split(path.sep).join('/');
}

function firstLine(name) {
  return templateBody(name).split('\n').find((line) => line.trim()) || '';
}

function run(args, root = projectRoot()) {
  const [command = 'list', name] = args.filter((a) => !a.startsWith('--'));
  const force = args.includes('--force');
  const unknown = args.filter((a) => a.startsWith('--') && a !== '--force');
  if (unknown.length) return { code: 1, out: [`Unknown option ${unknown.join(', ')}. The only option is --force.`] };

  if (command === 'list') {
    const out = templateNames().map((t) => `${t.padEnd(16)} ${firstLine(t)}`);
    return { code: 0, out: [...out, '', describe(inspect(root))] };
  }
  if (command === 'status') return { code: 0, out: [describe(inspect(root))] };
  if ((command === 'show' || command === 'install') && !templateNames().includes(name)) {
    return { code: 1, out: [`Unknown template "${name || ''}". Available: ${templateNames().join(', ')}`] };
  }
  if (command === 'show') return { code: 0, out: [templateBody(name).trimEnd()] };
  if (command !== 'install' && command !== 'remove') {
    return { code: 1, out: [`Unknown command "${command}". Use list, show <name>, install <name> [--force], remove [--force] or status.`] };
  }

  const state = inspect(root);
  if (state === 'not-a-file' || state === 'symlink') return { code: 1, out: [`${describe(state)}. Nothing changed.`] };
  if (command === 'remove' && state === 'none') return { code: 0, out: ['.claude/loop.md does not exist.'] };
  const untouched = typeof state === 'object' && !state.modified;
  if (state !== 'none' && !untouched && !force) {
    const verb = command === 'install' ? 'Not overwritten' : 'Not removed';
    return { code: 2, out: [`${describe(state)}. ${verb}; re-run with --force (the current file is backed up to .claude/backups/loop-md/).`] };
  }
  const saved = state !== 'none' && !untouched ? backup(root) : null;
  const savedNote = saved ? ` (previous file backed up to ${saved})` : '';

  if (command === 'remove') {
    fs.rmSync(loopFile(root));
    return { code: 0, out: [`Removed .claude/loop.md${savedNote}; bare /loop runs the built-in maintenance prompt again.`] };
  }
  fs.mkdirSync(path.join(root, '.claude'), { recursive: true });
  fs.writeFileSync(loopFile(root), rendered(name));
  return {
    code: 0,
    out: [`Installed ${name} as .claude/loop.md${savedNote}.`, 'Run /loop to start it; /loop <prompt> still runs your own prompt instead.'],
  };
}

if (require.main === module) {
  const { code, out } = run(process.argv.slice(2));
  (code === 0 ? process.stdout : process.stderr).write(`${out.join('\n')}\n`);
  process.exit(code);
}

module.exports = { run, inspect, projectRoot, templateNames };
