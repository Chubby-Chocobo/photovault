'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { parsePlanTable, normalizeStatus } = require('./plan-parser.cjs');

function withPlan(content, fn) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kanban-parser-'));
  try {
    const file = path.join(dir, 'plan.md');
    fs.writeFileSync(file, content);
    return fn(file, dir);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

test('keeps alphanumeric phase 2a between phases 1 and 3', () => {
  const md = [
    '| Phase | Name | Status |',
    '|---|---|---|',
    '| 1 | [Setup](phase-01-setup.md) | Completed |',
    '| 2a | [Split](phase-02a-split.md) | In Progress |',
    '| 3 | [Ship](phase-03-ship.md) | Pending |',
    '',
  ].join('\n');
  withPlan(md, (file, dir) => {
    const phases = parsePlanTable(file);
    assert.deepStrictEqual(phases.map((p) => p.phaseId), ['1', '2a', '3']);
    const p2a = phases.find((p) => p.phaseId === '2a');
    assert.strictEqual(p2a.status, 'in-progress');
    assert.strictEqual(p2a.file, path.resolve(dir, 'phase-02a-split.md'));
  });
});

test('exports normalizeStatus', () => {
  assert.strictEqual(normalizeStatus('Done'), 'completed');
  assert.strictEqual(normalizeStatus('WIP'), 'in-progress');
  assert.strictEqual(normalizeStatus(''), 'pending');
});
