# Vendored upstream — Debian trixie official example preseed

This directory keeps a **byte-exact** archive of Debian's official example
preconfiguration file, so this lab is reproducible offline and its provenance
is explicit (upstream docs move between releases; `stable` will point at forky
once trixie ages out).

Both `examples/debian-pxe-lab/debian-preseed.cfg` (the single hand-tuned lab
preseed) and `examples/debian-preseed-gallery/` (the variant generator) are
derived from this file — they un-comment its documented choices rather than
inventing directives.

## Provenance

| Field | Value |
|---|---|
| Title | *Contents of the preconfiguration file (for trixie)* — `example-preseed.txt` |
| Publisher | The Debian Project (Debian Installer team) |
| Canonical URL | <https://www.debian.org/releases/trixie/example-preseed.txt> |
| Mirror URL | <https://d-i.debian.org/manual/example-preseed.txt> (byte-identical) |
| Generated from | the `installer-team/preseed` source package (`debian-installer/preseed`) |
| Release | Debian 13 "trixie" |
| Retrieved | 2026-07-03 |

## File hashes

| File | sha256 |
|---|---|
| `example-preseed.txt` | `5db6b4d2662b3fb94c10f5a67a1431e8ebfe1007bdc54652a366ffbfd513a4a3` |

Verify:

```bash
sha256sum -c <<'EOF'
5db6b4d2662b3fb94c10f5a67a1431e8ebfe1007bdc54652a366ffbfd513a4a3  example-preseed.txt
EOF
```

## What's here vs. what's cited (not mirrored)

- **Vendored:** `example-preseed.txt`, the complete reference file, byte-exact.
- **Cited, not mirrored:** the surrounding *Debian Installation Guide* appendix
  (Appendix B, *Automating the installation using preseeding*) at
  <https://www.debian.org/releases/trixie/amd64/apb.en.html> — read it live for
  the prose explaining each directive. The **netboot installer images**
  (`linux`/`initrd.gz`) are fetched + checksum-verified by
  `../fetch-debian-installer.sh`, not stored here.

## Licensing / attribution

The Debian Installation Guide and its generated `example-preseed.txt` are part
of Debian's `installation-guide` package, distributed under the **GNU GPL v2**
(see the guide's copyright notice). Copyright © the Debian Installer team and
contributors. Archived here unmodified for offline reference and provenance;
`git rm` this directory to remove it. All rights remain with the upstream
authors.
