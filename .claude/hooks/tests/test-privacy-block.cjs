#!/usr/bin/env node
/**
 * test-privacy-block.cjs - Unit tests for privacy-block hook
 */

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

const HOOK_PATH = path.join(__dirname, '..', 'privacy-block.cjs');
const ADF_CONFIG_PATH = path.join(__dirname, '..', 'config', 'adf-config.json');

async function runHook(hookData, cwd = undefined) {
  return new Promise((resolve) => {
    const options = cwd ? { cwd } : {};
    const proc = spawn('node', [HOOK_PATH], options);
    let stdout = '';

    proc.stdout.on('data', (data) => {
      stdout += data.toString();
    });

    proc.on('close', (code) => {
      let decision = null;
      try {
        decision = JSON.parse(stdout).hookSpecificOutput.permissionDecision;
      } catch {}
      resolve({ code, stdout, decision });
    });

    proc.stdin.write(JSON.stringify(hookData));
    proc.stdin.end();
  });
}

// Test cases - sensitive paths prompt the user (permissionDecision: ask)
const blockTests = [
  {
    name: '.env file - should ask',
    input: { tool_input: { file_path: '.env' } },
    expectBlock: true,
    expectContains: 'may contain secrets'
  },
  {
    name: '.env.local - should ask',
    input: { tool_input: { file_path: '.env.local' } },
    expectBlock: true,
    expectContains: 'may contain secrets'
  },
  {
    name: 'credentials.json - should ask',
    input: { tool_input: { file_path: 'config/credentials.json' } },
    expectBlock: true
  },
  {
    name: 'id_rsa - should ask',
    input: { tool_input: { file_path: '~/.ssh/id_rsa' } },
    expectBlock: true
  },
  {
    name: '.env in bash command - should ask',
    input: { tool_input: { command: 'cat .env' } },
    expectBlock: true
  },
  {
    name: 'secrets.yaml - should ask',
    input: { tool_input: { file_path: 'secrets.yaml' } },
    expectBlock: true
  },
  {
    name: 'private.key - should ask',
    input: { tool_input: { file_path: 'certs/private.key' } },
    expectBlock: true
  },
  // NEW: URL-encoded paths
  {
    name: 'URL-encoded .env (%2e%65%6e%76) - should ask',
    input: { tool_input: { file_path: '%2eenv' } },
    expectBlock: true
  },
  // NEW: Bash variable assignments
  {
    name: 'bash variable FILE=.env - should ask',
    input: { tool_input: { command: 'FILE=.env cat $FILE' } },
    expectBlock: true
  },
  // NEW: Command substitution
  {
    name: 'command substitution $(cat .env) - should ask',
    input: { tool_input: { command: 'echo $(cat .env)' } },
    expectBlock: true
  }
];

// APPROVED: prefix is no longer an approval mechanism - still sensitive
const approvedPrefixTests = [
  {
    name: 'APPROVED:.env - should ask (prefix is not approval)',
    input: { tool_input: { file_path: 'APPROVED:.env' } },
    expectBlock: true
  },
  {
    name: 'APPROVED in bash command - should ask',
    input: { tool_input: { command: 'cat APPROVED:.env' } },
    expectBlock: true
  }
];

// Test cases - non-sensitive files (always allowed)
const safeTests = [
  {
    name: 'regular file - should allow',
    input: { tool_input: { file_path: 'src/index.ts' } },
    expectBlock: false
  },
  {
    name: 'package.json - should allow',
    input: { tool_input: { file_path: 'package.json' } },
    expectBlock: false
  },
  {
    name: 'README.md - should allow',
    input: { tool_input: { file_path: 'README.md' } },
    expectBlock: false
  }
];

// Test cases - example/sample/template files (exempt from privacy checks)
const exemptTests = [
  {
    name: '.env.example - should allow (exempt)',
    input: { tool_input: { file_path: '.env.example' } },
    expectBlock: false
  },
  {
    name: '.env.local.example - should allow (exempt)',
    input: { tool_input: { file_path: '.env.local.example' } },
    expectBlock: false
  },
  {
    name: '.env.sample - should allow (exempt)',
    input: { tool_input: { file_path: '.env.sample' } },
    expectBlock: false
  },
  {
    name: '.env.template - should allow (exempt)',
    input: { tool_input: { file_path: '.env.template' } },
    expectBlock: false
  },
  {
    name: 'config/.env.example - should allow (exempt)',
    input: { tool_input: { file_path: 'config/.env.example' } },
    expectBlock: false
  },
  {
    name: 'credentials.example - should allow (exempt)',
    input: { tool_input: { file_path: 'credentials.example' } },
    expectBlock: false
  },
  {
    name: 'cat .env.example in bash - should allow (exempt)',
    input: { tool_input: { command: 'cat .env.example' } },
    expectBlock: false
  }
];

// Test cases - config toggle (privacyBlock: false)
const configToggleTests = [
  {
    name: 'privacyBlock: false - .env should allow',
    input: { tool_input: { file_path: '.env' } },
    config: { privacyBlock: false },
    expectBlock: false
  },
  {
    name: 'privacyBlock: false - credentials.json should allow',
    input: { tool_input: { file_path: 'credentials.json' } },
    config: { privacyBlock: false },
    expectBlock: false
  },
  {
    name: 'privacyBlock: true - .env should ask',
    input: { tool_input: { file_path: '.env' } },
    config: { privacyBlock: true },
    expectBlock: true
  }
];

async function main() {
  console.log('Testing privacy-block hook...\n');

  let passed = 0;
  let failed = 0;

  const groups = [
    ['Ask Tests (sensitive paths)', blockTests],
    ['APPROVED: prefix is not approval', approvedPrefixTests]
  ];
  for (const [title, tests] of groups) {
    console.log(`${groups[0][0] === title ? '' : '\n'}\x1b[1m--- ${title} ---\x1b[0m`);
    for (const test of tests) {
      const result = await runHook(test.input);
      const asked = result.code === 0 && result.decision === 'ask';
      const success = asked === test.expectBlock && result.code === 0;
      const containsOk = !test.expectContains || result.stdout.includes(test.expectContains);

      if (success && containsOk) {
        console.log(`\x1b[32m✓\x1b[0m ${test.name}`);
        passed++;
      } else {
        console.log(`\x1b[31m✗\x1b[0m ${test.name}: expected ASK, got ${asked ? 'ASK' : 'ALLOW'} (exit ${result.code})`);
        failed++;
      }
    }
  }

  console.log('\n\x1b[1m--- Safe Files (always allowed) ---\x1b[0m');
  for (const test of safeTests) {
    const result = await runHook(test.input);
    const blocked = result.decision === 'ask' || result.code !== 0;
    const success = blocked === test.expectBlock;

    if (success) {
      console.log(`\x1b[32m✓\x1b[0m ${test.name}`);
      passed++;
    } else {
      console.log(`\x1b[31m✗\x1b[0m ${test.name}: expected ALLOW, got ${blocked ? 'ASK' : 'ALLOW'}`);
      failed++;
    }
  }

  console.log('\n\x1b[1m--- Exempt Files (example/sample/template) ---\x1b[0m');
  for (const test of exemptTests) {
    const result = await runHook(test.input);
    const blocked = result.decision === 'ask' || result.code !== 0;
    const success = blocked === test.expectBlock;

    if (success) {
      console.log(`\x1b[32m✓\x1b[0m ${test.name}`);
      passed++;
    } else {
      console.log(`\x1b[31m✗\x1b[0m ${test.name}: expected ALLOW (exempt), got ${blocked ? 'ASK' : 'ALLOW'}`);
      failed++;
    }
  }

  // Config toggle tests - requires temp directory with .claude/config/adf-config.json
  console.log('\n\x1b[1m--- Config Toggle (privacyBlock setting) ---\x1b[0m');
  const os = require('os');
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'privacy-test-'));
  const tmpClaudeDir = path.join(tmpDir, '.claude');
  const tmpConfigDir = path.join(tmpClaudeDir, 'config');
  fs.mkdirSync(tmpConfigDir, { recursive: true });

  for (const test of configToggleTests) {
    // Write test config
    fs.writeFileSync(
      path.join(tmpConfigDir, 'adf-config.json'),
      JSON.stringify(test.config)
    );

    const result = await runHook(test.input, tmpDir);
    const blocked = result.decision === 'ask' || result.code !== 0;
    const success = blocked === test.expectBlock;

    if (success) {
      console.log(`\x1b[32m✓\x1b[0m ${test.name}`);
      passed++;
    } else {
      console.log(`\x1b[31m✗\x1b[0m ${test.name}: expected ${test.expectBlock ? 'ASK' : 'ALLOW'}, got ${blocked ? 'ASK' : 'ALLOW'}`);
      failed++;
    }
  }

  // Cleanup temp directory
  fs.rmSync(tmpDir, { recursive: true, force: true });

  console.log(`\n\x1b[1mResults:\x1b[0m ${passed} passed, ${failed} failed`);
  process.exit(failed > 0 ? 1 : 0);
}

main();
