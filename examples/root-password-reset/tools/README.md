# tools — serial-console driver

[`serial-drive.py`](serial-drive.py) scripts a QEMU **serial console** over a
`lab-vm.sh` VM's unix `serial.sock`: catch the GRUB countdown, edit the kernel
command line, then log in to confirm a password reset — or just passively
`--capture` the boot. It is the automation behind the **verified** transcripts in
[`../MANUAL_TESTING.md`](../MANUAL_TESTING.md).

It exists to work around the single hardest part of this lab: **GRUB's serial
input has no flow control and silently drops characters** sent too fast. The
driver sends **one byte at a time with a ~40 ms delay** and single-steps
keystrokes (single-byte emacs motions `Ctrl-n`/`Ctrl-p`/`Ctrl-a`/`Ctrl-e`, never
arrow escapes — the leading `Esc` reads as "discard edits"). See the module
docstring and [`../../../CLAUDE.md`](../../../CLAUDE.md) ("Driving a boot loader /
firmware serial console from a script") for the full list of traps.

> A **human** typing at `lab-vm.sh console` is naturally slow enough to hit none
> of this. The driver is only needed for *deterministic automation* / reruns.

## Quick use

```bash
# one client at a time on the socket — stop anything else attached first
SOCK=~/.local/state/lab-create/vms/rpr-debian-bios/serial.sock

# passively watch a boot (e.g. to see whether GRUB reaches the serial menu):
python3 serial-drive.py "$SOCK" --capture 60 --log /tmp/boot.transcript

# drive a scripted edit (DSL on stdin; see the docstring for all ops):
python3 serial-drive.py "$SOCK" --timeout 90 --log /tmp/reset.transcript <<'EOF'
EXPECT automatically in
KEY 20
SEND e
EOF
```

Ground-truth the result with the booted kernel's `/proc/cmdline`, not by
scraping GRUB's per-keystroke ANSI redraws. Full DSL reference: `serial-drive.py`
with no arguments (or read the module docstring).
