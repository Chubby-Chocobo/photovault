# Plan Contract

The machine-readable shape of a plan. Any agent or script can read it: ADF does not care who executes a plan, or with which agent. Every field below is **recommended for every plan** and **required only when a caller passes `--require`**.

Check or export a plan with:

```bash
node .claude/skills/adf-plan/scripts/plan-phases.cjs [--json|--check] [--require <field,...>] <plan-dir>
```

## Files

```text
<plans root>/<slug>/
  brief.md          optional: the request, written before the plan
  plan.md           title, status, scope, sources, a phases table, a `## Decisions` section
  phase-*.md        one per phase, front matter first
```

- The plans root is `paths.plans` of the project config (default `plans`). The plan dir is the brief's dir: `plan.md` and the phases are written next to `brief.md`.
- The project root is found from the plan dir, not from the current directory: the nearest ancestor holding `.claude/metadata.json`, stopping before `$HOME`. A bare `.claude/` (agent memory inside a plan dir, for example) is not a root.
- A plan dir outside the plans root is a problem.
- Not supported: an absolute `paths.plans` outside the project, or a plans root reached through a symlink. The root is found from the plan dir's real path, so such a plan dir exits 2 ("no project root").
- `brief.md`, `plan.md` and every `phase-*.md` start with a `---` front matter block on line 1 (a UTF-8 BOM is fine). A phase file without one is a problem; `plan.md` and `brief.md` without one only warn. A symlink must resolve inside the plan dir, and a file is read only up to 512 KB.

## Fields

### Phase front matter

| Field | Meaning |
|---|---|
| `phase` | Phase id, `^[a-z0-9][a-z0-9-]{0,15}$` and unique in the plan. Falls back to the first dash segment of the file name (`phase-01a-x.md` gives `01a`). Ids are compared as written: `dependencies: [1]` does not name phase `01`. |
| `title`, `status`, `priority`, `size` | As in `output-standards.md`. `status` is `pending`, `in-progress`, `completed`, `cancelled` or `in-review`; another value warns (`status-unknown`). It is the source of truth for the phase (see Status lines). |
| `dependencies` | Phase ids this phase waits for; `[]` or `none` for no dependency. Each must name an existing phase, with no cycle. |
| `touches` | Paths or globs this phase changes. See the grammar below. |
| `acceptance` | Shell commands that prove the phase is done, run from the repo root. |
| `sources` | Source entries, a subset of the plan's `sources`. |

### Plan front matter

`sources` and `authoritative`, next to the usual `title`, `status`, `priority`, `scope`.

### Brief front matter

`id` (`^[a-z0-9][a-z0-9-]{0,39}$`), `sources`, `authoritative`, then a free-text body with a recommended `## Principles` section: the rules to decide by when sources conflict or nobody can answer.

Short lowercase ids are safe in branch and directory names on case-insensitive file systems.

## Sources

An entry is `"<role>: <type>:<locator>"`:

- role is one of `tracker`, `spec`, `design`, `context`;
- type matches `^[a-z][a-z0-9-]*$`;
- the locator is opaque to ADF.

Rules: a phase `sources` entry is also in the plan's `sources`; `authoritative` is one entry of the same file's `sources`; at most one `tracker` entry per sources list (the brief's, the plan's, or a phase's).

Quote every source entry. The plan front matter is also read by YAML parsers that choke on a bare `:` or a leading `*`.

## Touches grammar

A `touches` entry is a repo-relative POSIX path or glob:

- It is split on `/` into segments. A segment is one or more of `A-Z a-z 0-9 . _ @ + -`, plus `*`. A leading dot is fine (`.github/workflows/ci.yml`). Nothing else is allowed, so `!`, `~`, `:`, `$`, `|`, `;`, `&`, quotes, backticks, `=`, `%`, `#`, non-ASCII letters and control characters are all rejected.
- `*` matches within one segment. `**` is a whole segment and matches any number of segments (`src/**/*.cjs`; never `a**b`).
- No empty, `.` or `..` segment, so no `//`, `../x` or `./x`.
- No leading `/`, no backslash, no drive letter (`C:/x`), no braces, no `?`, no `[]`, no whitespace.
- A trailing `/` means the whole directory.
- At most 200 characters.

| Valid | Invalid |
|---|---|
| `src/cache.cjs` | `../x`, `/etc/hosts`, `C:/x` |
| `.github/**` | `src\win.cjs` |
| `test/**/*.test.cjs` | `src/{a,b}.cjs`, `a?.cjs`, `file[1].cjs` |
| `pkg/@scope/lib-1.0+x_y.md` | `a**b`, `my file.md` |
| `docs/` | `!src/x`, `~/x`, `$HOME/x`, `a\|b` |

When the plan has a `scope`, each `touches` static prefix (the segments before the first `*`) should sit under a `scope` entry; otherwise `--check` warns. `scope` entries are compared as paths, so a scope written as a workspace member or component name (`gateway`) warns for every phase. `touches` is the per-phase form of `scope`, and the file ownership that `--parallel` plans can use.

## Writing lists

`parseFrontmatter` keeps an inline list as one string and drops a trailing ` # comment` from every `- item`. So:

- Write `acceptance` as a **block list**, one command per line. An inline `[a, b]` splits on every comma, and `--check` warns (`acceptance-inline-list`).
- An `acceptance` command, a source or a path never contains ` #` (a space, then `#`).
- Write `sources` as a block list too: a comma inside a quoted item of an inline list splits it.
- Quote `sources` items, and any glob that starts with `*`.
- An inline list must close (`[a, b]`). `[a, b` is read as no list at all, so `--check` reports `list-malformed` for `dependencies`, `touches`, `acceptance`, `sources` and `scope`.
- `status: pending   # a | b` keeps its comment in the raw value; the reader strips it from `phase`, `status`, `priority` and `size`, never from `title`.

```yaml
acceptance:
  - node --test "test/**/*.test.cjs"
  - npm run lint
```

`node --test` followed by a directory argument (`test/`) fails on Node 24; `--check` warns (`node-test-dir`).

## Acceptance is executable content

An `acceptance` command is run by whoever executes the phase, so review it like code. ADF enforces no allowlist: an executor may restrict which commands it runs. `/cook` lists a phase's commands in its reply before it runs them.

## Decisions

`plan.md` records trade-offs under `## Decisions`: one `### <topic>` per decision, then four bullets.

```markdown
## Decisions
### Cache store for sessions
- Chosen: in-process LRU
- Alternatives: Redis; no cache
- Why: the brief says "no new infrastructure"
- Review later: yes
```

- `Alternatives` is split on `; `. `Review later` is `yes` or `no`. `None` is allowed for a plan with no decision.
- Another shape (prose, a numbered list) is **legacy**: warning `decisions-legacy`, and `plan.decisions` is `[]`. A `###` entry with a missing field or another `Review later` value is a warning that names the entry and the field. An absent section is a warning.
- Only `--require decisions` turns these into problems. `--check` alone never fails a plan that ADF's own writers produced.

## Conflicting sources

1. `authoritative`, when present, wins.
2. Otherwise, when someone can answer (an interactive session in strict mode), the planner may ask.
3. When nobody can answer (a headless run or auto mode), it chooses by the brief's principles and records the choice under `## Decisions` with `Review later: yes`, unless the task's instructions name another place.
4. It stops only when every option breaks a stated principle, or a required source cannot be read.

## Status lines

Whoever executes a phase sets its `status`. The change that completes the last phase, or the executor's own later commit, also sets `plan.md` `status: completed`. The phase front matter is the source of truth: the `plan.md` phases table is a summary, and `--check` warns (`status-table-mismatch`) when a row disagrees with its phase file.

## CLI

`--json` prints the export and `--check` prints problems and warnings as text; both use the same exit codes. Without a mode flag, `--check` runs. `--require` takes comma-separated field names matching `^[a-z][a-zA-Z0-9_-]*$` (another name exits 2) and makes them present and non-empty in every phase; callers may require fields ADF does not define. `decisions` is the one plan-level name it accepts. When any phase field is required, a plan with no phase files is a problem (`no-phases`), because "every phase has it" would hold for nothing. The caller decides what to require.

| Exit | Meaning |
|---|---|
| 0 | no problems (warnings allowed) |
| 1 | problems; they win over 3, so a brief-only dir with a bad brief id exits 1 |
| 2 | usage error, a dir that cannot be read, no `plan.md` or `brief.md`, or no project root; one line on stderr, nothing on stdout |
| 3 | `brief.md` exists but `plan.md` or the phases do not: "awaiting plan", not "invalid" |

With `--json`, a dir holding only `brief.md` returns `plan: null` and `phases: []`.

### Problems (exit 1)

`plan-dir-outside-root`, `file-unreadable`, `symlink-outside-plan-dir`, `frontmatter-missing` (phase files), `list-malformed`, `brief-id-invalid`, `phase-id-invalid`, `phase-id-duplicate`, `dependency-unknown`, `dependency-cycle`, `touch-invalid`, `source-invalid`, `source-tracker-duplicate`, `source-not-in-plan`, `authoritative-not-in-sources`, `required-missing`, `no-phases` (with `--require` of a phase field); with `--require decisions` also the decisions codes below.

### Warnings

`no-phases` (a single-file plan: `plan.md` and no `phase-*.md`), `frontmatter-missing` (`plan.md`, `brief.md`), `status-unknown`, `plan-line-too-long` (a `plan.md` line over 2000 characters is not read for the phases table), `touches-missing`, `acceptance-missing`, `touches-outside-scope`, `node-test-dir`, `acceptance-inline-list`, `status-table-mismatch`, `brief-id-missing`, `principles-missing`, `decisions-missing`, `decisions-legacy`, `decision-field-missing`, `decision-review-later-invalid`.

## JSON schema v1

Fields are only ever added within v1. Paths are absolute real paths (symlinks are resolved, as on macOS where the temp dir is under a `private` prefix). `adfVersion` is the installed ADF version, or `null` when `.claude/metadata.json` cannot be read. `status` is the value as written, lowercased: it is not mapped onto ADF's set, so check `status-unknown`. Each problem and warning is `{code, file, message}`; `file` is relative to the plan dir, or `null`. `reviewLater` is `true`, `false`, or `null` when the bullet is missing or malformed. `--check` prints control characters in plan values as `?`. The example is the `valid-full` fixture of the contract test, with `<root>` for the project root and `<adfVersion>` for the installed ADF version.

```json
{
  "schemaVersion": 1,
  "adfVersion": "<adfVersion>",
  "plansRoot": "<root>/plans",
  "planDir": "<root>/plans/session-cache",
  "brief": {
    "file": "brief.md",
    "id": "session-cache",
    "sources": ["tracker: github-issue:acme/app#12", "spec: file:docs/sessions.md"],
    "authoritative": "spec: file:docs/sessions.md",
    "principles": "- Prefer no new infrastructure.\n- Keep public APIs unchanged."
  },
  "plan": {
    "file": "plan.md",
    "title": "Session cache",
    "status": "in-progress",
    "priority": "P2",
    "scope": ["services/api"],
    "sources": ["tracker: github-issue:acme/app#12", "spec: file:docs/sessions.md"],
    "authoritative": "spec: file:docs/sessions.md",
    "decisions": [
      {
        "topic": "Cache store for sessions",
        "chosen": "in-process LRU",
        "alternatives": ["Redis", "no cache"],
        "why": "the brief says \"no new infrastructure\"",
        "reviewLater": true
      }
    ]
  },
  "phases": [
    {
      "file": "phase-01-store.md",
      "id": "01",
      "title": "Cache store",
      "status": "completed",
      "priority": "P1",
      "size": "S",
      "dependencies": [],
      "touches": ["services/api/src/cache.cjs", "services/api/test/**"],
      "acceptance": ["node --test \"services/api/test/**/*.test.cjs\""],
      "sources": ["spec: file:docs/sessions.md"]
    },
    {
      "file": "phase-02-wiring.md",
      "id": "02",
      "title": "Wire the cache into sessions",
      "status": "pending",
      "priority": "P2",
      "size": "M",
      "dependencies": ["01"],
      "touches": ["services/api/src/sessions.cjs"],
      "acceptance": ["npm test", "npm run lint"],
      "sources": []
    }
  ],
  "problems": [],
  "warnings": []
}
```
