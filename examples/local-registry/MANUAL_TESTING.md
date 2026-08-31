# MANUAL_TESTING — local-registry

Transcripts from the verification host (Ubuntu 24.04, rootless podman 4.9.3). **This file
is a RECORD, dated per entry.** Re-running will not reproduce it byte for byte — digests
change with the timestamp baked into the demo image — and that is not a defect. What must
stay true is that the command exists, the success signature is reachable, and any
present-tense claim is re-derived rather than copied.

## 1. The shared root, then a leaf for the registry — 2026-08-30

```console
$ examples/local-registry/registry-lab.sh certs
[registry-lab] issuing a TLS leaf for registry.lab from the SHARED root (…/examples/lab-ca/lab-ca.crt)
==> verifying leaf against the lab CA (openssl verify):
    …/examples/lab-ca/private/certs/registry.lab.crt: OK
[registry-lab] staged: …/state/certs/tls.{crt,key} and …/state/certdir/ca.crt
[registry-lab] the anchor is 4F:A6:9C:1A:72:FD:3F:0B:AE:90:23:8E:55:86:97:5C:B6:44:3B:96:58:D5:EF:E7:B8:1A:42:CA:F0:07:0A:61
```

The fingerprint is the one tracked in `examples/lab-ca/lab-ca.fingerprint` — the same
anchor the netboot payload signer and System Transparency chain to. Printing it is how you
see that this lab did **not** mint a root of its own.

## 2. Up, through the phase-4 driver — 2026-08-30

```console
$ examples/local-registry/registry-lab.sh up
[registry-lab] spec renders to this lab: examples/local-registry/state/certs and …/state/data
[registry-lab] starting via the phase-4 driver (no one-off podman run)
[info] starting (plain) service 'registry' as lab-local-registry-registry (image=docker.io/library/registry:2)
[info] ── lab 'local-registry' up ──
[registry-lab] https://localhost:5000/v2/ answers 200, verified against the SHARED root
[registry-lab] catalog: {"repositories":[]}
```

Success signature: `answers 200, verified against the SHARED root`. The `--cacert` is the
tracked `lab-ca.crt`; **without** it the same request is refused, which is step 3.

## 3. The round trip, and the control — ✅ 2026-08-30

```console
$ examples/local-registry/registry-lab.sh demo
[registry-lab] building a scratch image (no network, no base layer)
[registry-lab] CONTROL: pushing with NO CA — this must be refused
[registry-lab]   refused: x509: certificate signed by unknown authority
[registry-lab] pushing WITH the shared root
[registry-lab] round trip: sha256:440497e9a2…4618dc — identical going in and coming out
[registry-lab] OK: TLS chains to the shared root, an untrusted client is refused, and the digest survives
```

> **Why the control comes first.** `podman push` succeeding proves nothing about TLS: a
> registry run with `--tls-verify=false` produces exactly the same line. The measured
> refusal is what separates the two, and the demo runs it *before* the real push so a run
> that skipped it cannot be mistaken for a pass.
>
> **Why the digest, not the tag.** A tag is a mutable pointer; *"the tag came back"* is
> equally true of a registry that handed back something else. The comparison is between the
> registry's `Docker-Content-Digest` header and the `RepoDigests` of the image pulled after
> the local copy was deleted.

Raw, from the same session — the two pushes side by side:

```console
$ podman push --cert-dir /nonexistent-certs localhost:5000/lab-hello:v1
Error: … pinging container registry localhost:5000: Get "https://localhost:5000/v2/":
tls: failed to verify certificate: x509: certificate signed by unknown authority

$ podman push --cert-dir state/certdir localhost:5000/lab-hello:v1
Copying config sha256:95736b159f2a…
Writing manifest to image destination
```

## 4. The suite — 2026-08-30

```console
$ examples/local-registry/tests/run-all.sh
summary: 3/3 discovered tests ran (3 test files on disk) — 3 passed, 0 skipped, 0 failed
```

Run from a **cold** start (no registry running): `test-round-trip.sh` issued the leaf,
brought the registry up through `lab-podman.sh`, ran the demo, and stopped it again —
`podman ps` was empty afterwards. Run with one already up, it says so and leaves it alone.

**What skips, and why that is an UNKNOWN rather than a pass:** `test-round-trip.sh` needs
podman, `registry:2` **already pulled** (it never reaches the network — a suite that
fetches from Docker Hub fails for reasons unrelated to the code), and the shared CA's
**private key**, which is gitignored and so exists only on the machine that made it. Each
of those prints its own `SKIP:` line naming the missing precondition. In CI all three are
absent, so this row is honestly reported as not-run rather than counted green.
`test-spec-paths.sh` needs none of them and always runs.

## 5. The spec was hard-coded, and CI said so — 2026-08-30

The first version of `local-registry.toml` carried this checkout's absolute path in
`volumes`, with a checker that derived the correct value and refused a mismatch. It passed
here and failed on the first CI run:

```console
FAIL: REGRESSION: local-registry.toml does not contain the volume line this checkout needs:
      want: /home/runner/work/mklab/mklab/examples/local-registry/state/certs:/certs:ro,Z
```

The check was right; the design was not. **A value that is false everywhere except one
machine is not rescued by checking it** — so the tracked file now carries `@LAB_DIR@` and
`registry-lab.sh render` writes the absolute paths into a gitignored copy.

Verified the way the failure was found — from somewhere else entirely:

```console
$ cp -a examples/local-registry /tmp/elsewhere/examples/ && rm -rf /tmp/elsewhere/examples/local-registry/state
$ /tmp/elsewhere/examples/local-registry/tests/test-spec-paths.sh
PASS: the tracked spec is portable (@LAB_DIR@, no absolute host path), rendering it produces
exactly the volume lines the driver asks for with no placeholder left …
$ grep state/certs /tmp/elsewhere/examples/local-registry/state/local-registry.rendered.toml
  "/tmp/elsewhere/examples/local-registry/state/certs:/certs:ro,Z",
```

## 6. What this lab does NOT prove

- **No authentication anywhere.** Anyone who can reach `127.0.0.1:5000` can push. The
  loopback bind is what makes that acceptable, and `test-spec-paths.sh` fails if the spec
  stops binding to loopback.
- **No image signing.** `cosign` appears in **0** files in this repo. The chain proven here
  is transport trust (TLS to the shared root), not artifact provenance — the container-side
  counterpart of `netboot/sign-payload.sh` does not exist yet.
- **Nothing about a remote client.** Everything runs on one host; the registry has never
  been reached from another machine, so no claim is made about it.
