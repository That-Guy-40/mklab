# DEFERRED — what a green run still does not prove

**Status as of 2026-07-28 (evening):** `run-e2e.sh` **PASSES** end to end on real libvirt
domains **with the verifying firmware doing the checking** (`FLEET_NIC_ROM=1
MAAS_IPXE_TRUSTS_CA=1`, no `E2E_NO_IMGVERIFY`; see [`PLAN.md`](PLAN.md), "PASS — the whole
path"). `tests/run-all.sh` is **27 passed / 0 failed** and `chaos-run.sh` reports **0
criticals**.

This file exists because *that sentence is not the same as "the lab is finished,"* and the
difference is easy to lose. Each numbered section below was a gap that a passing run
**cannot** reveal; most are now closed, and each closed one records what closing it found
— because every single one paid out a defect the green suite could not see. What remains
open is stated at the top of "Where to start next".

> **Item 1 has since been picked up, and it paid immediately.** The first time real
> verifying firmware was pointed at this lab's payloads it refused them all, because the
> signing certificate was missing `keyUsage=digitalSignature` — a defect no host-side check
> could ever have seen. That is the case for this file in one sentence: the gaps a green
> run cannot reveal are where the defects were.

When you pick one up: the PLAN.md section named with each item is the evidence trail (the
live run that exposed the gap, and what it printed). Update this file when an item lands —
an item that is quietly done is as misleading as one quietly abandoned.

---

## Where to start next (as of 2026-07-28, night — items 1–4 ALL done)

**Every numbered item below is closed, live.** Item 2's live run landed last
(2026-07-28, third attempt — the first two each paid out a fresh defect, all fixed
and regression-tested; transcripts in [`MANUAL_TESTING.md`](MANUAL_TESTING.md) §13):
`node1` reached `active` through the INSTALL driver, with the firmware verifying the
installer payload (`imgverify` over the Anaconda kernel and its 223 MB initrd), the
kickstart writing the disk, the self-poweroff observed out-of-band and confirmed
stable, and the INSTALLED OS reaching `login:` from its own disk.

What remains lives in "Smaller, still open" below — chiefly: the `image` and
`image+measured` drivers have still never touched a real node, and a failed deploy
corrupts the recorded rollback pair (see the new item).

---

## 1. The on-node half of F2 — ✅ DONE, live, both halves (2026-07-28)

**Status changed 2026-07-28.** The firmware half now executes, headlessly, on every run of
[`tests/test-verifying-rom.sh`](tests/test-verifying-rom.sh):

| half | where | status |
|---|---|---|
| host-side | `verify` — OpenSSL CMS against the CA, before the node is touched | exercised every run |
| on-node | `imgverify` in the iPXE script — the firmware re-checks as it fetches | **runs under QEMU** ✅ |
| on-node, live | the same, on a libvirt fleet node | **✅ run 2026-07-28, both directions** |

**The live run (2026-07-28, evening).** `FLEET_NIC_ROM=1 MAAS_IPXE_TRUSTS_CA=1
./run-e2e.sh` **PASSED end to end** — node1's console shows OUR ROM's banner
(`iPXE 2.0.0+ (g3ca79)`), the embedded chain resolving `maas/node1.ipxe`, both
`.sig` fetches, and the payload's login banner. Then the negative control, on the
same node: 6 bytes appended to the served kernel (signature left intact), one
power-cycle, and the firmware refused it on the console — `Could not verify:
Permission denied (https://ipxe.org/0227e13c)` — fell through to the dead-end
script and stopped at the iPXE shell. Nothing booted. Kernel restored, node
power-cycled back to `login:`. Afterwards node2 and node3 were recovered from
their held `error` states and `apply` converged the **whole fleet** to `active`
through the verifying firmware, with the invariant pass issuing 0 transitions.
Full transcripts: [`MANUAL_TESTING.md`](MANUAL_TESTING.md) §12.5.

**Three more defects the live run found first** (none visible to the green suite —
the pattern holds):

1. **virt-aa-helper does not parse `<rom file=>`**, so AppArmor denied qemu the ROM
   and the domain died with `failed to find romfile` on a file that exists,
   world-readable — and the denial was **silent** (no DENIED line anywhere).
   `build-verifying-rom.sh install` now writes the rule into
   `/etc/apparmor.d/local/abstractions/libvirt-qemu`, the abstraction's own
   extension hook.
2. **`FLEET_NIC_ROM` had to ride the e2e itself** — the documented two-command
   sequence (attach, then run) self-destructed, because phase 3 redefines the
   domains and silently dropped the ROM. It bit a THIRD time the same evening
   (a bare `create-fleet.sh up`, prescribed by this repo's own messages, rebuilt
   the fleet ROM-less minutes before an install run — 0-byte console, full
   timeout ahead). Fixed structurally: the ROM now **defaults ON** whenever it
   is installed on the host (`FLEET_NIC_ROM=0` opts out), and both e2e runners
   refuse up front when `MAAS_IPXE_TRUSTS_CA=1` but the domain carries no
   `<rom file=>`.
3. **The images-dir default was split**: `run-e2e.sh` said `~/.cache/…`,
   `maas-lab.sh` said `$XDG_STATE_HOME/…` — so a bare `maas-lab.sh apply` read a
   store that did not exist and reported it as "F2 signature verification failed"
   (the gate swallowed the driver's honest "no such image dir"). Fixed by making
   `maas-lab.sh _images-dir` the one owner of the answer, moving the store (and
   the signing key) under the state root, and letting `gate()` keep the driver's
   own last line in `GATE_REASON`.

**What it cost to find out, and why it was worth it.** The very first time real verifying
firmware was pointed at this lab's own signed payloads, it refused them — *all* of them,
including good ones:

```
http://…/good.img... ok
http://…/good.img.sig... ok
Could not verify: Permission denied (https://ipxe.org/022ae13c)   ← "Not a signing certificate"
```

`drivers/verify-lib.sh` minted its code-signing leaf with `extendedKeyUsage=codeSigning`
and nothing else. `openssl cms -verify` does not look at key usage, so every host-side
gate, every driver test and the whole green suite accepted it — and iPXE requires
**`keyUsage=digitalSignature`** as well. **This fleet had been signing payloads that no
verifying firmware would ever accept**, and by construction nothing on the host could see
it. Fixed in `verify-lib.sh` (the profile now matches `netboot/sign-payload.sh`, the signer
the RAM-infra lab proved against real iPXE), guarded by `verify-lib.sh check-keys`, and
pinned against re-divergence by
[`tests/test-signing-cert-profile.sh`](tests/test-signing-cert-profile.sh) §4.

**The second hole is confirmed and closed too.** Measured on this fleet's own `node1.log`:
it begins at `Linux version …` with **zero** SeaBIOS or iPXE lines. Side by side in
libvirt's own QEMU invocation (`-display none`, *not* `-nographic`): **stock ROM 0 bytes on
the serial console, the new ROM 617**. ⚠️ Do not test a `CONSOLE_SERIAL` build under
`-nographic`: QEMU sets `FW_CFG_NOGRAPHIC`, SeaBIOS puts *its* console on COM1 too, and the
two writers interleave byte-by-byte (`iiPPXXEE`) — under that invocation the stock ROM looks
instrumented and this one looks broken, which is exactly backwards.

**How to build it** (the earlier note here named `--certfile`, which is not a flag
`build-ipxe.sh` has — that was OpenSSL's `-certfile`, from `verify-lib.sh`):

```bash
./build-verifying-rom.sh build      # docker, ~10 min: iPXE + IMAGE_TRUST_CMD + TRUST=<fleet CA>
./build-verifying-rom.sh install    # sudo: /var/lib/libvirt, because qemu cannot read $HOME
```

**Done when** (met 2026-07-28): a live run with neither `E2E_NO_IMGVERIFY` nor
`--no-verify` reaches `active` ✅, **and** a deliberately tampered payload is refused
by the firmware with the refusal visible in that node's console log ✅.

**Evidence trail:** [`PLAN.md`](PLAN.md) — "The verifying ROM". Headless coverage:
[`tests/test-verifying-rom.sh`](tests/test-verifying-rom.sh) (the firmware itself),
[`tests/test-signing-cert-profile.sh`](tests/test-signing-cert-profile.sh) (the certificate
profile), [`tests/test-rom-xml.sh`](tests/test-rom-xml.sh) (the domain rewrite),
[`tests/test-imgverify-halves.sh`](tests/test-imgverify-halves.sh) (the seam).

---

## 2. Only the `ramdisk` driver has touched a real node — ✅ DONE: `install` ran live (2026-07-28)

**Status changed 2026-07-28 (late).** The build half is done and headlessly proven:

- **`install-catalog.toml`** — the install driver's own image registry (the shape
  `ramdisk-catalog.toml` established), with `almalinux9`: the Anaconda netboot pair,
  the lab kickstart (`clearpart`+`autopart` on vda, ends in `poweroff` — the
  completion signal the driver waits for), and the `inst.stage2=` cmdline.
- **`install.sh stage`** — stages kernel+initrd+**ks.cfg** into the signed store and
  signs all three. Deliberately no `cmdline` file: that triple is the ramdisk
  driver's ownership fingerprint, and each driver's staged shape is now its claim.
- **`install.sh deploy` answers the netboot CHAIN** — it writes the per-node
  `maas/<node>.ipxe` (with `imgverify` for kernel+initrd and `inst.ks=` pointing at
  the served kickstart) exactly as the ramdisk driver does. Before this, an install
  on the fleet network would have fallen through to the dead-end script and timed
  out — the same hole the first two live ramdisk runs paid for. Honest gap, stated
  in the generated script: the firmware attests the installer it boots; the
  kickstart is fetched later by Anaconda, which cannot `imgverify` (its `.sig` is
  staged and served; only the host-side gate checks it).
- **`run-e2e-install.sh`** — the separate runner (so `run-e2e.sh` stays fast). Its
  preflight catches, with the fix named: fleet down, chain absent, payload server
  dead, legacy trust leaf, and a missing or **sha-mismatched Anaconda stage2**
  (checked against `.treeinfo`; fetched fresh with `E2E_FETCH_STAGE2=1`, never
  resumed — the `curl -C -` trap this repo already paid for once). Before the
  deploy it **rotates the node's console log** (append-only across boots, and the
  RAM payload's old `login:` would satisfy the health gate instantly — the cheap
  check standing in for the real one) and **powers the node off** (a deploy begins
  from rest, as on real metal; `power on` against a running RAM node never PXEs).

Coverage: [`tests/test-install-driver.sh`](tests/test-install-driver.sh) — the real
driver through the mock BMC: chain script written with `imgverify` + `inst.ks`,
payload served, `describe` accepts its own shape and refuses both the ramdisk shape
and an unclaimed image, `stage` signs all three and names the build command when
artifacts are missing.

**The live run (2026-07-28, third attempt).** `MAAS_IPXE_TRUSTS_CA=1
./run-e2e-install.sh` **PASSED**: chain → firmware-verified installer (`imgverify`
over kernel + 223 MB initrd) → kickstart wrote vda → `reboot: Power down` observed
out-of-band and confirmed stable → `bootdev disk` → AlmaLinux 9.8 booted from its
own disk to `login:` → `active (driver=install image=almalinux9)`. The first two
attempts each found a live-only defect (all fixed + regression-tested, see
MANUAL_TESTING §13): a 0600 stage2 the web server 403'd (mktemp perms survived the
sha check — the sha said perfect, the perms said nobody may look), virtlogd's 2 MiB
rotation replacing the readable console with a 0600 root file (both console health
gates now refuse loudly instead of timing out with "never reached login"), and an
out-of-band power cycle racing the poweroff-wait (the driver now confirms the off
STAYS off; `MOCK_BMC_BLIP` reproduces the incident headlessly).

**Done when** (met): a live run reaches `active` through `install` on a real domain,
with the installed OS's own `login:` on the console — not the ramdisk's ✅.

`image` and `image+measured` on real hardware remain open (see below).

## 3. A chaos scenario for a BMC that answers for a *different machine* — ✅ DONE (2026-07-28)

**Landed as the `bmc-misbound` scenario** (oob layer, `chaos-run.sh`), injected via
`MOCK_BMC_ACTUATES=<victim>` in [`tests/mock-bmc.sh`](tests/mock-bmc.sh): every power
verb — `status` included — succeeds and answers **truthfully about the victim
machine**, which is exactly what made the live incident invisible (four IPMI commands,
every answer true, none about the machine in the record).

**The finding the scenario forced:** every through-the-seam check passes *by
construction*, so no power poll can ever catch this. The defence that works is the
health gate's **console** check — the console is bolted to the machine, not the BMC,
and the subject's silent console is the one witness the mis-binding cannot fake. The
chaos driver's health now carries that check (`CHAOS_CONSOLE_DIR`, mirroring what the
real drivers' console-grep health gates already do), and the mock BMC writes a boot
line to the console of whichever machine **actually** powers on.

**Where it grades:** HALTED — the deploy's health fails on the silent console, the
A/B rollback runs through the same lying seam and honestly fails too, and the node
lands in `error` with the reason recorded. The victim machine really is powered on
behind its owner's back (the scenario asserts the collateral fired). Not ABSORBED —
prevention lives at enroll time in [`lib/vbmc_check.py`](lib/vbmc_check.py); this
scenario is what happens when a mis-binding gets past it anyway.

**Done when** (met): the scenario exists in the oob layer ✅, is graded after the
recovery the system offers ✅, and
[`tests/test-chaos-matrix.sh`](tests/test-chaos-matrix.sh) fails when it is removed ✅
— plus two run-not-reasoned controls: with the console check **off**, the registry
records `active` on a machine that never powered on (the LIED shape, demonstrated
live in the test); with it **on**, the same deploy halts.

## 4. Should `apply` self-heal a node its own guard demoted? — ✅ ANSWERED AND BUILT (2026-07-28)

**The answer: yes — for that kind of error only, bounded, on the record.** The two
roads into `error` are now distinguishable and treated differently:

- **A failed deploy** holds for the operator, exactly as before: the image is
  unproven and a human should look. `apply` never touches it.
- **A recheck demotion** (`cmd_recheck` writes a `demoted_by_recheck` marker) was
  healthy at activation and died afterwards — what a reconcile loop exists to
  repair. `apply` plans a `retry` for it: visible in the table as
  `self-heal N/MAX`, recorded in the node's history as `apply self-heal N/MAX`.
- **The bound** (`MAAS_APPLY_SELFHEAL_MAX`, default 2) is the mask-guard: a node
  that dies after every heal ends up HELD with `self-heal budget spent` in the
  table, not absorbed by the loop forever. Only a **human** `retry` resets the
  budget (the operator's semantics); the loop's own attempts spend it.
- **Entering a deploy consumes the marker**, so a heal whose redeploy fails becomes
  a failed-deploy hold — a crash-looping image cannot be self-healed repeatedly.

Coverage: [`tests/test-apply-selfheal.sh`](tests/test-apply-selfheal.sh) — heal,
bound, hold-with-reason, human reset, dry-run honesty (plans the heal, writes
nothing), and the negative control that a failed-deploy error is never touched.

## Smaller, still open

- ~~**The fleet's signing key lives in a cache directory.**~~ **DONE 2026-07-28**, and it
  turned out to be two defects, not one: beyond the deletable-`~/.cache` contract, the
  default was **split** — `run-e2e.sh` said `~/.cache/lab-create/maas/images` while
  `maas-lab.sh` said `$STATE_ROOT/images`, so a bare `maas-lab.sh apply` read a store that
  did not exist (and misreported it as a signature failure; also fixed — `gate()` now keeps
  the driver's own words). The store, key included, now lives under
  `$XDG_STATE_HOME/lab-create/metal-as-a-service/images`, and `run-e2e.sh`,
  `build-verifying-rom.sh` and `tests/test-verifying-rom.sh` all resolve it via
  **`maas-lab.sh _images-dir`** instead of each keeping a copy of the path. Migration for
  an existing fleet: `cp -a ~/.cache/lab-create/maas/images
  "$(./maas-lab.sh _images-dir)"` (same CA, so the ROM does **not** need a rebuild), then
  delete the cache copy.
- **`tests/test-e2e-fails-fast.sh` runs the real `run-e2e.sh`.** `MAAS_STATE` is now
  sandboxed on that line, but the test is still only safe because the preflight refuses
  before phase 1 — a test whose hermeticity depends on the order of checks *inside the
  script under test*. Measured harmless today (the registry's history is byte-identical
  across a run); worth making structural.

- ~~**A failed deploy corrupts the recorded rollback pair.**~~ **DONE 2026-07-28
  (night)**, made structural rather than patched per-branch: the `(driver, image)`
  pair is now **only ever written when a gate passes** — a failed deploy leaves the
  last verified pair untouched, so there is no pre-gate write for a future failure
  branch to forget to undo. The in-flight driver lives in a transient
  `deploying_driver` (written at deploy start, removed on every exit), which is
  what `watch` renders while state is `deploying` — so mid-deploy progress still
  shows what is actually booting. Regression-locked in
  [`tests/test-rollback-driver-pair.sh`](tests/test-rollback-driver-pair.sh) §4+§7,
  written red-first: §7 replays the live incident (both-slots-bad failure, then a
  successful redeploy) and asserts the recorded previous pair is the real one. The
  live registry's own lie (`previous: install/micro-linux-x86_64` on node1) was
  cleared by hand, with the why appended to the node's history.
- **`image` and `image+measured` have never touched a real node.** The install
  driver's live run (item 2) proves the pattern; these two still have only their
  headless real-driver tests. `image` needs a golden whole-disk raw staged first.
- ~~**`install.sh`'s ownership test is narrow on purpose.**~~ **CLOSED 2026-07-28** by
  [`install-catalog.toml`](install-catalog.toml) — the per-driver catalog this item
  asked for. `describe` now answers positively (cataloged, or staged in the driver's
  own kernel+initrd+ks.cfg shape) and refuses both the ramdisk triple **and** an
  image no driver has claimed.
- **`describe` is asked of every driver by `gate`, but only `ramdisk` and `install`
  answer meaningfully.** `image` and `image+measured` still accept any image name.
