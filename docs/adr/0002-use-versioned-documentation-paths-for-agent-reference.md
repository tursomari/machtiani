# ADR: Use Versioned Documentation Paths for Agent Reference

## Date

2026-09-07

## Status

Accepted

## Context

Dear Machine's installer and management concierge need authoritative product
guidance about Dear Machine, Machtiani, the installer, and their shared runtime.
That guidance is also useful to maintainers, contributors, operators, and other
automation. It should therefore be developed as product documentation in its
own right, rather than as knowledge owned by a particular conversational
interface.

Several ways of exposing documentation to an agent are possible:

1. Add documentation-specific commands or model tools that list and return
   documentation topics.
2. Copy or generate a separate runtime documentation bundle for the
   concierge.
3. Embed substantial product manuals directly in role system prompts.
4. Keep one organized body of ordinary documentation in the versioned source
   snapshot and give each agent its filesystem entry-point path.

The first three approaches introduce another interface, representation, or
copy whose behavior and content must remain synchronized with the canonical
documentation. They also make general product documentation subordinate to
the needs of one model integration.

The umbrella repository already defines a coherent product version: its commit
pins the Dear Machine, Machtiani Harness, and Machtiani Installer submodule
commits. Documentation stored in that source history can therefore describe
the same composite version as the implementation and tests.

Documentation describes intended and supported behavior. Observed runtime
state remains authoritative for facts about the current machine. Source code
and tests provide deeper implementation evidence when documentation is
ambiguous, incomplete, or inconsistent with observed behavior.

## Decision

Maintain the canonical Dear Machine and Machtiani documentation as ordinary,
human-readable files in the versioned umbrella source snapshot and its pinned
submodules.

Provide one stable documentation entry point by filesystem path. The umbrella
documentation entry point will be `docs/README.md`; it will organize and link
to the relevant umbrella and pinned-component documentation. Runtime context
may supply its absolute path, the corresponding source root, and the installed
umbrella revision. These values are references, not copies of the
documentation.

The installer, concierge, humans, and development agents use the same
documentation tree through their ordinary file-reading capabilities. We will
not add documentation-specific CLI commands, model tools, service endpoints,
generated runtime bundles, or concierge-owned documentation copies.

Role prompts contain only the stable policy for using this reference:

1. Consult the canonical documentation first and follow links from its entry
   point to material relevant to the current task.
2. Inspect runtime state for claims about what is currently configured or
   running on the machine.
3. Inspect source code and tests only when documentation needs clarification,
   observed behavior conflicts with documented behavior, or a likely defect
   requires diagnosis.
4. Distinguish documented intent, observed state, and implementation evidence
   whenever they disagree.

The source path and revision used for installation must be retained as
non-secret installation metadata so the concierge can be given the correct
documentation entry point. The concierge must not assume that an unrelated
working directory is the product source tree.

## Consequences

**Positive**

- Product documentation remains useful independently of the concierge or any
  particular model provider.
- Humans and agents share one reviewed source of intended behavior.
- Git history and umbrella submodule pins naturally version documentation with
  the composite product.
- No synchronization mechanism is needed between repository documentation,
  system prompts, a documentation API, and a runtime copy.
- System prompts remain smaller and more stable for provider-side prefix
  caching.
- Source and tests remain available as a precise fallback without displacing
  documentation as the normal entry point.

**Negative**

- Concierge documentation access depends on the recorded source snapshot
  remaining readable at its retained path.
- Moving or removing that snapshot can make extended documentation unavailable
  until the path is restored or explicitly updated.
- Documentation structure and links must be maintained as a real public
  interface.

**Neutral**

- Missing documentation does not disable deterministic local lifecycle and
  status controls.
- A future requirement for source-independent documentation distribution would
  require a new decision rather than an implicit synchronized copy.
- This decision does not make documentation a substitute for observing current
  machine state.
