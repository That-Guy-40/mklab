# NVRAM on x86: a disabled switch, not a missing peripheral

> **RESULT: GREEN.** Configuration variables persist across a cold power cycle on
> the x86 emu flavor. `nvramrc` executes at startup. `nvalias` survives. And the
> warm-reboot branch — documented for two increments as "correct by reading,
> unprovable by running" — now runs.

## The question

The lab's working assumption was that Open Firmware's central extension mechanism
was simply unavailable on x86:

```
ok setenv use-nvramrc? true
Out of NVRAM environment space
<buffer@1c3ebb8>:0: Unimplemented package interface procedure
ok printenv use-nvramrc?
use-nvramrc? =        false          ← unchanged
```

[`FULL-BOOT-TRACING.md`](FULL-BOOT-TRACING.md) called that *"a missing peripheral
in this firmware build."* That was wrong, and the tree says so.

The suspicion worth testing was different: that NVRAM got switched off as an
expedient during the port, with other fires burning — and that if so, the three
IEEE 1275 architectures in this repo could be unified in **mechanism**, not just
in idiom, because x86 is the only one where the mechanism appeared dead.

## Finding 1 — the two errors are one cause

`ofw/core/ofwcore.fth:236` declares `defer nv-c@` / `defer nv-c!`. The emu flavor
**assigns neither** — it floads neither `cpu/x86/pc/nullnv.fth` nor
`cpu/x86/pc/biosload/filenv.fth`. Everything else follows mechanically:

| symptom | mechanism |
|---|---|
| `Unimplemented package interface procedure` | `nvram-node` = 0, so `" size" nvram-node $call-method` hits `no-proc` (`ofwcore.fth:2111`) |
| `Out of NVRAM environment space` | `config-size`/`config-mem` stay 0 (`nvcache.fth:18-19`), so `cv-area` is a **zero-length region** and `add-ge-var` returns −1 (`nameval.fth:158`) |

One unbound `defer`, reported by two layers. Not two problems.

Crucially the **rest of the machinery is fully compiled in**: `cpu/x86/basefw.bth:58`
floads `ofw/confvar/loadcv.fth`, which pulls `conftype`, `nvramrcg`, `nvalias`,
`nvcache` and `nameval`. Parser, cache, name=value encoder, persistent devaliases —
all present and reachable. Only the backing store was absent.

## Finding 2 — it was deliberate, and the author wrote down why

Not an expedient. `cpu/x86/pc/emu/config.fth`, in Mitch Bradley's own prose:

```forth
\ use-null-nvram installs stub implementations of non-volatile access routines
\ ... Generic PCs generally have no good place to store those configuration
\ variables, as the CMOS RAM is too small for typical string-valued variables.
create use-null-nvram              ← the shipped default

\ pseudo-nvram installs non-volatile access routines that use a fixed-name file
\ on drive A ... a reasonable way to enable configuration variable storage when
\ running OFW under an emulator ... not particularly useful for real hardware.
\ create pseudo-nvram              ← commented out
```

That is a platform judgment, not a casualty. **x86 has no architectural NVRAM** —
unlike SPARC (a dedicated NVRAM/TOD chip) or PPC
(`/pci@80000000/mac-io@10/nvram@60000`). PC CMOS is ~114 usable bytes; a single
`boot-device` string can exceed that.

And the enablement **already ships**: `cpu/x86/pc/emu/devices.fth:176` carries the
complete `[ifdef] pseudo-nvram` block — `filenv.fth`, a `/file-nvram` node, and a
`stand-init:` that opens it and calls `init-config-vars`.

Two supporting details found while checking: `create use-null-nvram` is
**vestigial** in emu (no `[ifdef] use-null-nvram` exists anywhere in emu's build
chain — `fw.bth`, `emuofw.bth`, `builton.bth`, `basefw.bth`), and OFW's FAT driver
has **full write support** (`ofw/fs/fatfs/write.fth`, `create.fth`,
`write-clusters`, `$dosopen r/w`). The store was achievable.

## The three edits

Built by [`build-nvram-rom.sh`](build-nvram-rom.sh), in an **isolated clone** with
a sha-guard on the sister lab's `emuofw.rom`:

| # | file | change |
|---|---|---|
| 1 | `cpu/x86/pc/emu/config.fth` | `\ create pseudo-nvram` → `create pseudo-nvram` |
| 2 | `cpu/x86/pc/emu/config.fth` | `create use-null-nvram` → commented (vestigial) |
| 3 | `cpu/x86/pc/emu/devices.fth` | `nv-file` → `" a:\nvram.dat"` |

**Edit 3 is the only non-obvious one**, and the first explanation of it here was
**wrong**. This page originally said emu *"declares no `c` devalias"*. It does:
`report-disk` creates it (`devices.fth:261`, `" c" " /pci-ide/ide@0/disk@0"
$devalias`). The real problem is **ordering**, which is a better answer:

- `report-disk` runs inside **`probe-all`**, which `startup` calls *long after*
  `stand-init: Pseudo-NVRAM` has already tried to open the store.
- Worse, **PCI itself is unprobed** at stand-init, so no PCI-IDE path could resolve
  then even if the alias existed.
- `devalias a /isa/fdc/disk@0` (`devices.fth:127`) is different in kind: it is
  declared **statically at build time**, and its ISA node exists immediately.

So retargeting to `a:` is not a correction of upstream's `c:` — it is choosing a
store that is reachable *at the moment stand-init runs*. `config.fth`'s own prose
("a fixed-name file on drive A") reflects exactly that constraint.

Upstream hit this too and solved it: `biosload`'s `stand-init` calls
**`reread-config-vars`** (`biosload/devices.fth:213`), a `config-valid?`-guarded
retry, precisely because it boots off USB/disk. emu calls `init-config-vars` once
and gives up. `build-nvram-rom.sh --disk` adds that retry — but it is **not** the
binding constraint: emu's PCI-IDE probe creates a primary-channel `disk@0` only
intermittently (~2 boots in 18), so the `c:` store is **nondeterministic** and the
floppy remains the dependable one. Full evidence, including two wrong conclusions
reached along the way, in [`DELIVERY-MECHANISMS.md`](DELIVERY-MECHANISMS.md).

## Result — cold power cycle, `-fda` FAT12 floppy

```
Pseudo-NVRAM                       ← stand-init ran; no "EEPROM is not working"
ok printenv use-nvramrc?
use-nvramrc? =        false
ok setenv use-nvramrc? true        ← previously TWO errors
use-nvramrc? =        true

═══ QEMU killed, machine restarted from power-off ═══

ok printenv use-nvramrc?
use-nvramrc? =        true         ← survived

$ mdir -i nvram-floppy.img ::
NVRAM    DAT      1024
```

`nvramrc` executes at startup, in the startup stream, with nothing typed:

```
Probe IDE
nvramrc
NVRAMRC-FIRED                       ← from `" .( NVRAMRC-FIRED ) cr" to nvramrc`
Probing
```

`nvalias` persists across a cold power cycle:

```
ok nvalias labdisk /isa/fdc/disk@0
═══ power cycle ═══
ok devalias
labdisk                  /isa/fdc/disk@0
```

## Finding 3 — the warm-reboot gap was never an NVRAM problem

The interesting result, and it only surfaced because the first fix *didn't* close
the gap. With NVRAM working, `reboot-command` persisted fine — and the machine
still took the normal boot path.

Cause: **the emu flavor defines its own `startup`** (`cpu/x86/pc/emu/fw.bth:288`),
and unlike the generic `ofw/core/startup.fth:16` it **never calls
`copy-reboot-info`**. That is the only writer of `reboot?`. So
`auto-boot`'s warm-reboot branch (`bootparm.fth:330`) was dead code on this flavor
*independently of NVRAM*.

One line — `copy-reboot-info` after `standalone? 0= if exit then` — closes it.
`build-nvram-rom.sh --reboot-hook` adds it.

### The controlled experiment

Both arms share the identical NVRAM enablement; they differ only in that one line.

| ROM | `reboot-command` persists | `Rebooting with command:` | `do-auto-boot` skipped |
|---|---|---|---|
| `nvram-emuofw.rom` | ✔ | ✘ | ✘ — `Boot device:` still printed |
| `nvram-reboot-emuofw.rom` | ✔ | ✔ | ✔ — early `exit` taken |

```
Rebooting with command: .( WARM-REBOOT-TAKEN ) cr
WARM-REBOOT-TAKEN
```

and no countdown, no `Boot device:` — `auto-boot` returned before
`" boot-" do-drop-in` and `do-auto-boot`, exactly as `bootparm.fth:330` reads.

**The control arm is the point.** Without it, "we enabled NVRAM and the reboot path
started working" would have been a plausible, wrong story. The two causes are
independent, and only the pair closes the gap. This also retroactively confirms the
earlier decision to hook **`banner-`** rather than `boot-`: the `reboot?` early exit
is real, reachable, and now demonstrable.

## What this unifies

| capability | x86 stock | x86 + these edits | SPARC | PPC |
|---|---|---|---|---|
| `setenv` persists a cold power cycle | ✘ | ✔ | ✔ | ✔ |
| `nvramrc` executes at startup | ✘ | ✔ | ✔ | ✔ |
| `nvalias` persistent devaliases | ✘ | ✔ | ✔ | ✔ |
| `reboot-command` → warm-reboot branch | ✘ | ✔ *(+`--reboot-hook`)* | ✔ | ✔ |

So the three architectures **do** share one mechanism. What separated them was a
build-time switch and a flavor-local `startup`, not the IEEE 1275 abstractions —
which is the stronger version of the claim the native-habitats plan makes: they
differ in topology and idiom, and now in nothing else that matters for the DSL.

## Why this is the same move UEFI makes

OVMF splits into `OVMF_CODE.fd` + **`OVMF_VARS.fd`** precisely so UEFI variables
get a writable pflash backing store. EFI variables work on x86 for no architectural
reason at all — they work because *someone attached a writable device*.
`pseudo-nvram` on a floppy is structurally identical: OFW's abstraction was always
there; it just had nothing bound underneath it.

The honest difference is that OVMF's vars store is the **shipped default** and
OFW's is opt-in, because OFW targeted real PCs where no such device is guaranteed.
Under an emulator that reasoning doesn't bind — which is exactly what Bradley's
comment says.

## Honest limits

- **Emulator-scoped, by design.** The store is a file on an attached drive. It is
  not suitable for real PC hardware, and upstream is right about that. This is a
  lab capability, not a portability claim.
- **Requires an attached writable drive.** No `-fda` → `stand-init` prints *"The
  configuration EEPROM is not working"* and behaviour falls back to stock.
- **`--reboot-hook` changes boot behaviour** on the reboot path only, and it
  diverges from upstream's emu flavor. It is a separate ROM for that reason.
- **Not the stock ROM.** Everything here builds to `$OFW_WORKDIR/nvram*-emuofw.rom`
  in an isolated clone; the sister lab's `emuofw.rom` is sha-guarded and untouched.
  The 22-of-23 dictionary audit still measures the stock ROM.
