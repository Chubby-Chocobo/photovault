#!/usr/bin/env node
/**
 * Tests for privacy-block.cjs hook
 * Run: node --test .claude/hooks/__tests__/privacy-block.test.cjs
 */

const { describe, it, after } = require('node:test');
const assert = require('node:assert');
const path = require('path');

// The hook module exports its helpers for unit testing
const {
  isSafeFile,
  isPrivacySensitive,
  extractPaths,
} = require('../privacy-block.cjs');

describe('privacy-block.cjs', () => {

  describe('isSafeFile', () => {
    it('returns true for .example files', () => {
      assert.strictEqual(isSafeFile('.env.example'), true);
      assert.strictEqual(isSafeFile('config.example'), true);
      assert.strictEqual(isSafeFile('/path/to/.env.example'), true);
    });

    it('returns true for .sample files', () => {
      assert.strictEqual(isSafeFile('.env.sample'), true);
      assert.strictEqual(isSafeFile('config.sample'), true);
    });

    it('returns true for .template files', () => {
      assert.strictEqual(isSafeFile('.env.template'), true);
      assert.strictEqual(isSafeFile('config.template'), true);
    });

    it('returns false for actual sensitive files', () => {
      assert.strictEqual(isSafeFile('.env'), false);
      assert.strictEqual(isSafeFile('.env.local'), false);
      assert.strictEqual(isSafeFile('credentials.json'), false);
    });

    it('handles null/undefined gracefully', () => {
      assert.strictEqual(isSafeFile(null), false);
      assert.strictEqual(isSafeFile(undefined), false);
      assert.strictEqual(isSafeFile(''), false);
    });
  });

  describe('isPrivacySensitive', () => {
    describe('env files', () => {
      it('blocks .env', () => {
        assert.strictEqual(isPrivacySensitive('.env'), true);
      });

      it('blocks .env.local, .env.production, etc.', () => {
        assert.strictEqual(isPrivacySensitive('.env.local'), true);
        assert.strictEqual(isPrivacySensitive('.env.production'), true);
        assert.strictEqual(isPrivacySensitive('.env.development'), true);
      });

      it('blocks paths containing .env', () => {
        assert.strictEqual(isPrivacySensitive('/path/to/.env'), true);
        assert.strictEqual(isPrivacySensitive('src/config/.env.local'), true);
      });

      it('allows .env.example, .env.sample, .env.template', () => {
        assert.strictEqual(isPrivacySensitive('.env.example'), false);
        assert.strictEqual(isPrivacySensitive('.env.sample'), false);
        assert.strictEqual(isPrivacySensitive('.env.template'), false);
      });
    });

    describe('credentials and secrets', () => {
      it('blocks MCP server configs but not similar names', () => {
        assert.strictEqual(isPrivacySensitive('.mcp.json'), true);
        assert.strictEqual(isPrivacySensitive('.claude/.mcp.json'), true);
        assert.strictEqual(isPrivacySensitive('mcp.json'), false);
      });

      it('blocks credentials files', () => {
        assert.strictEqual(isPrivacySensitive('credentials.json'), true);
        assert.strictEqual(isPrivacySensitive('Credentials.yaml'), true);
        assert.strictEqual(isPrivacySensitive('/path/credentials.txt'), true);
      });

      it('blocks secrets files', () => {
        assert.strictEqual(isPrivacySensitive('secrets.yaml'), true);
        assert.strictEqual(isPrivacySensitive('secret.yml'), true);
        assert.strictEqual(isPrivacySensitive('secrets.yml'), true);
      });
    });

    describe('private keys', () => {
      it('blocks .pem files', () => {
        assert.strictEqual(isPrivacySensitive('private.pem'), true);
        assert.strictEqual(isPrivacySensitive('/ssl/cert.pem'), true);
      });

      it('blocks .key files', () => {
        assert.strictEqual(isPrivacySensitive('server.key'), true);
        assert.strictEqual(isPrivacySensitive('/path/private.key'), true);
      });

      it('blocks SSH keys', () => {
        assert.strictEqual(isPrivacySensitive('id_rsa'), true);
        assert.strictEqual(isPrivacySensitive('id_ed25519'), true);
        assert.strictEqual(isPrivacySensitive('~/.ssh/id_rsa'), true);
      });
    });

    describe('path normalization', () => {
      it('handles Windows paths', () => {
        assert.strictEqual(isPrivacySensitive('C:\\path\\.env'), true);
        assert.strictEqual(isPrivacySensitive('C:\\path\\.env.local'), true);
      });

      it('handles URI-encoded paths', () => {
        // %2e = '.'
        assert.strictEqual(isPrivacySensitive('%2eenv'), true);
      });
    });

    describe('APPROVED: prefix handling', () => {
      it('treats APPROVED: prefix as a plain sensitive path, not approval', () => {
        assert.strictEqual(isPrivacySensitive('APPROVED:.env'), true);
        assert.strictEqual(isPrivacySensitive('APPROVED:/path/.env.local'), true);
      });
    });

    it('handles null/undefined gracefully', () => {
      assert.strictEqual(isPrivacySensitive(null), false);
      assert.strictEqual(isPrivacySensitive(undefined), false);
      assert.strictEqual(isPrivacySensitive(''), false);
    });
  });

  describe('extractPaths', () => {
    it('extracts file_path', () => {
      const paths = extractPaths({ file_path: '.env' });
      assert.deepStrictEqual(paths, [{ value: '.env', field: 'file_path' }]);
    });

    it('extracts path', () => {
      const paths = extractPaths({ path: '/src/.env' });
      assert.deepStrictEqual(paths, [{ value: '/src/.env', field: 'path' }]);
    });

    it('extracts pattern', () => {
      const paths = extractPaths({ pattern: '**/.env*' });
      assert.deepStrictEqual(paths, [{ value: '**/.env*', field: 'pattern' }]);
    });

    it('extracts multiple fields', () => {
      const paths = extractPaths({
        file_path: '.env',
        path: '/config',
        pattern: '*.env'
      });
      assert.strictEqual(paths.length, 3);
    });

    describe('command parsing', () => {
      it('extracts .env from commands', () => {
        const paths = extractPaths({ command: 'cat .env' });
        assert.deepStrictEqual(paths, [{ value: '.env', field: 'command' }]);
      });

      it('extracts .env.local from commands', () => {
        const paths = extractPaths({ command: 'cat .env.local' });
        assert.deepStrictEqual(paths, [{ value: '.env.local', field: 'command' }]);
      });

      it('treats APPROVED:.env as a plain .env path', () => {
        const paths = extractPaths({ command: 'cat APPROVED:.env' });
        assert.deepStrictEqual(paths, [{ value: '.env', field: 'command' }]);
      });

      it('extracts from variable assignments', () => {
        const paths = extractPaths({ command: 'FILE=.env.local cat $FILE' });
        const values = paths.map(p => p.value);
        assert.ok(values.includes('.env.local'));
      });

      it('extracts from command substitution', () => {
        const paths = extractPaths({ command: 'cat $(echo .env)' });
        const values = paths.map(p => p.value);
        assert.ok(values.includes('.env'));
      });
    });

    it('handles null/undefined input', () => {
      assert.deepStrictEqual(extractPaths(null), []);
      assert.deepStrictEqual(extractPaths(undefined), []);
      assert.deepStrictEqual(extractPaths({}), []);
    });
  });
});

describe('checkPrivacy', () => {
  const fs = require('fs');
  const { checkPrivacy, isReadDeniedBySettings } = require('../lib/privacy-checker.cjs');
  const opts = { disabled: false, configDir: '/nonexistent' };

  it('flags .env via Edit', () => {
    const r = checkPrivacy({ toolName: 'Edit', toolInput: { file_path: '.env' }, options: opts });
    assert.strictEqual(r.sensitive, true);
    assert.strictEqual(r.filePath, '.env');
    assert.match(r.reason, /\.env may contain secrets/);
  });

  it('leaves Read of deny-listed files to the settings deny rules', () => {
    for (const file of ['.env', 'app/.env.production', '.env.dev.local', 'server.pem', 'tls.key', 'id_rsa', 'secrets.yaml']) {
      const r = checkPrivacy({ toolName: 'Read', toolInput: { file_path: file }, options: opts });
      assert.strictEqual(r.sensitive, false, file);
    }
  });

  const tempProjects = [];
  after(() => { for (const dir of tempProjects) fs.rmSync(dir, { recursive: true, force: true }); });
  const projectWith = (deny) => {
    const dir = fs.mkdtempSync(path.join(require('os').tmpdir(), 'privacy-proj-'));
    tempProjects.push(dir);
    fs.mkdirSync(path.join(dir, '.claude'));
    fs.writeFileSync(path.join(dir, '.claude', 'settings.json'), JSON.stringify({ permissions: { deny } }));
    return dir;
  };

  it('still asks for deny-listed names outside the working directory', () => {
    const dir = projectWith(['Read(**/.env)', 'Read(**/id_rsa)']);
    const cwdOpts = { ...opts, cwd: dir };
    for (const file of [path.join(path.dirname(dir), '.env'), '../other/.env', '/tmp/x/id_rsa', '~/.env']) {
      const r = checkPrivacy({ toolName: 'Read', toolInput: { file_path: file }, options: cwdOpts });
      assert.strictEqual(r.sensitive, true, file);
    }
    const inside = checkPrivacy({ toolName: 'Read', toolInput: { file_path: path.join(dir, 'api', '.env') }, options: cwdOpts });
    assert.strictEqual(inside.sensitive, false);
  });

  it('asks for Read when the project settings no longer deny it', () => {
    const none = projectWith([]);
    const narrowed = projectWith(['Read(**/.env.local)']);
    const covered = projectWith(['Read(**/.env)']);
    const read = (cwd) => checkPrivacy({ toolName: 'Read', toolInput: { file_path: '.env' }, options: { ...opts, cwd } }).sensitive;
    assert.strictEqual(read(none), true);
    assert.strictEqual(read(narrowed), true);
    assert.strictEqual(read(covered), false);
  });

  it('reads deny rules from the project root, whatever directory the hook runs in', () => {
    // Claude Code loads the launch project's settings only, so a member's own deny rule is not in
    // effect, while a project-root rule still covers files in any subdirectory.
    const root = projectWith(['Read(**/*.key)']);
    const member = path.join(root, 'services', 'core');
    fs.mkdirSync(path.join(member, '.claude'), { recursive: true });
    fs.writeFileSync(path.join(member, '.claude', 'settings.json'), JSON.stringify({ permissions: { deny: ['Read(**/your-credentials.json)'] } }));
    const saved = process.env.CLAUDE_PROJECT_DIR;
    process.env.CLAUDE_PROJECT_DIR = root;
    try {
      for (const [cwd, keyPath] of [[member, '../order/x.key'], [root, 'services/order/x.key']]) {
        const check = (toolName, toolInput) => checkPrivacy({ toolName, toolInput, options: { ...opts, cwd } }).sensitive;
        assert.strictEqual(check('Read', { file_path: 'your-credentials.json' }), true, `member rule must not apply (cwd ${cwd})`);
        assert.strictEqual(check('Read', { file_path: keyPath }), false, `root rule must apply (cwd ${cwd})`);
        assert.strictEqual(check('Bash', { command: `cat ${keyPath}` }), true, `Bash still asks (cwd ${cwd})`);
      }
    } finally {
      if (saved === undefined) delete process.env.CLAUDE_PROJECT_DIR; else process.env.CLAUDE_PROJECT_DIR = saved;
    }
  });

  describe('secret files in workspace members', () => {
    const SECRETS = ['services/be/fireblocks_secret.key', 'apps/mobile/your-credentials.json', 'apps/mobile/.env.production'];
    const member = (root) => {
      const dir = path.join(root, 'services', 'core');
      fs.mkdirSync(dir, { recursive: true });
      return dir;
    };
    const withProjectDir = (root, fn) => {
      const saved = process.env.CLAUDE_PROJECT_DIR;
      process.env.CLAUDE_PROJECT_DIR = root;
      try { fn(); } finally { if (saved === undefined) delete process.env.CLAUDE_PROJECT_DIR; else process.env.CLAUDE_PROJECT_DIR = saved; }
    };
    const asks = (toolName, toolInput, cwd) => checkPrivacy({ toolName, toolInput, options: { ...opts, cwd } }).sensitive;

    it('asks for Read, Bash cat and Grep path when no deny rule covers the file', () => {
      const root = projectWith([]);
      const cwd = member(root);
      withProjectDir(root, () => {
        for (const file of SECRETS) {
          for (const target of [file, path.join(root, file), `../../${file}`]) {
            assert.strictEqual(asks('Read', { file_path: target }, cwd), true, `Read ${target}`);
            assert.strictEqual(asks('Bash', { command: `cat ${target}` }, cwd), true, `Bash cat ${target}`);
            assert.strictEqual(asks('Grep', { pattern: 'KEY', path: target }, cwd), true, `Grep ${target}`);
          }
        }
      });
    });

    it('leaves Read to the project deny rules but still asks for Bash and Grep', () => {
      const root = projectWith(['Read(**/*.key)', 'Read(**/.env.production)']);
      const cwd = member(root);
      withProjectDir(root, () => {
        for (const file of ['services/be/fireblocks_secret.key', 'apps/mobile/.env.production']) {
          assert.strictEqual(asks('Read', { file_path: path.join(root, file) }, cwd), false, `Read ${file}`);
          assert.strictEqual(asks('Bash', { command: `cat ${file}` }, cwd), true, `Bash ${file}`);
          assert.strictEqual(asks('Grep', { pattern: 'KEY', path: file }, cwd), true, `Grep ${file}`);
        }
        assert.strictEqual(asks('Read', { file_path: path.join(root, 'apps/mobile/your-credentials.json') }, cwd), true);
      });
    });

    it('asks for git-credentials and netrc files at any depth, through every tool', () => {
      const root = projectWith([]);
      const cwd = member(root);
      withProjectDir(root, () => {
        for (const file of ['.git-credentials', '.netrc', '~/.git-credentials', 'services/core/.netrc', 'apps/mobile/.git-credentials']) {
          for (const toolName of ['Read', 'Edit', 'Write']) {
            assert.strictEqual(asks(toolName, { file_path: file }, cwd), true, `${toolName} ${file}`);
          }
          assert.strictEqual(asks('Grep', { pattern: 'x', path: file }, cwd), true, `Grep ${file}`);
          assert.strictEqual(asks('Bash', { command: `cat ${file}` }, cwd), true, `Bash ${file}`);
        }
        assert.strictEqual(asks('Bash', { command: 'cat .net*' }, cwd), true);
        assert.strictEqual(asks('Bash', { command: 'cat .git-cred*' }, cwd), true);
        for (const file of ['netrc', '.netrc.example', '.netrc.sample', 'docs/git-credentials.md', '.netrcx']) {
          assert.strictEqual(asks('Read', { file_path: file }, cwd), false, file);
        }
        assert.strictEqual(asks('Bash', { command: 'git config credential.helper store' }, cwd), false);
      });
    });
  });

  describe('.claude/settings files', () => {
    const FILES = ['.claude/settings.json', '.claude/settings.local.json', 'services/core/.claude/settings.json', '/home/u/.claude/settings.json'];
    const check = (toolName, toolInput) => checkPrivacy({ toolName, toolInput, options: opts });

    it('asks before Edit, MultiEdit and Write change them', () => {
      for (const file of FILES) {
        for (const toolName of ['Edit', 'MultiEdit', 'Write']) {
          assert.strictEqual(check(toolName, { file_path: file }).sensitive, true, `${toolName} ${file}`);
        }
      }
    });

    it('asks before a shell command that may change them', () => {
      for (const command of ['sed -i s/a/b/ .claude/settings.json', 'echo {} > .claude/settings.local.json', 'cp x services/core/.claude/settings.json',
        'cat x > .claude/settings.json', 'git checkout -- .claude/settings.json', 'tee .claude/settings.local.json < x', 'node fix.js .claude/settings.json',
        'cat a.json | tee .claude/settings.json']) {
        assert.strictEqual(check('Bash', { command }).sensitive, true, command);
      }
    });

    it('leaves shell commands that only read them free', () => {
      for (const command of ['cat .claude/settings.local.json', 'git diff -- .claude/settings.json', 'git show HEAD:.claude/settings.json',
        'git -C services/core diff .claude/settings.json', 'jq .hooks .claude/settings.json', 'ls -la .claude/settings.json',
        'git add .claude/settings.json', 'grep deny .claude/settings.json', 'head -5 .claude/settings.json; git status']) {
        assert.strictEqual(check('Bash', { command }).sensitive, false, command);
      }
    });

    it('leaves Read and Grep free', () => {
      for (const file of FILES) {
        assert.strictEqual(check('Read', { file_path: file }).sensitive, false, `Read ${file}`);
        assert.strictEqual(check('Grep', { pattern: 'deny', path: file }).sensitive, false, `Grep ${file}`);
      }
    });

    it('does not ask about other settings files or look-alikes', () => {
      for (const file of ['settings.json', 'docs/settings.json', '.claude/settings.json.example', '.claude/settings.jsonc', '.claude/config/adf-config.json', '.vscode/settings.json']) {
        for (const toolName of ['Edit', 'Write']) assert.strictEqual(check(toolName, { file_path: file }).sensitive, false, `${toolName} ${file}`);
      }
      assert.strictEqual(check('Bash', { command: 'ls .claude' }).sensitive, false);
    });

    it('says why it asks, without claiming the file holds secrets', () => {
      const settings = check('Edit', { file_path: '.claude/settings.json' });
      assert.match(settings.reason, /permissions and hooks/);
      assert.doesNotMatch(settings.reason, /secrets/);
      assert.match(check('Edit', { file_path: '.env' }).reason, /may contain secrets/);
    });
  });

  it('reads deny rules from settings.local.json too', () => {
    const dir = projectWith([]);
    fs.writeFileSync(path.join(dir, '.claude', 'settings.local.json'), JSON.stringify({ permissions: { deny: ['Read(**/*.pem)'] } }));
    assert.strictEqual(isReadDeniedBySettings('certs/server.pem', dir), true);
    assert.strictEqual(isReadDeniedBySettings('.env', dir), false);
  });

  it('still asks for Read of sensitive files the deny rules do not cover', () => {
    const r = checkPrivacy({ toolName: 'Read', toolInput: { file_path: 'config/credentials.json' }, options: opts });
    assert.strictEqual(r.sensitive, true);
  });

  it('asks when a shell command names any sensitive path', () => {
    for (const command of [
      'cat ~/.aws/credentials', 'cat .mcp.json', 'cat credentials.json', 'cat ~/.ssh/id_rsa', 'less $HOME/.ssh/config',
      'cat .env*', 'cat .env.*', 'cp server.pem /tmp/x', 'cat "secrets.yml"', 'cat config/secrets.yaml', 'ls ~/.aws',
      'FILE=~/.ssh/id_ed25519 cat $FILE', 'cat .env.local; echo done',
    ]) {
      assert.strictEqual(checkPrivacy({ toolName: 'Bash', toolInput: { command }, options: opts }).sensitive, true, command);
    }
  });

  it('does not ask for templates or ordinary commands that mention env or keys', () => {
    for (const command of [
      'cat .env.example', 'cp .env.sample /tmp/x', 'echo $HOME', 'node -e "console.log(process.env.CREDENTIALS)"',
      'cat src/auth/credentials.ts', 'cat ssh_config_notes.md', 'cat id_rsa.pub', 'git status',
    ]) {
      assert.strictEqual(checkPrivacy({ toolName: 'Bash', toolInput: { command }, options: opts }).sensitive, false, command);
    }
  });

  it('does not ask about ordinary source and docs files named after credentials', () => {
    for (const file of ['src/auth/credentials.ts', 'src/lib/credentials-provider.tsx', 'docs/guides/aws-credentials-setup.md']) {
      for (const toolName of ['Read', 'Edit', 'Write']) {
        assert.strictEqual(checkPrivacy({ toolName, toolInput: { file_path: file }, options: opts }).sensitive, false, `${toolName} ${file}`);
      }
    }
    for (const file of ['credentials', '.credentials.json', 'gcp-credentials.json', 'config/credentials.yml']) {
      assert.strictEqual(checkPrivacy({ toolName: 'Edit', toolInput: { file_path: file }, options: opts }).sensitive, true, file);
    }
  });

  it('does not ask about commands that only search for env, key or credential words', () => {
    for (const command of [
      'grep -rn "process.env" src', 'rg process.env', 'node -e "console.log(Object.keys(process.env))"',
      'grep -rn import.meta.env src', 'jq .key package.json', "jq '.data.key' a.json", 'grep -ri credentials src',
      'git log --grep credentials', 'grep -e credentials -r src', 'rg -t js process.env', 'npm test -- --grep id_rsa',
    ]) {
      assert.strictEqual(checkPrivacy({ toolName: 'Bash', toolInput: { command }, options: opts }).sensitive, false, command);
    }
  });

  it('still asks when grep or rg is pointed at a secret file', () => {
    for (const command of ['grep KEY .env', 'rg token ~/.aws/credentials', 'grep -rn password .env.local src']) {
      assert.strictEqual(checkPrivacy({ toolName: 'Bash', toolInput: { command }, options: opts }).sensitive, true, command);
    }
  });

  it('sees through quoting, globs and letter case in shell commands', () => {
    for (const command of ['cat .e""nv', "awk 1 .e'n'v", 'cat .e*', 'cat .en[v]', 'cat .en?', 'cat .ENV', 'cat x/.Env.local', 'cat ~/.s*/id_rsa']) {
      assert.strictEqual(checkPrivacy({ toolName: 'Bash', toolInput: { command }, options: opts }).sensitive, true, command);
    }
    for (const command of ['ls *.json', 'cat *', 'cat .env[x]', 'cat .envrc']) {
      assert.strictEqual(checkPrivacy({ toolName: 'Bash', toolInput: { command }, options: opts }).sensitive, false, command);
    }
  });

  it('checks the glob filter of Grep like a path', () => {
    for (const glob of ['**/.aws/credentials', '**/.env*', '.env', '**/id_rsa']) {
      const r = checkPrivacy({ toolName: 'Grep', toolInput: { pattern: 'secret', path: '/home/x', glob }, options: opts });
      assert.strictEqual(r.sensitive, true, glob);
    }
    const ok = checkPrivacy({ toolName: 'Grep', toolInput: { pattern: 'secret', glob: '**/*.ts' }, options: opts });
    assert.strictEqual(ok.sensitive, false);
  });

  it('flags Windows-style .env paths in shell commands', () => {
    for (const command of ['type C:\\app\\.env', 'cat config\\.env']) {
      assert.strictEqual(checkPrivacy({ toolName: 'Bash', toolInput: { command }, options: opts }).sensitive, true, command);
    }
  });

  it('ignores env access in code and Grep search text', () => {
    for (const command of ['grep -rn process.env.API_KEY src', "sed -i 's/import.meta.env.VITE_A/x/' src/a.ts", 'node -e "console.log(process.env.HOME)"']) {
      assert.strictEqual(checkPrivacy({ toolName: 'Bash', toolInput: { command }, options: opts }).sensitive, false, command);
    }
    const grep = checkPrivacy({ toolName: 'Grep', toolInput: { pattern: 'AWS_SECRET|credentials' }, options: opts });
    assert.strictEqual(grep.sensitive, false);
  });

  it('honours every Read deny rule shipped in settings.json', () => {
    const settings = JSON.parse(fs.readFileSync(path.join(__dirname, '..', '..', 'settings.json'), 'utf8'));
    for (const rule of settings.permissions.deny) {
      const glob = rule.match(/^Read\(\*\*\/(.+)\)$/);
      assert.ok(glob, `unexpected deny rule shape: ${rule}`);
      const sample = glob[1].replace(/\*/g, 'sample');
      assert.ok(isReadDeniedBySettings(sample, path.join(__dirname, '..', '..', '..')), `${rule} is not honoured by isReadDeniedBySettings`);
    }
  });

  it('flags cat .env via Bash', () => {
    const r = checkPrivacy({ toolName: 'Bash', toolInput: { command: 'cat .env' }, options: opts });
    assert.strictEqual(r.sensitive, true);
  });

  it('flags APPROVED:.env instead of treating it as approval', () => {
    const r = checkPrivacy({ toolName: 'Read', toolInput: { file_path: 'APPROVED:.env' }, options: opts });
    assert.strictEqual(r.sensitive, true);
  });

  it('allows .env.example and normal files', () => {
    assert.strictEqual(checkPrivacy({ toolName: 'Read', toolInput: { file_path: '.env.example' }, options: opts }).sensitive, false);
    assert.strictEqual(checkPrivacy({ toolName: 'Read', toolInput: { file_path: 'src/index.ts' }, options: opts }).sensitive, false);
  });

  it('allows everything when disabled', () => {
    const r = checkPrivacy({ toolName: 'Read', toolInput: { file_path: '.env' }, options: { disabled: true } });
    assert.strictEqual(r.sensitive, false);
  });
});

describe('hook stdout contract', () => {
  const { spawnSync } = require('child_process');
  const hook = path.join(__dirname, '..', 'privacy-block.cjs');
  const run = (data) => spawnSync('node', [hook], { input: JSON.stringify(data), encoding: 'utf8' });

  it('prints ask decision JSON and exits 0 for .env', () => {
    const r = run({ tool_name: 'Bash', tool_input: { command: 'cat .env' } });
    assert.strictEqual(r.status, 0);
    const out = JSON.parse(r.stdout);
    assert.strictEqual(out.hookSpecificOutput.hookEventName, 'PreToolUse');
    assert.strictEqual(out.hookSpecificOutput.permissionDecision, 'ask');
    assert.match(out.hookSpecificOutput.permissionDecisionReason, /may contain secrets/);
  });

  it('prints nothing for a normal file', () => {
    const r = run({ tool_name: 'Read', tool_input: { file_path: 'src/index.ts' } });
    assert.strictEqual(r.status, 0);
    assert.strictEqual(r.stdout, '');
  });
});
