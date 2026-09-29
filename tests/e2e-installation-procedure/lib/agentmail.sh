#!/usr/bin/env bash

# Host-side read-only AgentMail snapshots and host-client identity checks.

agentmail_error() {
  printf 'AGENTMAIL HARNESS ERROR: %s\n' "$*" >&2
}

agentmail_require_runtime() {
  test -n "${TXN_RUNTIME_ROOT:-}" && test -d "$TXN_RUNTIME_ROOT" || {
    agentmail_error 'transaction runtime is not initialized'
    return 1
  }
  test -n "${TXN_AGENTMAIL_HELPER:-}" && test -x "$TXN_AGENTMAIL_HELPER" || {
    agentmail_error 'AgentMail helper is unavailable'
    return 1
  }
}

agentmail_helper() {
  agentmail_require_runtime || return 1
  env -u AGENTMAIL_BASE_URL -u AGENTMAIL_CUSTOM_HEADERS \
    "$TXN_AGENTMAIL_HELPER" "$@"
}

agentmail_discover_host_client_address() {
  python3 - <<'PY'
from pathlib import Path
import tomllib

matches=[]
for process in Path("/proc").iterdir():
    if not process.name.isdigit():
        continue
    try:
        argv=[part.decode("utf-8", errors="replace") for part in (process/"cmdline").read_bytes().split(b"\0") if part]
    except OSError:
        continue
    if not argv or Path(argv[0]).name!="dearmachine":
        continue
    if "--inbox-id" in argv:
        index=argv.index("--inbox-id")
        if index+1<len(argv) and "@" in argv[index+1]:
            matches.append(argv[index+1])
        continue
    try:
        environment=dict(item.split(b"=",1) for item in (process/"environ").read_bytes().split(b"\0") if b"=" in item)
        home=Path(environment[b"HOME"].decode())
        registry=tomllib.loads((home/".dearmachine"/"pairs.toml").read_text())
        addresses={row.get("address","") for row in registry.get("inboxes",[]) if "@" in row.get("address","")}
    except (OSError, KeyError, UnicodeDecodeError, tomllib.TOMLDecodeError):
        continue
    matches.extend(addresses)
if len(matches)>1:
    raise SystemExit(f"expected at most one address-polling host DearMachine client, found {len(matches)}")
if matches:
    print(matches[0])
PY
}

agentmail_discover_stable_inbox_address() {
  agentmail_helper list-inboxes | python3 -c '
import json, sys
rows = json.load(sys.stdin)["inboxes"]
requested = sys.argv[1]
if requested:
    matches = [row for row in rows if row["email"].casefold() == requested.casefold()]
    if len(matches) != 1:
        raise SystemExit("IPE_STABLE_INBOX_ADDRESS must match exactly one existing AgentMail inbox")
    print(matches[0]["email"])
    raise SystemExit(0)
if len(rows) != 1:
    raise SystemExit(f"host DearMachine client is stopped and the stable inbox is ambiguous: found {len(rows)} inboxes")
print(rows[0]["email"])
' "${IPE_STABLE_INBOX_ADDRESS:-}"
}

agentmail_snapshot_host_client() {
  agentmail_output=$1
  agentmail_stable_address=$2
  python3 - "$agentmail_output" "$agentmail_stable_address" <<'PY'
from pathlib import Path
import json
import os
import sys
import tomllib

output = Path(sys.argv[1])
stable = sys.argv[2]
matches = []
for process in Path("/proc").iterdir():
    if not process.name.isdigit():
        continue
    try:
        raw = (process / "cmdline").read_bytes()
        argv = [part.decode("utf-8", errors="replace") for part in raw.split(b"\0") if part]
        executable = os.readlink(process / "exe")
        stat_text = (process / "stat").read_text(encoding="utf-8")
    except OSError:
        continue
    if not argv or Path(argv[0]).name != "dearmachine":
        continue
    inboxes = set()
    for index, argument in enumerate(argv[:-1]):
        if argument == "--inbox-id":
            inboxes.add(argv[index + 1])
            break
    if not inboxes:
        try:
            environment=dict(item.split(b"=",1) for item in (process/"environ").read_bytes().split(b"\0") if b"=" in item)
            home=Path(environment[b"HOME"].decode())
            registry=tomllib.loads((home/".dearmachine"/"pairs.toml").read_text())
            inboxes={row.get("address","") for row in registry.get("inboxes",[])}
        except (OSError, KeyError, UnicodeDecodeError, tomllib.TOMLDecodeError):
            pass
    if stable not in inboxes:
        continue
    tail = stat_text[stat_text.rfind(")") + 2:].split()
    matches.append({
        "pid": int(process.name),
        "start_time": tail[19],
        "executable": executable,
        "cmdline": argv,
        "inbox_address": stable,
    })
if len(matches) != 1:
    raise SystemExit(f"expected exactly one stable DearMachine client, found {len(matches)}")
encoded = (json.dumps(matches[0], sort_keys=True, separators=(",", ":")) + "\n").encode()
descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
try:
    os.write(descriptor, encoded)
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
}

agentmail_assert_host_client_unchanged() {
  agentmail_snapshot=$1
  python3 - "$agentmail_snapshot" <<'PY'
from pathlib import Path
import json
import os
import sys

record = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
process = Path("/proc") / str(record["pid"])
try:
    argv = [part.decode("utf-8", errors="replace") for part in (process / "cmdline").read_bytes().split(b"\0") if part]
    executable = os.readlink(process / "exe")
    stat_text = (process / "stat").read_text(encoding="utf-8")
except OSError as error:
    raise SystemExit(f"stable DearMachine client disappeared: {error}")
tail = stat_text[stat_text.rfind(")") + 2:].split()
if tail[19] != record["start_time"] or argv != record["cmdline"] or executable != record["executable"]:
    raise SystemExit("stable DearMachine client identity changed")
PY
}

agentmail_snapshot() {
  agentmail_require_runtime || return 1
  agentmail_output=$1
  agentmail_stable_address=$2
  agentmail_work=$(mktemp -d "$TXN_RUNTIME_ROOT/snapshot-work.XXXXXX")
  chmod 0700 "$agentmail_work"
  agentmail_helper list-inboxes > "$agentmail_work/inboxes.json"
  agentmail_helper get-organization > "$agentmail_work/organization.json"
  agentmail_helper list-pods > "$agentmail_work/pods.json"
  chmod 0600 "$agentmail_work"/*.json

  agentmail_stable_id=$(python3 - "$agentmail_work/inboxes.json" "$agentmail_stable_address" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1], encoding="utf-8"))["inboxes"]
matches = [row for row in rows if row["email"].casefold() == sys.argv[2].casefold()]
if len(matches) != 1:
    raise SystemExit(f"expected one stable inbox record, found {len(matches)}")
print(matches[0]["inbox_id"])
PY
) || return 1
  agentmail_org_id=$(python3 - "$agentmail_work/organization.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["organization_id"])
PY
)
  : > "$agentmail_work/lists.jsonl"
  chmod 0600 "$agentmail_work/lists.jsonl"

  agentmail_scopes=$agentmail_work/scopes.tsv
  printf 'inbox\t%s\norg\t%s\n' "$agentmail_stable_id" "$agentmail_org_id" > "$agentmail_scopes"
  python3 - "$agentmail_work/pods.json" >> "$agentmail_scopes" <<'PY'
import json, sys
for pod in json.load(open(sys.argv[1], encoding="utf-8"))["pods"]:
    print(f"pod\t{pod['pod_id']}")
PY
  chmod 0600 "$agentmail_scopes"

  while IFS=$'\t' read -r agentmail_scope agentmail_scope_id; do
    for agentmail_direction in send receive reply; do
      for agentmail_type in allow block; do
        agentmail_helper lists \
          --scope "$agentmail_scope" --scope-id "$agentmail_scope_id" \
          --direction "$agentmail_direction" --type "$agentmail_type" \
          >> "$agentmail_work/lists.jsonl"
      done
    done
  done < "$agentmail_scopes"

  python3 - "$agentmail_work/inboxes.json" "$agentmail_work/organization.json" \
    "$agentmail_work/pods.json" "$agentmail_work/lists.jsonl" "$agentmail_stable_address" \
    "$agentmail_output" <<'PY'
from pathlib import Path
import json
import os
import sys

inbox_path, org_path, pod_path, lists_path, stable_address, output_path = sys.argv[1:]
inboxes = json.load(open(inbox_path, encoding="utf-8"))["inboxes"]
organization = json.load(open(org_path, encoding="utf-8"))
pods = json.load(open(pod_path, encoding="utf-8"))["pods"]
entries = []
with open(lists_path, encoding="utf-8") as stream:
    for line in stream:
        entries.extend(json.loads(line)["entries"])
stable = [row for row in inboxes if row["email"].casefold() == stable_address.casefold()]
if len(stable) != 1:
    raise SystemExit("stable inbox identity became ambiguous during snapshot")
data = {
    "inboxes": sorted(inboxes, key=lambda row: row["inbox_id"]),
    "organization": organization,
    "pods": sorted(pods, key=lambda row: row["pod_id"]),
    "lists": sorted(entries, key=lambda row: (
        row["scope"], row["scope_id"], row["direction"], row["type"], row["entry"],
        row["entry_type"], row["list_type"], str(row["read_only"]), row["reason"],
        row["created_at"],
    )),
    "stable_inbox": stable[0],
}
encoded = (json.dumps(data, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode()
descriptor = os.open(output_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
try:
    os.write(descriptor, encoded)
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
  find "$agentmail_work" -depth -delete
}

agentmail_snapshot_stable_id() {
  python3 - "$1" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["stable_inbox"]["inbox_id"])
PY
}

agentmail_compare_snapshots() {
  python3 - "$1" "$2" <<'PY'
from pathlib import Path
import json, sys
before = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
after = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
if before != after:
    for key in ("stable_inbox", "inboxes", "organization", "pods", "lists"):
        if before.get(key) != after.get(key):
            print(f"unexpected AgentMail baseline difference: {key}", file=sys.stderr)
    raise SystemExit(1)
PY
}

agentmail_wait_for_baseline() {
  agentmail_before=$1
  agentmail_after=$2
  agentmail_stable_address=$3
  for agentmail_baseline_attempt in 1 2 3 4 5; do
    agentmail_candidate=$agentmail_after.attempt-$agentmail_baseline_attempt
    if agentmail_snapshot "$agentmail_candidate" "$agentmail_stable_address" && \
       agentmail_compare_snapshots "$agentmail_before" "$agentmail_candidate"; then
      mv -- "$agentmail_candidate" "$agentmail_after"
      return 0
    fi
    rm -f -- "$agentmail_candidate"
    test "$agentmail_baseline_attempt" -lt 5 && sleep 0.5
  done
  agentmail_error 'final AgentMail baseline did not converge after five bounded checks'
  return 1
}
