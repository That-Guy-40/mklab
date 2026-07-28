#!/usr/bin/env python3
"""Read fleet.toml and emit shell-eval'able node records (stdlib tomllib, 3.11+).

Mirrors bmc-toolkit's lib/registry.py contract so create-fleet.sh can source it:

    fleet.py <fleet.toml> names            -> one node name per line
    fleet.py <fleet.toml> get <name>       -> NODE_<FIELD>=<shell-quoted> lines,
                                              [defaults] merged under per-node keys
    fleet.py <fleet.toml> pool             -> POOL_<FIELD>=<shell-quoted> lines
    fleet.py <fleet.toml> claims           -> one claim name per line
    fleet.py <fleet.toml> claim <name>     -> CLAIM_<FIELD>=<shell-quoted> lines

Kept dependency-free and small on purpose — the fleet spec is the hand-edited
source of truth; this only projects it for bash.
"""
import shlex
import sys

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - Python < 3.11
    sys.exit("fleet.py: needs Python 3.11+ (tomllib)")


def load(path):
    with open(path, "rb") as fh:
        return tomllib.load(fh)


def nodes(doc):
    defaults = doc.get("defaults", {})
    out = []
    for n in doc.get("node", []):
        merged = dict(defaults)
        merged.update(n)
        out.append(merged)
    return out


def main(argv):
    if len(argv) < 3:
        sys.exit("usage: fleet.py <fleet.toml> {names|get <name>|pool|claims|claim <name>}")
    path, cmd = argv[1], argv[2]
    doc = load(path)
    ns = nodes(doc)
    if cmd == "names":
        for n in ns:
            print(n["name"])
        return
    if cmd == "claims":
        for c in doc.get("claim", []):
            print(c.get("name", ""))
        return

    if cmd == "claim":
        if len(argv) < 4:
            sys.exit("usage: fleet.py <fleet.toml> claim <name>")
        for c in doc.get("claim", []):
            if c.get("name") == argv[3]:
                for k, v in c.items():
                    print(f"CLAIM_{k.upper()}={shlex.quote(str(v))}")
                return
        sys.exit(f"fleet.py: no claim '{argv[3]}'")

    if cmd == "pool":
        for k, v in doc.get("pool", {}).items():
            print(f"POOL_{k.upper()}={shlex.quote(str(v))}")
        return

    if cmd == "get":
        if len(argv) < 4:
            sys.exit("usage: fleet.py <fleet.toml> get <name>")
        want = argv[3]
        for n in ns:
            if n["name"] == want:
                for k, v in n.items():
                    key = "NODE_" + k.upper()
                    print(f"{key}={shlex.quote(str(v))}")
                return
        sys.exit(f"fleet.py: no node '{want}'")
    sys.exit(f"fleet.py: unknown command '{cmd}'")


if __name__ == "__main__":
    main(sys.argv)
