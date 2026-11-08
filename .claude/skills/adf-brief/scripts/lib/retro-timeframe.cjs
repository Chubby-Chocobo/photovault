'use strict';

// Resolves a retro timeframe ("7d", "2w", "1m", "sprint" or "YYYY-MM-DD:YYYY-MM-DD") to a
// [since, until) window in local time, plus the preceding window of equal length for --compare.
// Relative windows cover whole calendar days ending today: "7d" is today and the 6 days before.

const DAY_MS = 24 * 60 * 60 * 1000;

function startOfDay(date) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate());
}

function localDay(date) {
  const pad = (value) => String(value).padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

function addDays(date, count) {
  const result = new Date(date);
  result.setDate(result.getDate() + count);
  return result;
}

// Same day-of-month `count` months earlier, clamped to the end of a shorter month.
function monthsBefore(date, count) {
  const lastDay = new Date(date.getFullYear(), date.getMonth() - count + 1, 0).getDate();
  return new Date(date.getFullYear(), date.getMonth() - count, Math.min(date.getDate(), lastDay));
}

// Calendar dates the window touches; Math.round absorbs daylight-saving shifts.
function calendarDays(since, until) {
  return Math.round((startOfDay(new Date(until - 1)) - startOfDay(since)) / DAY_MS) + 1;
}

function parseLocalDate(value, name) {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  const date = match ? new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3])) : null;
  if (!date || date.getFullYear() !== Number(match[1]) || date.getMonth() !== Number(match[2]) - 1
    || date.getDate() !== Number(match[3])) {
    throw new Error(`${name} is not a valid date: ${value}`);
  }
  return date;
}

function windowOf(label, since, until) {
  if (!(since < until)) throw new Error(`timeframe ${label} is empty: the start must be before the end`);
  return { label, since, until, days: calendarDays(since, until) };
}

// latestTagDate: commit date of the most recent tag, used as the start of "sprint".
function resolveTimeframe(spec = '7d', { now = new Date(), latestTagDate = null } = {}) {
  const value = String(spec || '7d').trim();
  const relative = /^(\d+)([dwm])$/.exec(value);
  if (relative) {
    const count = Number(relative[1]);
    if (count < 1) throw new Error(`timeframe must be at least 1: ${value}`);
    const today = startOfDay(now);
    const since = relative[2] === 'm'
      ? addDays(monthsBefore(today, count), 1)
      : addDays(today, 1 - count * (relative[2] === 'w' ? 7 : 1));
    return windowOf(value, since, new Date(now));
  }
  const range = /^(\d{4}-\d{2}-\d{2}):(\d{4}-\d{2}-\d{2})$/.exec(value);
  if (range) {
    const since = parseLocalDate(range[1], 'start date');
    const until = addDays(parseLocalDate(range[2], 'end date'), 1); // the end date is inclusive
    return windowOf(value, since, until);
  }
  if (value === 'sprint') {
    if (!latestTagDate) {
      throw new Error('sprint starts at the latest git tag, and this repo has none; pass a date range such as 2026-10-01:2026-10-14');
    }
    // Start one second after the tagged commit: it closed the previous sprint.
    return windowOf(value, new Date(new Date(latestTagDate).getTime() + 1000), new Date(now));
  }
  throw new Error(`unknown timeframe: ${value} (use 7d, 2w, 1m, sprint or YYYY-MM-DD:YYYY-MM-DD)`);
}

// The same number of calendar days just before the window. git treats --since and --until as
// inclusive to the second, so the previous window ends one second before this one starts.
function previousWindow(window) {
  return {
    label: `previous ${window.label}`,
    since: addDays(window.since, -window.days),
    until: new Date(window.since.getTime() - 1000),
    days: window.days,
  };
}

module.exports = { localDay, resolveTimeframe, previousWindow };
