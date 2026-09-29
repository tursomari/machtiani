#!/usr/bin/env bash

# Host-side transaction journal for exact AgentMail resource identities.

txn_error() {
  printf 'TRANSACTION ERROR: %s\n' "$*" >&2
}

txn_require_initialized() {
  test -n "${TXN_RUNTIME_ROOT:-}" && test -f "${TXN_JOURNAL:-}" || {
    txn_error 'txn_init must be called first.'
    return 1
  }
}

txn_init() {
  test -z "${TXN_RUNTIME_ROOT:-}" || {
    txn_error 'transaction is already initialized.'
    return 1
  }
  umask 077
  TXN_RUNTIME_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/machtiani-agentmail-txn.XXXXXX")
  chmod 0700 "$TXN_RUNTIME_ROOT"
  TXN_JOURNAL=$TXN_RUNTIME_ROOT/journal.jsonl
  : > "$TXN_JOURNAL"
  chmod 0600 "$TXN_JOURNAL"
  TXN_TRAP_ACTIVE=false
  TXN_CLEANUP_ACTIVE=false
  TXN_INCONCLUSIVE=false
  TXN_CLEANUP_ENABLED=${TXN_CLEANUP_ENABLED:-1}
  export TXN_RUNTIME_ROOT TXN_JOURNAL TXN_INCONCLUSIVE
  trap 'txn_handle_signal HUP 129' HUP
  trap 'txn_handle_signal INT 130' INT
  trap 'txn_handle_signal TERM 143' TERM
  trap 'txn_handle_exit $?' EXIT
}

txn_handle_signal() {
  txn_signal_name=$1
  txn_signal_status=$2
  printf 'Transaction interrupted by %s; cleaning exact journaled identities.\n' "$txn_signal_name" >&2
  exit "$txn_signal_status"
}

txn_handle_exit() {
  txn_exit_status=$1
  if test "${TXN_TRAP_ACTIVE:-false}" = true; then
    return
  fi
  TXN_TRAP_ACTIVE=true
  trap - EXIT HUP INT TERM

  if test "${TXN_CLEANUP_ENABLED:-1}" = 1 && test -s "${TXN_JOURNAL:-/dev/null}"; then
    if ! txn_cleanup_all; then
      printf 'INCONCLUSIVE CLEANUP: exact journaled resources could not all be verified absent.\n' >&2
      txn_exit_status=1
    fi
  fi

  if test "${TXN_KEEP_RUNTIME:-0}" != 1 && test -n "${TXN_RUNTIME_ROOT:-}" && test -d "$TXN_RUNTIME_ROOT"; then
    rm -rf -- "$TXN_RUNTIME_ROOT"
  fi
  exit "$txn_exit_status"
}

txn_record() {
  txn_require_initialized || return 1
  txn_phase=${1:-}
  txn_kind=${2:-}
  txn_identity=${3:-}
  test -n "$txn_phase" && test -n "$txn_kind" && test -n "$txn_identity" || {
    txn_error 'usage: txn_record <phase> <resource-kind> <exact-json-identity>'
    return 1
  }

  TXN_LAST_RESOURCE_KEY=$(python3 - "$TXN_JOURNAL" "$txn_phase" "$txn_kind" "$txn_identity" <<'PY'
import hashlib
import json
import os
import sys

journal, phase, kind, raw_identity = sys.argv[1:]
try:
    identity = json.loads(raw_identity)
except json.JSONDecodeError as error:
    raise SystemExit(f"identity is not valid JSON: {error}")
if not isinstance(identity, dict) or not identity:
    raise SystemExit("identity must be a non-empty JSON object")
canonical = json.dumps(identity, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
key = f"{kind}:{hashlib.sha256(canonical.encode()).hexdigest()}"

records = []
with open(journal, "r", encoding="utf-8") as stream:
    for line in stream:
        if line.strip():
            records.append(json.loads(line))
if any(record.get("event") == "record" and record.get("key") == key for record in records):
    raise SystemExit("resource identity is already journaled")

event = {"event": "record", "phase": phase, "kind": kind, "key": key, "identity": identity}
encoded = (json.dumps(event, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode()
descriptor = os.open(journal, os.O_WRONLY | os.O_APPEND)
try:
    os.write(descriptor, encoded)
    os.fsync(descriptor)
finally:
    os.close(descriptor)
print(key)
PY
) || return 1
  export TXN_LAST_RESOURCE_KEY
}

txn_mark_done() {
  txn_require_initialized || return 1
  txn_resource_key=${1:-}
  test -n "$txn_resource_key" || {
    txn_error 'usage: txn_mark_done <resource-key>'
    return 1
  }

  python3 - "$TXN_JOURNAL" "$txn_resource_key" <<'PY'
import json
import os
import sys

journal, key = sys.argv[1:]
with open(journal, "r", encoding="utf-8") as stream:
    records = [json.loads(line) for line in stream if line.strip()]
if not any(record.get("event") == "record" and record.get("key") == key for record in records):
    raise SystemExit("completion key has no matching record")
if any(record.get("event") == "done" and record.get("key") == key for record in records):
    raise SystemExit("completion key is already marked done")
encoded = (json.dumps({"event": "done", "key": key}, sort_keys=True, separators=(",", ":")) + "\n").encode()
descriptor = os.open(journal, os.O_WRONLY | os.O_APPEND)
try:
    os.write(descriptor, encoded)
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
}

txn_key_is_done() {
  txn_require_initialized || return 1
  txn_resource_key=$1
  python3 - "$TXN_JOURNAL" "$txn_resource_key" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    events = [json.loads(line) for line in stream if line.strip()]
raise SystemExit(0 if any(event.get("event") == "done" and event.get("key") == sys.argv[2] for event in events) else 1)
PY
}

txn_created_ids() {
  txn_require_initialized || return 1
  python3 - "$TXN_JOURNAL" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as stream:
    events = [json.loads(line) for line in stream if line.strip()]
for event in events:
    # Once the API returns an exact ID, treat the record as cleanable even if
    # interruption happens before its done event is fsynced.
    if event.get("event") != "record":
        continue
    if event.get("phase") != "create" or event.get("kind") != "inbox":
        continue
    identity = event.get("identity")
    inbox_id = identity.get("inbox_id") if isinstance(identity, dict) else None
    if not isinstance(inbox_id, str) or not inbox_id or any(char in inbox_id for char in "\r\n\x00"):
        raise SystemExit("journaled inbox identity has no safe exact inbox_id")
    print(inbox_id)
PY
}

txn_unfinished_inbox_intents() {
  txn_require_initialized || return 1
  python3 - "$TXN_JOURNAL" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as stream:
    events = [json.loads(line) for line in stream if line.strip()]
done = {event.get("key") for event in events if event.get("event") == "done"}
required = ("client_id", "display_name", "run_id", "role")
for event in events:
    if event.get("event") != "record" or event.get("phase") != "intent" or event.get("kind") != "inbox-create":
        continue
    if event.get("key") in done:
        continue
    identity = event.get("identity")
    if not isinstance(identity, dict) or set(identity) != set(required):
        raise SystemExit("unfinished inbox intent does not contain the complete run-unique tuple")
    if any(not isinstance(identity[name], str) or not identity[name] or any(c in identity[name] for c in "\r\n\t\x00") for name in required):
        raise SystemExit("unfinished inbox intent contains an unsafe tuple value")
    print(json.dumps(identity, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
PY
}

txn_resource_key_for_identity() {
  txn_require_initialized || return 1
  txn_phase=$1
  txn_kind=$2
  txn_identity=$3
  python3 - "$TXN_JOURNAL" "$txn_phase" "$txn_kind" "$txn_identity" <<'PY'
import json
import sys

journal, phase, kind, raw = sys.argv[1:]
identity = json.loads(raw)
with open(journal, "r", encoding="utf-8") as stream:
    matches = [event.get("key") for event in map(json.loads, filter(str.strip, stream))
               if event.get("event") == "record" and event.get("phase") == phase
               and event.get("kind") == kind and event.get("identity") == identity]
if len(matches) != 1:
    raise SystemExit(1)
print(matches[0])
PY
}

txn_expected_inbox_identity() {
  txn_require_initialized || return 1
  txn_expected_id=$1
  python3 - "$TXN_JOURNAL" "$txn_expected_id" <<'PY'
import json
import sys

journal, expected_id = sys.argv[1:]
with open(journal, "r", encoding="utf-8") as stream:
    events = [json.loads(line) for line in stream if line.strip()]
matches = []
for event in events:
    if event.get("event") != "record":
        continue
    if event.get("phase") != "create" or event.get("kind") != "inbox":
        continue
    identity = event.get("identity")
    if isinstance(identity, dict) and identity.get("inbox_id") == expected_id:
        matches.append(identity)
if len(matches) != 1:
    raise SystemExit("journal does not contain exactly one completed matching inbox identity")
print(json.dumps(matches[0], sort_keys=True, separators=(",", ":"), ensure_ascii=False))
PY
}

txn_created_list_composites() {
  txn_require_initialized || return 1
  python3 - "$TXN_JOURNAL" <<'PY'
import json
import sys

required = ("scope", "scope_id", "direction", "type", "entry")
with open(sys.argv[1], "r", encoding="utf-8") as stream:
    events = [json.loads(line) for line in stream if line.strip()]
for event in events:
    # The composite is known before mutation. Treat an uncompleted record as
    # "may have been created" so interruption between the API response and the
    # done event remains safely cleanable after baseline absence was proved.
    if event.get("event") != "record":
        continue
    if event.get("phase") != "create" or event.get("kind") != "allowlist-entry":
        continue
    identity = event.get("identity")
    if not isinstance(identity, dict):
        raise SystemExit("journaled allowlist identity is not an object")
    values = [identity.get(name) for name in required]
    if any(not isinstance(value, str) or not value or any(char in value for char in "\r\n\t\x00") for value in values):
        raise SystemExit("journaled allowlist identity is not a safe exact composite")
    print("\t".join(values))
PY
}

txn_require_helper() {
  test -n "${TXN_AGENTMAIL_HELPER:-}" && test -x "$TXN_AGENTMAIL_HELPER" || {
    txn_error 'TXN_AGENTMAIL_HELPER must name the exact executable helper path.'
    return 1
  }
}

txn_helper() {
  txn_require_helper || return 1
  env -u AGENTMAIL_BASE_URL -u AGENTMAIL_CUSTOM_HEADERS \
    "$TXN_AGENTMAIL_HELPER" "$@"
}

txn_reconcile_unfinished_inbox_intents() {
  txn_require_initialized || return 1
  txn_require_helper || return 1
  txn_intents=$(txn_unfinished_inbox_intents) || return 1
  while IFS= read -r txn_intent; do
    test -n "$txn_intent" || continue
    txn_output=$TXN_RUNTIME_ROOT/reconcile-inboxes.json
    txn_helper list-inboxes > "$txn_output" || {
      txn_error "unfinished inbox intent $txn_intent could not be listed; no deletion has occurred."
      return 1
    }
    chmod 0600 "$txn_output"
    if ! txn_identity=$(python3 - "$txn_output" "$txn_intent" \
      "${AGENTMAIL_MUTATION_FORBIDDEN_ID:-}" "${AGENTMAIL_MUTATION_FORBIDDEN_ADDRESS:-}" <<'PY'
import json
import sys

path, raw_intent, protected_id, protected_address = sys.argv[1:]
intent = json.loads(raw_intent)
data = json.load(open(path, encoding="utf-8"))
rows = data.get("inboxes")
if not isinstance(rows, list):
    raise SystemExit("unfinished inbox intent reconciliation received an invalid inbox list")
expected_metadata = {
    "machtiani_ipe_run": intent["run_id"],
    "machtiani_ipe_role": intent["role"],
}
matches = [row for row in rows if isinstance(row, dict)
           and row.get("client_id") == intent["client_id"]
           and row.get("display_name") == intent["display_name"]
           and row.get("metadata") == expected_metadata]
tuple_text = json.dumps(intent, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
if len(matches) != 1:
    raise SystemExit(f"unfinished inbox intent {tuple_text} matched {len(matches)} inboxes; expected exactly one; no deletion has occurred")
row = matches[0]
for name in ("inbox_id", "email", "pod_id", "client_id", "display_name"):
    value = row.get(name)
    if not isinstance(value, str) or not value or any(c in value for c in "\r\n\x00"):
        raise SystemExit(f"reconciled inbox has no safe exact {name}; no deletion has occurred")
if row["inbox_id"] == protected_id or (protected_address and row["email"].casefold() == protected_address.casefold()):
    raise SystemExit("unfinished inbox intent resolved to the protected stable identity; no deletion has occurred")
print(json.dumps(row, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
PY
    ); then
      txn_error "unfinished inbox intent reconciliation failed for $txn_intent"
      return 1
    fi

    if txn_create_key=$(txn_resource_key_for_identity create inbox "$txn_identity"); then
      :
    else
      txn_record create inbox "$txn_identity" || return 1
      txn_create_key=$TXN_LAST_RESOURCE_KEY
    fi
    txn_key_is_done "$txn_create_key" || txn_mark_done "$txn_create_key" || return 1
    txn_intent_key=$(txn_resource_key_for_identity intent inbox-create "$txn_intent") || return 1
    txn_mark_done "$txn_intent_key" || return 1
  done <<< "$txn_intents"
}

txn_container_intent_identity() {
  txn_require_initialized || return 1
  txn_container_name=$1
  python3 - "$TXN_JOURNAL" "$txn_container_name" <<'PY'
import json
import sys

journal, name = sys.argv[1:]
with open(journal, "r", encoding="utf-8") as stream:
    events = [json.loads(line) for line in stream if line.strip()]
matches = [event["identity"] for event in events if event.get("event") == "record"
           and event.get("phase") == "intent" and event.get("kind") == "container-create"
           and isinstance(event.get("identity"), dict) and event["identity"].get("container_name") == name]
if len(matches) != 1:
    raise SystemExit(f"journal does not contain exactly one container intent for {name!r}")
identity = matches[0]
required = ("container_name", "cidfile", "label_name", "label_value")
if set(identity) != set(required) or any(not isinstance(identity[key], str) or not identity[key] for key in required):
    raise SystemExit("container intent is incomplete")
print(json.dumps(identity, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
PY
}

txn_reconcile_container_from_cidfile() {
  txn_require_initialized || return 1
  txn_container_name=$1
  txn_intent=$(txn_container_intent_identity "$txn_container_name") || return 1
  txn_cidfile=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["cidfile"])' "$txn_intent")
  txn_container_id=$(python3 - "$txn_cidfile" "$TXN_RUNTIME_ROOT" <<'PY'
from pathlib import Path
import os
import re
import stat
import sys

path = Path(sys.argv[1])
runtime = Path(sys.argv[2]).resolve()
try:
    parent = path.parent.resolve(strict=True)
except OSError as error:
    raise SystemExit(f"durable container cidfile parent is unavailable: {error}")
if runtime != parent and runtime not in parent.parents:
    raise SystemExit("durable container cidfile is outside the private transaction runtime")
try:
    metadata = path.lstat()
except OSError as error:
    raise SystemExit(f"durable container cidfile is unavailable: {error}")
if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
    raise SystemExit("durable container cidfile is not a regular, non-symlink file")
if metadata.st_uid != os.geteuid() or stat.S_IMODE(metadata.st_mode) & 0o077:
    raise SystemExit("durable container cidfile has unsafe ownership or mode")
value = path.read_text(encoding="ascii").strip()
if not re.fullmatch(r"[0-9a-f]{64}", value):
    raise SystemExit("durable container cidfile does not contain one exact container ID")
print(value)
PY
  ) || return 1

  txn_docker_bin=${TXN_DOCKER_BIN:-docker}
  command -v "$txn_docker_bin" >/dev/null 2>&1 || {
    txn_error 'docker is required to reconcile the durable container identity.'
    return 1
  }
  txn_inspect=$TXN_RUNTIME_ROOT/container-inspect.json
  "$txn_docker_bin" inspect "$txn_container_id" > "$txn_inspect" || return 1
  chmod 0600 "$txn_inspect"
  txn_identity=$(python3 - "$txn_intent" "$txn_container_id" "$txn_inspect" <<'PY'
import json
import sys

intent = json.loads(sys.argv[1])
container_id = sys.argv[2]
rows = json.load(open(sys.argv[3], encoding="utf-8"))
if not isinstance(rows, list) or len(rows) != 1 or not isinstance(rows[0], dict):
    raise SystemExit("docker inspect did not return exactly one container")
row = rows[0]
labels = row.get("Config", {}).get("Labels", {})
if row.get("Id") != container_id or row.get("Name") != "/" + intent["container_name"]:
    raise SystemExit("cidfile container does not match the exact journaled name")
if not isinstance(labels, dict) or labels.get(intent["label_name"]) != intent["label_value"]:
    raise SystemExit("cidfile container does not match the exact journaled ownership label")
identity = dict(intent)
identity["container_id"] = container_id
print(json.dumps(identity, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
PY
  ) || return 1

  if txn_create_key=$(txn_resource_key_for_identity create container "$txn_identity"); then
    :
  else
    txn_record create container "$txn_identity" || return 1
    txn_create_key=$TXN_LAST_RESOURCE_KEY
  fi
  txn_key_is_done "$txn_create_key" || txn_mark_done "$txn_create_key" || return 1
  txn_intent_key=$(txn_resource_key_for_identity intent container-create "$txn_intent") || return 1
  if ! txn_key_is_done "$txn_intent_key"; then
    txn_mark_done "$txn_intent_key" || return 1
  fi
  printf '%s\n' "$txn_container_id"
}

txn_assert_inbox_journaled() {
  txn_candidate_id=$1
  txn_candidate_found=false
  while IFS= read -r txn_recorded_id; do
    if test "$txn_recorded_id" = "$txn_candidate_id"; then
      txn_candidate_found=true
      break
    fi
  done < <(txn_created_ids)
  test "$txn_candidate_found" = true || {
    txn_error 'refusing cleanup of an inbox identity not created by this transaction.'
    return 1
  }
}

txn_assert_list_composite_journaled() {
  txn_candidate_composite=$(printf '%s\t%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4" "$5")
  txn_candidate_found=false
  while IFS= read -r txn_recorded_composite; do
    if test "$txn_recorded_composite" = "$txn_candidate_composite"; then
      txn_candidate_found=true
      break
    fi
  done < <(txn_created_list_composites)
  test "$txn_candidate_found" = true || {
    txn_error 'refusing cleanup of an allowlist composite not created by this transaction.'
    return 1
  }
}

txn_delete_inbox_exact() {
  txn_require_initialized || return 1
  txn_require_helper || return 1
  txn_exact_inbox_id=$1
  test -n "$txn_exact_inbox_id" && ! printf '%s' "$txn_exact_inbox_id" | grep -q '[[:cntrl:]]' || {
    txn_error 'refusing unsafe inbox identity.'
    return 1
  }
  txn_assert_inbox_journaled "$txn_exact_inbox_id" || return 1
  if test -n "${AGENTMAIL_MUTATION_FORBIDDEN_ID:-}" && \
      test "$txn_exact_inbox_id" = "$AGENTMAIL_MUTATION_FORBIDDEN_ID"; then
    txn_error 'refusing cleanup of the protected stable inbox ID.'
    return 1
  fi
  txn_output=$TXN_RUNTIME_ROOT/cleanup-inboxes.json
  chmod 0600 "$txn_output" 2>/dev/null || true

  txn_helper list-inboxes > "$txn_output"
  chmod 0600 "$txn_output"
  if python3 - "$txn_output" "$txn_exact_inbox_id" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
raise SystemExit(0 if any(row.get("inbox_id") == sys.argv[2] for row in data.get("inboxes", [])) else 1)
PY
  then
    txn_expected=$TXN_RUNTIME_ROOT/cleanup-inbox-expected.json
    txn_actual=$TXN_RUNTIME_ROOT/cleanup-inbox-actual.json
    txn_expected_inbox_identity "$txn_exact_inbox_id" > "$txn_expected"
    txn_helper get-inbox --id "$txn_exact_inbox_id" > "$txn_actual"
    chmod 0600 "$txn_expected" "$txn_actual"
    python3 - "$txn_expected" "$txn_actual" <<'PY'
import json, sys
expected = json.load(open(sys.argv[1], encoding="utf-8"))
actual = json.load(open(sys.argv[2], encoding="utf-8"))
if expected != actual:
    raise SystemExit("exact inbox metadata does not match the journal; refusing deletion")
PY
    txn_helper delete-inbox --id "$txn_exact_inbox_id" > "$txn_output"
    for txn_absence_attempt in 1 2 3 4 5; do
      txn_helper list-inboxes > "$txn_output" || return 1
      if python3 - "$txn_output" "$txn_exact_inbox_id" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
raise SystemExit(0 if not any(row.get("inbox_id") == sys.argv[2] for row in data.get("inboxes", [])) else 1)
PY
      then
        break
      fi
      test "$txn_absence_attempt" -lt 5 && sleep 0.2
    done
  fi

  python3 - "$txn_output" "$txn_exact_inbox_id" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
if any(row.get("inbox_id") == sys.argv[2] for row in data.get("inboxes", [])):
    raise SystemExit("exact journaled inbox is still present after cleanup")
PY
}

txn_delete_list_composite_exact() {
  txn_require_initialized || return 1
  txn_require_helper || return 1
  txn_scope=$1
  txn_scope_id=$2
  txn_direction=$3
  txn_type=$4
  txn_entry=$5
  txn_assert_list_composite_journaled "$txn_scope" "$txn_scope_id" "$txn_direction" "$txn_type" "$txn_entry" || return 1
  if test -n "${AGENTMAIL_MUTATION_FORBIDDEN_ID:-}" && \
      test "$txn_scope_id" = "$AGENTMAIL_MUTATION_FORBIDDEN_ID"; then
    txn_error 'refusing cleanup in the protected stable inbox scope.'
    return 1
  fi
  if test -n "${AGENTMAIL_MUTATION_FORBIDDEN_ADDRESS:-}" && \
      { test "$txn_scope_id" = "$AGENTMAIL_MUTATION_FORBIDDEN_ADDRESS" || \
        test "$txn_entry" = "$AGENTMAIL_MUTATION_FORBIDDEN_ADDRESS"; }; then
    txn_error 'refusing cleanup involving the protected stable inbox address.'
    return 1
  fi
  txn_output=$TXN_RUNTIME_ROOT/cleanup-list.json
  chmod 0600 "$txn_output" 2>/dev/null || true

  txn_helper lists \
    --scope "$txn_scope" --scope-id "$txn_scope_id" \
    --direction "$txn_direction" --type "$txn_type" > "$txn_output"
  chmod 0600 "$txn_output"
  if python3 - "$txn_output" "$txn_entry" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
raise SystemExit(0 if any(row.get("entry") == sys.argv[2] for row in data.get("entries", [])) else 1)
PY
  then
    txn_helper lists-delete-by-composite \
      --scope "$txn_scope" --scope-id "$txn_scope_id" \
      --direction "$txn_direction" --type "$txn_type" --entry "$txn_entry" \
      > "$txn_output"
    for txn_absence_attempt in 1 2 3 4 5; do
      txn_helper lists \
        --scope "$txn_scope" --scope-id "$txn_scope_id" \
        --direction "$txn_direction" --type "$txn_type" > "$txn_output" || return 1
      if python3 - "$txn_output" "$txn_entry" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
raise SystemExit(0 if not any(row.get("entry") == sys.argv[2] for row in data.get("entries", [])) else 1)
PY
      then
        break
      fi
      test "$txn_absence_attempt" -lt 5 && sleep 0.2
    done
  fi

  python3 - "$txn_output" "$txn_entry" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
if any(row.get("entry") == sys.argv[2] for row in data.get("entries", [])):
    raise SystemExit("exact journaled allowlist entry is still present after cleanup")
PY
}

txn_cleanup_all() {
  txn_require_initialized || return 1
  if test "${TXN_CLEANUP_ACTIVE:-false}" = true; then
    return 0
  fi
  TXN_CLEANUP_ACTIVE=true

  # Resolve every ambiguous create response before deleting any resource. A
  # zero or multiple match is uncertainty, not absence, and stops cleanup.
  txn_reconcile_unfinished_inbox_intents || {
    TXN_CLEANUP_ACTIVE=false
    return 1
  }

  txn_composites=$(txn_created_list_composites) || {
    TXN_CLEANUP_ACTIVE=false
    return 1
  }
  while IFS=$'\t' read -r txn_scope txn_scope_id txn_direction txn_type txn_entry; do
    test -n "$txn_scope" || continue
    txn_delete_list_composite_exact "$txn_scope" "$txn_scope_id" "$txn_direction" "$txn_type" "$txn_entry" || {
      TXN_CLEANUP_ACTIVE=false
      return 1
    }
  done <<< "$txn_composites"

  txn_inbox_ids=$(txn_created_ids) || {
    TXN_CLEANUP_ACTIVE=false
    return 1
  }
  while IFS= read -r txn_inbox_id; do
    test -n "$txn_inbox_id" || continue
    txn_delete_inbox_exact "$txn_inbox_id" || {
      TXN_CLEANUP_ACTIVE=false
      return 1
    }
  done <<< "$txn_inbox_ids"

  TXN_CLEANUP_ACTIVE=false
  return 0
}

txn_fail_inconclusive() {
  txn_reason=${1:-unspecified cleanup uncertainty}
  TXN_INCONCLUSIVE=true
  export TXN_INCONCLUSIVE
  printf 'INCONCLUSIVE CLEANUP: %s; refusing deletion by inference.\n' "$txn_reason" >&2
  exit 1
}

txn_self_test() (
  set -euo pipefail
  txn_test_parent=$(mktemp -d "${TMPDIR:-/tmp}/machtiani-txn-self-test.XXXXXX")
  chmod 0700 "$txn_test_parent"
  trap 'rm -rf -- "$txn_test_parent"' EXIT HUP INT TERM
  TMPDIR=$txn_test_parent
  TXN_KEEP_RUNTIME=1
  TXN_CLEANUP_ENABLED=0
  export TMPDIR TXN_KEEP_RUNTIME TXN_CLEANUP_ENABLED

  txn_init
  test "$(stat -c '%a' "$TXN_RUNTIME_ROOT")" = 700
  test "$(stat -c '%a' "$TXN_JOURNAL")" = 600

  ! txn_record create inbox 'not-json' 2>/dev/null
  ! txn_mark_done missing-key 2>/dev/null

  # The fake transport models response loss, successful response receipt,
  # allowlist cleanup, protected baseline state, and final restoration.
  txn_fake_helper=$txn_test_parent/fake-agentmail-helper
  txn_fake_state=$txn_test_parent/fake-state
  txn_fake_list_state=$txn_test_parent/fake-list-state
  txn_fake_calls=$txn_test_parent/fake-calls
  printf '%s\n' \
    '#!/usr/bin/env python3' \
    'from pathlib import Path' \
    'import json, os, sys' \
    'assert "AGENTMAIL_BASE_URL" not in os.environ and "AGENTMAIL_CUSTOM_HEADERS" not in os.environ' \
    'state=Path(os.environ["TXN_FAKE_STATE"])' \
    'list_state=Path(os.environ["TXN_FAKE_LIST_STATE"])' \
    'calls=Path(os.environ["TXN_FAKE_CALLS"])' \
    'row={"inbox_id":"inbox-recovered","email":"recovered@example.invalid","pod_id":"pod-self-test","client_id":"client-self-test","display_name":"display-self-test","metadata":{"machtiani_ipe_run":"run-self-test","machtiani_ipe_role":"receiver"},"created_at":"2026-01-01T00:00:00Z"}' \
    'command=sys.argv[1]' \
    'if command=="create-inbox":' \
    '    state.write_text("present\n")' \
    '    if os.environ.get("TXN_FAKE_CREATE_MODE")=="response-loss": raise SystemExit(75)' \
    '    print(json.dumps(row,separators=(",",":")))' \
    'elif command=="list-inboxes":' \
    '    protected={"inbox_id":"inbox-protected","email":"protected@example.invalid"}' \
    '    current=state.read_text().strip()' \
    '    rows=[protected]' \
    '    if current in ("present","ambiguous"): rows.insert(0,row)' \
    '    if current=="ambiguous": rows.insert(1,{**row,"inbox_id":"inbox-recovered-two"})' \
    '    print(json.dumps({"inboxes":rows},separators=(",",":")))' \
    'elif command=="get-inbox":' \
    '    assert sys.argv[2:]==["--id","inbox-recovered"]' \
    '    print(json.dumps(row,separators=(",",":")))' \
    'elif command=="delete-inbox":' \
    '    assert sys.argv[2:]==["--id","inbox-recovered"]' \
    '    calls.write_text(calls.read_text()+"delete-inbox:inbox-recovered\n")' \
    '    state.write_text("absent\n")' \
    '    print(json.dumps({"deleted":True,"inbox_id":"inbox-recovered"},separators=(",",":")))' \
    'elif command=="lists":' \
    '    entries=[]' \
    '    if list_state.read_text().strip()=="present": entries=[{"scope":"inbox","scope_id":"inbox-recovered","direction":"receive","type":"allow","entry":"sender@example.invalid"}]' \
    '    print(json.dumps({"entries":entries},separators=(",",":")))' \
    'elif command=="lists-delete-by-composite":' \
    '    calls.write_text(calls.read_text()+"delete-list:"+" ".join(sys.argv[2:])+"\n")' \
    '    list_state.write_text("absent\n")' \
    '    print(json.dumps({"deleted":True},separators=(",",":")))' \
    'else:' \
    '    raise SystemExit(64)' > "$txn_fake_helper"
  chmod 0700 "$txn_fake_helper"
  TXN_AGENTMAIL_HELPER=$txn_fake_helper
  TXN_FAKE_STATE=$txn_fake_state
  TXN_FAKE_LIST_STATE=$txn_fake_list_state
  TXN_FAKE_CALLS=$txn_fake_calls
  export TXN_AGENTMAIL_HELPER TXN_FAKE_STATE TXN_FAKE_LIST_STATE TXN_FAKE_CALLS
  AGENTMAIL_MUTATION_FORBIDDEN_ID=inbox-protected
  AGENTMAIL_MUTATION_FORBIDDEN_ADDRESS=protected@example.invalid
  export AGENTMAIL_MUTATION_FORBIDDEN_ID AGENTMAIL_MUTATION_FORBIDDEN_ADDRESS

  reset_fake_case() {
    : > "$TXN_JOURNAL"
    TXN_CLEANUP_ACTIVE=false
    printf '%s\n' absent > "$txn_fake_state"
    printf '%s\n' absent > "$txn_fake_list_state"
    : > "$txn_fake_calls"
    chmod 0600 "$txn_fake_state" "$txn_fake_list_state" "$txn_fake_calls"
  }

  inbox_intent='{"client_id":"client-self-test","display_name":"display-self-test","run_id":"run-self-test","role":"receiver"}'
  allow_identity='{"scope":"inbox","scope_id":"inbox-recovered","direction":"receive","type":"allow","entry":"sender@example.invalid"}'

  # Response loss: the fake API mutates and returns no response. Cleanup must
  # reconcile the one complete tuple, journal its exact identity, delete the
  # allowlist first, then delete only that inbox and restore the baseline.
  reset_fake_case
  txn_record intent inbox-create "$inbox_intent"
  txn_record create allowlist-entry "$allow_identity"
  printf '%s\n' present > "$txn_fake_list_state"
  TXN_FAKE_CREATE_MODE=response-loss
  export TXN_FAKE_CREATE_MODE
  ! txn_helper create-inbox >/dev/null 2>&1
  unset TXN_FAKE_CREATE_MODE
  AGENTMAIL_BASE_URL=http://127.0.0.1:1
  AGENTMAIL_CUSTOM_HEADERS='X-Untrusted: blocked'
  export AGENTMAIL_BASE_URL AGENTMAIL_CUSTOM_HEADERS
  txn_cleanup_all
  unset AGENTMAIL_BASE_URL AGENTMAIL_CUSTOM_HEADERS
  test "$(txn_created_ids)" = inbox-recovered
  test "$(sed -n '1p' "$txn_fake_state")" = absent
  test "$(sed -n '1p' "$txn_fake_list_state")" = absent
  test "$(sed -n '1p' "$txn_fake_calls")" = 'delete-list:--scope inbox --scope-id inbox-recovered --direction receive --type allow --entry sender@example.invalid'
  test "$(sed -n '2p' "$txn_fake_calls")" = 'delete-inbox:inbox-recovered'
  test "$(wc -l < "$txn_fake_calls")" -eq 2

  # Signal after response receipt but before exact journaling is represented by
  # a successful response file plus an intent-only journal. The same cleanup
  # recovery must succeed and remain idempotent.
  reset_fake_case
  txn_record intent inbox-create "$inbox_intent"
  txn_helper create-inbox > "$txn_test_parent/received-response.json"
  chmod 0600 "$txn_test_parent/received-response.json"
  txn_cleanup_all
  txn_cleanup_all
  test "$(wc -l < "$txn_fake_calls")" -eq 1
  test "$(sed -n '1p' "$txn_fake_calls")" = 'delete-inbox:inbox-recovered'

  # Ambiguous reconciliation must stop txn_cleanup_all before even an exact
  # journaled allowlist deletion. Its diagnostic includes the tuple and count.
  reset_fake_case
  txn_record intent inbox-create "$inbox_intent"
  txn_record create allowlist-entry "$allow_identity"
  printf '%s\n' ambiguous > "$txn_fake_state"
  printf '%s\n' present > "$txn_fake_list_state"
  ambiguity_error=$txn_test_parent/ambiguity.stderr
  ! txn_cleanup_all 2> "$ambiguity_error"
  test ! -s "$txn_fake_calls"
  grep -Fq 'matched 2 inboxes; expected exactly one; no deletion has occurred' "$ambiguity_error"

  # Protected and non-journaled identities remain undeletable.
  ! txn_delete_inbox_exact inbox-protected 2>/dev/null
  unset AGENTMAIL_MUTATION_FORBIDDEN_ID
  unset AGENTMAIL_MUTATION_FORBIDDEN_ADDRESS

  # Simulated SIGKILL/interrupt window: only the durable intent and cidfile
  # exist; no shell container variable was assigned. Reconciliation validates
  # ID ownership against exact Docker name/label before journaling it.
  reset_fake_case
  container_id_self_test=$(printf 'a%.0s' {1..64})
  cidfile=$TXN_RUNTIME_ROOT/container.cid
  printf '%s\n' "$container_id_self_test" > "$cidfile"
  chmod 0600 "$cidfile"
  container_intent=$(python3 - "$cidfile" <<'PY'
import json,sys
print(json.dumps({"container_name":"container-self-test","cidfile":sys.argv[1],"label_name":"test.owner","label_value":"run-self-test"}, sort_keys=True, separators=(",",":")))
PY
)
  txn_record intent container-create "$container_intent"
  txn_fake_docker=$txn_test_parent/fake-docker
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'test "$1" = inspect && test "$2" = "$(printf "a%.0s" {1..64})"' \
    'printf '\''[{"Id":"%s","Name":"/container-self-test","Config":{"Labels":{"test.owner":"%s"}}}]\n'\'' "$2" "${TXN_FAKE_CONTAINER_LABEL:-run-self-test}"' \
    > "$txn_fake_docker"
  chmod 0700 "$txn_fake_docker"
  TXN_DOCKER_BIN=$txn_fake_docker
  export TXN_DOCKER_BIN
  test "$(txn_reconcile_container_from_cidfile container-self-test)" = "$container_id_self_test"
  test -n "$(txn_resource_key_for_identity intent container-create "$container_intent")"
  test "$(grep -c '"kind":"container"' "$TXN_JOURNAL")" -eq 1

  # A mismatched label or unsafe cidfile ownership/mode cannot become an owned
  # container identity.
  reset_fake_case
  txn_record intent container-create "$container_intent"
  TXN_FAKE_CONTAINER_LABEL=other-run
  export TXN_FAKE_CONTAINER_LABEL
  ! txn_reconcile_container_from_cidfile container-self-test >/dev/null 2>&1
  unset TXN_FAKE_CONTAINER_LABEL
  chmod 0644 "$cidfile"
  ! txn_reconcile_container_from_cidfile container-self-test >/dev/null 2>&1
  chmod 0600 "$cidfile"

  fail_output=$txn_test_parent/inconclusive.stderr
  if (trap - EXIT HUP INT TERM; txn_fail_inconclusive 'self-test reason') 2> "$fail_output"; then
    txn_error 'txn_fail_inconclusive unexpectedly succeeded.'
    exit 1
  fi
  grep -Fq 'INCONCLUSIVE CLEANUP: self-test reason; refusing deletion by inference.' "$fail_output"

  trap - EXIT HUP INT TERM
  printf 'txn.sh self-test, response-loss/signal recovery, allowlist cleanup, fail-closed ambiguity, container ownership, and baseline restoration passed\n'
)

if test "${BASH_SOURCE[0]}" = "$0"; then
  case "${1:-}" in
    --self-test) txn_self_test ;;
    *)
      txn_error 'usage: txn.sh --self-test'
      exit 2
      ;;
  esac
fi
