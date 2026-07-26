\ spike1-card.fth — a minimal FCode driver, tokenized to bytecode and carried on
\ a PCI card's expansion ROM. If the firmware evaluates it, the proof is left in
\ the DEVICE TREE, not on the console: probe-pci runs BEFORE "Install console",
\ so anything printed here would go into the void.
fcode-version2
   " spike1-card" device-name
   " SPIKE1-FCODE-RAN" encode-string " spike1-marker" property
fcode-end
