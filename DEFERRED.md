# DEFERRED — mklab (repo level)

> Work that was consciously **not done** in the PR that found it, with the reason it was
> not, who owns it, and what closes it. Two labs already keep a ledger of this shape —
> [`examples/metal-as-a-service/DEFERRED.md`](examples/metal-as-a-service/DEFERRED.md) and
> [`examples/micro-cloud/DEFERRED.md`](examples/micro-cloud/DEFERRED.md) — for items that
> belong to one lab. This file is the same shape one level up, for items that belong to
> none. An item that is quietly done is as misleading as one quietly abandoned: **update
> this file when an item lands.**

## D1 — the `phase4-podman` readiness-race fix (deferred out of #459, 2026-09-20)

**✅ RESOLVED 2026-09-20 (PR #466, branch `fix/phase4-podman-readiness-race`).**
`test-pod-lifecycle.sh`'s one-shot probe at line 57 is replaced with a bounded
readiness wait on the observable outcome —
`await_match 30 nginx -- "$LAB_PODMAN" exec "$LAB/b" -- wget -q -O- http://localhost/` — so the
test waits for nginx to *answer*, not merely for its container to be *listed*. Verified on a host
with **podman 4.9.3**: `tests/run-all.sh` → `26/26 discovered tests ran — 24 passed, 2 skipped,
0 failed`, and the **control bit** — pointing the same wait at a dead port (`:81`) expired at its
5 s deadline with `wget: can't connect … Connection refused` and returned non-zero (a real
bounded wait, not a hang, not a false pass). Diff touches only `test-pod-lifecycle.sh`. The
process guardrail (do not merge over a red `shell test suites`) starts counting from this fix.

<details><summary>Original entry (why it was deferred out of #459)</summary>

**What.** `phase4-podman/tests/test-pod-lifecycle.sh` awaits the pod and both containers
*existing* (`await_line 20` on their names), then probes nginx **immediately** at line 57 —
before it is *listening* — and fails with:

```
FAIL: b couldn't reach a via localhost; got: wget: can't connect to remote host: Connection refused
```

The fix is a bounded wait on the **observable outcome** using the suite's own helper
(`await_match`, [`phase4-podman/tests/lib.sh`](phase4-podman/tests/lib.sh) line 260), a control
that must bite, and the never-skip guardrails.

**Where the fix is specified.** [`TODO.md`, NEXT → Item 1](TODO.md#item-1--main-is-red-from-a-readiness-race-in-phase4-podman-not-from-the-firmware-family).
The brief already prescribes the fix in full — the wait, the control, the acceptance — so that
section is the **specification**. This entry is the **record that it has not been done**, and why.

**Why it was not folded into #459.**

- [#459](https://github.com/That-Guy-40/mklab/pull/459) was a docs-only change (217 lines
  in `TODO.md`). A test fix belongs in its own one-test PR against `phase4-podman`, so that
  *that* PR's own `shell test suites` run is the acceptance oracle and a docs change does not
  carry a behavioural one.
- The authoring host had **no `podman`**. The fix could not be reproduced or verified there,
  and CLAUDE.md's rule — *reproduce with the tool the SUBJECT runs* — forbids pushing a fix
  to a race one has only reasoned about.
- No fix existed on any branch to port.

**Who owns it.** Opus 4.8, as **item 1** of the brief — first, before the Tier-0 contract,
because a checker landed on a red `main` proves nothing.

**State at the time of writing (2026-09-20, ~20:00 UTC).** Still red, and still the only
failing suite. Confirmed on **15 consecutive `main` pushes**: #446–#458 (the 13 the brief
measured), then #460 ([run 1024](https://github.com/That-Guy-40/mklab/actions/runs/35494879681))
and #461 ([run 1026](https://github.com/That-Guy-40/mklab/actions/runs/35497134090)). The
runs for #462 and #459 were in progress when this was written. #459 itself was merged over
that red by the owner's explicit decision, with a
[standing-down comment](https://github.com/That-Guy-40/mklab/pull/459#issuecomment-5747654660)
on the PR naming the failing check and why it was not that PR's. The brief's own process
guardrail (item 1, point 6: *do not merge over a red `shell test suites` job until `main` is
green*) therefore starts counting from **this fix landing**, not from #459.

**What closes this entry** (from the brief's acceptance): a PR whose `ci.yml` run is fully
green (all four jobs), whose diff touches `phase4-podman/tests/test-pod-lifecycle.sh` (and
at most `lib.sh` if the helper needs a tiny extension), and whose description quotes the
control biting. When it lands: mark this entry ✅ with the PR number and date, and move the
brief's item 1 down into `TODO.md` §0 as a dated ✅.

**Evidence trail.** First red run 996 (#446, 2026-09-18 08:10 UTC); the latest the brief
measured, [run 1021](https://github.com/That-Guy-40/mklab/actions/runs/35454272557) (#458).
Intermittent across PR runs — 986 failed and its re-run 987 passed; 1003 and 1007 passed amid
failures — which is a race's fingerprint, not a broken test. Every other suite in the step
prints `0 failed`.

</details>

## D2–D4 — deferred by the same brief, not started

Listed so this file is a complete ledger of what the brief defers. Their specifications live
in `TODO.md` and are not duplicated here.

| # | item | where specified | owner |
|---|---|---|---|
| D2 | **1a** — ◑ **attestation half DONE 2026-09-20 (`fix/tier-b-cbfs-attestation-tracks`); CBFS half still open.** `event-log event-replay event-real event-bench` are now in Tier B's `DEFAULT_TRACKS` with `tpm2-tools` installed and a **strict gate** (a 77/SKIP from them is red, not a `::warning::`) — the SHA-256 replay + event-log/real/bench parse are verified in CI, not only on the dev host (all four pass locally with tpm2-tools + vendored fixtures; there is no separate `sha256` track — `event-replay` *is* the NIST-vector + PCR replay). **Still open — the `cbfs*` tracks** (`cbfs cbfs-live cbfs-write cbfs-payload`) need the built coreboot ROM (`$HOME/linuxboot-lab/coreboot`), which the Tier B job does not provision; they are **named CI-unrunnable** in the workflow rather than left to skip quietly. Closing them is a coreboot-build (or vendored-ROM) step in the Tier B job. | [Item 1a/1b](TODO.md#item-1a1b--two-hygiene-gaps-the-same-audit-surfaced-small-do-alongside-or-right-after) | Opus 4.8, alongside or right after D1 |
| D3 | **1b** — the `qemu-system` install step can fail silently (2 s, swallowed by `\|\| echo "::warning::…"`), leaving every QEMU-gated row UNKNOWN inside a job that claimed to install the tool | [Item 1a/1b](TODO.md#item-1a1b--two-hygiene-gaps-the-same-audit-surfaced-small-do-alongside-or-right-after) | Opus 4.8, alongside or right after D1 |
| D4 | **2** — the Tier-0 conformance contract (`dsl/CONTRACT.md` v1) + slim-profile checker; four modules currently refuse bad input four different ways | [Item 2](TODO.md#item-2--the-tier-0-conformance-contract--slim-profile-checker-the-roadmaps-unbuilt-piece) | Opus 4.8, **after** D1 |
