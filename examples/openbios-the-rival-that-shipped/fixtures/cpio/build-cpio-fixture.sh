#!/usr/bin/env bash
# build-cpio-fixture.sh — author the newc cpio archive the `cpio` track reads.
#
# Derived at run time, never cached (the repo's rule): three members of known,
# distinct sizes — one nested — built with the host's OWN GNU cpio, so the same
# `cpio -itv` that lists them is a faithful oracle of the exact bytes the
# firmware walks. The archive is `newc` (`cpio -o -H newc`), the format
# `u-root -o initramfs.cpio` writes and the kernel's initramfs unpacker reads.
#
#   greet.txt  6 bytes  "hello\n"
#   data.bin   4 bytes  "ABCD"     — cpio-find's subject; its bytes are graded
#   etc/conf   4 bytes  "x=1\n"    — a nested path, so the name is not bare 8.3
#
# The member order is fixed here so the reader's order can be graded against
# `cpio -itv`'s. Usage: build-cpio-fixture.sh <out.cpio>
set -eu
OUT="${1:?usage: build-cpio-fixture.sh <out.cpio>}"
command -v cpio >/dev/null || { echo "cpio not installed (GNU cpio)" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf 'hello\n' > "$TMP/greet.txt"
printf 'ABCD'    > "$TMP/data.bin"
mkdir -p "$TMP/etc"; printf 'x=1\n' > "$TMP/etc/conf"

( cd "$TMP" && printf '%s\n' greet.txt data.bin etc/conf | cpio -o -H newc 2>/dev/null ) > "$OUT"
[[ -s "$OUT" ]] || { echo "cpio produced an empty archive at $OUT" >&2; exit 1; }
