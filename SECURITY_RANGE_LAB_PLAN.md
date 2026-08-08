# Defensive Security Range Lab — Design Plan v1

> **Status**: **v1.1 — BUILD-READY** (decisions resolved 2026-08-08; proposed
> 2026-07-24 as option **E** of the "what can we compose?" survey). Anchors on `examples/root-password-reset/` (init-shell / GRUB
> recovery, ✅ Debian BIOS + UEFI variants), `examples/tiny-linux-experiments/floppinux/`
> `HASH_CRACKING.md` + `crack.py` (crack our **own** `$1$` login hash, ✅),
> `examples/chroot-breakout/` (the `breakout.c` chroot escape, ✅), and the
> container-internals labs `examples/exploring-containers/` + `examples/linux-proc-vfs-internals/`.
> Scope: bind these individually-built exercises into **one guided range** — stations
> that each attack *your own throwaway lab credential*, every one paired with the
> cryptographic/kernel **why**, all boxed in disposable targets. **Nothing built yet
> — the four §9 questions are now answered, so assembly is unblocked.**

---

## 1. What we're building

A **defensive, educational "range"**: a small set of stations where you recover,
crack, or escape *your own* throwaway lab artifacts — and, crucially, learn the
mechanism that made each possible and the control that would have stopped it. The
exercises already exist as separate labs; what's new is a **unifying spine** — a
range driver that stands each target up in a disposable box, a consistent
"objective → do it → *why it worked* → *the fix*" arc, and a Phase-6 `demo-ctf`
topology (already sketched in the Phase-6 SHOWCASE) that surfaces the whole range.

```
   range.sh station <n>  ─►  disposable target (container / QEMU VM — gone on teardown)
        │
        ├─ S1  Physical recovery   root-password-reset  ─► GRUB init=/bin/bash → reset root
        │        WHY: no disk encryption ⇒ bootloader = root.  FIX: FDE + GRUB password.
        ├─ S2  Credential crypto   floppinux HASH_CRACKING ─► crack our own $1$ hash
        │        WHY: fast unsalted-era MD5-crypt.  FIX: yescrypt/bcrypt, real salts.
        ├─ S3  Weak isolation      chroot-breakout      ─► breakout.c walks out of a chroot
        │        WHY: chroot ≠ security boundary.  FIX: namespaces + pivot_root (shown).
        └─ S4  Resource / ns limits exploring-containers + proc-vfs ─► cgroup-OOM, PID view
                 WHY: unbounded cgroup ⇒ noisy-neighbour / fork-bomb.  FIX: limits (shown).

   Every target is YOUR lab's throwaway credential. Nothing here targets a third party.
```

**The teaching arc:** the fastest way to internalize a defense is to defeat its
*absence* on a machine you own, then watch the control close the hole. Each station is
red-team *technique* in service of a blue-team *lesson* — recovery, hashing, isolation,
resource control — and the range makes the throughline explicit instead of leaving it
scattered across four labs.

---

## 2. How it maps onto LAB_CREATE_V2 (reuse vs. invent)

The stations are **all built and verified**; this lab is a **spine + safety rails +
the "why/fix" framing**, not new exploits.

| Station | Status | Foundation to reuse |
|---|---|---|
| **S1** root recovery via init-shell / GRUB | ✅ verified (Debian BIOS + UEFI) | `examples/root-password-reset/` (`reset-demo*.sh`, RUNBOOKs) |
| **S2** crack our own `$1$` login hash | ✅ verified | `examples/tiny-linux-experiments/floppinux/` `HASH_CRACKING.md` + `crack.py` |
| **S3** chroot escape + what *actually* isolates | ✅ verified | `examples/chroot-breakout/` (`breakout.c`, RUNBOOK) |
| **S4** namespaces / cgroup-OOM / PID view | ✅ verified | `examples/exploring-containers/`, `examples/linux-proc-vfs-internals/` |
| Disposable target substrate | ✅ exists | Phase-1 chroot, Phase-2 QEMU VM, Phase-4 podman `--privileged` box |
| Phase-6 `demo-ctf` topology surface | ✅ sketched | `phase6-tui/SHOWCASE.md` already shows a `demo-ctf` tree |
| **A range spine (`range.sh`) + station registry** | ❌ **GAP** | — invent: stand-up / verify / teardown per station |
| **Consistent objective→why→fix scaffolding** | ❌ **GAP (crux)** | — invent: a per-station `STATION.md` shape + verifier |
| **A `demo-ctf` range topology + Phase-6 wiring** | ❌ **GAP** | — invent: a unified `range.toml` |

Host reality check: `breakout.c` escapes to the **real root of whatever it runs in** —
so S3 must **only ever** run inside the `--privileged` *throwaway container* (its own
lab already bolds this). S1's GRUB recovery drives a QEMU VM over the serial console
(the repo's serial-driver gotchas apply). Nothing in the range needs — or is permitted
— to touch the host's own credentials or storage.

---

## 3. The crux — the "why it worked / how you'd stop it" scaffold (the reusable centrepiece)

A CTF that only says "you got root" teaches a trick; a *range* teaches a **control**.
The spine's job is to make every station end in the same three beats, machine-checked
where possible:

1. **Objective** — a one-line goal (`reset root on debian-bios`, `recover the plaintext
   of our own $1$ hash`).
2. **The mechanism** — *why* the technique worked, at the level the user's
   learning-goal expects (S1: with no FDE the bootloader is a root shell; S2: `$1$` is
   unsalted-era MD5-crypt, cheap to brute; S3: `chroot` only moves `/`, it doesn't drop
   you out of the root filesystem's reach; S4: an unbounded cgroup lets one task starve
   the box).
3. **The control** — the fix that closes it, *demonstrated* not just named (S1: set a
   GRUB password + FDE and show recovery now fails; S2: re-hash with yescrypt and show
   the same cracker time out; S3: the namespaces + `pivot_root` section that *does*
   contain the escape; S4: apply the cgroup limit and watch the OOM-kill land on the
   offender, `EXIT=137`).

Each station ships a `STATION.md` in that fixed shape + a `verify` verb that asserts
the objective was met (and, for the control step, that the fix holds). This is the part
the four source labs don't share — the connective *pedagogy*, with a checkpoint, so the
range is a graded path and not a pile of demos.

---

## 4. Safety rails (load-bearing — this is a security lab)

Per CLAUDE.md's standing rules, made concrete for this lab:

- **Own-credential only, always.** Every target is a throwaway lab artifact the range
  itself creates (a `$1$` hash *we* generate, a VM *we* provision). The README states
  in bold: **this range never targets a system, hash, or account you don't own**;
  point it at nothing external.
- **Every exploit is boxed in a disposable target.** S3's `breakout.c` runs **only**
  inside the `--privileged` throwaway container and is `gone on exit`; the range driver
  refuses to build/run it outside that box. S1 drives a **VM**, never the host GRUB.
- **Never let sample/exploit data execute as a live host command.** Dangerous strings
  used as *data* (a crafted password, a payload) use inert placeholders
  (`$(echo INJECTED)`, `DANGER-PLACEHOLDER`) and single-quoted heredocs — no real
  destructive verb ever lands where an inner shell re-evaluates it (the repo's real
  `$(reboot)` incident is cited in the README as the reason).
- **Teardown is by PID / by the tool's own verb**, never `pkill -f` (the shared-cmdline
  footgun). Disposable targets vanish on `range.sh teardown`.
- **Framed as blue-team.** Every station's headline is the *defense*; the offense is
  the motivation. No detection-evasion, no third-party targeting, no persistence — the
  refusals in this repo's charter apply.

---

## 5. New components & files

| File | Type | Notes |
|---|---|---|
| `SECURITY_RANGE_LAB_PLAN.md` | **this doc** | roadmap |
| `examples/security-range/range.sh` | new | `list`/`up <station>`/`verify <station>`/`teardown`; stands each target in its disposable box, refuses S3 outside the container |
| `examples/security-range/range.toml` | new | the `demo-ctf` topology (chroot target + victim VM + tools box) mapping the four stations |
| `examples/security-range/stations/S{1..4}/STATION.md` | new | the objective→mechanism→control scaffold, one per station, each linking its source lab |
| `examples/security-range/tests/` | new | one-verdict smokes per host-safe station verifier (e.g. S2 crack-our-own-hash is fully headless); EXIT-trap net; **`REGRESSION:` prefix** where a control-holds check guards a fix |
| `examples/security-range/{README,RUNBOOK,MANUAL_TESTING}.md` | new | charter + safety rails + the graded walk + verified transcripts |
| `phase6-tui/…` | edit (optional) | wire `range.toml` as the `demo-ctf` topology the SHOWCASE already depicts |
| `examples/00-INDEX.md` | edit | one row (a new 🛡️ defensive-security cluster, cross-referencing the four source labs) |
| `examples/learning-paths.toml` | edit | route it as a **collection** ("break your own box, then fix it") bundling the four stations; observable checkpoint per station = its `verify` green line (S2: recovered plaintext; S3: `pivot_root` contains the escape; S4: `EXIT=137`). Then `paths.py render && --check`. |

The four source labs stay **standalone and unchanged**; the range *references* them
(and their already-vendored `upstream-tutorial/` provenance) — no duplication, no
re-mirror (self-containment via citation).

---

## 6. Provenance (cite-and-vendor)

- All four stations' sources are **already vendored** under their labs'
  `upstream-tutorial/` (Van Laere's *Exploring Containers* for S3/S4, the floppinux
  tutorial for S2) or documented (root-password-reset's RUNBOOKs); the range **cites**
  them (self-containment — no re-mirror).
- Crypto background for S2 (MD5-crypt `$1$` vs. yescrypt/bcrypt) → cite, don't mirror
  (URL + retrieved date): it's reference material, not one write-up.

---

## 7. Security posture (AUDIT.md alignment + charter)

- **F1 (throwaway creds).** The *entire premise* — every credential is one the range
  minted to be broken; README bolds "own systems only."
- **F7 (destructive-op guard).** Teardown/wipe is path/name-guarded and by-PID; S3 is
  container-boxed and refused elsewhere.
- **Charter compliance.** Defensive/educational, own-lab targets, no evasion, no
  persistence, no third-party targeting — squarely inside "authorized security testing
  / educational contexts," explicitly *outside* the refused categories.
- **The `$(reboot)` lesson is a first-class citizen** — the README uses this repo's
  own real incident to teach why exploit *data* must never be live host *code*.

---

## 8. Build order (dependency-aware) & verified-vs-author-run

1. **Spine + S2 (crack our own hash)** — `range.sh` + the objective→why→fix scaffold,
   proven on the **fully-headless** station (mint a `$1$` hash, crack it with `crack.py`,
   re-hash yescrypt, show the cracker time out). *Fully verifiable; the cleanest first
   station.*
2. **S3 (chroot escape + the isolation fix)** — inside the existing `--privileged`
   throwaway container, with the namespaces/`pivot_root` control step. *Verifiable in
   the container.*
3. **S4 (cgroup-OOM / ns view)** — reuse the container-internals `EXIT=137` signature
   as the checkpoint. *Verifiable (already a `verify_host=true`-style marker exists).* 
4. **S1 (physical recovery)** — drive the root-password-reset VM over serial; the
   control step sets a GRUB password + FDE and shows recovery now fails. *Verifiable in
   QEMU; long boot-cycles / UEFI variants may be **author-run** with the handed-over
   command (serial-console driving is finicky — the repo's `--echo-gate` guidance
   applies).* 

Each step ends in a POC-style writeup with real transcripts; the lab ships one-verdict
smokes + EXIT-trap net (with `REGRESSION:` on control-holds checks); both catalogs stay
green; anything env-blocked is marked author-run with the exact handed-over command.

---

## 9. Decisions — resolved 2026-08-08

Recorded as **decisions with reasons**, not deleted: an open item nobody intends to
revisit is a queue entry that never drains, and a resolved one with no reason gets
re-litigated by the next reader.

| # | question | decision |
|---|---|---|
| 9.1 | first increment scope | **the spine + S2** |
| 9.2 | Phase-6 `demo-ctf` wiring | **fast-follow**, not v1 |
| 9.3 | the red-team boundary | **written below as a charter**, before any station is added |
| 9.4 | directory name | **`examples/security-range/`** |

**9.1 — spine + S2 first.** As recommended: it is the smallest slice that is fully
headless, and it fixes the objective→why→fix template every later station copies.
Getting that template right once is worth more than getting one more station built.
Then S3/S4 (container-boxed), then S1 (VM/serial, the slowest to verify).

**9.2 — `demo-ctf` is a fast-follow.** The CLI range stands alone and is what the
checks assert against. The SHOWCASE tree promising it is a reason to build it, not a
reason to build it *first*: a demo wired to a spine that is still moving has to be
rewired every time the spine moves.

**9.3 — the boundary, stated before it is needed.** This is a **defensive** range,
and the line is drawn by *who owns the target* and *what the exercise teaches*:

- **In charter.** Attacking a credential, image, or box **this repo created to be
  destroyed**, where the lesson is the mechanism and the fix — the four stations as
  scoped. A control **proving itself** is also in (the fail2ban brute-force-lockout
  demo named in the original item): the deliverable there is evidence the control
  fires, not a working attack.
- **Out of charter, permanently.** Anything whose subject is a machine this repo did
  not create; anything about **evasion** (defeating detection), **persistence**, or
  **mass/automated targeting**; and any technique whose write-up is more useful to an
  attacker than to a defender. These are out regardless of how the lab is framed —
  "for testing" does not move the line.
- **The test to apply to a proposed station:** *could the finished artifact be
  pointed at someone else's machine with no modification?* If yes, it is not a
  station here.

**9.4 — `examples/security-range/`.** It matches this plan's filename, it is what
the routing and 00-INDEX rows will say, and it is the least misleading of the three:
`blue-team-range` claims a defensive-only posture that the stations (which do attack
things) would undercut, and `break-your-own-box` reads as an invitation to break
something that is not a lab. Picked now because the directory name is load-bearing
for `learning-paths.toml` and `link_check.py`, and renaming it later is the
repo-wide-grep task this project has a working practice about.
