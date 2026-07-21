# POC-3 — homecoming: the payload that worked first try

**Goal:** `openbios-builtin.elf` as a modern coreboot payload. **Result:
PASSED on the first boot.** The shortest POC in either firmware lab — and the
contrast is the lesson.

## The thinking

Two reasons to expect this to *just work*, both borne out:

1. **This is the code's birthplace.** OpenBIOS's README still says "On x86
   you can start openbios for example from GRUB or LinuxBIOS" — LinuxBIOS
   being coreboot's old name. The builtin image (dictionary embedded, no
   modules needed) is exactly the self-contained ELF a payload must be, and
   `CONFIG_LINUXBIOS=y` (coreboot-table parsing) is already in the default
   x86 config.
2. **The sister lab paved the road.** The OFW lab already proved the i440fx
   emulation board + `CONFIG_PAYLOAD_ELF` recipe on this exact cached coreboot
   tree, and established the isolation discipline for sharing it.

## The live commands

Guard first — the shared `~/linuxboot-lab/coreboot` tree now carries kept
artifacts from TWO sibling labs:

```console
$ cd ~/linuxboot-lab/coreboot && sha256sum .config build/coreboot.rom \
    .config-ofw build-ofw/coreboot.rom > ~/openbios-lab/coreboot-guard.sha
```

Then a five-line config and an isolated build (third parallel objdir in the
same tree — coreboot's `DOTCONFIG=`/`obj=` make this painless):

```console
$ cat > .config-openbios <<'EOF'
CONFIG_VENDOR_EMULATION=y
CONFIG_BOARD_EMULATION_QEMU_X86_I440FX=y
CONFIG_COREBOOT_ROMSIZE_KB_4096=y
CONFIG_PAYLOAD_ELF=y
CONFIG_PAYLOAD_FILE="/home/sqs/openbios-lab/openbios/obj-x86/openbios-builtin.elf"
EOF
$ make DOTCONFIG=.config-openbios obj=build-openbios olddefconfig
$ make DOTCONFIG=.config-openbios obj=build-openbios -j$(nproc)
Built emulation/qemu-i440fx (QEMU x86 i440fx/piix4)          # ~1 min, crossgcc cached
$ sha256sum -c ~/openbios-lab/coreboot-guard.sha
.config: OK
build/coreboot.rom: OK
.config-ofw: OK
build-ofw/coreboot.rom: OK
```

First boot:

```console
$ qemu-system-x86_64 -M pc,accel=kvm -m 256 -bios build-openbios/coreboot.rom \
    -display none -serial unix:...,server=on -no-reboot &
[NOTE ]  coreboot-c583b0c4f8f0-dirty ... bootblock starting ...
[NOTE ]  ... ramstage starting ...
Searching for LinuxBIOS tables...
vga-driver-fcode:Welcome to OpenBIOS v1.1 built on Jul 21 2026 ...
0 >   ok
0 > 3 4 + . 7  ok
```

June-2026 coreboot hands off to a payload whose table parser was written for
2003 LinuxBIOS, and the `ok` prompt answers. (The parser *did* have a modern
blind spot — but it fails soft here, and it took POC-4's Linux boot to expose
it: see the forwarding-table fix, bug #8.)

## Why this track still earns its keep

With the multiboot track (POC-2) already giving a bare-QEMU prompt, the
payload track's value is the *chain*: `-bios` → coreboot bootblock/romstage →
ramstage → ELF payload → Forth prompt — the identical shape as the OFW lab's
Track 2 and linuxboot's coreboot+LinuxBoot, with a different answer in the
payload slot. Same board, same tree, three payload philosophies:

```
build/           coreboot → LinuxBoot (u-root)     "Linux is the firmware"
build-ofw/       coreboot → OFW ofwlb.elf          "Forth, the original, frozen"
build-openbios/  coreboot → openbios-builtin.elf   "Forth, the rival, alive"
```

## Pitfalls checklist

- Extend the sha guard *before* the first build, and cover BOTH sibling labs'
  artifacts (`.config`/`build/` and `.config-ofw`/`build-ofw/`).
- i440fx, not q35 — proven board for these era-payloads (OFW POC-3 note).
- The builtin (not multiboot) image is the payload — no module plumbing in
  coreboot, and its embedded dictionary sidesteps POC-2's bug #2 entirely.
- On this track the banner DOES reach serial (`vga-driver-fcode:` prefix and
  all) — a quirk worth knowing when writing expect anchors that must serve
  both x86 tracks: anchor on `0 > `, not the banner.
