\ fcode-card.fth — a minimal FCode driver, tokenized to bytecode and carried on
\ a PCI card's expansion ROM. This is the mechanism that made Open Firmware
\ architecture-independent: a 1990s option card shipped its driver as ISA-neutral
\ bytecode, and any OF machine could run it.
\
\ The proof it ran is left in the DEVICE TREE, not on the console: a probe runs
\ before the console exists, so anything printed here would go into the void.
\
\ A byte-for-byte copy of examples/open-firmware-debugs-itself/dsl/fcode-card.fth
\ (this repo's self-containment rule: a lab copies, it does not cross-load). There
\ it rides an e1000 under Firmworks OFW; here the SAME ROM rides an e1000 under
\ OpenBIOS -- vendor/device ffff in its PCIR is "any card", so one artifact serves
\ both firmwares, which is what makes the comparison a comparison.
fcode-version2
   " fcode-card" device-name
   " FCODE-FROM-CARD-RAN" encode-string " fcode-marker" property
fcode-end
