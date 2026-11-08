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

## Foundry notes

- Run the tests before changing a public function, an event or the storage layout: other components depend on the ABI.
- Every contract change needs a test that fails without it.
- Deployment scripts and addresses are recorded with the deploy, not guessed from a past run.
- ABIs and addresses shared with other components change in their own repository, then here.

## System context

Paths below are relative to the root of the workspace or monorepo, not to this component.

- Docs for this component: `{{docs}}/architecture/services/{{name}}.md`
- System map (components, calls, contracts): `{{docs}}/architecture/system-map.json`
- System architecture: `{{docs}}/architecture/system-architecture.md`
- Conventions and code standards: `{{docs}}/conventions/`

Changes that touch another component or a contract start from a plan in the workspace.
