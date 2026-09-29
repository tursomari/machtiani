# Installer backend catalogue

This catalogue records facts learned and verified during development and IXE
runs. Use it to accelerate discovery, not to suppress investigation. The
installed CLI and a successful current health probe outrank stale catalogue
assumptions. An agent absent from this file may still be usable through the
custom-backend path.

A version-specific setup helper is not a bundled backend binary. Standard
supplies Dear Machine, Machtiani, and their runtime tools; this catalogue and
the presence of a Forge preparation helper do not mean Forge, Codex, OMP, or Claude Code
has been downloaded or installed. If discovery found none, say so. Do not
promise an offline or local installation unless you have verified an
accessible existing backend artifact; otherwise use the selected guide's
official acquisition route after installation consent.

Recommend from verified facts about the human's requirements. Subscription
login is an option, not a requirement for Codex or OMP: both also support API
credentials as documented below. Forge's verified OpenRouter route can be a
reason to recommend it without inventing restrictions on the other agents.

| User-facing agent | Executable | Dear Machine backend ID | Canonical GitHub repository | Official site or documentation entry point | Preferred Nix source | Known authentication path | Selected-agent guide |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Codex | `codex` | `codex-yolo` | `https://github.com/openai/codex` | `https://developers.openai.com/codex/cli/` | the reviewed `dearmachine#codex-tool` output in this umbrella checkout | ChatGPT subscription login or supported API credentials | `docs/installation/backends/codex.md` |
| Forge | `forge` | `forge` | `https://github.com/tailcallhq/forgecode` | `https://forgecode.dev/docs/` | `github:tailcallhq/forgecode#forge` | Provider credentials supported by the installed Forge CLI | `docs/installation/backends/forge.md` |
| OMP | `omp` | `omp` | `https://github.com/can1357/oh-my-pi` | `https://omp.sh/docs` | `github:can1357/oh-my-pi#omp` | ChatGPT subscription login or providers supported by the installed OMP CLI | `docs/installation/backends/omp.md` |
| Claude Code | `claude` | `claude` | `https://github.com/anthropics/claude-code` | `https://code.claude.com/docs/en/setup` | Use the official native installer; no additional Nix source prescribed | Provider-owned login or supported private API credentials | `docs/installation/backends/claude.md` |

Treat the repository owner and project name in this table as a security
boundary for a new installation. A similarly named repository, package, fork,
advertisement, or search result is not a substitute. The official site and
documentation links are starting points that give the installer an edge; they
do not replace inspecting the current canonical repository, its Nix flake, the
installed CLI, or its observed behavior. If a canonical source cannot be
reached or its ownership cannot be established, stop rather than installing
from an unverified alternative.

The Nix source names above are product-specific. In particular,
`nixpkgs#forge` is not ForgeCode and must never be used to install this
catalogue entry.
They apply to a Nix installation, not to the Standard (Nix-free) path. Follow
Stage 4 and the selected guide for official direct-install routes; never
introduce Nix merely because this table records a preferred Nix source.

The internal `codex-yolo` identifier is configuration, not a user-facing
product name. Present it simply as Codex. Do not characterize it as unsafe.
Codex, Forge, OMP, and Claude Code can make changes on the human's behalf and should be
described consistently using the canonical language in `INSTALL.md`.

When an IXE establishes a dependable new executable name, authentication path,
automation mode, or compatibility constraint, update this catalogue or the
relevant selected-agent guide. Keep observations version-aware and retain the
general instruction to inspect current CLI behavior.
