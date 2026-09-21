#!/usr/bin/env bash
# test-dsl-defs-present.sh — every dsl/*.fth, loaded on the hosted firmware, must
# leave EVERY word it defines findable in the dictionary. A headless check: no
# QEMU, the firmware as a plain process (obj-amd64/openbios-unix), one fresh
# process per file.
#
# THE BUG THIS EXISTS FOR IS SILENT. A missing word inside `evaluate` of a Forth
# file does not raise at the prompt — the evaluate stops at that word and every
# definition after it simply is not there. Measured 2026-09-17: `u<=` is not a
# word in this Forth, so `sec-in-image?` aborted pe.fth's compilation mid-file,
# `pe-find` was never defined, and the only symptom was the prompt sitting at
# `3 > ` with junk on the stack. Each smoke track calls only the handful of words
# it happens to use, so a definition NO track calls can rot undefined for as long
# as nobody calls it. This asks the whole question, of every file, on every run:
# after the load, is each `: word` it defines actually in the dictionary — and
# was it put there BY THIS LOAD, not merely found because a dependency or the
# firmware already had a word of that name?
#
# WHY UNIX, AND WHY THAT IS ENOUGH. Forth source is arch-independent; whether a
# definition COMPILES cannot differ across arches unless it names an arch-bound
# primitive, and those files are the ones excluded by name below (the same set
# dict-budget's db_skip carries). The byte-order BEHAVIOUR of the compiled words
# is what varies by arch, and that is what the four-arch smoke tracks
# (tlv-primitives, cpio, pe, fdt, …) grade. So a word's PRESENCE after a load is
# fairly answered on one target — the fast, QEMU-free one — and the abort class
# above is caught here before any of those tracks runs.
#
# WHY NOT dict-budget. That track loads the whole toolkit in ONE process to
# measure it, and the hosted grubfs silently stops mounting after 16 `load`s per
# process (measured 2026-09-18: load 17 comes back a bare `ok`, nothing mounted,
# load-base still holding the previous file). One fresh process per file, loading
# only that file's short dependency chain, stays far under that ceiling — and a
# per-file verdict says WHICH file rotted, which a single combined load cannot.
set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd genisoimage

WORKDIR="${OPENBIOS_WORKDIR:-$HOME/openbios-lab}"
UBIN="$WORKDIR/openbios/obj-amd64/openbios-unix"
UDICT="$WORKDIR/openbios/obj-amd64/openbios-unix.dict"
[[ -x "$UBIN"  ]] || skip "missing $UBIN — run ./build-openbios.sh amd64 first (this is the hosted firmware; a missing build is an UNKNOWN, not a pass)"
[[ -f "$UDICT" ]] || skip "missing $UDICT — run ./build-openbios.sh amd64 first"

DSL="$LAB_DIR/dsl"
[[ -d "$DSL" ]] || fail "no dsl/ directory at $DSL — this test loads the SHIPPED readers, it does not re-implement them"

# ── the dependency map: what each file needs loaded before it ────────────────
# Read from each file's own "Load … first" header (see the files); a file with no
# dependency loads on struct alone or nothing. Encoded here so a fresh process
# loads the SHORTEST chain that lets the file compile — not the whole toolkit,
# which would hit the 16-mount ceiling and defeat the point.
deps_of() {  # deps_of <file> -> space-separated deps in load order (excl. the file)
  case "$1" in
    struct)        echo "" ;;
    contract)      echo "struct" ;;
    elf)           echo "struct" ;;
    elf-conform)   echo "struct contract elf" ;;
    elf32)         echo "struct elf" ;;
    sha256)        echo "struct" ;;
    eventlog)      echo "struct sha256" ;;
    evlog-conform) echo "struct contract sha256 eventlog" ;;
    cbfs)          echo "struct" ;;
    cbfs-conform)  echo "struct contract cbfs" ;;
    cbfs-write)    echo "struct cbfs" ;;
    cbfs-payload)  echo "struct cbfs cbfs-write" ;;
    region)        echo "struct" ;;
    lbregion)      echo "struct region" ;;
    fdt)           echo "struct" ;;
    fdt-read)      echo "struct fdt" ;;
    fdt-conform)   echo "struct contract fdt fdt-read" ;;
    cpio)          echo "struct" ;;
    cpio-edit)     echo "struct cpio" ;;
    pe)            echo "struct" ;;
    pe-edit)       echo "struct pe" ;;
    bootparams)    echo "struct" ;;
    bootparams-edit) echo "struct bootparams" ;;
    optrom)        echo "struct" ;;
    elf-write)     echo "struct elf" ;;
    *)             return 1 ;;
  esac
}

# Not loadable on the hosted target, by name (the same reasons dict-budget skips
# them): lbregion binds patch 58's words, defined only on x86/amd64; optrom names
# config-l@, a PCI bus word the hosted target has no PCI to bind. Loading either
# on unix aborts partway — which this test would then (correctly) report as
# missing definitions, but the abort is a KNOWN arch limit, not a rot, so it is
# an UNKNOWN here and belongs to the QEMU tracks.
unix_cannot() { [[ "$1" == lbregion || "$1" == optrom ]]; }

db_iso() { tr -d '-' <<<"${1^^}"; }   # cbfs-write → CBFSWRITE (same scheme as dict-budget)

# ── the file set is DERIVED, and the map must cover it ───────────────────────
# A dsl file that deps_of() does not know is one this test would skip in silence
# — the coverage gap this repo keeps paying — so an unmapped file is a FAILURE by
# name, the way run-all.sh fails on a test file in no list.
#
# TRACKED files, not every file on disk, when this is a git work tree: a reader
# is part of the lab once it is committed or staged, and an UNTRACKED *.fth is
# work in progress (a parallel session's, say) that is not yet the lab's to
# cover. Scanning raw disk would fail the moment any such scratch file sat in
# dsl/, which is a false alarm, not a coverage gap. In CI the checkout is clean,
# so tracked == on-disk and the guard is unchanged; outside git (a tarball
# install) we fall back to the disk glob.
if git -C "$DSL" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  mapfile -t ALL < <(cd "$DSL" && git ls-files '*.fth' 2>/dev/null | sed 's|\.fth$||' | sort)
  note "file set: $(( ${#ALL[@]} )) git-tracked dsl/*.fth (an untracked WIP reader is not the lab's to cover yet)"
else
  mapfile -t ALL < <(cd "$DSL" && ls ./*.fth 2>/dev/null | sed 's|^\./||; s|\.fth$||' | sort)
  note "file set: $(( ${#ALL[@]} )) dsl/*.fth on disk (not a git work tree)"
fi
(( ${#ALL[@]} > 0 )) || fail "no dsl/*.fth files found under $DSL"
unmapped=()
for f in "${ALL[@]}"; do deps_of "$f" >/dev/null || unmapped+=("$f"); done
(( ${#unmapped[@]} == 0 )) \
  || fail "${#unmapped[@]} dsl file(s) are not in deps_of(), so this test does not load them and their words go unchecked: ${unmapped[*]} — add each with the files it must be loaded on top of (its 'Load … first' header)"

# ── build one ISO: every dsl file + a generated probe file per file + control ─
STAGE="$(mktemp -d)"; TMPDIRS+=("$STAGE")
for f in "${ALL[@]}"; do cp "$DSL/$f.fth" "$STAGE/$(db_iso "$f").FTH"; done

# defs_of <file> — the colon definitions the file makes, one per line. The LAST
# is the canary: present means the file compiled to its end. (Colon defs are the
# clearest "word"; a file that aborts mid-way loses every def after the abort
# regardless of definer, so the tail of this list is what bites.)
defs_of() { grep -oE '^[[:space:]]*:[[:space:]]+[^[:space:]]+' "$DSL/$1.fth" | awk '{print $2}'; }

# mk_probe <out> <name...> — a loadable Forth file that, for each NAME, prints
# PRE=name; if the word exists but sits BELOW the pre-load mark `mk` (a dependency
# or firmware word, so the file's OWN definition never compiled), MISSING=name; if
# it does not exist at all, and nothing if it exists and was made by this load.
# Delivered as a FILE, not typed: a typed `s" name"` echoes the name back and the
# echo is indistinguishable from the verdict (the console-echo trap). Ends on
# PROBE-END so a truncated run is not read as "all present".
mk_probe() {
  local out="$1"; shift
  { for n in "$@"; do
      printf 's" %s" $find if mk @ u< if ." PRE=%s;" cr then else 2drop ." MISSING=%s;" cr then\n' "$n" "$n" "$n"
    done
    printf '." PROBE-END" cr\n'
  } > "$out"
}

PIDX=0
declare -A PROBE   # file -> probe iso name
for f in "${ALL[@]}"; do
  unix_cannot "$f" && continue
  PIDX=$((PIDX+1)); pn="DEF$(printf '%02d' "$PIDX")"
  # `dup` (a firmware word) leads every probe as a live control: it MUST read PRE
  # every run, or the mark is not below the words a load makes and every PRE below
  # is meaningless.
  mapfile -t D < <(defs_of "$f")
  mk_probe "$STAGE/$pn.FTH" dup "${D[@]}"
  PROBE[$f]="$pn"
done

# the abort control, run once: a file with an undefined word between two defs.
# bk-a (before it) must be found; bk-b (after it) must read MISSING — the proof
# that the probe can SEE a definition an aborted load never reached, without which
# every "present" above is unearned.
printf '%s\n' ': bk-a 1 ;' 'zz-undefined-control-word' ': bk-b 2 ;' > "$STAGE/BROKEN.FTH"
mk_probe "$STAGE/DBROKEN.FTH" dup bk-a bk-b

ISO="$STAGE/defs.iso"
genisoimage -quiet -o "$ISO" -V DEFS -r -J "$STAGE" 2>/dev/null || fail "genisoimage failed building $ISO"

# run_unix <load-line...> — a fresh hosted-firmware process with the ISO mounted
# read-only, load-base re-pointed into an arena buffer (nothing is mapped at the
# default 0x4000000 on unix, so `load` would segfault otherwise). CR-stripped.
run_unix() {
  { printf '%s\n' '80000 alloc-mem value dbb' 'dbb (u.) s" load-base" $setenv' "$@" 'bye'
  } | "$UBIN" -f "$ISO" "$UDICT" 2>&1 | tr -d '\r'
}
EV='load-base load-size evaluate'

# ── the control first: break the subject and watch the instrument bite ───────
CO="$(run_unix 'variable mk  here mk !' 'load hd:\BROKEN.FTH' "$EV" 'load hd:\DBROKEN.FTH' "$EV")"
grep -qF 'PROBE-END' <<<"$CO" || fail "the control probe never completed (no PROBE-END) — DBROKEN.FTH did not load, so the instrument is unverified and every result below is unearned"
grep -qE 'MISSING=bk-b;' <<<"$CO" \
  || fail "CONTROL FAILED: bk-b, defined AFTER an undefined word, was not reported MISSING — the probe cannot see a definition an aborted evaluate never reached, so a silently half-compiled file would pass here — the instrument is not attached"
grep -qE '(MISSING|PRE)=bk-a;' <<<"$CO" \
  && fail "CONTROL FAILED: bk-a, defined BEFORE the undefined word, was reported $(grep -aoE '(MISSING|PRE)=bk-a;' <<<"$CO") — the probe cannot find a definition that exists and was made by the load"
grep -qE 'PRE=dup;' <<<"$CO" \
  || fail "CONTROL FAILED: the firmware's own 'dup' was not reported PRE — the mark is not below the words a load makes, so 'made by this load' cannot be told from pre-existing and every PRE verdict is meaningless"
note "control: bk-b after an undefined word → MISSING, bk-a before it → present, firmware dup → PRE — the instrument sees both halves"

# ── every mappable file: load its deps + itself, probe its own definitions ───
checked=0 nfiles=0 skipped=""
for f in "${ALL[@]}"; do
  if unix_cannot "$f"; then skipped+="$f "; continue; fi
  args=()
  for d in $(deps_of "$f"); do args+=("load hd:\\$(db_iso "$d").FTH" "$EV"); done
  args+=('variable mk  here mk !' "load hd:\\$(db_iso "$f").FTH" "$EV" "load hd:\\${PROBE[$f]}.FTH" "$EV")
  O="$(run_unix "${args[@]}")"
  grep -qF 'PROBE-END' <<<"$O" \
    || fail "dsl/$f.fth: the probe did not complete (no PROBE-END) — the file's load or its probe did not run to the end; the firmware said: $(grep -aE 'undefined word|isn.t unique|segmentation' <<<"$O" | head -2 | tr '\n' '|')"
  grep -qE 'PRE=dup;' <<<"$O" \
    || fail "dsl/$f.fth: the per-run control failed — firmware 'dup' not PRE, so this file's PRE/MISSING verdicts are unreliable"
  # `|| true` on each: no match means no missing/no unexpected-pre — the PASS case —
  # and a failed grep under this file's `set -e`/pipefail would otherwise kill the
  # run with no verdict. (Whole-pipeline `|| true`, not `grep … || echo`, so an
  # empty result stays empty rather than gaining a stray line.)
  miss="$( { grep -aoE 'MISSING=[^;]+;' <<<"$O" || true; } | sed 's/MISSING=//; s/;//' | tr '\n' ' ')"
  pre="$( { grep -aoE 'PRE=[^;]+;' <<<"$O" | grep -v '^PRE=dup;' || true; } | sed 's/PRE=//; s/;//' | tr '\n' ' ')"
  [[ -z "$miss" ]] \
    || fail "dsl/$f.fth: $(wc -w <<<"$miss") word(s) it defines are NOT in the dictionary after loading it — the evaluate stopped at an undefined word before reaching them (silent at the prompt): $miss— load the file on unix by hand and watch for a non-'0 > ' prompt after the evaluate"
  [[ -z "$pre" ]] \
    || fail "dsl/$f.fth: $(wc -w <<<"$pre") word(s) it should define resolve ONLY to a pre-existing word below the load mark, so the file's own definition never compiled (its name collides with a dependency or firmware word): $pre"
  n=$(defs_of "$f" | grep -c . || true); checked=$((checked+n)); nfiles=$((nfiles+1))
  note "dsl/$f.fth: all $n colon definitions present and made by this load (deps: $(deps_of "$f" | tr -s ' '))"
done

pass "every dsl reader loads whole on the hosted firmware: all $checked colon definitions across $nfiles files are in the dictionary after their load AND were made BY the load (xt above the pre-load mark, not a pre-existing collision), so the silent mid-file abort that undefined pe-find in 2026-09-17 (a missing word ends an evaluate with no error and the prompt says nothing) is caught by name, per file. Files needing an arch-bound primitive the hosted target lacks are UNKNOWN here and left to the QEMU tracks: ${skipped:-none}. The control fires first every run — a definition after an undefined word reads MISSING, one before it is found, the firmware's own dup reads PRE — so an all-present result cannot come from a probe that checks nothing"
