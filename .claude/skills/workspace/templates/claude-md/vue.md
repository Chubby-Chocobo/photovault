# {{name}}

`{{name}}` is a component of {{product}} (role: {{role}}, stack: {{stack}}).

This is a starter file. Edit it as the component changes; scaffolding never overwrites it.

## Commands

{{commands}}

## Do not edit

Generated directories, rebuilt by the tools:

{{generatedDirs}}

Vendored directories, changed in their own repository:

{{vendoredDirs}}

## Vue notes

- Keep components small; move shared state and API calls out of components.
- Calls to backend services go through one API layer, so a contract change touches one place.
- Contracts shared with other components (OpenAPI, events) change in their own repository, then here.
- Check a UI change in the browser before calling it done.

## System context

Paths below are relative to the root of the workspace or monorepo, not to this component.

- Docs for this component: `{{docs}}/architecture/services/{{name}}.md`
- System map (components, calls, contracts): `{{docs}}/architecture/system-map.json`
- System architecture: `{{docs}}/architecture/system-architecture.md`
- Conventions and code standards: `{{docs}}/conventions/`

Changes that touch another component or a contract start from a plan in the workspace.
