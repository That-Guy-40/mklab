# Vendored upstream — Debian trixie official example preseed

A **byte-exact** archive of Debian's official example preconfiguration file — the
single reference this whole gallery is derived from. Every variant
`fetch-preseeds.sh` generates un-comments *this* file's own documented
partitioning options (method = `regular`\|`lvm`\|`crypto`, recipe =
`atomic`\|`home`\|`multi`); nothing is invented.

This is a self-contained copy (byte-identical to
[`../../debian-pxe-lab/upstream-preseed/example-preseed.txt`](../../debian-pxe-lab/upstream-preseed/README.md)),
so each lab archives its own source per the repo's self-containment rule.

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

```bash
sha256sum -c <<'EOF'
5db6b4d2662b3fb94c10f5a67a1431e8ebfe1007bdc54652a366ffbfd513a4a3  example-preseed.txt
EOF
```

## What's here vs. what's cited (not mirrored)

- **Vendored:** `example-preseed.txt`, the complete reference file, byte-exact.
- **Cited, not mirrored:** the *Debian Installation Guide* Appendix B
  (<https://www.debian.org/releases/trixie/amd64/apb.en.html>). The **netboot
  installer images** are fetched + checksum-verified by
  `../../debian-pxe-lab/fetch-debian-installer.sh`, not stored here.

## Licensing / attribution

Part of Debian's `installation-guide` package, distributed under the **GNU GPL
v2**. Copyright © the Debian Installer team and contributors. Archived here
unmodified for offline reference and provenance; `git rm` to remove. All rights
remain with the upstream authors.
