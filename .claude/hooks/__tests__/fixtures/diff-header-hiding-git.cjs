'use strict';

// A `git` first on PATH that drops one file's `diff --git` header from every -U0 diff it prints. git itself prints
// one per changed file, so this is how a test stages a name the scanner's diff does not cover.

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

/** Env entries (PATH) that run the shim; `name` is a plain file name at the top level. */
function hidingGitEnv(name) {
  const realGit = execFileSync('sh', ['-c', 'command -v git'], { encoding: 'utf8' }).trim();
  const bin = fs.mkdtempSync(path.join(os.tmpdir(), 'hiding-git-'));
  process.on('exit', () => fs.rmSync(bin, { recursive: true, force: true }));
  const pattern = name.replace(/[.[\]*^$\\/]/g, '\\$&');
  const script = [
    '#!/bin/sh',
    'case " $* " in',
    `  *" -U0 "*) "${realGit}" "$@" | sed '/^diff --git a\\/${pattern} /d'; exit 0 ;;`,
    'esac',
    `exec "${realGit}" "$@"`,
  ];
  fs.writeFileSync(path.join(bin, 'git'), `${script.join('\n')}\n`, { mode: 0o755 });
  return { PATH: `${bin}${path.delimiter}${process.env.PATH}` };
}

module.exports = { hidingGitEnv };
