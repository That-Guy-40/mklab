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
need sha256sum

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

R="$tmp/r.ext4"
cp -- "$BASE" "$R" || skip "could not copy the base rootfs"
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
[[ -d "/proc/$pp" ]] || fail "the plain VMM (pid $pp) is not running"
[[ -d "/proc/$jp" ]] || fail "the jailed VMM (pid $jp) is not running"

# ── /proc/<pid>/root — THE CHROOT, and the whole of the tier ────────────────────────────
proot="$(readlink "/proc/$pp/root" || true)"
jroot="$(readlink "/proc/$jp/root" || true)"
expected="$(sed -n 's/^jail_root = "\(.*\)"$/\1/p' "$LAB_STATE_DIR/fc/$JAILED/manifest.toml")"
[[ "$proot" == "/" ]] \
    || fail "the PLAIN VMM is not rooted at / (it is at '$proot') — the control arm is not a control, so any difference below proves nothing about the jailer"
[[ "$jroot" != "/" ]] \
    || fail "REGRESSION: the JAILED VMM is rooted at / — it is not in a chroot at all, and §5.6's tier is a flag that did nothing"
[[ "$jroot" == "$expected" ]] \
    || fail "the jailed VMM is rooted at '$jroot', not at the jail this tool built ('$expected') — something else chrooted it, so what it can see is UNKNOWN"
note "/proc/<pid>/root — plain: $proot · jailed: $jroot"

# …and the chroot is not decorative: the host state dir must be unreachable from inside it.
[[ ! -e "$jroot/$LAB_STATE_DIR" ]] \
    || fail "the host state dir is reachable from inside the jail — the chroot contains the thing it is meant to exclude"

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

pass "the same microVM, plain and jailed: the jailed VMM is rooted at its own chroot ($jroot) while the plain one is at /, it dropped to uid $juid, the host state dir is unreachable from inside the jail, both VMMs carry Firecracker's own seccomp filter, and the jailed instance is still visible to \`list\` and stoppable by \`stop\` despite an argv that carries no host path at all. The network namespace is REPORTED rather than asserted: the jailer joins one given with --netns and does not create one"
