#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'credential entry test failure: %s\n' "$*" >&2
  exit 1
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
helper=$repo_root/scripts/credential-entry.sh
test -x "$helper" || fail 'scripts/credential-entry.sh is missing or not executable'
installer_helper=$repo_root/dearmachine-concierge/assets/credential-entry.sh
test ! -e "$installer_helper" || fail 'the installer must not package the legacy micro credential helper'

test_root=$(mktemp -d "${TMPDIR:-/tmp}/machtiani-credential-entry-test.XXXXXX")
cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT HUP INT TERM

export HOME=$test_root/home
export XDG_STATE_HOME=$test_root/state
install -d -m 0700 "$HOME" "$test_root/bin"
export PATH=$test_root/bin:/usr/bin:/bin

cat > "$test_root/bin/micro" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
test "$#" -eq 1
form=$1
updated=$form.updated
grep -F -- 'Paste your key anywhere above this line.' "$form" >/dev/null
grep -F -- "$EXPECTED_PASTE_INSTRUCTION" "$form" >/dev/null
grep -F -- 'Save with Ctrl+S.' "$form" >/dev/null
grep -F -- 'Exit with Ctrl+Q.' "$form" >/dev/null
{
  printf '%s\n' "$FAKE_CREDENTIAL"
  sed -n '/^--- DEAR MACHINE CREDENTIAL INSTRUCTIONS ---$/,$p' "$form"
} > "$updated"
chmod 0600 "$updated"
mv -- "$updated" "$form"
EOF
chmod 0755 "$test_root/bin/micro"

cat > "$test_root/bin/uname" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
test "$#" -eq 1
test "$1" = -s
printf '%s\n' "$FAKE_UNAME"
EOF
chmod 0755 "$test_root/bin/uname"

llm_destination=$HOME/.config/dearmachine/backends.env
"$helper" prepare \
  --name enter-llm-key \
  --destination "$llm_destination" \
  --format environment \
  --variable OPENROUTER_API_KEY
test "$(stat -c %a "$HOME/.local/bin/enter-llm-key")" = 700 || \
  fail 'LLM helper must be owner-executable only'
test "$("$helper" status --name enter-llm-key)" = pending || \
  fail 'LLM helper must report pending before credential entry finishes'

FAKE_UNAME=Linux \
EXPECTED_PASTE_INSTRUCTION='Paste with Ctrl+Shift+V.' \
FAKE_CREDENTIAL='test-openrouter-key' \
  "$HOME/.local/bin/enter-llm-key"
test "$("$helper" status --name enter-llm-key)" = ready || \
  fail 'LLM helper must report ready after credential entry finishes'
test "$(stat -c %a "$llm_destination")" = 600 || \
  fail 'LLM destination must be private'
test "$(sed -n '1p' "$llm_destination")" = 'OPENROUTER_API_KEY=test-openrouter-key' || \
  fail 'LLM destination does not contain the normalized assignment'
! grep -F -- 'DEAR MACHINE CREDENTIAL INSTRUCTIONS' "$llm_destination" >/dev/null || \
  fail 'instructions leaked into the final LLM credential file'
test ! -e "$HOME/.local/bin/enter-llm-key" || \
  fail 'successful status check must remove the one-shot LLM helper'

email_destination=$HOME/.config/dearmachine/agentmail-api-key
"$helper" prepare \
  --name enter-email-key \
  --destination "$email_destination" \
  --format raw
"$helper" wait --name enter-email-key &
wait_pid=$!
FAKE_UNAME=Darwin \
EXPECTED_PASTE_INSTRUCTION='Paste with Command+V.' \
FAKE_CREDENTIAL='test-agentmail-key' \
  "$HOME/.local/bin/enter-email-key"
wait "$wait_pid"
test "$(sed -n '1p' "$email_destination")" = 'test-agentmail-key' || \
  fail 'email destination does not contain the normalized raw key'
! grep -F -- 'DEAR MACHINE CREDENTIAL INSTRUCTIONS' "$email_destination" >/dev/null || \
  fail 'instructions leaked into the final email credential file'

# Without micro (for example, a Standard installation without Nix), the helper
# reads one masked line from the terminal instead of drafting a file.
no_micro_path=/usr/bin:/bin
! PATH=$no_micro_path command -v micro >/dev/null 2>&1 || \
  fail 'the masked-entry check requires a PATH without micro'
masked_destination=$HOME/.config/machtiani/model-provider.env
"$helper" prepare \
  --name enter-llm-key \
  --destination "$masked_destination" \
  --format environment \
  --variable DEEPSEEK_API_KEY
printf 'test-deepseek-key\r\n' | PATH=$no_micro_path "$HOME/.local/bin/enter-llm-key" 2>"$test_root/masked.err"
grep -F -- 'The key will not be shown.' "$test_root/masked.err" >/dev/null || \
  fail 'masked entry must explain that input is hidden'
! grep -F -- 'test-deepseek-key' "$test_root/masked.err" >/dev/null || \
  fail 'masked entry must not echo the credential'
test ! -e "$XDG_STATE_HOME/dearmachine/installation/enter-llm-key.input" || \
  fail 'masked entry must not leave a draft file'
test "$("$helper" status --name enter-llm-key)" = ready || \
  fail 'masked entry must report ready'
test "$(stat -c %a "$masked_destination")" = 600 || \
  fail 'masked destination must be private'
test "$(cat "$masked_destination")" = 'DEEPSEEK_API_KEY=test-deepseek-key' || \
  fail 'masked destination does not contain the normalized assignment'

"$helper" prepare \
  --name enter-email-key \
  --destination "$HOME/.config/dearmachine/openmail-api-key" \
  --format raw
if printf '\n' | PATH=$no_micro_path "$HOME/.local/bin/enter-email-key" 2>/dev/null; then
  fail 'empty masked entry must fail'
fi
if "$helper" status --name enter-email-key 2>/dev/null; then
  fail 'status must report failed masked entry'
fi
test ! -e "$HOME/.config/dearmachine/openmail-api-key" || \
  fail 'failed masked entry must not create the destination'

printf 'credential entry test passed\n'
