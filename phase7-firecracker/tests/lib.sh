#!/usr/bin/env bash
# Shared helpers for phase7-firecracker tests. Same skip/fail/pass/note contract as
# Phase 3/4/5's lib.sh, retargeted at lab-fc.sh.
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR
readonly LAB_FC="${TEST_DIR}/../lab-fc.sh"

# _VERDICT guards the EXIT net below: a test that already said FAIL must not also be told
# "no verdict was printed", or the net becomes noise a reader learns to skip past.
_VERDICT=0
skip()  { _VERDICT=1; printf 'SKIP: %s\n' "$*" >&2; exit 77; }
fail()  { _VERDICT=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass()  { _VERDICT=1; printf 'PASS: %s\n' "$*" >&2; exit 0; }
note()  { printf '  - %s\n' "$*" >&2; }

require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || skip "missing required command: $c"
    done
}

# Belt-and-suspenders: a `die` inside lab-fc.sh is an exit, and an unguarded one would
# otherwise end a test with a bare rc and NO verdict line. Real incident in phases 1-5.
#
# CLEANUP GOES THROUGH THIS TRAP, NEVER A SECOND `trap ... EXIT`. Bash keeps ONE EXIT trap
# per shell, so a test writing `trap 'rm -rf "$tmp"' EXIT` silently REPLACES this net and
# the verdict line disappears. Found 2026-08-02: all four tests here did exactly that, and
# an injected fault produced a python traceback, rc=1, and no FAIL: line — the safety net
# was present and inert. Register scratch dirs instead:
#     tmp="$(mktemp -d)"; TMPDIRS+=("$tmp")
# TMPDIRS covers scratch directories; on_exit covers any other teardown, which is what
# a test would otherwise reach for a second `trap … EXIT` to do.
TMPDIRS=()
_CLEANUPS=()
on_exit() { _CLEANUPS+=("$*"); }
_on_exit() {
    local rc=$? i
    # Registered cleanup can READ the exit status as $_EXIT_RC. Without it a teardown
    # that needs to know whether the run failed — keep the evidence, skip the tidy-up —
    # has to write its own `trap … EXIT`, which is the defect this block exists to stop.
    _EXIT_RC=$rc
    for (( i=${#_CLEANUPS[@]}-1; i>=0; i-- )); do eval "${_CLEANUPS[i]}" || true; done
    local d; for d in ${TMPDIRS+"${TMPDIRS[@]}"}; do [[ -n "$d" ]] && rm -rf "$d"; done
    if (( rc != 0 && rc != 77 )) && (( _VERDICT == 0 )); then
        printf 'FAIL: test exited early (rc=%d) — no verdict was printed by the test itself\n' "$rc" >&2
    fi
}
trap _on_exit EXIT

# A microVM spec that is valid in shape. Callers append or override keys.
# Uses paths that do not need to exist: gates about FILES are expected to fail here, and
# the tests below assert on SPECIFIC gate lines rather than on the overall exit status.
mkspec() {  # mkspec <file> [extra lines...]
    local f="$1"; shift
    {
        printf '[lab]\nname = "t"\n\n[[microvm]]\n'
        printf 'name = "t1"\nkernel = "/nonexistent/vmlinux"\nrootfs = "/nonexistent/rootfs.ext4"\n'
        local l; for l in "$@"; do printf '%s\n' "$l"; done
    } > "$f"
}

# ── fixtures: what these tests actually need, which is NOT a virtual machine ──────────
#
# REVIEW-phase7.md §3b. `test-config-generation.sh` and `test-rootfs-is-per-instance.sh`
# opened with `require_cmd firecracker` + `/dev/kvm` + two env vars naming artifacts the
# caller had to supply. Nobody supplied them: they skipped on this host AND on every CI
# run since the phase was written, so the only test that ever parses a generated config,
# and the only one that exercises `create`'s write path, had never run anywhere. Neither
# would have caught P7-2 on its own (a benign spec emits valid JSON either way) — the cost
# was subtler and worse: two of six tests were inert, so the phase's real coverage was
# 4/6 while every summary line said "0 failed".
#
# The precondition was itself the defect, which is the usual finding. NEITHER TEST BOOTS
# ANYTHING: one runs `create --dry-run` and parses stdout, the other runs `create` and
# reads three files. They required a VMM because `preflight`'s version gate does — a gate
# about the HOST, standing in for artifacts about the SPEC.
#
# So the fixtures are built here:
#   * kernel — any ELF satisfies the generator's gate; the system `bash` is one.
#   * rootfs — a real ext4 with a real /sbin/init, via `mke2fs -d` (no root, no loop mount).
#   * firecracker — the REAL one at the pinned version when it is installed (still the best
#     evidence); otherwise a stand-in on PATH that answers `--version` and nothing else.
#
# WHAT THE STAND-IN DOES NOT PROVE, said out loud: that Firecracker accepts the config, or
# that the microVM boots. Those need a VMM and are covered by
# `examples/micro-cloud/tests/test-edge-on-the-fabric.sh`, which boots api1 through this
# tool for real. What these tests ask — *is the generated document well-formed, and does
# the record describe the file the VM would boot* — is answerable without one, and was
# never asked because it was bundled with a question that was not.
fc_fixtures() {   # sets FC_K, FC_R, and prepends a stand-in firecracker to PATH if needed
    require_cmd file sha256sum python3
    [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] \
        || skip "/dev/kvm is not read-write for uid $EUID — preflight's KVM gate refuses, so \`create\` cannot complete (this is the one precondition left; add yourself to the kvm group)"

    local d="${TMPDIRS[${#TMPDIRS[@]}-1]:-}"
    [[ -n "$d" && -d "$d" ]] || { d="$(mktemp -d)"; TMPDIRS+=("$d"); }

    # A caller-supplied pair still wins: real artifacts are better evidence than built ones.
    FC_K="${FC_TEST_KERNEL:-}"; FC_R="${FC_TEST_ROOTFS:-}"
    if [[ ! -r "$FC_K" ]]; then
        FC_K="$d/vmlinux-fixture"
        cp -- "$(command -v bash)" "$FC_K" || skip "could not build an ELF kernel fixture"
        [[ "$(file -b "$FC_K")" == *ELF* ]] || skip "the kernel fixture is not ELF — the generator's own gate would refuse it"
    fi
    if [[ ! -r "$FC_R" ]]; then
        command -v mke2fs >/dev/null 2>&1 || skip "mke2fs not installed (e2fsprogs) — cannot build an ext4 rootfs fixture"
        command -v debugfs >/dev/null 2>&1 || skip "debugfs not installed (e2fsprogs) — preflight's /sbin/init gate would report UNKNOWN and \`create\` needs it to pass"
        FC_R="$d/rootfs-fixture.ext4"
        mkdir -p "$d/rfs/sbin" && cp -- /bin/true "$d/rfs/sbin/init" \
            || skip "could not stage a /sbin/init for the rootfs fixture"
        truncate -s 16M "$FC_R" \
            && mke2fs -q -F -t ext4 -d "$d/rfs" "$FC_R" >/dev/null 2>&1 \
            || skip "mke2fs could not build the rootfs fixture"
    fi

    # The real VMM at the pinned version, or a stand-in that is honest about being one.
    FC_STANDIN=0
    local want; want="$(sed -n 's/^readonly FC_PINNED_VERSION="\${FC_PINNED_VERSION:-\(v[0-9.]*\)}"$/\1/p' "$LAB_FC")"
    if ! command -v firecracker >/dev/null 2>&1 \
       || [[ "$(firecracker --version 2>&1 | head -1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || true)" != "$want" ]]; then
        mkdir -p "$d/shim"
        cat > "$d/shim/firecracker" <<SHIM
#!/usr/bin/env bash
# STAND-IN, not Firecracker. It answers the version gate and nothing else.
[[ "\$1" == "--version" ]] && { printf 'Firecracker %s\n' '$want'; exit 0; }
printf 'stand-in firecracker: refusing to pretend to boot\n' >&2
exit 70
SHIM
        chmod +x "$d/shim/firecracker"
        PATH="$d/shim:$PATH"; export PATH
        FC_STANDIN=1
        note "no firecracker $want on PATH — using a stand-in for the VERSION GATE only; nothing here boots a VM either way"
    fi
}

# Run lab-fc.sh and capture combined output WITHOUT letting a pipe decide the exit status.
run_fc() {  # run_fc <outfile> <args...>
    local out="$1"; shift
    set +e
    bash "$LAB_FC" "$@" > "$out" 2>&1
    local rc=$?
    set -e
    return "$rc"
}
