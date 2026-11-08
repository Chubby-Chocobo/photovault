'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { extractPlanMetadata, normalizeSize } = require('./plan-metadata-extractor.cjs');

function withPlan(frontmatter, fn) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kanban-meta-'));
  try {
    const file = path.join(dir, 'plan.md');
    fs.writeFileSync(file, `---\n${frontmatter}\n---\n\n# Plan\n`);
    return fn(extractPlanMetadata(file));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

test('shows human_effort as written and counts its upper bound', () => {
  withPlan('title: "A"\nsize: m\nhuman_effort: 3-6h', (meta) => {
    assert.strictEqual(meta.totalEffortFormatted, '3-6h');
    assert.strictEqual(meta.totalEffortHours, 6);
    assert.strictEqual(meta.size, 'M');
    assert.strictEqual(meta.effortKind, 'human');
  });
});

test('counts day and mixed-unit ranges at their upper bound', () => {
  withPlan('human_effort: "1–2d"', (meta) => assert.strictEqual(meta.totalEffortHours, 16));
  withPlan('human_effort: 30m-1h', (meta) => assert.strictEqual(meta.totalEffortHours, 1));
});

test('reads a bare human_effort number as hours', () => {
  withPlan('human_effort: 4', (meta) => {
    assert.strictEqual(meta.totalEffortFormatted, '4h');
    assert.strictEqual(meta.totalEffortHours, 4);
  });
});

test('human_effort wins over the legacy effort field', () => {
  withPlan('human_effort: 1-2h\neffort: 14h', (meta) => {
    assert.strictEqual(meta.totalEffortFormatted, '1-2h');
    assert.strictEqual(meta.totalEffortHours, 2);
  });
});

test('plans with only the legacy effort field still show it', () => {
  withPlan('effort: 14h', (meta) => {
    assert.strictEqual(meta.totalEffortFormatted, '14.0h');
    assert.strictEqual(meta.effortKind, 'legacy');
    assert.strictEqual(meta.size, null);
  });
});

test('unparseable human_effort falls back to the legacy effort field', () => {
  withPlan('human_effort: unknown\neffort: 4h', (meta) => {
    assert.strictEqual(meta.totalEffortFormatted, '4.0h');
  });
});

test('normalizeSize accepts S, M and L only', () => {
  assert.strictEqual(normalizeSize(' l '), 'L');
  assert.strictEqual(normalizeSize('XL'), null);
  assert.strictEqual(normalizeSize(undefined), null);
});
