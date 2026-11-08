'use strict';

const test = require('node:test');
const assert = require('node:assert');

const { notifyCommand, appleScriptString } = require('../desktop-notify.cjs');

test('macOS uses osascript with the message escaped as an AppleScript string', () => {
  const [exe, args] = notifyCommand('Claude Code · app', 'Run "rm" \\ now?', 'darwin');
  assert.strictEqual(exe, 'osascript');
  assert.deepStrictEqual(args, ['-e', 'display notification "Run \\"rm\\" \\\\ now?" with title "Claude Code · app"']);
});

test('appleScriptString cannot be broken out of with quotes', () => {
  const literal = appleScriptString('x" & (do shell script "id") & "');
  assert.strictEqual(literal, '"x\\" & (do shell script \\"id\\") & \\""');
});

test('Linux uses notify-send with plain arguments; other platforms are a no-op', () => {
  assert.deepStrictEqual(notifyCommand('T', 'M', 'linux'), ['notify-send', ['--app-name=Claude Code', '--', 'T', 'M']]);
  assert.strictEqual(notifyCommand('T', 'M', 'win32'), null);
});
