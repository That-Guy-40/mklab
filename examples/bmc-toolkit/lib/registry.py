#!/usr/bin/env python3
"""Tiny reader for fleet-bmc.toml — the toolkit's per-node backend registry.

Usage:
  registry.py <toml> list                 -> node names, one per line
  registry.py <toml> get <node>           -> shell-eval'able  KEY=VALUE  lines (fields
                                             upper-cased, prefixed NODE_): NODE_BACKEND=...
  registry.py <toml> backend <node>       -> just the backend name

Kept intentionally small and dependency-free (stdlib tomllib, Python 3.11+), so bmc.sh
can source a node's parameters without a bash TOML parser.
"""
import sys, tomllib, shlex

def load(path):
    with open(path, "rb") as f:
        return tomllib.load(f)

def nodes(doc):
    return doc.get("node", [])

def find(doc, name):
    for n in nodes(doc):
        if n.get("name") == name:
            return n
    return None

def main():
    if len(sys.argv) < 3:
        sys.exit("usage: registry.py <toml> {list|get <node>|backend <node>}")
    path, cmd = sys.argv[1], sys.argv[2]
    doc = load(path)
    if cmd == "list":
        for n in nodes(doc):
            print(n.get("name", ""))
    elif cmd in ("get", "backend"):
        if len(sys.argv) < 4:
            sys.exit(f"usage: registry.py <toml> {cmd} <node>")
        n = find(doc, sys.argv[3])
        if n is None:
            sys.exit(f"registry: no node '{sys.argv[3]}' in {path}")
        if cmd == "backend":
            print(n.get("backend", ""))
        else:
            for k, v in n.items():
                print(f"NODE_{k.upper()}={shlex.quote(str(v))}")
    else:
        sys.exit(f"registry: unknown command '{cmd}'")

if __name__ == "__main__":
    main()
