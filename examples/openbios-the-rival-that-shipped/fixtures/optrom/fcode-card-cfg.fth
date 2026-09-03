\ fcode-card-cfg.fth — the SECOND card, and the one that needs the firmware to be
\ a PCI bus. Where fcode-card.fth only names its node, this driver READS ITS OWN
\ CONFIGURATION SPACE from inside its own bytecode, the way the IEEE 1275 PCI Bus
\ Binding says a card driver does it:
\
\   my-space                        the device's config-space address (phys.hi:
\                                   bus<<16 | dev<<11 | fn<<8), handed to the
\                                   driver by the firmware that probed it
\   " config-l@" $call-parent       config space is the PARENT BUS's business, so
\                                   the driver calls the bus node's method — it is
\                                   not an FCode function and has no token
\                                   (measured 2026-09-03: neither toke nor detok
\                                   knows `config-l@`; `$call-parent` is 0x209)
\
\ Register 0 is vendor-id (low half) and device-id (high half), so `cfg-id` must
\ come out 0x100e8086 on a QEMU e1000 — a number the card read about ITSELF, which
\ the host can check against `lspci`/`info pci` without trusting the firmware.
\
\ WHAT THIS IS THE TEST OF. Patch 55 bound config-{b,w,l}@/! as global words: good
\ enough for a Forth prompt, and invisible to a card. Patch 56 puts them where the
\ binding puts them — methods of the PCI bus node — so this driver resolves them
\ through its parent. Before 56 this exact bytecode byte-loads and throws (the
\ negative control, measured), and no `cfg-id` appears.
fcode-version2
   " cfg-card" device-name
   my-space " config-l@" $call-parent  encode-int " cfg-id" property
fcode-end
