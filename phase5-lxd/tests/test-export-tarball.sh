#!/usr/bin/env bash
# Slice 7 / §9.5 tier 2 for LXD — the sibling of phase 3's and phase 4's
# test-export-tarball.sh.
#
# Same correction behind it: the plan's §9.5 table claimed LXD could already do
# this, read off Appendix A's "`export` verb present". It is present, and it emits
# lxc-yaml/compose — a topology SPEC. `export-tarball` produces the artifact the
# other phases can consume: a bare rootfs tarball.
#
# WHAT RUNS HERE AND WHAT DOES NOT. The refusal and resolution paths are read-only
# (`list`), create nothing, and run anywhere an engine answers. The round trip —
# launch, write a marker, export, import, read it back — is gated behind
# LAB_LXD_LIVE=1, because this development host runs a live Calico cluster and
# launching an instance manufactures the Appendix F.6 bridge-capture hazard. That
# half is an UNKNOWN on this host and says so; phases 3 and 4 ran their full round
# trips, marker and all.

set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd jq
require_lxd_or_incus

LAB="exporttar-$$"

out="$("$LAB_LXD" export-tarball "$LAB/nosuch" --output /tmp/never-$$.tar.gz 2>&1)" \
    && fail "export-tarball invented an instance that does not exist"
grep -q 'no such instance' <<<"$out" || fail "wrong refusal for an absent instance: $out"
grep -q "lab-${LAB}-nosuch" <<<"$out" \
    || fail "the lab/service target did not resolve to lab-<lab>-<svc>: $out"
note "refuses an absent instance, and names what it looked for"

out="$("$LAB_LXD" export-tarball 2>&1)" && fail "export-tarball with no target should refuse"
grep -q 'usage:' <<<"$out" || fail "no usage line for a missing target: $out"

[[ "${LAB_LXD_LIVE:-}" == "1" ]] || skip "the export round trip needs LAB_LXD_LIVE=1 — this host runs a live Calico cluster and creating an instance manufactures the bridge-capture hazard of Appendix F.6; the refusal and resolution paths above DID run"

CONFIG="$(mktemp --suffix=.toml)"
TARBALL="$(mktemp -u --suffix=.tar.gz)"
on_exit 'rm -f "$CONFIG" "$TARBALL"; cleanup_lab "$LAB"'
cat > "$CONFIG" <<EOF
[lab]
name = "$LAB"

[[instance]]
name   = "web"
engine = "lxd"
image  = "images:alpine/edge"
EOF

iname="lab-${LAB}-web"
"$LAB_LXD" up --config "$CONFIG" >/dev/null || fail "up failed"

MARKER="preserved-$$"
"$LXC_CMD" exec "$iname" -- sh -c "echo $MARKER > /etc/mklab-marker" \
    || fail "could not write the marker into the instance"

out="$("$LAB_LXD" export-tarball "$LAB/web" --output "$TARBALL" 2>&1)" \
    || fail "export-tarball failed: $out"
grep -q '^PASS: exported' <<<"$out" || fail "no PASS verdict: $out"

# List once to a file: `tar tzf | grep -q` sends SIGPIPE to tar and fails the
# assertion over a good archive under pipefail (it cost phase 4's version a run).
LIST="$(mktemp)"; on_exit 'rm -f "$LIST"'
tar tzf "$TARBALL" > "$LIST" 2>/dev/null || fail "the tarball is not readable as a gzipped tar"
(( "$(wc -l < "$LIST")" > 100 )) || fail "that is not a root filesystem"
grep -qx './etc/mklab-marker' "$LIST" || grep -qx 'etc/mklab-marker' "$LIST" \
    || fail "the marker is not IN the tarball, so the export did not capture this instance's state"
note "exported with the marker present in the archive"

pass "export-tarball produces a portable rootfs tarball carrying the instance's own state"
