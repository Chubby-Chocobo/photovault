#!/usr/bin/env node
/**
 * Notification hook: shows a desktop notification when Claude Code waits for the user
 * (permission prompt, idle prompt, input request).
 *
 * macOS: osascript; Linux: notify-send (skipped when missing); other platforms: no-op.
 * Types shown: `notify.types` in adf-config.json (default below). Side effects only, never blocks.
 * Toggle: hooks.desktop-notify=false.
 */

const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { isHookEnabled, readProjectSection, getProjectRoot } = require('./lib/adf-config-utils.cjs');

const DEFAULT_TYPES = ['permission_prompt', 'idle_prompt', 'elicitation_dialog', 'agent_needs_input'];
const MAX_MESSAGE = 200;

/** AppleScript string literal: escape backslashes and double quotes. */
function appleScriptString(value) {
  return `"${String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
}

/** Executable and args for the platform, or null when unsupported. Arguments are never shell-parsed. */
function notifyCommand(title, message, platform = process.platform) {
  if (platform === 'darwin') {
    return ['osascript', ['-e', `display notification ${appleScriptString(message)} with title ${appleScriptString(title)}`]];
  }
  if (platform === 'linux') return ['notify-send', ['--app-name=Claude Code', '--', title, message]];
  return null;
}

function main() {
  if (!isHookEnabled('desktop-notify')) return;
  const stdin = fs.readFileSync(0, 'utf8').trim();
  if (!stdin) return;
  const payload = JSON.parse(stdin);
  const cwd = payload.cwd || process.cwd();
  const types = readProjectSection(cwd, 'notify').types;
  const allowed = Array.isArray(types) ? types : DEFAULT_TYPES;
  if (payload.notification_type && !allowed.includes(payload.notification_type)) return;

  const project = path.basename(getProjectRoot(cwd));
  const title = `Claude Code · ${project}`;
  const message = String(payload.message || 'Claude is waiting for you').replace(/\s+/g, ' ').slice(0, MAX_MESSAGE);
  const command = notifyCommand(title, message);
  if (!command) return;
  const child = spawn(command[0], command[1], { detached: true, stdio: 'ignore' });
  child.on('error', () => {}); // notify-send not installed
  child.unref();
}

if (require.main === module) {
  try {
    main();
  } catch {
    // Notifications are best-effort
  }
}

module.exports = { notifyCommand, appleScriptString };
