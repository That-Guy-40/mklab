# DEFERRED — what a green run still does not prove

**Status as of 2026-07-29 (night):** all three live runs pass end to end on real libvirt
domains — `run-e2e.sh` (**with the verifying firmware doing the checking**:
`FLEET_NIC_ROM=1 MAAS_IPXE_TRUSTS_CA=1`, no `E2E_NO_IMGVERIFY`; see [`PLAN.md`](PLAN.md),
"PASS — the whole path"), `run-e2e-image.sh`, and now **`run-e2e-measured.sh`**:

```
PASS: node3 attested to a real TPM measurement of the image it booted, activated only
      against a policy captured from that measurement, and was REFUSED when the policy
      no longer matched.
```

`tests/run-all.sh` is **34 passed / 0 skipped / 0 failed** and `chaos-run.sh` reports
**0 criticals**.

That last run is the one this file spent two days pointing at, and it closed the two
steps no run had ever reached: **deploy #2** (the same image must now attest and
activate) and **deploy #3** (a policy the node cannot satisfy must be refused). #3 is
the one that matters most — it is the only thing that distinguishes a real gate from
one that always says yes.

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

## Where to start next (as of 2026-07-29, night — every numbered item and every live run done)

**Every numbered item below is closed, live, and so is the `image+measured` run this
file spent two days pointing at.** Item 2's install run landed 2026-07-28 (third
attempt — the first two each paid out a fresh defect; transcripts in
[`MANUAL_TESTING.md`](MANUAL_TESTING.md) §13). The measured run landed 2026-07-29
(§15), and the fifteen-defect ledger below is the reason it took that long.

**What is genuinely left is smaller than it has ever been**, and none of it blocks a
run:

- **`describe` is meaningful for only two of four drivers** (`image` and
  `image+measured` still accept any image name) — see "Smaller, still open".
- **`tests/test-e2e-fails-fast.sh` runs the real `run-e2e.sh`**, and its hermeticity
  depends on the order of checks inside the script under test. Measured harmless;
  worth making structural.
- **The honest gap that no amount of work here can close:** swtpm is faithful plumbing
  and the attestation key is baked into the image, so the measured path proves the
  MECHANISM and the REFUSAL PATH, never the integrity of a machine. Real hardware needs
  a discrete TPM whose endorsement key is certified by the manufacturer, with the AK
  generated *inside* it. Stated the same way in
  [`drivers/image-measured.sh`](drivers/image-measured.sh) and
  [`measure-init.sh`](measure-init.sh), deliberately, in three places.
- **CI note (2026-07-29):** the `shell test suites` job is red on `main` for an
  environmental reason — the GitHub runner's `crun` cannot report its own version
  (`crun: unknown version specified`), so three **phase4-podman** container tests
  cannot start a container. Confirmed by re-running a commit that had passed earlier
  the same evening and watching it fail: the machine changed, not the repo. Nothing in
  this lab is implicated; every metal-as-a-service test in that job passes.

---

## The defect ledger — 15 defects a green suite could not see

Each was found by pointing real hardware at a suite that was green at every step. They
are listed here because the *pattern* turned out to matter more than any individual fix,
and it is now written up in the repo's [`CLAUDE.md`](../../CLAUDE.md) → "The two bug
classes a green suite cannot see".

| # | the defect | why the suite missed it |
|---|---|---|
| 1 | signing leaf had no `keyUsage=digitalSignature`; verifying firmware refused every payload | only a booted ROM can refuse a certificate the host-side gate accepts |
| 2 | `install.sh` asked `virsh domstate` whether the installer had finished | a machine in a rack has no `virsh` — and the call no seam could intercept was the one nothing tested |
| 3 | the PXE network served one baked payload to every node | the per-node scripts the drivers write were never fetched; the suite *is* the substitute |
| 4 | domains had a `pty` console, so nothing wrote the log every health gate greps | every headless test writes that file by hand |
| 5 | node stranded in a transient state no verb accepted | the runners covered `active`/`error`/`manageable` and not `deploying` |
| 6 | the documented driver name `image+measured` never resolved | the test typed the *filename*, and `test-deploy-rollback.sh` **asserted the bug** |
| 7 | measured kernel's NIC drivers were modular; the node measured perfectly and could not report it | an initramfs carries no modules, and no test booted that kernel with a NIC |
| 8 | `udhcpc` obtained the lease and threw it away (script at a path that busybox does not consult) | the test recorded the missing address as a *limitation of slirp* — a caveat nobody checked |
| 9 | `pcrs.expected` outlived the build it was captured from | so `verify` passed, the node was wiped and re-imaged, and the refusal arrived **after** the destructive write |
| 10 | `error_reason` was never written by a failed deploy | three verbs maintained the field and the fourth did not, so it showed an older incident |
| 11 | a second deploy passed its health gate on the **first** deploy's console banner | the console log is append-only across boots; fixtures were pre-written, proving only that `grep` works |
| 12 | the registry said `firmware bios` for a domain whose XML said `<os firmware='efi'>` | an enroll-time default nobody revisited; only `show` reads the field, so nothing failed |
| 13 | a second deploy **never rebooted the node** — `bootdev pxe` applies at the next boot, and a running node ignores `power on` | hidden by #11: the dishonest gate reported `active` in one second and survived every run |
| 14 | the attestation signature was truncated at its first NUL — `busybox wget --post-file` sends `Content-Length=strlen()` | the delivery test used `curl --data-binary`, which is binary-safe; the node has no curl |
| 15 | `mlbuild.sh` reported **failure for successful builds** (3 sites) — a terminal `[[ … ]] && cmd` under `set -e` | `all` silently never packed an initramfs, and printed nothing; `set -e` exits quietly |

**The two shapes.** All but a couple are either *a record that outlived the thing it
described* (#9, #10, #11, #12, and a stale `~/.cache` image plus a served kernel that
`file -b` could not distinguish from its replacement) or *a test that asserted the
mechanism instead of the outcome* (#6, #7, #8, #14). Both are authoring mistakes, which
is why more tests of the same kind would not have found them.

**And the ordering rule, learned the hard way twice.** #13 was *hidden* by #11: the
dishonest gate reported success in one second and survived every run, while the honest
gate's nineteen minutes of silence diagnosed itself. Fixing the liar does not fix the
fault underneath — it makes the fault visible. That is why **LIED** outranks **HALTED**
on the chaos ladder.

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
- ~~**`image` has never touched a real node.**~~ **DONE 2026-07-28 (night)** — a
  deployer ramdisk streamed a 200 MiB golden Alpine raw onto node2's disk and the
  node booted it to `node2 login:` (`active (image/golden-alpine)`, `<boot dev='hd'/>`,
  663 MB written to vda). New pieces: [`deployer-init.sh`](deployer-init.sh) (streams,
  never buffers; parks on failure rather than rebooting into a re-imaging loop),
  `--init` on [`build-probe-initramfs.sh`](build-probe-initramfs.sh) so the deployer
  reuses the probe's hard-won verification, and
  [`run-e2e-image.sh`](run-e2e-image.sh). **Four defects, none of which the green
  suite could see** — three found by reading the real seam before the run, one by the
  run itself:
  1. the driver issued `power cycle`, which **vbmcd does not implement** ("Invalid
     data field in request") — it would have died at its last step, *after* the
     destructive write. The mock implemented `cycle` happily; `MOCK_BMC_NO_CYCLE=1`
     now reproduces the real BMC's refusal.
  2. `imgverify disk <sig>` named an image **iPXE never downloaded** (the ramdisk
     fetches the raw with `wget`); the firmware would have refused an unknown image
     and booted nothing. It now verifies what iPXE *does* fetch — the signed deployer
     kernel+initrd — and the raw is verified where it can be: on the node, after the
     write.
  3. no `ip=dhcp` on the deployer's cmdline, so the kernel left `eth0` down and the
     ramdisk **hung with no output at all** — indistinguishable from a slow write, so
     the operator waits out the whole write timeout. (Diagnosed by `domblkstat`: zero
     writes, no HTTP connection. The same `ip=dhcp` lesson this repo already learned
     in the pxeboot lab.) The network step now proves it has an address or refuses.
  4. the read-back sha256 check **silently downgraded itself to a warning** on the
     first real run: it parsed the byte count from `dd`'s status line, which busybox
     dd does not print. The driver now passes `maas.bytes=` and a missing byte count
     is fatal — an unverified disk is not a successful deploy. **The harness caught
     this one on itself**: every step of that run succeeded and the node reached
     `active`, and `run-e2e-image.sh`'s verdict still reported FAIL, because the
     console carried no proof of verification. The second run printed
     `verified: the bytes on /dev/vda match the published sha256` and passed.
- **The deployer ramdisk gets a POOL address, not the node's reservation.** Observed
  live: `eth0 = 192.168.123.31` where node2's reservation is `.102`. dnsmasq keys the
  reservation on the DHCP hostname/MAC pair and the ramdisk sends no hostname, so it
  lands in the dynamic range. Harmless today — the deployer only needs to reach the
  payload server — but anything that ever keys off the deploying node's address (a
  callback, an ACL, a metadata lookup) would be surprised. Fix shape: `udhcpc -x
  hostname:$node`, or drop the reservation requirement entirely.
- **`image+measured`: the measuring payload is BUILT and proven; the live fleet run
  is not done.** Picked up 2026-07-28 (night). What the investigation found is worth
  more than the increment:

  **The BIOS fleet cannot measure a payload at all.** Measured under swtpm:

  | experiment | result |
  |---|---|
  | two different golden images (96 MB vs 160 MB) | **PCR4 identical** |
  | same image, files swapped INSIDE the filesystem | **every PCR identical** |
  | UEFI/UKI, one byte of kernel cmdline changed | **PCR4 and PCR9 both move** |

  SeaBIOS measures the boot-sector code (PCR4) and the partition table (PCR5) and
  nothing in the filesystem, so a PCR policy over a BIOS boot **blesses any
  payload** — a gate that looks like measured boot and proves nothing about what
  ran. Shipping that would have been the LIED rung inside the control plane. The
  honest path is UEFI: the firmware measures the binary it loads, and a UKI makes
  kernel+initramfs+cmdline one measured object.

  **Built and proven headless** ([`tests/test-measured-image.sh`](tests/test-measured-image.sh),
  5 sections incl. the anti-theatre and determinism checks):
  [`build-golden-measured.sh`](build-golden-measured.sh) (UEFI ESP + UKI via
  `ukify`, rootless and loop-free), [`measure-init.sh`](measure-init.sh) (reads real
  PCRs from `/sys/class/tpm/tpm0/pcr-sha256/`, signs the quote **on the node** with a
  bundled openssl, delivers by MAC, parks rather than claiming attestation it did not
  achieve), `verify-lib.sh gen-ak` (a dedicated attestation leaf — a key baked into
  every copy of an image must not be the key that signs what the fleet boots), and
  `--add` on the initramfs builder.

  **Also found:** neither existing payload can measure anything — Alpine's cloud
  images ship the **`-virt` kernel flavour with no TPM drivers at all**, and
  micro-linux's kernel has none either. The AlmaLinux 9 netboot vmlinuz (already
  staged for the install driver) has TPM support built in, which is why the UKI uses
  it. And an init that writes to `/tmp` when the initramfs has no `/tmp` **exits, and
  an init that exits is a kernel panic** — the builder now creates it and verifies it.

  **The fleet-side pieces are now built too** (2026-07-28, night): `FLEET_TPM=1`
  on [`create-fleet.sh`](create-fleet.sh) via [`lib/tpm_xml.py`](lib/tpm_xml.py),
  which sets a TPM **and** UEFI together and refuses to set one without the other
  (a TPM on a BIOS domain yields quotes that verify, match, and mean nothing);
  **quote delivery endpoints** in [`lib/metadata.py`](lib/metadata.py)
  (`POST /quote/<mac>` + `/quote-sig-b64/<mac>` — base64 since 2026-07-29, because
  `busybox wget --post-file` sends `Content-Length=strlen()` and truncated the DER
  signature at its first NUL; the raw `/quote-sig/` endpoint remains for clients that
  can post binary, and now refuses a DER blob shorter than its own header declares —
  keyed by MAC because a measured image
  is generic — until this landed nothing in the lab could write `quote.json`, so
  the driver's gate was real and unfeedable); `image-measured.sh capture-policy`
  (trust-on-first-use, pinning only PCR4+PCR7 and refusing a quote with a hole in
  it); and [`run-e2e-measured.sh`](run-e2e-measured.sh), which drives three
  deploys — refused with no policy, activated against a captured policy, and
  **refused again** against a bent one, because zero refusals is also what a gate
  that never refuses anything reports.

  **The first live attempt (2026-07-28, night) got through preflight, build, stage
  and the sink, and then found two more things** — neither visible headlessly:

  1. **`image+measured` refuses at `verify`, before any hardware.** Correct, and the
     runner assumed otherwise: it waited for a quote from a node that had never been
     powered on. The policy cannot come from a measured deploy (the gate refuses an
     image with no policy — that is the point), so the **enrollment boot now uses the
     plain `image` driver**: identical lay-down, identical payload, no gate. Observe
     what it measures, pin that, then enforce — which is how it works in life.
  2. **A UEFI node cannot netboot this fleet's deployer.** The network hands every
     client `boot.ipxe`, an iPXE *script*, which works only because a BIOS node's
     option ROM chainloads it; a UEFI firmware would TFTP the script and try to
     execute it as a binary. The measured node must be UEFI (or it measures
     nothing), so the two requirements collide.

  **The UEFI netboot path is now BUILT** (2026-07-29), and writing it found that the
  two-line fix this file previously prescribed was wrong in both lines:

  - **It pointed at the wrong binary.** This file said `ipxe.efi` was "already built,
    at `~/netboot/ipxe.efi`" — that is the RAM-infra lab's *generic* build: no
    `IMAGE_TRUST_CMD`, no fleet CA. TFTP it to the measured node and everything goes
    green while the firmware half of F2 is silently switched off on the one node whose
    entire purpose is proving a machine refuses what the fleet did not sign. The
    **verifying** binary existed all along: `netboot/build-ipxe.sh` emits `ipxe.efi`
    beside the option ROM from the *same* build, so the ROM build had already produced
    one — `build-verifying-rom.sh` just never installed it.

    | binary | `imgverify` | fleet CA |
    |---|---|---|
    | `~/netboot/ipxe.efi` | ✗ | ✗ |
    | `~/.cache/lab-create/maas/ipxe/ipxe.efi` | ✓ | ✓ |

    Guarded now by **`build-verifying-rom.sh check-efi`**, which refuses before the
    copy. It looks for the CA's **SHA-256 fingerprint**, because that is how iPXE's
    `TRUST=` actually embeds a root — not the certificate, which is why searching for
    the subject or the DER finds nothing in a perfectly good binary. (EFI only: the
    option ROM is compressed, so every such search comes up empty on a working ROM.)

  - **The dnsmasq snippet chainloads forever.**
    `dhcp-match=set:efi64,option:client-arch,7` + `dhcp-boot=tag:efi64,ipxe.efi` hands
    `ipxe.efi` to a client that is *already running* `ipxe.efi`: it boots, does its own
    DHCP, is still architecture 7, and loads itself again. The BIOS path never showed
    this because a script is executed, not re-loaded. iPXE announces itself in DHCP
    option 77, so the tag must mean "EFI firmware that is **not** already iPXE":

    ```
    dhcp-match=set:efi64,option:client-arch,7
    dhcp-match=set:efi64,option:client-arch,9
    dhcp-userclass=set:ipxe,iPXE
    tag-if=set:efi-fw,tag:efi64,tag:!ipxe      ← the loop break
    dhcp-boot=tag:efi-fw,ipxe.efi
    ```

    Both directions are proven against a **real dnsmasq answering real DHCP packets**
    in [`tests/test-uefi-netboot-dhcp.sh`](tests/test-uefi-netboot-dhcp.sh) — including
    §3, which runs the naive config and asserts the loop, so the guard is demonstrated
    to be load-bearing rather than assumed. It is rootless and hermetic: dnsmasq needs
    `NET_ADMIN`, so it runs inside an `unshare -rn --map-auto` namespace (`--map-auto`
    matters — a plain `unshare -r` denies `setgroups()` and dnsmasq dies dropping
    privileges). [`tests/dhcp-probe.py`](tests/dhcp-probe.py) is the client, because no
    ordinary DHCP client will lie about its architecture on request.

  New pieces: [`lib/dnsmasq_arch_xml.py`](lib/dnsmasq_arch_xml.py) (the rewrite, third
  sibling of `rom_xml.py`/`tpm_xml.py`, and the **single source of truth** for the
  option list — the test feeds dnsmasq the same lines the network gets),
  `build-verifying-rom.sh install-efi` / `check-efi`, and
  `netboot-chain.sh install-uefi`, which refuses a non-enforcing binary, refuses while
  fleet domains are running (the network restart drops their links and does not
  restore them), and afterwards **verifies the options are live in libvirt's rendered
  dnsmasq config** rather than trusting that a definition libvirt accepted took effect.

  **Per-node firmware, also fixed.** `FLEET_TPM=1` applied to the whole fleet, which is
  how node1 and node2 ended up on UEFI their BIOS-installed disks cannot boot. It now
  takes node names — `FLEET_TPM=node3`, `FLEET_TPM=node2,node3` — with `1`/`all` kept
  (it is in existing scripts and notes) but warning. A name matching **no** node is
  refused outright: it would equip nobody, say nothing, and surface an hour later as
  "the node never delivered a quote", which reads as a payload bug and sends you
  debugging the wrong half of the lab. Covered by
  [`tests/test-fleet-tpm-selection.sh`](tests/test-fleet-tpm-selection.sh), including
  the prefix trap (`node1` must not match `node10`).

  **A third defect, found by the first run with all of the above in place**
  (2026-07-29): node3 booted to the **EFI internal shell**, no PXE attempt at all,
  despite `bootindex=1` on its NIC. OVMF's `NetworkPkg` has the PXE stack, but the
  driver for the card comes from the card's UEFI option ROM — and this lab attaches a
  **legacy-only** verifying ROM over QEMU's `efi-e1000.rom`, leaving a UEFI firmware
  with no network device at all. Nothing errored; the run just waited for a quote from
  a machine sitting at a firmware prompt. A measured node now uses **virtio with no
  option ROM** (OVMF drives it natively), which is also what makes the loop break
  matter: OVMF's PXE client sends no iPXE user-class, so it is handed the verifying
  `ipxe.efi` rather than the script. Leaving the *stock* iPXE oprom would be worse
  than either — it announces itself as iPXE, gets the script, and has no `imgverify`.
  `lib/tpm_xml.py` had **no test at all** before this, which is the honest reason it
  reached a live run; [`tests/test-tpm-xml.sh`](tests/test-tpm-xml.sh) is red against
  the code that shipped it.

  **A fourth defect, from the next run** (2026-07-29): with the NIC fixed, the run
  reached deploy #1 and the state machine correctly refused —
  `cannot 'deploy' node 'node3' from state 'deploying'`. The *previous*, interrupted
  attempt had left the node stranded mid-transition, and **neither runner handled a
  transient state**: `run-e2e-image.sh` covered `active`/`error`/`manageable`,
  `run-e2e-measured.sh` covered nothing, two copies of one idea drifted apart. The
  refusal was right; it just arrived after the fleet rebuild, the UKI build, staging,
  signing and the sink. Now one shared [`lib/e2e-common.sh`](lib/e2e-common.sh)
  `make_deployable`, called early in both preflights, recovering through the control
  plane's own `abort` → `retry` → `provide` and **saying so** rather than quietly
  tidying up after a run that did not finish. Guarded by
  [`tests/test-e2e-make-deployable.sh`](tests/test-e2e-make-deployable.sh).

  **A fifth defect, and the run that found it got furthest of all** (2026-07-29). With
  the state recovered and the digest fixed, the node laid the image down, verified it,
  rebooted, **measured 10 real PCRs on a TPM 2.0 and signed its own quote** — then had
  no network interface to deliver it from (`udhcpc: SIOCGIFINDEX: No such device`,
  `mac=`). The two kernels available *at the time* had exactly complementary gaps:
  AlmaLinux 9.8 (the UKI's, chosen for its built-in TPM) kept its **NIC drivers modular**
  for dracut, while micro-linux (the deployer's) had the NICs built in and **no TPM at
  all**. (Both halves live in one micro-linux kernel since 2026-07-29 — see "The durable
  fix" below; everything in this paragraph is the record of the interim, not the current
  shape.) The measuring initramfs is busybox and loads no modules. Interim fix: the build lifts
  `failover`/`net_failover`/`virtio_net` out of the matching netboot initrd and
  **refuses unless they match the kernel's own version string** (a mismatch is
  `insmod: invalid module format`, i.e. the same silent no-network symptom one layer
  down). `measure-init.sh` now separates "no interface exists" from "no lease", and
  refuses to POST a quote with an empty MAC. Proven headless by
  [`tests/test-measured-image.sh`](tests/test-measured-image.sh) §4b, whose VM gets a
  virtio NIC so `eth0` exists only if the module truly loaded.

  **A sixth defect, immediately behind it.** With the modules loading, DHCP then
  *succeeded* and the address was never applied: `lease of 192.168.123.103 obtained`
  followed by `addr=none`. `udhcpc` configures nothing itself — it execs a script — and
  the initramfs installed that script at micro-linux's path (`/usr/share/udhcpc/`) while
  bundling the **host's** busybox, which Ubuntu compiles to look in `/etc/udhcpc/`. No
  script, no error, lease discarded. It had been latent in `deployer-init.sh` all along,
  masked because that kernel's built-in `virtio_net` lets the KERNEL's `ip=dhcp` do the
  job before init runs. Now shipped at both paths, `-s` passed explicitly by both inits,
  and named specifically by `measure-init.sh`. It had also fooled
  `tests/test-measured-image.sh`, which recorded the missing address as a limitation of
  `restrict=on` slirp — a caveat that was never checked and was simply wrong; §4b now
  asserts a real address.

  **A seventh and eighth defect, from the run after that** (2026-07-29). The node
  measured, signed and **delivered** its quote, the policy was captured from that very
  boot — and deploy #2 died at
  `maas: deploy: 'image+measured' is a documented fast-follow (not yet implemented)`,
  a sentence that had been false for weeks. `deploy` resolved a driver as
  `$MAAS_DRIVER_DIR/$driver.sh`, so the documented name `image+measured` looked for
  `drivers/image+measured.sh` (the file is `image-measured.sh`) and fell through to a
  stale `case` arm. The mapping was open-coded in **four** places and three were wrong,
  including the **rollback** path — a node deployed as `image+measured` could never have
  been rolled back. One `driver_path()` helper now owns it.

  **Why nothing caught it, which is the more useful half.**
  `tests/test-image-measured-driver.sh` drives the driver as `image-measured` — the
  *filename* — while README, DEFERRED, MANUAL_TESTING and `run-e2e-measured.sh` all say
  `image+measured`. The suite was green for weeks on a name no operator would type. And
  `tests/test-deploy-rollback.sh` **asserted the bug**: it required the refusal to say
  "fast-follow", so fixing the driver turned the suite red — a test pinning a temporary
  claim in place long after it stopped being true. Both are corrected: §2b now drives the
  *documented* name against the same fixture, and the rollback test asserts the durable
  behaviour (an unknown driver is refused by name, listing what exists) with a negative
  control against ever calling an unknown name a not-yet-implemented roadmap item.

  **The durable fix was micro-linux + TPM — ✅ BUILT 2026-07-29.**
  `micro-linux/mlbuild.sh` sets and asserts `TCG_TPM`/`TCG_TIS`/`TCG_CRB` beside the
  `VIRTIO_NET`/`E1000` lines it already asserted — the same "an initramfs carries NO
  MODULES" rule that file already documented for NICs, applied to the TPM (`=y` is not a
  preference: a modular TPM is indistinguishable from none). The kernel was rebuilt and
  **proven by boot, not by config**: `tpm_tis MSFT0101:00: 2.0 TPM (device-id 0x1,
  rev-id 1)` with all four PCR banks readable under swtpm.

  So the golden image now uses **one kernel with both halves** — the same one the
  deployer, the inspection probe and the ramdisk catalog already used, for the first time.
  Deleted with it: `MAAS_MEASURED_MODULES`, the kernel-version guard, `nic-load-order`,
  the `insmod` loop, and **two** `~/netboot/` dependencies (a 15 MB `vmlinuz` and a 223 MB
  `initrd.img`, both outside the repo and both in the periodic reclaim path). Net **−15
  lines** while adding capability.

  Kept deliberately: [`measure-init.sh`](measure-init.sh) still separates "no interface
  exists" from "an interface exists but got no lease" (different faults, different fixes,
  and collapsing them cost a live run), now pointing at `VIRTIO_NET=y` rather than at
  bundled modules.

  Two defects fell out of the rebuild — `mlbuild.sh` reporting failure for successful
  builds (#15), and `tests/test-probe-nic.sh` sitting on disk **in no list**, so nothing
  ran it. It guards the exact fault class this lab keeps rediscovering and now runs in
  the suite; a test with no runner is a test nobody runs.

  **The live run itself — ✅ PASSED 2026-07-29** (§15 of
  [`MANUAL_TESTING.md`](MANUAL_TESTING.md)). For a fleet that is already up, it is just
  `./run-e2e-measured.sh`; from cold, the sudo-gated prerequisites are:

  ```bash
  ./build-verifying-rom.sh install-efi     # the VERIFYING ipxe.efi into the TFTP root
  ./create-fleet.sh down                   # install-uefi restarts the network
  ./netboot-chain.sh install-uefi          # arch-conditional DHCP
  FLEET_TPM=node3 ./create-fleet.sh up
  ./run-e2e-measured.sh
  ```

  The honest framing stays exactly as `drivers/image-measured.sh` states it: swtpm is
  faithful plumbing and the AK is baked into the image, so this proves the MECHANISM
  and the REFUSAL PATH, never the integrity of a machine.
- ~~**`install.sh`'s ownership test is narrow on purpose.**~~ **CLOSED 2026-07-28** by
  [`install-catalog.toml`](install-catalog.toml) — the per-driver catalog this item
  asked for. `describe` now answers positively (cataloged, or staged in the driver's
  own kernel+initrd+ks.cfg shape) and refuses both the ramdisk triple **and** an
  image no driver has claimed.
- **`describe` is asked of every driver by `gate`, but only `ramdisk` and `install`
  answer meaningfully.** `image` and `image+measured` still accept any image name.
