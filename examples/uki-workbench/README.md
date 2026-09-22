# The UKI Workbench — a UKI dissected, and rescued, through the conformance contract

A **Unified Kernel Image** is one PE/COFF `.efi` file with a kernel (`.linux`), an
initramfs (`.initrd`), a command line (`.cmdline`) and more glued on as named PE
sections — a firmware-flashable, signable Linux in a single self-describing binary.
This lab makes the UKI the **subject** and reads every claim it makes about itself
**through the toolkit's conformance contract** ([`contract v1`](../openbios-the-rival-that-shipped/dsl/CONTRACT.md)):
it hands each artifact the UKI contains to the registry-driven capstone
[`identify`](../openbios-the-rival-that-shipped/dsl/identify.fth), which names the
format with **no per-format code** — and then mutates the boot artifact in place
through the contract's **`NAME-write`** surface, the rescue edits an operator makes
without a USB stick or a chroot.

**The full design and rationale live in the plan:**
[`UKI_WORKBENCH_LAB_PLAN.md`](../../UKI_WORKBENCH_LAB_PLAN.md) (Spikes 0–11). This lab
operationalizes its capstone. It is a sibling of, and consumes, the OpenBIOS toolkit
in [`../openbios-the-rival-that-shipped/`](../openbios-the-rival-that-shipped/) — the
`dsl/` readers (`pe`, `cpio`, `bootparams`), their `-conform` sidecars, the `identify`
capstone, and the `pe-edit`/`cpio-edit` editors — and the UKI fixture builder
[`fixtures/uki/build-uki-fixture.sh`](../openbios-the-rival-that-shipped/fixtures/uki/build-uki-fixture.sh).
It does **not** copy the toolkit.

**Contract pin (roadmap §2):** this workbench **consumes `{pe, bootparams, cpio}` at
[`contract v1`](../openbios-the-rival-that-shipped/dsl/CONTRACT.md)**, driven through
`identify` and `NAME-write`. The **readers** conform (`dsl/{pe,bootparams,cpio}-conform.fth`):
each has `NAME-open`/`-fields`/`-validate`/`-manifest`, so the dissector
([`uki-dissect.fth`](uki-dissect.fth)) speaks only the uniform vocabulary. The **writer**
half conforms through the contract's `NAME-write` extension (`dsl/{pe,cpio}-write-conform.fth`),
graded on a delta with a refuse-before-write control. This is the capstone the contract
was built for: *"a capstone can consume any module the same way."*

## Status — PR1: the dissector + the in-RAM rescue edits, both self-proving

Two one-verdict tracks, driven headless on `openbios-unix` against a real UKI the
host's own `ukify` builds at run time (never cached), graded against foreign oracles
(`objdump`/`objcopy`/`file`/`cpio`):

- **`smoke-uki-dissect.sh` — DONE.** `identify` names the container **pe**, `.linux`
  **bootparams** (a kernel — see the polymorphism note below), and `.initrd` **cpio**,
  each matching what the foreign oracles say the blob *is*, with no per-format code in
  the consumer. Controls that bite: a garbage buffer → `IDENTIFY: unrecognised`; drop
  the `cpio-conform` sidecar and `.initrd` is no longer claimed while `need-module cpio`
  names it absent — **federation, not fusion**, made checkable.
- **`smoke-uki-rescue.sh` — DONE.** The contract's `NAME-write` performs both in-RAM
  rescue edits: `pe-write` **grows** `.cmdline` to a rescue line (`rd.break`), and
  `cpio-write` flips a boot-blocking config value **inside** the `.initrd` in place —
  each a scoped delta (the target changed, a neighbour did not) that agrees with a
  **foreign pre-edit oracle**, and each refusing an out-of-bounds edit by name
  (`edit| TOO-BIG`, `cpio| LEN-CHANGE`) while writing nothing.

**The `.linux` polymorphism, stated honestly.** A modern EFI-stub kernel is *both* a
valid PE (it has `MZ`/`PE\0\0`) and a valid x86 boot image (`0xAA55`/`HdrS`), so two
modules legitimately claim `.linux`. `identify` returns the **first registered
claimant**; the profile registers `bootparams` before `pe`, so the meaningful kernel
identity wins. That first-match-by-registration-order is a documented dispatch policy,
not an accident — and it is why the dissector loads the readers in that order.

## What this lab does NOT do (scope guards)

- **The attestation strand is deferred** (plan Spikes 3/4/5, 8-full): reading
  `.pcrsig`/`.pcrpkey`, checking the UKI's self-predicted TPM measurement against an
  OVMF+swtpm boot, and the Authenticode signature. Those need a PCR-keyed UKI rebuild
  and a live OVMF+swtpm — a different theme and heavier infrastructure. **Deferred, not
  claimed:** UNKNOWN is a verdict distinct from PASS.
- **The persisted rescue is the next increment.** The in-RAM edits here are one-shot
  (the OpenFirmware/OpenBoot form). A firmware RAM edit is not visible to a host tool,
  so it is graded by the firmware's own re-read plus the pre-edit foreign anchor. The
  **persisted** deliverable — [`uki-edit.sh`](../openbios-the-rival-that-shipped/uki-edit.sh)
  re-emitting a patched UKI that `objcopy`/`ukify` read back, and the full
  break→fail→rescue showcase — is PR2 (see [`PLAN.md`](PLAN.md)).
- **The readers' four-arch/big-endian correctness** is graded upstream by the rival
  lab's `uki`/`pe`/`bootparams`/`cpio` tracks (the `ppc` big-endian rows). This lab
  proves the **dispatch** on the `unix` door, which is arch-independent Forth over
  those same readers.

## The tracks this lab defines

| track | what it proves | the control that must bite |
|---|---|---|
| `smoke-uki-dissect.sh` | `identify` names container=pe, .linux=bootparams, .initrd=cpio through the contract, matching objdump/file/cpio, with no per-format code | garbage → unrecognised; drop `cpio-conform` → .initrd unclaimed + `need-module cpio` names it absent |
| `smoke-uki-rescue.sh` | `pe-write` grows .cmdline, `cpio-write` flips a config inside .initrd — each a scoped delta agreeing with a foreign pre-edit oracle | an oversize .cmdline → `edit| TOO-BIG`; a length-changing config edit → `cpio| LEN-CHANGE`; bytes unchanged after each refusal |

## Layout

```
uki-workbench/
├── README.md                 this file
├── PLAN.md                   PR1 coverage vs. the deferred strands (links the canonical plan)
├── MANUAL_TESTING.md         the ! commands + success signatures
├── uki-dissect.fth           the capstone consumer: dissect a UKI in contract words only
├── smoke-uki-dissect.sh      identify NAMES every typed artifact a real UKI carries
└── smoke-uki-rescue.sh       the in-RAM rescue edits via the contract's NAME-write surface
```

## Running it

```sh
# build the firmware once (in the rival lab), then:
OPENBIOS_WORKDIR=~/openbios-lab ./smoke-uki-dissect.sh
OPENBIOS_WORKDIR=~/openbios-lab ./smoke-uki-rescue.sh
```

Each prints exactly one `PASS:`/`FAIL:`/`SKIP:` line. They **SKIP by name** without
`ukify`, `binutils`, `file`, GNU `cpio`, `genisoimage`, the built `openbios-unix`, or a
readable bzImage (set `BZIMAGE=/path/to/bzImage`). See
[`MANUAL_TESTING.md`](MANUAL_TESTING.md).
