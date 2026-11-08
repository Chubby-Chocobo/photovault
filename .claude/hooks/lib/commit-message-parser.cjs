'use strict';

/**
 * Extracts the message of a `git commit` shell command and checks it against
 * conventional-commit format and AI attribution lines. Handles `-m`/`--message`
 * (repeated, quoted, `$(cat <<'EOF' … EOF)` heredocs) and `-F`/`--file`. Returns
 * null when the message comes from an editor or cannot be read.
 */

const fs = require('node:fs');
const path = require('node:path');

const DEFAULT_TYPES = ['feat', 'fix', 'docs', 'style', 'refactor', 'perf', 'test', 'build', 'ci', 'chore', 'revert'];

const AI_ATTRIBUTION = [
  /co-authored-by:.*\b(?:claude|anthropic|copilot|chatgpt|openai|gemini)\b/i,
  /generated (?:with|by)\b.*\b(?:claude|chatgpt|copilot|gemini|ai)\b/i,
  /\u{1F916}/u,
];

/** Split a shell command into words, honouring quotes. `$(...)` inside double quotes stays one word. */
function shellWords(command) {
  const words = [];
  let current = '';
  let quote = null;
  let started = false;
  for (let i = 0; i < command.length; i++) {
    const ch = command[i];
    if (quote === "'") {
      if (ch === "'") quote = null; else current += ch;
    } else if (quote === '"') {
      if (ch === '\\' && i + 1 < command.length && '"\\$`'.includes(command[i + 1])) current += command[++i];
      else if (ch === '"') quote = null;
      else current += ch;
    } else if (ch === "'" || ch === '"') {
      quote = ch; started = true;
    } else if (ch === '\\' && i + 1 < command.length) {
      current += command[++i]; started = true;
    } else if (/\s/.test(ch)) {
      if (started) { words.push(current); current = ''; started = false; }
    } else if (';&|'.includes(ch)) {
      if (started) { words.push(current); current = ''; started = false; }
      words.push(ch);
    } else {
      current += ch; started = true;
    }
  }
  if (started) words.push(current);
  return words;
}

/** Body of `$(cat <<'EOF' … EOF)` (any delimiter), or the value itself. */
function unwrapHeredoc(value) {
  const m = /^\$\(\s*cat\s+<<-?\s*['"]?(\w+)['"]?\s*\n([\s\S]*?)\n\s*\1\s*\)\s*$/.exec(value);
  return m ? m[2] : value;
}

/**
 * Message of the first `git commit` in the command, or null when it cannot be determined.
 * @param {string} command
 * @param {string} cwd - for resolving `-F <file>`
 */
function extractCommitMessage(command, cwd) {
  // A heredoc body may contain bare quotes, so read it from the raw command before word splitting
  const heredoc = /(?:-m|--message)[=\s]+"\$\(\s*cat\s+<<-?\s*['"]?(\w+)['"]?\s*\n([\s\S]*?)\n\s*\1\s*\)"/.exec(command);
  if (heredoc) return heredoc[2];
  const words = shellWords(command);
  const gitSubcommand = (from) => {
    for (let i = from; i < words.length; i++) {
      if (';&|'.includes(words[i])) return null;
      if (words[i] === '-C' || words[i] === '-c') i++;
      else if (!words[i].startsWith('-')) return words[i];
    }
    return null;
  };
  const start = words.findIndex((w, i) => w === 'git' && gitSubcommand(i + 1) === 'commit');
  if (start === -1) return null;
  const parts = [];
  for (let i = words.indexOf('commit', start) + 1; i < words.length && !';&|'.includes(words[i]); i++) {
    const word = words[i];
    let value = null;
    if (word === '-m' || word === '--message') value = words[++i];
    else if (word.startsWith('--message=')) value = word.slice(10);
    else if (/^-[a-zA-Z]*m$/.test(word)) value = words[++i]; // -am "msg"
    else if (/^-m./.test(word)) value = word.slice(2);
    else if (word === '-F' || word === '--file' || word.startsWith('--file=')) {
      const file = word.startsWith('--file=') ? word.slice(7) : words[++i];
      if (!file || file === '-') return null;
      try { return fs.readFileSync(path.resolve(cwd, file), 'utf8'); } catch { return null; }
    }
    if (value !== null && value !== undefined) {
      const text = unwrapHeredoc(value);
      if (text.startsWith('$(')) return null; // command substitution we cannot evaluate: do not judge it
      parts.push(text);
    }
  }
  return parts.length ? parts.join('\n\n') : null;
}

/**
 * Problems with a commit message; empty when it passes.
 * @param {string} message
 * @param {{ types?: string[], subjectMax?: number }} options
 */
function checkCommitMessage(message, { types = DEFAULT_TYPES, subjectMax = 0 } = {}) {
  const problems = [];
  const subject = message.split('\n').find((line) => line.trim()) || '';
  const format = new RegExp(`^(?:${types.join('|')})(?:\\([^)]+\\))?!?: \\S`);
  if (!format.test(subject) && !/^(?:Merge |Revert ")/.test(subject)) {
    problems.push(`subject "${subject.slice(0, 72)}" is not a conventional commit (<type>(<scope>): <summary>, type one of ${types.join(', ')})`);
  }
  const conventional = format.test(subject);
  if (conventional && subjectMax > 0 && subject.length > subjectMax) problems.push(`subject is ${subject.length} characters; keep it within ${subjectMax}`);
  if (conventional && /\.$/.test(subject)) problems.push('subject ends with a period; drop it');
  if (AI_ATTRIBUTION.some((re) => re.test(message))) {
    problems.push('message contains an AI attribution line (Co-Authored-By / "Generated with" an AI tool)');
  }
  return problems;
}

/** The conventional type of a message's subject, or null. */
function commitType(message) {
  const subject = (message || '').split('\n').find((line) => line.trim()) || '';
  return (/^(\w+)(?:\([^)]*\))?!?:/.exec(subject) || [])[1] || null;
}

module.exports = { extractCommitMessage, checkCommitMessage, commitType, shellWords, DEFAULT_TYPES };
