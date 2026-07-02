# Vendored reference — the two stboot helpers this tool is a port of

[`../qemu-guestfwd-boot.py`](../qemu-guestfwd-boot.py) is a pure-Python
reimplementation of the reusable core of System Transparency's **stboot** QEMU
test harness (`integration/qemu-boot-from-net.sh`). Two tiny Go programs carry
that core:

- **`serve-http.go`** — reads one HTTP request on stdin, serves a static file
  from a directory, writes the response to stdout, exits. QEMU's user-net
  `guestfwd=…-cmd:` runs one per guest TCP connection, so the "web server"
  needs no listening socket, no bound host port, and no root.
- **`look-for.go`** — reads stdin (the serial console) and exits 0 the moment a
  line begins with a given prefix; the harness pipes QEMU's console through it
  under a `timeout` to decide pass/fail.

They are archived here **byte-exact** so this tool's provenance is explicit and
so the port can be checked against its source. The Python does not build or run
them — it reimplements their behavior (with a couple of robustness tweaks noted
in [`../README.md`](../README.md)).

## Provenance

| Field | Value |
|---|---|
| Project | System Transparency — `stboot` |
| Upstream | <https://git.glasklar.is/system-transparency/core> (repo `stboot`) |
| Version | **v0.7.0** |
| Commit | `493857ccfbfc2ad4c3911348bf97eb15870d6eba` (2026-03-09) |
| Paths | `integration/serve-http/serve-http.go`, `integration/look-for/look-for.go` |
| Retrieved | **2026-07-02** |
| License | **BSD-2-Clause** (`LICENSE.stboot`, "Copyright (c) 2021, stboot authors") |

## sha256 (byte-exact copies)

| File | sha256 |
|---|---|
| `serve-http.go` | `f7514ce349cf44ca6d9707245a3a73f604976e48aadc1ba27961a020852e02a9` |
| `look-for.go` | `611bfc912d9747f76e82d08ddc4496d7a176dd248cdfd6573c65eb2f1f99e6b0` |

Verify: `sha256sum -c` against the table, or re-hash with
`sha256sum serve-http.go look-for.go`.

## Attribution / license

These two files are © the stboot authors and redistributed under the
BSD-2-Clause license reproduced verbatim in `LICENSE.stboot`. All rights remain
with the upstream authors; they are archived here for offline reference and
provenance. `git rm` this directory to remove the vendored copies — the Python
tool does not depend on them at runtime.
