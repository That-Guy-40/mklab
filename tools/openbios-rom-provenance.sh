#!/usr/bin/env bash
# openbios-rom-provenance.sh — bind a coreboot ROM to the payload inside it, and
# refuse a mismatch by name.
#
# THE DEFECT THIS EXISTS FOR, measured 2026-08-27. smoke-openbios.sh's `coreboot`
# track boots $COREBOOT_DIR/build-openbios/coreboot.rom and had NO relationship to
# the firmware under test — unlike the `multiboot` arm, which boots straight out of
# $OPENBIOS_WORKDIR. Consequences, both observed:
#
#   - Pointed at an EMPTY workdir the track still PASSED, reporting "OpenBIOS
#     (coreboot) answered 7 at the 0 > prompt" for a tree that had never been built.
#   - On this machine the ROM was dated Aug 25 and the payload ELF Aug 27, so every
#     run for two days had booted firmware predating an entire session of fixes
#     while presenting the result as a test of them.
#
# Nothing errored. The ROM is readable, it boots, it answers 7 — it is merely a
# record that has outlived its subject, which is bug class #1 in CLAUDE.md and the
# reason a green suite could not see this.
#
# WHY A CACHED PAIRING RATHER THAN A DERIVATION. The honest first choice is to
# derive: extract the payload from the ROM and compare it against the ELF. coreboot
# TRANSFORMS an ELF into its own segment format on the way in (1,163,888 bytes of
# ELF became a 79,144-byte `simple elf` CBFS file here), so a byte-compare is
# meaningless: `cbfstool extract` DOES work on a payload — the 2026-08-27 note here
# that it "cannot extract a payload at all" was a run missing the `-m ARCH` flag the
# error's own first line asks for (re-measured 2026-09-01: `extract -n
# fallback/payload -m x86` exits 0) — but what comes out is an ELF RECONSTITUTED
# from the SELF segments (sections and symbols gone; different size, different
# sha256 than the input), so deriving the pairing from bytes is still impossible.
# So the pairing is recorded at
# build time, which CLAUDE.md permits precisely here: "if it must be cached, bind it
# to its subject's identity and refuse a mismatch by name." Both ends are re-derived
# at check time; only the PAIRING is stored, because only the pairing is what cannot
# be recovered afterwards.
#
# TWO FAILURE MODES, GRADED DIFFERENTLY, and the difference is the ladder in
# CLAUDE.md:
#
#   - The ROM was built from a DIFFERENT payload  -> 77 (UNKNOWN). Nothing is
#     broken; the test simply cannot say anything about the firmware in front of it.
#     Rebuild the ROM and it has something to say again.
#   - The sidecar does not describe THIS ROM      -> 1 (FAIL). The record and
#     reality disagree, which is the LIED rung, and it outranks an honest failure
#     because everything downstream of it is unreliable.
set -uo pipefail

usage() {
    cat <<'USAGE'
openbios-rom-provenance.sh --stamp <rom> <payload-elf>
openbios-rom-provenance.sh --check <rom> <payload-elf>

  --stamp   record the pairing beside the ROM, as <rom>.provenance
  --check   re-derive both digests and compare against that record

Exit (check): 0 the ROM carries this payload / 77 UNKNOWN, stated / 1 the record
and the ROM disagree.
USAGE
}

MODE="${1:-}"; ROM="${2:-}"; ELF="${3:-}"
case "$MODE" in -h|--help) usage; exit 0 ;; esac
[[ "$MODE" == --stamp || "$MODE" == --check ]] || { usage >&2; exit 2; }
[[ -n "$ROM" && -n "$ELF" ]] || { usage >&2; exit 2; }
SIDECAR="$ROM.provenance"

if [[ "$MODE" == --stamp ]]; then
    [[ -f "$ROM" ]] || { echo "ERROR: no ROM at $ROM" >&2; exit 2; }
    [[ -f "$ELF" ]] || { echo "ERROR: no payload at $ELF" >&2; exit 2; }
    cat > "$SIDECAR" <<PROV
# Provenance for $(basename "$ROM"), written by tools/openbios-rom-provenance.sh.
#
# The pairing of a ROM with the payload built into it. Neither digest is trusted on
# its own: --check re-derives both from the bytes on disk and compares. What cannot
# be recovered after the fact, and is therefore the only thing stored, is WHICH
# payload went into this ROM.
rom-sha256: $(sha256sum "$ROM" | cut -d' ' -f1)
payload-sha256: $(sha256sum "$ELF" | cut -d' ' -f1)
payload-path: $ELF
stamped: $(date -u +%Y-%m-%dT%H:%M:%SZ)
PROV
    echo "==> stamped $(basename "$SIDECAR")"
    exit 0
fi

# ── --check ────────────────────────────────────────────────────────────────────
if [[ ! -f "$ROM" ]]; then
    echo "UNKNOWN: no ROM at $ROM"; exit 77
fi
if [[ ! -f "$SIDECAR" ]]; then
    echo "UNKNOWN: $ROM has no .provenance beside it, so nothing records which payload is inside it — rebuild with ./build-coreboot-openbios.sh to stamp one"
    exit 77
fi
if [[ ! -f "$ELF" ]]; then
    echo "UNKNOWN: no payload at $ELF, so there is nothing to compare the ROM against — run ./build-openbios.sh x86 first"
    exit 77
fi

want_rom="$(sed -n 's/^rom-sha256: //p'     "$SIDECAR" | head -1)"
want_pay="$(sed -n 's/^payload-sha256: //p' "$SIDECAR" | head -1)"
if [[ ! "$want_rom" =~ ^[0-9a-f]{64}$ || ! "$want_pay" =~ ^[0-9a-f]{64}$ ]]; then
    echo "FAIL: $SIDECAR does not carry two 64-hex digests — it was hand-edited or truncated, and a provenance record that cannot be parsed is worse than none: it looks like one"
    exit 1
fi

got_rom="$(sha256sum "$ROM" | cut -d' ' -f1)"
got_pay="$(sha256sum "$ELF" | cut -d' ' -f1)"

# ROM-vs-record FIRST. If the sidecar is not about this ROM, its payload line is
# not about this ROM either, and reporting on it would be the lie compounding.
if [[ "$got_rom" != "$want_rom" ]]; then
    echo "FAIL: $(basename "$SIDECAR") describes a different ROM — recorded ${want_rom:0:12}, on disk ${got_rom:0:12}. The ROM was rebuilt or replaced without restamping, so the payload line beside it is about some other build."
    exit 1
fi
if [[ "$got_pay" != "$want_pay" ]]; then
    echo "UNKNOWN: this ROM was built from a DIFFERENT payload — it carries ${want_pay:0:12}, the tree now has ${got_pay:0:12}. Booting it would report on firmware that is not the firmware under test. Rebuild with ./build-coreboot-openbios.sh."
    exit 77
fi
echo "the ROM carries this tree's payload (${got_pay:0:12})"
exit 0
