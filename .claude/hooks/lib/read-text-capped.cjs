/**
 * read-text-capped.cjs - Read a text file only when it is a regular file within a size cap.
 *
 * Hooks and skill scripts read files that a repo, a member or a plan controls, so each read states
 * how large a file it will accept. Every failure (missing, not a regular file, over the cap,
 * unreadable) is the same answer: null.
 *
 * @module read-text-capped
 */

'use strict';

const fs = require('fs');

/**
 * @param {string} file
 * @param {number} maxBytes Largest accepted size in bytes
 * @param {{ encoding?: BufferEncoding }} [opts]
 * @returns {string|null}
 */
function readTextCapped(file, maxBytes, { encoding = 'utf8' } = {}) {
  try {
    const stat = fs.statSync(file);
    if (!stat.isFile() || stat.size > maxBytes) return null;
    return fs.readFileSync(file, encoding);
  } catch { return null; }
}

module.exports = { readTextCapped };
