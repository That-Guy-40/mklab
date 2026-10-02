# Manual testing — pacme inspects the firmware

Every step is a short `!` command. Each script prints exactly one `PASS:`/`FAIL:`/`SKIP:` line
(exit 0/1/77).

## Prerequisites

- **GNU poke** (the bridge's engine — needs root, so you run it):
  `! sudo apt-get install -y poke`
  (brings `poke`, `poked`, and `/usr/share/poke/pickles/pe.pk`; `libnbd` is already present for its
  NBD backend.)
- A built OpenBIOS x86 firmware:
  `! cd ../openbios-the-rival-that-shipped && ./build-openbios.sh x86`
- `qemu-system-x86_64`, `qemu-nbd`, `python3` (all standard). Missing any → the tracks **SKIP by
  name**, they do not fail.

Check readiness at any time:

```
! examples/pacme-inspects-the-firmware/deps.sh
```

It prints `ok`/`MISSING` per dependency and `READY` when Spike 0 + Spike 1 can run, and it names
pacme (the Spike-3 UI) with its source-build recipe without building it.

## 1. Spike 0 — choose the bridge, measure the hazard

```
! OPENBIOS_WORKDIR=~/openbios-lab examples/pacme-inspects-the-firmware/bridge.sh
```

It boots OpenBIOS with its IDE NVRAM store, writes a nonce, and reports the FILE/NBD surfaces plus
the writable-export hazard. Success signature (the key lines):

```
  - hazard MEASURED: a writable export of the in-use node is REFUSED — Permission conflict on node
    '#blockN': permissions 'write' are both required … and unshared by block device 'ide1-hd1'.
BRIDGE: B (NBD, QMP block-export-add of the live IDE node)
LABEL:  LIVE: block-only (read-only; writable export REFUSED while the guest holds the node)
PASS: Spike 0 decided: poke bridges to the live firmware over NBD …
```

## 2. Spike 1 — the seam is faithful

```
! OPENBIOS_WORKDIR=~/openbios-lab examples/pacme-inspects-the-firmware/smoke-pacme-seam.sh
```

Success signature:

```
  - seam faithful: poke(NBD)=<hex> == od(store)=<hex> over N bytes at offset …
  - control bit: poke's read != the one-byte-flipped span …
PASS: the seam is faithful: GNU poke, reading the LIVE OpenBIOS IDE NVRAM over the NBD bridge, sees
the firmware's own N nonce bytes byte-for-byte equal to od of the store … (LIVE: block-only)
```

## 3. Watch a control bite (the repo's rule: run it, don't reason it)

Make poke read one byte past the real offset and confirm the seam-faithful assertion flips to FAIL:

```
! cd examples/pacme-inspects-the-firmware && sed 's/"\$OFF" "\$LEN")/"$((OFF+1))" "$LEN")/' smoke-pacme-seam.sh > _b.sh && OPENBIOS_WORKDIR=~/openbios-lab bash _b.sh; rm -f _b.sh
```

Expected: `FAIL: SEAM UNFAITHFUL: poke over NBD read <shifted> but od of the store reads <true> …`
— proving the equality is a real byte comparison, not a tautology.

## Cleanup

Both scripts launch QEMU in the background, capture its PID, and tear it down **by PID** on exit
(a `trap` prints `FAIL: … exited early` on any unexpected rc). Sockets live under a short
`/tmp/pk.XXXXXX` dir (the AF_UNIX path-length limit) and are removed on exit. Nothing is written
under the repo. If you ever need to check for a stray: `pgrep -af 'obj-x86/openbios.multiboot'`
(match the firmware path, never a self-matching pattern — and kill by the PID you see, not by
pattern, or you will also kill any other QEMU whose cmdline shares the string).
