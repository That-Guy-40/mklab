# 2.88 MB variant — manual testing (differential)

Only the **deltas** from the parent runbook are here. The kernel, BusyBox, and
initramfs are byte-for-byte the same as the 1.44 MB build — those checks are
size-independent, so for them follow [`../MANUAL_TESTING.md`](../MANUAL_TESTING.md)
§2–§3 unchanged. What changes is the floppy: its geometry, its free space, and
the drive QEMU reports. Verified on a Debian host (2026-06-06).

```bash
cd examples/tiny-linux-experiments/floppinux/floppinux-2.88mb
O=~/.cache/lab-create/floppinux
```

## §1 — Build at 2.88 MB

```bash
./build-2.88.sh build      # full build; or, if the parent already built:
./build-2.88.sh pack       # just re-write floppinux.img at 2.88 MB (no toolchain, seconds)
```

**Pass** — the floppy line names the ED size:

```text
[floppinux] building floppinux.img — 2.88 MB (extended density), rootless via mtools
```

(`./build-2.88.sh` is just `FLOPPY_KB=2880 ../build-floppinux.sh`.)

## §2 — Verify the floppy geometry (the delta)

```bash
file "$O"/floppinux.img
mdir -i "$O"/floppinux.img :: | tail -2
```

**Pass:**

```text
…/floppinux.img: DOS/MBR boot sector, OEM-ID "SYSLINUX" … sectors/cluster 2 … sectors 5760 … sectors/track 36 … FAT (12 bit) … label "FLOPPINUX"
        4 files           1 013 196 bytes
                          1 735 680 bytes free
```

The deltas vs 1.44 MB: **5760 sectors** (not 2880), **36 sectors/track** (not 18),
**2 sectors/cluster** (keeps FAT12 ≤ 4084 clusters), and **1,735,680 bytes free**
(vs 264,192). `mkfs.fat -F 12` produced all of that with no special flags.

## §3 — Boot it

```bash
./build-2.88.sh test       # headless serial; or ./build-2.88.sh boot for graphical
```

**Pass** — the kernel reports the ED drive, then reaches the shell exactly as the
1.44 MB build does:

```text
Booting from Floppy...
Floppy drive(s): fd0 is 2.88M AMI BIOS
Run /etc/init.d/rc as init process
        … FLOPPINUX 0.3.1 splash …
BusyBox v1.36.1 (…) built-in shell (ash)
# cat /home/hello.txt
Hello, FLOPPINUX user!
```

`fd0 is 2.88M AMI BIOS` is the one line that proves the size change reached the
emulated hardware. Everything past it (mounts, `/dev/fd0` msdos, `/home`,
`halt`) is identical to the parent runbook [`../MANUAL_TESTING.md`](../MANUAL_TESTING.md) §6.

## §4 — Shared checks (no delta)

These are size-independent — run them from the parent runbook as-is:

| Check | Where |
|---|---|
| Kernel `.config` + `bzImage` | [`../MANUAL_TESTING.md`](../MANUAL_TESTING.md) §2 |
| BusyBox static-pie + applet set + `/dev/console` 5,1 | [`../MANUAL_TESTING.md`](../MANUAL_TESTING.md) §3 |
| In-VM mount / `/home` / `halt` | [`../MANUAL_TESTING.md`](../MANUAL_TESTING.md) §6 |

## §5 — Switch back to 1.44 MB

There is one shared `floppinux.img`; rebuild it at the default size to return:

```bash
../build-floppinux.sh pack          # back to 1.44 MB (2880 sectors)
file "$O"/floppinux.img | grep -o 'sectors 2880'
```

## §6 — Troubleshooting (delta only)

| Symptom | Cause | Fix |
|---|---|---|
| Booted image is 1.44 MB, not 2.88 | A later `../build-floppinux.sh build/pack` (no `FLOPPY_KB`) overwrote the shared `floppinux.img`. | Re-run `./build-2.88.sh pack`. |
| `fd0 is 1.44M` at boot | You booted a stale/1.44 image. | Rebuild here, confirm §2 shows `sectors 5760`. |
| Want it on real hardware | 2.88 MB ED drives/media are rare. | For physical floppies prefer 1.44 MB; 2.88 MB shines in QEMU. |
