/**
 * plan-contract-project.cjs - Where a plan dir lives: its project root, the plans root from that
 * project's config, and whether the dir sits inside it.
 *
 * The root comes from the plan dir, never from the current directory, so the answer is the same
 * wherever the script runs.
 *
 * @module plan-contract-project
 */

'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { loadConfigFromPath, sanitizePath, LOCAL_CONFIG_PATH, DEFAULT_CONFIG } = require('../../../../hooks/lib/adf-config-utils.cjs');
const { realpathLoose, relativePosix, insideRoot } = require('../../../../hooks/lib/path-containment.cjs');

const ROOT_MARKER = path.join('.claude', 'metadata.json');

/**
 * Nearest ancestor of `startDir` (itself included) holding `.claude/metadata.json`, stopping
 * before $HOME. A bare `.claude/` is not a root: agents with local memory create one in plan dirs.
 * @returns {string|null}
 */
function findProjectRoot(startDir) {
  const home = realpathLoose(path.resolve(os.homedir()));
  let current = startDir;
  while (current !== home) {
    try {
      if (fs.statSync(path.join(current, ROOT_MARKER)).isFile()) return current;
    } catch { /* keep walking */ }
    const parent = path.dirname(current);
    if (parent === current) break;
    current = parent;
  }
  return null;
}

/** `paths.plans` of the project's config, sanitized the way loadConfig does, as an absolute path. */
function plansRootOf(root) {
  const config = loadConfigFromPath(path.join(root, LOCAL_CONFIG_PATH));
  const configured = config && config.paths ? sanitizePath(config.paths.plans, root) : null;
  return realpathLoose(path.resolve(root, configured || DEFAULT_CONFIG.paths.plans));
}

/**
 * @param {string} planDirArg Plan dir as given on the command line
 * @returns {{ error: string }|{ root: string, plansRoot: string, planDir: string, insidePlansRoot: boolean }}
 */
function locatePlanDir(planDirArg) {
  let planDir;
  try {
    planDir = fs.realpathSync(path.resolve(planDirArg));
    if (!fs.statSync(planDir).isDirectory()) return { error: `not a directory: ${planDirArg}` };
    fs.readdirSync(planDir);
  } catch {
    return { error: `cannot read directory: ${planDirArg}` };
  }
  const root = findProjectRoot(planDir);
  if (!root) return { error: `no project root (.claude/metadata.json) above ${planDir}` };
  const plansRoot = plansRootOf(root);
  return { root, plansRoot, planDir, insidePlansRoot: insideRoot(relativePosix(plansRoot, planDir)) };
}

module.exports = { findProjectRoot, plansRootOf, locatePlanDir };
