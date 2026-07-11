# MANUAL_TESTING — systemd-261 measured-boot NixOS lab

Verification log, spike by spike. Host: this repo's COLD_STORAGE host (rootless
podman + KVM). Each spike records the exact commands and the **captured** success
signature. See [`PLAN.md`](PLAN.md) for the roadmap and what's still ahead.

---

## Spike B — a Nix-built NixOS UEFI image boots under OVMF (✅ VERIFIED 2026-07-11)

### B.0 — systemd 261 is obtainable, no overlay needed

```
$ nix eval --raw github:NixOS/nixpkgs/nixos-26.05#systemd.version      → 260.2
$ nix eval --raw github:NixOS/nixpkgs/nixos-unstable#systemd.version   → 261
```

**Signature:** stable is 260.2; **`nixos-unstable` ships systemd 261**. The flake
pins `nixos-unstable` — no custom systemd overlay required. `flake.lock` pins the
exact commit (`0bb7ec5`, 2026-07-08).

### B.1 — the image builds (inside nix-build-box, KVM-assisted)

```
$ ./build-nixos-image.sh
--- systemd version baked into this image ---
261
… nixos-disk-image> Number  Start   End     Size    File system  Name   Flags
              1      8389kB  269MB   261MB   fat32   ESP    boot, esp
              2      269MB   4622MB  4353MB  ext4    primary
PASS: image built → out/nixos261.qcow2        # 2.2 GB qcow2
```

The build closure contains `…-systemd-261`, `…-systemd-minimal-261` (grep of the
build log). Kernel params baked in include **`lsm=landlock,yama,bpf`** — BPF-LSM is
on, which Spike D's `RestrictFileSystemAccess=` needs.

### B.2 — it boots under OVMF to systemd 261 (via lab-vm.sh)

```
$ phase2-qemu-vm/lab-vm.sh create --config examples/systemd261-nixos-measured-boot/vm-nixos261-uefi.toml
$ phase2-qemu-vm/lab-vm.sh start  nixos261        # OVMF (OVMF_CODE_4M.fd) + KVM
# drive the serial socket:
BdsDxe: starting Boot0001 "UEFI Misc Device" …
<<< Welcome to NixOS 26.11.20260708.0bb7ec5 (x86_64) - ttyS0 >>>
nixos261 login: root (automatic login)
root@nixos261:~]# grep PRETTY_NAME /etc/os-release; systemctl --version | head -1; uname -sr
PRETTY_NAME="NixOS 26.11 (Zokor)"
systemd 261 (261)
Linux 6.18.38
```

**Signature:** genuine OVMF (`BdsDxe: starting Boot0001`) launches the Nix-built
image to an autologin root shell on `ttyS0`; the running system reports **systemd
261**, kernel 6.18.38.

> **Gotchas found (both fixed / noted):**
> 1. `boot.loader.timeout` — the `qcow-efi` format already pins it to `0`; also
>    setting it → *"conflicting definition values"*. Don't redefine it.
> 2. **Serial-socket capture race.** `lab-vm.sh` wires the serial as a
>    `socket,server=on,wait=off` chardev, which **drops output produced before a
>    client connects**. KVM boot is fast and the autologin shell then sits idle
>    (emits nothing), so a naive reader that *waits to see a prompt* captures zero
>    bytes and looks like a dead VM. The image is fine — you must **drive** the
>    idle shell (send a command; read the reply), or capture from `t=0` with a
>    private `qemu … -serial file:` boot (how B.2's boot log above was obtained).

---

## Spike C — swtpm in lab-vm.sh + measured boot (✅ driver+plumbing VERIFIED 2026-07-11)

### C.1 — the shared-driver change (`phase2-qemu-vm/lab-vm.sh`)

A new opt-in `tpm = true` VM key wires an emulated **TPM 2.0** (swtpm sidecar +
`-tpmdev emulator` + `tpm-crb` on x86_64 / `tpm-tis-device` on aarch64). The
sidecar is started before QEMU and **reaped by recorded PID** (never by pattern —
CLAUDE.md) on `stop`/`destroy`.

```
$ bash phase2-qemu-vm/tests/test-tpm-args.sh
PASS: tpm selector: true → emulated TPM 2.0 (crb) wired; false/unset → none
$ bash phase2-qemu-vm/tests/test-firmware-mode.sh      # regression: my edits didn't break it
PASS: firmware selector: bios → SeaBIOS (no pflash), uefi → OVMF pflash
```

The test is `REGRESSION:`-guarded — an ordinary (`tpm=false`/unset) VM must never
silently acquire a TPM (it would change its measured-boot surface).

### C.2 — the guest gets a working TPM 2.0 (live, via lab-vm.sh)

With `tpm = true` in `vm-nixos261-uefi.toml`, `lab-vm.sh start` launches swtpm and
QEMU; driving the guest shell:

```
VIRT=kvm
TPM: /dev/tpm0 + /dev/tpmrm0, /sys/class/tpm/tpm0, tpm_version_major = 2
PCR7  = 0xB5710BF57D25623E4019027DA116821FA99F5C81E9E38B87671CC574F9281439   (measured, not zero)
systemd-analyze pcrs → 25 PCRs listed
```

On `lab-vm.sh stop`, the swtpm sidecar is **reaped by PID** (verified: pid gone,
`swtpm.sock`/`swtpm.pid` removed).

### C.3 — `ConditionSecurity=measured-os` is correctly NOT-MET (and why)

```
$ systemd-run -p ConditionSecurity=measured-os --wait --quiet /bin/sh -c 'touch /run/mflag'
$ test -e /run/mflag && echo MET || echo NOT-MET      → NOT-MET
# precise reason:
PCR11 = 0x000…000            (the systemd "OS" PCR — never extended)
systemd-pcrphase.service     = inactive / not-found
StubPcrKernelImage EFI var   = absent      → kernel NOT booted via systemd-stub
bootctl … stub:              = (empty)     → plain systemd-boot, no UKI
```

**This is the correct result, not a failure.** The Spike-B image boots a *plain*
systemd-boot kernel+initrd, so nothing measures the OS into PCR 11 and there is no
systemd-measured chain. `measured-os` becomes satisfiable only with a **UKI booted
by `systemd-stub`** (which extends PCR 11) — i.e. the Tier-B UKI/verity image built
in Spike D. So: the swtpm **plumbing** is done and verified here; the measured-os
**gate turns green in Spike D** when the UKI lands. (Honest framing throughout:
swtpm is a software TPM — plumbing, not a trust anchor.)

---

## Spikes D–G — not yet run

See [`PLAN.md`](PLAN.md). Measured boot (swtpm PCRs, `ConditionSecurity=measured-os`),
`RestrictFileSystemAccess=`, the `ConditionFraction=` 3-VM fleet, and TPM2-sealed
LUKS + attestation land here as they are built — each with its captured signature
and the honest swtpm-is-not-a-trust-anchor caveat.
