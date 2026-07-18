#!/usr/bin/env bash
# demo.sh — less without less: prove it, don't just show it.
#
# Runs in ~/less-without-less/ inside the lab container (see
# ../setup-workshop.sh) or straight from the repo checkout. Ends on exactly
# one verdict line: PASS: / FAIL: / SKIP:.
#
# THE PREMISE. `ddpager` is a full-screen, raw-terminal-mode program — you
# cannot pipe keystrokes into it and call that a test (the line discipline,
# not the program, would eat them). So this demo drives it through a REAL
# pty (drive-pager.py), typing one byte every 40 ms like a careful human,
# and greps the captured screen bytes for the status-line evidence.
#
# It also proves the two mechanisms the pager quietly depends on:
#   * the dd binary-detection trick — bash's $( ) strips NUL bytes, dd's
#     stderr knows how many bytes there really were; the difference IS the
#     detector — reproduced standalone;
#   * the raw-mode illusion — `stty raw` turns ICRNL and ISIG off, yet
#     Enter (\r) works and Ctrl-C kills the pager (exit 130, as USAGE.md
#     says). Both happen because bash's `read -n1` swaps its OWN termios in
#     for the duration of every read. An external reader (dd) sees the raw
#     bytes 13 and 3 that bash's read never lets the script see.
export LC_ALL=C

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASSED=0; FAILED=0
PAGER_BIN="$HERE/bin/ddpager"      # the object of study, VERBATIM
DRIVER="$HERE/drive-pager.py"

# sha256 of the vendored original (upstream-source/ddpager.sh). bin/ddpager
# must never drift from it.
PAGER_SHA="96edd0965de6cd33fa12b24814f7d5c64c518056ebcb723cb7628cbc21d7866a"

# ── verdict helpers (house convention) ─────────────────────────────────────────
note() { printf '  %s\n' "$*"; }
ok()   { PASSED=$((PASSED+1)); printf '   [ok]  %s\n' "$*"; }
bad()  { FAILED=$((FAILED+1)); printf '   [XX]  %s\n' "$*"; }
check() { # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then ok "$1"
    else bad "$1"; printf '            expected: [%s]\n            actual:   [%s]\n' "$2" "$3"; fi
}
# EXIT-trap safety net: a bare `exit` must never leave the reader with no verdict.
_verdict_printed=""
WORK=""
cleanup() {
    rc=$?
    [ -n "$WORK" ] && [ -d "$WORK" ] && case "$WORK" in
        */ddpager-demo.*) rm -rf "$WORK" ;;
    esac
    [ -n "$_verdict_printed" ] || { [ "$rc" = 0 ] && rc=1
        printf 'FAIL: demo.sh exited early (rc=%s)\n' "$rc"; }
}
trap cleanup EXIT

# ── preflight ──────────────────────────────────────────────────────────────────
[ -r "$PAGER_BIN" ] || { _verdict_printed=1; echo "SKIP: $PAGER_BIN not found (run from the sandbox or repo)"; exit 77; }
[ -r "$DRIVER" ]    || { _verdict_printed=1; echo "SKIP: $DRIVER not found"; exit 77; }
command -v python3 >/dev/null \
    || { _verdict_printed=1; echo "SKIP: python3 not installed (run setup-workshop.sh; the pty driver needs it)"; exit 77; }
command -v tput >/dev/null \
    || { _verdict_printed=1; echo "SKIP: tput not installed (ddpager needs it; run setup-workshop.sh)"; exit 77; }

# drive <out-basename> <keys...> -- <pager args...>  -> sets DRV_RC
drive() {
    local out="$WORK/$1"; shift
    local -a keys=()
    while [ "$1" != "--" ]; do keys+=(-k "$1"); shift; done
    shift
    DRV_RC=0
    python3 "$DRIVER" --out "$out" --timeout 20 "${keys[@]}" -- \
        bash "$PAGER_BIN" "$@" || DRV_RC=$?
}
# saw <out-basename> <literal-string>  -> "yes"/"no" (screen bytes contain it)
saw() { grep -aqF "$2" "$WORK/$1" && echo yes || echo no; }

echo "================================================================"
echo " less without less -- driving ddpager through a real pty"
echo "================================================================"

# ── 0. fixtures ────────────────────────────────────────────────────────────────
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ddpager-demo.XXXXXX")"
cd "$WORK"    # short filenames: the 80-column status line truncates long paths
seq 1 100 | sed 's/^/line /' > hundred.txt
{ seq 1 59 | sed 's/^/line /'; echo 'a needle here'
  seq 61 79 | sed 's/^/line /'; echo 'a needle again'
  seq 81 100 | sed 's/^/line /'; } > haystack.txt
printf 'text\000with\000nuls\000inside\n' > binary.bin
printf 'plain text, no surprises\n' > plain.txt

# ── 1. provenance & the parts that need no terminal ───────────────────────────
echo
echo "1. PROVENANCE: the verbatim script, and the dd it actually earns."
actual_sha="$(sha256sum "$PAGER_BIN" | cut -d' ' -f1)"
check "bin/ddpager is byte-identical to the vendored original (sha256)" "$PAGER_SHA" "$actual_sha"
dd_calls="$(grep -c '\$(dd ' "$PAGER_BIN")" || true
check "unlike its sibling ddls, ddpager REALLY calls dd (2 call sites, both in detect_binary)" \
      "2" "$dd_calls"
check "-v prints the version and exits 0" \
      "ddpager 0.1.0/0" "$(bash "$PAGER_BIN" -v)/$?"
msg="$(bash "$PAGER_BIN" missing.txt 2>&1 </dev/null)"; rc=$?
check "a missing file is refused with exit 1" "1" "$rc"
check "...and says so" "yes" "$(printf '%s' "$msg" | grep -qF 'No such file' && echo yes || echo no)"

# ── 2. the dd trick, reproduced standalone ────────────────────────────────────
echo
echo "2. THE dd TRICK: bash \$( ) silently strips NUL bytes; dd knows the truth."
real_bytes="$(stat -c %s binary.bin 2>/dev/null || wc -c < binary.bin)"
# bash >= 5.1 tattles on the stripping ("ignored null byte in input") on OUR
# stderr; older bash strips silently -- which is exactly why dd's stderr
# byte-count, not a bash-side warning, is the load-bearing detector.
{ sample="$(dd if=binary.bin bs=512 count=1 2>/dev/null; printf X)"; } 2>/dev/null
sample="${sample%X}"
note "binary.bin: $real_bytes bytes on disk, ${#sample} after a bash \$( ) round-trip"
note "(your bash may print 'warning: ignored null byte in input' here -- suppressed;"
note " older bashes strip silently, which is why dd's byte-count is the detector)"
check "NULs vanish in command substitution -> length shrinks -> BINARY detected" \
      "yes" "$( [ "${#sample}" -lt "$real_bytes" ] && echo yes || echo no )"
real_bytes="$(stat -c %s plain.txt 2>/dev/null || wc -c < plain.txt)"
sample="$(dd if=plain.txt bs=512 count=1 2>/dev/null; printf X)"; sample="${sample%X}"
check "a text file survives the round-trip intact (trailing-newline sentinel and all)" \
      "$real_bytes" "${#sample}"

# ── 3. the pager, driven like a human ─────────────────────────────────────────
echo
echo "3. THE PAGER: keystrokes in, status-line evidence out."
drive open-quit.bin "1.0:q" -- hundred.txt
check "open a file, press q: clean exit 0" "0" "$DRV_RC"
check "the status line shows 'line 1/100'" "yes" "$(saw open-quit.bin 'line 1/100')"
check "the alternate screen was entered (smcup)..." "yes" \
      "$(grep -aqF $'\033[?1049h' "$WORK/open-quit.bin" && echo yes || echo no)"
check "...and left again on quit (rmcup): your shell gets its screen back" "yes" \
      "$(grep -aqF $'\033[?1049l' "$WORK/open-quit.bin" && echo yes || echo no)"

drive binary.out "1.0:q" -- binary.bin
check "opening a NUL-laden file shows the binary WARNING" "yes" "$(saw binary.out 'WARNING: binary file detected')"
drive plain.out "1.0:q" -- plain.txt
check "a plain text file draws no such warning" "no" "$(saw plain.out 'WARNING: binary file detected')"

drive goto.bin "1.0:25G" "0.8:G" "0.8:q" -- hundred.txt
check "25G jumps to line 25 (numeric prefix, vi-style)" "yes" "$(saw goto.bin 'line 25/100')"
check "bare G lands on the last page: (END)" "yes" "$(saw goto.bin '(END)')"

drive scroll.bin "1.0:\r" "0.6:q" -- hundred.txt
check "Enter (a raw \\r!) scrolls one line -- keep reading, section 4 explains why" \
      "yes" "$(saw scroll.bin 'line 2/100')"

drive search.bin "1.0:/needle\n" "0.8:n" "0.8:q" -- haystack.txt
check "/needle jumps to the first hit at line 60" "yes" "$(saw search.bin 'line 60/100')"
check "n finds the second hit (line 80) -- shown clamped to the last page, 'line 78/100'" \
      "yes" "$(saw search.bin 'line 78/100')"

drive filter.bin "1.0:&needle\n" "0.8:q" -- haystack.txt
check "&needle filters the view: '2 matching lines'" "yes" "$(saw filter.bin '2 matching lines')"

drive ring.bin "1.0::n\n" "0.8:q" -- haystack.txt hundred.txt
check "two files open with a ring hint: 'Opened 2 files'" "yes" "$(saw ring.bin 'Opened 2 files')"
check ":n switches to '(file 2 of 2)'" "yes" "$(saw ring.bin '(file 2 of 2)')"

drive info.bin "1.0:h" "0.8:q" "0.6:=" "0.8:\x07" "0.8:q" -- haystack.txt
check "h shows the help screen (NAVIGATION)" "yes" "$(saw info.bin 'NAVIGATION')"
check "= shows short file info: 'haystack.txt: 100 lines'" "yes" "$(saw info.bin 'haystack.txt: 100 lines')"
check "Ctrl-G shows extended info (name, line range, bytes)" "yes" \
      "$(grep -aq ' bytes [0-9]' "$WORK/info.bin" && echo yes || echo no)"

EDITOR=/bin/true drive edit.bin "1.0:v" "1.0:q" -- plain.txt
check "v hands off to \$EDITOR and reloads: 'Reloaded after edit'" "yes" "$(saw edit.bin 'Reloaded after edit')"

# ── 4. the raw-mode illusion ──────────────────────────────────────────────────
echo
echo "4. THE RAW-MODE ILLUSION: term_init says 'stty raw' (ICRNL off, ISIG"
echo "   off) -- so Enter should be a dead key and Ctrl-C should be a plain"
echo "   byte. Yet Enter scrolls (section 3) and Ctrl-C kills the pager:"
drive intr.bin "1.0:\x03" -- hundred.txt
check "Ctrl-C exits 130 -- exactly what USAGE.md documents, DESPITE stty raw" "130" "$DRV_RC"
check "...and bash still ran the EXIT trap: rmcup restored the terminal" "yes" \
      "$(grep -aqF $'\033[?1049l' "$WORK/intr.bin" && echo yes || echo no)"

note "the mechanism: bash's read -n1 swaps its OWN termios in during every"
note "read (ICRNL and ISIG come back on), then restores. Proof: replace the"
note "reader with dd -- an external that cannot touch termios -- and the raw"
note "bytes reappear:"
cat > rawprobe.sh <<'RAWPROBE'
#!/usr/bin/env bash
# Reads 3 keys with dd (NOT bash's read) under the pager's exact stty line,
# and logs the raw byte values it received.
stty -echo -icanon raw min 1 time 0
: > rawlog.txt
for i in 1 2 3; do
    b=$(dd bs=1 count=1 2>/dev/null | od -An -tu1)
    printf '%s ' $b >> rawlog.txt
done
RAWPROBE
python3 "$DRIVER" --out "$WORK/rawprobe.out" --timeout 15 \
    -k '1.0:\r' -k '0.5:\x03' -k '0.5:q' -- bash rawprobe.sh || true
check "dd sees Enter as byte 13 (\\r survives: ICRNL really is off for dd)" \
      "13 3 113" "$(cat rawlog.txt 2>/dev/null | tr -s ' ' | sed 's/^ //;s/ $//')"
note "same stty line, same pty: dd got the raw 13 and a harmless byte 3;"
note "bash's read got a translated newline and a fatal SIGINT. The pager's"
note "Enter key and its Ctrl-C behavior are bash's doing, not stty's."

# ── verdict ───────────────────────────────────────────────────────────────────
echo
echo "----------------------------------------------------------------"
TOTAL=$((PASSED+FAILED))
_verdict_printed=1
if [ "$FAILED" -eq 0 ]; then
    echo "PASS: all $TOTAL checks hold (ddpager's features verified through a real"
    echo "      pty; the dd trick and the raw-mode illusion both reproduce)"
    exit 0
else
    echo "FAIL: $FAILED of $TOTAL checks failed"
    exit 1
fi
