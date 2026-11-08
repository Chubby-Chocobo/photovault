#!/usr/bin/env node
/**
 * PostToolUse hook — warns when plan.md uses filenames as link text instead of human-readable names.
 * Reads stdin JSON from Claude, checks file_path and content for bad link text patterns.
 * Always fail-open: returns { continue: true } on any error.
 */

'use strict';

const { createHookTimer, logHookCrash } = require('./lib/hook-logger.cjs');

let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => { input += chunk; });
process.stdin.on('end', () => {
  const timer = createHookTimer('plan-format-kanban', { event: 'PostToolUse' });
  try {
    const data = JSON.parse(input);
    const toolName = data.tool_name || '';
    const filePath = data.tool_input?.file_path || data.tool_input?.path || '';

    // Only inspect plan.md files
    if (filePath.replace(/\\/g, '/').split('/').pop() !== 'plan.md') {
      timer.end({ tool: toolName, status: 'skip', exit: 0, note: 'non-plan-file' });
      process.stdout.write(JSON.stringify({ continue: true }));
      return;
    }

    // Read the file and check for filename-as-link-text pattern
    const fs = require('fs');
    if (!fs.existsSync(filePath)) {
      timer.end({ tool: toolName, status: 'skip', exit: 0, note: 'file-missing' });
      process.stdout.write(JSON.stringify({ continue: true }));
      return;
    }

    const content = fs.readFileSync(filePath, 'utf8');
    // Matches: [phase-01a-some-name.md](./...) — filename used as link text
    const badPattern = /\|\s*\d+[a-z]?\s*\|\s*\[phase-\d+[a-z]?-[^\]]*\.md\]\(/gi;
    const matches = content.match(badPattern);

    const warnings = [];

    if (matches && matches.length > 0) {
      warnings.push(
        '[!] plan.md: Link text should be human-readable, not filenames.',
        `    Found ${matches.length} instance(s) using filename as link text.`,
        '    Bad:  [phase-01-setup.md](./phase-01-setup.md)',
        '    Good: [Setup Environment](./phase-01-setup.md)',
        '    Update link text to descriptive phase names for better readability.'
      );
    }

    // A phases-table row written with a status the kanban view does not know. The canonical values
    // (Pending | In Progress | Completed) are what subagents are told to write, so they pass silently.
    if (toolName === 'Edit' || toolName === 'Write') {
      const written = data.tool_input?.new_string || data.tool_input?.content || '';
      // Only table rows (lines starting with | and a phase ID) count; frontmatter and prose do not
      const nonCanonical = String(written).split('\n').some(line => {
        if (!/^\|\s*\d+[a-z]?\s*\|/i.test(line)) return false;
        const alias = /\|\s*(Pending|In Progress|In-Progress|Completed|Complete|Done|Active|WIP)\s*\|?\s*$/i.exec(line);
        return Boolean(alias) && !/^(Pending|In Progress|Completed)$/.test(alias[1]);
      });
      if (nonCanonical) {
        warnings.push(
          '\n[Plan Status Warning] Non-canonical status in the phases table.',
          'Canonical format: | Phase | Name | Status | (3-column table)',
          'Use canonical status values: Pending | In Progress | Completed.',
          'Edit only the Status cell; do not reformat other columns.',
          'Non-canonical edits may break the kanban view.'
        );
      }
    }

    if (warnings.length > 0) {
      timer.end({
        tool: toolName,
        status: 'warn',
        exit: 0,
        target: 'plan.md',
        note: `${warnings.length}-warning(s)`
      });
      process.stdout.write(JSON.stringify({
        continue: true,
        hookSpecificOutput: { hookEventName: 'PostToolUse', additionalContext: warnings.join('\n') }
      }));
      return;
    }

    timer.end({ tool: toolName, status: 'ok', exit: 0, target: 'plan.md' });
    process.stdout.write(JSON.stringify({ continue: true }));
  } catch (_err) {
    // Fail-open: never block on hook errors
    logHookCrash('plan-format-kanban', _err, { event: 'PostToolUse' });
    process.stdout.write(JSON.stringify({ continue: true }));
  }
});
