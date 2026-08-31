#!/usr/bin/env bash
# check-spec-paths.sh — no tracked spec may name one machine's filesystem.
#
# WHY (TODO 15.10). TOML has no shell expansion, so a spec needing an ABSOLUTE path wrote
# one in. That is a cached fact about a machine, in a tracked file, and it was wrong twice
# before anything looked:
#
#   * examples/zfsbootmenu-boot-environments/zbm-debian.toml named /home/user/mklab/… —
#     absolute, and NOBODY's home directory on any machine — from the day it was written
#     (TODO 15.7). Nothing noticed because the only question ever asked of that path was
#     whether it began with a slash.
#   * nineteen more named THIS checkout, /media/sqs/COLD_STORAGE/LAB_CREATE_V2/…, which is
#     false everywhere else. CI proved it on a lab built the same day: its checkout is
#     /home/runner/work/mklab/mklab.
#
# AND A CHECKER THAT ONLY COMPARES IS NOT THE FIX, which is the part worth keeping. The
# first attempt at 15.10's sibling derived the correct path and refused a mismatch — a real
# improvement, and still wrong, because a value that is false everywhere except one machine
# is not rescued by checking it. So the drivers expand @LAB_DIR@ / @REPO@ / @NETBOOT@ at
# parse time, the specs carry placeholders, and THIS checker exists to keep it that way.
#
# WHAT IT GATES, and what it only counts:
#
#   FAIL   a phase-2 path field (image/kernel/initrd/pxe_dir) holding an absolute path
#          under a home or a checkout. lab-vm.sh expands placeholders, so there is no
#          reason left to write one.
#   COUNT  `volumes` entries doing the same. phase3/4/5 do NOT expand yet, so the hand-edit
#          instruction in those files is still TRUE and failing them would be punishing a
#          document for being honest. They are named and counted every run instead of being
#          quietly excluded — see TODO 15.11.
#   PASS   /var/lib/... and other system paths: the same on every machine, and correct.
#
# Own verdict helpers on purpose: it must not source a suite's lib.sh.
set -uo pipefail

REPO="${REPO:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$REPO" || { echo "FAIL: cannot cd to repo root" >&2; exit 1; }

_V=0
pass() { _V=1; printf 'PASS: %s\n' "$*" >&2; exit 0; }
fail() { _V=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
note() { printf '  - %s\n' "$*" >&2; }
WORK=""
_on_exit() {
    local rc=$?
    [[ -n "$WORK" ]] && rm -rf -- "$WORK"
    if (( rc != 0 && rc != 77 )) && (( _V == 0 )); then
        printf 'FAIL: check-spec-paths.sh exited early (rc=%d) — no verdict printed\n' "$rc" >&2
    fi
}
trap _on_exit EXIT
WORK="$(mktemp -d)"

# WHICH absolute paths are machine-specific? The first draft answered by listing the
# machine-specific ones — /home/…, /root, /Users/…, and a pattern for a checkout under
# /media. Its own control caught it immediately: `/media/sqs/COLD_STORAGE/LAB_CREATE_V2/`
# did not match, because the checkout directory has a digit in it and the pattern said
# `[A-Z_]+`. That is not a typo to patch — enumerating machine-specific prefixes means
# encoding THIS machine into the checker that exists to stop specs encoding this machine.
#
# So it is inverted: match ANY absolute path in a path field, then subtract a closed
# allowlist of roots that are the same everywhere. A new kind of home directory, a
# checkout under /srv/work, an NFS mount — all caught without anybody teaching it a new
# prefix. And when the allowlist is wrong it FAILS LOUD (a false positive somebody must
# look at), where the first shape failed silent.
SYS_ROOTS='"/(var|usr|etc|opt|srv|tmp|dev|proc|sys|boot|run|lib|bin|sbin)/'
P2_FIELDS='(image|kernel|initrd|pxe_dir)'

scan_p2() {
    grep -nE "^[[:space:]]*${P2_FIELDS}[[:space:]]*=[[:space:]]*\"/" "$@" 2>/dev/null \
        | grep -vE "$SYS_ROOTS" || true
}

# ── §0. THE SCANNER PROVES ITSELF ON FIXTURES FIRST ─────────────────────────────────────
# A scan that matches nothing and a scan that is broken print the same green tick. Both
# directions are fixtured: the shapes that MUST be caught, and the ones that must not —
# because over-firing here would push somebody to write an exemption, and an exemption list
# is how the original 19 would have survived.
c_ok=0; c_bad=0
must_catch() {  # <label> <line>
    printf '%s\n' "$2" > "$WORK/f.toml"
    if [[ -n "$(scan_p2 "$WORK/f.toml")" ]]; then c_ok=$((c_ok+1)); else
        c_bad=$((c_bad+1)); printf '  ✗ CONTROL MISSED: %s\n' "$1" >&2; fi
}
must_not() {    # <label> <line>
    printf '%s\n' "$2" > "$WORK/f.toml"
    if [[ -z "$(scan_p2 "$WORK/f.toml")" ]]; then c_ok=$((c_ok+1)); else
        c_bad=$((c_bad+1)); printf '  ✗ CONTROL FALSE POSITIVE: %s\n' "$1" >&2; fi
}
must_catch "a home directory"            'image = "/home/sqs/netboot/ipxe.qcow2"'
must_catch "a home directory belonging to NOBODY (the 15.7 defect)" 'image = "/home/user/mklab/examples/x/out/d.qcow2"'
must_catch "this checkout"               'kernel  = "/media/sqs/COLD_STORAGE/LAB_CREATE_V2/micro-linux/out/x86_64/kernel"'
must_catch "the root account home"       'initrd = "/root/netboot/initrd.gz"'
must_catch "a macOS home"                'pxe_dir = "/Users/someone/netboot"'
must_catch "leading whitespace"          '    image = "/home/sqs/x.qcow2"'
must_not   "a placeholder"               'image = "@LAB_DIR@/out/root-on-zfs.qcow2"'
must_not   "the repo placeholder"        'kernel = "@REPO@/micro-linux/out/x86_64/kernel"'
must_not   "the netboot placeholder"     'pxe_dir = "@NETBOOT@"'
must_not   "the home placeholder"        'image = "@HOME@/.local/state/lab-create/x.qcow2"'
must_not   "a system path"               'chroot = "/var/lib/lab-create/chroots/vm-seed"'
must_not   "a container image reference" 'image = "docker.io/library/registry:2"'
must_not   "a distro image name"         'image = "images:debian/13"'
must_not   "a comment mentioning a path" '# image = "/home/sqs/netboot/ipxe.qcow2" is what it used to say'
(( c_bad == 0 )) \
    || fail "§0: $c_bad of $((c_ok + c_bad)) scanner controls behaved wrongly — nothing below means anything"
note "§0: $c_ok fixtures behaved (6 must-catch, 8 must-not-catch)"

# ── §1. the tracked specs ───────────────────────────────────────────────────────────────
mapfile -t SPECS < <(git ls-files '*.toml')
(( ${#SPECS[@]} > 20 )) \
    || fail "only ${#SPECS[@]} tracked .toml files found — the enumeration collapsed, and a scan over almost nothing reads exactly like a clean pass"

hits="$(scan_p2 "${SPECS[@]}")"
if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" | while IFS= read -r h; do note "$h"; done
    fail "$(printf '%s\n' "$hits" | grep -c .) phase-2 path field(s) name one machine's filesystem.
  lab-vm.sh expands @LAB_DIR@ (this file's directory), @REPO@ (the repo root) and
  @NETBOOT@ (\$LAB_NETBOOT_DIR, or ~/netboot) when it parses a spec — so an absolute path
  here is a value that is false on every machine but one, and no amount of checking
  rescues it. Use a placeholder."
fi
note "phase-2 path fields: ${#SPECS[@]} specs scanned, none names a home or a checkout"

# ── §2. volumes, now GATED rather than counted (TODO 15.11) ─────────────────────────────
# This section used to only COUNT these, because phase3/4/5 could not express them as
# placeholders and failing a document for being honest would have been punishing the wrong
# thing. All four drivers now carry a byte-identical _expand_spec_paths (bound by
# check-driver-helper-parity.sh), so the reason for the exception is gone and the exception
# goes with it.
vol="$(grep -nE '^[[:space:]]*(volumes[[:space:]]*=[[:space:]]*\[?|[[:space:]]*)"/' "${SPECS[@]}" 2>/dev/null \
        | grep -E '"/[^"]+:' | grep -vE "$SYS_ROOTS" || true)"
n_vol="$(printf '%s' "$vol" | grep -c . || true)"
if (( n_vol > 0 )); then
    printf '%s\n' "$vol" | while IFS= read -r v; do note "$v"; done
    fail "$n_vol volume path(s) name one machine's filesystem.
  Every driver that reads a volumes list — phase3/4/5 — now expands @LAB_DIR@, @REPO@,
  @NETBOOT@ and @HOME@ when it parses the spec, so an absolute host path here is a value
  that is false on every machine but one."
fi
note "volumes: none names a home or a checkout either"

pass "no tracked spec writes one machine's filesystem into a phase-2 path field: ${#SPECS[@]} specs scanned, $c_ok scanner controls fired first, and volumes are gated the same way now that all four drivers expand the placeholders (TODO 15.11 — the exception went when its reason did)"
