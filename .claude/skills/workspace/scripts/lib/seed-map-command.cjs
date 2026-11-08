/**
 * seed-map-command.cjs - `workspace seed-map [--merge]`: write the system map from what is on disk.
 *
 * Without --merge an existing map is never replaced. With --merge only missing components and
 * contracts are appended; hand edits stay as they are. `--archetype <id>` merges that archetype's
 * role aliases into `roles` and stores its id (with --merge on an existing map too).
 *
 * @module seed-map-command
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { loadManifest } = require('../../../../hooks/lib/workspace-manifest.cjs');
const { mapPath, validateSystemMap } = require('../../../../hooks/lib/system-map.cjs');
const { parseJson } = require('../../../../hooks/lib/workspace-manifest-validate.cjs');
const { ownerOf, stripCredentials } = require('../../../../hooks/lib/git-remote-url.cjs');
const { seedMap } = require('./system-map-seed.cjs');
const { archetypeOption } = require('./archetypes.cjs');
const { originOf } = require('./workspace-git.cjs');
const { list, jsonText, fail, usageError, identityError } = require('./workspace-util.cjs');

/** org, client and product for a monorepo map (a workspace map takes them from the manifest). */
function monorepoIdentity(root, opts) {
  const owner = ownerOf(stripCredentials(originOf(root) || ''));
  const org = list(opts.org);
  return { org: org.length > 0 ? org : owner ? [owner] : undefined, client: opts.client, product: opts.product };
}

/** Existing map as stored, or { map: null } when absent, or { errors }. */
function readStoredMap(file, manifest) {
  let text;
  try { text = fs.readFileSync(file, 'utf8'); } catch (err) {
    return err && err.code === 'ENOENT' ? { map: null } : { errors: ['system-map.json cannot be read'] };
  }
  const { value, error } = parseJson(text, 'system-map.json');
  if (error) return { errors: [error] };
  const { errors } = validateSystemMap(value, { manifest });
  return errors.length > 0 ? { errors } : { map: value };
}

/** @param {{ root: string, docsRel: string, opts: object }} ctx */
function run({ root, docsRel, opts }) {
  const { manifest, errors } = loadManifest(root);
  if (errors.length > 0) return fail(errors);
  if (!manifest) {
    const bad = identityError(opts, { forMap: true });
    if (bad) return usageError(bad);
  }
  const chosen = archetypeOption(opts);
  if (chosen.error) return usageError(chosen.error);
  const file = mapPath(root, docsRel);
  const stored = readStoredMap(file, manifest);
  if (stored.errors) return fail(stored.errors);
  if (stored.map && !opts.merge) return fail(['the system map already exists; use --merge to add missing components and contracts, or delete the file to start over']);

  const { map, added } = seedMap({ root, manifest, existing: stored.map, archetype: chosen.archetype, ...(manifest ? {} : monorepoIdentity(root, opts)) });
  const rel = path.relative(root, file).split(path.sep).join('/');
  const seeded = validateSystemMap(map, { manifest });
  if (seeded.errors.length > 0) return fail([`the seeded map is invalid, nothing written: ${seeded.errors.join('; ')}`]);
  if (!opts['dry-run'] && (added.length > 0 || !stored.map)) {
    try {
      fs.mkdirSync(path.dirname(file), { recursive: true });
      fs.writeFileSync(file, jsonText(map));
    } catch (err) { return fail([`cannot write ${rel} (${err && err.code ? err.code : 'error'})`]); }
  }
  const verb = opts['dry-run'] ? 'would add' : 'added';
  const text = added.length > 0 ? `${rel}: ${verb} ${added.join(', ')}` : `${rel}: nothing to add`;
  return { code: 0, result: { ok: true, file: rel, dryRun: Boolean(opts['dry-run']), added }, text };
}

module.exports = { run, monorepoIdentity };
