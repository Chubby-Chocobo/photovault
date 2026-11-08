/**
 * template-render.cjs - Fill `{{key}}` placeholders in a workspace template.
 *
 * Strict on purpose: a missing key or any `{{` left in the result throws, so a template and its
 * values cannot drift apart silently. Lists render as `- item` lines, an empty list as `- none`.
 * Values are inserted once and never re-scanned.
 *
 * @module template-render
 */

'use strict';

const fs = require('fs');
const path = require('path');

const TEMPLATES_DIR = path.join(__dirname, '..', '..', 'templates');
const PLACEHOLDER = /\{\{([A-Za-z][A-Za-z0-9]*)\}\}/g;
const TEMPLATE_NAME = /^[a-z][a-z-]*(\/[a-z][a-z-]*)?$/;

function format(key, value) {
  if (Array.isArray(value)) return value.length > 0 ? value.map((item) => `- ${item}`).join('\n') : '- none';
  if (typeof value === 'string' || typeof value === 'number') return String(value);
  throw new Error(`template value "${key}" must be a string, a number or a list`);
}

/**
 * @param {string} text Template text
 * @param {Record<string, string|number|string[]>} values
 * @returns {string}
 */
function render(text, values) {
  const out = text.replace(PLACEHOLDER, (_, key) => {
    if (!Object.hasOwn(values, key) || values[key] === undefined) throw new Error(`template needs a value for "${key}"`);
    return format(key, values[key]);
  });
  if (out.includes('{{')) throw new Error('template has a malformed or leftover "{{" placeholder');
  return out;
}

/** Text of a template under the skill's templates dir, by name without extension (e.g. `claude-md/nestjs`). */
function readTemplate(name) {
  if (typeof name !== 'string' || !TEMPLATE_NAME.test(name)) throw new Error('invalid template name');
  return fs.readFileSync(path.join(TEMPLATES_DIR, `${name}.md`), 'utf8');
}

module.exports = { render, readTemplate, TEMPLATES_DIR };
