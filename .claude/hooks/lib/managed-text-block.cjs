'use strict';

// A marked block of lines inside a text file the user also edits (.claude/.gitignore, AGENTS.md).
// Pure functions: text in, text out. ADF replaces or removes only what sits between its markers.

/** @typedef {{begin: string, end: string}} Markers */

const count = (text, needle) => text.split(needle).length - 1;

/**
 * Locate the block. `malformed` = begin without end, end before begin, or more than one of either:
 * callers must not write in that case.
 * @returns {{state: 'absent'|'ok'|'malformed', body: string|null, start: number, end: number}}
 */
function readBlock(text, { begin, end }) {
  const none = { body: null, start: -1, end: -1 };
  const begins = count(text, begin);
  const ends = count(text, end);
  if (begins === 0 && ends === 0) return { state: 'absent', ...none };
  const start = text.indexOf(begin);
  const stop = text.indexOf(end);
  if (begins !== 1 || ends !== 1 || stop < start) return { state: 'malformed', ...none };
  const bodyStart = start + begin.length;
  return { state: 'ok', body: text.slice(bodyStart, stop).replace(/^\r?\n/, '').replace(/\r?\n$/, ''), start, end: stop + end.length };
}

/** Text with the block holding `bodyLines` (string or array): replaced in place, or appended when absent. Malformed markers: text unchanged. */
function withBlock(text, markers, bodyLines) {
  const eol = text.includes('\r\n') ? '\r\n' : '\n';
  const lines = Array.isArray(bodyLines) ? bodyLines : String(bodyLines).replace(/\r/g, '').split('\n');
  const block = [markers.begin, ...lines, markers.end].join(eol);
  const found = readBlock(text, markers);
  if (found.state === 'malformed') return text;
  if (found.state === 'ok') return `${text.slice(0, found.start)}${block}${text.slice(found.end)}`;
  const base = text.replace(/(\r?\n)*$/, '');
  return `${base}${base ? eol + eol : ''}${block}${eol}`;
}

/** Text without the block; everything else stays. A malformed or absent block leaves the text as is. */
function withoutBlock(text, markers) {
  const found = readBlock(text, markers);
  if (found.state !== 'ok') return text;
  const eol = text.includes('\r\n') ? '\r\n' : '\n';
  const before = text.slice(0, found.start).replace(/(\r?\n)*$/, '');
  const after = text.slice(found.end).replace(/^(\r?\n)+/, '');
  const joined = before && after ? `${before}${eol}${eol}${after}` : (before || after);
  return joined ? joined.replace(/(\r?\n)*$/, eol) : '';
}

module.exports = { readBlock, withBlock, withoutBlock };
