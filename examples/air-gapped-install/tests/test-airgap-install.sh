#!/usr/bin/env bash
# test-airgap-install.sh — a Debian base system really installs from the local signed
# mirror, inside a namespace with no route anywhere, and the four rows that make that
# claim mean something all behave.
#
# WHAT IS ASSERTED IS THE OUTCOME. Not "the driver has a mirror verb", not "the config
# names 127.0.0.1" — the tree on disk afterwards: /bin/bash, /usr/bin/dpkg, an
# /etc/debian_version, and the package count debootstrap unpacked. A driver that printed
# a banner and created an empty directory would satisfy every cheaper check.
#
# AND THE ROWS ARE READ BY NAME, not by exit status. `airgap.sh controls` exits 0 when its
# four graded rows behave — but a version of it that quietly stopped running the rows would
# also exit 0, which is the failure mode this repo has hit more than once. So the summary
# line is required to say that five rows behaved, and the C1/C2/C3 lines are required to
# say they refused on their OWN reason (the network, the signature, the hash) rather than
# merely to have failed.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
set +e                      # every check below captures its own status

DRIVER="$LAB_DIR/airgap.sh"
[[ -x "$DRIVER" ]] || fail "missing the lab driver: $DRIVER"

# ASK THE DRIVER what it needs, rather than keeping a copy of the list here. `require_cmd`
# stops at the FIRST missing command, so a machine short of three things learns about one
# per run — and CI's own hand-written copy of this list was short by one (the Debian
# keyring, which Ubuntu's debootstrap does not depend on), which is how this suite went
# green having checked nothing twice in a row. `preflight` names them all at once.
pre="$("$LAB_DIR/airgap.sh" preflight 2>&1)" || {
    printf '%s\n' "$pre" | sed 's/^/    /' >&2
    skip "this machine does not meet the lab's preconditions (named above) — an UNKNOWN, not a pass"
}

# The mirror is the one step that needs the network. Building it here rather than
# requiring a prior manual step is deliberate: a test whose precondition is "somebody ran
# a command earlier" is a test that skips, and a guard that never runs is an UNKNOWN.
# Captured, not piped. `"$DRIVER" status | grep -q …` reads correctly and is wrong twice
# over: grep -q exits at the first match, SIGPIPEs the still-printing status, and pipefail
# then reports 141 for a pipeline whose grep succeeded. Measured here on 2026-08-30 — the
# sibling test skipped with "no mirror built yet" while the mirror sat on disk. A skip is
# the quiet direction of that bug, which is what makes it worth a comment.
status_out="$("$DRIVER" status 2>/dev/null)"
if ! grep -q '^mirror  *built for' <<<"$status_out"; then
    note "no mirror yet — building it (this is the only step that touches the network)"
    out="$("$DRIVER" mirror 2>&1)"; rc=$?
    if (( rc != 0 )); then
        printf '%s\n' "$out" | sed 's/^/    /' >&2
        skip "could not build the mirror from upstream (rc=$rc) — no network, or an unusable debian-archive-keyring. Nothing below can be checked without it"
    fi
fi

# ── 1. the install ──────────────────────────────────────────────────────────────────────
out="$("$DRIVER" install 2>&1)"; rc=$?
printf '%s\n' "$out" | sed 's/^/    /' >&2
(( rc == 0 )) || fail "the air-gapped install FAILED (rc=$rc) — the local mirror did not serve a complete base system with no route to upstream"

paths_out="$("$DRIVER" paths)" || fail "airgap.sh paths failed, so this test does not know where to look for the tree it just asked the driver to build"
root="$(awk '/^state/ {print $2}' <<<"$paths_out")/rootfs"
[[ -x "$root/bin/bash"     ]] || fail "the install reported success but there is no $root/bin/bash — an empty success is worse than a failure, because it is believed"
[[ -x "$root/usr/bin/dpkg" ]] || fail "the install reported success but there is no $root/usr/bin/dpkg"
[[ -s "$root/etc/debian_version" ]] || fail "no /etc/debian_version in the bootstrapped tree — whatever was unpacked, it is not a Debian base system"
ndeb="$(find "$root/var/cache/apt/archives" -name '*.deb' 2>/dev/null | wc -l)"
(( ndeb > 50 )) || fail "only $ndeb .deb(s) came from the mirror — a base system is ~79, so the mirror served a fragment and the install stopped early without saying so"
note "installed Debian $(cat "$root/etc/debian_version") — $ndeb packages, all from the loopback mirror"

# ── 2. the rows, read by name ───────────────────────────────────────────────────────────
out="$("$DRIVER" controls 2>&1)"; rc=$?
printf '%s\n' "$out" | sed 's/^/    /' >&2
(( rc == 0 )) || fail "airgap.sh controls exited $rc — at least one row that must fail did not, or one that must pass did not. The rows are above"

grep -q 'C0 the air gap itself' <<<"$out" \
    || fail "the controls no longer report C0 — the air gap is the precondition every other row leans on, and a run that stops checking it grades four rows against an unknown"
grep -q 'C1 upstream, from inside the ns *refused on the network' <<<"$out" \
    || fail "C1 did not refuse ON THE NETWORK. A C1 that merely 'failed' is satisfied by 'debootstrap can only run as root' — which is what it printed for a whole draft while proving nothing about isolation"
grep -q "C2 our mirror, Debian's keyring *refused the signature" <<<"$out" \
    || fail "C2 did not refuse ON THE SIGNATURE — so nothing here shows the mirror's signature is checked, and a mirror anyone can rewrite would install just as well"
grep -q 'C3 a corrupted .deb in the tree *refused the bad hash' <<<"$out" \
    || fail "C3 did not refuse ON THE HASH — the per-package hashes would then be decorative"
grep -q 'C4 repaired tree (positive) *passed' <<<"$out" \
    || fail "C4 did not pass — so C3's refusal was leftover state, not the corruption, and C3 proves nothing"
grep -q '5 rows behaved' <<<"$out" \
    || fail "the controls did not report all five rows behaving — a run that silently stopped executing rows still exits 0, which is why the summary line is read and not the status"
note "5 rows: the air gap, three refusals each on its own reason, one success"

pass "a Debian $(cat "$root/etc/debian_version") base system ($ndeb packages) installed from the local signed mirror inside a namespace whose only interface is loopback, and all five control rows behaved — upstream refused on the network, a foreign keyring refused on the signature, a corrupted .deb refused on the hash, and the repaired tree installed again"
