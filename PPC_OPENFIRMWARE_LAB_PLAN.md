# PowerPC / Apple Open Firmware Lab — Design Plan v1

> **Status**: Draft v1 — proposed 2026-07-26, with **Spike 0 already GREEN**
> ([§3](#3-spike-0--result-green)). Both of the questions this plan was asked to
> settle — **NVRAM** and **device pathing** — are answered, on real evidence.
>
> **Decisions locked:**
> - **The lab is OpenBIOS-on-PPC**, driven on the stock QEMU blob. Apple's own
>   Open Firmware (the ROM in a real PowerMac) is proprietary and unobtainable;
>   the same honesty rule as the SPARC plan.
> - **Spike 0 first.** Done — before this plan was written, as with SPARC.
>
> ⚠️ **OPEN DECISION, and it is the important one:** whether this is a **sixth
> lab** or a **second track inside the SPARC lab**. Spike 0 produced evidence that
> argues for the latter. See [§5](#5-the-open-decision--sixth-lab-or-second-track).

## 1. The distinctness problem (stated first, because it is the risk)

Unlike SPARC — which no lab touches — **PowerPC is already used twice**:

| lab | how it uses ppc |
|---|---|
| [`openbios-the-rival-that-shipped/`](examples/openbios-the-rival-that-shipped/README.md) | **builds** `openbios-ppc` and swaps it in for QEMU's blob; the banner date proves the running firmware is *ours* |
| [`openbios-clib-hello-to-emacs/`](examples/openbios-clib-hello-to-emacs/README.md) | runs **C client programs** on stock `qemu-system-ppc` via the IEEE 1275 client interface |

Those are a *build* story and a *client-interface* story. Neither touches the
device tree, NVRAM, boot policy, or the machine's own idiom. So a ppc lab is only
justified if its thesis is genuinely the third thing — which spike 0 says it is:
**Apple's Open Firmware as a vendor lineage.**

## 2. The thesis: Apple's OF is not Sun's OpenBoot

Same standard, different house style, and the boot sequence says so out loud:

```text
>> CPU type PowerPC,750
Trying hd:,\\:tbxi...              ← Apple's BLESSED system file (HFS+ type code 'tbxi')
Trying hd:,\ppc\bootinfo.txt...    ← the CHRP boot script
Trying hd:,%BOOT...
0 >
```

Nothing in the SPARC or x86 labs looks like this. `:tbxi` is the mechanism that
made a PowerMac bootable by *blessing a folder* rather than writing a boot block;
`bootinfo.txt` is CHRP's XML-ish boot script. This is the firmware a generation
met by holding **Cmd-Opt-O-F** at the chime.

## 3. Spike 0 — RESULT: **GREEN**

Stock blob (`/usr/share/qemu/openbios-ppc`, OpenBIOS 1.1 built Apr 22 2026),
default machine **g3beige** (Heathrow PowerMac, PowerPC,750). No build required.

### NVRAM — **writable**

```text
0 > printenv boot-device
boot-device   "hd:,\\:tbxi hd:,\ppc\bootinfo.txt hd:,%BOOT"     ← a THREE-entry list
0 > setenv boot-device hd:,\\:tbxi  ok
0 > printenv boot-device
boot-device   "hd:,\\:tbxi"                                      ← it STUCK
0 > setenv use-nvramrc? true  ok
```

Same result as SPARC, and for a visible reason — **NVRAM is a real device node
here**: `nvram → /pci@80000000/mac-io@10/nvram@60000`.

### Device pathing — **authentically Apple**

`dev / ls` gives a CHRP tree (`pci@80000000`, `rom@ff800000`, `memory@0`), and
`/aliases` is pure PowerMac hardware:

| alias | path |
|---|---|
| `via-cuda` | `/pci@80000000/mac-io@10/via-cuda` — the CUDA power/ADB controller |
| `adb-keyboard` · `adb-mouse` | `…/via-cuda/adb/keyboard` — **Apple Desktop Bus** |
| `nvram` | `/pci@80000000/mac-io@10/nvram@60000` |
| `ttya` · `scca` | `/pci@80000000/mac-io@10/escc/ch-a` — the Zilog **ESCC** |
| `cd` · `cdrom` · `ide0` | `/pci@80000000/mac-io@10/ata-3@21000/cdrom@0` |
| `mac-io` | `/pci@80000000/mac-io@10` — the Heathrow ASIC |

**PCI exists here** (`pci@80000000`), unlike sparc32's SBus — so `ofscope`'s
`pci-map` has a real target, which sparc32 does not give it.

### The rest

- **Console: pty only**, same as SPARC — `-nographic` + `drive-pty-repl.py`.
- **Prompt `0 >`, base hex** — same as SPARC.
- `' see .` and `' nvramrc .` both resolve.
- Curiosity worth chasing later: the boot prints **`milliseconds isn't unique.`**
  — a redefinition warning from the firmware's own startup.

## 4. The family-level payoff: one standard, three topologies

This is the strongest thing the evidence supports, and it only exists once ppc is
in play. The **same `why-no-boot` question** has three completely different
shapes:

| | `boot-device` default | device idiom |
|---|---|---|
| **x86** (OFW emu) | `disk net` | `/pci/pci-ide@1,1/ide@1/cdrom@0` |
| **SPARC** (sun4m) | `disk:a disk` | SBus; `/iommu/sbus/…` |
| **PPC** (g3beige) | `hd:,\\:tbxi hd:,\ppc\bootinfo.txt hd:,%BOOT` | `/pci@80000000/mac-io@10/…`, ADB, CUDA, ESCC |

All three are **lists**, which is exactly the structure `why-no-boot` was built to
walk — and all three fail differently. That comparison is a better lesson than any
single architecture's tour.

## 5. The open decision — sixth lab, or second track?

Spike 0 makes SPARC and PPC look **mechanically near-identical**:

| | SPARC (sun4m) | PPC (g3beige) |
|---|---|---|
| firmware | OpenBIOS 1.1 stock blob | OpenBIOS 1.1 stock blob |
| console | pty only | pty only |
| prompt / base | `0 >` / hex | `0 >` / hex |
| NVRAM `setenv` | **works** | **works** |
| `boot-device` | a list | a list |
| bus | **SBus** (no PCI) | **PCI** + mac-io |

They differ in *topology and idiom*, not in *mechanism*. Everything the harness
cares about — how you drive the console, what the prompt looks like, whether
NVRAM works — is the same.

### Option A — **one lab, two tracks** *(recommended)*
Rename the planned SPARC lab to cover **both native habitats**: Sun and Apple.
One harness, one set of adapted vocabularies, two `--flavor`-style tracks, and the
**three-way comparison in §4 as the centrepiece**. The `smoke-dsl.sh`
flavor-argument pattern from the x86 lab already fits this exactly — and unlike
x86-vs-SPARC, here the two tracks genuinely *do* share a mechanism.
*Cost:* revisits the "SPARC is its own lab" lock made earlier today — though it
stays true (it is still its own lab, just a wider one).

### Option B — **a sixth lab**
`openbios-ppc-apple-open-firmware/` as a separate sibling.
*For:* the Apple material (blessed `tbxi`, CHRP `bootinfo.txt`, ADB/CUDA/ESCC,
Old World vs New World, `mac99` vs `g3beige`) is rich enough to stand alone, and
keeps each lab's thesis sharp.
*Against:* a near-duplicate harness, and the §4 comparison gets split across two
labs instead of being the point of one.

**Recommendation: A.** The argument that made SPARC its own lab was that *every
axis* differed from x86. Here almost none differ from SPARC — which is precisely
the test that decision should be applied consistently.

## 6. Next work (after the decision)

1. **Spike 1** — port `ofdiag`'s diagnosis ladder to OpenBIOS semantics and
   measure what "adapted, not copied" costs. Shared between both tracks.
2. **`mac99` vs `g3beige`** — New World vs Old World device trees; a second
   dimension inside the ppc track.
3. **`nvramrc` demonstrated** — the thing the x86 lab could never show, now
   possible on *both* native habitats.

## 7. Risks

- **Thesis overlap.** Two labs already use ppc; this must stay a *device-tree,
  NVRAM and boot-policy* story, not another build or client story.
- **`mac99` unprobed.** Only `g3beige` has been driven. New World may differ.
- **`devalias` printed nothing** on both SPARC and PPC — the aliases live in
  `/aliases` and were read with `.properties`. Worth understanding before writing
  a tour around it.
- **Scope.** The x86 lab grew from three verdicts to eight modes. Whichever
  option wins, ship one track before adding the second.
