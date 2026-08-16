# Review — Phase 2 (`phase2-qemu-vm/lab-vm.sh`)

**Date:** 2026-08-12
**Scope:** Phase 2 only — `lab-vm.sh` (3761 LOC), its `tests/`, and the shared
harness-net checker as it applies to Phase 2. Audited for **safety** (host
damage), **soundness** (correctness/data-integrity), **security** (isolation/
injection), and **feature completeness** — the same axes and format as
[`REVIEW-phase1.md`](REVIEW-phase1.md).
**Method:** the driver read end-to-end; every finding reproduced from the
running script (this pass ran as root) with a control before being recorded.
Builds on [`REVIEW-phases-1-5.md`](REVIEW-phases-1-5.md) (2026-07-08) and
[`AUDIT.md`](AUDIT.md) — the M4 manifest-injection and H2 loop-device items
there were re-checked against today's code.

---

## 1. Verdict

Phase 2 is as disciplined as Phase 1 and then some: `set -euo pipefail`,
TOML→JSON→`jq` (no `eval`/`source`), a strict `validate_vm_name` regex gating
every path built from a name, the H2 loop-device build wrapped in a
subshell+EXIT trap (verified correct), comma-injection guards on
mac/bridge/tap/pxe_dir/peer_link, `StrictHostKeyChecking=accept-new` with a
per-VM `known_hosts`, an AF_UNIX socket-path length preflight, and the
peer-link feature that *cannot spell an address* so it can never widen host
exposure. The suite is green here (6 pass / 13 self-skip on missing
qemu/qemu-img/ISO tools / 0 fail).

The residue is **two real defects**, both of a shape the repo already names in
CLAUDE.md and both reproduced:

- **P2-1 (MED)** — the numeric/enum manifest fields (`cpus`, `cores`,
  `threads`, `ssh_port`, `memory`, `microvm`) are **never validated numeric**.
  Written unquoted and un-`_mf_clean`'d, a newline in one **injects manifest
  lines** that flip `network_mode`/`tap`/`disk` on re-read (the M4 class,
  reopened); a comma injects **`-smp` / `hostfwd` sub-options** (the Finding-8
  class, applied to the other comma-fields but missed on these).
- **P2-2 (MED)** — ✅ **FIXED 2026-08-15.** `stop`/`destroy`/the swtpm reaper trust `qemu.pid` as an
  **identity**. A stale pidfile (QEMU was SIGKILLed or the host crashed) plus a
  recycled PID makes `vm_running` report a false positive and `stop`/`destroy`
  **SIGKILL an unrelated process** — as root for sudo-run VMs. The "record that
  outlives the thing it describes" class.

One suspicion — the `RETURN` trap at `lab-vm.sh:1423`, which the codebase's own
comments call a bug class — was **investigated and cleared** (§4).

Phase 2 addresses VMs strictly by validated name (no path argument), so the
Phase 1 **P1-1** basename-collision class does **not** exist here.

---

## 2. Findings

### P2-1 — MED — unvalidated numeric/enum fields inject manifest lines and QEMU sub-options

`write_vm_manifest` writes the numeric/enum fields **unquoted and without
`_mf_clean`** (lines ~362–380):

```sh
cpus        = ${MF_CPUS}
microvm     = ${MF_MICROVM}
ssh_port    = ${MF_SSH_PORT}
cores       = ${MF_CORES:-0}
threads     = ${MF_THREADS:-0}
```

The M4 fix (2026-07-08) added `_mf_clean` (strip CR/LF, then escape `"`) to the
*free-text* fields, on the stated assumption that "Enum/numeric fields can't
carry these." But nothing validates them: `create_one` extracts each with a
bare `cpus="$(spec_get "$spec" cpus)"` (lines ~2554, 2572–2575) and no
integer check exists anywhere between `spec_get` and the manifest write
(`grep` for a numeric assertion on cpus/memory/cores/threads returns nothing).
A TOML config supplies these as **strings**, so a newline rides straight
through.

**Facet (a) — manifest-line injection (M4 class). Reproduced** at the vulnerable
seam:

```
$ MF_CPUS=$'2\nnetwork_mode = "tap"\ntap = "evil0"'  write_vm_manifest victim
$ grep -n 'network_mode\|tap' victim/manifest.toml
10:network_mode = "tap"      # <- injected, appears BEFORE...
11:tap = "evil0"
31:network_mode = "user"     # <- ...the legitimate line
$ read_manifest_field victim network_mode   # -> tap
$ read_manifest_field victim tap            # -> evil0
```

`read_manifest_field`'s awk takes the **first** match and `exit`s, so the
injected line wins. A field that looks like a CPU count silently reconfigures
the VM's networking on every subsequent `start`/`inspect` — exactly the M4
impact (`build_qemu_argv` reads `network_mode`/`tap` and honors them).

**Facet (b) — QEMU sub-option injection (Finding-8 class).** `build_qemu_argv`
builds a comma-separated `-smp` string (line ~2232) and a `hostfwd` string
(line ~2472) from these fields with **no comma guard**, unlike the mac/bridge/
tap/pxe_dir fields right beside them (lines 2399–2413):

```sh
smp="${cpus},cores=${_c},threads=${_t}"          # comma in cpus/cores/threads → extra -smp opts
netdev="user,id=net0,hostfwd=tcp:127.0.0.1:${ssh_port}-:22"   # comma in ssh_port → extra netdev opts
```

**Reproduced end-to-end** the manifest injection stopped only where the sandbox
lacks an ISO maker; the seam proof above plus the absent-validation grep make
the reachability unambiguous.

**Fix direction:** validate `cpus`/`cores`/`threads`/`ssh_port`/`memory` as
integers (and `microvm` as a bool) in `validate_spec`, before `create` writes
anything — the same "refuse before the expensive step" rule the MAC check
already follows there. That closes both facets at once.

### P2-2 — MED — `stop`/`destroy` trust the pidfile as identity → can SIGKILL an unrelated process — ✅ FIXED 2026-08-15

> **Fixed** by deriving identity instead of trusting the number. `_pid_owns PID PROGRAM
> MARKER` reads `/proc/PID/cmdline` and requires both `qemu-system` and **this VM's own
> pidfile path** — a path that is unique per VM and that `build_qemu_argv` already puts on
> the command line unconditionally (`-pidfile "$(vm_pidfile "$name")"`). Nothing new is
> cached, so there is no second record to go stale in turn; verified against a **real
> daemonized** `qemu-system-x86_64` that `/proc/PID/cmdline` survives `-daemonize`, and
> that it is world-readable, so an unprivileged `list` still sees a sudo-started VM.
>
> Applied at **three** sites — `_running_at`, `stop_swtpm` (both named in this finding), and
> **`start_swtpm`'s "already alive?" check**, which the finding did not name and which fails
> the *other* way: with a bare `kill -0`, a recycled swtpm PID reads as "already running", so
> the verb returns success **without starting a TPM** and QEMU launches against a control
> socket nothing is serving. A false success is worse than a failure to start.
>
> **A trap introduced by the fix, and caught by its own control:** `cmd_list` iterates
> `"$store"/*/`, so `_running_at` receives its argument **with a trailing slash**. Left in, the
> marker became `…/name//qemu.pid`, matched nothing, and every genuinely-running VM read
> `stopped`. Measured both ways — the guard is load-bearing, and §2 of the test asserts
> through `list` specifically so it stays that way.
>
> Regression: [`phase2-qemu-vm/tests/test-pidfile-identity.sh`](phase2-qemu-vm/tests/test-pidfile-identity.sh) —
> six sections, three of them controls: the impostor is not killed; a **real** QEMU is still
> listed running and stopped normally (falling back to an argv-shaped stand-in, labelled as
> one, where qemu is not installed); the launcher still emits the marker the check matches;
> the swtpm reaper likewise; and a **negative control** that re-injects the pre-fix check and
> watches it reap the unrelated process.
>
> **The fix broke two existing tests, and they deserved it.** `test-inspect-json.sh` and
> `test-snapshot.sh` fabricated "running" by writing **the test's own PID** (`$$`) into
> `qemu.pid` — the P2-2 defect restated as a fixture, asserting the *mechanism* ("some live
> pid is recorded") rather than the outcome ("this VM's QEMU is running"). They kept passing
> for a shell that was never a plausible QEMU and failed the moment the driver got stricter:
> CLAUDE.md's bug class #2, in the direction it warns costs a day. Both now use
> `fake_qemu_for` in `tests/lib.sh`, a stand-in whose **argv** looks like the VM's QEMU —
> honestly labelled as a stand-in, with the real-binary evidence kept in the new test.
>
> Phase 2 suite: **19 passed, 1 skipped, 0 failed** (20 files, 20 ran; the skip is the
> loop-mount test, which needs real root — `unshare -rm` grants no loop devices).

`_running_at` (lines 404–413) is the single source of truth for "is this VM
running", used by `stop`, `destroy`, `inspect`, and `list`:

```sh
pid="$(cat "$pf" 2>/dev/null || true)"
[[ "$pid" =~ ^[0-9]+$ ]] || return 1     # Finding 16: integer only
[[ -d "/proc/$pid" ]]                     # ...and the PID is alive
```

It stops one check short of identity: it never verifies the process at that PID
is **this VM's QEMU**. QEMU with `-pidfile -daemonize` removes the pidfile on a
*clean* exit, but not when SIGKILLed (which `cmd_stop` itself sends after its
30s timeout), OOM-killed, or lost to a host crash — so a stale `qemu.pid` is
reachable. Once the kernel recycles that PID to an unrelated process,
`vm_running` returns a false positive and `cmd_stop`/`cmd_destroy` send it
`SIGTERM`→`SIGKILL`.

**Reproduced (as root):**
```
$ sleep 600 &                 # an innocent NON-QEMU process; pid 8694
$ echo 8694 > .../vms/ghost/qemu.pid
$ vm_running ghost            # -> TRUE   (cmdline is literally "sleep 600")
$ lab-vm stop ghost --force
[info] killing ghost (pid 8694)
[info] ghost stopped
# the sleep was terminated — an unrelated process reaped by "stop ghost"
```

For a `from-chroot`/`tap` VM (created and torn down under `sudo`), the victim
is killed **as root**. This is the CLAUDE.md "record that outlives its subject"
shape — the recorded PID outlives the QEMU it described, and nothing re-checks
whose PID it now is. `stop_swtpm` (lines 2175–2186) has the identical gap: it
`kill -TERM`s the recorded swtpm PID guarded only by `kill -0`.

**Fix direction:** before killing, confirm identity — cheapest is to read
`/proc/$pid/cmdline` and require it to contain `qemu-system` **and** this VM's
socket/pidfile path (the pidfile path is already unique per VM); or record and
compare `/proc/$pid` start-time (field 22, which `inspect` already reads).
Fall through to "not running, clearing stale pidfile" when identity fails,
rather than killing.

---

## 3. Minor / robustness (not a standalone finding)

- **`_safe_rm_rf_vm` lacks the `_mounts_under` fail-closed check `_safe_rm_rf`
  has in Phase 1.** It is currently safe because nothing bind-mounts under a
  VM's state dir (the `from-chroot` build mounts a throwaway `mktemp -d`, not
  the VM dir). Noted only so the invariant "no mounts ever live under
  `vm_dir`" stays a conscious one; if a future backend mounts inside the VM
  dir, `destroy`'s `rm -rf` would inherit the Phase 1 H1 hazard.
- **`memory` feeds `-m "$memory"` as a single argv element** — a bad value
  makes QEMU error rather than injecting, so it is lower-risk than the
  comma-string fields, but folding it into the P2-1 integer check costs
  nothing and removes the last unvalidated numeric.

## 4. Investigated and cleared (so it is not re-raised)

- **The `RETURN` trap at `lab-vm.sh:1423`** (`trap "rm -rf '$work'" RETURN` in
  `build_alpine_microvm_initramfs`). The codebase elsewhere (`make_seed_iso`'s
  header, the H2 rationale) asserts "RETURN traps in bash are global and fire
  for every later function return." **Measured — that is not true of default
  bash:** without `set -o functrace`, a RETURN trap fires only on *its own
  function's* return, not on nested `inner()` returns. A control
  (`builder` sets the trap, then calls `inner1`/`inner2`) showed `$work`
  surviving until `builder` itself returned, cleaned exactly once. It is
  additionally set inside a command-substitution subshell (`initrd="$(build_…)"`,
  line 2698), so it cannot leak to the parent shell at all. Benign — the
  double-quoted form also pre-expands `$work`, so there is no out-of-scope
  reference. (The broader claim in those comments is worth softening, but the
  H2 subshell+EXIT conversion is still correct on its own merits.)

## 5. Feature completeness

Phase 2's surface is complete and coherent: three backends (disk-image with
cached+sha256-verified cloud images, kernel+initrd with an auto-built Alpine
microvm path, from-chroot → bootable BIOS qcow2), six arches with a per-arch
firmware/machine/cpu table and kvm↔tcg auto-selection, cloud-init NoCloud seed,
swtpm vTPM (honestly documented as *not* a trust anchor), UEFI/BIOS/Secure-Boot
selection, tap/bridge/user/peer-link networking, PXE-install and snapshot verbs,
and `inspect --json` for Phase 6. Stated limitations carry reasons in-code
(from-chroot is x86_64-only in v0.1; microvm+disk-image needs an explicit
kernel). No missing feature rises to a finding.

## 6. Calibration — good patterns preserved

The H2 loop-device build is textbook (subshell + single EXIT trap + `ok=1`
success flag, cleaning loop device *and* mount on every `die`); kill logic reads
a recorded PID rather than pattern-matching (the P2-2 gap is *identity*, not
`pkill`); comma-injection guards on the network fields; the AF_UNIX
socket-path length preflight refuses before writing state; `peer_link` is
constructed so an address cannot be expressed; `default_pubkey` matches all real
key types (M7); and `_mf_clean` correctly strips CR/LF before escaping quotes on
the free-text fields — P2-1 is that same fix simply not extended to the numeric
fields the comment assumed were safe.
