/**
 * member-attach.cjs - `workspace.cjs attach <workspace-url> [--dir <path>] [--dry-run] [--yes]`
 *
 * Run inside a standalone member repo: clones the workspace next to it and lets Claude read it by
 * adding its absolute path to `permissions.additionalDirectories` in the member's
 * `.claude/settings.local.json`. The member's committed marker is the trust anchor: the URL must
 * be on the marker's host and under one of its `org` owners, and so must the member's own origin.
 * Without `--yes` (or with `--dry-run`) nothing is cloned or written; the plan and the exact
 * settings diff are printed.
 *
 * @module member-attach
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { parseRemoteUrl, sameRepo } = require('../../../../hooks/lib/git-remote-url.cjs');
const { hasCredentials } = require('../../../../hooks/lib/workspace-manifest-validate.cjs');
const { loadManifest } = require('../../../../hooks/lib/workspace-manifest.cjs');
const { loadSystemMap } = require('../../../../hooks/lib/system-map.cjs');
const { realpathLoose, relativePosix, insideRoot } = require('../../../../hooks/lib/path-containment.cjs');
const { readMarkerFile, docsRelOf } = require('../../../../hooks/lib/member-link.cjs');
const { mergeSettingsLocal, SETTINGS_REL } = require('./settings-local-writer.cjs');
const { git, originOf, ignoreStatus } = require('./workspace-git.cjs');
const { fail, usageError } = require('./workspace-util.cjs');

const CLONEABLE_RE = /^(?:https?:\/\/|ssh:\/\/|[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:)/i;

function urlError(url) {
  if (typeof url !== 'string' || !url) return 'attach needs the workspace URL: attach <url>';
  if (/[?#]/.test(url)) return 'the URL must not contain a query or a fragment';
  if (url.startsWith('-')) return 'the URL must not start with "-"';
  if (hasCredentials(url)) return 'the URL must not contain credentials; use an ssh URL or a credential helper';
  if (!CLONEABLE_RE.test(url) || !parseRemoteUrl(url)) return 'the URL must be an https:// or ssh:// URL, or user@host:owner/repo';
  return null;
}

/** Messages when the URL or the member's origin is not covered by the marker; empty when both are. */
function trustErrors(marker, parsedUrl, origin) {
  const owners = new Set(marker.org.map((o) => o.toLowerCase()));
  const parsedOrigin = origin ? parseRemoteUrl(origin) : null;
  const ok = parsedUrl.host === marker.host && owners.has(parsedUrl.owner.toLowerCase()) && Boolean(parsedOrigin) && owners.has(parsedOrigin.owner.toLowerCase());
  if (ok) return [];
  return [
    'refused: the URL and this repo must both belong to the owners the marker trusts',
    `  URL host: ${parsedUrl.host} (marker host: ${marker.host})`,
    `  URL owner: ${parsedUrl.owner}`,
    `  member origin owner: ${parsedOrigin ? parsedOrigin.owner : '(no usable origin remote)'}`,
    `  marker org: ${marker.org.join(', ')}`,
  ];
}

/** Where the workspace goes, and what is already there: `{ dir, state: 'absent'|'clone'|'empty' }` or `{ error }`. */
function targetOf(root, parsedUrl, url, optDir) {
  const dir = path.resolve(optDir !== undefined ? path.resolve(root, optDir) : path.join(path.dirname(root), parsedUrl.repo));
  const rel = relativePosix(realpathLoose(root), path.join(realpathLoose(path.dirname(dir)), path.basename(dir)));
  if (rel === '' || insideRoot(rel)) return { error: 'the workspace folder must be outside this repo' };
  let stat;
  try { stat = fs.lstatSync(dir); } catch { return { dir, state: 'absent' }; }
  if (stat.isSymbolicLink() || !stat.isDirectory()) return { error: 'the target path exists and is not a plain folder' };
  if (!fs.existsSync(path.join(dir, '.git'))) return fs.readdirSync(dir).length === 0 ? { dir, state: 'empty' } : { error: 'the target folder exists, is not empty and is not a git clone' };
  const existing = originOf(dir);
  return existing && sameRepo(existing, url) ? { dir, state: 'clone' } : { error: 'the target folder is a clone of a different repo' };
}

/** A message when the clone at `dir` is not a workspace that lists this repo, else null. */
function membershipError(dir, marker, origin) {
  const { manifest, errors } = loadManifest(dir);
  if (errors.length > 0) return 'the workspace manifest is invalid; run workspace.cjs check in it';
  if (!manifest) return 'the clone has no adf-workspace.json, so it is not a workspace';
  if (origin && manifest.members.some((m) => m.repo && sameRepo(origin, m.repo))) return null;
  const { map } = loadSystemMap(dir, docsRelOf(dir), { manifest });
  return map && (map.components || []).some((c) => c.name === marker.component) ? null : 'the workspace does not list this repo (no member with this origin, no component named in the marker)';
}

/** The directories already granted, or null when the settings value is not an array of strings. */
function grantedDirs(root) {
  let data;
  try { data = JSON.parse(fs.readFileSync(path.join(root, ...SETTINGS_REL.split('/')), 'utf8')); } catch { return []; }
  const dirs = data && data.permissions && data.permissions.additionalDirectories;
  if (dirs === undefined) return [];
  return Array.isArray(dirs) && dirs.every((d) => typeof d === 'string') ? dirs : null;
}

const NEXT_STEPS = (dir) => [
  'Next steps:',
  '- additionalDirectories lets Claude read and edit files in the workspace. It does not load the workspace CLAUDE.md or skills.',
  `- To load the workspace CLAUDE.md too, start Claude with --add-dir ${dir} and CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1. Do that only for a workspace you trust.`,
];

/** @param {{ root: string, docsRel: string, opts: object }} ctx root is the member repo */
function run({ root, opts }) {
  const url = opts._[1];
  if (opts._.length > 2) return usageError('attach takes one workspace URL');
  const bad = urlError(url);
  if (bad) return typeof url === 'string' && url ? fail([`refused: ${bad}`]) : usageError(bad);
  const found = readMarkerFile(root);
  if (found.kind !== 'ours' || !found.marker) return fail([found.kind === 'absent' ? 'this repo has no .adf-workspace.json; run sync in the workspace and commit the marker here' : '.adf-workspace.json is not a valid ADF marker']);
  const { marker } = found;
  const parsedUrl = parseRemoteUrl(url);
  const origin = originOf(root);
  const refused = trustErrors(marker, parsedUrl, origin);
  if (refused.length > 0) return fail(refused);
  const target = targetOf(root, parsedUrl, url, opts.dir);
  if (target.error) return fail([target.error]);

  const apply = Boolean(opts.yes) && !opts['dry-run'];
  const lines = [];
  let clone = target.state === 'clone' ? 'reused' : 'would-clone';
  if (apply && target.state !== 'clone') {
    const r = git(['clone', '--quiet', '--', url, target.dir]);
    if (r.status !== 0) return fail([`git clone failed: ${r.stderr || 'unknown error'}`]);
    clone = 'cloned';
  }
  if (clone !== 'would-clone') {
    const message = membershipError(target.dir, marker, origin);
    if (message) return fail([message, ...(clone === 'cloned' ? ['the clone was left in place; remove it if it is not the workspace you meant'] : [])]);
  }
  lines.push(`${clone === 'would-clone' ? 'Would clone' : clone === 'cloned' ? 'Cloned' : 'Found'} the workspace at ${target.dir}`);
  if (clone === 'would-clone') lines.push('Whether it lists this repo is checked after the clone.');

  const granted = grantedDirs(root);
  if (granted === null) return fail([`${SETTINGS_REL}: permissions.additionalDirectories must be an array of strings; fix it first`]);
  const has = granted.some((d) => path.resolve(root, d) === target.dir);
  const patch = { permissions: { additionalDirectories: has ? granted : [...granted, target.dir] } };
  let settings;
  try { settings = mergeSettingsLocal(root, patch, { dryRun: !apply }); } catch (err) { return fail([err && err.message ? err.message : 'settings cannot be updated']); }
  lines.push(settings.changed ? `${SETTINGS_REL} ${settings.written ? 'now has' : 'would get'}:` : `${SETTINGS_REL} already grants the workspace.`, ...settings.diff.map((d) => `  ${d}`));
  const warnings = ignoreStatus(root, SETTINGS_REL) === 'not-ignored' ? [`${SETTINGS_REL} is not git-ignored in this repo; ignore it so the absolute path is not committed`] : [];
  lines.push(...warnings.map((w) => `Warning: ${w}`), '', ...NEXT_STEPS(target.dir));
  if (!apply) lines.push('', 'Nothing cloned or written. Re-run with --yes after confirming.');
  return {
    code: 0,
    result: { ok: true, applied: apply, workspace: { url, dir: target.dir, clone }, settings: { file: SETTINGS_REL, changed: settings.changed, written: settings.written, diff: settings.diff }, warnings },
    text: lines.join('\n'),
  };
}

module.exports = { run };
