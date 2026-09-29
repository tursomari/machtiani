# ADR: Umbrella Project Pattern

## Date

2026-08-19

## Status

Accepted

## Context

The maintainer needs a single home for two related projects, DearMachine and Machtiani. The candidate arrangements are a monorepo, fully distinct projects, or an umbrella repository that pins the projects as git submodules.

1. **Preserving the network effect.** The projects share one network and one audience. We do not want to disperse that network or split the audience; a single shared home benefits users of both projects.

2. **Per-project development isolation.** Separate version histories give each project its own branches, history, and release cadence. Working on one project is easier when it cannot disturb the other.

3. **Cost of the umbrella.** An umbrella repository adds management complexity, but it is a simple thing that composes and is cryptographically coherent through pinned submodule commits. Human developers on average struggle with git submodules because git is hard for them; agents have no such issue and will follow explicitly defined management rules.

4. **Contributor focus.** Contributors find the arrangement easier because they can focus on the single project they actually care about rather than navigating a combined tree.

5. **Maintainer preference.** The maintainer enjoys the elegance of umbrella repositories and enjoys helping unblock anyone having honest difficulties using one at that level.

## Decision

Use a git-submodule umbrella repository, over a monorepo and over fully distinct projects.

- **Umbrella over monorepo.** A monorepo would couple the two projects' histories and make per-project isolation and focused contribution harder. The umbrella keeps the histories separate while still sharing one repository and audience.
- **Umbrella over fully distinct projects.** Fully distinct projects would disperse the network effect and split the audience. The umbrella preserves a single shared home.

The umbrella records each submodule's pinned commit, making the composite state cryptographically coherent and explicit.

## Consequences

**Positive**

- One shared network and audience across both projects.
- Independent version histories and per-project development isolation.
- Contributors only need to engage with the project they care about.

**Negative**

- The umbrella adds management complexity around submodule pointers.
- Git submodules are a known pain point for human contributors who are less comfortable with git; this cost is mitigated by explicitly documented management rules.

**Neutral**

- Management rules live in `docs/umbrella-runbook.md`.
- Submodule pointer bumps are explicit release decisions and must never be hidden in unrelated work.
