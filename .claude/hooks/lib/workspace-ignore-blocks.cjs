/**
 * workspace-ignore-blocks.cjs - The two managed blocks that keep members out of the workspace repo
 * and in reach of search: `.gitignore` (one /<roleDir>/ line each + worktrees/) and `.ignore`
 * (one !/<roleDir>/ line each, so Grep, which skips gitignored paths, still searches members).
 *
 * Both are derived from the manifest's roleDirs. A block whose content differs from the derived
 * one is out of date and gets rewritten between its markers; a malformed block is never touched.
 *
 * @module workspace-ignore-blocks
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { readBlock, withBlock } = require('./managed-text-block.cjs');

const BLOCKS = [
  {
    file: '.gitignore',
    markers: { begin: '# >>> ADF workspace members (managed by /workspace init) >>>', end: '# <<< ADF workspace members <<<' },
    lines: (roleDirs) => [...roleDirs.map((d) => `/${d}/`), 'worktrees/'],
  },
  {
    file: '.ignore',
    markers: { begin: '# >>> ADF workspace search (managed by /workspace init) >>>', end: '# <<< ADF workspace search <<<' },
    lines: (roleDirs) => roleDirs.map((d) => `!/${d}/`),
  },
];

function readText(file) {
  try { return fs.readFileSync(file, 'utf8'); } catch { return ''; }
}

/**
 * @param {string} root
 * @param {typeof BLOCKS[number]} block
 * @param {string[]} roleDirs
 * @returns {{ file: string, status: 'written'|'updated'|'kept'|'malformed', next: string|null }} next is the new file text when it must be written
 */
function planBlock(root, block, roleDirs) {
  const text = readText(path.join(root, block.file));
  const found = readBlock(text, block.markers);
  const wanted = block.lines(roleDirs);
  if (found.state === 'malformed') return { file: block.file, status: 'malformed', next: null };
  if (found.state === 'ok' && found.body.replace(/\r/g, '') === wanted.join('\n')) return { file: block.file, status: 'kept', next: null };
  return { file: block.file, status: found.state === 'ok' ? 'updated' : 'written', next: withBlock(text, block.markers, wanted) };
}

/** Plan for every block. */
const planBlocks = (root, roleDirs) => BLOCKS.map((block) => planBlock(root, block, roleDirs));

module.exports = { BLOCKS, planBlock, planBlocks };
