# Documentation Triggers

## When to Update Docs

Must update project documentation in `./docs` when:

| Trigger | Which Docs | Action |
|---------|-----------|--------|
| Phase status changes | requirements/roadmap.md | Update progress %, milestone status |
| Major feature complete | requirements/roadmap.md, architecture/codebase-summary.md | Add feature, update architecture |
| Bug fix (significant) | requirements/roadmap.md | Document fix, severity, impact |
| Security patch | requirements/roadmap.md, architecture/system-architecture.md | Record improvement |
| API contract changes | architecture/system-architecture.md, conventions/code-standards.md | Update endpoints, schemas |
| Architecture decision | architecture/system-architecture.md | Document decision + rationale |
| Scope/timeline change | requirements/roadmap.md | Adjust phases, dates |
| Dependencies updated | architecture/system-architecture.md | Record version changes |
| Breaking changes | conventions/code-standards.md | Document migration path |

## Documentation Files

```
./docs
├── README.md                 # Map of the docs
├── requirements/             # prd.md, srs.md, roadmap.md, usecases/
├── design/                   # design-system/, mockups/, wireframes/
├── architecture/             # system-architecture.md, codebase-summary.md, decisions/
├── testing/                  # testcases/, test-summary.md, exports/
├── conventions/              # code-standards.md, deployment.md, <topic>.md
└── guides/                   # User-facing guides
```

## Update Protocol

1. **Read current state:** Always read target doc before editing
2. **Analyze reports:** Review agent reports in plan reports directory
3. **Update content:** Modify progress %, statuses, dates, descriptions
4. **Cross-reference:** Ensure consistency across docs
5. **Validate:** Verify dates, versions, references accurate

## Quality Standards

- **Consistency:** Same formatting, versioning across all docs
- **Accuracy:** Progress %, dates, statuses reflect reality
- **Completeness:** Sufficient detail for stakeholder communication
- **Timeliness:** Update within same session as significant changes
- **Traceability:** Clear links between roadmap items and implementation

## Delegation Pattern

Use `docs-manager` subagent for documentation updates:

```
Task(
  subagent_type: "docs-manager",
  prompt: "Update ./docs for [changes]. Work context: [path]",
  description: "Update docs"
)
```

Project manager coordinates WHEN to update; docs-manager handles HOW.
