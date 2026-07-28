#!/usr/bin/env python3
"""vbmc_check.py — prove each node's BMC actuates THAT node, before anyone trusts it.

    vbmc-lab.sh list | vbmc_check.py node1:6230 node2:6231 node3:6232

Exit 0 if every node owns its port and its BMC is running; exit 1 with a specific
message per problem otherwise.

WHY THIS EXISTS — the nastiest failure this lab has produced. VirtualBMC keeps one
listener per registered domain, and two domains can be registered on the SAME port:

    +-------------+---------+---------+------+
    | Domain name | Status  | Address | Port |
    +-------------+---------+---------+------+
    | alpine-node | running | ::      | 6230 |     <-- the sibling lab's own node
    | node1       | error   | ::      | 6230 |     <-- ours, could not bind
    +-------------+---------+---------+------+

The second one fails to bind and sits in `error`; the first keeps answering. Every IPMI
command the control plane sent to 127.0.0.1:6230 was then served by **a different
machine** — and served *plausibly*. `manage node1` verified creds. `power node1 status`
answered "Chassis Power is on". `bootdev pxe` and `power on` were accepted. All true,
all about alpine-node. node1 never powered on at all, and the only symptom was a health
gate timing out two phases later.

On this lab's own chaos ladder that is **LIED**: the record and reality disagreed and
every check said healthy. It is worse than an unreachable BMC, which fails immediately
and honestly. And it is invisible to the control plane by construction — the BMC seam
is exactly the abstraction that hides *which* machine is on the other end, so the check
has to live here, in the fleet plumbing that knows this is vbmcd.
"""
import re
import sys


def parse(text):
    """The `vbmc list` table -> [(domain, status, port)]. Ignores borders/headers."""
    rows = []
    for line in text.splitlines():
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 4:
            continue
        domain, status, _addr, port = cells[0], cells[1], cells[2], cells[3]
        if domain.lower() == "domain name" or not re.fullmatch(r"\d+", port):
            continue
        rows.append((domain, status, int(port)))
    return rows


def check(rows, want):
    """want = [(node, port)]. Returns a list of problem strings (empty = all good)."""
    problems = []
    by_port = {}
    for domain, status, port in rows:
        by_port.setdefault(port, []).append((domain, status))

    for node, port in want:
        here = by_port.get(port, [])
        mine = [(d, s) for d, s in here if d == node]
        others = [(d, s) for d, s in here if d != node]

        if not mine:
            if others:
                names = ", ".join(f"{d} ({s})" for d, s in others)
                problems.append(
                    f"port {port} is registered to {names}, NOT to '{node}'. Every IPMI "
                    f"command for '{node}' would actuate a different machine, and answer "
                    f"plausibly. Remove the squatter (vbmc delete <name>) or give '{node}' "
                    f"a free port in fleet.toml.")
            else:
                problems.append(
                    f"'{node}' has no BMC registered on port {port} — nothing will answer "
                    f"for it (register it: vbmc add {node} --port {port}).")
            continue

        if others:
            names = ", ".join(f"{d} ({s})" for d, s in others)
            problems.append(
                f"PORT COLLISION on {port}: '{node}' shares it with {names}. Only one "
                f"listener can bind, so whichever won answers for BOTH — the control "
                f"plane would drive the wrong machine while every check passed. Remove "
                f"the other registration (vbmc delete <name>) or move '{node}' to a free "
                f"port in fleet.toml.")
            continue

        status = mine[0][1]
        if status != "running":
            problems.append(
                f"'{node}' is registered on port {port} but its BMC is '{status}', not "
                f"running — it never bound the port. If something else holds {port}, that "
                f"something answers for '{node}'.")
    return problems


def main():
    want = []
    for arg in sys.argv[1:]:
        node, _, port = arg.partition(":")
        if not node or not port.isdigit():
            print(f"vbmc_check: bad argument '{arg}' (want node:port)", file=sys.stderr)
            return 2
        want.append((node, int(port)))
    if not want:
        print("usage: vbmc-lab.sh list | vbmc_check.py <node>:<port> ...", file=sys.stderr)
        return 2

    rows = parse(sys.stdin.read())
    if not rows:
        print("vbmc_check: no BMC registrations found in the `vbmc list` output — is "
              "vbmcd up? Refusing to assume the fleet's BMCs are fine.", file=sys.stderr)
        return 1

    problems = check(rows, want)
    for p in problems:
        print(f"vbmc_check: {p}", file=sys.stderr)
    if problems:
        return 1
    print(f"vbmc_check: all {len(want)} nodes own their BMC port and are running",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
