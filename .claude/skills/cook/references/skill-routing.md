# Skill Routing

Use this file only when choosing between installed ADF skills. For the order of
steps in a multi-step task, read `workflow-routing.md` after choosing the
primary skill.

## Routing Rules

- If the user names a skill, use that skill.
- Pick one primary skill per distinct intent. Mention secondary skills only as
  follow-up helpers.
- If two skills overlap, prefer the more specific domain skill over a generic
  workflow skill.
- If no row fits, compare the candidate skills' `when_to_use` lines in the
  skill listing.

## Planning, Requirements, and Delivery

| User intent | Primary skill |
|---|---|
| Debate architecture, stack, or feasibility | `/brainstorm-technical` |
| Shape a new feature into a spec | `/brainstorm-features` |
| Phased implementation plan | `/adf-plan` |
| Implement a feature or plan | `/cook` |
| Functional spec and use cases | `/specs` |
| Test cases from use cases, CSV/JSON export | `/test-cases` |
| Fix a concrete bug, error, or CI failure | `/fix` |
| Root-cause investigation without a fix yet | `/adf-debug` |
| Review a GitHub PR (duplicates, AI-slop, `--fix`, `--reply`) | `/review-pr <PR>` |
| Review a diff, commits or local changes | `/adf-code-review` |
| Ship: test, review, commit, PR | `/ship` |

## Frontend and UI

| User intent | Primary skill |
|---|---|
| Replicate a mockup, screenshot, or video | `/frontend-design` |
| Build React or TypeScript components | `/frontend-development` |
| Style with Tailwind or shadcn/ui | `/ui-styling` |
| Choose color, typography, or layout | `/ui-ux-pro-max` |
| Design tokens, component catalog, themes | `/design-system` |
| Clickable HTML mockups from requirements | `/design-mockup-create` |
| Brand identity, logos, banners | `/design` |
| Audit UI accessibility or UX | `/ui-ux-pro-max` |
| Apply React or Next.js performance patterns | `/react-best-practices` |
| Generate UI designs with Stitch | `/stitch` |
| Build 3D, WebGL, or Three.js scenes | `/threejs` |
| Write shaders or procedural graphics | `/shader` |

## Codebase Understanding

| User intent | Primary skill |
|---|---|
| Locate files or understand code quickly | `/scout` |
| Pack a repository for LLM use | `/repomix` |
| Semantic go-to-definition or find-usages | `/gkg` |
| Build a queryable knowledge graph | `/graphify` |

## Backend, Data, and Auth

| User intent | Primary skill |
|---|---|
| Build REST, GraphQL, or backend services | `/backend-development` |
| Add auth, OAuth, sessions, or passkeys | `/better-auth` |
| Design schemas or write SQL/NoSQL queries | `/databases` |
| Integrate Stripe, Polar, Paddle, or SePay | `/payment-integration` |

## Infrastructure and Security

| User intent | Primary skill |
|---|---|
| Deploy to hosted platforms | `/deploy` |
| Docker, Kubernetes, CI/CD, or cloud ops | `/devops` |
| STRIDE/OWASP audit with remediation | `/security` |
| Secret, dependency, or vulnerability scan | `/quality-gates` (quick scan) |
| Quality gates before review or push | `/quality-gates` |
| OSINT or cyber threat intelligence | `/cti-expert` |

## AI, MCP, and Browser Automation

| User intent | Primary skill |
|---|---|
| Context, memory, or agent architecture | `/context-engineering` |
| Generate `llms.txt` | `/llms` |
| Build Google ADK agents | `/google-adk-python` |
| Build MCP servers | `/mcp-builder` |
| Convert code into CLI/MCP surface | `/agentize` |
| Discover or execute MCP tools | `/use-mcp` |
| Test generic browser workflows | `/agent-browser` |
| Use the user's real Chrome profile | `/chrome-profile` |
| Analyze images, video, audio, or PDFs with AI | `/ai-multimodal` |

## Testing, Docs, and Media

| User intent | Primary skill |
|---|---|
| Run tests, coverage, or TDD gates | `/test` |
| Playwright, Vitest, k6, visual or a11y tests | `/web-testing` |
| Project docs init/update/summarize | `/docs` |
| Library/framework docs lookup | `/docs-seeker` |
| Visual explanation, preview, slides, or diagrams | `/preview` |
| Mermaid syntax | `/mermaidjs-v11` |
| Publish-grade technical diagrams | `/tech-graph` |
| Video/audio/image processing | `/media-processing` |
| HTML-template video rendering | `/html-video` |

## Frameworks and Platforms

| User intent | Primary skill |
|---|---|
| Next.js, App Router, RSC, Turborepo | `/web-frameworks` |
| TanStack Start/Form/AI | `/tanstack` |
| React Native, Flutter, SwiftUI, Kotlin | `/mobile-development` |
| Shopify apps, extensions, or themes | `/shopify` |
