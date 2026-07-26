\ fcode-card.fth — a minimal FCode driver, tokenized to bytecode and carried on
\ a PCI card's expansion ROM. This is the mechanism that made Open Firmware
\ architecture-independent: a 1990s option card shipped its driver as ISA-neutral
\ bytecode, and any OF machine could run it.
\
\ The proof it ran is left in the DEVICE TREE, not on the console: probe-pci runs
\ BEFORE "Install console", so anything printed here would go into the void.
fcode-version2
   " fcode-card" device-name
   " FCODE-FROM-CARD-RAN" encode-string " fcode-marker" property
fcode-end
