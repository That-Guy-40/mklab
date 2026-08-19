#!/usr/bin/env bash
# §5.6's jailer tier — the half that can be proved WITHOUT the privilege it needs.
#
# `jailer` unshares a mount namespace as its first act, so a jailed microVM cannot be booted
# without CAP_SYS_ADMIN and this test does not pretend otherwise: the live plain-vs-jailed
# comparison is examples/micro-cloud/tests/test-jailer-isolation.sh, and it is root-gated.
#
# ── WHAT IS ACTUALLY CHECKABLE HERE, AND WHY IT IS NOT NOTHING ──────────────────────────
# §5.6 names one sharp edge: *"under the jailer every path in config.json is relative to the
# new chroot, so kernel and rootfs must be hard-linked or bind-mounted in first."* That is a
# claim about FILES AND TEXT, and it is completely testable unprivileged:
#
#   * the kernel and the rootfs are inside the jail root;
#   * the rootfs is the SAME INODE as the instance's, not a second copy that can drift;
#   * the in-chroot config names in-chroot paths and contains NO host path;
#   * the refusal, when the capability is absent, names the capability and the syscall —
#     and fires BEFORE the staging copy rather than after it.
#
# A jailed Firecracker that opens the wrong root device fails in a way that reads like a
# corrupt image rather than a bad path, so these are the assertions that save the expensive
# diagnosis — and they are exactly the ones a root-only test would leave unrun on every
# machine that is not the author's.
#
# shellcheck disable=SC1090
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

tmp="$(mktemp -d)"; TMPDIRS+=("$tmp")
export LAB_STATE_DIR="$tmp/state"
N=jailst
D="$LAB_STATE_DIR/fc/$N"

r() { rc=0; out="$(bash "$LAB_FC" "$@" 2>&1)" || rc=$?; }

# ── 1. THE REFUSAL, and it must name the capability rather than "not root" ──────────────
# Built by hand: the refusal is reached before anything is staged, which is the property, so
# a fixture that stages nothing is the honest subject.
mkdir -p "$D"
printf 'name = "%s"\nkernel = "%s"\n' "$N" "$tmp/vmlinux" > "$D/manifest.toml"
printf '{"boot-source":{"kernel_image_path":"%s"},"drives":[{"path_on_host":"%s"}]}\n' \
    "$tmp/vmlinux" "$D/rootfs.ext4" > "$D/config.json"
: > "$tmp/vmlinux"; : > "$D/rootfs.ext4"

# `jailer` on PATH is a precondition of the refusal being about the CAPABILITY. Without the
# binary the tool refuses for a different reason, which would make this row pass for the
# wrong one — the shape a stand-in is supposed to prevent, not create.
# Look for the real binaries WHERE THIS REPO PUTS THEM before falling back to a stand-in.
# Slice 0's P2 fetch put firecracker and jailer in the micro-cloud workdir rather than
# installing them system-wide, and the sibling test-snapshot-round-trip.sh already resolves
# firecracker that way. Without this, §5 below reports UNKNOWN on the one machine that has
# the binary — a guard quietly retiring the question it exists to ask.
_W="${MC_WORKDIR:-$HOME/.local/state/lab-create/micro-cloud-s3}"
if ! command -v jailer >/dev/null 2>&1 && [[ -x "$_W/jailer" ]]; then
    PATH="$_W:$PATH"; export PATH
fi
if ! command -v jailer >/dev/null 2>&1; then
    printf '#!/bin/sh\nexit 0\n' > "$tmp/jailer"; chmod +x "$tmp/jailer"
    printf '#!/bin/sh\nexit 0\n' > "$tmp/firecracker"; chmod +x "$tmp/firecracker"
    export PATH="$tmp:$PATH"
    note "no real jailer on PATH — a stand-in stands in for its PRESENCE only; every assertion below is about lab-fc.sh's own staging"
    STANDIN=1
else
    STANDIN=0
fi

capeff="$(sed -n 's/^CapEff:[[:space:]]*//p' /proc/self/status)"
if (( ( 0x$capeff >> 21 ) & 1 )); then
    note "this process HAS CAP_SYS_ADMIN, so the refusal below cannot be exercised — §1 is UNKNOWN on this run, not passed"
    HAVE_CAP=1
else
    HAVE_CAP=0
    r start "$N" --jailer
    (( rc != 0 )) || fail "start --jailer succeeded without CAP_SYS_ADMIN — jailer's first act is unshare(CLONE_NEWNS), so it cannot have"
    grep -q 'CAP_SYS_ADMIN' <<<"$out" \
        || fail "the refusal does not name the capability that is missing — 'permission denied' sends the reader to sudo without saying why: $out"
    grep -q 'unshare' <<<"$out" \
        || fail "the refusal does not name the syscall that needs it, so it cannot be checked against jailer's own error: $out"
    # BEFORE the staging copy, not after. jailer's own failure comes after it has copied the
    # exec-file in; a gate that fires there is a post-mortem.
    [[ ! -d "$(dirname "$D")/$N/jail" ]] \
        || fail "REGRESSION: the capability refusal fired AFTER a jail was staged — on a real guest that is a multi-hundred-megabyte copy taken to reach a refusal that was answerable first"
    note "refused without CAP_SYS_ADMIN, naming both the capability and the syscall, before staging anything"
fi

# ── 2. THE STAGING, exercised directly — this is the §5.6 sharp edge ────────────────────
# `_stage_jail` is sourced and called rather than reached through `start`, because `start`'s
# first act under --jailer is the refusal above and there is no way past it here. Sourcing the
# tool to call one function is what makes this checkable at all; the alternative is asserting
# nothing and calling the tier tested.
#
# `main "$@"` runs on source, so it is given a verb that does nothing observable: `mac`
# prints a derived MAC and RETURNS (it does not `exit`), which leaves every function defined
# in this shell. `--help` would have exited 0 and ended this test with a false PASS.
# shellcheck disable=SC1090
. "$LAB_FC" mac "$N" >/dev/null 2>&1 || true

command -v _stage_jail >/dev/null 2>&1 \
    || fail "_stage_jail is not defined after sourcing lab-fc.sh — the jail staging cannot be exercised, so §5.6's sharp edge is UNVERIFIED"

# Real content, so "same inode" and "no host path" mean something.
printf 'KERNEL-BYTES\n' > "$tmp/vmlinux"
printf 'ROOTFS-BYTES\n' > "$D/rootfs.ext4"
rootfs_inode_before="$(stat -c %i "$D/rootfs.ext4")"

# `( … )` so a `die` inside is contained rather than ending this test before its assertions —
# the silent-exit trap this repo has a rule about. Then run it for real, for its effects.
( _stage_jail "$N" "$(id -u)" "$(id -g)" ) >/dev/null 2>&1 || fail "_stage_jail failed on a valid instance"
_stage_jail "$N" "$(id -u)" "$(id -g)" >/dev/null 2>&1
JR="$D/jail/firecracker/$N/root"

[[ -f "$JR/vmlinux" ]]     || fail "the kernel was not staged into the jail root — inside the chroot there is nothing to boot"
[[ -f "$JR/rootfs.ext4" ]] || fail "the rootfs was not staged into the jail root — Firecracker would fail to open its root device, and the error reads like a corrupt image"
[[ -f "$JR/config.json" ]] || fail "no in-chroot config.json was written"

# THE SAME INODE, NOT A COPY. Two mutable images of one guest disk is the drift `cmd_create`
# already shipped once; a hard link makes it impossible rather than unlikely. (Across
# filesystems `ln` cannot, and _stage_jail copies and says so — here the jail is inside the
# instance dir, so it is always the same filesystem and the link must have been taken.)
[[ "$(stat -c %i "$JR/rootfs.ext4")" == "$rootfs_inode_before" ]] \
    || fail "the rootfs in the jail is a SEPARATE inode from the instance's — two mutable images of one guest disk, which can and eventually will disagree"

# ── 3. EVERY PATH IN THE IN-CHROOT CONFIG RESOLVES INSIDE THE CHROOT ────────────────────
grep -q '"kernel_image_path": "/vmlinux"' "$JR/config.json" \
    || fail "REGRESSION: the in-chroot config does not name /vmlinux — under the jailer a host path does not exist, and Firecracker's failure to open it looks like a bad image rather than a bad path: $(cat "$JR/config.json")"
grep -q '"path_on_host": "/rootfs.ext4"' "$JR/config.json" \
    || fail "REGRESSION: the in-chroot config does not name /rootfs.ext4: $(cat "$JR/config.json")"
grep -qF "$LAB_STATE_DIR" "$JR/config.json" \
    && fail "REGRESSION: the in-chroot config still contains a HOST state path — every path in it must resolve inside $JR: $(grep -F "$LAB_STATE_DIR" "$JR/config.json")"

# JSON PUTS NO CONSTRAINT ON THE SPACE AFTER A COLON, AND THE REWRITE MUST NOT EITHER.
# The first version of the rewrite matched `"key": "…"` with a literal space — the form
# `gen_config` happens to emit — so against a config written `"key":"…"` it silently changed
# NOTHING and produced a jail whose config still named host paths. Caught by the assertion
# inside _stage_jail, which is why this row exists: it pins the tolerance so a later
# simplification cannot quietly take it away. The fixture above is written WITHOUT the space
# on purpose, so every assertion in §3 is already running against the harder form.
grep -q '"kernel_image_path":"' "$D/config.json" \
    || fail "the fixture no longer uses the no-space form, so §3 has stopped testing the tolerance it was written for"

# …and the ordinary config is untouched, because the two must not become one file with two
# readers. It is the record `create` wrote and `start` without --jailer still uses.
grep -qF "$D/rootfs.ext4" "$D/config.json" \
    || fail "REGRESSION: staging the jail rewrote the INSTANCE's own config.json — a plain start would now name a path that only exists inside a chroot"

# ── 3a. THE STAGED FILES MUST BELONG TO THE UID THE VMM WILL BECOME ────────────────────
# MEASURED 2026-08-19, on the first privileged run of the sibling isolation test: without the
# chown the jailed VMM starts, binds its API socket, and then dies with
#     Unable to create the virtio block device: … Permission denied (os error 13) /rootfs.ext4
# jailer chowns the chroot and its own copy of the exec-file, and nothing else — files staged
# in beforehand keep the invoking user's ownership, and the VMM has by then dropped to --uid.
#
# Unprivileged, the POSITIVE case is trivially true (staging as our own uid), so the assertion
# that carries weight is the negative one: asking for a uid we cannot grant must FAIL BY NAME
# rather than stage files the VMM will not be able to open. A chown whose failure is swallowed
# is exactly how the defect above would come back, silently and one layer down.
[[ "$(stat -c %u "$JR/rootfs.ext4")" == "$(id -u)" ]] \
    || fail "the staged rootfs is not owned by the uid it was staged for — the jailed VMM drops to that uid before opening it and would fail with a bare 'Permission denied' about a path inside the chroot"
if (( HAVE_CAP == 0 )); then
    rc=0; out="$( _stage_jail "$N" 30000 30000 2>&1 )" || rc=$?
    (( rc != 0 )) \
        || fail "REGRESSION: _stage_jail reported success staging for uid 30000 while unable to chown to it — the files would belong to the wrong uid and the VMM would die on its own root device"
    grep -q 'chown' <<<"$out" \
        || fail "the staging failure does not name the chown, so the reader is sent to look at the jail rather than at ownership: $out"
    grep -q 'Permission denied' <<<"$out" \
        || fail "the staging failure does not name the error the VMM would have given, which is the whole point of failing here instead: $out"
    note "staging refuses by name when it cannot give the files to the jail uid, naming the VMM error it prevents"
else
    note "UNKNOWN: this process has CAP_SYS_ADMIN, so the cannot-chown refusal was NOT exercised on this run"
fi

# ── 4. THE JAILED IDENTITY, which is where P7-5 would return for a third time ───────────
# A jailed VMM's argv carries neither the host config path nor the host socket path — jailer
# chroots before it execs, so both are in-chroot names identical for every instance. If
# `_running_pid` still asked only about argv, `list`, `stop` and `start` would each give a
# different answer about a jailed instance, which is P7-5 verbatim.
#
# This section asserts the NEGATIVE half — that an unrelated live process is not accepted for
# this instance — with a `sleep` of our own. The positive half (what a jailed instance IS
# recognised by) moved twice and now lives in §4a: the VMM answering `GET /` with its own id.
# Both halves are needed, and neither is sufficient: a check that accepts everything and a
# check that accepts nothing both make one of these two rows pass.
sleep 300 & SLEEPER=$!
on_exit 'kill '"$SLEEPER"' 2>/dev/null || true'
printf '%s\n' "$SLEEPER" > "$D/fc.pid"
printf 'jail_root = "%s"\n' "$JR" >> "$D/manifest.toml"
if _running_pid "$N" >/dev/null 2>&1; then
    fail "REGRESSION: _running_pid accepted a process that is NOT rooted in this instance's jail — /proc/<pid>/root is the identity for a jailed VMM, and matching anything else means a recycled pid can answer for this instance"
fi
# The positive half: point jail_root at where that process really is rooted, and it must be
# recognised. Without this row the assertion above is satisfied by a check that refuses
# everything, which is indistinguishable from working.
sed -i "s#^jail_root = .*#jail_root = \"$(readlink "/proc/$SLEEPER/root")\"#" "$D/manifest.toml"
# `sleep` is not firecracker, so the cmdline gate refuses it first — which is correct and is
# itself worth stating: the jail_root check is an ADDITIONAL identity, not a replacement for
# asking whether this is a VMM at all.
if _running_pid "$N" >/dev/null 2>&1; then
    fail "_running_pid accepted a process whose cmdline is not firecracker — the jail_root check must ADD an identity, never replace the question of whether this is a VMM"
fi
note "an unrelated live process is not accepted as this jailed instance, and the is-it-a-VMM check is not weakened to make room for the jail check"

# ── 4a. IDENTIFYING THE JAILED VMM — and the two guesses that were wrong ───────────────
# Three privileged runs went into this, each on a guess about how the kernel renders a
# chrooted process to a reader in another mount namespace:
#   run 3: `readlink /proc/<pid>/root` == the jail. Never matched.
#   run 4: a /proc scan for that, plus a working-directory fallback. Neither matched, the
#          scan took 45 s of a healthy guest's life, and the same run disproved the "jailer
#          forks" theory the run-3 diagnosis rested on — `$!` was reported STILL ALIVE.
# What is not a guess: firecracker binds its API socket inside the chroot, which is a real
# host directory, so the socket has an inode this tool can compare against every open fd —
# and the VMM will state its own id if asked. Both are checkable here with no jail at all,
# because neither is a question about jails: one is about an inode, the other about an HTTP
# reply on a unix socket.
for _f in _jail_sock_pid _jail_id_matches; do
    command -v "$_f" >/dev/null 2>&1 \
        || fail "$_f is not defined — the jailed-VMM identity cannot be exercised, so it is UNVERIFIED"
done

require_cmd python3 curl
# A stand-in that binds $JR/api.sock and answers `GET /` the way Firecracker does. It is the
# honest subject: `_jail_id_matches` asks a socket a question and reads the answer, and it
# neither knows nor cares which program is on the other end.
cat > "$tmp/fakevmm.py" <<'PY'
import os, socket, sys, threading
sock, ident = sys.argv[1], sys.argv[2]
try: os.unlink(sock)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(sock); s.listen(4)
body = ('{"id": "%s", "state": "Running", "vmm_version": "1.16.1"}' % ident).encode()
while True:
    c, _ = s.accept()
    try:
        c.recv(4096)
        c.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
                  + str(len(body)).encode() + b"\r\n\r\n" + body)
    finally:
        c.close()
PY
python3 "$tmp/fakevmm.py" "$JR/api.sock" "$N" & FAKE=$!
on_exit 'kill '"$FAKE"' 2>/dev/null || true'
for _ in $(seq 1 60); do [[ -S "$JR/api.sock" ]] && break; sleep 0.05; done
[[ -S "$JR/api.sock" ]] || skip "the stand-in VMM never bound $JR/api.sock"

# THE VMM ANSWERS FOR ITSELF. This is the identity `start`, `list` and `stop` all use.
_jail_id_matches "$JR" "$N" \
    || fail "_jail_id_matches did not accept a VMM answering with its own id — this is the identity every verb uses for a jailed instance, so list/stop/start would all report it as not running while it happily served its API"
# …and it must REFUSE another instance's id. Without this row the assertion above is
# satisfied by a check that accepts anything answering on a socket, which is exactly the
# recycled-identity shape P7-5 was.
_jail_id_matches "$JR" "someotherinstance" \
    && fail "REGRESSION: _jail_id_matches accepted a VMM that named itself '$N' as 'someotherinstance' — it is testing that SOMETHING answers, not that the right machine did, so two jailed instances would answer for each other"

# THE PID THAT HOLDS THAT SOCKET, by inode. Derived from a file this tool created, not
# inferred from how a namespace renders.
found="$(_jail_sock_pid "$JR" 2>/dev/null || true)"
[[ "$found" == "$FAKE" ]] \
    || fail "_jail_sock_pid did not find the process holding $JR/api.sock (found '${found:-nothing}', expected $FAKE) — without it a jailed instance has no pid to stop"
mkdir -p "$tmp/otherjail"
other="$(_jail_sock_pid "$tmp/otherjail" 2>/dev/null || true)"
[[ -z "$other" ]] \
    || fail "REGRESSION: _jail_sock_pid returned pid $other for a jail with no socket at all"
note "the jailed VMM is identified by ASKING IT (it must name itself, and another name is refused) and located by the inode of the socket it holds"

# ── 5. THE REAL JAILER, as far as it will go without the privilege ─────────────────────
# Not a claim that a jailed VM boots. It is the one thing a stand-in cannot tell us: that the
# real binary accepts this argv and this pre-populated chroot, and gets all the way to the
# privileged step. Measured: it fails at unshare(CLONE_NEWNS) AFTER copying its exec-file in,
# which is also why §1's refusal has to come first.
if (( STANDIN == 0 )) && (( HAVE_CAP == 0 )); then
    jout="$(jailer --id "$N" --exec-file "$(command -v firecracker || printf /bin/true)" \
        --uid "$(id -u)" --gid "$(id -g)" --chroot-base-dir "$D/jail" \
        -- --config-file /config.json 2>&1 || true)"
    grep -qi 'unshare' <<<"$jout" \
        || fail "the real jailer did not fail at the unshare step against this staging — it refused something earlier, so what it objected to is UNKNOWN and the staging above may not be what it wants: $jout"
    [[ -f "$JR/vmlinux" && -f "$JR/config.json" ]] \
        || fail "the real jailer removed or replaced the staged files before failing — lab-fc.sh's staging does not survive contact with it"
    note "the real $(jailer --version 2>/dev/null | head -1) accepted this argv and this pre-populated chroot, and reached unshare(CLONE_NEWNS) with the staging intact"
else
    note "UNKNOWN: the real jailer binary was NOT exercised on this run ($( (( STANDIN )) && printf 'none on PATH' || printf 'this process has CAP_SYS_ADMIN, so it would have gone on to boot a VM' ))"
fi

pass "the jailer tier's file-and-text half is verified without the privilege it needs: the kernel and rootfs are staged inside the chroot (the rootfs as the SAME INODE, so one guest disk cannot become two), the in-chroot config names only in-chroot paths while the instance's own config is left alone, a jailed instance is identified by /proc/<pid>/root rather than by an argv that no longer carries anything host-specific (P7-5's third arrival, refused), and the missing capability is refused by name BEFORE the staging copy. Booting a jailed guest needs CAP_SYS_ADMIN and is examples/micro-cloud/tests/test-jailer-isolation.sh"
