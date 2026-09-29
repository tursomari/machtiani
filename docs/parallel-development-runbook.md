# Parallel development runbook

## Purpose and audience

This runbook is for concurrent agents working from one machtiani umbrella
checkout on a target submodule: `machtiani-harness`, `dearmachine`, or
`dearmachine-concierge`. An agent is given the umbrella path, the target
submodule, a worktree name, and the location of this runbook. Everything the
agent does is local.

## Invariants

1. Work happens in a linked worktree beneath `${TMPDIR:-/tmp}`, not in the umbrella repository or the submodule's primary checkout.
2. Development Git operations run on the host. QSE may use disposable Git repositories reconstructed from committed object exports as described below.
3. Containers receive isolated source snapshots. QSE may additionally receive the selected commits and their trees to exercise real cloning and submodule pins. Never mount `.git`, `.git/modules`, the umbrella tree, canonical repositories, `~/.ssh`, agent sockets, other git projects, or any shared path between git projects.
4. Commit incrementally using the target submodule's history style. Inspect
   recent `git log` subjects first: `machtiani-harness` mixes `type(scope):`
   and `type:` prefixes, `dearmachine` uses short `feat`, `fix`, and `docs`
   subjects, and `dearmachine-concierge` uses conventional `type:` subjects.
5. Stage explicit paths only. Never use `git add .` or `git add -A`.
6. Sign every commit according to the repository's signing configuration.
7. NEVER, EVER run `git push` against any remote or from any repository.
8. Ask the user whenever a conflict resolution is not clear.

## Phase 1 — worktree setup

From the umbrella repository root, run the versioned setup helper on the host:

```bash
./scripts/worktree-setup <submodule-path> <worktree-name>
```

The helper resolves the base from the revision pinned by the umbrella's `HEAD:<submodule>` entry, not from the submodule's possibly drifted `HEAD`. It creates branch `wt/<worktree-name>`, a linked worktree beneath `${TMPDIR:-/tmp}`, and a sibling sidecar at `<worktree-path>.base`. The sidecar records the base OID, worktree name, and absolute submodule path.

The optional `--guard` flag installs a pre-push guard only for that worktree. It is off by default and is skipped unless the submodule already has `extensions.worktreeConfig` enabled; the helper never changes shared configuration. The helper also refuses Git's known-broken partial migration in which `extensions.worktreeConfig` is enabled but `core.worktree` was not moved out of the common config as required by `git-worktree(1)`. Do not enable the extension merely to get the guard. The no-push rule applies whether or not the guard is active.

## Phase 2 — work

Work and commit incrementally in the submodule's existing message style. Stage only named paths, inspect the staged diff, and never create an empty commit:

```bash
git -C "$wt" add path/to/file another/path
git -C "$wt" diff --cached
git -C "$wt" commit -m "<concise subject>"
```

The temporary directory is volatile, so commit useful work often. Signed local commits are the durable checkpoints until the branch is landed.

## Phase 3 — test and run

Development Git commands and Nix checks run on the host. If a non-Nix test needs a container, copy an isolated source snapshot into a disposable context. QSE may also receive freshly generated object packs containing only the chosen commit and its complete tree for each recursively pinned repository. It reconstructs fresh shallow local origins and configuration inside the container; no host Git administration, reflogs, hooks, remotes, history, or credentials are transferred. Never expose host `.git`, `.git/modules`, the umbrella checkout, a canonical repository, `~/.ssh`, agent sockets, another git project, or shared project mounts to the container.

Use the umbrella [`TESTING.md`](../TESTING.md) to choose the owning component
entrypoint and any affected cross-product gate. Each submodule's root
`TESTING.md` is authoritative for its complete test catalogue; the minimum
landing checks below remain mandatory.

If a build needs git-derived metadata such as a version stamp, compute it on the host and pass the value as an argument or build argument instead of mounting git plumbing.

For `machtiani-harness`, run at least one appropriate host check:

```bash
nix build '.#machtiani'
# or
nix flake check
```

For `dearmachine`, run the host check, which includes `go test ./...`:

```bash
nix flake check
```

For `dearmachine-concierge`, use its pinned Node and pnpm toolchain and build the
isolated runtime closure:

```bash
nix develop -c pnpm install --frozen-lockfile
nix develop -c pnpm typecheck
nix develop -c pnpm test
nix build
```

Other non-Nix tests may run inside the source-only container.

## Phase 4 — sensitive-file and version-worthiness gate

Run this gate before landing and again after every rebase or conflict resolution. Read the base value from the sidecar, then inspect tracked and untracked state and check the complete commit range:

```bash
sidecar="$wt.base"
base=$(sed -n 's/^base=//p' "$sidecar")

git -C "$wt" status --porcelain
git -C "$wt" diff --check "$base..HEAD"
git -C "$wt" diff --name-only "$base..HEAD"
git -C "$wt" diff "$base..HEAD"
git -C "$wt" ls-files --others --exclude-standard
```

Review every changed name and diff. Remove anything that is not version-worthy, including generated output, host-local notes, `.env*` files, credentials, private keys, and backup files. For any untracked candidate expected to be ignored, verify the applicable rule explicitly:

```bash
git -C "$wt" check-ignore -v -- path/to/candidate
```

Secret-scan the entire commit range and every untracked candidate. These example patterns are a minimum starting point and do not replace inspection:

```bash
git -C "$wt" diff --no-ext-diff "$base..HEAD" |
  grep -Ein 'TOKEN=|API_KEY|BEGIN .*PRIVATE KEY|password'

(
  cd "$wt"
  while IFS= read -r -d '' candidate; do
    grep -HnEI 'TOKEN=|API_KEY|BEGIN .*PRIVATE KEY|password' -- "$candidate"
  done < <(git ls-files --others --exclude-standard -z)
)
```

A `grep` exit status of 1 means it found no matching lines. Investigate every match rather than assuming it is harmless.

### Installation Procedure Evaluation (IPE)

When `README.md` changes, run the credential-free documentation contract and
IPE self-test from the umbrella repository:

```bash
scripts/verify-installation-procedure.sh
tests/e2e-installation-procedure/run.sh --self-test
```

When `docs/installation-procedure.md`,
`scripts/verify-installation-procedure.sh`, or anything under
`tests/e2e-installation-procedure/` changes, run these gates in order:

```bash
scripts/verify-installation-procedure.sh
tests/e2e-installation-procedure/run.sh
```

The documentation gate requires a small README with Nix and curl acquisition,
`dearmachine` as the lifecycle entry point, and a link to the canonical detailed
procedure. It also asserts that the Installation Procedure does not select the
Codex backend and that the runtime `.secrets` credential file is ignored. The
live execution gate is the IPE and reads only `DEEPSEEK_API_KEY` and
`AGENTMAIL_API_KEY` from the ignored mode-`0600` `.secrets` file. Its host
transaction provisions two temporary AgentMail inboxes and scoped policies,
has Forge follow the published flow in a clean source-only container, verifies
a forge-only delegated email round trip, and performs journaled exact cleanup.
It makes provider requests, sends email, and can incur charges.

## Phase 5 — land locally

Landing is local only. First acquire a per-submodule lock inside the submodule's common git directory. Record enough owner and session metadata to identify the holder, and arrange trap-based removal of only the lock this session acquired:

```bash
common=$(git -C "$sub" rev-parse --path-format=absolute --git-common-dir)
lock="$common/parallel-land.lock"
lock_owned=false

release_lock() {
    if [ "$lock_owned" = true ]; then
        unlink "$lock/owner"
        rmdir "$lock"
        lock_owned=false
    fi
}
trap 'release_lock' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if ! mkdir "$lock"; then
    echo "landing lock is held: $lock" >&2
    cat "$lock/owner" >&2 2>/dev/null || true
    exit 1
fi
lock_owned=true
{
    printf 'pid=%s\n' "$$"
    printf 'session=%s\n' "${PARALLEL_SESSION_ID:-manual-$$}"
    printf 'worktree=%s\n' "$wt"
    date -u '+started=%Y-%m-%dT%H:%M:%SZ'
} > "$lock/owner"
```

Never remove another session's lock without first validating its owner metadata. A live or ambiguous owner means stop and ask the user.

With the lock held, rebase the worktree branch onto the submodule's local `main` tip with editors disabled:

```bash
GIT_EDITOR=true GIT_SEQUENCE_EDITOR=true git -C "$wt" rebase main
```

Resolve conflicts non-interactively using an explicit path-by-path rule, stage only the resolved paths, and continue with `GIT_EDITOR=true git -C "$wt" rebase --continue`. Any conflict whose correct resolution is unclear stops the landing; ask the user. After every rebase or conflict resolution, rerun the minimum submodule check from Phase 3 and the complete Phase 4 gate.

Record the verified local `main` tip. Immediately before merging, read it again. If it moved, rebase onto the new tip and repeat all checks and the gate before continuing:

```bash
verified_main=$(git -C "$sub" rev-parse main)
# Run the Phase 3 minimum check and the complete Phase 4 gate here.
current_main=$(git -C "$sub" rev-parse main)
test "$current_main" = "$verified_main" || {
    echo "local main moved; rebase and re-verify before landing" >&2
    exit 1
}
```

In the submodule's primary checkout, verify that the tree is clean, that it is on `main`, and that the recorded umbrella pin remains on its lineage. Then fast-forward only, producing no merge commit:

```bash
test -z "$(git -C "$sub" status --porcelain)"
test "$(git -C "$sub" symbolic-ref --short HEAD)" = main
git -C "$sub" merge-base --is-ancestor "$base" HEAD
git -C "$sub" merge --ff-only "wt/$name"
```

Let the trap release the lock on exit. NEVER push.

## Phase 6 — umbrella pointer bump is a separate release decision

Updating the umbrella pin belongs to the maintainer or to a separately and explicitly authorized release step. Follow the two-commit rhythm in `docs/umbrella-runbook.md` and use `scripts/update-submodules.sh` only in that authorized step. It is not part of normal agent landing. Never push. For umbrella-side changes that depend on in-flight submodule feature
branches, see "Development pairing for in-flight feature branches" in
`docs/umbrella-runbook.md`.

## Phase 7 — cleanup only on the user's request

When the user explicitly requests cleanup, run:

```bash
./scripts/worktree-teardown <worktree-path>
```

The helper refuses to remove a dirty worktree. It prunes the linked-worktree administration and guard hooks, and deletes the task branch only if the branch has landed; otherwise it warns and leaves the branch in place.

## Hazards and notes

- Git refuses to reuse a branch name already checked out by another worktree. Use a distinct worktree name rather than trying to share or reuse its branch.
- The worktree's `.git` file is a pointer to administration outside `/tmp`. Never mount that file or its target into a container.
- The temporary directory is disposable: a reboot or janitor may remove uncommitted work. Commit often and land promptly.
- The landing lock is per submodule. Every landing session must acquire and respect it.
- Do not enable `extensions.worktreeConfig` merely to get the optional push guard. The no-push policy is the protection.
