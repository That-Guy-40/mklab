# Manual testing — the UKI Workbench

Every step is a short `!` command you can run in this session. Each smoke script
prints exactly one `PASS:`/`FAIL:`/`SKIP:` verdict line (exit 0/1/77).

## Prerequisites

- The firmware, built once in the rival lab:
  `! cd ../openbios-the-rival-that-shipped && ./build-openbios.sh unix`
  (produces `~/openbios-lab/openbios/obj-amd64/openbios-unix` + `.dict`).
- Host oracles/tools: `ukify` (systemd-ukify), `binutils` (objdump/objcopy),
  `file`, GNU `cpio`, `genisoimage`, and the systemd EFI stub
  (`/usr/lib/systemd/boot/efi/linuxx64.efi.stub`). Missing any → the tracks
  **SKIP by name**, they do not fail.
- A readable bzImage for the UKI's `.linux` (auto-detected under `micro-linux/` or
  `/boot`; else `BZIMAGE=/path/to/bzImage`).

## 1. The dissector — identify NAMES a real UKI's contents through the contract

```
! OPENBIOS_WORKDIR=~/openbios-lab examples/uki-workbench/smoke-uki-dissect.sh
```

Success signature (one line):

```
PASS: the contract's identify NAMES every typed artifact a real UKI carries
(container=pe, .linux=bootparams, .initrd=cpio) with no per-format code in the
consumer, matching the foreign oracles; garbage is unrecognised, and dropping a
module's sidecar stops its kind being claimed — federation, not fusion
```

The `note` lines above it name the subject (the ukify-built UKI, its sections per
`objdump`/`file`/`cpio`) and confirm both controls fired.

### See the dissection itself

To watch `identify` name each section (not just the PASS), run the consumer word by
hand — stage the modules + a UKI on an ISO and drive `openbios-unix`, then:

```
load-base load-size uki-dissect
```

prints the PE section table, then `UKI| the container itself: IDENTIFY: pe`,
`UKI| .linux -> IDENTIFY: bootparams`, `UKI| .initrd -> IDENTIFY: cpio`, and the list
of modules the dispatcher consulted. (The smoke script does exactly this and asserts
each line.)

## 2. The rescue edits — mutate the boot artifact in place via NAME-write

```
! OPENBIOS_WORKDIR=~/openbios-lab examples/uki-workbench/smoke-uki-rescue.sh
```

Success signature:

```
PASS: the contract's NAME-write surface performs both in-RAM rescue edits on a real
UKI — pe-write grows .cmdline to a rescue line, cpio-write flips a config value inside
the .initrd — each a scoped DELTA agreeing with a foreign pre-edit oracle, and each
refusing an out-of-bounds edit BY NAME while writing nothing
```

## 3. Watch a control bite (the repo's rule: run it, don't reason it)

Neuter the rescue lab's oversize guard and confirm the track flips to FAIL:

```
! cd examples/uki-workbench && sed 's/cb 400 pe-write/cb 4 pe-write/' smoke-uki-rescue.sh > _b.sh && OPENBIOS_WORKDIR=~/openbios-lab bash _b.sh; rm -f _b.sh
```

Expected: `FAIL: CONTROL did NOT bite: an oversize .cmdline edit was not refused edit| TOO-BIG …`
— proving the `edit| TOO-BIG` assertion is attached to a real refusal, not a string
that is always present.

## Cleanup

Both scripts stage into a `mktemp -d` and remove it on exit (the trap prints
`FAIL: … exited early` on any unexpected rc, so a silent early exit is impossible).
Nothing is written under the repo.
