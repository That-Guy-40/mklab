#!/usr/bin/env bash
# Slice 7 / §9.5 tier 2: a running thing → a PORTABLE artifact, and back.
#
# The plan's §9.5 table said docker could already do this — read off Appendix A's
# row *"preserve: docker → portable — `export` verb present"*.  The verb IS
# present; `lab-docker.sh export` emits compose YAML, a topology SPEC.  The
# question was whether the thing can become a portable artifact, and what was
# measured was whether a verb with that name exists: a mechanism check standing in
# for an outcome, which is this repo's signature defect.
#
# So this test does not check that a verb exists.  It writes a marker INTO a
# running container, exports, imports the tarball back as a new container through
# the driver's own `from-tarball` backend, and reads the marker out of the new
# one.  A round trip is the only thing that proves "portable".

set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_docker

LAB="exporttar-$$"
CONFIG="$(mktemp --suffix=.toml)"
TARBALL="$(mktemp -u --suffix=.tar.gz)"
CLONE="roundtrip-$$"
on_exit 'rm -f "$CONFIG" "$TARBALL"; cleanup_lab "$LAB"; docker rm -f "lab-$CLONE" >/dev/null 2>&1 || true; docker image rm -f "lab-from-tarball-$CLONE" >/dev/null 2>&1 || true'

cat > "$CONFIG" <<EOF
[lab]
name = "$LAB"

[[service]]
name    = "web"
engine  = "docker"
image   = "busybox:latest"
command = "sleep 300"
EOF

"$LAB_DOCKER" up --config "$CONFIG" >/dev/null || fail "up failed"
cname="lab-${LAB}-web"
await_line 20 running -- docker inspect -f '{{.State.Status}}' "$cname" \
    || fail "the fixture never came up, so nothing below would mean anything"

# Something that exists ONLY in this container — the thing a backup has to carry.
MARKER="preserved-$$"
docker exec "$cname" sh -c "echo $MARKER > /etc/mklab-marker" \
    || fail "could not write the marker into the container"

# ── export ────────────────────────────────────────────────────────────────────
out="$("$LAB_DOCKER" export-tarball "$LAB/web" --output "$TARBALL" 2>&1)" \
    || fail "export-tarball failed: $out"
grep -q '^PASS: exported' <<<"$out" || fail "no PASS verdict from export-tarball: $out"
[[ -s "$TARBALL" ]] || fail "export-tarball reported success but wrote no bytes"

# The artifact is asserted, not the exit status: an empty archive is a file that
# exists and imports as nothing.
# List ONCE to a file, then ask questions of the file.
#
# `tar tzf … | grep -q PATTERN` looks obvious and is a trap this file hit on its
# first run: `grep -q` exits at the first match, tar gets SIGPIPE, and under
# `set -o pipefail` the pipeline reports 141 — so the assertion failed while the
# marker was sitting in the archive exactly where it belonged. The repo has this
# written down (`grep -q` + pipefail = SIGPIPE) and it still cost a run.
LIST="$(mktemp)"
on_exit 'rm -f "$LIST"'
tar tzf "$TARBALL" > "$LIST" 2>/dev/null || fail "the tarball is not readable as a gzipped tar"
members="$(wc -l < "$LIST")"
(( members > 100 )) || fail "the tarball has only $members members — that is not a root filesystem"
grep -qx 'etc/mklab-marker' "$LIST" \
    || fail "the marker is not IN the tarball, so the export did not capture this container's state"
note "exported $members members, marker present in the archive"

# ── ...and back, through the driver's own consumer ────────────────────────────
"$LAB_DOCKER" run --name "$CLONE" --tarball "$TARBALL" --detach -- sleep 120 >/dev/null \
    || fail "from-tarball run failed — the artifact is not consumable by this driver"
got="$(docker exec "lab-$CLONE" cat /etc/mklab-marker 2>&1)" \
    || fail "could not read the marker back out of the restored container: $got"
[[ "$got" == "$MARKER" ]] \
    || fail "REGRESSION: the round trip lost the container's state — wrote '$MARKER', read back '$got'"
note "round trip: the marker survived export → tarball → import → new container"

# ── refusals ──────────────────────────────────────────────────────────────────
out="$("$LAB_DOCKER" export-tarball "$LAB/nosuch" --output /tmp/never-$$.tar.gz 2>&1)" \
    && fail "export-tarball invented a container that does not exist"
grep -q 'no such container' <<<"$out" || fail "wrong refusal for an absent container: $out"

out="$("$LAB_DOCKER" export-tarball "$LAB/web" --output "$TARBALL" 2>&1)" \
    && fail "export-tarball silently overwrote an existing artifact"
grep -q 'refusing to overwrite' <<<"$out" || fail "wrong refusal for an existing output: $out"
note "refuses an absent container, and refuses to overwrite an existing artifact"

pass "export-tarball produces a portable rootfs tarball that round-trips back into a container with its state intact"
