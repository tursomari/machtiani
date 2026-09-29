# Uninstall container acceptance

This umbrella-owned integration gate tests the actual candidate DearMachine
CLI and installer/concierge together. Start at the root `TESTING.md` for suite
selection. Component unit tests remain in DearMachine and Installer.

Build the candidate native and Installer Nix packages, then run from the
umbrella checkout on the build host:

```sh
python3 tests/uninstall/run.py \
  --native /nix/store/<candidate-native>/bin/dearmachine \
  --installer /nix/store/<candidate-installer>/bin/machtiani-installer \
  --python /nix/store/<python>/bin/python3 \
  --image debian:bookworm-slim
```

The image must already be cached; the runner resolves its immutable ID and
does not pull. It copies exact Nix runtime closures and the test script into a
disposable container tmpfs. Streaming the closures avoids building duplicate disk layers. There are no host mounts, Git metadata, credentials, host
services or network access. Tests run as an ordinary container user with all
container capabilities dropped. The host runner removes only its own container. Builds happen on the host, before this gate.

The installation fixture uses real candidate executables with a managed release
layout; acquisition and model/email providers are not exercised. Tests drive a
real PTY, native supervisor and concierge with a disposable SQLite database and
fake private files. Assertions inspect the live container before fixture or
container cleanup, so teardown cannot supply evidence of uninstall success.

Coverage includes confirmation decline/EOF, noninteractive refusal, instruction-only
`/uninstall`, running-process shutdown, binary self-removal, private-data removal,
update-lock rejection, changed roots, interior symlink preservation, independent
user data, open databases, protected product processes and partial deletion
failures. A real DearMachine daemon opens its real pair database: initial harness
sync is a no-op fixture and a fake transport key runs only with networking disabled.
The Nix closure in the image is test infrastructure and shared immutable package
content, not an installed user release subject to deletion.

## Live systemd variant

Prepare a disposable base image with systemd and dbus using
`docker build -f tests/uninstall/Dockerfile.systemd -t uninstall-systemd-base tests/uninstall`.
Image preparation downloads OS packages; the test itself is offline and records
the exact cached image ID. Repeat the command above with
`--systemd --image uninstall-systemd-base` to run the separate service case.

This variant boots a real container-local systemd and user manager. It needs
Docker cgroup v2, a **private** cgroup namespace and `CAP_SYS_ADMIN` to remount
that namespace's cgroup filesystem writable. On AppArmor hosts, the runner uses
`--security-opt apparmor=unconfined` for this container only because Docker's
default profile denies mount operations even with `CAP_SYS_ADMIN`. Seccomp
remains enabled; the ordinary uninstall variant retains AppArmor and drops
all capabilities. It uses tmpfs for `/run` and
mounts no host directory, service socket or cgroup directory. It does not use
`--privileged` or a host cgroup namespace. The base image must include
`/lib/systemd/systemd`, `loginctl`, `systemctl` and dbus user sessions.

The test uses the native service generator, then runs the native supervisor
under that unit with a disposable child. It proves cancellation preserves the
active service, confirmation stops/disables it, unit and drop-in files disappear,
and an independent enabled service and account-wide lingering survive. Root is
used only to initialize the container's user manager; uninstall runs as tester.

## Standard portable installation

The umbrella `tests/standard-curl-smoke.py` gate also proves the actual curl
bootstrap, declined and confirmed running uninstall, fresh bootstrap after
download-cache deletion, and a second complete uninstall without `/nix`. Its
verifier remains outside the installed bundle. Supply the candidate's prepared
download and a cached Debian image with curl, as documented in root `TESTING.md`.

## Docker-built installation

After building the production Docker `release` target, run:

```sh
python3 tests/uninstall/container-build.py --runtime-image <cached-release-image-id>
```

This offline gate copies the raw runtime into a disposable Debian container,
relocates it, and invokes production activation with a fixed source identity and
an already-built payload. It does not repeat wizard interaction or compilation.
A separate process holds the actual builder lock: uninstall must refuse without
stopping the supervisor or deleting data. Once released, the gate proves declined
confirmation and successful running uninstall, including the relocated software
and public commands. The host verifier and base shell survive self-removal.
There are no host mounts, credentials, Git metadata or Docker socket in the guest.
Supply `--image` to select a different cached Debian base; both image IDs are
resolved and reported. Only the gate's disposable containers are removed.

Live IXE/QSE remain experience/release gates, not the destructive-test inner loop.
