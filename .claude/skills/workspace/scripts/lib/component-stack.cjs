/**
 * component-stack.cjs - Detect the stack of one component directory from marker files.
 *
 * Pure fs reads. Returns exactly the stacks the context templates cover.
 *
 * @module component-stack
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { readTextCapped } = require('../../../../hooks/lib/read-text-capped.cjs');

const STACKS = ['nestjs', 'react-native', 'vue', 'maven', 'foundry', 'python', 'unknown'];
// Role a stack implies when the component name says nothing (seed-map falls back to this)
const STACK_ROLES = { nestjs: 'backend', 'react-native': 'mobile', vue: 'frontend', maven: 'backend', foundry: 'smart-contract', python: 'backend', unknown: 'unknown' };
const MAX_PACKAGE_BYTES = 1024 * 1024;

const exists = (dir, file) => { try { return fs.statSync(path.join(dir, file)).isFile(); } catch { return false; } };

function readPackage(dir) {
  try {
    const text = readTextCapped(path.join(dir, 'package.json'), MAX_PACKAGE_BYTES);
    const pkg = text === null ? null : JSON.parse(text);
    return pkg && typeof pkg === 'object' ? pkg : null;
  } catch { return null; }
}

/**
 * @param {string} dir Component directory
 * @returns {'nestjs'|'react-native'|'vue'|'maven'|'foundry'|'python'|'unknown'}
 */
function detectStack(dir) {
  const pkg = readPackage(dir);
  if (pkg) {
    const deps = { ...pkg.devDependencies, ...pkg.dependencies };
    if (deps['@nestjs/core']) return 'nestjs';
    if (deps['react-native']) return 'react-native';
    if (deps.vue || deps.nuxt) return 'vue';
  }
  if (exists(dir, 'pom.xml')) return 'maven';
  if (exists(dir, 'foundry.toml')) return 'foundry';
  if (exists(dir, 'pyproject.toml') || exists(dir, 'requirements.txt')) return 'python';
  return 'unknown';
}

module.exports = { STACKS, STACK_ROLES, detectStack, readPackage };
