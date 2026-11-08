'use strict';

// Rewrites the relative links of one Markdown file after files moved. A link is resolved against the
// file's old location, its target is mapped to where that target lives now, and the link is recomputed
// from the file's new location. URLs, anchors, absolute paths, templated paths and anything inside code
// (fenced blocks, inline code spans) are left alone.

const path = require('path');

// Group 1 is always the target; the d flag gives its exact position
const LINK_PATTERNS = [
  /\]\(\s*<?([^)\s>]+)>?/dg, // [text](target "title")
  /^[ \t]*\[[^\]]+\]:[ \t]*<?([^\s>]+)/dgm, // [label]: target
  /\b(?:href|src)=["']([^"']+)["']/dg, // href="target"
];

/** The text with fenced blocks and inline code blanked out; same length and line breaks, so positions still match. */
function maskCode(text) {
  return text
    .replace(/^(\s*)(```|~~~)[\s\S]*?^\s*\2.*$/gm, (block) => block.replace(/[^\n]/g, ' '))
    .replace(/`[^`\n]*`/g, (span) => ' '.repeat(span.length));
}

function isRewritable(target) {
  return Boolean(target) && !/^[a-z][a-z0-9+.-]*:/i.test(target) && !target.startsWith('#') && !target.startsWith('/') && !/[{}]/.test(target);
}

/**
 * @param {string} text file content
 * @param {{fileOld: string, fileNew: string, mapPath: (rel: string) => string, exists?: (rel: string) => boolean}} opts
 *   project-relative POSIX paths; mapPath gives the new location of an old path (itself when it did not move);
 *   exists tells whether an old path exists, to report links that are broken either way
 * @returns {{text: string, changes: Array<{from: string, to: string}>, broken: string[]}}
 */
function rewriteLinks(text, { fileOld, fileNew, mapPath, exists }) {
  const changes = [];
  const broken = [];
  const fix = (target) => {
    if (!isRewritable(target)) return target;
    const hashAt = target.search(/[#?]/);
    const pathPart = hashAt === -1 ? target : target.slice(0, hashAt);
    const suffix = hashAt === -1 ? '' : target.slice(hashAt);
    if (!pathPart) return target;
    const oldTarget = path.posix.normalize(path.posix.join(path.posix.dirname(fileOld), pathPart));
    if (oldTarget === '..' || oldTarget.startsWith('../')) return target; // points outside the project
    if (exists && !exists(oldTarget)) {
      broken.push(target);
      return target;
    }
    let next = path.posix.relative(path.posix.dirname(fileNew), mapPath(oldTarget)) || '.';
    if (pathPart.endsWith('/') && !next.endsWith('/')) next += '/';
    if (pathPart.startsWith('./') && !next.startsWith('.')) next = `./${next}`;
    if (next === pathPart) return target;
    changes.push({ from: target, to: `${next}${suffix}` });
    return `${next}${suffix}`;
  };
  const masked = maskCode(text);
  const edits = new Map(); // start -> {end, value}
  for (const re of LINK_PATTERNS) {
    for (const m of masked.matchAll(re)) {
      const [start, end] = m.indices[1];
      if (edits.has(start)) continue;
      const target = text.slice(start, end);
      const next = fix(target);
      if (next !== target) edits.set(start, { end, value: next });
    }
  }
  let out = text;
  for (const [start, { end, value }] of [...edits].sort((a, b) => b[0] - a[0])) out = out.slice(0, start) + value + out.slice(end);
  return { text: out, changes, broken };
}

module.exports = { rewriteLinks, isRewritable, maskCode, LINK_PATTERNS };
