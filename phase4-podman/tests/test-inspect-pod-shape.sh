#!/usr/bin/env bash
# `inspect` must read a pod from BOTH podman 4's and podman 5's `pod inspect` shape.
#
# THE DEFECT. `podman pod inspect` returned a JSON **object** through podman 4.x and
# returns a one-element **array** in podman 5.x — matching `podman container inspect`,
# which has always been an array. `cmd_inspect` had one query for each and only the
# container one knew: it opened `.[0] as $c`, while the pod query opened `. as $p`. On
# podman 5 every pod field became null and the first label lookup raised
#
#     jq: error (at <stdin>:80): Cannot index array with string "Labels"
#
# Found 2026-08-06 when GitHub's runner image moved to podman 5: CI went red on a branch
# that touched no phase-4 file at all, while podman 4.9.3 on the author's host went on
# passing. That combination — red on a machine nobody changed, green on the machine that
# runs the tests — is the signature of an environment-shaped bug, and it is worth naming
# because the first instinct is to look at the diff.
#
# WHY THIS TEST EXISTS ALONGSIDE test-inspect-json.sh. That test found it, but only
# because the runner happened to have podman 5 — it exercises whatever `podman` is
# installed, so on a podman-4 host it cannot distinguish the fixed code from the broken
# code. The property is "both shapes are accepted", and a host only ever produces ONE of
# them. So the shapes have to be supplied rather than installed.
#
# HOW. Extract the pod query TEXT OUT OF THE SHIPPED SCRIPT and run it against both
# shapes. That matters: a copy of the query pasted into this file would keep passing after
# the real one regressed — asserting the test's idea of the code rather than the code.
# Needs only jq, so it runs everywhere, including where podman is absent entirely.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_cmd jq python3

tmp="$(mktemp -d)"
on_exit 'rm -rf "$tmp"'

# ── lift the shipped query out of lab-podman.sh ────────────────────────────
python3 - "$LAB_PODMAN" "$tmp/pod.jq" <<'PY'
import sys, pathlib
src, out = sys.argv[1], sys.argv[2]
s = pathlib.Path(src).read_text()
try:
    i = s.index('rendered="$(podman pod inspect')
    j = s.index("        ')", i)
    prog = s[s.index("jq -r --arg qm", i):j]
    prog = prog[prog.index("'") + 1:]
except ValueError:
    sys.exit(0)
pathlib.Path(out).write_text(prog)
# stay quiet on success: the test prints its own progress

PY
[[ -s "$tmp/pod.jq" ]] \
    || fail "could not lift the pod-inspect jq out of $LAB_PODMAN — the surrounding code was reshaped, so this test is no longer checking the shipped query and must be repaired rather than deleted"
grep -q 'schema_version' "$tmp/pod.jq" \
    || fail "the text lifted from $LAB_PODMAN does not look like the pod renderer (no schema_version) — extraction matched the wrong region"
note "lifted the pod-inspect query from the shipped script ($(wc -c < "$tmp/pod.jq") bytes)"

# ── one fixture, two shapes ────────────────────────────────────────────────
cat > "$tmp/obj.json" <<'JSON'
{"Id":"podid1","Name":"lab-demo-pod","State":"Running","Created":"2026-01-01T00:00:00Z",
 "Labels":{"lab-create.lab":"demo","lab-create.pod":"ctf","lab-create.tool":"lab-podman.sh","extra":"keep"},
 "Containers":[{"Id":"c1","Name":"lab-demo-a","State":"running"},{"Id":"c2","Name":"lab-demo-b","State":"exited"}],
 "InfraContainerID":"infra1","CgroupPath":"/machine.slice"}
JSON
python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));json.dump([d],open(sys.argv[2],"w"))' "$tmp/obj.json" "$tmp/arr.json"

render() {  # render <fixture> -> prints the rendered JSON, or fails
    jq -r --arg qm "" --arg qs "" --arg qu "" -f "$tmp/pod.jq" < "$1" 2>"$tmp/err"
}

# ── 1. podman 4's object shape ─────────────────────────────────────────────
o_obj="$(render "$tmp/obj.json")" \
    || fail "the pod query failed on podman 4's OBJECT shape: $(head -1 "$tmp/err")"
# ── 2. podman 5's array shape — the regression ─────────────────────────────
o_arr="$(render "$tmp/arr.json")" \
    || fail "REGRESSION: the pod query failed on podman 5's one-element ARRAY shape: $(head -1 "$tmp/err") — 'podman pod inspect' became an array in podman 5, and 'inspect <lab>/<pod>' is broken on every podman 5 host"

# ── 3. and both must render the SAME pod, not merely exit 0 ────────────────
# Exiting 0 is not enough: `. as $p` on an array yields null for every field and still
# succeeds for a while. Compare the rendered documents.
[[ "$o_obj" == "$o_arr" ]] \
    || fail "REGRESSION: the two shapes rendered DIFFERENT documents — object gave $(jq -c '{name,labels}' <<<"$o_obj"), array gave $(jq -c '{name,labels}' <<<"$o_arr")"
note "both shapes render byte-identical output"

# ── 4. and it is the RIGHT pod, so a null-rendering fix cannot pass ────────
# The control for assertion 3: two identically-empty renders would also compare equal.
for f in name labels.lab pod.id; do
    v="$(jq -r ".$f // \"NULL\"" <<<"$o_arr")"
    [[ "$v" != "NULL" && -n "$v" ]] \
        || fail "the array shape rendered .$f as null — the query 'succeeded' while reading nothing, which is how this defect looked before it reached a label lookup"
done
[[ "$(jq -r .name <<<"$o_arr")" == "lab-demo-pod" ]] || fail "wrong pod name from the array shape"
[[ "$(jq -r .labels.lab <<<"$o_arr")" == "demo" ]]   || fail "wrong lab label from the array shape"
[[ "$(jq -r '.containers|length' <<<"$o_arr")" == "2" ]] || fail "wrong container count from the array shape"
note "the array shape renders the real pod: name, labels and 2 containers"

pass "inspect reads a pod from both podman 4's object and podman 5's array shape, rendering identical output"
