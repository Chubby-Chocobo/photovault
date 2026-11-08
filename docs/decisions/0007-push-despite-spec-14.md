# 0007 Push the feature branch and open a PR despite spec §14

- **Status:** Accepted (owner instruction)
- **Spec refs:** §14 ("Không commit secret, không push")
- **Review trigger:** none; the owner set this scope

## Context

Spec §14 says the agent does not push. The owner explicitly asked for the GitHub remote to be set up and for the change to ship through the release flow.

## Decision

Push the feature branch and open a PR into `release/0.1.0`. Merge with squash. The release-to-main step is outside this run.

## Consequences

- The code and docs are on GitHub. Secrets must stay out of git: `Config/Secrets.xcconfig` and `Config/Local.xcconfig` are gitignored, and only their `.example` templates are tracked (`.gitignore`).
- The spec §14 rule still applies to any later agent run that was not given this instruction.
