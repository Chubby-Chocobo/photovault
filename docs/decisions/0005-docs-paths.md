# 0005 Spec paths for decisions, spikes and the sidecar schema

- **Status:** Accepted
- **Spec refs:** §12 (acceptance criteria name these paths)
- **Review trigger:** when the docs map (`docs/README.md`) is reorganized

## Context

The ADF layout puts decision records in `docs/architecture/decisions/` and tests in `docs/testing/`. The spec's acceptance criteria name `docs/decisions/`, `docs/spikes/`, `docs/sidecar-schema.md` and `docs/test-report.md`.

## Decision

Use the spec's paths. The spec is authoritative for this project. `docs/README.md` lists `decisions/` and `spikes/` as top-level folders.

## Consequences

- `docs/architecture/` holds the architecture documents and does not hold decisions.
- Any doc that points to `architecture/decisions/` must be corrected to `decisions/`.
