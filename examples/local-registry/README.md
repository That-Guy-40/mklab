# local-registry — a place to push to, and a chain worth verifying

A rootless OCI registry (`registry:2`) with **real TLS**, its server certificate issued by
the repo's [shared lab root CA](../lab-ca/README.md), plus a push/pull round trip that
compares **digests** — and a control that proves the TLS is doing something.

## Why it exists

`push` was a verb in exactly one driver ([`phase3-docker/lab-docker.sh`](../../phase3-docker/lab-docker.sh)),
and there was nowhere to push **to**: `registry:2` appeared in **zero** files repo-wide
(TODO 15.6). A verb whose destination does not exist is a verb nobody has ever watched
work. And this repo had a firm opinion about signed *boot* artifacts — the
[iPXE `imgverify` chain](../../netboot/MANUAL_TESTING.md), the
[shared CA](../lab-ca/README.md) — and none at all about container ones.

It is also the shared root's **third consumer**, which is the only part of a lab PKI that
is actually hard: one anchor that TLS, System Transparency and now a registry all chain to.

## What it is not

Not a production registry, and the shape says so: **no authentication**, **bound to
127.0.0.1**, **delete disabled**. The loopback bind is the only reason "no auth" is
defensible, so it is asserted by a test rather than left to whoever edits the spec next.

## Run it

```bash
examples/lab-ca/make-ca.sh                       # once, ever — the shared root
examples/local-registry/registry-lab.sh certs    # a TLS leaf for the registry, from that root
examples/local-registry/registry-lab.sh up       # via phase4-podman/lab-podman.sh
examples/local-registry/registry-lab.sh demo     # push, pull, compare digests + the control
examples/local-registry/registry-lab.sh down
```

`demo` prints, in this order:

```
CONTROL: pushing with NO CA — this must be refused
  refused: x509: certificate signed by unknown authority
pushing WITH the shared root
round trip: sha256:… — identical going in and coming out
```

## The control is the whole value

**"`podman push` succeeded" proves nothing about TLS.** The usual way to make a lab
registry work is `--tls-verify=false`, and from the outside that is indistinguishable from
a working chain right up until the day it matters. So `demo` pushes **twice** — once with
no CA, which must fail with an `x509` error, and once with the shared root, which must
succeed. A run where the control did not fire is not a pass, and
[`tests/test-round-trip.sh`](tests/test-round-trip.sh) asserts the control's own output
rather than the exit status.

The round trip is compared on the **manifest digest**, not the tag. A tag is a mutable
pointer: *"the tag came back"* is equally true of a registry that returned something else.

## Trust, stated honestly

| | |
|---|---|
| what verifies | the **client**, against `examples/lab-ca/lab-ca.crt` passed as `--cert-dir` |
| what does **not** | the registry does not authenticate the client at all — anyone who can reach the port can push |
| where the trust is installed | nowhere global. `--cert-dir` keeps the decision inside the command being demonstrated; installing the CA into `~/.config/containers/certs.d` would make every later run pass for a reason unrelated to this lab |
| what a real deployment adds | authentication (htpasswd/token), a non-loopback bind behind it, and image signing — `cosign` appears in **0** files here, which is the honest state of container-artifact signing in this repo |

## The absolute paths are derived, not written down — and the first draft got this wrong

`volumes` needs absolute host paths. Five specs in this repo answer that by hard-coding one
checkout's path — a cached fact about a machine, in a tracked file — which is how the
sibling in TODO 15.7 came to name `/home/user/mklab/…`, absolute and nobody's home
directory, from the day it was written. Nothing caught it because the only question ever
asked of that path was whether it began with a slash.

**The first draft of this lab made the same trade and added a checker**: hard-code the
path, derive the correct one, compare, refuse by name. That is a real improvement, and it
was still wrong. CI answered within the hour — its checkout is
`/home/runner/work/mklab/mklab`, so the check fired **correctly** on a design that could
never have passed anywhere but one machine.

> **A value that is false everywhere except one machine is not rescued by checking it.**

So [`local-registry.toml`](local-registry.toml) carries `@LAB_DIR@` — and since TODO
15.11 the **phase-4 driver itself** resolves it at parse time, alongside `@REPO@`,
`@NETBOOT@` and `@HOME@`, exactly as phase 2 does. This lab briefly rendered its own copy
because `lab-podman.sh` could not; that private mechanism is gone, because two mechanisms
for one problem is the thing this repo argues against everywhere else. [`tests/test-spec-paths.sh`](tests/test-spec-paths.sh)
asserts the tracked file stays portable **and** that rendering produces what the driver
asks for — with no podman, no network and no registry, on any machine — and both halves
were watched to fail on injected defects.

## Files

| file | what it is |
|---|---|
| [`registry-lab.sh`](registry-lab.sh) | the lab driver: `certs`, `up`, `demo`, `status`, `down`, `spec-check` |
| [`local-registry.toml`](local-registry.toml) | the phase-4 service spec (`@LAB_DIR@`, resolved by the driver) — read by `lab-podman.sh`, never a one-off `podman run` |
| [`tests/`](tests/) | the always-runnable spec check, and the round trip (skips, by name, without podman / the image / the CA key) |
| `state/` | gitignored: the issued leaf, the registry's storage, and the client `--cert-dir` |

Manual transcripts and what each run proved: [`MANUAL_TESTING.md`](MANUAL_TESTING.md).
