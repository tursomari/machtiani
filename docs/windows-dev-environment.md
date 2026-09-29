# Windows development environment

## Purpose

Use this environment to test Machtiani on Windows 11 in a KVM/libvirt virtual machine on the Linux host. The complete virtualization stack comes from nixpkgs; do not install host packages with `pacman`.

## Preflight environment check

Check memory first:

```bash
free -h
```

Read the `Mem:` row's `available` value. Before creating an 8 GiB guest, the host needs roughly 10 GiB available for guest RAM plus host and virtualization overhead. If less than 10 GiB is available, close browsers, development tools, and other memory-heavy applications before continuing. Treat small or exhausted swap as no safety margin.

Confirm that the current user can access KVM:

```bash
[ -r /dev/kvm ] && [ -w /dev/kvm ] && echo "KVM OK" || echo "KVM missing/not accessible"
```

The expected result is `KVM OK`. Confirm Intel nested virtualization:

```bash
cat /sys/module/kvm_intel/parameters/nested
```

The expected result is `Y` or `1`. On an AMD host, the equivalent parameter is `/sys/module/kvm_amd/parameters/nested`.

## Install from nixpkgs

Use one immutable nixpkgs revision for evaluation, download, and installation. The validated revision is `6b5e5b7a6631f065bf6908986990b37d845f847f`, with source NAR hash `sha256-smTKQXMLLStzc8zJevMCckbk3My7SvbbLmPYZUJJKW4=`.

| nixpkgs attribute | Version |
| --- | --- |
| `libvirt` | 12.6.0 |
| `virt-manager` | 5.1.0 |
| `qemu_kvm` | 11.0.3, host-CPU-only build |
| `OVMF` | edk2 202605, `fd` output |
| `swtpm` | 0.10.1-unstable-2026-05-21; the binary reports 0.11.0 |
| `virtio-win` | 0.1.285-1 |

The native Windows proof used `OVMFFull.fd` (edk2 202605): its firmware
supports TPM 2.0 and Secure Boot with the Microsoft-enrolled variable template.
The plain `OVMF.fd` image did not expose the required TPM/Secure Boot support
in that Q35 guest. Give each VM its own writable copy of the matching variable
store; leave firmware in the Nix store read-only. See
[the native proof](../tests/windows-native/README.md) for its bounded scope.

Do not substitute `qemu_full` at this revision. It is not available from `cache.nixos.org` and would trigger a large local source build. `qemu_kvm` is cache-backed and provides the KVM accelerator and Q35 machines needed by this x86_64 host.

Nix 2.24 cannot directly build or profile-install several packages at this newer revision because it rejects their `meta.outputsToInstall` values. Resolve the immutable output paths first, require every path to exist in the trusted cache, and then copy and install those paths. Run the following in one Bash session:

```bash
nixpkgs_ref='github:NixOS/nixpkgs/6b5e5b7a6631f065bf6908986990b37d845f847f'
cache_url='https://cache.nixos.org'
cache_key='cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY='

nix flake metadata "$nixpkgs_ref" --json | \
  jq -e '.locked.rev == "6b5e5b7a6631f065bf6908986990b37d845f847f" and
    .locked.narHash == "sha256-smTKQXMLLStzc8zJevMCckbk3My7SvbbLmPYZUJJKW4="'
nix config show | grep -F "$cache_key"

for attribute in libvirt virt-manager qemu_kvm OVMF swtpm virtio-win; do
  printf '%s: ' "$attribute"
  nix eval --raw "$nixpkgs_ref#$attribute.version"
  printf '\n'
done

declare -A selectors=(
  [libvirt]='libvirt.outPath'
  [virt-manager]='virt-manager.outPath'
  [qemu_kvm]='qemu_kvm.outPath'
  [OVMF]='OVMF.fd'
  [swtpm]='swtpm.outPath'
  [virtio-win]='virtio-win.outPath'
  [virtio-win-iso]='virtio-win.src.outPath'
)
declare -A paths=()

for name in libvirt virt-manager qemu_kvm OVMF swtpm virtio-win virtio-win-iso; do
  paths[$name]=$(nix eval --raw "$nixpkgs_ref#${selectors[$name]}")
  printf '%-16s %s\n' "$name" "${paths[$name]}"
  nix path-info --store "$cache_url" "${paths[$name]}" >/dev/null
done

nix copy --from "$cache_url" "${paths[@]}"

for name in libvirt virt-manager qemu_kvm OVMF swtpm virtio-win virtio-win-iso; do
  path=${paths[$name]}
  nix store verify --sigs-needed 1 "$path"
  remote_hash=$(nix path-info --store "$cache_url" --json "$path" |
    jq -r --arg path "$path" '.[$path].narHash')
  local_hash=$(nix path-info --json "$path" |
    jq -r --arg path "$path" '.[$path].narHash')
  [ "$remote_hash" = "$local_hash" ] || {
    printf 'NAR hash mismatch: %s\n' "$name" >&2
    exit 1
  }
done

expected_iso_hash=$(nix eval --raw "$nixpkgs_ref#virtio-win.src.outputHash")
actual_iso_hash=$(nix hash file --type sha256 "${paths[virtio-win-iso]}")
[ "$expected_iso_hash" = "$actual_iso_hash" ] || {
  printf 'virtio-win ISO content hash mismatch\n' >&2
  exit 1
}

nix profile install \
  "${paths[libvirt]}" \
  "${paths[virt-manager]}" \
  "${paths[OVMF]}" \
  "${paths[swtpm]}" \
  "${paths[virtio-win]}"
nix profile install --priority 4 "${paths[qemu_kvm]}"
```

The `virtio-win` profile package is an extracted driver tree, not an ISO. Its pinned `src` is the Fedora driver ISO at `https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/virtio-win.iso`; the commands above fetch it through the trusted Nix cache and verify both its cache signature and its fixed-output content hash. This is not a Windows installation image.

`virtiofsd` is optional when virtio-fs sharing is needed; it is not required for the base VM.

## Post-install soft checks

Confirm that the profile resolves the intended binaries and that the emulator advertises the required capabilities:

```bash
for command in libvirtd virsh virt-host-validate virt-manager \
  qemu-system-x86_64 swtpm; do
  printf '%-24s %s\n' "$command" "$(readlink -f "$(command -v "$command")")"
done

libvirtd --version
virt-manager --version
qemu-system-x86_64 --version
swtpm --version
qemu-system-x86_64 -accel help
qemu-system-x86_64 -machine help | grep q35
virt-host-validate qemu
```

`virt-host-validate qemu` should pass hardware virtualization, `/dev/kvm`, vhost-net, tun, CPU/memory cgroups, and IOMMU. A warning about the devices controller for an unprivileged user and a warning that SEV/TDX secure-guest support is absent do not block an ordinary Windows 11 VM.

Soft-check the remaining non-NixOS integration without making privileged changes:

```bash
getent passwd qemu || echo 'qemu user: absent'
getent group qemu || echo 'qemu group: absent'
getent group libvirt || echo 'libvirt group: absent'

for unit in virtqemud.service virtqemud.socket \
  virtnetworkd.service virtnetworkd.socket \
  virtstoraged.service virtstoraged.socket; do
  systemctl is-enabled "$unit" 2>&1 || true
done

pgrep -af 'libvirtd|virtqemud' || echo 'no libvirt daemon running'
timeout 15 virsh -c qemu:///system uri || true
```

Before host integration, the expected connection failure names `/run/libvirt/virtqemud-sock`.

## One-time non-NixOS daemon scaffolding

This step is not yet live-validated and must not be treated as ready to run. Installation alone does not create the `qemu` or `libvirt` identities, host configuration, service links, runtime directories, or polkit integration.

The validated package facts narrow the remaining work:

- Libvirt 12 clients prefer the modular `virtqemud` socket. Do not enable only the legacy `libvirtd` sockets.
- QEMU VM management needs `virtqemud`; default NAT and storage management also need `virtnetworkd` and `virtstoraged`.
- The modular units require `virtlogd` and `virtlockd`, but this nixpkgs output does not ship their service/socket unit files. Supply and live-test those helper units before enabling the main sockets.
- This Nix build's compiled system configuration paths are `/var/lib/libvirt/virtqemud.conf` and `/var/lib/libvirt/qemu.conf`, not `/etc/libvirt`.
- The package supplies one polkit rule at `share/polkit-1/rules.d/50-libvirt.rules` and no D-Bus policy or service files. Link only files that actually exist.
- The system daemon does not inherit the user's Nix profile `PATH`; configure the resolved QEMU store path explicitly.

The future privileged integration test must create isolated `qemu` and `libvirt` identities, configure the compiled `/var/lib/libvirt` paths, install complete modular systemd integration, link the polkit rule, start the sockets, and prove `virsh -c qemu:///system uri` plus the default NAT network. Bridged networking remains out of scope.

## Windows 11 VM creation settings

Create the VM with virt-manager and use these settings:

- Q35 machine type and UEFI firmware from the nixpkgs `OVMF` output: `OVMF_CODE.fd` plus a writable copy of `OVMF_VARS.fd`.
- An emulated TPM 2.0 backed by `swtpm`; Windows 11 requires TPM 2.0.
- CPU mode `host-passthrough`, 8 GiB RAM, and 4 vCPUs.
- A qcow2 system disk, the Windows 11 ISO, and a host-local copy of the verified `virtio-win` source ISO.
- The default libvirt NAT network.

A system libvirt daemon does not inherit the user's Nix profile `PATH`. Resolve QEMU, firmware, and the driver ISO from their store paths, then copy the driver ISO to the host-local VM directory:

```bash
qemu_emulator=$(readlink -f "$(command -v qemu-system-x86_64)")
ovmf_store=$(nix eval --raw "$nixpkgs_ref#OVMF.fd")
virtio_iso=$(nix eval --raw "$nixpkgs_ref#virtio-win.src.outPath")
printf 'emulator=%s\nfirmware=%s\ndriver_iso=%s\n' \
  "$qemu_emulator" "$ovmf_store" "$virtio_iso"
install -Dm0644 "$virtio_iso" "<VM_LOCAL_DIR>/iso/virtio-win.iso"
```

Set the resolved emulator explicitly in libvirt configuration or, preferably, in the domain XML. Set firmware with explicit loader and NVRAM entries; copy the variable template into the host-local VM directory before defining the domain:

```xml
<domain type='kvm'>
  <os firmware='efi'>
    <type arch='x86_64' machine='q35'>hvm</type>
    <loader readonly='yes' type='pflash'><OVMF_CODE_FD></loader>
    <nvram template='<OVMF_VARS_FD>'><VM_LOCAL_DIR>/nvram/<VM_NAME>_VARS.fd</nvram>
  </os>
  <cpu mode='host-passthrough' check='none'/>
  <memory unit='GiB'>8</memory>
  <vcpu>4</vcpu>
  <devices>
    <emulator><QEMU_SYSTEM_X86_64></emulator>
    <tpm model='tpm-crb'>
      <backend type='emulator' version='2.0'/>
    </tpm>
  </devices>
</domain>
```

Replace every placeholder before using the XML. Keep the copied NVRAM file and swtpm state beside the other host-local VM state.

## Clean_Win11 snapshot and revert workflow

Complete Windows setup, install the virtio drivers and test prerequisites, apply the desired baseline updates, and shut down cleanly. Then create the baseline snapshot:

```bash
virsh snapshot-create-as \
  --domain <VM_NAME> \
  --name Clean_Win11 \
  --description 'Clean Windows 11 Machtiani test baseline' \
  --atomic
```

Boot the VM, test the Machtiani installer, and collect the result. Before retesting a bug fix, stop the guest and revert to the clean baseline:

```bash
virsh shutdown <VM_NAME>
virsh snapshot-revert <VM_NAME> Clean_Win11 --running
```

Use `virsh destroy <VM_NAME>` only when a hung guest cannot shut down normally; it is equivalent to cutting power.

## Stays out of git

Keep all VM artifacts in a host-local directory such as `~/vm/<VM_NAME>/`, outside the Machtiani checkout. Do not add any of the following to git:

- Disk images.
- Windows, driver, or tool ISOs.
- Snapshots.
- UEFI NVRAM files.
- swtpm state.
- Generated domain XML.
- Unattended-install answer files.
- Credentials or Windows product keys.

## Placeholders

Tokens in angle brackets, such as `<VM_NAME>`, `<VM_LOCAL_DIR>`, `<QEMU_SYSTEM_X86_64>`, `<OVMF_CODE_FD>`, and `<OVMF_VARS_FD>`, are deliberately host-local values. Replace them before running a command or defining XML. Never substitute secrets into a tracked file.
