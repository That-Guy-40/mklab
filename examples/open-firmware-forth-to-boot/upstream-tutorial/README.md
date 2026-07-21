# upstream-tutorial — byte-exact archive of the openfirmware.info how-tos

The three wiki pages this lab operationalizes, saved **byte-exact** with their
stylesheets so they render offline. openfirmware.info is a decade-stale
documentation site (the svn endpoint it references is already dead) — a prime
link-rot candidate, hence the archive.

## Provenance

| | |
|---|---|
| **Site** | openfirmware.info — "OpenBIOS documentation" (a Sphinx render; hosts docs for both OpenBIOS *and* Mitch Bradley's Open Firmware — the lab explains the distinction) |
| **Authors** | The OpenBIOS/coreboot wiki community; the OFW content traces to Mitch Bradley / Firmworks |
| **Canonical URLs** | `https://www.openfirmware.info/<page>.html` (see table below) |
| **Published** | The recipes are QEMU-0.9.1 / coreboot-v2/v3 era (~2008); the Sphinx rendering is later |
| **Retrieved** | 2026-07-21, all pages HTTP 200 with expected `<title>`s verified before hashing |

## Files

| file | sha256 |
|---|---|
| `Open_Firmware.html` | `17ab8df720311d146f15732a22b308f2561b0e1feaa7c634498cb485ec987f16` |
| `Building_OFW_for_QEMU.html` | `3d2dde344d3d5ebdba12078a2c69b92462ea10364cd5de0a2ccca20c0f711410` |
| `OFW_as_a_coreboot_Payload.html` | `f4614da1b233b0fadbba3be97496166330d4a4758106776a852a115da2c799af` |
| `_static/alabaster.css` | `0d8f370b1fc706ed0da4ac1f7ff1f2f00561baefd2bafc530ef697e5346727b3` |
| `_static/basic.css` | `a38727026ca8e79bc677b7b3d373cc328d82b7e03582e1f6e7a0845a642ab9dc` |
| `_static/custom.css` | `39f23a6561786e3cb4e33e4a96562a1305a8b74c0d45dc215a64018692cd5d4c` |
| `_static/pygments.css` | `a42214812c4dcad4030f3aff4dededf30929b5a2158e365dcb6fef0755958b86` |

**Left un-vendored:** the pages' `_static/*.js` (Sphinx doctools — cosmetic
only; the pages read fine without them), the site's navigation targets
(`genindex.html`, `search.html`, neighboring articles), and any images —
their links resolve against the live site.

## What the lab does differently (era deviations, proven in the POCs)

The recipes are followed faithfully except where 2026 forced a change — each
deviation is documented where it was discovered: `svn co` → GitHub clone and
`-std=gnu89` ([POC-1](../POC-1-BUILD-BOX.md)); serial-console/physical-mode
config, ISO9660 instead of the dead ATA-disk path, and the memory-map fixes
([POC-2](../POC-2-OK-PROMPT.md)); modern coreboot + `resident-packages`
([POC-3](../POC-3-COREBOOT-PAYLOAD.md)).

## Copyright & attribution

All rights to the archived pages remain with their authors and the
OpenBIOS/openfirmware.info project. They are archived here solely as an
offline reference for this lab, with source URLs and retrieval dates recorded
above. `git rm -r upstream-tutorial/` removes the archive.
