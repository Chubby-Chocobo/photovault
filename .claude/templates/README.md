# ADF templates

Starters that the installer copies into a project once. After the copy, the file belongs to the project. This folder is ADF's and is replaced on update; edit the copies, not these.

## `docs/`

- Each file under `templates/docs/` is seeded to the same path under the project's docs root, which is `paths.docs` in `.claude/config/adf-config.json` and defaults to `docs`. For example, `templates/docs/README.md` becomes `docs/README.md`.
- A file is seeded only when it is missing. A seeded file the project later deletes is not recreated. The installer remembers it in `.claude/.adf-manifest` under `seededDocs`.
- Each seeded copy carries `adf-template: <template path>@<hash>`. When the template changes, the installer prints a note naming the file to compare. It never overwrites the project's copy.

## Rules for template authors

- **Keep templates neutral.** No ADF-specific names, repos, version files or processes. Lint enforces this.
- **ADF's own `docs/` folder is not a template.** It documents the development of ADF and is never shipped.
- **Generation templates stay with their skill.** A template that a skill fills in to produce a document, such as `specs/references/templates/srs-template.md`, lives inside that skill. Only starters that the project edits by hand belong here.
