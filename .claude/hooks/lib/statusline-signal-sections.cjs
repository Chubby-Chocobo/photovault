'use strict';

/**
 * Statusline sections for per-session signals Claude Code passes on stdin or ADF hooks record:
 * prompt cache lifetime, the branch's pull request, and code edited since the last check.
 * Each renderer: (ctx, sectionConfig, theme) => string | null (null hides the section).
 * Kept apart from statusline-section-registry.cjs, which stays under the file-size limit.
 */

const { green, yellow, red, dim, cyan, isColorEnabled, resolveColor } = require('./colors.cjs');

const CACHE_WARNING_MS = 5 * 60 * 1000;
const CACHE_MAX_MS = 24 * 60 * 60 * 1000; // longer than any cache TTL: bad data, not a real expiry

/** OSC 8 hyperlink; plain text when colors are off or the URL is not http(s). */
function hyperlink(url, text) {
  // No C0/C1 control characters (ESC, BEL, 8-bit ST), so the URL cannot end the sequence early
  if (!isColorEnabled() || typeof url !== 'string' || !/^https?:\/\/[^\s\x00-\x1f\x7f-\x9f]+$/.test(url)) return text;
  return `\x1b]8;;${url}\x1b\\${text}\x1b]8;;\x1b\\`;
}

/** Milliseconds since the epoch from epoch seconds, epoch milliseconds or an ISO string; NaN otherwise. */
function toEpochMs(value) {
  if (typeof value === 'number') return value < 1e12 ? value * 1000 : value;
  if (typeof value === 'string') return Date.parse(value);
  return NaN;
}

function formatMinutes(ms) {
  const mins = Math.max(1, Math.ceil(ms / 60000));
  return mins < 60 ? `${mins}m` : `${Math.floor(mins / 60)}h ${mins % 60}m`;
}

/** "🧊 42m": how long the warm prompt cache lasts; yellow in its last five minutes. */
function renderCacheSection(ctx, sectionConfig) {
  const cache = ctx.promptCache;
  if (!cache || cache.warm !== true) return null;
  const left = toEpochMs(cache.expires_at) - (ctx.now || Date.now());
  if (!Number.isFinite(left) || left <= 0 || left > CACHE_MAX_MS) return null;
  const tone = sectionConfig.color ? resolveColor(sectionConfig.color) : left <= CACHE_WARNING_MS ? yellow : cyan;
  return `${sectionConfig.icon || '🧊'} ${tone(formatMinutes(left))}`;
}

const REVIEW_STATES = {
  approved: (text) => green(`✓ ${text}`),
  changes_requested: (text) => red(`✎ ${text}`),
  pending: (text) => yellow(`… ${text}`),
  draft: (text) => dim(`◌ ${text}`),
};
const REVIEW_LABELS = { approved: 'approved', changes_requested: 'changes', pending: 'review', draft: 'draft' };

/** "🔗 #18 ✓ approved", linked to the PR (GitLab merge requests use "!18"). */
function renderPrSection(ctx, sectionConfig) {
  const pr = ctx.pr;
  if (!pr || !Number.isInteger(pr.number)) return null;
  const label = `${pr.kind === 'mr' ? '!' : '#'}${pr.number}`;
  const tint = resolveColor(sectionConfig.color || 'magenta');
  // Own keys only: "constructor" or "__proto__" must not reach Object.prototype
  const state = Object.hasOwn(REVIEW_STATES, pr.review_state) ? REVIEW_STATES[pr.review_state] : null;
  const review = state ? ` ${state(REVIEW_LABELS[pr.review_state])}` : '';
  return `${sectionConfig.icon || '🔗'} ${hyperlink(pr.url, tint(label))}${review}`;
}

/** "⚠ 3 unverified": code files edited since the last test, lint, typecheck or build (verify-before-stop). */
function renderVerifySection(ctx, sectionConfig) {
  if (!ctx.unverifiedCount) return null;
  const tone = sectionConfig.color ? resolveColor(sectionConfig.color) : yellow;
  return `${sectionConfig.icon || '⚠'} ${tone(`${ctx.unverifiedCount} unverified`)}`;
}

module.exports = {
  SIGNAL_SECTION_RENDERERS: { cache: renderCacheSection, pr: renderPrSection, verify: renderVerifySection },
  hyperlink,
  toEpochMs,
};
