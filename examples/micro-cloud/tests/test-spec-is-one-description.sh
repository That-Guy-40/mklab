#!/usr/bin/env bash
# Verdict: nothing in micro-cloud.toml is a SECOND description of something described
# elsewhere — and where a copy was unavoidable, it is bound to its source by name.
#
# §9.1 asks for ONE spec, and slice 10 wrote one.  But "one spec" is a claim about the whole
# repo, not about a file: two of the values in micro-cloud.toml exist somewhere else too,
# and a copy nobody compares is precisely the record that outlives its subject.  This repo
# has a table of those (plan §"a record that outlives the thing it describes") and every row
# in it was readable, plausible, and false.
#
# So the two copies are declared, and refused on mismatch BY NAME:
#
#   1. `edge`'s [[vm]] block is a copy of edge.toml's.  edge.toml is slice 5b's artifact —
#      the one that actually booted, took the RESERVED lease, and resolved `api1` by name —
#      and tests/test-edge-on-the-fabric.sh drives it.  Restating it in micro-cloud.toml was
#      the only way to have one file describe the whole lab, so the restatement is checked
#      key by key rather than trusted.
#
#   2. Every `mac` in the spec is a DERIVED value: `fabric.sh mac <name>` and
#      `lab-fc.sh mac <name>` compute it from the instance name by a formula the two share.
#      It is written into the spec because the fabric reserves the DHCP lease against it —
#      and that is exactly what makes a stale one dangerous: a guest whose MAC does not
#      match its reservation takes a DYNAMIC lease instead, boots fine, answers pings, and
#      is simply at the wrong address.  Nothing errors.  So the file is compared against the
#      derivation on every run, which is the plan's own rule: *if it must be cached, bind it
#      to its subject's identity and refuse a mismatch by name.*
set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

need python3
SPEC="$LAB_DIR/micro-cloud.toml"
EDGE="$LAB_DIR/edge.toml"
[[ -r "$SPEC" ]] || fail "the lab's one spec is missing: $SPEC"
[[ -r "$EDGE" ]] || fail "slice 5b's verified spec is missing: $EDGE (the [[vm]] block in micro-cloud.toml is a copy of it, so its source has to be there to compare against)"

# ── 1. the edge block, key by key ────────────────────────────────────────────
diff_out="$(python3 - "$SPEC" "$EDGE" <<'PY'
import sys, tomllib

def load(path):
    with open(path, "rb") as fh:
        return tomllib.load(fh)

spec, edge = load(sys.argv[1]), load(sys.argv[2])
mine = next((v for v in spec.get("vm", []) if v.get("name") == "edge"), None)
theirs = next((v for v in edge.get("vm", []) if v.get("name") == "edge"), None)
if mine is None:
    print("micro-cloud.toml has no [[vm]] named 'edge'"); raise SystemExit(0)
if theirs is None:
    print("edge.toml has no [[vm]] named 'edge'"); raise SystemExit(0)

# `lab` is allowed to differ only by being PRESENT in the one-file spec: edge.toml carries
# it too, so nothing is exempt here.  Every other key must agree exactly.
for key in sorted(set(mine) | set(theirs)):
    a, b = mine.get(key, "<absent>"), theirs.get(key, "<absent>")
    if a != b:
        print(f"{key}: micro-cloud.toml has {a!r}, edge.toml has {b!r}")
PY
)"
[[ -z "$diff_out" ]] || fail "the 'edge' block in micro-cloud.toml has DRIFTED from edge.toml, which is the copy slice 5b actually booted:
$(sed 's/^/    /' <<<"$diff_out")
    Two descriptions of one VM, and only one of them was ever run."
note "the [[vm]] 'edge' block is key-for-key identical to edge.toml's"

# ...and the same comparison, run against a copy with ONE key bent, must object. An
# equality check that has never seen an inequality is not known to be comparing anything.
WORK="$(mktemp -d)"; on_exit 'rm -rf -- "$WORK"'
sed 's/^memory  *= *"1G"/memory = "2G"/' "$EDGE" > "$WORK/edge-bent.toml"
grep -q 'memory = "2G"' "$WORK/edge-bent.toml" \
    || fail "the control fixture did not actually bend a key, so the check below proves nothing"
control_out="$(python3 - "$SPEC" "$WORK/edge-bent.toml" <<'CTRL'
import sys, tomllib
def load(p):
    with open(p, "rb") as fh:
        return tomllib.load(fh)
spec, edge = load(sys.argv[1]), load(sys.argv[2])
mine   = next((v for v in spec.get("vm", []) if v.get("name") == "edge"), None)
theirs = next((v for v in edge.get("vm", []) if v.get("name") == "edge"), None)
for key in sorted(set(mine) | set(theirs)):
    a, b = mine.get(key, "<absent>"), theirs.get(key, "<absent>")
    if a != b:
        print(f"{key}: {a!r} vs {b!r}")
CTRL
)"
[[ -n "$control_out" ]] \
    || fail "CONTROL DID NOT BITE: edge.toml with memory bent to 2G compared EQUAL to micro-cloud.toml's edge block — the key comparison is not looking at the keys"
note "control: bending edge.toml's memory to 2G made the same comparison report a difference"

# ── 2. every mac, against the derivation ─────────────────────────────────────
# ASKED of both tools, not read from a table here: a third copy of the formula in this test
# would drift from the two it is comparing, and would then certify them wrong together.
declared="$(python3 - "$SPEC" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
for block in ("microvm", "vm", "instance"):
    for item in doc.get(block) or []:
        mac = item.get("mac")
        if mac is None:
            dev = (item.get("devices") or {}).get("eth0") or {}
            mac = dev.get("hwaddr")
        if mac:
            print(f"{item['name']}\t{mac}")
PY
)"
[[ -n "$declared" ]] || fail "no instance in the spec declares a mac — the fabric reserves leases against the MAC, so a spec with none cannot get a reserved address for anything"

n=0
while IFS=$'\t' read -r name mac; do
    [[ -n "$name" ]] || continue
    n=$((n+1))
    from_fabric="$("$FABRIC" mac "$name" 2>/dev/null)" || from_fabric="<fabric refused>"
    from_fc="$("$REPO_DIR/phase7-firecracker/lab-fc.sh" mac "$name" 2>/dev/null)" || from_fc="<lab-fc refused>"
    [[ "$mac" == "$from_fabric" ]] \
        || fail "REGRESSION: '$name' declares mac $mac but fabric.sh derives $from_fabric. The fabric reserves the DHCP lease against ITS value, so this guest would miss its reservation, take a dynamic lease, and be at the wrong address while looking perfectly healthy"
    [[ "$from_fabric" == "$from_fc" ]] \
        || fail "REGRESSION: the two tools no longer agree about '$name': fabric.sh says $from_fabric, lab-fc.sh says $from_fc. The formula is shared BY CONTRACT and this is the drift the contract exists to prevent"
done <<<"$declared"
note "$n declared mac(s) match both fabric.sh's and lab-fc.sh's derivation"

# ── 3. the control ───────────────────────────────────────────────────────────
# A comparison that never sees a mismatch is indistinguishable from one that compares
# nothing, so a wrong value is fed to the same derivation check and must be rejected.
bogus_name="$(python3 -c 'print("api1")')"
bogus_mac="06:00:ac:47:00:01"
real_mac="$("$FABRIC" mac "$bogus_name" 2>/dev/null)" || fail "fabric.sh mac refused a name from the spec"
[[ "$real_mac" != "$bogus_mac" ]] \
    || fail "the control is void: the deliberately wrong MAC happens to BE the derived one for '$bogus_name'"
note "control: $bogus_mac is not what fabric.sh derives for $bogus_name ($real_mac), so the comparison above can fail"

# ── 4. the lease path micro-cloud.sh reads is the one fabric.sh writes ───────
# `status` reads the fabric's dnsmasq lease file to report addresses, so it carries a copy
# of a path fabric.sh owns. The first version guessed dnsmasq's distro default
# (/var/lib/misc/…) rather than the `--dhcp-leasefile` the fabric actually passes, which
# would have made `status` report every address as UNKNOWN on every run — a wrong answer
# wearing the clothes of a careful one, since "UNKNOWN" is exactly what it should say when
# the fabric is down. Bound to its source here rather than trusted.
fabric_state="$(sed -n 's/^STATE=\(.*\)$/\1/p' "$FABRIC" | head -1)"
[[ -n "$fabric_state" ]] \
    || fail "could not read a STATE= line out of fabric.sh, so the lease path in micro-cloud.sh cannot be checked against its source — if that variable was renamed, this assertion needs updating with it"
mc_leases="$(sed -n 's/.*MC_LEASES:-\([^}]*\)}.*/\1/p' "$LAB_DIR/micro-cloud.sh" | head -1)"
[[ -n "$mc_leases" ]] \
    || fail "could not read the lease path out of micro-cloud.sh (expected an \${MC_LEASES:-…} default)"
[[ "$mc_leases" == "$fabric_state/leases" ]] \
    || fail "REGRESSION: micro-cloud.sh reads leases from '$mc_leases' but fabric.sh writes them under '$fabric_state'. 'status' would report every instance's address as UNKNOWN while the fabric was serving them perfectly well"
note "the lease path micro-cloud.sh reads ($mc_leases) is the one fabric.sh writes"

pass "micro-cloud.toml restates edge.toml exactly, every MAC still matches what both tools derive, and status reads the lease file the fabric actually writes"
