#!/usr/bin/env bash
# Verdict: a node whose BMC port is answered by a DIFFERENT machine is refused up front.
#
# THE INCIDENT. VirtualBMC lets two domains register on one port. Only one binds; the
# loser sits in `error`; the winner answers IPMI for both. The sibling lab's own
# `alpine-node` defaults to port 6230 — which is also node1's — so for two consecutive
# end-to-end runs every command the control plane issued for node1 was served by
# alpine-node:
#
#     manage node1        -> "manageable node1 (BMC creds verified)"
#     power node1 status  -> "Chassis Power is on"          (alpine-node was)
#     bootdev pxe         -> "Set Boot Device to pxe"       (on alpine-node)
#     power on            -> "Chassis Power Control: Up/On" (alpine-node again)
#
# All four succeeded. node1 never powered on, its console stayed empty, and the failure
# surfaced as a health-gate timeout two phases later. On this lab's chaos ladder that is
# LIED — the record and reality disagreed and every check said healthy — and it is
# strictly worse than an unreachable BMC, which fails at once and honestly.
#
# The control plane CANNOT catch this: the BMC seam is the abstraction that hides which
# machine is on the other end. So the check lives in the fleet plumbing, which still
# knows it is talking to vbmcd, and it runs BEFORE enroll.
#
# SAFETY: pure text. Fixture tables on stdin; no vbmcd, no libvirt, no IPMI.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
need python3
CHK="$LAB_DIR/lib/vbmc_check.py"
[[ -f "$CHK" ]] || fail "lib/vbmc_check.py is missing — the fleet has no way to detect a BMC port collision"

# run <fixture> <node:port>... -> sets OUT, returns the checker's rc
run_chk() { local fx="$1"; shift; OUT="$(printf '%s\n' "$fx" | python3 "$CHK" "$@" 2>&1)"; }

HEALTHY='+-------------+---------+---------+------+
| Domain name | Status  | Address | Port |
+-------------+---------+---------+------+
| node1       | running | ::      | 6230 |
| node2       | running | ::      | 6231 |
| node3       | running | ::      | 6232 |
+-------------+---------+---------+------+'

# The real table from the failed run, verbatim.
COLLIDED='+-------------+---------+---------+------+
| Domain name | Status  | Address | Port |
+-------------+---------+---------+------+
| alpine-node | running | ::      | 6230 |
| node1       | error   | ::      | 6230 |
| node2       | running | ::      | 6231 |
| node3       | running | ::      | 6232 |
+-------------+---------+---------+------+'

# ── 1. the positive control: a correctly wired fleet passes ────────────────
# Without this, §2 would also pass on a checker that refuses everything.
run_chk "$HEALTHY" node1:6230 node2:6231 node3:6232 \
    || fail "a correctly wired fleet was refused — the check would block every good run (said: ${OUT//$'\n'/ })"
note "a fleet where every node owns its port passes  ✓"

# ── 2. the incident, verbatim: refused, naming the squatter ────────────────
run_chk "$COLLIDED" node1:6230 node2:6231 node3:6232 \
    && fail "REGRESSION: the exact table from the failed live run was accepted. alpine-node holds 6230 and node1 could not bind, so every IPMI command for node1 would actuate alpine-node — successfully, and about the wrong machine"
grep -Fq 'alpine-node' <<<"$OUT" \
    || fail "the refusal does not name the domain that actually holds the port (said: ${OUT//$'\n'/ })"
grep -Fq '6230' <<<"$OUT" \
    || fail "the refusal does not name the contended port (said: ${OUT//$'\n'/ })"
grep -Fq 'node1' <<<"$OUT" \
    || fail "the refusal does not name which fleet node is affected (said: ${OUT//$'\n'/ })"
note "the real collision is refused, naming node1, port 6230 and alpine-node  ✓"

# ── 3. …and it does not condemn the innocent ───────────────────────────────
# node2 and node3 were fine in that run. A check that fails the whole fleet on one
# node's collision sends the operator looking in three places instead of one.
grep -Fq 'node2' <<<"$OUT" \
    && fail "REGRESSION: node2 was reported as a problem; only node1's port was contended. A check that blames every node hides which one is actually broken"
note "nodes that DO own their ports are not implicated  ✓"

# ── 4. registered but not running -> refused (it never bound the port) ─────
NOTRUNNING='| Domain name | Status  | Address | Port |
| node1       | error   | ::      | 6230 |'
run_chk "$NOTRUNNING" node1:6230 \
    && fail "REGRESSION: a BMC in state 'error' was accepted. It never bound its port, so either nothing answers for the node or something else does"
grep -Fq 'error' <<<"$OUT" || fail "the refusal does not report the BMC's actual status (said: ${OUT//$'\n'/ })"
note "a BMC that is registered but not running is refused  ✓"

# ── 5. no registration at all -> refused, not assumed fine ─────────────────
run_chk "$HEALTHY" node4:6233 \
    && fail "REGRESSION: a node with NO BMC registration passed. Nothing would answer for it and the first power command would fail far from here"
grep -Fq 'node4' <<<"$OUT" || fail "the missing-registration refusal does not name the node (said: ${OUT//$'\n'/ })"
note "a node with no BMC registered at all is refused  ✓"

# ── 6. an EMPTY table is refused, not read as "no problems found" ──────────
# The bug class this lab has shipped before: a verifier that passes when the artifact
# is missing. `vbmc list` returns nothing when vbmcd is down, and "no rows, no
# problems" would wave the whole fleet through at exactly the wrong moment.
run_chk "" node1:6230 \
    && fail "REGRESSION: an EMPTY \`vbmc list\` was read as a clean bill of health. vbmcd being down produces exactly this, and it is the moment the check most needs to refuse"
note "an empty registration table refuses instead of passing vacuously  ✓"

# ── 7. the fleet plumbing actually calls it ────────────────────────────────
# The checker being correct is worth nothing if nothing runs it before enroll.
grep -q 'verify_bmc_bindings' "$LAB_DIR/create-fleet.sh" \
    || fail "REGRESSION: create-fleet.sh no longer verifies the BMC bindings — the check exists but nothing runs it, which is how the fleet got here in the first place"
note "create-fleet.sh runs the check on the way up  ✓"

pass "a BMC port answered by another machine is refused before enroll, naming the node, the port and the squatter — and a correctly wired fleet, an empty table, and the innocent nodes are each handled distinctly"
