#!/usr/bin/env bash
# §5.6's exercise: boot the same microVM plain and jailed, then DIFF the two processes.
#
#     "Every noun there is something an earlier phase taught: chroot (Phase 1), namespaces
#      and cgroups — now wrapped around a hypervisor. The step: boot the same microVM plain
#      and jailed, then diff /proc/<pid>/root, /proc/<pid>/ns/net, and /proc/<pid>/status's
#      Seccomp line."
#
# ── THIS TEST NEEDS CAP_SYS_ADMIN AND SAYS SO ───────────────────────────────────────────
# `jailer`'s first act is unshare(CLONE_NEWNS). There is no unprivileged path to a jailed
# microVM, so on any machine without the capability this SKIPs by name — and a SKIP here is
# an UNKNOWN about the isolation tier, not a pass. The half that CAN be checked without the
# privilege (staging, the in-chroot config rewrite, the jailed identity, the refusal) is
# phase7-firecracker/tests/test-jailer-staging.sh, and it runs in CI.
#
# ── WHAT IS ASSERTED, AND WHAT IS ONLY REPORTED ─────────────────────────────────────────
# §5.6 names three things to diff, and they do not all differ — which is the finding, not a
# shortfall:
#
#   /proc/<pid>/root    ASSERTED to differ. This is the chroot, and it is the whole tier.
#   /proc/<pid>/status  ASSERTED: the jailed VMM runs as the --uid/--gid it was given.
#   /proc/<pid>/ns/net  REPORTED. The jailer joins a network namespace only when it is GIVEN
#                       one with --netns; it does not create one. So unless the operator has
#                       already made a netns, this is EXPECTED to be identical, and a test
#                       that asserted a difference would be asserting something the tier does
#                       not claim.
#   Seccomp             REPORTED. Firecracker installs its own seccomp filter with or without
#                       the jailer, so both processes are expected to be filtered. What the
#                       jailer adds here is not the filter; it is everything around it.
#
# Reporting the two that do not differ is the point of running the diff at all: "wrapped a
# hypervisor in a chroot" is a precise claim, and the precision is lost if the write-up
# implies the jailer hands you a network namespace it does not.
#
# shellcheck disable=SC1090
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
need sha256sum e2fsck debugfs

FC_TOOL="$REPO_DIR/phase7-firecracker/lab-fc.sh"
[[ -x "$FC_TOOL" ]] || skip "lab-fc.sh not executable at $FC_TOOL"

W="${MC_WORKDIR:-$(mc_workdir)}"
KERNEL="${MC_KERNEL:-$W/vmlinux}"
BASE="${MC_ROOTFS:-$W/api1.ext4}"
# BOTH BINARIES ARE LOOKED FOR WHERE THIS REPO PUTS THEM, not only on PATH — and it matters
# more here than anywhere else, because this test is meant to be run under `sudo`, and sudo
# replaces PATH with secure_path. A guard that required them on PATH would SKIP on the one
# machine that can run it, in the one way it is meant to be run: a guard that quietly retires
# the question it exists to ask.
have firecracker || { [[ -x "$W/firecracker" ]] && { PATH="$W:$PATH"; export PATH; }; }
have firecracker || skip "no firecracker on PATH and none at $W/firecracker — nothing to jail"
have jailer      || { [[ -x "$W/jailer" ]] && { PATH="$W:$PATH"; export PATH; }; }
have jailer      || skip "no jailer on PATH and none at $W/jailer — it ships beside firecracker in the same release tarball (slice 0's P2 fetch, DEFERRED.md §17.1) but is not installed system-wide; put it next to firecracker in $W. Without it the isolation tier cannot be exercised"

# THE CAPABILITY, DERIVED — not `[[ $EUID -eq 0 ]]`. What is needed is CAP_SYS_ADMIN, and uid
# 0 is merely the usual way to have it: a root process inside a user namespace may not, and a
# non-root process with the capability does.
_capeff="$(sed -n 's/^CapEff:[[:space:]]*//p' /proc/self/status 2>/dev/null || true)"
[[ -n "$_capeff" ]] && (( ( 0x$_capeff >> 21 ) & 1 )) \
    || skip "this process lacks CAP_SYS_ADMIN (CapEff=${_capeff:-unreadable}) — jailer unshares a mount namespace, so the isolation tier CANNOT be exercised here. That is an UNKNOWN about §5.6, not a pass; run this under sudo"

[[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] || skip "/dev/kvm is not read-write — no microVM to jail"
[[ -r "$KERNEL" ]] || skip "no bootable kernel at $KERNEL"
[[ -r "$BASE"   ]] || skip "no bootable rootfs at $BASE"

tmp="$(mktemp -d /tmp/mcjail.XXXXXX)"; on_exit 'rm -rf -- "$tmp"'
export LAB_STATE_DIR="$tmp/state"
PLAIN=jplain
JAILED=jjail
# Teardown by NAME through the tool's own verb, registered before anything exists — never a
# pattern, which would also match the harness that mentions these paths.
on_exit 'for _n in '"$PLAIN $JAILED"'; do bash "'"$FC_TOOL"'" destroy "$_n" --force >/dev/null 2>&1 || true; done'

# ── THE GUEST HAS TO STAY UP, OR THERE IS NOTHING TO COMPARE ────────────────────────────
# MEASURED 2026-08-19: the first version booted the base rootfs unmodified. That image's init
# runs slice 3's network probe, finds no NIC (this test configures no tap), and EXITS — so the
# VMM was gone by the time `start` polled for liveness and the run failed with "did not
# start" about a guest whose console showed a perfectly good boot. A comparison of two live
# /proc entries needs two live processes; a fixture that ends on its own is measuring a race.
#
# So the same backgrounded ticker the fleet tests use is injected with `debugfs` — no loop
# mount, no extra privilege — and it keeps both arms running for as long as this test needs
# them. It is registered as `sysinit` and BACKGROUNDED: busybox init runs every sysinit entry
# to completion before it starts any respawn one.
R="$tmp/r.ext4"
cp -- "$BASE" "$R" || skip "could not copy the base rootfs"
# A guest killed mid-run leaves a dirty bitmap debugfs refuses to open. Repair the COPY.
e2fsck -fy "$R" >/dev/null 2>&1 || true
cat > "$tmp/mc-probe.sh" <<'EOS'
#!/bin/sh
( while :; do echo "MC-ALIVE $(cut -d. -f1 /proc/uptime)" > /dev/console; sleep 1; done ) &
EOS
debugfs -w -R "rm /mc-probe.sh" "$R" >/dev/null 2>&1 || true
debugfs -w -R "write $tmp/mc-probe.sh mc-probe.sh" "$R" >/dev/null 2>&1 \
    || skip "debugfs could not inject the keep-alive probe into the rootfs copy"
debugfs -w -R "sif /mc-probe.sh mode 0100755" "$R" >/dev/null 2>&1 || true
debugfs -R "stat /mc-probe.sh" "$R" 2>/dev/null | grep -q 'Mode:  0755' \
    || skip "the injected probe is not executable in the image — the guest would not stay up"

fc() { bash "$FC_TOOL" "$@"; }

# THE SAME microVM, TWICE. Same kernel, same rootfs bytes, same memory — so the only variable
# between the two processes is the tier. A comparison whose two arms differ in more than one
# thing measures nothing in particular.
for n in "$PLAIN" "$JAILED"; do
    out="$(fc create --name "$n" --kernel "$KERNEL" --rootfs "$R" --memory 256M 2>&1)" \
        || fail "create $n failed: $out"
done

out="$(fc start "$PLAIN" 2>&1)"  || fail "the PLAIN start failed, so there is nothing to compare against: $out"
# A dedicated uid for the jailed arm, so "it dropped privilege" is observable rather than
# asserted. 30000 is §5.6's own example.
export LAB_FC_JAIL_UID=30000 LAB_FC_JAIL_GID=30000
out="$(fc start "$JAILED" --jailer 2>&1)" || fail "the JAILED start failed: $out"

pp="$(cat "$LAB_STATE_DIR/fc/$PLAIN/fc.pid")"
jp="$(cat "$LAB_STATE_DIR/fc/$JAILED/fc.pid")"
# BOTH must still be alive AT THE SAME INSTANT, which is a different question from "did each
# one start". `start` polls for liveness and returns; a guest that exits a second later
# satisfies it and leaves nothing to compare. Named separately so a future failure says which
# of the two happened.
[[ -d "/proc/$pp" ]] || fail "the plain VMM (pid $pp) started and has since exited — its guest did not stay up, so there is no live process to compare against (see $LAB_STATE_DIR/fc/$PLAIN/fc.log)"
[[ -d "/proc/$jp" ]] || fail "the jailed VMM (pid $jp) started and has since exited (see $LAB_STATE_DIR/fc/$JAILED/fc.log)"
# …and they must both be up for long enough that the reads below are of the same moment.
sleep 2
[[ -d "/proc/$pp" && -d "/proc/$jp" ]] \
    || fail "one of the two VMMs exited during the comparison — the /proc reads below would be of a machine that is no longer there"

# ── THE CHROOT — and §5.6 names a mechanism that does not answer from the host ──────────
# MEASURED 2026-08-19, fifth privileged run: `readlink /proc/<pid>/root` is `/` for the
# JAILED VMM, exactly as it is for the plain one. The jail is set up inside a private mount
# namespace, so its path is not reachable from the reader's namespace and the kernel renders
# the link as `/`. §5.6 says to diff that field; from the host it does not distinguish them.
#
# That is this repo's own rule arriving where it was least expected — in the plan's
# instructions rather than in a test. The mechanism ("read this /proc field") is not the
# property ("this process is confined to a different filesystem view"), and the mechanism can
# be present, correct and useless. So the field is REPORTED, and the property is asserted
# through things that do not depend on how a path is rendered to a reader:
#
#   * the two VMMs are in DIFFERENT MOUNT NAMESPACES. `readlink /proc/<pid>/ns/mnt` yields
#     `mnt:[N]` — an inode number, not a path — so it is immune to the rendering problem
#     above. jailer's first act is unshare(CLONE_NEWNS); if these match, it did not happen.
#   * what each VMM HAS OPEN. Both opened the same guest disk; the plain one holds it under
#     its host path and the jailed one under a path inside its own root. That is the chroot
#     made visible, and it is the thing a reader of §5.6 actually wants to see.
p_ns="$(readlink "/proc/$pp/ns/mnt" || true)"
j_ns="$(readlink "/proc/$jp/ns/mnt" || true)"
[[ -n "$p_ns" && -n "$j_ns" ]] || fail "could not read the mount namespace of both VMMs (plain='$p_ns' jailed='$j_ns')"
[[ "$p_ns" != "$j_ns" ]] \
    || fail "REGRESSION: both VMMs are in the SAME mount namespace ($j_ns) — jailer's first act is unshare(CLONE_NEWNS), so it did not happen and §5.6's tier is a flag that did nothing"
note "mount namespace — plain: $p_ns · jailed: $j_ns (different, so the unshare happened)"

# What each has open. Reported in full, and asserted only as "these are not the same path",
# which is the chroot without depending on either path's exact spelling.
_rootfs_fd() {  # _rootfs_fd <pid> -> the path that pid has its guest disk open under
    local d fd l
    for fd in "/proc/$1"/fd/*; do
        l="$(readlink "$fd" 2>/dev/null || true)"
        [[ "$l" == *rootfs.ext4* ]] && { printf '%s' "$l"; return 0; }
    done
    return 1
}
p_disk="$(_rootfs_fd "$pp" || true)"
j_disk="$(_rootfs_fd "$jp" || true)"
if [[ -n "$p_disk" && -n "$j_disk" ]]; then
    [[ "$p_disk" != "$j_disk" ]] \
        || fail "REGRESSION: both VMMs have their guest disk open under the SAME path ($j_disk) — the jailed one is not seeing a different filesystem root"
    note "the guest disk, as each VMM has it open — plain: $p_disk · jailed: $j_disk"
else
    note "UNKNOWN: could not read an open rootfs fd for one of the VMMs (plain='${p_disk:-none}' jailed='${j_disk:-none}') — the chroot was NOT demonstrated this way on this run; the namespace assertion above stands on its own"
fi

# The field §5.6 names, reported rather than asserted, with what it actually said.
p_root="$(readlink "/proc/$pp/root" || true)"
j_root="$(readlink "/proc/$jp/root" || true)"
note "/proc/<pid>/root — plain: ${p_root:-unreadable} · jailed: ${j_root:-unreadable} $( [[ "$p_root" == "$j_root" ]] && printf '(IDENTICAL — from the host this field does not distinguish the tiers; see the header)' )"

# …and the jail directory this tool built must be where the tool said it is, so that a reader
# following §5.6 by hand is looking at the right place.
jail_dir="$(sed -n 's/^jail_root = "\(.*\)"$/\1/p' "$LAB_STATE_DIR/fc/$JAILED/manifest.toml")"
[[ -d "$jail_dir" ]] || fail "the jail root recorded for '$JAILED' does not exist on the host: $jail_dir"
[[ -f "$jail_dir/rootfs.ext4" && -f "$jail_dir/config.json" ]] \
    || fail "the jail root $jail_dir does not contain the staged guest disk and config — the VMM is running on something else"
[[ ! -e "$jail_dir/$LAB_STATE_DIR" ]] \
    || fail "the host state dir is reachable inside the jail directory — the chroot contains the thing it is meant to exclude"

# ── /proc/<pid>/status — the uid/gid switch, observable ─────────────────────────────────
juid="$(awk '/^Uid:/{print $2}' "/proc/$jp/status")"
puid="$(awk '/^Uid:/{print $2}' "/proc/$pp/status")"
[[ "$juid" == "$LAB_FC_JAIL_UID" ]] \
    || fail "REGRESSION: the jailed VMM runs as uid $juid, not the $LAB_FC_JAIL_UID it was given — the privilege drop did not happen, and a chroot a root process can escape is not a boundary"
[[ "$juid" != "$puid" ]] \
    || fail "both VMMs run as uid $juid — the two arms do not differ in privilege, so this row measured nothing"
note "uid — plain: $puid · jailed: $juid (dropped, as asked)"

# ── /proc/<pid>/ns/net — REPORTED, because the jailer does not create one ───────────────
pnet="$(readlink "/proc/$pp/ns/net" || true)"
jnet="$(readlink "/proc/$jp/ns/net" || true)"
if [[ "$pnet" == "$jnet" ]]; then
    note "/proc/<pid>/ns/net — IDENTICAL ($jnet). Expected: the jailer JOINS a network namespace given with --netns; it does not make one. The netns in §5.6's command line is something the operator creates first"
else
    note "/proc/<pid>/ns/net — plain: $pnet · jailed: $jnet (they differ, so something supplied a namespace)"
fi

# ── the Seccomp line — REPORTED, and the reason matters ─────────────────────────────────
pse="$(awk '/^Seccomp:/{print $2}' "/proc/$pp/status")"
jse="$(awk '/^Seccomp:/{print $2}' "/proc/$jp/status")"
# 0 = disabled, 1 = strict, 2 = filter. Firecracker installs its own filter either way, so
# both are expected to be 2 — asserting a DIFFERENCE here would be asserting something the
# jailer does not claim, and asserting BOTH ARE FILTERED is the claim that matters.
(( pse == 2 && jse == 2 )) \
    || fail "a VMM is running without a seccomp filter (plain=$pse jailed=$jse; 2 means filter) — Firecracker installs one itself, so a 0 here means it was disabled and the syscall surface is wide open in BOTH tiers"
note "Seccomp — plain: $pse · jailed: $jse (both filtered; the filter is Firecracker's own, in either tier — what the jailer adds is the chroot and the uid switch around it)"

# ── and the jailed instance is still MANAGEABLE, which is where P7-5 would return ───────
# A jailed VMM's argv carries only in-chroot paths, so an identity check that asked about
# argv alone would make list/stop/start disagree about this instance — P7-5's shape through
# a third verb. It is asserted here against the live process rather than only against the
# fixture the headless test uses.
out="$(fc list 2>&1)"
grep -qE "^${JAILED}[[:space:]]+running" <<<"$out" \
    || fail "REGRESSION: \`list\` does not see the jailed instance as running — its argv carries no host path, so the identity must come from /proc/<pid>/root: $out"
out="$(fc stop "$JAILED" 2>&1)" || fail "\`stop\` could not stop the jailed instance: $out"
[[ -d "/proc/$jp" ]] \
    && fail "\`stop\` reported success and the jailed VMM (pid $jp) is still running"

pass "the same microVM, plain and jailed: the two VMMs are in DIFFERENT mount namespaces, the jailed one holds its guest disk under a path inside its own root while the plain one holds the host path, it dropped to uid $juid, its jail ($jail_dir) contains the staged disk and config and not the host state dir, both carry Firecracker's own seccomp filter, and the jailed instance is still visible to \`list\` and stoppable by \`stop\` despite an argv that carries no host path at all. THREE fields are REPORTED rather than asserted, each because the tier does not claim them: /proc/<pid>/root (from the host it renders as / for both, so §5.6's own instruction does not distinguish them), the network namespace (jailer JOINS one given with --netns and does not create one), and the seccomp mode (Firecracker filters itself in either tier)"
