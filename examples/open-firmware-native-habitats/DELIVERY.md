# DELIVERY.md — how a vocabulary gets into the firmware, and why it is different on each track

A Forth vocabulary is useless until the firmware is *holding* it. On x86 the
sibling lab has `fload` — one word, reads a file off a disc, done — and it built
[four delivery mechanisms](../open-firmware-debugs-itself/DELIVERY-MECHANISMS.md)
on top of that.

**OpenBIOS has no `fload`.** It has no `dl` either — `7.5.2 Serial download` is
`: dl ( -- ) ;`, an empty stub (`forth/debugging/firmware.fs:23`). So the first
question this lab had to answer was the most basic one, and the answer turned
out to be the lab's spine.

## The four doors

| | mechanism | SPARC (sun4m) | PPC (g3beige) |
|---|---|---|---|
| **D1** | `-prom-env nvramrc=…` — QEMU writes the NVRAM chip at machine init | ✅ | ✅ |
| **D2** | `setenv nvramrc …` at the prompt, flush, reset | ❌ | ✅ |
| **D3** | `load <dev>:<path>` + `load-base load-size evaluate` | ✅ | ❌ |
| **D4** | type it at the `0 >` prompt | ❌ | ❌ |

**D1 is the only door open on both tracks**, which is why `smoke-habitat.sh`
uses it for every mode that needs the vocabulary resident. Each ❌ below has a
specific cause in the source, not a shrug.

---

## D1 — NVRAM, written from outside (both tracks)

```bash
qemu-system-ppc -nographic -m 128 \
  -prom-env "use-nvramrc?=true" \
  -prom-env "nvramrc=$(cat ~/ofhabitat-lab/ofdiag.min.fth)"
```

QEMU populates the machine's NVRAM before the firmware runs, so the script is
already on the chip at power-on. `forth/system/main.fs` then evaluates it in a
very specific window:

```forth
: initialize-of ( startmem endmem -- )
  initialize-forth
  PREPOST-list … POST-list … SYSTEM-list …
  use-nvramrc? if  nvramrc evaluate  then    \ ← here
  suppress-banner? 0= if
    probe-all  install-console  banner       \ ← everything visible happens after
  then
  …
```

Which is why the proof in `smoke-habitat.sh nvramrc` is not "the banner
printed" but "the banner printed **before** `Welcome to OpenBIOS`":

```text
>> CPU type PowerPC,750
ofdiag loaded: dev-head diag-open why-no-boot     ← pre-probe
Welcome to OpenBIOS v1.1 built on Apr 22 2026 09:24
```

This is the same pre-probe window the x86 lab reached with a `banner-` dropin
compiled into a rebuilt ROM. Here it is a command-line argument.

### Two silent-failure traps, both of which cost real time

**① A device node is active, so `:` does not define a word.** When `nvramrc`
runs, `active-package` is non-zero (measured: `-a9ef8` on g3beige). Under IEEE
1275 that means a colon definition compiles a **package method**, not a global
word. The script runs, prints its banner, reports nothing wrong — and every word
it defined is gone by the time you reach the prompt:

```text
0 > nvhi
nvhi: undefined word.            ← defined before device-end
0 > nvhi2
NVHI2-RAN  ok                    ← defined after device-end
```

So every staged one-liner is prefixed with **`device-end`** (`stage-dsl.sh`
does it, and `smoke-habitat.sh nvramrc` fails loudly if it is ever dropped).
This belongs to the delivery, not the vocabulary — which is why it is *not* in
`dsl/ofdiag.fth`, whose media path has `active-package` = 0 already.

**② `\` eats the rest of the vocabulary.** `setenv` parses its value to the end
of the line (`linefeed parse`, `forth/admin/nvram.fs`), so an nvramrc script is
*necessarily* one line — and on one line, the first `\` comment swallows
everything after it. Silently. `minify-fth.py` strips both comment forms and
preserves string interiors (it did not, at first; the check that caught it is in
MANUAL_TESTING).

### The size budget

`packages/nvram.c:31` — `#define DEF_SYSTEM_SIZE 0xc10`, minus a `0x10`
partition header:

> **3072 bytes, shared by every config variable**, stored CHRP-style as
> `name=value\0`. Not reserved for `nvramrc` — `boot-device`, `ttya-mode` and
> ~30 others come out of the same pot.

`ofdiag.min.fth` is **784 bytes** including its `device-end` prefix, so it fits
with room to spare. `stage-dsl.sh` fails rather than staging an oversized script:
a truncated `nvramrc` would install a *half* vocabulary and still say `ok`.

---

## D2 — NVRAM, written from inside (PPC only)

```text
0 > setenv nvramrc device-end : q ." PERSISTED-ACROSS-RESET" cr ; q  ok
0 > setenv use-nvramrc? true  ok
0 > " update-nvram" " nvram" open-dev $call-method  ok
0 > reset-all
…
PERSISTED-ACROSS-RESET                    ← survived
```

Note the third line. **`setenv` alone does not write the chip** — it sets a
property on the in-memory `/options` node. The flush is a *method on the
`/nvram` package*, not a root word:

```c
NODE_METHODS( nvram ) = {
        …
        { "update-nvram",       (void*)update_nvram     },
};
```
— `packages/nvram.c:303`. `' update-nvram .` at the prompt reports
`undefined word` on **both** tracks, which is exactly the sort of negative that
looks like "the feature is missing" and is really "you are calling it wrong".

### Why SPARC cannot do this

`nvram_init()` — the function that runs `BIND_NODE_METHODS(get_cur_dev(),
nvram)` — is called from `drivers/macio.c` and the other Apple ports. **Nothing
on sun4m calls it.** `drivers/obio.c:168` has its own `ob_nvram_init()` that
builds a bare node:

```c
ob_new_obio_device("eeprom", NULL);
nvram = (unsigned char *)ob_reg(base, offset, NVRAM_SIZE, 1);
… "address" property … model "mk48t08" …
fword("finish-device");
```

reg, address, model — and no methods. Probed live:

```text
0 > " update-nvram" " /obio/eeprom" find-package drop ?m
NO-METHOD
0 > " read" " /obio/eeprom" find-package drop ?m
NO-METHOD
0 > " nvram" find-package . .
0                                  ← no such alias or node either
```

So on sun4m a `setenv` can only ever live in RAM. `smoke-habitat.sh persist
sparc32` asserts the behaviour end-to-end (set it, reset, watch it be gone) and
says plainly in its failure message that if this ever *starts* passing, upstream
has bound the package and this document is what needs updating.

> **This is a genuine, upstream-reportable gap** in the same family as the
> [rival lab's x86 revival patch](../openbios-the-rival-that-shipped/README.md):
> the hardware is emulated, the driver is written, the Forth side is written —
> only the binding is absent.

---

## D3 — media (SPARC only)

```text
0 > load cdrom:\OFDIAG.FTH  ok
0 > load-size . cr 134c                    ← hex: 4940 bytes
0 > load-base load-size evaluate
ofdiag loaded: dev-head diag-open why-no-boot
```

Three things worth knowing:

**The Sun path idiom takes no comma.** `cdrom:\FILE` works; `cdrom:,\FILE` and
`cdrom:f,\FILE` both report `File not found`. Apple's idiom is the opposite —
`cd:,\file` — which is visible in its own default `boot-device`. One character,
and the failure is a silent empty buffer if the *device* rather than the path is
what fails to resolve.

**`load` fails silently.** `$load` (`forth/debugging/client.fs:135`) opens the
device and, if `open-dev` returns 0, simply `exit`s — printing `ok`. The only
way to know is `load-size`, which is why the smoke asserts on that and not on
the `ok`. This is how the PPC attempt looked *successful* for a while:

```text
0 > load cd:,\HELLO.FTH  ok          ← nothing happened
0 > load-base load-size . .  0 4000000
```

**8.3, uppercase.** No Rock Ridge, same as the sibling lab's ISO9660 reader.
`stage-dsl.sh` refuses a name that will not survive.

### Why PPC cannot do this

`config/examples/ppc_config.xml` sets **every** `CONFIG_FSYS_*` to `false` —
ext2, FAT, ISO9660, UFS, FFS, all of them. What is left is `CONFIG_HFS` and
`CONFIG_HFSP`: the firmware reads Apple's filesystems and nothing else. That is
not an oversight; it is exactly what a PowerMac needs, and it is why the default
`boot-device` hunts for an HFS+ file blessed with type `tbxi`. Attempting a
directory listing on an ISO9660 disc does not fail politely:

```text
0 > dir cd:\
>> out of malloc memory (7c9bf94)!
 Stack Underflow.
```

Compare sparc32, which compiles ext2 + UFS + FFS + ISO9660. **The two habitats
disagree about what a filesystem is**, and the vocabulary has to respect that.

---

## D4 — typing it in (neither track)

There is no paste-it-in door. Typed input stops being echoed after exactly **80
characters** on a line, on both tracks, and the console stops accepting input
there:

```text
0 > \ abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefgh
ECHO-GATE: step 1 byte 80 (b'i') never echoed after 3 attempts
```

Things it is **not**:

- **not the input buffer.** That is 256 bytes — `forth/bootstrap/builtin.fs:19`,
  `100 #ib !` (hex).
- **not `screen-#columns`.** Booting with `-prom-env "screen-#columns=200"`
  changes nothing: still 78 characters plus the two-character prefix. Tested,
  because it was the obvious explanation and it was wrong.

The house `--echo-gate` doctrine is what makes this a *finding* rather than a
mystery: the driver self-clocks on the console's echo, so a byte that never
comes back is resent and then **reported (exit 125)** instead of vanishing into
a silently mangled definition. A fixed `--char-delay` would have produced a
half-typed vocabulary and a confusing error much later.

`smoke-habitat.sh console` guards this on both tracks — because if the limit
ever lifts, D3 and the whole `stage-dsl.sh` apparatus stop being *necessary*,
and this document would be wrong about why they exist.
