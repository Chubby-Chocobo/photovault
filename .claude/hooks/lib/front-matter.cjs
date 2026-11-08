/**
 * front-matter.cjs - Minimal YAML front matter reader shared by hooks and skill scripts.
 *
 * Handles `key: value` lines only. A value stays a string (quotes trimmed, inline lists such as
 * `[a, b]` included); a key with an empty value followed by `- item` lines becomes an array.
 *
 * @module front-matter
 */

'use strict';

const unquote = (value) => {
  const v = value.trim();
  return (v.startsWith('"') && v.endsWith('"') && v.length > 1) || (v.startsWith("'") && v.endsWith("'") && v.length > 1) ? v.slice(1, -1) : v;
};

/** One `- item` line: the item without a trailing ` # comment` and without quotes, or null. */
function listItem(line) {
  const match = line.match(/^-\s+(.*)$/);
  return match ? unquote(match[1].replace(/\s+#.*$/, '')) : null;
}

/**
 * @param {string} content Markdown text that may start with a `---` block
 * @returns {Record<string, string|string[]>} {} when there is no front matter
 */
function parseFrontmatter(content) {
  const match = String(content).match(/^---\s*\n([\s\S]*?)\n---\s*\n?/);
  if (!match) return {};
  const data = {};
  let listKey = null;
  for (const rawLine of match[1].split('\n')) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;
    if (listKey) {
      const item = listItem(line);
      if (item !== null) {
        if (!Array.isArray(data[listKey])) data[listKey] = [];
        data[listKey].push(item);
        continue;
      }
      listKey = null;
    }
    const field = line.match(/^([A-Za-z0-9_-]+):\s*(.*)$/);
    if (!field) continue;
    const value = unquote(field[2]);
    data[field[1]] = value;
    if (field[2].trim() === '') listKey = field[1];
  }
  return data;
}

const unquoteEntry = (s) => s.trim().replace(/^(["'])(.*)\1$/, '$2');

/**
 * List value of a parsed key: an inline list `[a, b]`, a block list (already an array), or one
 * comma-separated value. Quotes and a trailing ` # comment` are dropped; nothing is validated.
 * @param {string|string[]|undefined} raw A value from parseFrontmatter
 * @returns {string[]}
 */
function toList(raw) {
  if (Array.isArray(raw)) return raw.filter((e) => typeof e === 'string');
  if (typeof raw !== 'string' || raw.trim() === '') return [];
  let inner = raw.trim().replace(/\s+#.*$/, '');
  if (inner.startsWith('[')) {
    const m = /^\[([^\]]*)\]/.exec(raw.trim());
    if (!m) return [];
    inner = m[1];
  }
  return inner.split(',').map(unquoteEntry).filter(Boolean);
}

module.exports = { parseFrontmatter, toList };
