'use strict';

// setup-ci: copies ADF's CI workflow template into the project once, stamped with the template's hash,
// so a later --check can say when ADF's template changed. The copy belongs to the project and is
// never overwritten.

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const TEMPLATE_DIR = path.join(__dirname, '..', '..', 'templates', 'github');
const WORKFLOWS = [{ template: 'adf-git-guards.yml', target: '.github/workflows/adf-git-guards.yml' }];
const STAMP = /^# adf-template: (\S+)@([0-9a-f]{16})$/m;

const hash = (text) => crypto.createHash('sha256').update(text).digest('hex').slice(0, 16);

function render(config, templateText, name) {
  const lines = templateText.replace(/__MAIN_BRANCH__/g, config.mainBranch).split('\n');
  lines.splice(1, 0, `# adf-template: ${name}@${hash(templateText)}`);
  return lines.join('\n');
}

/** @returns {Array<{target, status: 'created'|'exists'|'would-create'}>} */
function setupCi(config, { dryRun = false } = {}) {
  return WORKFLOWS.map(({ template, target }) => {
    const file = path.join(config.root, target);
    if (fs.existsSync(file)) return { target, status: 'exists' };
    if (dryRun) return { target, status: 'would-create' };
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, render(config, fs.readFileSync(path.join(TEMPLATE_DIR, template), 'utf8'), template));
    return { target, status: 'created' };
  });
}

/** @returns {Array<{target, status: 'missing'|'current'|'template-changed'|'not-from-adf'}>} */
function checkCi(config) {
  return WORKFLOWS.map(({ template, target }) => {
    const file = path.join(config.root, target);
    if (!fs.existsSync(file)) return { target, status: 'missing' };
    const stamp = STAMP.exec(fs.readFileSync(file, 'utf8'));
    if (!stamp) return { target, status: 'not-from-adf' };
    const current = hash(fs.readFileSync(path.join(TEMPLATE_DIR, template), 'utf8'));
    return { target, status: stamp[2] === current ? 'current' : 'template-changed', template: path.relative(config.root, path.join(TEMPLATE_DIR, template)) };
  });
}

module.exports = { WORKFLOWS, render, setupCi, checkCi };
