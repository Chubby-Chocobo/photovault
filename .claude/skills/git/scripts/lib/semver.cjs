'use strict';

// Release versions are plain x.y.z; pre-release tags exist in some repos but never decide the next version.

const SEMVER = /^(\d+)\.(\d+)\.(\d+)$/;

function parse(version) {
  const m = SEMVER.exec(String(version || ''));
  return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null;
}

const isVersion = (v) => parse(v) !== null;

function compare(a, b) {
  const pa = parse(a);
  const pb = parse(b);
  for (let i = 0; i < 3; i++) if (pa[i] !== pb[i]) return pa[i] - pb[i];
  return 0;
}

function bumpPatch(version) {
  const p = parse(version);
  return p ? `${p[0]}.${p[1]}.${p[2] + 1}` : null;
}

function bumpMinor(version) {
  const p = parse(version);
  return p ? `${p[0]}.${p[1] + 1}.0` : null;
}

/** The highest x.y.z among tags that carry the prefix; pre-release and foreign tags are ignored. */
function newestVersion(tags, prefix = 'v') {
  const versions = tags
    .filter((t) => t.startsWith(prefix))
    .map((t) => t.slice(prefix.length))
    .filter(isVersion);
  return versions.sort(compare).at(-1) || null;
}

module.exports = { parse, isVersion, compare, bumpPatch, bumpMinor, newestVersion };
