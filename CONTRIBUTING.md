# Contributing to Machtiani

Machtiani is an umbrella repository with three independently versioned components:

- `machtiani-harness`: the agent runtime and its Go tools.
- `dearmachine`: email transports, lifecycle, and Agent Manager.
- `dearmachine-concierge`: installation, provider setup, and the terminal interface.

Clone with `git clone --recurse-submodules <repository-url>`. Start with
[the documentation entrypoint](docs/README.md) and [the testing guide](TESTING.md).
Make a component change in that component's repository. An umbrella change that
depends on it must record the exact component commit.

Use a feature branch and make small commits describing the problem and resulting
behavior. Include the checks you ran and any remaining validation gaps in the
pull request. Report defects with reproduction steps, expected and observed
behavior, operating system, and component revisions. Remove credentials and
private email or project content from examples and logs.

The [development runbook](docs/parallel-development-runbook.md) specifies local
worktree setup, signing, verification, and rebase/fast-forward landing. The
[umbrella runbook](docs/umbrella-runbook.md) defines component pin updates and the
maintainer's publication boundary. Preserve unrelated local work and stage only
reviewed paths. Do not commit runtime state, credentials, build outputs, or
host-specific notes.

Run the credential-free checks for the owning component first. Live email,
subscription, and installation evaluations use disposable resources and their
own documented authorization and cleanup procedures. A passing unit suite does
not substitute for a required release evaluation.

Machtiani's first-party code is distributed under the MIT license in each
repository. Preserve third-party license and attribution notices.
