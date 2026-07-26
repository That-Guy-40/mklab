# MANUAL_TESTING.md — exact commands, real transcripts, success signatures

Host these were captured on: Ubuntu 24.04, QEMU 8.2.2, stock OpenBIOS blobs
(`/usr/share/qemu/openbios-sparc32`, `openbios-ppc`, both *v1.1 built on Apr 22
2026*). **No firmware build is required for anything on this page.**

Prerequisites:

```bash
sudo apt install qemu-system-sparc qemu-system-ppc genisoimage    # author-run
```

State lives in `$HABITAT_WORKDIR` (default `~/ofhabitat-lab/`), outside the repo.

---

## 0. Stage

```bash
./stage-dsl.sh
```

```text
  - ofdiag.fth -> ofdiag.min.fth (784 bytes of 3072) + /home/sqs/ofhabitat-lab/dsl-stage/OFDIAG.FTH
staged OFDIAG.FTH -> /home/sqs/ofhabitat-lab/dsl.iso
```

**Signature:** two artifacts, and a byte count *under* 3072. If the count ever
exceeds the budget the script fails rather than staging a truncated `nvramrc`
(which would install half a vocabulary and still report `ok`).

## 1. The whole suite

```bash
./smoke-habitat.sh all sparc32
./smoke-habitat.sh all ppc
```

```text
=== nvramrc (sparc32) ===
PASS: nvramrc (sparc32): the diagnostic vocabulary is resident in NVRAM and self-installs at power-on
=== ladder (sparc32) ===
PASS: ladder (sparc32): the ported diagnosis ladder reports four distinct fault classes
=== media (sparc32) ===
PASS: media (sparc32): the vocabulary loads off a disc the firmware mounts itself
=== persist (sparc32) ===
PASS: persist (sparc32): setenv is session-only here — no update-nvram method exists to flush it (the honest negative)
=== console (sparc32) ===
PASS: console (sparc32): typed input dies at 80 columns, which is why the vocabulary arrives by NVRAM or disc instead

PASS: every claim verified (sparc32)
```

On **ppc** the same five run, with `media` reporting

```text
SKIP: media (ppc): the firmware compiles NO filesystem — ppc_config.xml disables
every CONFIG_FSYS_*, leaving HFS/HFS+ only, so there is nothing to stage a .fth
file on (see DELIVERY.md)
```

That SKIP is the expected result, not an environment gap. 4 PASS + 1 SKIP on
ppc, 5 PASS on sparc32.

## 2. The headline, by hand — a vocabulary living in NVRAM

```bash
qemu-system-ppc -nographic -m 128 \
  -prom-env "use-nvramrc?=true" \
  -prom-env "nvramrc=$(cat ~/ofhabitat-lab/ofdiag.min.fth)"
```

```text
>> =============================================================
>> OpenBIOS 1.1 [Apr 22 2026 09:24]
>> CPU type PowerPC,750
milliseconds isn't unique.
ofdiag loaded: dev-head diag-open why-no-boot          ← ★ pre-probe, from NVRAM
Welcome to OpenBIOS v1.1 built on Apr 22 2026 09:24
Trying hd:,\\:tbxi...
Trying hd:,\ppc\bootinfo.txt...
Trying hd:,%BOOT...
No valid state has been set by load or init-program

0 > why-no-boot
OFDIAG: boot-device = hd:,\\:tbxi hd:,\ppc\bootinfo.txt hd:,%BOOT
OFDIAG target: hd:,\\:tbxi
OFDIAG-1: not a path, and no such devalias
OFDIAG target: hd:,\ppc\bootinfo.txt
OFDIAG-1: not a path, and no such devalias
OFDIAG target: hd:,%BOOT
OFDIAG-1: not a path, and no such devalias
 ok
0 >
```

**Signature:** the `ofdiag loaded` line sits **above** `Welcome to OpenBIOS`.
Below it and the delivery still worked, but not in the pre-probe window — which
is the claim. `Ctrl-A X` to quit.

The diagnosis is correct, incidentally: a diskless g3beige has no `hd` alias, so
all three Apple boot entries genuinely cannot resolve.

## 3. The four fault classes, one machine (sparc32)

```bash
./run-habitat.sh sparc32
```

```text
0 > " nosuchalias" diag-open
OFDIAG target: nosuchalias
OFDIAG-1: not a path, and no such devalias
0 > " /obio/nosuch@9" diag-open
OFDIAG target: /obio/nosuch@9
OFDIAG path:   /obio/nosuch@9
OFDIAG-2: no such node in the device tree
0 > " cdrom" diag-open
OFDIAG target: cdrom
OFDIAG path:   /iommu/sbus/espdma/esp/sd@2,0        ← the devalias expanded
OFDIAG-0: opens OK - failure is later (load/execute)
0 > " /obio/eeprom" diag-open
OFDIAG target: /obio/eeprom
OFDIAG path:   /obio/eeprom
OFDIAG-3: node exists but its open method FAILED
```

The PPC equivalents are `nosuchalias`, `/pci@80000000/nosuch@9`, `/memory@0`,
and `cd` (which reports **OFDIAG-3 with no disc in the drive and OFDIAG-0 with
one** — the ladder is reading real machine state, not a script).

## 4. The media door (sparc32 only)

```text
0 > load cdrom:\OFDIAG.FTH  ok
0 > load-size . cr 134c                       ← hex. 4940 bytes.
0 > load-base load-size evaluate
ofdiag loaded: dev-head diag-open why-no-boot
```

**Signature:** a non-zero `load-size`. Do **not** trust the `ok` — `$load` exits
silently when `open-dev` fails, so a wrong path gives you `ok` and an empty
buffer. Try it yourself; the comma is the trap:

```text
0 > load cdrom:,\HELLO.FTH
File not found
0 > load cdrom:f,\HELLO.FTH
File not found
0 > load cdrom:\HELLO.FTH  ok           ← Sun idiom: no comma
```

## 5. Does a `setenv` survive a reset? (the tracks disagree)

**PPC — yes:**

```text
0 > setenv nvramrc device-end : q ." PERSISTED-ACROSS-RESET" cr ; q  ok
0 > setenv use-nvramrc? true  ok
0 > " update-nvram" " nvram" open-dev $call-method  ok
0 > reset-all
>> CPU type PowerPC,750
PERSISTED-ACROSS-RESET                                ← ★
Welcome to OpenBIOS v1.1 …
```

**SPARC — no.** Same commands minus the flush (there is nothing to call), and
after `reset-all`:

```text
0 > printenv use-nvramrc?
…
use-nvramrc?              "false"                     ← back to the default
```

To see *why*, ask the node directly:

```text
0 > : ?m find-method 0= if ." NO-METHOD" else ." HAS-METHOD " . then cr ;  ok
0 > " update-nvram" " /obio/eeprom" find-package drop ?m
NO-METHOD
0 > " nvram" find-package . .
0                                          ← no such alias or node
```

## 6. The 80-column wall

```bash
LONG=$(python3 -c "print('\\\\ ' + 'abcdefghij'*25)")   # inert: it is a COMMENT
python3 ../../tools/drive-pty-repl.py /tmp/ll.log --timeout 60 --echo-gate \
  --expect "0 >" --send "$LONG\r" --expect "0 >" \
  -- qemu-system-ppc -nographic -m 128
```

```text
ECHO-GATE: step 1 byte 80 (b'i') never echoed after 3 attempts — the console is dropping input
```
```text
0 > \ abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefgh
```

**Signature:** exit **125**, and exactly 78 payload characters echoed (80 with
the `\ ` prefix). Adding `-prom-env "screen-#columns=200"` changes nothing —
worth running yourself, because it is the obvious explanation and it is wrong.

## 7. The stubs, from the firmware's own mouth

```text
0 > see patch
: patch
  ;
 ok
0 > see .calls
: .calls
  ;
 ok
```

**Signature:** an empty body. `' patch .` resolves happily — which is exactly
why the tick-probe idiom over-reported "11 of 11 words present" in spike 0.

---

## Troubleshooting

| symptom | cause |
|---|---|
| the driver hangs waiting for `0 >` and the log shows `1 >` | the prompt **is** the stack depth — a word left something behind. This is a free stack-balance assertion; find the leak rather than loosening the anchor |
| `-serial unix:…` produces an empty log | OpenBIOS on these machines gives **zero bytes** on a socket. Use `tools/drive-pty-repl.py`; there is no socket path |
| `nvramrc` prints its banner but its words are `undefined` at the prompt | the one-liner is missing its leading `device-end`; `:` compiled package methods (see [DELIVERY.md](DELIVERY.md)) |
| `nvramrc` set with `setenv` vanishes after `reset-all` on sparc32 | expected — no `update-nvram` method is bound on sun4m |
| `load` reports `ok` and nothing happens | `$load` exits silently on a failed `open-dev`. Check `load-size`; check the comma |
| `dir cd:\` on ppc → `out of malloc memory` | no filesystem is compiled into the PPC build at all |
| `devalias` prints nothing | it is not a stub, but it lists nothing useful here — use `dev /aliases .properties` |
| numbers look wrong | the base is **hex**. `5 6 * .` → `1e` |
| stray `qemu-system-*` processes after an interrupted run | kill them **by PID** (`pgrep -f` to *list*, then `kill <pid>`). `pkill -f` on a shared substring is a house-documented footgun |
