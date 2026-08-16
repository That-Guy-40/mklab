# Phase 7 — Manual Testing Walkthrough

Copy-pasteable exercise of `lab-fc.sh`. Part 1 needs nothing but the repo and a shell;
part 2 needs a real Firecracker, a real kernel and a real rootfs, and is the only part that
boots anything. Part 3 re-runs, **by hand**, every defect the
[2026-08-16 review](../REVIEW-phase7.md) found — because a fix nobody can reproduce a break
against is a fix nobody can check.

> **Set up a working dir:**
> ```bash
> cd /media/sqs/COLD_STORAGE/LAB_CREATE_V2
> alias fc='phase7-firecracker/lab-fc.sh'
> export LAB_STATE_DIR="$(mktemp -d)/state"     # never touch your real instances
> ```

---

## 0. The automated suite

```bash
phase7-firecracker/tests/run-all.sh
```

**Success signature:**

```
summary: 13/13 discovered tests ran (13 test files on disk) — 13 passed, 0 skipped, 0 failed
```

If any test **skips**, the runner names the file and the `SKIP:` line above says why. The
only preconditions left are `/dev/kvm` being read-write for you (preflight's KVM gate is a
real gate and `create` cannot complete without it) and `e2fsprogs` for `mke2fs`/`debugfs`.

> **What the suite does NOT prove.** No test here boots a virtual machine. When a real
> Firecracker at the pinned version is not on `PATH`, `tests/lib.sh` puts a **stand-in** on
> it that answers `--version` and nothing else, and says so in a `note`. That is the right
> seam for the questions these tests ask — *is the generated document well-formed? does the
> record describe the file the VM would boot? what does the tool report when the VMM dies?*
> — and a real Firecracker cannot be made to die on demand anyway. The question it cannot
> answer is whether Firecracker **accepts** the config, which is what part 2 and
> [`examples/micro-cloud/tests/test-edge-on-the-fabric.sh`](../examples/micro-cloud/tests/test-edge-on-the-fabric.sh)
> are for.

---

## 1. Dry runs — no VMM, no root, nothing written

`create --dry-run` runs every gate, generates the config, prints the provenance table, and
writes nothing. Stage two throwaway artifacts first — any ELF is a valid "kernel" as far as
the generator is concerned, and `mke2fs -d` builds an ext4 with an init without root or a
loop mount:

```bash
W=$(mktemp -d)
cp "$(command -v bash)" "$W/vmlinux"                  # an ELF
mkdir -p "$W/rfs/sbin" && cp /bin/true "$W/rfs/sbin/init"
truncate -s 16M "$W/rootfs.ext4" && mke2fs -q -F -t ext4 -d "$W/rfs" "$W/rootfs.ext4"
```

Without Firecracker installed the version gate refuses, correctly. Put a stand-in on `PATH`
for this section only — and notice that the tool offers no flag to point at a binary,
deliberately:

```bash
mkdir -p "$W/bin"
cat > "$W/bin/firecracker" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && { echo "Firecracker v1.16.1"; exit 0; }
echo "stand-in: refusing to pretend to boot" >&2; exit 70
EOF
chmod +x "$W/bin/firecracker"; export PATH="$W/bin:$PATH"

fc create --dry-run --name api1 --kernel "$W/vmlinux" --rootfs "$W/rootfs.ext4" --memory 128M
```

**Success signature** — nine `ok` gate lines, a JSON block, and:

```
WHAT THIS TOOL DID THAT YOU DID NOT TYPE:
  WHERE FROM FIELD = VALUE                 WHY
  ...
  APPENDED  boot_args: root=/dev/vda rw    FIRECRACKER adds this after ours; ...
  REFUSED   boot_args: root=<yours>        not offered as a knob — ...

DRY RUN: nothing written. 10 field(s) came from somewhere other than your spec.
```

### 1a. The two refusals that encode measurements

```bash
fc preflight --name api1 --kernel "$W/vmlinux" --rootfs "$W/rootfs.ext4" --append 'root=/dev/vdb'
fc preflight --name api1 --kernel "$W/vmlinux" --rootfs "$W/rootfs.ext4" --ip 10.71.0.11
```

```
FAIL     append contains root= — Firecracker appends its own root=/dev/vda AFTER ours ...
FAIL     ip=10.71.0.11 is set but no tap is configured — this costs ~23x boot time ...
```

### 1b. `UNKNOWN` is not a pass

Point it at a file that is emphatically not a filesystem, so `debugfs` cannot open it:

```bash
echo 'this is not a filesystem' > "$W/notfs.ext4"
fc preflight --name api1 --kernel "$W/vmlinux" --rootfs "$W/notfs.ext4"
```

The `/sbin/init` gate must say **`UNKNOWN … /sbin/init NOT verified`** — *not* "rootfs has
no /sbin/init". "I could not look" is a different answer from "I looked and it is missing",
and conflating them invents a specific defect. (That is not hypothetical: an earlier version
did exactly that about an image which had booted minutes earlier.)

### 1c. The two spellings must agree

```bash
cat > "$W/api1.toml" <<TOML
[[microvm]]
name    = "api1"
kernel  = "$W/vmlinux"
rootfs  = "$W/rootfs.ext4"
memory  = "128M"          # inline comments are comments
append  = "mc_name=api1"
TOML
diff <(fc create --dry-run --config "$W/api1.toml") \
     <(fc create --dry-run --name api1 --kernel "$W/vmlinux" --rootfs "$W/rootfs.ext4" \
                 --memory 128M --append 'mc_name=api1') && echo "IDENTICAL"
```

---

## 2. A real microVM

Needs a real Firecracker at the pinned version, an **uncompressed ELF `vmlinux`** (not a
`vmlinuz` — Firecracker's loader is ELF-only and answers a bzImage with
`Elf(InvalidElfMagicNumber)`), and an ext4 rootfs with an init.
[`phase1-chroot`](../phase1-chroot/) produces exactly that image:

```bash
phase1-chroot/lab-chroot.sh export-rootfs <name> --output "$W/real-rootfs.ext4"
```

```bash
export PATH="/path/to/firecracker/dir:$PATH"
fc create  --name api1 --kernel /path/to/vmlinux --rootfs "$W/real-rootfs.ext4"
fc start   api1
fc list
fc inspect api1
fc stop    api1
fc destroy api1
```

**Success signature:**

```
PASS: created .../fc/api1
      rootfs is a per-instance copy of ... (source sha recorded)
      kernel stays where it is, bound to this instance by sha256 — `start` refuses a swapped one
  - kernel sha256 matches the one recorded at create
PASS: started api1 (pid 12345) — process confirmed running, not merely forked; console -> .../fc.log
api1             running
PASS: api1 (pid 12345) stopped — process confirmed gone, not merely signalled
```

Watch the boot on the console log:

```bash
tail -f "$LAB_STATE_DIR/fc/api1/fc.log"
```

### 2a. With a NIC

`lab-fc.sh` never makes taps. Bring one up with the fabric first, then hand it over:

```bash
sudo examples/micro-cloud/fabric.sh up
sudo examples/micro-cloud/fabric.sh tap api1
fc create --name api1 --kernel /path/to/vmlinux --rootfs "$W/real-rootfs.ext4" \
          --tap mc-api1 --ip 10.71.0.101 --gateway 10.71.0.1 --lab micro-cloud
```

The MAC the tool will set must equal the one the fabric reserved a lease against, or the
guest takes a *dynamic* lease while dnsmasq goes on answering the name with an address
nothing holds — invisible from either tool alone:

```bash
diff <(fc mac api1) <(examples/micro-cloud/fabric.sh mac api1) && echo "AGREE"
```

---

## 3. Reproducing the 2026-08-16 findings by hand

Each of these **must now refuse**. To watch one of them break instead, copy the phase
directory, revert the named fix in the copy, and re-run against `<copy>/lab-fc.sh` — which
is exactly how each fix was verified.

> ⚠️ Every payload below is **inert** — it writes a marker file. Never put a real
> destructive verb in test data: a `$(reboot)` inside a double-quoted `printf` in an inner
> `bash -c` once actually rebooted this machine.

### P7-1 — a config value must not reach `$(( ))`

```bash
rm -f /tmp/PWNED
fc preflight --name t1 --kernel "$W/vmlinux" --rootfs "$W/rootfs.ext4" \
             --memory 'BASH_VERSINFO[$(echo INJECTED > /tmp/PWNED)]G'
cat /tmp/PWNED 2>&1      # must be "No such file or directory"
```

Expected: `FAIL  memory 'BASH_VERSINFO[...]G' must be an integer >= 64 MiB`, and **no
marker file**. Before the fix this printed `ok  memory 5120 MiB` and the command ran.

### P7-2 — `config.json` must be JSON, not string concatenation

```bash
fc create --dry-run --name t1 --kernel "$W/vmlinux" --rootfs "$W/rootfs.ext4" \
  --append 'quiet"}, "vsock": {"guest_cid": 3, "uds_path": "/tmp/INJECTED.sock"}, "x": {"a": "b' \
  | sed -n '/^{/,/^}/p' \
  | python3 -c 'import json,sys; c=json.load(sys.stdin); print("top-level keys:", list(c))'
```

Expected: `['boot-source', 'drives', 'machine-config']`. Before the fix this was valid JSON
containing `vsock` — a host unix socket the guest can reach, from a boot-argument string.

### P7-3 — the instance name is not a path

`fc_dir` pasted the name straight after `$LAB_STATE_DIR/fc/`, so the bystander goes exactly
where `../../precious` resolves to from there:

```bash
V="$LAB_STATE_DIR/../precious"                   # == $LAB_STATE_DIR/fc/../../precious
mkdir -p "$V" && echo IRREPLACEABLE > "$V/data.txt"
fc destroy ../../precious
ls "$V"
```

Expected: `lab-fc.sh: invalid instance name '../../precious' — must match
^[a-z][a-z0-9-]{0,30}$`, and `data.txt` still there. Before the fix:
`PASS: destroyed ../../precious`, and it was gone. Try `start`, `stop` and `inspect` with
the same argument too — the guard is at the accessor, not in one verb.

### P7-4 — `start` must prove the VM is running

```bash
cat > "$W/bin/firecracker" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && { echo "Firecracker v1.16.1"; exit 0; }
echo "Error: Invalid JSON: expected value at line 1" >&2; exit 1
EOF
fc create --name t1 --kernel "$W/vmlinux" --rootfs "$W/rootfs.ext4"
fc start t1; echo "rc=$?"
```

Expected: `FAIL: t1 did not start — firecracker is not running`, the console log echoed
back, `rc=1`, and **no pidfile left behind**. Before the fix: `PASS: started t1 (pid …)`,
`rc=0`, and then `stop` saying `PASS: t1 was not running`. Two passes, no VM.

### P7-5 — one pidfile, one answer

```bash
sleep 600 & echo $! > "$LAB_STATE_DIR/fc/t1/fc.pid"
fc list ; fc stop t1
```

Expected: `t1  stopped` and `PASS: t1 was not running`, and the `sleep` untouched. Before
the fix `list` said `running`, `start` refused as "already running", and `stop` said "was
not running" — three answers, one instant.

### P7-6 — a `;` in a value is not a second key

```bash
fc preflight --name t1 --kernel "$W/vmlinux" --rootfs "$W/rootfs.ext4" --append 'quiet;mmds=true'
```

Expected: a refusal naming the key and the record separator, before any gate line prints.
Before the fix this switched MMDS on; `--append 'quiet;name=HIJACKED'` changed the
instance's identity.

### §3 — the recorded digest is compared

```bash
fc create --name t1 --kernel "$W/vmlinux" --rootfs "$W/rootfs.ext4"
cp /bin/false "$W/vmlinux"          # different bytes, still a valid ELF
fc start t1; echo "rc=$?"
fc inspect t1 | grep _check
```

Expected: `REFUSING to start 't1': the kernel … is not the one it was created against`, with
**both digests printed**, and `kernel_check = "CHANGED since create"`. `--force` starts it
anyway and says that it did. Before the fix every verb carried on in silence.

---

## 4. Cleanup

```bash
fc list --json
for n in $(fc list --json | python3 -c 'import json,sys;[print(i["name"]) for i in json.load(sys.stdin)]'); do
    fc destroy "$n" --force
done
rm -rf -- "$W" "$LAB_STATE_DIR"
```

If a stand-in VMM is still running, resolve it to a **PID** and kill that — never
`pkill -f` on the instance path, which matches every process whose command line carries it,
including the workload you are protecting:

```bash
pgrep -af firecracker          # look at the hits first
kill <pid>
```
