'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const { parseTranscript } = require('../transcript-parser.cjs');

const dirs = [];
test.after(() => dirs.forEach((dir) => fs.rmSync(dir, { recursive: true, force: true })));

function transcript(entries) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'transcript-bg-'));
  dirs.push(dir);
  const file = path.join(dir, 'session.jsonl');
  fs.writeFileSync(file, entries.map((e) => JSON.stringify(e)).join('\n'));
  return file;
}

const spawn = (id, at, description) => ({
  timestamp: at, type: 'assistant',
  message: { content: [{ type: 'tool_use', id, name: 'Agent', input: { subagent_type: 'code-reviewer', description } }] },
});
const launched = (id, at) => ({
  timestamp: at, type: 'user', toolUseResult: { isAsync: true, status: 'async_launched', agentId: 'a1' },
  message: { content: [{ type: 'tool_result', tool_use_id: id, content: [{ type: 'text', text: 'Async agent launched successfully.' }] }] },
});
const notification = (id, at, status = 'completed') => ({
  timestamp: at, type: 'user',
  message: { content: `<task-notification>\n<task-id>a1</task-id>\n<tool-use-id>${id}</tool-use-id>\n<status>${status}</status>\n<summary>done</summary>\n</task-notification>` },
});

test('a background agent stays running after its launch result', async () => {
  const result = await parseTranscript(transcript([
    spawn('toolu_bg', '2026-10-13T10:00:00Z', 'Review'),
    launched('toolu_bg', '2026-10-13T10:00:01Z'),
  ]));
  assert.strictEqual(result.agents[0].status, 'running');
  assert.strictEqual(result.agents[0].endTime, null);
});

test('its task-notification completes it with the notification time as the end', async () => {
  const result = await parseTranscript(transcript([
    spawn('toolu_bg', '2026-10-13T10:00:00Z', 'Review'),
    launched('toolu_bg', '2026-10-13T10:00:01Z'),
    notification('toolu_bg', '2026-10-13T10:08:00Z'),
  ]));
  const [agent] = result.agents;
  assert.strictEqual(agent.status, 'completed');
  assert.strictEqual(agent.endTime.toISOString(), '2026-10-13T10:08:00.000Z');
});

test('a failed or killed background agent also stops showing as running', async () => {
  for (const status of ['failed', 'killed']) {
    const result = await parseTranscript(transcript([
      spawn('toolu_bg', '2026-10-13T10:00:00Z', 'Review'),
      launched('toolu_bg', '2026-10-13T10:00:01Z'),
      notification('toolu_bg', '2026-10-13T10:02:00Z', status),
    ]));
    assert.strictEqual(result.agents[0].status, 'completed', status);
  }
});

test('a foreground agent still completes on its tool result; unknown notification ids are ignored', async () => {
  const result = await parseTranscript(transcript([
    spawn('toolu_fg', '2026-10-13T10:00:00Z', 'Inline'),
    { timestamp: '2026-10-13T10:03:00Z', type: 'user', message: { content: [{ type: 'tool_result', tool_use_id: 'toolu_fg', content: 'report' }] } },
    notification('toolu_other', '2026-10-13T10:04:00Z'),
  ]));
  assert.strictEqual(result.agents.length, 1);
  assert.strictEqual(result.agents[0].status, 'completed');
  assert.strictEqual(result.agents[0].endTime.toISOString(), '2026-10-13T10:03:00.000Z');
});

test('a notification is found in a tool result, a queued attachment or a queue record; the earliest wins', async () => {
  const body = (id) => `<task-notification>\n<tool-use-id>${id}</tool-use-id>\n<status>completed</status>\n</task-notification>`;
  const cases = {
    'tool result': { timestamp: '2026-10-13T10:05:00Z', type: 'user', message: { content: [{ type: 'tool_result', tool_use_id: 'toolu_other', content: `CI green\n${body('toolu_bg')}` }] } },
    attachment: { timestamp: '2026-10-13T10:05:00Z', type: 'attachment', attachment: { type: 'queued_command', prompt: body('toolu_bg') } },
    'queue record': { timestamp: '2026-10-13T10:05:00Z', type: 'queue-operation', operation: 'enqueue', content: body('toolu_bg') },
  };
  for (const [where, entry] of Object.entries(cases)) {
    const result = await parseTranscript(transcript([
      spawn('toolu_bg', '2026-10-13T10:00:00Z', 'Review'),
      launched('toolu_bg', '2026-10-13T10:00:01Z'),
      entry,
      notification('toolu_bg', '2026-10-13T11:00:00Z'), // redelivered later
    ]));
    const agent = result.agents.find((a) => a.id === 'toolu_bg');
    assert.strictEqual(agent.status, 'completed', where);
    assert.strictEqual(agent.endTime.toISOString(), '2026-10-13T10:05:00.000Z', where);
  }
});

test('formatElapsed never shows 60s and switches to hours after 60 minutes', () => {
  const { formatElapsed } = require('../statusline-string-utils.cjs');
  const at = (ms) => new Date(Date.parse('2026-10-13T10:00:00Z') + ms);
  const start = at(0);
  assert.strictEqual(formatElapsed(start, at(500)), '<1s');
  assert.strictEqual(formatElapsed(start, at(59_600)), '59s');
  assert.strictEqual(formatElapsed(start, at(119_600)), '1m 59s');
  assert.strictEqual(formatElapsed(start, at(120_000)), '2m 0s');
  assert.strictEqual(formatElapsed(start, at(18_942_000)), '5h 15m');
});

test('the statusline snapshot flips a background agent to completed once its notification lands', async () => {
  const { refreshStatuslineSnapshot } = require('../session-state-manager.cjs');
  const { readSessionState } = require('../adf-config-utils.cjs');
  const sessionId = `agent-activity-${process.pid}-${Date.now()}`;
  const iso = (offsetMs) => new Date(Date.now() + offsetMs).toISOString();
  const file = transcript([spawn('toolu_bg', iso(-60_000), 'Review'), launched('toolu_bg', iso(-59_000))]);
  try {
    await refreshStatuslineSnapshot({ session_id: sessionId, transcript_path: file, hook_event_name: 'PostToolUse', tool_name: 'Agent' });
    assert.strictEqual(readSessionState(sessionId).statusline.agents[0].status, 'running');

    fs.appendFileSync(file, `\n${JSON.stringify(notification('toolu_bg', iso(1_000)))}`);
    await refreshStatuslineSnapshot({ session_id: sessionId, transcript_path: file, hook_event_name: 'Stop' });
    const [agent] = readSessionState(sessionId).statusline.agents;
    assert.strictEqual(agent.status, 'completed');
    assert.ok(Date.parse(agent.endTime) - Date.parse(agent.startTime) > 60_000, 'elapsed runs to the notification');
  } finally {
    fs.rmSync(path.join(os.tmpdir(), `adf-session-${sessionId}.json`), { force: true });
  }
});

test('agent lines: running uses the section icon, the last finished one a check, stale history is hidden', () => {
  const { renderAgentsLines } = require('../statusline-activity-renderers.cjs');
  const plain = (lines) => lines.map((line) => line.replace(/\x1b\[[0-9;]*m/g, ''));
  const now = Date.parse('2026-10-13T10:30:00Z');
  const agent = (status, start, end, description) => ({ type: 'code-reviewer', status, startTime: start, endTime: end, description });
  const config = { icon: '🔄' };

  const running = plain(renderAgentsLines({ agents: [agent('running', '2026-10-13T10:20:00Z', null, 'Review')] }, 4, config, false, now));
  assert.match(running[1], /🔄 Review \(10m 0s\)/);

  const finished = [agent('completed', '2026-10-13T10:20:00Z', '2026-10-13T10:27:55Z', 'Re-review')];
  const recent = plain(renderAgentsLines({ agents: finished }, 4, config, false, now));
  assert.match(recent[1], /✓ Re-review \(7m 55s\)/);
  assert.ok(!recent[1].includes('🔄'), 'a finished agent never shows the running icon');

  const later = now + 6 * 60 * 1000;
  assert.deepStrictEqual(renderAgentsLines({ agents: finished }, 4, config, false, later), [], 'hidden 5 minutes after the last one finished');
  assert.deepStrictEqual(plain(renderAgentsLines({ agents: finished }, 4, config, true, later)), ['○'], 'a configured row keeps its idle marker');
  const stillRunning = [...finished, agent('running', '2026-10-13T10:35:00Z', null, 'Next')];
  assert.match(plain(renderAgentsLines({ agents: stillRunning }, 4, config, false, later))[1], /🔄 Next/);
});
