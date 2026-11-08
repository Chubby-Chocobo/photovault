# Workspace files

Two JSON files, one source per fact. Hooks read them without dependencies. Messages from the loaders name the field, never the value.

## `adf-workspace.json` (workspace root)

Its presence makes the project a workspace. It holds membership, member repos and the bootstrap data.

```json
{
  "version": 1,
  "client": "tcx",
  "product": "tcx",
  "org": ["acme", "tcx-client"],
  "repo": "https://github.com/acme/tcx-workspace",
  "roleDirs": ["services", "apps", "contracts", "infra"],
  "members": [
    {
      "name": "order",
      "path": "services/order",
      "repo": "https://github.com/acme/tcx-order.git",
      "branch": "develop",
      "git": { "flow": "off", "enforcement": "ask", "mainBranch": "develop" }
    }
  ]
}
```

| Field | Rule |
|---|---|
| `version` | `1` |
| `client`, `product`, member `name` | `^[a-z0-9][a-z0-9-]{0,62}$`; names and paths are unique |
| `org` | Non-empty array of unique owner names: the trusted owners. `check` warns on a member whose repo owner is not listed |
| `repo` | The workspace's own remote in canonical form `https://host/owner/name`, no credentials |
| `roleDirs` | Optional; unique names matching `^[a-z][a-z0-9-]{0,30}$`; default `services`, `apps`, `contracts`, `infra`. `docs`, `plans`, `worktrees` are reserved. `init` writes the list explicitly |
| member `path` | Exactly `<roleDir>/<dir>`, posix, one of `roleDirs` |
| member `repo` | A remote URL, a `file://` URL or an absolute path; never credentials, never a leading `-` |
| member `branch` | Optional branch name |
| member `git` | Required: `flow` is `release-train`, `trunk` or `off`; `enforcement` is `off`, `ask` or `deny`; `mainBranch` is a branch name |

Unknown keys warn, they do not fail. The manifest keeps one canonical URL per repo; `bootstrap --protocol ssh|https|auto` picks the clone protocol, and `auto` follows the workspace's own `origin`.

## `docs/architecture/system-map.json` (under `paths.docs`)

Components, roles, transports and contracts. Valid in a monorepo and in a workspace.

```json
{
  "version": 1,
  "archetype": "exchange",
  "roles": { "frontend": ["fe", "web", "frontend", "interface", "ui"] },
  "components": [
    {
      "name": "order",
      "member": "order",
      "role": "backend",
      "stack": "nestjs",
      "calls": [{ "to": "matching-engine", "via": "kafka", "topic": "orders.new" }],
      "consumes": ["tcx-proto"]
    }
  ],
  "contracts": [{ "id": "tcx-proto", "kind": "proto", "member": "tcx-proto" }]
}
```

### The `member` join

- In a workspace, components and contracts carry `member` (an existing manifest member) and an optional `subpath` inside it. The loader derives `path` and `repo` from the manifest; stored `path`, `repo` and `org` are ignored with a warning.
- In a monorepo (no manifest), components carry `path`; contracts carry `path` and an optional `repo` for a contract kept in another repo. `org` is read from the map.
- Callers are derived (the inverse of `calls`) and never stored.

### Rules

- Component names and contract ids match the name pattern above and are unique.
- `calls[].to` names a component; `via` is `grpc`, `rest`, `kafka`, `amqp`, `websocket`, `db` or `other`.
- `consumes` and `produces` name contract ids; `kind` is `proto`, `openapi`, `asyncapi`, `json-schema`, `abi`, `graphql` or `other`.
- **Strings that are later printed** (`role`, `stack`, `topic`, `subpath`, `path`, `client`, `product`, role aliases) must match `^[A-Za-z0-9][A-Za-z0-9 ._/:@-]{0,120}$` and must not contain `--`. This excludes `<`, `>`, newlines and control characters.

### Archetypes

`archetype` is optional: a name (same pattern as component names) written by `init --archetype <id>` or `seed-map --archetype <id>`, which also merge the archetype's role aliases into `roles` (existing aliases stay). A shipped archetype is a file in `templates/archetypes/<id>.json`:

```json
{
  "id": "nest-service-monorepo",
  "description": "A NestJS service monorepo: ...",
  "roles": { "backend": ["service", "worker"], "gateway": ["gateway"] },
  "expectedRoles": ["gateway", "backend"],
  "expectedContractKinds": ["proto", "openapi"]
}
```

`id` equals the file name; `roles` maps a role to name aliases; `expectedContractKinds` are system-map contract kinds. `check` prints, as information and with exit code unchanged, each expected role no component has, and a note when no contract has one of the expected kinds. An `archetype` id this ADF does not ship is a warning. An id with path characters is refused by the loader and fails map validation.

| Archetype | Roles it adds | Expected roles | Expected contract kinds |
|---|---|---|---|
| `exchange` | gateway: gateway, gw; auth: auth, iam, sso; backend: order, trading; engine: matching; admin: admin, backoffice | gateway, auth, backend, engine, frontend, admin, mobile, infra | proto, json-schema |
| `nest-service-monorepo` | backend: service, worker; gateway: gateway | gateway, backend | proto, openapi |

### Roles

A component name maps to a role by its last `-` segment first, then the whole name; no match is `unknown`. `seed-map` then falls back to the detected stack. A map with its own `roles` replaces these defaults entirely.

| Role | Aliases |
|---|---|
| frontend | fe, web, frontend, interface, ui |
| backend | be, api, backend, service, server |
| smart-contract | sc, contracts, contract |
| engine | engine, matching-engine |
| mobile | mobile, app, ios, android |
| infra | infra, devops, deploy |
| bot | bot |
| sdk | sdk, lib, libs |

| Stack (detected) | Marker | Fallback role |
|---|---|---|
| nestjs | `@nestjs/core` in `package.json` | backend |
| react-native | `react-native` | mobile |
| vue | `vue` or `nuxt` | frontend |
| maven | `pom.xml` | backend |
| foundry | `foundry.toml` | smart-contract |
| python | `pyproject.toml`, `requirements.txt` | backend |

## Generated blocks

`init` keeps two managed blocks derived from `roleDirs`; edit `roleDirs` and re-run `init` to update both. A block with damaged markers is reported and left alone.

| File | Lines per role dir | Purpose |
|---|---|---|
| `.gitignore` | `/<roleDir>/`, plus `worktrees/` | Members are never committed into the workspace repo |
| `.ignore` | `!/<roleDir>/` | Grep skips gitignored paths; this lets it search members from the root |

## Member back-reference

`workspace.cjs sync` lets a member repo know it belongs to a workspace. It writes a marker at the member root (workspace only) and a generated block into each component's `AGENTS.md` and `CLAUDE.md` (workspace and monorepo). It writes files and never commits, pushes or opens a PR; commit the result through the member's normal flow (`workspace.cjs repos --changed` lists the members that changed).

### `.adf-workspace.json` (member root, committed)

```json
{
  "adf": 1,
  "workspace": "https://github.com/acme/tcx-workspace",
  "host": "github.com",
  "org": ["acme", "tcx-client"],
  "client": "tcx",
  "product": "tcx",
  "component": "order"
}
```

| Field | Rule |
|---|---|
| `adf` | `1`. A file of this name without `"adf": 1` is not ADF's: `sync` keeps it and warns |
| `workspace` | The manifest's top-level `repo`, canonical. Without it `sync` writes the block but no marker |
| `host` | Host of `workspace`; `attach` accepts only a URL on this host |
| `org` | A copy of the manifest `org`: the owners `attach` trusts. Both the URL owner and the member's own `origin` owner must be listed |
| `client`, `product` | Copied from the manifest when set |
| `component` | The member's main component: the one at the member root, else the first. Names the member in session lines and `attach` checks |

`sync` writes the marker when it is missing and rewrites it when it is ours (`"adf": 1`) and differs from what the manifest gives. A member with several components gets one marker.

### System context block (component `AGENTS.md` and `CLAUDE.md`)

Codex, Cursor and Copilot read `AGENTS.md`; Claude Code reads `CLAUDE.md`. Both files carry the same block, except that a `CLAUDE.md` with the line `@AGENTS.md` (or `@./AGENTS.md`, in its first 200 lines) imports the `AGENTS.md` and gets none. `sync` removes a block left in such a `CLAUDE.md` (an edited one needs `--force`). The row reports `block: "current"` unless that leftover block is stale, edited or damaged: then it reports `stale` or `edited` and `--check` fails, as it would without the import. An import line inside a fenced code block does not count. Between `<!-- adf:system-context begin -->` and `<!-- adf:system-context end -->`. Text outside the markers is never touched, line ends included. The first line inside is the stamp:

```
<!-- adf:system-context v=2 source=0123456789ab hash=0123456789abcdef -->
```

- `v`: block format version. A different version is `outdated` and `sync` rewrites it without `--force`.
- `source`: first 12 characters of the workspace commit, `-dirty` when the map has uncommitted changes, `unknown` outside git. Informational: it never decides a state.
- `hash`: first 16 hex digits of the SHA-256 of the bullets (the `- ` lines, `\r` removed), the fixed ones included, so editing a safety line by hand reads `edited`. The heading, the generated-from sentence and the `Workspace repo:` line are not hashed, so an ssh or https clone and wording changes do not make a block stale.

The bullets, each value in backticks: `Product`, `Client`, `Component` (role, stack), `Called by (derived)`, `Calls` (transport and topic), `Consumes`, `Produces`, `System doc` (`<docs>/architecture/services/<name>.md`). Lists are sorted. Four fixed bullets follow: `Safety` (never read or print `.env*` files, templates such as `.env.example` excepted, keys or credentials; ask before destructive commands; no `--no-verify`; stop and tell the user when a hook refuses a commit or push), `Git` (stage files by name; never force-push the main branch or a `release/*` branch), `PR base` (in a workspace the `git-flow.cjs status --cwd <member path>` command and the member's row in the workspace `git-workflow.md`; in a monorepo `git-flow.cjs status` and `git-workflow.md`) and `Rules` (the workspace repo's or the root `AGENTS.md`). The renderer checks every value against the system-map text rules again and fails the whole run on a value that does not pass, so a map that skipped `check` cannot put text into an instruction file.

| State | Meaning | `sync` | `--check` |
|---|---|---|---|
| `missing` | no block (the file exists) | appends it | fails for `CLAUDE.md`; for `AGENTS.md` only when `CLAUDE.md` imports it or is absent, and never when the file holds only ADF's installer block |
| `current` | stamped hash equals the hash of the freshly derived lines | nothing | passes |
| `stale` | block untouched, but the map changed | replaces it | fails |
| `edited` | bullets differ from their stamped hash, a line was added that the renderer does not produce, the stamp is unreadable, or the markers are damaged | skips; `--force` replaces (never with damaged markers) | fails |
| `outdated` | stamp `v` is not the current version (a v=1 block from an earlier release) | replaces it | passes |

A component with neither file is reported `no CLAUDE.md (run workspace.cjs scaffold)`; `sync` never creates one, but still writes the member's marker. An absent `AGENTS.md` is reported `agentsBlock: "n/a"`; a symlinked one is skipped and reported `agentsBlock: "symlink"` (the row's `action` and `reason` are not affected; the file it points to gets the block through `CLAUDE.md`). A member whose `CLAUDE.md`, `AGENTS.md` or marker has uncommitted changes is skipped as a whole (`uncommitted changes`) unless `--force`.

`sync --json` rows keep `member`, `component`, `path` (the `CLAUDE.md`), `block`, `marker`, `action`, `files` and `reason` with their earlier values; `block` is one of `missing`, `current`, `stale`, `edited`, `outdated` or null. `paths: { claude, agents }` and `agentsBlock` (those states, `n/a`, `symlink` or null) carry everything about `AGENTS.md`. `--check` also fails when a marker is missing or differs from the manifest.

### Session start

- Workspace or monorepo: `System context: 2 member blocks stale (order, gateway); run workspace.cjs sync` for blocks that are missing, stale or edited, in the file that holds them (a `CLAUDE.md` that imports `AGENTS.md` is reported only while it still holds a stale or edited block of its own).
- Member with its own ADF: if `.claude/settings.local.json` lists the workspace in `permissions.additionalDirectories`, a stale block gives `System context block is stale; run /workspace sync in the workspace at <dir>`. Otherwise the line is `Member "order" of workspace tcx: <url>`, the URL only. A member without its own ADF gets no warning (settings are not inherited), and its block is static text.

### `attach`

`workspace.cjs attach <url> [--dir <path>] [--dry-run] [--yes]`, run inside a standalone member. It refuses a URL with credentials, a query or fragment, or a leading `-`, any URL that is not https or ssh, and any URL whose host differs from the marker's `host` or whose owner, or the owner of the member's `origin`, is not in the marker's `org`. It clones next to the member (`git clone -- <url> <dir>`), checks that the workspace lists this repo, prints the exact `settings.local.json` change, and with `--yes` adds the workspace path to `permissions.additionalDirectories`. `additionalDirectories` gives file access only; it loads no `CLAUDE.md` or skills. Loading the workspace `CLAUDE.md` takes `--add-dir` plus `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1`: do that only for a workspace you trust.

## Example: TCX

`services/{order,gateway,core,matching-engine,trading,market}`, `apps/admin-web`, `contracts/tcx-proto`. After `init` the map holds `order` (backend, nestjs), `matching-engine` (engine, maven), `admin-web` (frontend, vue), the contract `tcx-proto` (proto), and `consumes: ["tcx-proto"]` on `order`, `gateway` and `core`, read from their `.gitmodules`.
