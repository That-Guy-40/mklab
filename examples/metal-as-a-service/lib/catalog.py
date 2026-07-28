#!/usr/bin/env python3
"""Read ramdisk-catalog.toml and project it for bash (stdlib tomllib, 3.11+).

Sibling of fleet.py — same contract, same reason: the catalog is the hand-edited
source of truth and this only projects it.

    catalog.py <catalog.toml> names          -> one image name per line
    catalog.py <catalog.toml> get <name>     -> IMG_<FIELD>=<shell-quoted> lines
    catalog.py <catalog.toml> check          -> validate every entry; non-zero on error

Paths (`kernel`, `initrd`) are expanded here — `~` and $VARS — so bash never has to
eval a string out of a config file. A catalog is data, not code: nothing in it is
ever executed by this module, and `build` is only ever PRINTED (it is the command a
human runs when an artifact is missing).
"""
import os
import shlex
import sys

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - Python < 3.11
    sys.exit("catalog.py: needs Python 3.11+ (tomllib)")

# What each health kind needs in order to be checkable at all. An entry that
# declares `health = "http"` with no `url` is a promise the driver cannot keep, so
# it is a catalog error rather than a runtime surprise on a node that is already
# booting.
REQUIRED = {
    "console": ("marker",),
    "http": ("url",),
    "dns": ("query",),
}

# A `region_check` says how to prove the node JOINED a region — the same three kinds,
# with their own fields. Declaring the kind without its field would leave the driver
# unable to verify membership it is about to claim, so it is a catalog error.
REGION_REQUIRED = {
    "console": ("region_marker",),
    "http": ("region_url",),
    "dns": ("region_query",),
}


def load(path):
    with open(path, "rb") as fh:
        return tomllib.load(fh)


def images(doc):
    return doc.get("image", [])


def expand(p):
    return os.path.expanduser(os.path.expandvars(p)) if p else p


def find(doc, name):
    for img in images(doc):
        if img.get("name") == name:
            return img
    return None


def problems(img):
    """Every reason this entry is unusable, as a list of sentences."""
    out = []
    name = img.get("name") or "<unnamed>"
    for field in ("name", "summary", "lab", "build", "kernel", "initrd", "health"):
        if not img.get(field):
            out.append(f"{name}: missing required field '{field}'")
    health = img.get("health")
    if health and health not in REQUIRED:
        out.append(
            f"{name}: health '{health}' is not one of {'/'.join(sorted(REQUIRED))}"
        )
    elif health:
        for field in REQUIRED[health]:
            if not img.get(field):
                out.append(
                    f"{name}: health='{health}' needs '{field}' — without it the "
                    f"driver has no way to decide the node reached active"
                )
    rk = img.get("region_check")
    if rk:
        if rk not in REGION_REQUIRED:
            out.append(f"{name}: region_check '{rk}' is not one of "
                       f"{'/'.join(sorted(REGION_REQUIRED))}")
        else:
            for field in REGION_REQUIRED[rk]:
                if not img.get(field):
                    out.append(
                        f"{name}: region_check='{rk}' needs '{field}' — without it the "
                        f"driver would claim a region membership it cannot verify"
                    )
    return out


def main(argv):
    if len(argv) < 3:
        sys.exit("usage: catalog.py <catalog.toml> {names|get <name>|check}")
    path, cmd = argv[1], argv[2]
    doc = load(path)

    if cmd == "names":
        for img in images(doc):
            print(img.get("name", ""))
        return

    if cmd == "check":
        errs = [p for img in images(doc) for p in problems(img)]
        names = [i.get("name") for i in images(doc)]
        dupes = {n for n in names if names.count(n) > 1}
        errs += [f"duplicate image name '{n}'" for n in sorted(dupes)]
        if not images(doc):
            errs.append("the catalog contains no [[image]] entries")
        for e in errs:
            print(f"catalog: {e}", file=sys.stderr)
        sys.exit(1 if errs else 0)

    if cmd == "get":
        if len(argv) < 4:
            sys.exit("usage: catalog.py <catalog.toml> get <name>")
        img = find(doc, argv[3])
        if img is None:
            known = ", ".join(i.get("name", "?") for i in images(doc))
            sys.exit(f"catalog.py: no image '{argv[3]}' (have: {known})")
        errs = problems(img)
        if errs:
            for e in errs:
                print(f"catalog: {e}", file=sys.stderr)
            sys.exit(1)
        for k, v in img.items():
            v = expand(str(v)) if k in ("kernel", "initrd") else str(v)
            print(f"IMG_{k.upper()}={shlex.quote(v)}")
        return

    sys.exit(f"catalog.py: unknown command '{cmd}'")


if __name__ == "__main__":
    main(sys.argv)
