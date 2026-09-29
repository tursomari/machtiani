#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'INSTALL guidance test failure: %s\n' "$*" >&2
  exit 1
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
prompt=$repo_root/INSTALL.md
stage_root=$repo_root/docs/installation

environment=$stage_root/01-environment.md
provider=$stage_root/02-provider.md
email=$stage_root/03-email.md
backend=$stage_root/04-backend.md
product=$stage_root/05-product-and-verification.md
always_on=$stage_root/06-always-on.md
email_progress=$stage_root/live-email-progress.md
catalogue=$stage_root/backend-catalogue.md
guidance_readme=$stage_root/README.md
standard=$repo_root/docs/standard-installation.md
codex=$stage_root/backends/codex.md
forge=$stage_root/backends/forge.md
omp=$stage_root/backends/omp.md

for file in "$prompt" "$guidance_readme" "$environment" "$provider" "$email" "$backend" \
  "$product" "$always_on" "$email_progress" "$catalogue" "$codex" "$forge" "$omp" "$standard"; do
  test -f "$file" || fail "missing ${file#"$repo_root/"}"
done

for conversation_contract in \
  'not a verbatim script' \
  'information supplied early' \
  'Do not ask again for an unambiguous answer' \
  'security and consent boundaries'; do
  grep -Fi -- "$conversation_contract" "$prompt" >/dev/null || fail "missing flexible conversation policy: $conversation_contract"
done
! grep -F 'questions below exactly' "$prompt" >/dev/null || fail 'canonical questions must not force verbatim repetition'
grep -F 'confirm its intended role' "$email" >/dev/null || fail 'early email addresses require contextual reuse or clarification'
grep -F 'already explicitly authorized' "$email" >/dev/null || fail 'do not repeat established sender authorization'
init_line=$(grep -nF 'machtiani init --no-interactive' "$product" | head -1 | cut -d: -f1)
sync_line=$(grep -nFx 'machtiani sync' "$product" | head -1 | cut -d: -f1)
test -n "$init_line" && test -n "$sync_line" && test "$init_line" -lt "$sync_line" || fail 'fresh provider-check repository must be initialized before sync'
for probe_isolation in \
  'Keep probe-only Git identity and environment overrides inside the disposable' \
  'Do not carry probe-only Git environment overrides' \
  'Do not ask for a Git name, email address, account, or signing setup' \
  'including resumed setup. Leave existing repositories and global Git settings'; do
  grep -F -- "$probe_isolation" "$product" >/dev/null || fail "missing provider-probe isolation guidance: $probe_isolation"
done

for permanent in \
  'permanent operating contract' \
  'Ask exactly one question at a time' \
  'Do not ask the human to run commands that you can run yourself' \
  'Never ask the human to paste a secret into chat' \
  'Credential messages below are helper-owned reference text' \
  'announce a secure field before it exists' \
  'Ask permission at meaningful authority boundaries' \
  'Treat written catalogue entries and guides as useful prior knowledge' \
  'a substitute for observing the installed software' \
  'call the entry-point repository' \
  'choose or understand an entry point.' \
  'optional always-on question' \
  'Installation map' \
  'Do not preload later instructions' \
  'Installation outcome'; do
  grep -Fi -- "$permanent" "$prompt" >/dev/null || \
    fail "INSTALL.md is missing permanent contract: $permanent"
done

for canonical_message in \
  'Welcome to Dear Machine,' \
  'Would you like to continue with the installation now?' \
  'First, choose the AI service for the installation assistant and Machtiani.' \
  'Which {provider} model should conduct the installation and power Dear Machine’s reasoning?' \
  'Paste your {provider} API key into the secure field and press Enter.' \
  'saved once for the installer and Dear Machine' \
  'never enter the conversation.' \
  'Dear Machine needs an email service to receive messages and send replies.' \
  'If you don’t already have an AgentMail API key, a free tier is available. Do you need help getting one?' \
  'Dear Machine needs your {transport} API key to connect to the email service you chose.' \
  'What email address should be allowed to send work to Dear Machine?' \
  'Dear Machine delegates work to a backend agent — a separate AI worker similar to a subagent.' \
  'Would you like to use {agent} as the backend agent? I can also help configure another agent you prefer.' \
  'Which would you like to use as the backend agent? I can also help configure another agent you prefer.' \
  'May I run a small health check to confirm {agent} actually works?' \
  'Which agent would you like to use?' \
  'Would you like to log in with {subscription}, or use an API key instead?' \
  'I have what I need. I’m installing Machtiani and Dear Machine now. This may take a few minutes.' \
  'Please send a short test email from {authorized sender address} to {inbox address}.' \
  'check your spam folder and mark it as “Not spam.”' \
  'Tell me when you’ve sent it.' \
  'Would you like Dear Machine to start automatically when your computer turns on, even before you sign in?' \
  'You can turn it off later.' \
  'powered on, awake, and connected to the internet'; do
  grep -F -- "$canonical_message" "$prompt" >/dev/null || \
    fail "INSTALL.md is missing canonical user message: $canonical_message"
done

! grep -F -- 'may lower separate API costs' "$prompt" >/dev/null || \
  fail 'backend choice must not use promotional catalogue copy'

choice_line=$(grep -nF -- '- Backend choice when one supported agent is installed:' "$prompt" | cut -d: -f1)
health_line=$(grep -nF -- '- Selected-backend health-check permission:' "$prompt" | cut -d: -f1)
test "$choice_line" -lt "$health_line" || fail 'backend choice must precede health-check consent'
for retired in 'Which installed agent would you like to configure?' 'Which ready agent should it use?' 'investigate every detected candidate'; do
  ! grep -F -- "$retired" "$prompt" "$backend" >/dev/null || fail "readiness-first flow remains: $retired"
done

provider_choice_line=$(grep -nF 'First, choose the AI service for the installation assistant and Machtiani.' "$prompt" | cut -d: -f1)
model_choice_line=$(grep -nF 'Which {provider} model should conduct the installation and power Dear Machine’s reasoning?' "$prompt" | cut -d: -f1)
credential_line=$(grep -nF 'Paste your {provider} API key into the secure field and press Enter.' "$prompt" | cut -d: -f1)
test "$provider_choice_line" -lt "$model_choice_line" && \
  test "$model_choice_line" -lt "$credential_line" || \
  fail 'provider, model, and credential prompts must remain in that order'

llm_message=$(sed -n '/^- Launcher API-key credential:$/,/^- Email transport:/p' "$prompt")
test "$(grep -cFx '  >' <<<"$llm_message")" -eq 1 || \
  fail 'the LLM credential message must separate its explanation and secure input instruction'
grep -F -- 'secure field' <<<"$llm_message" >/dev/null || \
  fail 'the launcher API-key message must describe the secure field'
! grep -F -- 'enter-llm-key' <<<"$llm_message" >/dev/null || \
  fail 'the LLM credential message must not retain the legacy helper'

email_message=$(sed -n '/^- Email credential:$/,/^- Authorized sender:/p' "$prompt")
test "$(grep -cFx '  >' <<<"$email_message")" -eq 1 || \
  fail 'the email credential message must separate its explanation and secure input instruction'
grep -F -- 'masked, saved directly to a private file' <<<"$email_message" >/dev/null || \
  fail 'the email credential message must describe the secure masked field'
! grep -F -- 'enter-email-key' <<<"$email_message" >/dev/null || \
  fail 'the email credential message must not retain the legacy helper'

for retired_credential_ui in micro enter-llm-key enter-email-key; do
  ! grep -Fi -- "$retired_credential_ui" "$prompt" "$environment" "$provider" "$email" >/dev/null || \
    fail "the canonical installer still references retired credential UI: $retired_credential_ui"
done

# The initial prompt owns invariants and routing, not phase mechanics. Loading
# the complete procedure or branch details at startup defeats progressive
# disclosure and has previously caused unrelated backend paths to bleed into
# one another.
for deferred_detail in \
  'read the entire procedure before changing the machine' \
  'nixpkgs#git' \
  'credential-entry.sh prepare' \
  'agent-manager backend health' \
  'setup-agents --backend'; do
  ! grep -Fi -- "$deferred_detail" "$prompt" >/dev/null || \
    fail "INSTALL.md preloads deferred detail: $deferred_detail"
done

grep -F -- 'After the launcher records consent and starts this agent' "$prompt" >/dev/null || \
  fail 'the initial prompt does not gate the first stage on launcher consent'
grep -F -- '`docs/installation/01-environment.md`' "$prompt" >/dev/null || \
  fail 'the initial prompt does not route to Stage 1'
grep -F -- 'Do not read later stage' "$prompt" >/dev/null || \
  fail 'the initial prompt does not forbid eager stage loading'

assert_route() {
  source_file=$1
  next_path=$2
  grep -F -- "$next_path" "$source_file" >/dev/null || \
    fail "${source_file#"$repo_root/"} does not route to $next_path"
}

assert_route "$environment" 'docs/installation/02-provider.md'
assert_route "$provider" 'docs/installation/03-email.md'
assert_route "$email" 'docs/installation/04-backend.md'
assert_route "$backend" 'docs/installation/05-product-and-verification.md'
assert_route "$product" 'docs/installation-procedure.md'
assert_route "$product" 'docs/standard-installation.md'
grep -F 'Do not install Nix, invoke Nix, or rebuild a missing product.' "$environment" >/dev/null || fail 'Standard must not silently fall back to Nix'
grep -F 'installation.distribution.binaries.modelHost' "$product" >/dev/null || fail 'Standard must retain the supplied model host path'
assert_route "$product" 'docs/installation/live-email-progress.md'
assert_route "$email_progress" 'docs/installation/06-always-on.md'

for stage_file in "$environment" "$provider" "$email" "$backend" "$product" "$always_on"; do
  grep -F -- 'permanent contract in `INSTALL.md` remains in force' "$stage_file" >/dev/null || \
    fail "${stage_file#"$repo_root/"} does not retain the permanent contract"
done

for dependency_contract in \
  'Ask permission before installing Nix' \
  'https://nixos.org/nix/install' \
  'nixpkgs#git' \
  'nixpkgs#git-lfs' \
  'permission to install Git or Git LFS after Nix is available' \
  'only resolving the `codex`, `forge`, and `omp` executables' \
  'health-probe a backend yet'; do
  grep -F -- "$dependency_contract" "$environment" >/dev/null || \
    fail "environment stage is missing: $dependency_contract"
done
grep -F -- 'Do not open the shared model profile during environment discovery' "$environment" >/dev/null || \
  fail 'environment discovery must preserve the opaque shared model reference'

for provider_contract in \
  'shared model profile' \
  'choose them again' \
  'complete provider catalogue' \
  'OpenAI-compatible' \
  'remote and local' \
  'all Machtiani model roles' \
  'same profile' \
  'opaque private reference' \
  'Never open, read, print' \
  'subscription tokens into' \
  'This working installation conversation is the verification' \
  'Do not run standalone CLI auth or config checks in this stage' \
  'Live provider validation follows installation'; do
  grep -F -- "$provider_contract" "$provider" >/dev/null || \
    fail "provider stage is missing: $provider_contract"
done

grep -F -- 'exact model and reasoning level already selected' \
  "$product" >/dev/null || \
  fail 'product stage may not replace the selected Machtiani provider or model'
grep -F -- 'Run the Agent Manager health check inside a disposable Git repository' "$product" >/dev/null || \
  fail 'Agent Manager health checks must not write into supplied source'
grep -F -- 'Persistence: unknown' "$product" >/dev/null || \
  fail 'product verification must distinguish unknown persistence from failure'
grep -F -- 'separate from whether the pairing database or workspace has been saved' "$product" >/dev/null || \
  fail 'product verification must distinguish service persistence from saved data'

for email_contract in \
  'recommending or ranking any of them' \
  'Wait for their answer before offering API-key help' \
  'https://app.sendmux.ai/' \
  'Infrastructure key' \
  'A mailbox credential and a Sending key are not sufficient' \
  'put the key in chat' \
  'masked credential field' \
  'credentialHelper.email' \
  'These are adapter responsibilities, not instructions to handle the value yourself' \
  'DSH event stream' \
  'mode `0600`' \
  "credential adapter's success result is the only verification" \
  'do not open, read, print, source' \
  'parse, stat, hash, count, or measure' \
  'credential value.' \
  'Never guess an email address'; do
  grep -F -- "$email_contract" "$email" >/dev/null || \
    fail "email stage is missing: $email_contract"
done

for backend_contract in \
  'advisory index' \
  'Detection proves only' \
  'functional probes until the human agrees' \
  'Check only the selected agent' \
  'Selection is not health-check permission' \
  'A no or maybe is not consent' \
  'Offer the supported backends' \
  'Do not treat every failed health check as missing authentication' \
  'Inspect the resolved executable, version, and built-in help' \
  'repository. The permission to check readiness' \
  'Do not infer readiness from a config file, credential file, or executable alone' \
  'read its one catalogue-linked guide' \
  'load a staged credential into a backend' \
  'Never pipe' \
  'allocate or emulate a terminal' \
  'API-key alternative' \
  'Apply any remaining selection-specific configuration' \
  'named a candidate to use' \
  'do not ask them to select it again' \
  'typed `backend-provider` credential helper' \
  'helper itself presents the canonical message' \
  'Do not silently select or fall back' \
  'Do not read guides for unselected built-ins' \
  'dearmachine/docs/custom-backend-guide.md' \
  'retain that verification as a' \
  'Stage 5 completion condition'; do
  grep -Fi -- "$backend_contract" "$backend" >/dev/null || \
    fail "backend stage is missing: $backend_contract"
done
grep -F -- 'A version-specific setup helper is not a bundled backend binary' "$catalogue" >/dev/null || \
  fail 'catalogue must distinguish setup helpers from installed backends'

for catalogue_contract in \
  'assumptions. An agent absent from this file may still be usable' \
  '| Codex | `codex` | `codex-yolo`' \
  '| Forge | `forge` | `forge`' \
  '| OMP | `omp` | `omp`' \
  'https://github.com/openai/codex' \
  'https://github.com/tailcallhq/forgecode' \
  'https://github.com/can1357/oh-my-pi' \
  'nixpkgs#forge` is not ForgeCode' \
  'ChatGPT subscription login' \
  'relevant selected-agent guide'; do
  grep -F -- "$catalogue_contract" "$catalogue" >/dev/null || \
    fail "backend catalogue is missing: $catalogue_contract"
done

for backend_install_contract in \
  'exact canonical repository identity' \
  'Prefer the documented Nix source' \
  'inspect any downloaded installer' \
  'Prefer an official Nix' \
  'package published by that project' \
  'not invent an unofficial Nix'; do
  grep -Fi -- "$backend_install_contract" "$backend" >/dev/null || \
    fail "backend stage is missing safe installation policy: $backend_install_contract"
done

for guide_contract in \
  'codex.md:https://github.com/openai/codex' \
  'codex.md:dearmachine/flake.lock' \
  'forge.md:https://github.com/tailcallhq/forgecode' \
  'forge.md:github:tailcallhq/forgecode#forge' \
  'forge.md:Never use `nixpkgs#forge`' \
  'omp.md:https://github.com/can1357/oh-my-pi' \
  'omp.md:github:can1357/oh-my-pi#omp'; do
  guide=${guide_contract%%:*}
  contract=${guide_contract#*:}
  grep -F -- "$contract" "$stage_root/backends/$guide" >/dev/null || \
    fail "$guide is missing safe installation guidance: $contract"
done

for mapping in \
  'Codex:codex.md' \
  'Forge:forge.md' \
  'OMP:omp.md'; do
  display=${mapping%%:*}
  guide=${mapping#*:}
  guide_path=$stage_root/backends/$guide
  grep -F -- "Selected backend: $display" "$guide_path" >/dev/null || \
    fail "$guide is not scoped to $display"
  grep -F -- 'installed `' "$guide_path" >/dev/null || \
    fail "$guide does not direct the agent to inspect the installed CLI"
  grep -F -- 'functional probe' "$guide_path" >/dev/null || \
    fail "$guide does not require functional verification"
done

for forge_credential_contract in \
  'Health-check permission is required before credential setup' \
  'Do not inject the credential staged in' \
  'During the consented health check' \
  'provider-environment forwarding as version-specific compatibility' \
  'typed `backend-provider` credential helper' \
  'before running the Forge preparation helper' \
  'human to re-enter a credential' \
  'Confirm the resulting authentication with a functional probe'; do
  grep -F -- "$forge_credential_contract" "$forge" >/dev/null || \
    fail "Forge guide is missing credential-isolation behavior: $forge_credential_contract"
done
if grep -F -- 'that selection authorizes the smallest' "$forge" >/dev/null; then
  fail 'Forge selection must not bypass health-check permission'
fi

for forge_helper_contract in \
  'machtiani-installer-backend prepare-forge-2.13.21' \
  'refuses any other Forge version' \
  'removes it on success or failure' \
  '--reasoning-effort' \
  'verify its readback before the functional probe' \
  'An empty unauthenticated catalogue is not evidence' \
  'non-secret structured receipt'; do
  grep -F -- "$forge_helper_contract" "$forge" >/dev/null || \
    fail "forge.md is missing the maintained migration helper contract: $forge_helper_contract"
done
grep -F -- 'healthy existing ChatGPT subscription login' "$codex" >/dev/null || \
  fail 'Codex guide does not recognize an existing subscription login'
grep -F -- 'healthy existing ChatGPT subscription login' "$omp" >/dev/null || \
  fail 'OMP guide does not recognize an existing subscription login'

for product_contract in \
  'selected healthy backend must already be established' \
  'Read `docs/managed-nix-installation.md` for coordinated' \
  'installation.acquisitionCommand' \
  'skipping its clone and individual software acquisition steps' \
  '--agent-bin "$HOME/.local/bin/machtiani"' \
  'nonterminal progress update' \
  'Immediately make the first installation tool call in' \
  'reference rather than a literal secret' \
  'selected backend passes the installed Agent Manager health check' \
  'tracked changes or credentials.' \
  'docs/installation/live-email-progress.md'; do
  grep -F -- "$product_contract" "$product" >/dev/null || \
    fail "product stage is missing: $product_contract"
done

for progress_contract in \
  'after the human has sent the test email' \
  'dearmachine status' \
  'machtiani session list --json' \
  'machtiani session show' \
  'machtiani run --attach --resume' \
  'display-only' \
  'Never run an' \
  'safe high-level fields' \
  'processed message=' \
  'one outbound reply' \
  'provider or backend error'; do
  grep -F -- "$progress_contract" "$email_progress" >/dev/null || \
    fail "live email progress guide is missing: $progress_contract"
done

for always_on_contract in \
  'Address automatic startup before finishing every successful installation.' \
  'Wait for an explicit yes before service or lingering changes.' \
  'Reuse an explicit answer already supplied' \
  'or silently skip the explanation' \
  "I can't set up automatic startup in this environment." \
  'After restarting your computer, run `dearmachine up`' \
  'The native supervisor may still provide crash recovery.' \
  'unknown, say it is unverified rather than claiming it is disabled.' \
  'Verify persistent service enablement (`enabled`, not `enabled-runtime`)' \
  'active service, the same supervisor PID' \
  'Distinguish configured persistence from an actual reboot test.' \
  'Do not reboot the computer or log the user out' \
  'report automatic startup' \
  'last question in the' \
  'If the human declines' \
  'persistent native systemd user unit' \
  'dearmachine systemd on' \
  'dearmachine persistence on' \
  'Do not create a second unit' \
  'systemctl --user is-enabled' \
  'systemctl --user is-active' \
  'give the exact failed step and recovery action' \
  'dearmachine persistence off'; do
  grep -F -- "$always_on_contract" "$always_on" >/dev/null || \
    fail "always-on stage is missing: $always_on_contract"
done

for macos_contract in \
  'dearmachine launchd status' \
  'dearmachine launchd on' \
  'dearmachine persistence on' \
  'dearmachine persistence off' \
  'dearmachine launchd off' \
  'stops at logout and does not run before login' \
  'Both Standard and Nix use' \
  'Credentials remain in their private files' \
  'never put keys in a plist' \
  'configuration, not an actual logout or' \
  'Disable future login startup'; do
  grep -Fi -- "$macos_contract" "$always_on" >/dev/null || fail "missing macOS startup contract: $macos_contract"
done
grep -F -- 'Would you like Dear Machine to start automatically when you log in?' "$prompt" >/dev/null || fail 'missing macOS startup question'

for completion_contract in \
  'whether host-appropriate automatic startup (login on macOS; before sign-in' \
  'as configured, declined, unavailable, or remains unverified' \
  'Also address automatic startup explicitly' \
  'automatic startup has not been configured or verified'; do
  grep -F -- "$completion_contract" "$prompt" >/dev/null || fail "missing startup completion outcome: $completion_contract"
done
! grep -F -- 'automatic restart was not configured' "$always_on" >/dev/null || \
  fail 'no-systemd guidance must distinguish reboot startup from native crash recovery'

for file in "$prompt" "$environment" "$provider" "$email" "$backend" \
  "$product" "$email_progress" "$catalogue" "$codex" "$forge" "$omp"; do
  ! grep -F -- '<!-- installation-procedure:begin -->' "$file" >/dev/null || \
    fail "${file#"$repo_root/"} duplicates the generated Installation Procedure"
  ! grep -F -- 'dangerously-bypass-approvals-and-sandbox' "$file" >/dev/null || \
    fail "${file#"$repo_root/"} exposes an internal harness flag"
  ! grep -F -- 'systemctl' "$file" >/dev/null || \
    fail "${file#"$repo_root/"} configures systemd during basic installation"
done

printf 'INSTALL guidance contract test passed\n'
