# Booted NixOS runtime smoke test

Run `nix build .#checks.x86_64-linux.installation --no-write-lock-file` from
this directory. For a development installer, append `--override-input installer
path:/absolute/path/to/installer-worktree`. The test uses the installer's pinned
Nixpkgs; KVM is recommended.

A real NixOS guest installs the installer runtime in an ordinary user's Nix
profile and executes its public entrypoints before and after a reboot. A
separate user-service probe checks restart and boot persistence. The guest
uses a store image with no host repository, home, credential or Docker socket
mount. It makes no provider requests.

This is an installer-runtime and NixOS supervision smoke test. The service
probe is not the Dear Machine daemon. It does not verify native product
acquisition, backend authentication, live email, or a complete installation.
Use IXE for those checks. It introduces no installer UI or method-order changes.
