# `fixtures/config-edit/` — a same-length config patch for the `config-edit` track (Spike 10)

[`build-config-patch.sh`](build-config-patch.sh) authors, **at run time** (derived,
never cached — the repo's rule), the same-length edit the `config-edit` track
applies to a config file **inside** a UKI's `.initrd`. It reads the target config
(`etc/conf`) *out of the UKI's own initrd* with `objcopy` + `cpio`, and produces a
**same-length** replacement by flipping its value byte — a "fix a boot-blocking
config value in place" edit that needs no cpio rebuild. Same length is the whole
point: growing a member would shift every later member and the trailer.

It emits two files:

- **`CONFIG.FTH`** — Forth that compiles the replacement into the **dictionary**
  (ordinary Forth memory on every arch — the cross-arch way to carry bytes without
  a second load buffer), plus the member name and a bogus name for the control:
  `config-name` / `config-new` / `config-bogus`. These are compiled words so no two
  transient `s"` are live at the prompt at once.
- **`new.bin`** — the replacement bytes, for the host oracle to compare against.

The builder **verifies what it emitted**: the replacement is the same length as
the original and actually differs from it, and the Forth encodes exactly that many
bytes (`od` without `-v` would collapse repeats and drop some).

**The `config-edit` track ([`smoke-openbios.sh config-edit`](../../smoke-openbios.sh))
edits `etc/conf` inside the UKI's `.initrd`, in place, on unix, x86, amd64 and ppc**
— a **three-deep** edit: [`pe.fth`](../../dsl/pe.fth) finds `.initrd`,
[`cpio.fth`](../../dsl/cpio.fth)'s `cpio-find` locates the file, and
[`cpio-edit.fth`](../../dsl/cpio-edit.fth)'s `cpio-patch` overwrites it. On unix
`cpio -i` pulls the edited config back out of the written-back image (foreign
oracle). **Controls:** a different-length replacement → `cpio| LEN-CHANGE`; an
absent member → `cpio| NO-MEMBER`; each refused by name, the config **unchanged**
after.

Rebuild by hand:

```sh
# needs a UKI whose .initrd carries etc/conf (fixtures/pe/ builds one)
./build-config-patch.sh /tmp/uki.efi /tmp/CONFIG.FTH /tmp/new.bin
head -5 /tmp/CONFIG.FTH          # the dictionary-data Forth
od -c /tmp/new.bin               # the same-length replacement
```
