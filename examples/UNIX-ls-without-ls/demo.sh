#!/usr/bin/env bash
# demo.sh — ls without ls: prove it, don't just show it.
#
# Runs in ~/ls-without-ls/ inside the lab container (see ../setup-workshop.sh)
# or straight from the repo checkout. Ends on exactly one verdict line:
# PASS: / FAIL: / SKIP:.
#
# THE PREMISE. `ddls` reimplements ls from bash builtins + GNU stat + tput —
# no awk, no sed, no grep, no ls. The only standard that matters for a
# reimplementation is the original: this demo runs ddls and GNU ls over the
# same crafted directory and diffs the bytes. Where they agree, that is the
# check. Where they DISAGREE, the divergence is asserted exactly (so it can't
# drift silently), and the corrected twin in bin/fixed/ is held to the
# stricter standard: it must match ls.
#
# LC_ALL=C is load-bearing twice over: ls's sort order is collation-dependent
# (glibc vs musl would disagree), and ls's -l time format is locale-dependent.
# One export is why this file is reproducible on Debian AND Alpine.
export LC_ALL=C
export TZ="${TZ:-UTC}"

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASSED=0; FAILED=0
DDLS="$HERE/bin/ddls"           # the object of study, VERBATIM
FDLS="$HERE/bin/fixed/ddls"     # the corrected twin

# sha256 of the vendored original (upstream-source/ddls.sh.txt). bin/ddls must
# never drift from it — you cannot learn from code that was silently rewritten.
DDLS_SHA="45437be6ab84316fab53069ca1052bccddaf9363b92f66ed547d5ba1e660e47a"

# ── verdict helpers (house convention) ─────────────────────────────────────────
note() { printf '  %s\n' "$*"; }
ok()   { PASSED=$((PASSED+1)); printf '   [ok]  %s\n' "$*"; }
bad()  { FAILED=$((FAILED+1)); printf '   [XX]  %s\n' "$*"; }
check() { # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then ok "$1"
    else bad "$1"; printf '            expected: [%s]\n            actual:   [%s]\n' "$2" "$3"; fi
}
check_diff() { # check_diff <label> <file-expected> <file-actual>
    if diff -u "$2" "$3" > "$WORK/diff.tmp" 2>&1; then ok "$1"
    else bad "$1"; sed 's/^/            /' "$WORK/diff.tmp" | head -15; fi
}
# EXIT-trap safety net: a bare `exit` must never leave the reader with no verdict.
_verdict_printed=""
WORK=""
cleanup() {
    rc=$?
    [ -n "$WORK" ] && [ -d "$WORK" ] && case "$WORK" in
        */ddls-demo.*) rm -rf "$WORK" ;;
    esac
    [ -n "$_verdict_printed" ] || { [ "$rc" = 0 ] && rc=1
        printf 'FAIL: demo.sh exited early (rc=%s)\n' "$rc"; }
}
trap cleanup EXIT

# ── preflight ──────────────────────────────────────────────────────────────────
[ -r "$DDLS" ] || { _verdict_printed=1; echo "SKIP: $DDLS not found (run from the sandbox or repo)"; exit 77; }
[ -r "$FDLS" ] || { _verdict_printed=1; echo "SKIP: $FDLS not found"; exit 77; }
ls --version 2>/dev/null | head -1 | grep -q GNU \
    || { _verdict_printed=1; echo "SKIP: ls is not GNU ls -- the oracle must be the real thing (run setup-workshop.sh; BusyBox ls will not do)"; exit 77; }
stat --version 2>/dev/null | head -1 | grep -q GNU \
    || { _verdict_printed=1; echo "SKIP: stat is not GNU stat (ddls needs stat --printf)"; exit 77; }
[ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; } \
    || { _verdict_printed=1; echo "SKIP: bash >= 4.2 required (printf %(...)T)"; exit 77; }
HAVE_SCRIPT=1
command -v script >/dev/null || HAVE_SCRIPT=0

echo "================================================================"
echo " ls without ls -- ddls vs the real thing, byte for byte"
echo "================================================================"

# ── 0. the fixture: one crafted directory, mtimes and sizes all distinct ──────
# Everything the demo LISTS lives in $WORK/box; everything the demo WRITES
# (captured outputs, later fixtures) lives outside it, so the two sides of
# every diff see exactly the same directory.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ddls-demo.XXXXXX")"
mkdir "$WORK/box"
cd "$WORK/box"
mkdir subdir subdir/nested
printf 'hello\n'             > subdir/inner.txt
printf 'alpha\n'             > alpha.txt
printf 'beta beta\n'         > beta.log
printf '#!/bin/sh\nexit 0\n' > tool.sh && chmod +x tool.sh
printf 'h'                   > .hidden
head -c 3000 /dev/zero       > filler.dat
ln -s alpha.txt link-ok
ln -s nowhere   link-dangling
mkfifo fifo1
# distinct whole-second mtimes, all safely clear of the ~6-month -l boundary
i=0
for f in .hidden alpha.txt beta.log filler.dat tool.sh link-ok link-dangling fifo1 subdir subdir/inner.txt subdir/nested; do
    i=$((i+1))
    touch -h -d "$i days ago 12:00:0$((i%10))" "$f"
done
touch -d '400 days ago' beta.log     # one entry in the "Mon dd  YYYY" format

# ── 1. provenance: what is under test ─────────────────────────────────────────
echo
echo "1. PROVENANCE: the verbatim script, and what it actually calls."
actual_sha="$(sha256sum "$DDLS" | cut -d' ' -f1)"
check "bin/ddls is byte-identical to the vendored original (sha256)" "$DDLS_SHA" "$actual_sha"
dd_calls="$(grep -cE '(^|[^-A-Za-z_.])dd[[:space:]]+(if=|of=|bs=)' "$DDLS")" || true
note "the script is CALLED ddls, its header SAYS it uses dd..."
check "...but it never invokes dd anywhere -- the dd is branding" "0" "$dd_calls"
# Every external ddls runs is spawned via $( ) command substitution -- a fork
# per call. Census them by that shape (comments and help text don't match).
externals="$(grep -oE '\$\((stat|tput|dirname|awk|sed|grep|ls|find|sort|date|column|dd) ' "$DDLS" \
    | tr -d '$( ' | sort -u | tr '\n' ' ')"
note "externals actually invoked: $externals"
check "externals are exactly: dirname stat tput (dirname breaks the stated 'no other externals')" \
      "dirname stat tput " "$externals"

# ── 2. the oracle: ddls vs GNU ls, byte for byte ──────────────────────────────
echo
echo "2. THE ORACLE: same directory, both tools, diff the bytes."
for flags in -1 "-a -1" "-A -1" "-S -1" "-r -1" "-F -1" "-t -1" -n; do
    # shellcheck disable=SC2086
    bash "$DDLS" $flags . > "$WORK/out.ddls" 2>&1
    # shellcheck disable=SC2086
    ls $flags . > "$WORK/out.ls" 2>&1
    check_diff "ddls $flags  ==  ls $flags" "$WORK/out.ls" "$WORK/out.ddls"
done
bash "$DDLS" -la . > "$WORK/out.ddls"; ls -la . > "$WORK/out.ls"
check_diff "ddls -la == ls -la -- perms, links, owner, sizes, dates, total line: all of it" \
           "$WORK/out.ls" "$WORK/out.ddls"
bash "$DDLS" -R subdir > "$WORK/out.ddls"; ls -R -1 subdir > "$WORK/out.ls"
check_diff "ddls -R == ls -R -1 (recursion, headers, blank lines)" "$WORK/out.ls" "$WORK/out.ddls"
bash "$DDLS" -l link-dangling > "$WORK/out.ddls"; ls -l link-dangling > "$WORK/out.ls"
check_diff "a dangling symlink still prints 'link-dangling -> nowhere'" "$WORK/out.ls" "$WORK/out.ddls"

bash "$DDLS" no-such-file > "$WORK/out.ddls" 2>&1; rc_d=$?
ls no-such-file          > "$WORK/out.ls"   2>&1; rc_l=$?
check "missing file: ddls exits 2, like ls ($rc_l)" "$rc_l" "$rc_d"
sed 's/^ls:/ddls:/' "$WORK/out.ls" > "$WORK/out.ls.norm"
check_diff "missing file: same message, modulo argv[0]" "$WORK/out.ls.norm" "$WORK/out.ddls"

# ── 3. documented divergences -- asserted exactly, then fixed ─────────────────
echo
echo "3. DIVERGENCES: four places ddls and ls disagree. Each is pinned"
echo "   as a REGRESSION check on the verbatim script (so it cannot drift"
echo "   silently), and the corrected twin must match ls."
cd "$WORK"

note "(a) -t compares whole seconds (stat %Y); ls compares nanoseconds."
mkdir tie && touch -d '2026-01-01 10:00:00.900' tie/zzz \
          && touch -d '2026-01-01 10:00:00.100' tie/aaa \
          && touch -d '2026-01-01 10:00:01.500' tie/mmm
check "REGRESSION: verbatim -t breaks the same-second tie by NAME (aaa first)" \
      "mmm aaa zzz" "$(bash "$DDLS" -t -1 tie | tr '\n' ' ' | sed 's/ $//')"
check "GNU ls breaks it by NANOSECONDS (zzz is .9s, newer)" \
      "mmm zzz aaa" "$(ls -t -1 tie | tr '\n' ' ' | sed 's/ $//')"
check "FIXED: bin/fixed/ddls -t agrees with ls (%.9Y)" \
      "$(ls -t -1 tie | tr '\n' ' ')" "$(bash "$FDLS" -t -1 tie | tr '\n' ' ')"

note "(b) -h truncates where GNU ls rounds UP."
head -c 1025 /dev/zero > kilo.plus
head -c 1048575 /dev/zero > almost.meg
check "REGRESSION: verbatim -lh says 1025 B = 1.0K (floor)" \
      "1.0K" "$(bash "$DDLS" -lh kilo.plus | tr -s ' ' | cut -d' ' -f5)"
check "GNU ls says 1025 B = 1.1K (ceiling)" \
      "1.1K" "$(ls -lh kilo.plus | tr -s ' ' | cut -d' ' -f5)"
check "REGRESSION: verbatim -lh says 1048575 B = 1023K; ls says 1.0M" \
      "1023K" "$(bash "$DDLS" -lh almost.meg | tr -s ' ' | cut -d' ' -f5)"
hs_all_ok=yes
for sz in 1023 1024 1025 1536 1537 10239 10240 1048575 1048576 5242881; do
    head -c "$sz" /dev/zero > hs.tmp
    a="$(ls -lh hs.tmp | tr -s ' ' | cut -d' ' -f5)"
    b="$(bash "$FDLS" -lh hs.tmp | tr -s ' ' | cut -d' ' -f5)"
    [ "$a" = "$b" ] || { hs_all_ok="MISMATCH at $sz: ls=$a fixed=$b"; break; }
done
check "FIXED: -lh matches ls across 10 boundary sizes (1023 B ... 5 MiB)" "yes" "$hs_all_ok"

if [ -c /dev/null ]; then
    note "(c) device files: minor printed as %3d; ls pads it dynamically."
    check "REGRESSION: verbatim prints '1,   3' for /dev/null (ls: '1, 3')" \
          "1,   3" "$(bash "$DDLS" -l /dev/null | grep -o '1,   3')"
    bash "$FDLS" -l /dev/null > "$WORK/out.ddls"; ls -l /dev/null > "$WORK/out.ls"
    check_diff "FIXED: the /dev/null line matches ls exactly" "$WORK/out.ls" "$WORK/out.ddls"
else
    note "(c) no /dev/null in this environment -- device checks skipped"
fi

note "(d) multiple FILE arguments: argv order + blank lines; ls groups and sorts."
check "REGRESSION: verbatim keeps argv order with a blank line between" \
      "box/beta.log||box/alpha.txt" \
      "$(bash "$DDLS" -1 box/beta.log box/alpha.txt | tr '\n' '|' | sed 's/|$//')"
check "FIXED: grouped into one sorted listing, like ls" \
      "$(ls -1 box/beta.log box/alpha.txt | tr '\n' '|')" \
      "$(bash "$FDLS" -1 box/beta.log box/alpha.txt | tr '\n' '|')"

# ── 4. tty-only behavior (colors, columns) via script(1) ──────────────────────
echo
echo "4. ON A TTY: color and column behavior (driven through script(1))."
ESC="$(printf '\033')"
if [ "$HAVE_SCRIPT" = 1 ]; then
    cd "$WORK/box"
    esc_n="$(script -qec "bash '$DDLS' --color=never ." /dev/null | grep -c "${ESC}\[")" || true
    check "REGRESSION: --color=never on a tty STILL emits ANSI (auto-color runs after parse_args)" \
          "yes" "$( [ "${esc_n:-0}" -gt 0 ] && echo yes || echo no )"
    esc_n="$(script -qec "DDLS_NO_COLOR=1 bash '$DDLS' --color=never ." /dev/null | grep -c "${ESC}\[")" || true
    check "...the env var DDLS_NO_COLOR=1 is the only working off switch" "0" "${esc_n:-0}"
    esc_n="$(script -qec "bash '$FDLS' --color=never ." /dev/null | grep -c "${ESC}\[")" || true
    check "FIXED: --color=never is honored" "0" "${esc_n:-0}"

    cd "$WORK"
    mkdir manyfiles; for i in 01 02 03 04 05 06 07 08 09 10 11 12; do touch "manyfiles/f$i"; done
    # How many of the 12 survive depends on the pty's width (it equals the
    # column layout's num_rows) -- the INVARIANT is: some are silently dropped.
    shown="$(script -qec "stty cols 40; bash '$DDLS' -i manyfiles" /dev/null | grep -c 'f[0-9]')" || true
    note "verbatim -i in columns printed ${shown:-0} of 12 entries -- no error, no hint"
    check "REGRESSION: -i in column mode silently drops entries (fewer than 12 shown)" \
          "dropped" "$( [ "${shown:-0}" -ge 1 ] && [ "${shown:-0}" -lt 12 ] && echo dropped || echo "all-${shown:-0}" )"
    shown="$(script -qec "stty cols 40; bash '$FDLS' -i manyfiles" /dev/null | grep -c 'f[0-9]')" || true
    check "FIXED: -i falls back to one-per-line and shows all 12" "12" "${shown:-0}"
else
    note "script(1) not found -- 5 tty checks skipped (install util-linux)"
fi

# ── verdict ───────────────────────────────────────────────────────────────────
echo
echo "----------------------------------------------------------------"
TOTAL=$((PASSED+FAILED))
_verdict_printed=1
if [ "$FAILED" -eq 0 ]; then
    echo "PASS: all $TOTAL checks hold (ddls == GNU ls byte-for-byte on the core;"
    echo "      all 4 divergences pinned exactly; the fixed twin closes every one)"
    exit 0
else
    echo "FAIL: $FAILED of $TOTAL checks failed"
    exit 1
fi
