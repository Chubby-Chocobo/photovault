/**
 * plan-contract-sections.cjs - Markdown body readers for the plan contract: the `## Decisions`
 * and `## Principles` sections of plan.md and brief.md.
 *
 * Pure functions over text; nothing here touches the file system.
 *
 * @module plan-contract-sections
 */

'use strict';

const FIELDS = { chosen: 'Chosen', alternatives: 'Alternatives', why: 'Why', 'review later': 'Review later' };
const BULLET_RE = /^[-*]\s+(Chosen|Alternatives|Why|Review later):\s*(.*)$/i;

const stripComments = (text) => text.replace(/<!--[\s\S]*?-->/g, '');

/** The text after the front matter block, with LF line ends. */
function bodyOf(content) {
  const text = String(content).replace(/\r\n?/g, '\n');
  const match = text.match(/^---\s*\n([\s\S]*?)\n---\s*\n?/);
  return match ? text.slice(match[0].length) : text;
}

/**
 * Lines of the `## <name>` section (heading match ignores case), up to the next `#` or `##`
 * heading. Fenced code is skipped when looking for headings.
 * @returns {string|null} null when the section is absent
 */
function sectionOf(body, name) {
  const heading = new RegExp(`^##\\s+${name}\\s*$`, 'i');
  const lines = [];
  let found = false;
  let fenced = false;
  for (const line of body.split('\n')) {
    if (/^\s*(```|~~~)/.test(line)) fenced = !fenced;
    else if (!fenced && /^#{1,2}\s/.test(line)) {
      if (found) break;
      found = heading.test(line);
      continue;
    }
    if (found) lines.push(line);
  }
  return found ? lines.join('\n') : null;
}

/** Text of the brief's `## Principles` section, or null when absent or empty. */
function readPrinciples(briefContent) {
  const section = sectionOf(bodyOf(briefContent), 'Principles');
  const text = section === null ? '' : stripComments(section).trim();
  return text === '' ? null : text;
}

function parseEntries(text) {
  const entries = [];
  let current = null;
  let last = null;
  let fenced = false;
  for (const line of text.split('\n')) {
    if (/^\s*(```|~~~)/.test(line)) fenced = !fenced;
    if (fenced) continue;
    const heading = line.match(/^###\s+(.+?)\s*$/);
    if (heading) {
      current = { topic: heading[1], values: {} };
      entries.push(current);
      last = null;
      continue;
    }
    if (!current) continue;
    const bullet = line.match(BULLET_RE);
    if (bullet) {
      last = bullet[1].toLowerCase();
      current.values[last] = bullet[2].trim();
    } else if (last && /^\s+\S/.test(line)) {
      current.values[last] = `${current.values[last]} ${line.trim()}`.trim();
    }
  }
  return entries;
}

function exportEntry({ topic, values }, findings) {
  for (const [key, label] of Object.entries(FIELDS)) {
    if (!values[key]) findings.push({ code: 'decision-field-missing', message: `decision "${topic}": missing "${label}"` });
  }
  const answer = (values['review later'] || '').toLowerCase();
  if (values['review later'] && answer !== 'yes' && answer !== 'no') {
    findings.push({ code: 'decision-review-later-invalid', message: `decision "${topic}": "Review later" must be yes or no, got "${values['review later']}"` });
  }
  const alternatives = (values.alternatives || '').split('; ').map((a) => a.trim()).filter((a) => a && a.toLowerCase() !== 'none');
  return { topic, chosen: values.chosen || '', alternatives, why: values.why || '', reviewLater: answer === 'yes' ? true : answer === 'no' ? false : null };
}

/**
 * Read the `## Decisions` section of plan.md.
 * @returns {{ decisions: object[], findings: { code: string, message: string }[] }}
 *   findings are warnings by default; the validator makes them problems under `--require decisions`
 */
function readDecisions(planContent) {
  const section = sectionOf(bodyOf(planContent), 'Decisions');
  const text = section === null ? '' : stripComments(section).trim();
  if (/^(?:[-*]\s*)?none\.?$/i.test(text)) return { decisions: [], findings: [] };
  if (text === '') {
    const why = section === null ? 'plan.md has no "## Decisions" section' : 'the "## Decisions" section is empty';
    return { decisions: [], findings: [{ code: 'decisions-missing', message: why }] };
  }
  if (!/^###\s/m.test(text)) {
    return { decisions: [], findings: [{ code: 'decisions-legacy', message: 'the "## Decisions" section is not a list of "### topic" entries with Chosen, Alternatives, Why and Review later bullets' }] };
  }
  const findings = [];
  const decisions = parseEntries(text).map((entry) => exportEntry(entry, findings));
  return { decisions, findings };
}

module.exports = { bodyOf, sectionOf, readPrinciples, readDecisions };
