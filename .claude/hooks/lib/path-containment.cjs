/**
 * path-containment.cjs - The one answer to "is this path inside that root".
 *
 * Compare real paths: `realpathLoose` resolves symlinks even when the tail does not exist yet,
 * `relativePosix` gives a separator-independent relative path, and `insideRoot` accepts only a
 * strict descendant. A sibling directory named `..foo` is inside; `..` and `../x` are not.
 *
 * @module path-containment
 */

'use strict';

const fs = require('fs');
const path = require('path');

/** realpath that tolerates a missing tail: the nearest existing ancestor is resolved, the rest appended. */
function realpathLoose(p) {
  try { return fs.realpathSync(p); } catch {
    const parent = path.dirname(p);
    return parent === p ? p : path.join(realpathLoose(parent), path.basename(p));
  }
}

/** Relative path from `from` to `to`, always with "/" separators. */
function relativePosix(from, to) {
  return path.relative(from, to).split(path.sep).join('/');
}

/** True when `rel` (from relativePosix) names something strictly below the root: not the root itself, not outside it. */
const insideRoot = (rel) => rel !== '' && rel !== '..' && !rel.startsWith('../') && !path.isAbsolute(rel);

module.exports = { realpathLoose, relativePosix, insideRoot };
