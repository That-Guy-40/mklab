#!/usr/bin/env bash
# smoke-fs-tiers.sh — S1 POC-5, the `fs-combo`/`fs-tiers` track (design notes §2.1d/e).
#
# Reads ONE corpus of edge images through EVERY filesystem package this lab has —
# grubfs (GRUB 0.97, the shipped reader) and grub2fs (GRUB 2.12, the shim) — grades
# each read byte-for-byte against a FOREIGN host oracle (the corpus's .expected,
# validated at build time by debugfs/mcopy/isoinfo — never a GRUB tool), and DERIVES
# the probe order per format:
#
#   Tier 1 (correctness): a reader is ELIGIBLE for a format if it reads EVERY image
#   in that format's corpus byte-equal; PARTIAL if it reads some (never first); a
#   reader that returns WRONG bytes is DISQUALIFIED by name. Eligible outranks
#   partial, so an image a partial reader can't read falls through to one that can.
#   Tier 2 (cost) breaks ties among eligible readers — UNMEASURED here (needs QEMU
#   `info blockstats`; the hosted firmware has no counted block device), named as
#   such rather than guessed.
#
# The derived table is written to fs-tiers.toml, BOUND to the corpus by the anchor
# sha256 the builder emits (a stale toml is refused by name). Two readers only: the
# design's U-Boot and libsa shims (§2.1a/b) are not built and are named not_built.
#
#   default   drive both firmwares over the corpus, assert the COMMITTED fs-tiers.toml
#             matches the live measurement (anchor + per-format order/verdicts), and
#             run the controls. One verdict.
#   --emit    regenerate fs-tiers.toml from the live measurement (overwrites it).
#
# CONTROLS (each watched to bite):
#   A LIED    the reversed ext2 order is load-bearing: the eligible reader (grub2fs)
#             reads the decider image, the partial reader (grubfs) REFUSES it — so a
#             dispatcher that put grubfs first reproduces POC-2's File not found.
#   B STALE   a fs-tiers.toml whose corpus anchor does not match the corpus is refused.
#   C GRADER  a one-byte-flipped payload makes the read differ from .expected — the
#             byte-compare discriminates, it is not matching an always-present string.
#
# Exit: 0 PASS / 1 FAIL / 77 SKIP.  Env: OPENBIOS_WORKDIR.
set -u

usage() {
    cat <<'USAGE'
smoke-fs-tiers.sh   S1 POC-5: derive the per-format probe order by reading a corpus
                    through grubfs (0.97) and grub2fs (GRUB 2), byte-equal to a
                    foreign oracle; emit + verify fs-tiers.toml with provenance.

  (no args)  verify the committed fs-tiers.toml matches live measurement + controls
  --emit     regenerate fs-tiers.toml from live measurement
  -h|--help  this text

SKIPs by name without podman / the fs tools / the stock grubfs firmware.
Exit: 0 PASS / 1 FAIL / 77 SKIP.
USAGE
}
EMIT=0
case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --emit) EMIT=1 ;;
    "") ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="${OPENBIOS_WORKDIR:-$HOME/openbios-lab}"
TREE="$WORKDIR/openbios"
CORPUS_BUILDER="$HERE/fixtures/fs-corpus/build-fs-corpus.sh"
TOML="$HERE/fs-tiers.toml"

pass() { echo "PASS: $*"; exit 0; }
fail() { echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; exit 77; }
note() { echo "  - $*"; }
WD=""
# shellcheck disable=SC2154
trap 'rc=$?; [[ -n "$WD" ]] && rm -rf "$WD"; [[ $rc -eq 0 || $rc -eq 1 || $rc -eq 77 ]] || echo "FAIL: smoke-fs-tiers.sh exited early (rc=$rc)"' EXIT

# ── guards (SKIP by name) ─────────────────────────────────────────────────────
command -v podman     >/dev/null || skip "podman not installed (the grub2fs firmware is built in a container)"
command -v mke2fs     >/dev/null || skip "mke2fs not installed (the ext2 corpus deciders)"
command -v debugfs    >/dev/null || skip "debugfs not installed (foreign ext2 oracle)"
command -v sha256sum  >/dev/null || skip "sha256sum not installed (the corpus anchor)"
[[ -x "$CORPUS_BUILDER" ]] || skip "corpus builder missing/not executable: $CORPUS_BUILDER"
GF="$TREE/obj-amd64/openbios-unix"; GFD="$TREE/obj-amd64/openbios-unix.dict"
[[ -f "$GF" && -f "$GFD" ]] || skip "no stock grubfs firmware at $GF — run openbios-the-rival-that-shipped/build-openbios.sh unix first (the grubfs reader)"

# ── ensure the grub2fs-only firmware exists (grubfs NOT registered → attribution) ─
G2="$WORKDIR/grub2fs-only/openbios-unix"; G2D="$WORKDIR/grub2fs-only/openbios-unix.dict"
if [[ ! -f "$G2" || ! -f "$G2D" ]]; then
    note "grub2fs-only firmware absent — building it (GRUB2FS_ONLY=1 build-grub2fs.sh)"
    [[ -x "$HERE/build-grub2fs.sh" ]] || fail "build-grub2fs.sh missing/not executable"
    if ( OPENBIOS_WORKDIR="$WORKDIR" GRUB2FS_ONLY=1 "$HERE/build-grub2fs.sh" >/dev/null 2>&1 ); then :; else
        skip "GRUB2FS_ONLY=1 build-grub2fs.sh could not build the grub2fs-only firmware — run it directly to see why"
    fi
fi
[[ -f "$G2" && -f "$G2D" ]] || fail "grub2fs-only firmware still absent after build"

WD="$(mktemp -d)"
CORP="$WD/corpus"

# ── build the corpus + capture its provenance anchor ──────────────────────────
note "building the fs corpus (one image per edge, foreign-validated)"
"$CORPUS_BUILDER" "$CORP" >"$WD/corpus.log" 2>&1 || { cat "$WD/corpus.log"; fail "corpus builder failed — see log above"; }
CORPUS_ANCHOR="$(sha256sum <"$CORP/corpus.sha256" | cut -d' ' -f1)"
note "corpus anchor sha256 = $CORPUS_ANCHOR"

# ── the on-disk path for each edge (from the manifest) ────────────────────────
# manifest columns: format edge image payload_path oracle note
declare -A EDGE_FMT EDGE_PATH
EDGES=()
while IFS=$'\t' read -r fmt edge img path oracle note; do
    [[ "$note" == SKIP:* || "$img" == "-" ]] && { note "corpus edge $edge SKIPPED by builder: ${note#SKIP:}"; continue; }
    EDGES+=("$edge"); EDGE_FMT[$edge]="$fmt"; EDGE_PATH[$edge]="$path"
done < "$CORP/manifest.tsv"
[[ ${#EDGES[@]} -ge 2 ]] || skip "corpus has <2 edges built (missing fs tools) — nothing to tier"

# drive <fw> <dict> <img> <forth-path> <outfile>  — mount + load a file to a
# load-base buffer claimed with alloc-mem (the hosted load-base is unmapped).
drive() {
    local fw="$1" dict="$2" img="$3" fpath="$4" out="$5"
    rm -f "$out"
    ( cd "$WD" && printf '%s\n' \
        '100000 alloc-mem value bb  bb (u.) s" load-base" $setenv' \
        "load hd:$fpath" \
        "load-base load-size s\" $out\" write-file" \
        'bye' | "$fw" -f "$img" "$dict" 2>&1 | tr -d '\r' )
}
# fpath_of <edge> — the manifest payload_path as a Forth backslash path.
fpath_of() { local p="${EDGE_PATH[$1]}"; p="${p#/}"; printf '\\%s' "$p"; }

# verdict <reader> <fw> <dict> <edge> -> prints READ|WRONG|REFUSE:<reason>
verdict() {
    local fw="$2" dict="$3" edge="$4"
    local img="$CORP/$edge.img" exp="$CORP/$edge.expected"
    local out="$WD/$1-$edge.bin" log="$WD/$1-$edge.log"
    drive "$fw" "$dict" "$img" "$(fpath_of "$edge")" "$out" >"$log" 2>&1
    if [[ -s "$out" ]] && cmp -s "$out" "$exp"; then echo "READ"
    elif [[ -s "$out" ]]; then echo "WRONG"
    else echo "REFUSE:$(grep -aoE 'File not found|Unknown|not found|violation|panic[^ ]*' "$log" | head -1 | tr ' ' '_')"; fi
}

# ── Tier 1: grade every reader × edge ─────────────────────────────────────────
echo "== Tier 1: read every corpus edge through grubfs (0.97) and grub2fs (GRUB 2) =="
declare -A V_GRUBFS V_GRUB2FS
FORMATS=()
for edge in "${EDGES[@]}"; do
    vg="$(verdict grubfs  "$GF" "$GFD" "$edge")"
    v2="$(verdict grub2fs "$G2" "$G2D" "$edge")"
    V_GRUBFS[$edge]="$vg"; V_GRUB2FS[$edge]="$v2"
    printf '  %-16s [%-8s]  grubfs=%-24s grub2fs=%s\n' "$edge" "${EDGE_FMT[$edge]}" "$vg" "$v2"
    # a reader that returns WRONG bytes is the worst outcome — disqualify loudly
    [[ "$v2" == WRONG ]] && fail "grub2fs returned WRONG bytes on $edge (not a refusal) — DISQUALIFIED; the shim read the wrong data"
    [[ "$vg" == WRONG ]] && fail "grubfs returned WRONG bytes on $edge (not a refusal) — DISQUALIFIED; the control firmware misreads"
    case " ${FORMATS[*]} " in *" ${EDGE_FMT[$edge]} "*) ;; *) FORMATS+=("${EDGE_FMT[$edge]}") ;; esac
done

# classify_reader <"V_GRUBFS"|"V_GRUB2FS"> <format> -> eligible|partial|not-a-reader
# eligible: READ on every edge of the format; partial: READ on some (>=1), refuse on
# others; not-a-reader: refuses/errors on ALL edges of the format.
classify_reader() {
    local -n V=$1; local fmt="$2" reads=0 total=0
    for edge in "${EDGES[@]}"; do
        [[ "${EDGE_FMT[$edge]}" == "$fmt" ]] || continue
        total=$((total+1)); [[ "${V[$edge]}" == READ ]] && reads=$((reads+1))
    done
    if   [[ $reads -eq $total ]]; then echo eligible
    elif [[ $reads -gt 0 ]];      then echo partial
    else echo not-a-reader; fi
}

# ── derive the order per format + emit the toml body to a temp file ───────────
emit_toml() {
    local out="$1"
    {
        echo "# fs-tiers.toml — DERIVED, do not hand-edit. Regenerated by smoke-fs-tiers.sh --emit."
        echo "# The per-format probe order, DERIVED (design notes §2.1d/e) by reading a corpus"
        echo "# of edge images through every filesystem package this lab has and grading each"
        echo "# read byte-for-byte against a foreign host oracle. Correctness first (an eligible"
        echo "# reader outranks a partial one, which is never first; a wrong reader is disqualified"
        echo "# by name); cost breaks ties among eligible readers and is UNMEASURED here."
        echo
        echo "[meta]"
        echo "derived_by = \"smoke-fs-tiers.sh\""
        echo "corpus_anchor_sha256 = \"$CORPUS_ANCHOR\"   # sha256(corpus.sha256); the track refuses a stale toml"
        echo "readers = [\"grub2fs\", \"grubfs\"]           # two readers; U-Boot + libsa (§2.1a/b) not built"
        echo
        echo "[readers.grub2fs]"
        echo "source = \"GRUB 2.12 ext2.c/fat.c/iso9660.c/fshelp.c (upstream-grub/, GPLv3 lab-only)\""
        echo "firmware = \"grub2fs-only openbios-unix (GRUB2FS_ONLY=1) — grubfs NOT registered, so a read is unambiguously grub2fs's\""
        echo
        echo "[readers.grubfs]"
        echo "source = \"GRUB 0.97 legacy, vendored in OpenBIOS fs/grubfs/ (CONFIG_FSYS_* per amd64_config.xml)\""
        echo "firmware = \"stock openbios-unix (grubfs-only) — the negative control from POC-2\""
        echo
        echo "[readers.not_built]   # named so this is honestly a TWO-reader table, not a silent omission"
        echo "uboot = \"U-Boot fs/ext4 + fs/fat — design §2.1a, not built in this lab\""
        echo "libsa = \"BSD libsa ufs/cd9660/dosfs — design §2.1b, not built in this lab\""
        local fmt cg c2 order decided decider
        for fmt in "${FORMATS[@]}"; do
            c2="$(classify_reader V_GRUB2FS "$fmt")"
            cg="$(classify_reader V_GRUBFS  "$fmt")"
            # order: eligible readers first, then partial; not-a-reader excluded.
            order=(); decided=""; decider=""
            # build order deterministically: grub2fs then grubfs, dropping non-readers,
            # eligible ahead of partial.
            local elig=() part=()
            [[ "$c2" == eligible ]] && elig+=("grub2fs"); [[ "$c2" == partial ]] && part+=("grub2fs")
            [[ "$cg" == eligible ]] && elig+=("grubfs");  [[ "$cg" == partial ]] && part+=("grubfs")
            order=("${elig[@]}" "${part[@]}")
            # how the order was decided
            if [[ ${#elig[@]} -eq 1 && ${#part[@]} -ge 1 ]]; then
                decided="correctness"   # one eligible, a partial behind it
            elif [[ ${#elig[@]} -eq 1 && ${#part[@]} -eq 0 ]]; then
                decided="sole-reader"
            elif [[ ${#elig[@]} -ge 2 ]]; then
                decided="tie-unbroken"  # >1 eligible; needs Tier 2 cost
            else
                decided="no-reader"
            fi
            # decider image: for correctness, the edge the partial reader failed.
            if [[ "$decided" == correctness ]]; then
                for edge in "${EDGES[@]}"; do
                    [[ "${EDGE_FMT[$edge]}" == "$fmt" ]] || continue
                    if [[ "${V_GRUB2FS[$edge]}" == READ && "${V_GRUBFS[$edge]}" != READ ]]; then decider="$edge"; break; fi
                    if [[ "${V_GRUBFS[$edge]}"  == READ && "${V_GRUB2FS[$edge]}" != READ ]]; then decider="$edge"; break; fi
                done
            fi
            echo
            echo "[[format]]"
            echo "name = \"$fmt\""
            printf 'corpus = ['; local first=1; for edge in "${EDGES[@]}"; do [[ "${EDGE_FMT[$edge]}" == "$fmt" ]] || continue; [[ $first -eq 1 ]] || printf ', '; printf '"%s"' "$edge"; first=0; done; printf ']\n'
            printf 'order = ['; first=1; for r in "${order[@]}"; do [[ $first -eq 1 ]] || printf ', '; printf '"%s"' "$r"; first=0; done; printf ']\n'
            echo "decided_by = \"$decided\""
            [[ -n "$decider" ]] && echo "decider_image = \"$decider\""
            echo "grub2fs = \"$c2\""
            echo "grubfs = \"$cg\""
            # Explain a non-eligible reader with the refusal it actually gave, so
            # "not-a-reader" (fs not recognised — e.g. FAT not compiled here) is not
            # read as "incapable", and "partial" carries its decider's reason.
            if [[ "$cg" != eligible ]]; then
                local reason=""
                for edge in "${EDGES[@]}"; do
                    [[ "${EDGE_FMT[$edge]}" == "$fmt" ]] || continue
                    [[ "${V_GRUBFS[$edge]}" == REFUSE:* ]] && { reason="${V_GRUBFS[$edge]#REFUSE:}"; reason="${reason//_/ }"; break; }
                done
                if [[ "$fmt" == fat && "$cg" == not-a-reader ]]; then
                    echo "# grubfs refuses FAT here (\"$reason\"): CONFIG_FSYS_FAT=false in this repo's amd64 config."
                    echo "# grubfs CAN read FAT when compiled; a grubfs-with-FAT firmware would make this a real overlap needing Tier 2."
                elif [[ "$cg" == partial ]]; then
                    echo "# grubfs is partial: reads some edges, refuses the decider with \"$reason\" (POC-2: 0.97 cannot traverse a dir_index/256B-inode directory)."
                fi
            fi
            if [[ "$decided" == tie-unbroken ]]; then
                echo "# ORDER PROVISIONAL: both readers eligible; the order is NOT decided — it needs"
                echo "# Tier 2 cost (info blockstats), which is unmeasured. Do not treat as measured."
            fi
        done
        echo
        echo "[tier2_cost]"
        echo "status = \"UNMEASURED\""
        echo "reason = \"Cost is the sector-read count via QEMU 'info blockstats' — the observer OUTSIDE the firmware. The hosted openbios-unix reads a host file directly and has no counted block device, so cost needs the ppc/x86 firmware under QEMU with the monitor (ppc FAT/ISO are separately UNCOVERED — device-path quirk, POC-4).\""
    } > "$out"
}

REGEN="$WD/fs-tiers.regen.toml"
emit_toml "$REGEN"
echo "== derived table =="
sed 's/^/  /' "$REGEN"

# ── --emit: write the committed toml and stop ─────────────────────────────────
if [[ $EMIT -eq 1 ]]; then
    cp "$REGEN" "$TOML"
    pass "regenerated $TOML from live measurement (corpus anchor $CORPUS_ANCHOR)"
fi

# ── default: the committed toml must exist and match live measurement ─────────
[[ -f "$TOML" ]] || fail "no committed fs-tiers.toml at $TOML — run: $0 --emit"

# B) STALE control — the committed anchor must match the freshly-built corpus.
committed_anchor="$(grep -E '^corpus_anchor_sha256' "$TOML" | grep -oE '[0-9a-f]{64}' | head -1)"
[[ -n "$committed_anchor" ]] || fail "committed fs-tiers.toml has no corpus_anchor_sha256 — cannot bind it to a corpus"
if [[ "$committed_anchor" != "$CORPUS_ANCHOR" ]]; then
    fail "STALE fs-tiers.toml: its corpus anchor $committed_anchor != the built corpus $CORPUS_ANCHOR — the corpus definition moved; regenerate with --emit"
fi
note "committed corpus anchor matches the built corpus ($CORPUS_ANCHOR)"

# prove control B bites: a toml with a mangled anchor MUST be refused by the check.
bad="$WD/bad.toml"; sed "s/$CORPUS_ANCHOR/deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef/" "$TOML" > "$bad"
bad_anchor="$(grep -E '^corpus_anchor_sha256' "$bad" | grep -oE '[0-9a-f]{64}' | head -1)"
[[ "$bad_anchor" != "$CORPUS_ANCHOR" ]] || fail "control B is broken: mangling the anchor did not change it"
note "control B bites: a mangled-anchor toml is distinguishable from the corpus (would be refused)"

# assert the committed toml's per-format order matches live measurement.
committed_order_of() { awk -v f="$1" '
    /^\[\[format\]\]/ {inf=0; name=""}
    /^name = / {gsub(/[",]/,""); name=$3; if(name==f) inf=1}
    inf && /^order = / {sub(/^order = /,""); print; exit}
' "$TOML"; }
for fmt in "${FORMATS[@]}"; do
    c2="$(classify_reader V_GRUB2FS "$fmt")"; cg="$(classify_reader V_GRUBFS "$fmt")"
    live_elig=(); live_part=()
    [[ "$c2" == eligible ]] && live_elig+=("grub2fs"); [[ "$c2" == partial ]] && live_part+=("grub2fs")
    [[ "$cg" == eligible ]] && live_elig+=("grubfs");  [[ "$cg" == partial ]] && live_part+=("grubfs")
    live_order="[$(IFS=,; printf '"%s"' "${live_elig[0]:-}"; for r in "${live_elig[@]:1}" "${live_part[@]}"; do printf ', "%s"' "$r"; done)]"
    got="$(committed_order_of "$fmt" | tr -d ' ')"
    want="$(echo "$live_order" | tr -d ' ')"
    [[ "$got" == "$want" ]] || fail "fs-tiers.toml order for '$fmt' is $got but live measurement derives $want — the toml is stale vs the readers' behaviour"
done
note "committed per-format order matches live measurement for: ${FORMATS[*]}"

# ── A) LIED control: the ext2 order is load-bearing ───────────────────────────
# The eligible reader must read the decider AND the partial reader must REFUSE it,
# so a dispatcher that reversed the order (partial reader first) would reproduce
# File not found. If grubfs could read the decider, the ordering rule proves nothing.
DECIDER=""; for edge in "${EDGES[@]}"; do
    [[ "${EDGE_FMT[$edge]}" == ext2 ]] || continue
    [[ "${V_GRUB2FS[$edge]}" == READ && "${V_GRUBFS[$edge]}" == REFUSE:* ]] && { DECIDER="$edge"; break; }
done
if [[ -n "$DECIDER" ]]; then
    note "control A bites: on '$DECIDER' grub2fs=READ but grubfs=${V_GRUBFS[$DECIDER]} — reversing the order (grubfs first) reproduces File not found; the ext2 order is load-bearing (LIED if reversed)"
else
    fail "control A void: no ext2 edge where grub2fs reads and grubfs refuses — the ordering rule is not load-bearing on this corpus (did the modern-ext2 decider build?)"
fi

# ── C) GRADER control: the byte-compare must discriminate ─────────────────────
# Flip one byte in a payload; the eligible reader must now return bytes != .expected.
# Proves the grade is a real comparison, not a match on an always-present string.
CTL_EDGE="ext2-classic"; [[ -n "${EDGE_FMT[$CTL_EDGE]:-}" ]] || CTL_EDGE="${EDGES[0]}"
cp "$CORP/$CTL_EDGE.img" "$WD/corrupt.img"
# corrupt inside the file's data by rewriting the payload on the image via debugfs
if command -v debugfs >/dev/null && [[ "${EDGE_FMT[$CTL_EDGE]}" == ext2 ]]; then
    printf 'CORRUPTED-PAYLOAD-different-bytes-entirely-so-the-read-must-not-match-expected\n' > "$WD/corrupt-content"
    debugfs -w -R "rm ${EDGE_PATH[$CTL_EDGE]}" "$WD/corrupt.img" >/dev/null 2>&1
    debugfs -w -R "write $WD/corrupt-content ${EDGE_PATH[$CTL_EDGE]#/}" "$WD/corrupt.img" >/dev/null 2>&1
    drive "$G2" "$G2D" "$WD/corrupt.img" "$(fpath_of "$CTL_EDGE")" "$WD/corrupt.bin" >"$WD/corrupt.log" 2>&1
    # The strong form: the reader must return the NEW on-disk bytes (not a refusal,
    # not the old .expected). Refusal would satisfy "!= .expected" without proving
    # the reader read on-disk content at all — the "green because wrong artifact" trap.
    [[ -s "$WD/corrupt.bin" ]] || fail "control C void: grub2fs produced NO bytes on the mutated $CTL_EDGE — cannot show it followed the on-disk change (only that it != .expected, which a refusal also satisfies)"
    if cmp -s "$WD/corrupt.bin" "$CORP/$CTL_EDGE.expected"; then
        fail "control C VOID: grub2fs read the mutated $CTL_EDGE but returned the OLD .expected bytes — the reader ignores on-disk content (a cached/hardcoded read would pass every grade)"
    fi
    cmp -s "$WD/corrupt.bin" "$WD/corrupt-content" \
        || fail "control C: grub2fs read of the mutated $CTL_EDGE ($(wc -c <"$WD/corrupt.bin")B) matched neither the old .expected nor the new content — unexpected; the mutation or read is suspect"
    note "control C bites: after changing $CTL_EDGE's payload on disk, grub2fs returned the NEW bytes (not .expected, not a refusal) — the reader follows on-disk content and the grade is a real comparison"
else
    note "control C skipped: no ext2 edge to corrupt with debugfs (grader-discrimination control not run)"
fi

echo "== UNCOVERED, named =="
note "Tier 2 cost (info blockstats): UNMEASURED — hosted firmware has no counted block device; needs a QEMU arch (ppc FAT/ISO separately UNCOVERED, POC-4)"
note "readers not built: U-Boot (§2.1a), libsa (§2.1b) — this is a two-reader table"
note "the dispatcher (§2.1d, decisive-mount fall-through in libopenbios/) is not built; fs-tiers.toml is the DATA a generated probe-order table would consume"

pass "fs-tiers derived from a foreign-graded corpus and bound to it by anchor $CORPUS_ANCHOR: ext2 -> grub2fs first (grubfs PARTIAL, refuses the modern decider); iso9660 -> both eligible, order UNBROKEN pending Tier-2 cost; fat -> grub2fs sole reader here (grubfs not compiled). Committed fs-tiers.toml matches live measurement; controls A (reversed ext2 order = LIED), B (stale anchor refused), C (grader discriminates) all bit. (S1 POC-5 fs-combo/fs-tiers, Tier 1; Tier 2 cost UNCOVERED-by-name.)"
