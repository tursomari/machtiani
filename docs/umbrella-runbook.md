# Umbrella maintenance runbook

## Purpose and audience

This public runbook defines how the maintainer and maintenance agents keep the umbrella repository reproducible, reviewable, and ready for release.

## Layout and pinned revisions

The default branch is `main`. The umbrella contains exactly three submodules:
`dearmachine/`, `machtiani-harness/`, and `dearmachine-concierge/`. It records an
exact commit for each submodule; `git submodule status` is the source of truth
for the current pins, so this document does not list commit IDs.

The canonical DearMachine source is the `dearmachine/` submodule in the machtiani umbrella. Standalone DearMachine checkouts made before the umbrella are retired.

Make submodule changes on branches inside the affected submodule. An umbrella checkout can legitimately leave a submodule in detached HEAD state when its recorded pin differs from the submodule's `main` tip.

## Two-commit rhythm

1. Commit the change on a branch inside the affected submodule.
2. Bump the umbrella pointer with `scripts/update-submodules.sh`, or with `git submodule update --remote` followed by explicit review, path-specific staging, and an umbrella commit.

A pointer bump is an explicit release decision and must never be hidden in unrelated work. Do not create empty commits. Use concise, informative commit messages.

## Development pairing for in-flight feature branches

When umbrella-side changes (for example Installation Procedure tests) depend on a
submodule feature branch that has not landed on a submodule `main` yet,
do not commit them on an umbrella branch whose gitlinks point at unrelated
commits. Instead create a paired development branch on the umbrella named
`wt/<name>` matching the submodule worktree name:

1. Base the umbrella branch on the umbrella `main`.
2. Include the umbrella-side changes and the gitlink updates to every
   dependent submodule branch tip in the same branch. A staged tree whose
   gitlinks do not point at the dependent worktree branch tips is out of
   tune and must be corrected before commit.
3. Such paired branches are local-only and are never pushed, because their
   gitlinks may reference commits absent from any published remote.
4. At landing time, first land and publish each submodule branch (see
   `docs/parallel-development-runbook.md`), then re-point the paired
   branch's gitlinks to the published submodule commits before it may be
   considered publishable.

## Authority boundary

Agents may perform all local work: submodule edits, local commits, locally available pin bumps, umbrella file edits, and verification. Agents never synchronize with, push to, or publish to any remote service. Those actions belong exclusively to the maintainer and require explicit authorization.

Agent work is complete when the intended local state is verified, free of unrelated tracked changes, and left staged or committed for the maintainer. Any network-facing step implied by an update command remains the maintainer's responsibility.

## Safety and signing

- Never rewrite history, including to add signatures to existing commits.
- Never mass-stage with `git add .` or `git add -A`. Stage only explicit, reviewed paths and inspect `git diff --cached` before committing.
- Preserve pre-existing untracked artifacts and do not commit them.
- Sign every new commit according to the project's signing configuration. Pre-existing unsigned commits are historical and remain unchanged.

## Local update script

`scripts/update-submodules.sh` discovers the submodule paths from `.gitmodules`,
initializes them recursively, refreshes their configured upstream tracking
references, advances their checkouts to the locally resolved default-branch
tips, stages changed gitlinks, and creates one umbrella pointer commit. It
refuses dirty tracked submodule worktrees and creates no commit when no pin
changed.

The script validates only against locally configured upstream information. Confirming that every pin exists at the canonical publication location belongs to the maintainer's publish step, not to the script or an agent.

## User-facing lifecycle

For a first clone:

```bash
git clone --recurse-submodules <umbrella-url>
```

For an existing clone:

```bash
git submodule update --init --recursive
```
