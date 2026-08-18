#!/usr/bin/env bash
# preserve.sh — MICRO_CLOUD_LAB_PLAN.md §9.5: back up a lab you liked, and be able to
# prove later that what you got back is what you kept.
#
#   ./preserve.sh save --tier portable --out ~/backups/mc podman:micro-cloud/metrics vm:edge
#   ./preserve.sh verify  ~/backups/mc          # re-hash every artifact; three outcomes, not two
#   ./preserve.sh restore ~/backups/mc          # verifies FIRST, then re-imports
#
# ─────────────────────────────────────────────────────────────────────────────
# WHY THERE IS A MANIFEST AT ALL, AND WHY IT IS THE POINT OF THIS SCRIPT.
#
# §9.5 states the requirement in one sentence:
#
#     A backup that cannot tell you what built it is a record that will outlive its
#     subject.
#
# That is this repo's bug class #1 with a tarball wrapped round it. `metal-as-a-service`
# paid for the lesson six times over — a `disk.raw.sha256` describing a re-staged image, a
# `pcrs.expected` captured from a build that no longer existed, a served `vmlinuz` whose
# `file -b` string was IDENTICAL to the kernel that had been rebuilt over it and only the
# sha differed. Every one of them was READABLE. None of them errored. They were merely
# false, and the failure surfaced far downstream wearing someone else's clothes.
#
# So `derivation.toml` is not a nicety attached to the tarball; the tarball is the thing
# the manifest is ABOUT. Every rule below is one of those six incidents:
#
#   * DERIVE, DON'T CACHE.  Digests are computed from the bytes as they are written, in
#     the same pass that writes them. Paths are asked of the driver (`lab-fc.sh inspect`),
#     never assembled from a layout this script believes phase 7 uses.
#
#   * WHEN IT MUST BE CACHED, BIND IT TO ITS SUBJECT AND REFUSE A MISMATCH BY NAME.
#     `verify` prints the unit, the file, the expected digest and the actual one. A
#     refusal that says "checksum failed" sends you looking; a refusal that names both
#     digests has already told you which half moved.
#
#   * A VERSION STRING IS NOT AN IDENTITY.  Engine versions are recorded because §9.5 asks
#     for them, but what a restore is gated on is the artifact's sha256 — and the DRIVER
#     is recorded by sha256 too, not by a `--version` it does not have.
#
#   * REFUSE BEFORE THE IRREVERSIBLE STEP.  `restore` runs the whole verify pass and exits
#     non-zero before it issues its first import. A gate that fires after the import is
#     not a gate, it is a post-mortem.
#
#   * UNKNOWN IS A VERDICT.  An artifact that cannot be read is not "changed" and it is
#     certainly not "fine". Every digest check here has THREE outcomes — the shape
#     `lab-fc.sh inspect` already uses, and the one `test-unknown-is-not-pass.sh` exists
#     to defend.
#
# ─────────────────────────────────────────────────────────────────────────────
# THE TWO TIERS, AND THE HONEST STATE OF EACH (§9.5's table, measured rather than quoted).
#
#   portable  — the filesystem, back out to a tarball, plus this manifest. Loses running
#               state; keeps reproducibility. Five phases have the verb (`export-tarball`,
#               shipped 2026-08-18 across phases 1–5); Firecracker's portable artifact
#               already IS a file, so it is copied rather than exported — see below.
#
#   fast      — engine-native snapshot. Keeps running state; non-portable, and locked to
#               the engine version that took it.
#
# ── AND A CORRECTION TO §9.5'S OWN TABLE, FOUND WHILE WIRING THIS UP ────────────────────
# §9.5 says the fast tier "preserves running state". For Firecracker's snapshot+memory and
# for a stateful LXD snapshot that is true. For phase 2 it is NOT: `lab-vm.sh snapshot
# create` is a `qemu-img` INTERNAL snapshot and the driver refuses to take one against a
# running VM ("would corrupt a live disk"), so what phase 2's fast tier preserves is DISK
# state at a stopped moment. That is still worth having and it is still non-portable — but
# a reader who took the table at its word would expect to resume a live guest and would not.
# The claim is corrected in §9.5 rather than quietly worked around here, because a doc that
# overstates a capability is the same defect as a manifest that outlives its subject.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHY UNITS ARE NAMED EXPLICITLY INSTEAD OF READ OUT OF ONE SPEC.
#
# §9.1's layout has `micro-cloud.toml` — ONE spec naming every instance — and this script
# would enumerate it. That file does not exist yet (slices 5a–5c built `edge.toml` and the
# Firecracker instances separately), so enumerating it would mean writing a TOML parser
# against a file nobody has written, and testing it against fixtures of my own invention.
# That is a mechanism standing in for an outcome.
#
# So units are given on the command line as `<phase>:<target>`, and `--spec FILE` records
# the spec's own sha256 in the manifest for when there is one to record. When
# `micro-cloud.toml` lands, enumeration is a loop over `lab_tui.topology` — which already
# parses this exact shape and is already tested — not a new parser here.
#
# ─────────────────────────────────────────────────────────────────────────────
# THE ONE PLACE THIS SCRIPT TOUCHES A DRIVER'S FILES, AND WHY THAT IS NOT A SECOND OWNER.
#
# Phase 7 has no `export-tarball`, and it should not grow one: a Firecracker instance's
# rootfs is ALREADY the portable artifact — a raw ext4 that `lab-chroot.sh export-rootfs`
# produced and that `lab-fc.sh create` copied in. Preserving it is copying a file.
#
# The path of that file is DERIVED by asking `lab-fc.sh inspect`, never by rebuilding
# phase 7's state layout here. A copy of a layout is a cached fact about someone else's
# code, and it goes stale the first time they move a directory — silently, because a
# missing file reads the same as an instance that was never created.
#
# ─────────────────────────────────────────────────────────────────────────────
# EXIT CODES (the same three-way split `lab_tui.reconcile` uses, for the same reason).
#
#   save     0 every unit preserved · 2 some refused (each named) · 1 nothing preserved
#   verify   0 every artifact matches · 1 at least one CHANGED · 3 at least one UNKNOWN
#   restore  0 restored · 1 refused by the gate, or a restore failed · 2 some units have
#              no import path in this repo yet (each named, with what is missing)
#
set -euo pipefail

LAB_PROG="$(basename "$0")"
SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd -- "$(dirname -- "$SCRIPT_PATH")/../.." && pwd)"
MANIFEST_NAME="derivation.toml"
SCHEMA=1

# ─── output ────────────────────────────────────────────────────────────────
log()  { printf '[%s] %s\n' "$LAB_PROG" "$*" >&2; }
note() { printf '  - %s\n' "$*" >&2; }
die()  { printf '[%s] error: %s\n' "$LAB_PROG" "$*" >&2; exit 1; }

# ─── the capability table ──────────────────────────────────────────────────
#
# WHICH PHASE CAN DO WHICH TIER. This is a cached fact about six other scripts, so it is
# exactly the kind of record §9.5 warns about — and it is therefore GATED rather than
# trusted: `tests/test-preserve-capability-table.sh` probes each driver for the verb and
# fails by name when this table and the drivers disagree, in either direction. Widening a
# driver without widening this table is as much a defect as the reverse; a preserve tool
# that refuses a capability the repo has grown is a record outliving its subject too.
#
# Format: PHASE  DRIVER  PORTABLE_VERB  FAST_VERB  ENGINE_CMD
# A '-' means "this phase has no verb for that tier", and the refusal below names what
# §9.5 says the mechanism WOULD be, so the gap reads as a gap and not as a bug.
PHASES=(chroot vm docker podman lxd fc)

driver_of() {
    case "$1" in
        chroot) printf 'phase1-chroot/lab-chroot.sh' ;;
        vm)     printf 'phase2-qemu-vm/lab-vm.sh' ;;
        docker) printf 'phase3-docker/lab-docker.sh' ;;
        podman) printf 'phase4-podman/lab-podman.sh' ;;
        lxd)    printf 'phase5-lxd/lab-lxd.sh' ;;
        fc)     printf 'phase7-firecracker/lab-fc.sh' ;;
        *)      return 1 ;;
    esac
}

# The engine whose version §9.5 asks us to record. Absent → recorded as UNKNOWN, never
# omitted: a field three phases fill in and a fourth silently drops is worse than absent.
engine_cmd_of() {
    case "$1" in
        chroot) printf 'tar' ;;
        vm)     printf 'qemu-img' ;;
        docker) printf 'docker' ;;
        podman) printf 'podman' ;;
        lxd)    printf 'incus' ;;
        fc)     printf 'firecracker' ;;
    esac
}

# Tier 2. 'export-tarball' for phases 1–5; 'copy' for phase 7 (see the header).
portable_verb_of() {
    case "$1" in
        chroot|vm|docker|podman|lxd) printf 'export-tarball' ;;
        fc)                          printf 'copy' ;;
    esac
}

# Tier 1. Phase 2 (qemu-img, offline) and phase 7 (Firecracker snapshot+memory, LIVE).
# Phase 7 gained its verb on 2026-08-18; before that this row was '-' and the refusal
# below named it as DEFERRED. `tests/test-preserve-capability-table.sh` is what makes that
# a fact rather than a comment — it probes each driver and fails when this table and the
# drivers disagree in EITHER direction, including a table that goes on refusing a tier the
# repo has since grown.
fast_verb_of() {
    case "$1" in
        vm|fc) printf 'snapshot' ;;
        *)     printf '-' ;;
    esac
}

# What §9.5 says the fast tier WOULD use, so a refusal names the missing thing rather than
# just declining. "podman has no snapshot" is unhelpful; "§9.5's mechanism here is `podman
# commit` and lab-podman.sh has no commit verb" is a work item.
fast_mechanism_of() {
    case "$1" in
        chroot) printf 'none — a chroot has no running state to freeze; §9.5 lists no fast-tier mechanism for it' ;;
        docker) printf '`docker commit` — lab-docker.sh has no commit verb' ;;
        podman) printf '`podman commit` — lab-podman.sh has no commit verb' ;;
        lxd)    printf '`incus snapshot` (stateful) — lab-lxd.sh has no snapshot verb' ;;
        fc)     printf 'Firecracker snapshot+memory — lab-fc.sh HAS this verb since 2026-08-18; if you are reading this refusal, the capability table and the driver have drifted apart' ;;
        *)      printf 'unknown' ;;
    esac
}

# ─── small helpers ─────────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

# sha256 of a file, with the exit status of sha256sum as the gate — NOT of a pipeline.
# `sha256sum f | cut -d' ' -f1` reports cut's status, and cut succeeds over an empty
# stream, so a failed hash would read as an empty digest and be written to the manifest
# as one. That is the pipe-masks-exit-status footgun this repo merged a red PR over.
sha256_of() {
    local f="$1" out
    out="$(sha256sum -- "$f")" || return 1
    printf '%s' "${out%% *}"
}

bytes_of() {
    local f="$1" out
    out="$(wc -c < "$f")" || return 1
    printf '%s' "${out// /}"
}

first_line() { local s="$1"; printf '%s' "${s%%$'\n'*}"; }

# A version string is recorded for the record, not for the gate — see the header.
engine_version_of() {
    local phase="$1" cmd; cmd="$(engine_cmd_of "$phase")"
    have "$cmd" || { printf 'UNKNOWN: %s is not on PATH' "$cmd"; return; }
    local out=""
    case "$phase" in
        lxd) out="$("$cmd" version 2>/dev/null || true)" ;;
        *)   out="$("$cmd" --version 2>/dev/null || true)" ;;
    esac
    [[ -n "$out" ]] || { printf 'UNKNOWN: %s gave no version output' "$cmd"; return; }
    first_line "$out"
}

# TOML string values are written with " quotes and nothing here escapes them, so a value
# that could close the quote is REFUSED BY NAME rather than written. A manifest that
# cannot be parsed back is a record that lies by omission, and a path is attacker-adjacent
# input the moment a lab is shared.
toml_safe() {
    local what="$1" v="$2"
    [[ "$v" != *'"'* && "$v" != *'\'* && "$v" != *$'\n'* ]] \
        || die "refusing to write $what to the manifest: it contains a quote, a backslash or a newline (${v})"
    printf '%s' "$v"
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ─── save ──────────────────────────────────────────────────────────────────

# One unit → its artifact rows, appended to the manifest being built.
#
# Every row carries `unit` because a unit may produce more than one file (phase 7 keeps a
# kernel beside its rootfs, and a kernel that does not match its rootfs is a boot that
# fails at init with no explanation).
save_unit_portable() {
    local phase="$1" target="$2" outdir="$3" manifest="$4"
    local driver; driver="$(driver_of "$phase")"
    local driver_abs="$REPO_ROOT/$driver"
    [[ -x "$driver_abs" || -r "$driver_abs" ]] || die "driver not found: $driver_abs"
    local driver_sha; driver_sha="$(sha256_of "$driver_abs")" || die "could not hash the driver: $driver_abs"
    local ev; ev="$(engine_version_of "$phase")"

    if [[ "$phase" == "fc" ]]; then
        save_unit_fc "$phase" "$target" "$outdir" "$manifest" "$driver" "$driver_sha" "$ev"
        return
    fi

    local base; base="$(artifact_base "${phase}-${target}")"
    local file="${base}.tar.gz"
    local out="$outdir/$file"
    log "portable: $phase:$target → $file"
    bash "$driver_abs" export-tarball "$target" --output "$out" >&2 \
        || die "$driver export-tarball failed for '$target' — nothing was written for this unit"
    [[ -s "$out" ]] || die "$driver export-tarball reported success and produced no bytes at $out (that is the liar case: fix it before trusting any of this)"

    emit_artifact "$manifest" \
        "$phase:$target" "$phase" "$target" "$driver" "$driver_sha" \
        "export-tarball" "$file" "$out" "$ev" "filesystem"
}

# Phase 7: derive the paths from the driver, copy the files, hash what was written.
save_unit_fc() {
    local phase="$1" target="$2" outdir="$3" manifest="$4" driver="$5" driver_sha="$6" ev="$7"
    local driver_abs="$REPO_ROOT/$driver" inspect
    inspect="$(bash "$driver_abs" inspect "$target" 2>/dev/null)" \
        || die "lab-fc.sh inspect '$target' failed — this is where the rootfs path comes FROM, so there is nothing to copy"

    # `sed -n 's/^k = "\(.*\)"$/\1/p'` is exactly how lab-fc.sh reads its own manifest.
    local rootfs kernel config
    rootfs="$(printf '%s\n' "$inspect" | sed -n 's/^rootfs = "\(.*\)"$/\1/p')"
    kernel="$(printf '%s\n' "$inspect" | sed -n 's/^kernel = "\(.*\)"$/\1/p')"
    config="$(printf '%s\n' "$inspect" | sed -n 's/^config = "\(.*\)"$/\1/p')"
    [[ -n "$rootfs" ]] || die "lab-fc.sh inspect '$target' named no rootfs — refusing to guess phase 7's layout"

    local base; base="$(artifact_base "${phase}-${target}")"
    local pair
    for pair in "rootfs|$rootfs|${base}.rootfs.ext4" "kernel|$kernel|${base}.vmlinux" "config|$config|${base}.config.toml"; do
        local role="${pair%%|*}" rest="${pair#*|}"
        local src="${rest%%|*}" file="${rest##*|}"
        if [[ -z "$src" ]]; then
            note "$phase:$target has no $role recorded — not copied, and said so rather than skipped silently"
            continue
        fi
        [[ -r "$src" ]] || die "$phase:$target names a $role at $src that cannot be read — a preserve that skips the unreadable produces a backup missing the half you needed"
        log "portable: $phase:$target $role → $file"
        cp -- "$src" "$outdir/$file" || die "copying $role for $phase:$target failed"
        emit_artifact "$manifest" \
            "$phase:$target" "$phase" "$target" "$driver" "$driver_sha" \
            "copy" "$file" "$outdir/$file" "$ev" "$role"
    done
}

# Tier 1. In-place by construction: an engine-native snapshot lives inside the engine, so
# there is no file to hash and the manifest records the HANDLE. `verify` therefore asks
# the engine whether the snapshot is still there — deriving the fact rather than trusting
# a digest of something that legitimately changes as the VM runs.
save_unit_fast() {
    local phase="$1" target="$2" outdir="$3" manifest="$4" snapname="$5"
    local driver; driver="$(driver_of "$phase")"
    local driver_abs="$REPO_ROOT/$driver"
    local driver_sha; driver_sha="$(sha256_of "$driver_abs")" || die "could not hash the driver: $driver_abs"
    local ev; ev="$(engine_version_of "$phase")"

    log "fast: $phase:$target → snapshot '$snapname'"
    bash "$driver_abs" snapshot create "$target" "$snapname" >&2 \
        || die "$driver snapshot create failed for '$target' (a running VM is refused on purpose — stop it first)"

    {
        printf '\n[[artifact]]\n'
        printf 'unit           = "%s"\n'  "$(toml_safe unit "$phase:$target")"
        printf 'phase          = "%s"\n'  "$phase"
        printf 'target         = "%s"\n'  "$(toml_safe target "$target")"
        printf 'role           = "snapshot"\n'
        printf 'driver         = "%s"\n'  "$driver"
        printf 'driver_sha256  = "%s"\n'  "$driver_sha"
        printf 'verb           = "snapshot create"\n'
        printf 'inplace        = true\n'
        printf 'snapshot       = "%s"\n'  "$(toml_safe snapshot "$snapname")"
        printf 'engine_version = "%s"\n'  "$(toml_safe engine_version "$ev")"
    } >> "$manifest"
}

emit_artifact() {   # manifest unit phase target driver driver_sha verb file abspath engine_version role
    local manifest="$1" unit="$2" phase="$3" target="$4" driver="$5" driver_sha="$6"
    local verb="$7" file="$8" abspath="$9" ev="${10}" role="${11}"
    local sha bytes
    sha="$(sha256_of "$abspath")"   || die "could not hash the artifact just written: $abspath"
    bytes="$(bytes_of "$abspath")"  || die "could not size the artifact just written: $abspath"
    {
        printf '\n[[artifact]]\n'
        printf 'unit           = "%s"\n'  "$(toml_safe unit "$unit")"
        printf 'phase          = "%s"\n'  "$phase"
        printf 'target         = "%s"\n'  "$(toml_safe target "$target")"
        printf 'role           = "%s"\n'  "$role"
        printf 'driver         = "%s"\n'  "$driver"
        printf 'driver_sha256  = "%s"\n'  "$driver_sha"
        printf 'verb           = "%s"\n'  "$verb"
        printf 'inplace        = false\n'
        printf 'file           = "%s"\n'  "$(toml_safe file "$file")"
        printf 'sha256         = "%s"\n'  "$sha"
        printf 'bytes          = %s\n'    "$bytes"
        printf 'engine_version = "%s"\n'  "$(toml_safe engine_version "$ev")"
    } >> "$manifest"
    note "sha256 $sha  ($bytes bytes)"
}

sanitize() {
    local s="$1"
    s="${s//\//-}"
    s="$(printf '%s' "$s" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9._-' '-')"
    printf '%s' "$s"
}

# A unit's target can be an absolute path (phase 1 takes `<name|path>`), and sanitising a
# deep path produces a filename that can exceed the 255-byte limit — where the failure is
# a write error halfway through a backup, which is the worst moment to discover it. Long
# names keep the distinctive END plus a short digest of the whole, so two units that share
# a tail still get different files.
artifact_base() {
    local full; full="$(sanitize "$1")"
    (( ${#full} > 72 )) || { printf '%s' "$full"; return; }
    local h; h="$(printf '%s' "$1" | sha256sum)"; h="${h:0:8}"
    printf '%s-%s' "${full: -60}" "$h"
}

cmd_save() {
    local tier="portable" outdir="" spec="" snap_suffix=""
    local -a units=()
    while (( $# )); do
        case "$1" in
            --tier)     tier="${2:?--tier needs portable|fast}"; shift 2 ;;
            --out)      outdir="${2:?--out needs a directory}"; shift 2 ;;
            --spec)     spec="${2:?--spec needs a file}"; shift 2 ;;
            --snapshot) snap_suffix="${2:?--snapshot needs a name}"; shift 2 ;;
            -h|--help)  usage; exit 0 ;;
            -*)         die "unknown option: $1" ;;
            *)          units+=("$1"); shift ;;
        esac
    done
    [[ "$tier" == portable || "$tier" == fast ]] || die "unknown tier: $tier (use portable|fast)"
    (( ${#units[@]} )) || die "usage: $LAB_PROG save [--tier portable|fast] [--out DIR] [--spec FILE] <phase>:<target>..."

    [[ -n "$outdir" ]] || outdir="./preserve-$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p -- "$outdir" || die "cannot create $outdir"
    outdir="$(cd -- "$outdir" && pwd)"
    local manifest="$outdir/$MANIFEST_NAME"
    [[ ! -e "$manifest" ]] \
        || die "$manifest already exists — refusing to append to someone else's derivation (a manifest that describes two saves describes neither)"

    # The header is written FIRST and in full, so a run that dies half way leaves a
    # manifest that is visibly incomplete rather than one that looks finished.
    local tool_sha; tool_sha="$(sha256_of "$SCRIPT_PATH")" || die "could not hash $SCRIPT_PATH"
    local commit dirty="unknown"
    if commit="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null)"; then
        if git -C "$REPO_ROOT" diff --quiet 2>/dev/null && git -C "$REPO_ROOT" diff --cached --quiet 2>/dev/null; then
            dirty="false"
        else
            dirty="true"
        fi
    else
        commit="UNKNOWN: not a git checkout"
    fi

    {
        printf '# %s — written by examples/micro-cloud/preserve.sh (MICRO_CLOUD_LAB_PLAN.md §9.5)\n' "$MANIFEST_NAME"
        printf '#\n'
        printf '# THIS FILE IS A CACHED FACT AND IT IS BOUND TO ITS SUBJECT.  Every `sha256` below was\n'
        printf '# computed from the bytes in this directory as they were written.  `preserve.sh verify`\n'
        printf '# recomputes them and refuses a mismatch BY NAME; `preserve.sh restore` runs that same\n'
        printf '# pass and exits non-zero BEFORE it imports anything.  Editing a digest here to make a\n'
        printf '# restore proceed defeats the only thing this file is for.\n'
        printf '\n[derivation]\n'
        printf 'schema      = %s\n'     "$SCHEMA"
        printf 'created     = "%s"\n'   "$(now_utc)"
        printf 'tier        = "%s"\n'   "$tier"
        printf 'host        = "%s"\n'   "$(toml_safe host "$(uname -srm)")"
        printf 'tool        = "examples/micro-cloud/preserve.sh"\n'
        printf 'tool_sha256 = "%s"\n'   "$tool_sha"
        printf 'repo_commit = "%s"\n'   "$commit"
        printf 'repo_dirty  = "%s"\n'   "$dirty"
    } > "$manifest"

    if [[ -n "$spec" ]]; then
        [[ -r "$spec" ]] || die "--spec: not readable: $spec"
        local spec_sha; spec_sha="$(sha256_of "$spec")" || die "could not hash the spec: $spec"
        {
            printf '\n[spec]\n'
            printf 'path   = "%s"\n' "$(toml_safe spec "$spec")"
            printf 'sha256 = "%s"\n' "$spec_sha"
        } >> "$manifest"
    else
        # Absent is recorded as absent. A [spec] block that is simply missing is
        # ambiguous between "there was none" and "nobody wrote it".
        printf '\n# no [spec] — this save named its units on the command line (see preserve.sh header)\n' >> "$manifest"
    fi

    local -a refused=() done_units=()
    local u phase target
    for u in "${units[@]}"; do
        [[ "$u" == *:* ]] || die "unit '$u' is not <phase>:<target> (phases: ${PHASES[*]})"
        phase="${u%%:*}"; target="${u#*:}"
        driver_of "$phase" >/dev/null || die "unknown phase '$phase' in unit '$u' (phases: ${PHASES[*]})"
        [[ -n "$target" ]] || die "unit '$u' names no target"

        if [[ "$tier" == fast ]]; then
            local fv; fv="$(fast_verb_of "$phase")"
            if [[ "$fv" == "-" ]]; then
                refused+=("$phase:$target — no fast tier: $(fast_mechanism_of "$phase")")
                continue
            fi
            save_unit_fast "$phase" "$target" "$outdir" "$manifest" "${snap_suffix:-preserve-$(date -u +%Y%m%dT%H%M%SZ)}"
        else
            save_unit_portable "$phase" "$target" "$outdir" "$manifest"
        fi
        done_units+=("$phase:$target")
    done

    printf '\n' >&2
    log "manifest: $manifest"
    log "preserved ${#done_units[@]}/${#units[@]} unit(s), tier=$tier"
    if (( ${#refused[@]} )); then
        log "REFUSED ${#refused[@]} — named, not skipped:"
        local r; for r in "${refused[@]}"; do note "$r"; done
        (( ${#done_units[@]} )) || { log "nothing was preserved"; exit 1; }
        exit 2
    fi
    exit 0
}

# ─── verify ────────────────────────────────────────────────────────────────
#
# THREE OUTCOMES PER ARTIFACT, NEVER TWO. "I could not look" is not "it matches".

manifest_path() {
    local arg="$1"
    if [[ -d "$arg" ]]; then printf '%s/%s' "${arg%/}" "$MANIFEST_NAME"
    else printf '%s' "$arg"; fi
}

# Read the [[artifact]] blocks as records. Deliberately a scanner over the exact shape
# this script WRITES rather than a general TOML parser — the file is machine-written and
# `toml_safe` refuses everything that would need real parsing.
each_artifact() {   # each_artifact <manifest> <callback>
    local manifest="$1" cb="$2"
    local unit="" phase="" target="" role="" file="" sha="" inplace="" snapshot="" driver="" line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "[[artifact]]" ]]; then
            [[ -z "$unit" ]] || "$cb" "$unit" "$phase" "$target" "$role" "$file" "$sha" "$inplace" "$snapshot" "$driver"
            unit=""; phase=""; target=""; role=""; file=""; sha=""; inplace=""; snapshot=""; driver=""
            continue
        fi
        [[ "${line#"${line%%[![:space:]]*}"}" != \#* ]] || continue   # a comment is not a field
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"; key="${key// /}"
        val="${line#*=}"; val="${val# }"; val="${val%\"}"; val="${val#\"}"; val="${val%% }"
        case "$key" in
            unit) unit="$val" ;; phase) phase="$val" ;; target) target="$val" ;;
            role) role="$val" ;; file) file="$val" ;; sha256) sha="$val" ;;
            inplace) inplace="$val" ;; snapshot) snapshot="$val" ;; driver) driver="$val" ;;
        esac
    done < "$manifest"
    [[ -z "$unit" ]] || "$cb" "$unit" "$phase" "$target" "$role" "$file" "$sha" "$inplace" "$snapshot" "$driver"
}

V_MATCH=0; V_CHANGED=0; V_UNKNOWN=0
V_DIR=""
_verify_row() {
    local unit="$1" phase="$2" target="$3" role="$4" file="$5" want="$6" inplace="$7" snapshot="$8" driver="$9"

    if [[ "$inplace" == "true" ]]; then
        # Derived, not cached: ask the engine whether the snapshot is still there.
        local driver_abs="$REPO_ROOT/$driver" out
        if [[ ! -r "$driver_abs" ]]; then
            printf '  UNKNOWN  %-34s snapshot %-22s the driver %s is gone; nobody could be asked\n' "$unit" "$snapshot" "$driver"
            (( ++V_UNKNOWN )); return
        fi
        if ! out="$(bash "$driver_abs" snapshot list "$target" 2>&1)"; then
            printf '  UNKNOWN  %-34s snapshot %-22s `snapshot list` failed (VM gone?): %s\n' \
                   "$unit" "$snapshot" "$(first_line "$out")"
            (( ++V_UNKNOWN )); return
        fi
        if grep -qF -- "$snapshot" <<<"$out"; then
            printf '  match    %-34s snapshot %s\n' "$unit" "$snapshot"
            (( ++V_MATCH ))
        else
            printf '  CHANGED  %-34s snapshot %-22s NOT PRESENT in the engine any more\n' "$unit" "$snapshot"
            (( ++V_CHANGED ))
        fi
        return
    fi

    local path="$V_DIR/$file"
    if [[ ! -r "$path" ]]; then
        printf '  UNKNOWN  %-34s %-30s the artifact is gone (%s)\n' "$unit" "$role" "$file"
        (( ++V_UNKNOWN )); return
    fi
    local got
    if ! got="$(sha256_of "$path")"; then
        printf '  UNKNOWN  %-34s %-30s could not be hashed (%s)\n' "$unit" "$role" "$file"
        (( ++V_UNKNOWN )); return
    fi
    if [[ "$got" == "$want" ]]; then
        printf '  match    %-34s %-30s %s\n' "$unit" "$role" "$file"
        (( ++V_MATCH ))
    else
        # REFUSE BY NAME, WITH BOTH DIGESTS. This is the line §9.5 is for.
        printf '  CHANGED  %-34s %-30s %s\n' "$unit" "$role" "$file"
        printf '           expected sha256 %s\n' "$want"
        printf '           actual   sha256 %s\n' "$got"
        (( ++V_CHANGED ))
    fi
}

cmd_verify() {
    local arg="${1:-}"
    [[ -n "$arg" ]] || die "usage: $LAB_PROG verify <DIR|derivation.toml>"
    local manifest; manifest="$(manifest_path "$arg")"
    [[ -r "$manifest" ]] || die "no manifest at $manifest"
    V_DIR="$(cd -- "$(dirname -- "$manifest")" && pwd)"
    V_MATCH=0; V_CHANGED=0; V_UNKNOWN=0

    printf 'verify %s\n' "$manifest"
    each_artifact "$manifest" _verify_row
    local total=$(( V_MATCH + V_CHANGED + V_UNKNOWN ))
    (( total )) || die "the manifest lists no artifacts — a save that preserved nothing is not a backup"
    printf '\n%d/%d match · %d CHANGED · %d UNKNOWN\n' "$V_MATCH" "$total" "$V_CHANGED" "$V_UNKNOWN"

    if (( V_CHANGED )); then
        printf 'REFUSED: %d artifact(s) no longer match the derivation that describes them.\n' "$V_CHANGED"
        return 1
    fi
    if (( V_UNKNOWN )); then
        printf 'INCOMPLETE: %d artifact(s) could not be checked. An unchecked artifact is not a verified one.\n' "$V_UNKNOWN"
        return 3
    fi
    printf 'OK: every artifact matches the derivation.\n'
    return 0
}

# ─── restore ───────────────────────────────────────────────────────────────

R_DIR=""; R_PREFIX=""; R_DRY=0
R_DONE=(); R_NOPATH=(); R_FAILED=(); R_NEXT=()

_restore_row() {
    local unit="$1" phase="$2" target="$3" role="$4" file="$5" inplace="$7" snapshot="$8" driver="$9"
    local driver_abs="$REPO_ROOT/$driver"

    if [[ "$inplace" == "true" ]]; then
        local -a argv=(bash "$driver_abs" snapshot restore "$target" "$snapshot")
        _issue "$unit" "${argv[@]}"
        return
    fi

    # Phase 7 keeps three files per unit; only the rootfs is importable, and the other two
    # are named in the summary rather than passed over in silence.
    case "$phase:$role" in
        fc:*) R_NOPATH+=("$unit ($role → $file) — lab-fc.sh has no import verb; place the file and run \`create --config\` by hand (RUNBOOK-preserve.md)"); return ;;
    esac
    [[ "$role" == "filesystem" ]] || { R_NOPATH+=("$unit ($role) — nothing consumes this role automatically"); return; }

    local tag; tag="$R_PREFIX-$(sanitize "${phase}-${target}")"
    local path="$R_DIR/$file"
    case "$phase" in
        # A RESTORE GIVES YOU BACK AN IMAGE, NOT A RUNNING CONTAINER — and that is a
        # measured fact about tier 2, not a shortcut. The drivers advertise
        # `run --name NEW --tarball FILE` on their way out of `export-tarball`, and it was
        # tried first. Against a real rootless podman it fails, at the last inch:
        #
        #     Error: no command or entrypoint provided, and no CMD or ENTRYPOINT from image
        #
        # `podman export` writes the FILESYSTEM. It does not write the OCI config, so the
        # image `podman import` builds back has no CMD, no ENTRYPOINT, no ENV and no
        # WORKDIR. §9.5 says the portable tier "loses running state"; what it actually
        # loses is running state AND the image's configuration — the filesystem survives
        # the round trip and the INTENT does not.
        #
        # The derivation is the right place for that intent, and it cannot carry it yet:
        # no driver reports a container's argv (`inspect` renders labels, state, userns and
        # network, and no command). Closing that is TODO A.4 — a row in phases 3/4/5's
        # `inspect`, which is where TODO A.3 put the last missing fact rather than having
        # phase 6 reach around the drivers for it.
        #
        # Until then this restores the image and NAMES what it could not restore, because
        # a restore that quietly produced something unstartable would be the liar case.
        docker|podman)
            _issue "$unit" bash "$driver_abs" build --tag "$tag" --backend from-tarball --tarball "$path"
            R_NEXT+=("$unit → image '$tag'.  Start it with a command, because the image has none: $driver run --name NEW --image $tag -- <cmd>") ;;
        lxd)
            _issue "$unit" bash "$driver_abs" build --alias "$tag" --backend from-tarball --tarball "$path"
            R_NEXT+=("$unit → image alias '$tag'.  Start it with: $driver run --name NEW --image $tag") ;;
        vm)
            R_NOPATH+=("$unit — phase 2 has no from-tarball backend: \`create --backend from-chroot\` takes a DIRECTORY and needs root (loop mounts, mkfs, extlinux). Extract $file as root, then point --chroot at it") ;;
        chroot)
            R_NOPATH+=("$unit — lab-chroot.sh has no import verb: it creates from debootstrap/pacstrap, not from a tarball. Extract $file as root into a new tree") ;;
        *)
            R_NOPATH+=("$unit — no import path is known for phase '$phase'") ;;
    esac
}

_issue() {
    local unit="$1"; shift
    if (( R_DRY )); then
        printf '  would issue  %s\n' "$*"
        R_DONE+=("$unit")
        return
    fi
    printf '  issuing      %s\n' "$*"
    if "$@" >&2; then R_DONE+=("$unit"); else R_FAILED+=("$unit — $*"); fi
}

cmd_restore() {
    local arg=""
    R_PREFIX="mklab-restored"; R_DRY=0
    while (( $# )); do
        case "$1" in
            --dry-run)    R_DRY=1; shift ;;
            --tag-prefix) R_PREFIX="${2:?--tag-prefix needs a value}"; shift 2 ;;
            -h|--help)    usage; exit 0 ;;
            -*)           die "unknown option: $1" ;;
            *)            arg="$1"; shift ;;
        esac
    done
    [[ -n "$arg" ]] || die "usage: $LAB_PROG restore [--dry-run] [--tag-prefix P] <DIR|derivation.toml>"
    local manifest; manifest="$(manifest_path "$arg")"
    [[ -r "$manifest" ]] || die "no manifest at $manifest"

    # THE GATE, BEFORE THE IRREVERSIBLE STEP. Not after, and not "warn and continue":
    # importing a filesystem that is not the one the manifest describes is precisely the
    # failure §9.5 exists to prevent, and it is silent on the other side.
    local rc=0
    cmd_verify "$manifest" || rc=$?
    if (( rc != 0 )); then
        printf '\nrestore REFUSED: the verify pass above did not come back clean (rc=%d).\n' "$rc"
        printf 'Nothing has been imported. Fix or re-take the backup — do not edit the digests.\n'
        return 1
    fi
    printf '\n'

    R_DIR="$(cd -- "$(dirname -- "$manifest")" && pwd)"
    R_DONE=(); R_NOPATH=(); R_FAILED=(); R_NEXT=()
    each_artifact "$manifest" _restore_row

    printf '\nrestored %d · no import path %d · failed %d\n' "${#R_DONE[@]}" "${#R_NOPATH[@]}" "${#R_FAILED[@]}"
    local x
    if (( ${#R_NEXT[@]} )); then
        printf 'what came back, and what did NOT (see the header: tier 2 keeps the filesystem, not the image config):\n'
        for x in "${R_NEXT[@]}"; do printf '  - %s\n' "$x"; done
    fi
    if (( ${#R_NOPATH[@]} )); then
        printf 'units this repo cannot yet re-import automatically — named, not skipped:\n'
        for x in "${R_NOPATH[@]}"; do printf '  - %s\n' "$x"; done
    fi
    if (( ${#R_FAILED[@]} )); then
        printf 'FAILED:\n'
        for x in "${R_FAILED[@]}"; do printf '  - %s\n' "$x"; done
        return 1
    fi
    (( ${#R_NOPATH[@]} == 0 )) || return 2
    return 0
}

# ─── capabilities ──────────────────────────────────────────────────────────
#
# The table above, printed. It exists so the table can be CHECKED rather than believed:
# `tests/test-preserve-capability-table.sh` reads these rows and probes each driver for
# the verb, failing by name when the two disagree in either direction. A capability table
# nobody re-derives is the same cached fact §9.5 is about — this one just happens to
# describe six sibling scripts instead of a tarball.
cmd_capabilities() {
    printf '# phase\tdriver\tportable\tfast\tengine\n'
    local p
    for p in "${PHASES[@]}"; do
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$p" "$(driver_of "$p")" "$(portable_verb_of "$p")" "$(fast_verb_of "$p")" "$(engine_cmd_of "$p")"
    done
}

# ─── dispatch ──────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
$LAB_PROG — §9.5 preserve: two tiers and a derivation.

  $LAB_PROG save [--tier portable|fast] [--out DIR] [--spec FILE] [--snapshot NAME] <phase>:<target>...
  $LAB_PROG verify  <DIR|derivation.toml>
  $LAB_PROG restore [--dry-run] [--tag-prefix P] <DIR|derivation.toml>
  $LAB_PROG capabilities                      # which phase can do which tier, as TSV

phases: ${PHASES[*]}

tiers:
  portable   the filesystem back out to a tarball + derivation.toml. Loses running
             state, keeps reproducibility. All six phases (phase 7 by copy — its
             rootfs already IS the portable artifact).
  fast       engine-native snapshot. Keeps state, non-portable. Phase 2 only today;
             every other phase REFUSES BY NAME and says what is missing.

exit codes:
  save     0 all preserved · 2 some refused (named) · 1 nothing preserved
  verify   0 all match · 1 something CHANGED · 3 something UNKNOWN
  restore  0 restored · 1 refused by the gate or an import failed · 2 some units
             have no automatic import path yet (each named)

examples:
  $LAB_PROG save --tier portable --out ~/bk podman:micro-cloud/metrics fc:api1
  $LAB_PROG save --tier fast --snapshot before-upgrade vm:edge
  $LAB_PROG verify ~/bk
  $LAB_PROG restore --dry-run ~/bk
EOF
}

main() {
    local verb="${1:-}"
    [[ -n "$verb" ]] || { usage; exit 2; }
    shift
    case "$verb" in
        save)         cmd_save "$@" ;;
        capabilities) cmd_capabilities ;;
        verify)    cmd_verify "$@" ;;
        restore)   cmd_restore "$@" ;;
        -h|--help|help) usage ;;
        *)         printf 'unknown verb: %s\n\n' "$verb" >&2; usage >&2; exit 2 ;;
    esac
}

main "$@"
