# Review — Phase 7 (`phase7-firecracker/lab-fc.sh`)

**Date:** 2026-08-16
**Scope:** Phase 7 only — `lab-fc.sh` (658 LOC as reviewed), its `tests/`, and the
shared harness-net checker as it applies to Phase 7. Audited for **safety**
(host damage), **soundness** (correctness/data-integrity), **security**
(isolation/injection), and **feature completeness**.
**Method:** the driver read end-to-end; **every finding reproduced from the running
script before being recorded**, with a control, and every fix re-verified by reverting it
in a copy of the driver and watching the new assertion bite. This pass ran unprivileged —
deliberately, since that is how the phase's own suite runs, and since none of these defects
needs root. Phase 7 is the first phase to get a per-phase review; the six that came before
it are [`REVIEW-phase1.md`](REVIEW-phase1.md) …
[`REVIEW-phase6b.md`](REVIEW-phase6b.md).

---

## 1. Verdict

Phase 7 is the youngest driver in the repo and, in its documentation, the most
self-aware: every field of the generated `config.json` carries a provenance tag,
`preflight` is *the same function* `create` runs rather than a prediction of it,
`UNKNOWN` is a verdict distinct from `ok`, `stop` refuses to call a signal a stop,
and `destroy` deliberately does **not** delete the tap because the fabric owns it.
Those are the right instincts and they are written down in the file.

They are also, in six places, only written down. The residue is **six real defects**,
two of which make a `[[microvm]]` spec — a *configuration file* — a way to run
arbitrary commands or reconfigure the VMM, and one of which makes `destroy` an
`rm -rf` of any directory you can name.

> **Status 2026-08-16: all six are FIXED**, each with a regression test carrying its own
> **negative control**, and each fix additionally verified by re-injecting the original
> defect into a copy of the driver and watching the named assertion fire. **§3's six minor
> items are fixed too**, along with **§3b** — two of the phase's six tests had never run
> *anywhere*, on this host or in CI, since the phase was written. The suite went
> **4 passed / 2 skipped of 6 → 13 passed / 0 skipped / 0 failed of 13**.

- **P7-1 (HIGH)** — ✅ **FIXED.** A config value reaches `$(( ))`. `memory =
  "BASH_VERSINFO[$(…)]G"` **executes**, during `preflight` — the verb whose entire promise
  is that nothing has happened yet — and the gate then prints `ok  memory 5120 MiB`.
- **P7-2 (HIGH)** — ✅ **FIXED.** `config.json` is built by raw string interpolation. An
  `append =` value injected a top-level `"vsock"` device — a host unix socket the guest can
  reach — as **valid JSON**, and the provenance table reported nothing.
- **P7-3 (HIGH)** — ✅ **FIXED.** The instance name is a path component and four verbs never
  validated it. `destroy ../../<dir>` `rm -rf`'d a directory outside the state dir and
  printed `PASS: destroyed`.
- **P7-4 (MED)** — ✅ **FIXED.** `start` reported `PASS: started <name> (pid N)` on the
  strength of a fork returning. Against a config Firecracker refuses: `PASS`, rc 0, and
  `Error: Invalid JSON` in the log. **Fix the liar first.**
- **P7-5 (MED)** — ✅ **FIXED.** One pidfile, three answers. With an unrelated `sleep`'s pid
  in `fc.pid`: `list` → running, `start` → "already running", `stop` → "was not running".
- **P7-6 (MED)** — ✅ **FIXED.** The record encoding is `k=v;` split on `;`, so a `;` in any
  value is a second key. `append = "quiet;mmds=true"` switched MMDS on; `append =
  "quiet;name=HIJACKED"` changed the instance name — both past a gate whose stated purpose
  is refusing what it does not understand.

Two suspicions were **investigated and cleared** by measurement — recorded in §4 so they
are not re-raised, since both are things a careful reader would suspect again.

**The recurring shape, for the seventh review running:** *a guard that exists in the
codebase, absent from one of its call sites.* P7-3's regex was in `preflight_checks`;
P7-5's identity check was in `_kill_recorded`; P7-4's "assert the outcome, not the
mechanism" lesson is written **in a comment inside `cmd_stop`, twenty lines below the
`cmd_start` that had not learned it**. Every fix here moves the guard to where the thing is
*selected* or *constructed*, not to each caller.

---

## 2. Findings

### P7-1 — HIGH — a config value reaches bash arithmetic — ✅ FIXED 2026-08-16

`mem_to_mib` accepts Phase 2's memory spelling (`256`, `256M`, `1G`) and converts the
gigabyte form with arithmetic:

```sh
mem_to_mib() {
    local m="$1"
    case "$m" in
        *G|*g) printf '%s' $(( ${m%[Gg]} * 1024 )) ;;
        …
}
```

Bash arithmetic evaluates **array subscripts** with full expansion, so a value shaped like
`NAME[$(command)]` runs the command substitution. `preflight` calls `mem_to_mib` on the raw
config value before any gate has passed.

**Reproduced (unprivileged, inert payload):**
```
$ cat inj.toml
[[microvm]]
name = "t1"
kernel = "…/vmlinux"
rootfs = "…/rootfs.ext4"
memory = "BASH_VERSINFO[$(echo INJECTED-ARITH > /tmp/PWNED)]G"

$ lab-fc.sh preflight --config inj.toml
  ok       memory 5120 MiB                 <-- the gate is happy
$ cat /tmp/PWNED
INJECTED-ARITH                             <-- the command ran
```

`set -u` looks like it covers this and does not. It stops the `a[$(…)]` form — the variable
is unset, so bash errors first — but **not** `EUID[$(…)]` or `BASH_VERSINFO[$(…)]`, which
name variables that exist. Both were measured executing. A fix (or a test) written against
only the unset-name form would have looked complete.

`create --dry-run` runs the same function, so "`--dry-run` writes nothing" was true and
beside the point: the interesting thing had already happened.

> **Fixed** by checking the shape before the arithmetic ever sees it: the digits are matched
> with a regex, `10#` guards a leading zero (`08G` used to be an *octal* error), and
> anything else is returned unchanged so the existing `memory must be an integer >= 64` gate
> refuses it — a refusal by the gate that already exists, rather than a second silent one
> inside the converter.
>
> Regression: [`tests/test-no-shell-eval-of-config.sh`](phase7-firecracker/tests/test-no-shell-eval-of-config.sh).
> Three injection shapes (including both that `set -u` does not stop), both entry points
> (config file and `--memory`), a **negative control** that runs the pre-fix `mem_to_mib`
> and *fails the test if it does not execute the payload* — so the assertions are known to
> be capable of failing on this bash, on this host — and a control that `128M 1G 2g 512 08G`
> all still convert. Re-injecting the original into the driver made section 1 bite.

### P7-2 — HIGH — `config.json` is assembled by string interpolation — ✅ FIXED 2026-08-16

`gen_config` writes the document Firecracker is handed with a heredoc:

```sh
  "boot-source": {
    "kernel_image_path": "$kernel",
    "boot_args": "$args"
  },
  …
    { "iface_id": "eth0", "host_dev_name": "$tap", "guest_mac": "$mac" }
```

No escaping, anywhere. A value containing `"` closes its string; the rest of the value is
then *document structure*.

**Reproduced:**
```
$ lab-fc.sh create --dry-run --name t1 --kernel K --rootfs R \
      --append 'quiet"}, "vsock": {"guest_cid": 3, "uds_path": "/tmp/INJECTED.sock"}, "x": {"a": "b'
…
$ python3 -c 'import json;c=json.load(open("cfg.json"));print(list(c))'
['boot-source', 'drives', 'vsock', 'ignored', 'machine-config']
```

Not a syntax error — **valid JSON**, with a `vsock` device (a host unix socket path the
guest can reach) that the operator never wrote. And `WHAT THIS TOOL DID THAT YOU DID NOT
TYPE` — the provenance table, this tool's entire product — reports nothing, because as far
as it is concerned that text is your boot argument.

Phases 3, 4 and 5 each grew exactly this escaping in the fortnight before this review
(P3's export hardening, P4-5, P5-2). Phase 7 was the fourth emitter of a structured
document from user scalars and the only one still raw.

> **Fixed** with a `json_str` escaper applied at all four interpolation sites. Pure bash on
> purpose: this driver's only hard dependencies are `awk`/`sed`/`file`, and a config
> generator that needs `jq` in order to be safe is not safe on a host without `jq`.
>
> Regression: [`tests/test-config-json-escaping.sh`](phase7-firecracker/tests/test-config-json-escaping.sh).
> It asserts **byte-identical round-trip**, not "no injection" — P5-2's lesson, paid for
> once already: an assertion that only checks for an injected key and for the substrings
> passes over an emitter that *corrupts* the value. Six hostile-but-legal values, the
> measured `vsock` payload verbatim, and — because a fix applied to `boot_args` alone would
> pass all of that — the **network block too**, which needs a real tap with the right owner
> and no IPv4 to reach. That is staged inside `unshare -rmn` with a sysfs remount, so an
> unprivileged run can create a tap named `tap"weird` in a namespace that evaporates with
> the subshell; if unprivileged userns is unavailable the section reports **UNKNOWN by
> name** rather than passing quietly. A control asserts an ordinary spec is unchanged
> (numbers still numbers, booleans still booleans). Reverting all four call sites in the
> driver made it bite on the `vsock` assertion.

### P7-3 — HIGH — the instance name is a path component, unvalidated in four verbs — ✅ FIXED 2026-08-16

```sh
fc_dir() { printf '%s/%s' "$LAB_FC_STATE_DIR" "$1"; }
cmd_destroy() {
    local name="$1" d; d="$(fc_dir "$name")"
    [[ -d "$d" ]] || die "no such instance: $name"
    _kill_recorded "$name" KILL >/dev/null || true
    rm -rf "$d"
```

`preflight_checks` gates the name with `^[a-z][a-z0-9-]{0,30}$` — but only `preflight` and
`create` run `preflight_checks`. `start`, `stop`, `destroy` and `inspect` take
`${positional[0]}` and paste it into a path.

**Reproduced:**
```
$ mkdir -p …/trav/precious && echo IRREPLACEABLE > …/trav/precious/data.txt
$ lab-fc.sh destroy ../../trav/precious
PASS: destroyed ../../trav/precious (its tap, if any, belongs to the fabric and was left alone)
$ ls …/trav/precious
ls: cannot access: No such file or directory
```

This is Phase 1's P1-1 in a different costume — there, a name *synthesised from a path* was
used as a manifest key and `destroy` orphaned an unrelated managed chroot. Same lesson,
same fix shape.

> **Fixed** at two points, both deliberate. The `fc_dir` **accessor** refuses an invalid
> name, so a verb added later is safe by *default* rather than by someone remembering — the
> reasoning Phase 1's P1-1 fix records. And `main` validates the positional where the name
> is **selected**, because the accessor guard alone is not enough: `cmd_stop` reaches
> `fc_dir` through `p="$(_kill_recorded …)"`, and **a `die` inside `$( … )` exits only the
> command substitution** — measured here, with the caller going on to print `PASS: … was
> not running`. The repo has that gotcha written down and it still cost a run.
>
> Regression: [`tests/test-instance-name-is-validated.sh`](phase7-firecracker/tests/test-instance-name-is-validated.sh)
> — all four verbs, a bystander directory that must survive, four non-traversal shapes
> (absolute, `-`-leading, embedded slash, over-long), a **control** that a legal name is
> still resolved/listed/destroyed (a guard that refused every name would pass everything
> else), and a **negative control** that resolves the pre-fix accessor's path and fails if
> it does *not* reach the bystander. Reverting both guards made it bite.

### P7-4 — MED — `start` asserts the mechanism, not the outcome — ✅ FIXED 2026-08-16

```sh
setsid firecracker --no-api --config-file "$(fc_config "$name")" > "$(fc_log …)" 2>&1 < /dev/null &
printf '%s\n' "$!" > "$(fc_pidfile "$name")"
printf 'PASS: started %s (pid %s), console -> %s\n' …
```

`$!` says bash created a process. It says nothing about whether Firecracker accepted the
config, opened the kernel, or is still alive a moment later.

**Reproduced**, with a VMM that refuses the config and exits 1:
```
$ lab-fc.sh start k1
PASS: started k1 (pid 3989863), console -> …/fc.log     ; rc 0
$ cat …/fc.log
Error: Invalid JSON: expected value at line 1
$ lab-fc.sh stop k1
PASS: k1 was not running (nothing to signal)             ; rc 0
```

Two `PASS` lines and no virtual machine. What makes this the sharpest finding in the set is
that **the lesson is already in the file** — in `cmd_stop`, twenty lines below:

> *"ASSERT THE OUTCOME. Sending a signal is not stopping a VM; the first version of this
> printed PASS on the strength of kill(2) returning 0…"*

Learned on `stop`, never carried to its sibling. `examples/micro-cloud/`'s edge test had
even worked around the consequence — *"KILLING THE WRAPPER IS NOT KILLING THE VM"* — without
the gap being named.

> **Fixed:** `start` polls for the outcome (returns the moment the process is recognisably
> this instance's VMM, gives up the moment it is gone), and on failure prints `FAIL`, the
> tail of the console log, and **removes the pidfile** so the next `list` is not reading a
> record of something that never existed. The success line now says *"process confirmed
> running, not merely forked"*, because a claim that cannot be distinguished from the old
> behaviour is not worth making.
>
> Regression: [`tests/test-lifecycle-asserts-the-outcome.sh`](phase7-firecracker/tests/test-lifecycle-asserts-the-outcome.sh)
> §1–2, with a stand-in VMM whose behaviour is chosen per-invocation (`die`, `deaf`, `run`).
> A stand-in is the *right* seam here and not a compromise: the question is "what does this
> tool report when the VMM does X", and a real Firecracker cannot be made to die on demand.
> What it does not prove — that a microVM boots — is covered by
> [`examples/micro-cloud/tests/test-edge-on-the-fabric.sh`](examples/micro-cloud/tests/test-edge-on-the-fabric.sh),
> with a real VMM.

### P7-5 — MED — one pidfile, three answers — ✅ FIXED 2026-08-16

`_kill_recorded` checks *identity* before signalling:

```sh
grep -qa firecracker "/proc/$p/cmdline" 2>/dev/null || return 1   # identity, not just liveness
```

`cmd_start` and `cmd_list` do not — they ask `[[ -d "/proc/$p" ]]`, which is true of every
process on the box.

**Reproduced**, with an unrelated `sleep 600`'s pid written into `fc.pid`:
```
$ lab-fc.sh list          -> k1               running
$ lab-fc.sh start k1      -> lab-fc.sh: 'k1' is already running (pid 4020101)
$ lab-fc.sh stop k1       -> PASS: k1 was not running (nothing to signal)
```

Three verbs, one pidfile, one instant, three answers. A recycled pid is not exotic: `start`
records `$!` and any failure to exec (P7-4) leaves that number free to be reused within
seconds.

The check that *did* exist was also too weak — `grep -qa firecracker` cannot tell **this**
instance's VMM from another instance's, so a pid recycled onto a *different* microVM would
have been signalled.

> **Fixed** with a single `_running_pid` used by all four verbs, bound to the instance by
> its own config path (which is in `firecracker`'s argv and unique per instance), not by the
> word "firecracker".
>
> Regression: same file, §4 — a foreign pid (all verbs must agree it is not ours, and the
> foreign process must be untouched) **and** a second instance's real VMM recorded against
> the first (which `grep -qa firecracker` alone cannot distinguish). Reverting the identity
> lines made `list` report `running` and the test bite.

### P7-6 — MED — a `;` in any value is a second key — ✅ FIXED 2026-08-16

A `[[microvm]]` block is flattened to `k=v;k=v;…` and split back apart on `;`:

```sh
rec = rec key "=" val ";"                                   # awk
v="$(printf '%s' "$rec" | tr ';' '\n' | sed -n "s/^${key}=//p" | head -1)"
```

So a `;` inside a value is not a quoting nuisance — it is a key the `KNOWN_KEYS` gate never
sees, because that gate validates the keys in the **file**, and this one arrives afterwards.

**Reproduced:**
```
append = "quiet;mmds=true"      -> lab-fc.sh: mmds = true needs a tap (MMDS is reached over a NIC)
append = "quiet;name=HIJACKED"  ->   FAIL     name 'HIJACKED' must be lowercase alnum/dash…
```

The first switched a device on. The second changed the instance's identity — and it is
**order-dependent**, since `field` takes the first match: with `append` before `name` the
injected name wins, with it after the real one does. Worse than uniformly wrong.

This is the tool's own tripwire, from its own header — *"a config key that is silently
dropped is a field that appears to work and does nothing"* — turned around: a key that was
never declared and works anyway.

> **Fixed** by refusing `;` and control characters in a value, **by name**, at both entry
> points: in the awk parser (before the record exists) and in `main`'s argv path, which
> builds its own record and is the path `examples/micro-cloud/` actually uses. Control
> characters are refused for a second reason — see §3's provenance item.
>
> Regression: [`tests/test-record-encoding.sh`](phase7-firecracker/tests/test-record-encoding.sh).
> Note the assertion **order** there, which was got wrong first: with the guard removed the
> run still exits non-zero (the injected name fails the name regex), so a message-shaped
> assertion placed first reports *"refused but not explained"* about a run whose real defect
> is that the injection worked. The sharp assertion — *the name gate ran at all* — goes
> first. A control confirms an ordinary kernel command line (`= , : / . |`) is untouched.

---

## 3. Minor / robustness (not security) — ✅ ALL FIXED 2026-08-16

- **`--force` was a knob that did nothing.** It is in `USAGE` for `stop` and `destroy`, it
  is **recommended by `stop`'s own failure message** (`"…ignored SIGTERM after 5s — still
  running. Use --force."`), it is passed by the repo's only consumer
  (`examples/micro-cloud/`'s cleanup calls `stop api1 --force` **and** `destroy api1
  --force`) — and `main` discarded it with `: "$force" "$lab"`. The advice was untrue at the
  moment the operator most needed it to be true.

  > **Fixed** with a real meaning on both verbs: `stop --force` escalates to `SIGKILL` and
  > confirms the process is gone; `destroy` now **refuses a running instance** unless
  > `--force` is given, which completes the pair with `create`'s existing refusal to
  > overwrite. `start --force` is new and documented — it is the way past the digest gate
  > below. Asserted in `test-lifecycle-asserts-the-outcome.sh` §3 and §5, with a
  > SIGTERM-deaf stand-in and an assertion that the fixture really is deaf (or the section
  > proves nothing).

- **`--lab` was parsed and thrown away; `--mac` and `--netmask` had no flag at all.**
  `--lab MY-OWN-LAB` wrote `lab = "micro-cloud"` — the default — into the manifest and said
  nothing. Two `KNOWN_KEYS` were expressible in TOML and not on the command line.

  > **Fixed** by building the CLI record from one derived loop. Regression:
  > [`tests/test-cli-vs-config-parity.sh`](phase7-firecracker/tests/test-cli-vs-config-parity.sh),
  > which reads `KNOWN_KEYS` **out of the driver** rather than restating it — a hand-copied
  > list here would be a second source of truth going stale silently, which is the defect
  > being fixed one level up. It asserts every key has a flag, every flag reaches the
  > manifest or the config, and — the strongest form — that **one spec written both ways
  > generates a byte-identical `config.json` and a byte-identical provenance table**. A
  > control proves the default `lab` differs from the flag's value, so the row is evidence
  > rather than a coincidence.

- **The provenance table mis-columned any value containing `|`.** It joined its three
  columns with `|` and split them with `IFS='|' read`. `append = "mc_name=a|b"` — an
  ordinary boot argument, and micro-cloud's actual spelling — rendered as field
  `boot_args: mc_name=a`, why `b|your append…`. The table whose entire job is to report
  what the tool did to your value misreported the value.

  > **Fixed** by joining on US (`0x1f`), which cannot appear because control characters are
  > now refused at the entry point — so the separator is a guarantee rather than a hope.

- **An inline TOML comment landed inside the value.** `name = "t1"   # the api node` was
  read as the name `t1"   # the api node`, so the tool refused a valid spec and complained
  about the **name**. Fail-closed for `name` (the regex catches it); silent for `append`.

  > **Fixed** in the awk reader: a quoted value ends at its closing quote, a bare one ends
  > at the first `#`. A control asserts a `#` **inside** a quoted value survives — the naive
  > fix (strip from the first `#`) breaks that.

- **A digest was recorded and never read.** `create` writes `rootfs_source_sha256`, and
  [`MICRO_CLOUD_LAB_PLAN.md`](MICRO_CLOUD_LAB_PLAN.md) says it is there *"so a re-staged
  source image is detectable instead of silent"*. `git grep` finds one writer, one test
  asserting the field is 64 hex characters, and **no reader**. The test asserted the
  *mechanism* (a field exists, shaped like a digest) rather than the *outcome* (a swap is
  refused) — the second of CLAUDE.md's two bug classes, inside a guard against the first.

  Meanwhile the **kernel** — which `config.json` points at *by path* rather than copying,
  and which this repo genuinely rebuilds between runs — had no digest at all. Overwriting
  it and re-running every verb produced no complaint from any of them.

  > **Fixed:** `create` records `kernel_sha256`; `start` re-derives it and **refuses by
  > name, printing both digests**, before anything is spawned; `--force` is the documented
  > way past and says so. Only the kernel is gated at `start`, deliberately — the rootfs
  > copy is booted read-write, so its digest is *expected* to change, and a gate that fires
  > on correct behaviour is a gate someone switches off. `inspect` reports both artifacts in
  > **three outcomes** (`match` / `CHANGED since create` / `UNKNOWN`), with a missing file
  > as UNKNOWN. Regression:
  > [`tests/test-recorded-digest-is-verified.sh`](phase7-firecracker/tests/test-recorded-digest-is-verified.sh).

- **`list --json` built JSON with `printf`** from a directory basename, and `list` reported
  on directories `create` could not have made.

  > **Fixed:** `list` skips names that are not valid instance names and emits the name
  > through `json_str`.

## 3b. Also fixed in the same pass — two tests that had never run anywhere

`test-config-generation.sh` and `test-rootfs-is-per-instance.sh` opened with
`require_cmd firecracker`, a `/dev/kvm` check, and two environment variables the caller had
to set to an ELF `vmlinux` and an ext4 image. Nobody set them. Both **SKIPped on this host
and on every CI run since the phase was written** — a third of the suite, inert, under a
summary line that said `0 failed`.

The precondition was itself the defect, which is the usual finding. **Neither test boots
anything**: one runs `create --dry-run` and parses stdout, the other runs `create` and reads
three files. They demanded a VMM because `preflight`'s *version gate* does — a question
about the **host**, standing in for artifacts about the **spec**.

`tests/lib.sh` now grows `fc_fixtures`, which builds what they actually need: an ELF kernel
(the system `bash` is one), a real ext4 with a real `/sbin/init` via `mke2fs -d` (no root,
no loop mount), and — only when no real pinned Firecracker is installed — a stand-in on
`PATH` that answers `--version` and nothing else, announcing itself in a `note`. A real
Firecracker still wins when present, and the caller's `FC_TEST_KERNEL`/`FC_TEST_ROOTFS`
still win over the built fixtures.

**Said out loud, since a stand-in that is not labelled is a lie:** this proves nothing about
whether Firecracker accepts the config or whether the microVM boots. Those need a VMM and
are covered by `examples/micro-cloud/tests/test-edge-on-the-fabric.sh`, which boots `api1`
through this tool for real. The residual precondition here is `/dev/kvm` being read-write,
because `preflight`'s KVM gate is a real gate and `create` cannot complete without it; a
host without it now gets a **named** skip saying exactly that.

To be exact about what the two skips cost: neither would have caught P7-2 on its own, since
a benign spec emits valid JSON either way. The cost was subtler and worse — no test in the
phase had ever parsed a generated config or exercised `create`'s write path, so nobody had
reason to look at how one was built.

**Phase 7 tests: 13 passed, 0 skipped, 0 failed** — from 4 passed / 2 skipped of 6 when this
review was written.

## 4. Investigated and cleared (so it is not re-raised)

- **`set -e` and a trailing `A && B` inside an `if` body.** `cmd_list` and `cmd_start` both
  end a `then` branch with `[[ … ]] && var=x`. The natural reading is that a false condition
  makes the `if` return 1 and `errexit` kill the script silently — a stale pidfile would
  then make `list` print nothing and exit non-zero. **Measured, and it does not:** bash
  exempts the failing command of an `&&` list from `errexit` unless it is the command
  *following the final* `&&`. `list`, `list --json` and `start` all behaved correctly with a
  stale pid. Reasoning said one thing and the shell said another; the shell wins.

- **`setsid` forking and orphaning the recorded pid.** `setsid` forks when the caller is
  already a process-group leader, which would make `$!` a short-lived parent and the pidfile
  point at nothing. **Measured:** in a non-interactive shell the background child is not a
  group leader, so `setsid` execs in place and `$!` is Firecracker's pid. Not a defect —
  but P7-4's fix removes the dependence on that being true, since `start` now confirms the
  recorded pid is this instance's VMM rather than assuming it.

- **Bare `$(…)` inside `$(( … ))`.** Worth recording because it is why P7-1 needs a specific
  shape: a command substitution arriving via a *parameter expansion* is **not** re-expanded
  (`$(( $(cmd)1 * 1024 ))` from a variable is a syntax error, and the command does not run).
  Only the array-subscript path executes. A reader who tests the obvious form and sees it
  fail may conclude, wrongly, that the function is safe.

## 5. Feature completeness

Phase 7's declared surface is small and honest: eight verbs, thirteen schema keys, and two
things it explicitly refuses to do — manufacture taps (the fabric owns them, and two owners
for one resource is the stale-record bug this repo keeps finding) and offer a `root=` knob
Firecracker would silently override. Both refusals are enforced, not merely documented, and
both have negative controls.

Two gaps were real and are now closed:

- **No `README.md` and no `MANUAL_TESTING.md`** — Phase 7 was the only phase with neither,
  which is also why its `[[microvm]]` schema had no worked example anywhere in the repo (the
  only consumer, `examples/micro-cloud/`, drives it entirely through flags). Both are now
  written, and `MANUAL_TESTING.md` carries the reproduction for **every finding above** so
  each can be re-run by hand; every command in it was executed while writing it, and two
  numbers in its success signature were corrected because the measured output disagreed
  with what had been typed.

  > **Deliberately not done, so it is a decision and not an omission:** Phase 7 still has no
  > routed spec under `examples/`, the way phases 1–5 do. Its only consumer,
  > `examples/micro-cloud/`, is `coverage_exempt` in
  > [`examples/learning-paths.toml`](examples/learning-paths.toml) as *"under construction"*,
  > and adding a lab unit into a staging area — which `tools/paths.py --check` would then
  > require routing into a journey — is a catalog decision rather than a phase-7 defect. The
  > worked schema lives in the phase's own `README.md` until micro-cloud's remaining slices
  > land.
- **Two hand-written test counts in prose** (`examples/bmc-toolkit/tests/lib.sh`,
  `examples/micro-cloud/README.md`) said "4" and "5". Both are gone — the repo's rule is a
  ratio printed by the runner, not an integer copied into a document.

`mmds` is V2-only (V1 would answer any GET unauthenticated), `smt` is forced off, and the
`ip=`-without-a-NIC refusal encodes a measured 23× boot regression. No missing feature rises
to a finding.

## 6. Calibration — good patterns preserved

`preflight` genuinely *is* the function `create` runs, asserted structurally by comparing
the two verbs' gate lines rather than by trusting the comment; the three-outcome `/sbin/init`
gate, which exists because an earlier version confidently reported "no `/sbin/init`" about an
image that had booted minutes earlier; the per-instance rootfs copy with an in-code assertion
that the generated config points at the copy and not the source; `create` refusing to
overwrite; the tap treated as an input and validated (existence, **owner**, and no IPv4 —
because `ip tuntap add` returning 0 says nothing about the `TUNSETIFF` the VMM will issue);
kill-by-PID everywhere with an explicit note about the `pkill -f` incident; the parser
refusing an unknown key *and stopping the run*, asserted by outcome after an earlier version
refused inside a process substitution and carried on. The six defects above are edge holes
in otherwise-sound guards, or guards that exist one call site away — not absent guards.
