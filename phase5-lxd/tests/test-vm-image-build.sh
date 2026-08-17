#!/usr/bin/env bash
# Closes REVIEW-phase5.md §8.4's first remaining UNKNOWN: `backend_from_chroot_vm` and
# `backend_from_tarball_vm` require `EUID=0` (loop mounts, `mkfs`, `extlinux`), so
# **the partitioning, the extlinux config, the MBR `dd` and the raw→qcow2 conversion had
# never been executed by any test** — here or in CI. `test-vm-lifecycle.sh` covers a VM's
# *launch*; it never builds one of these images.
#
# ── THE SEAM, AND WHY IT IS A REAL ONE ────────────────────────────────────────────────
# `backend_from_chroot_vm` ends by handing its qcow2 to `backend_from_qcow2`, which is the
# only step needing a live engine. Everything §8.4 named as unmeasured happens *before*
# that call. So the test sources `lab-lxd.sh` — which carries a source guard, so `main`
# does not run — and replaces `backend_from_qcow2` with a recorder that copies the qcow2
# aside. That is an existing function boundary, not an invented one, and the import it
# stands in for is separately covered by `test-vm-lifecycle.sh`.
#
# A tripwire guards the substitution: if the recorder is never called, the test FAILS
# rather than passing on an image nobody produced.
#
# ── WHAT IT ASSERTS: THE ARTIFACT, NOT THE STEPS ──────────────────────────────────────
# Every assertion reads the produced disk image. None greps the driver for a command it
# ran — a test that asserts `parted` was invoked passes when `parted` is invoked and
# broken, and fails when a better tool replaces it.
#
# The sharpest one is the UUID chain. `/etc/fstab` and `extlinux.conf` both carry the root
# filesystem's UUID, captured mid-build. If either disagrees with the filesystem actually
# on the image, the VM boots to `Cannot open root device` — a record that outlived its
# subject, in an artifact whose failure mode is a kernel panic minutes later on someone
# else's machine. Nothing had ever compared them.
#
# ── HOW TO RUN IT ─────────────────────────────────────────────────────────────────────
#     sudo phase5-lxd/tests/test-vm-image-build.sh
# It self-skips when it cannot become root, so `run-all.sh` stays green either way.
# CI's runner has passwordless sudo (phase 4's root-gated tests run there), so this runs
# in CI too.
#
# ── WHAT IT TOUCHES ───────────────────────────────────────────────────────────────────
# One 20 GiB **sparse** raw image and its qcow2, inside a temp dir removed at exit; loop
# devices, each detached and verified detached; no engine, no daemon, no network, and
# `LAB_STATE_DIR` pointed at the temp dir so the real state dir is never opened.
#
# shellcheck disable=SC1090
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd qemu-img parted mkfs.ext4 losetup extlinux rsync blkid dd tar

# The syslinux MBR blob the driver will pick, resolved the same way the driver resolves it
# — so the byte-exact comparison below is against the file it actually used, not a guess.
MBR_BIN=""
for p in /usr/lib/syslinux/mbr/mbr.bin /usr/share/syslinux/mbr.bin \
         /usr/lib/syslinux/mbr.bin /usr/lib/extlinux/mbr.bin; do
    [[ -r "$p" ]] && { MBR_BIN="$p"; break; }
done
[[ -n "$MBR_BIN" ]] || skip "no syslinux MBR blob found — install syslinux-common (the driver refuses without one too)"

if [[ $EUID -eq 0 ]]; then
    SUDO=()
else
    sudo -n true 2>/dev/null \
        || skip "not root and no passwordless sudo — run it directly:  sudo $0"
    SUDO=(sudo -n)
fi

tmp="$(mktemp -d)"
# 0755, not mktemp's 0700. Under the documented invocation (`sudo <this script>`) the whole
# run is root from PID 1, so `$tmp` would be root:root 0700 and §0's non-root check — which
# re-enters as SUDO_USER — could not even traverse it. It would then die on `not a
# directory` instead of the root gate, and the assertion would report the wrong defect.
chmod 0755 "$tmp"
export LAB_STATE_DIR="$tmp/state"      # never open the caller's real state dir
export TMPDIR="$tmp"                   # the driver's own mktemp -d lands here too
# /usr/sbin and /sbin hold parted, mkfs.ext4, losetup and blkid; a login PATH that omits
# them is common and would surface as a confusing mid-build failure rather than a refusal.
export PATH="/usr/local/sbin:/usr/sbin:/sbin:$PATH"

# Cleanup is registered with on_exit — never a second `trap … EXIT`, which would replace
# lib.sh's verdict net. Loop devices are detached BY DEVICE NAME, and only ones whose
# backing file is inside this test's tmp dir: this host has ~49 loop devices in normal use
# and reaping by pattern would take somebody's mounted image with it.
_reap_our_loops() {
    local line dev back
    while read -r line; do
        dev="${line%%:*}"
        back="$(sed -n 's/.*(\(.*\))$/\1/p' <<<"$line")"
        [[ "$back" == "$tmp"/* ]] || continue
        "${SUDO[@]}" losetup -d "$dev" 2>/dev/null || true
    done < <("${SUDO[@]}" losetup -a 2>/dev/null || true)
    return 0
}
on_exit '"${SUDO[@]}" umount "$tmp/inspect" 2>/dev/null || true
         _reap_our_loops
         "${SUDO[@]}" rm -rf -- "$tmp" 2>/dev/null || true'

# ── the fixture: a minimal tree shaped like a chroot with a kernel ────────────────────
# Deliberately NOT a debootstrap. The backend's job is to turn *a directory* into a
# bootable disk; what makes the build succeed or fail is the kernel/initrd it finds, the
# partitioning, and extlinux — none of which care whether the userland is real. A real
# chroot would add minutes and measure nothing extra.
KVER="6.1.0-test"
mkchroot() {   # mkchroot <dir> [omit]   — omit ∈ {kernel,initrd}
    local d="$1" omit="${2:-}"
    mkdir -p "$d"/{boot,etc,sbin,usr/bin,proc,sys,dev,run,tmp}
    [[ "$omit" == kernel ]] || head -c 65536 /dev/urandom > "$d/boot/vmlinuz-$KVER"
    [[ "$omit" == initrd ]] || head -c 32768 /dev/urandom > "$d/boot/initrd.img-$KVER"
    printf 'ID=labtest\n' > "$d/etc/os-release"
    printf '#!/bin/sh\nexec /bin/sh\n' > "$d/sbin/init"; chmod +x "$d/sbin/init"
    printf 'copied-by-rsync\n' > "$d/etc/lab-marker"
    printf 'must-not-be-copied\n' > "$d/proc/should-be-excluded"
}
mkchroot "$tmp/chroot"

# ── the runner: sources the driver, intercepts the import, calls the backend ──────────
cat > "$tmp/run-build.sh" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail
fn="$1"; src="$2"; alias_name="$3"
source "$LAB_LXD"                       # source guard means main() does not run
backend_from_qcow2() {                  # the only step that needs a live engine
    printf '%s\n' "$1" > "$IMPORT_MARKER"
    cp -- "$1" "$OUT_QCOW2"
    [[ "${IMPORT_MODE:-ok}" == fail ]] && return 1
    return 0
}
# A fault injected at a MIDDLE step, for the errexit-suppression regression. Shadowing the
# external command with a shell function is the real seam — the driver calls `extlinux`
# by name and cannot tell the difference.
if [[ "${BREAK_MIDSTEP:-}" == 1 ]]; then
    extlinux() { printf 'extlinux: simulated failure\n' >&2; return 1; }
fi
"$fn" "$src" "$alias_name"
RUNNER
chmod +x "$tmp/run-build.sh"

build() {   # build <fn> <src> <logfile> [IMPORT_MODE] [BREAK_MIDSTEP]
    local fn="$1" src="$2" log="$3" mode="${4:-ok}" brk="${5:-0}"
    rm -f "$tmp/import.marker" "$tmp/out.qcow2"
    set +e
    "${SUDO[@]}" env LAB_LXD="$LAB_LXD" LAB_STATE_DIR="$LAB_STATE_DIR" TMPDIR="$tmp" \
        IMPORT_MARKER="$tmp/import.marker" OUT_QCOW2="$tmp/out.qcow2" IMPORT_MODE="$mode" \
        BREAK_MIDSTEP="$brk" PATH="$PATH" \
        bash "$tmp/run-build.sh" "$fn" "$src" vmimg-test > "$log" 2>&1
    local rc=$?
    set -e
    return "$rc"
}

# ══ 0. the root gate, measured as the NON-ROOT user it exists for ═════════════════════
# Asserted before anything is built: as root this refusal cannot fire, so a test that only
# ran as root could never tell "the gate is correct" from "the gate is gone".
_as_user() {   # _as_user <fn> <src>  → the refusal text a non-root process gets
    local snippet='source "$LAB_LXD"; "$1" "$2" vmimg-test'
    if [[ $EUID -ne 0 ]]; then
        LAB_LXD="$LAB_LXD" bash -c "$snippet" _ "$1" "$2" 2>&1
    elif [[ -n "${SUDO_USER:-}" ]] && command -v runuser >/dev/null 2>&1; then
        runuser -u "$SUDO_USER" -- env LAB_LXD="$LAB_LXD" LAB_STATE_DIR="$tmp/state-u" \
            bash -c "$snippet" _ "$1" "$2" 2>&1
    else
        return 1
    fi
}
GATE_RAN=0
if out="$(_as_user backend_from_chroot_vm "$tmp/chroot")"; then
    fail "REGRESSION: backend_from_chroot_vm succeeded as a NON-ROOT user — the loop-mount/mkfs gate is gone"
else
    grep -qi 'requires root' <<<"$out" \
        || fail "the non-root refusal did not name root as the reason; got: ${out//$'\n'/ }"
    out2="$(_as_user backend_from_tarball_vm "$tmp/chroot" || true)"
    grep -qi 'requires root' <<<"$out2" \
        || fail "backend_from_tarball_vm's non-root refusal did not name root; got: ${out2//$'\n'/ }"
    GATE_RAN=1
    note "both VM backends refuse a non-root caller, by name"
fi
(( GATE_RAN )) || note "UNKNOWN: running as root with no SUDO_USER, so the non-root gate could not be measured in this pass"

# ══ 1. the build runs, and the interception really happened ══════════════════════════
build backend_from_chroot_vm "$tmp/chroot" "$tmp/build.log" \
    || { cat "$tmp/build.log" >&2; fail "backend_from_chroot_vm failed on a minimal chroot with a kernel — see the log above"; }
[[ -s "$tmp/import.marker" ]] \
    || fail "the build reported success without ever calling backend_from_qcow2 — nothing was produced, and every assertion below would be vacuous"
[[ -s "$tmp/out.qcow2" ]] || fail "no qcow2 was captured from the build"
note "the build completed and handed a qcow2 to the import step"

# ══ 2. raw → qcow2 really happened ═══════════════════════════════════════════════════
fmt="$("${SUDO[@]}" qemu-img info --output=json "$tmp/out.qcow2" | python3 -c 'import json,sys; print(json.load(sys.stdin)["format"])')"
[[ "$fmt" == qcow2 ]] \
    || fail "REGRESSION: the image handed to the import step is '$fmt', not qcow2 — the raw→qcow2 conversion did not happen"
note "the artifact is a real qcow2 (qemu-img info), not a renamed raw"

# ══ 3. the partition table: MBR, one primary, bootable ═══════════════════════════════
"${SUDO[@]}" qemu-img convert -f qcow2 -O raw "$tmp/out.qcow2" "$tmp/inspect.raw"
parted_out="$("${SUDO[@]}" parted -s -m "$tmp/inspect.raw" print 2>&1)" \
    || fail "parted cannot read the produced image: $parted_out"
grep -q ':msdos:' <<<"$parted_out" \
    || fail "REGRESSION: the disk label is not msdos (MBR) — an extlinux/BIOS image needs one. parted said: ${parted_out//$'\n'/ | }"
part_count="$(grep -c '^[0-9]:' <<<"$parted_out" || true)"
(( part_count == 1 )) \
    || fail "REGRESSION: expected exactly one partition, found $part_count: ${parted_out//$'\n'/ | }"
grep -qE '^1:.*boot' <<<"$parted_out" \
    || fail "REGRESSION: partition 1 does not carry the boot flag — the BIOS will not boot it. parted said: ${parted_out//$'\n'/ | }"
note "MBR label, exactly one primary partition, boot flag set"

# ══ 4. the MBR bootstrap code is the syslinux blob, byte for byte ════════════════════
# `dd if=$mbr_bin of=$lodev bs=440 count=1 conv=notrunc` is one of the four steps §8.4
# named. A size check would pass on 440 zero bytes; only the bytes prove it.
"${SUDO[@]}" dd if="$tmp/inspect.raw" of="$tmp/mbr.actual" bs=440 count=1 status=none
cmp -s "$tmp/mbr.actual" "$MBR_BIN" \
    || fail "REGRESSION: the first 440 bytes of the image are not $MBR_BIN — the MBR dd did not happen, or wrote something else. sha of ours=$(sha256sum "$tmp/mbr.actual" | cut -c1-16) theirs=$(sha256sum "$MBR_BIN" | cut -c1-16)"
note "the first 440 bytes are byte-identical to $MBR_BIN"

# ══ 5. the UUID chain — fstab and extlinux.conf must name the filesystem that IS there ═
lodev="$("${SUDO[@]}" losetup --find --partscan --show "$tmp/inspect.raw")" \
    || fail "could not attach the produced image to a loop device"
on_exit '"${SUDO[@]}" losetup -d "'"$lodev"'" 2>/dev/null || true'
# Wait for partscan to publish ${lodev}p1 rather than sleeping a guessed interval — udev
# latency varies by host, and a fixed sleep is a flake waiting for a slower machine.
for _i in $(seq 1 40); do [[ -b "${lodev}p1" ]] && break; sleep 0.1; done
[[ -b "${lodev}p1" ]] || fail "the produced image exposes no partition 1 on $lodev after 4s — partscan found nothing to scan, so the partitioning did not produce a usable partition"
real_uuid="$("${SUDO[@]}" blkid -s UUID -o value "${lodev}p1")"
[[ -n "$real_uuid" ]] || fail "partition 1 has no filesystem UUID — mkfs.ext4 did not run"
mkdir -p "$tmp/inspect"
"${SUDO[@]}" mount -o ro "${lodev}p1" "$tmp/inspect" \
    || fail "cannot mount the produced filesystem read-only — mkfs.ext4 produced nothing mountable"

fstab="$("${SUDO[@]}" cat "$tmp/inspect/etc/fstab" 2>/dev/null || true)"
grep -qE "^UUID=${real_uuid}[[:space:]]+/[[:space:]]+ext4" <<<"$fstab" \
    || fail "REGRESSION: /etc/fstab does not name the filesystem that is actually there. The image's root UUID is $real_uuid; fstab says: ${fstab//$'\n'/ | }"

extcfg="$("${SUDO[@]}" cat "$tmp/inspect/boot/extlinux/extlinux.conf" 2>/dev/null || true)"
[[ -n "$extcfg" ]] || fail "REGRESSION: no /boot/extlinux/extlinux.conf on the image — the bootloader was never configured"
grep -q "root=UUID=${real_uuid}" <<<"$extcfg" \
    || fail "REGRESSION: extlinux.conf's root=UUID does not match the filesystem on the image ($real_uuid) — this VM boots to 'Cannot open root device'. extlinux.conf: ${extcfg//$'\n'/ | }"
grep -q 'console=ttyS0' <<<"$extcfg" \
    || fail "extlinux.conf has no console=ttyS0 — a headless VM built by this backend would boot silently"
note "fstab and extlinux.conf both name the filesystem that is actually on the image ($real_uuid)"

# ...and the kernel and initrd those lines point at must exist on the image.
for f in "boot/vmlinuz-$KVER" "boot/initrd.img-$KVER"; do
    "${SUDO[@]}" test -s "$tmp/inspect/$f" \
        || fail "REGRESSION: extlinux.conf boots /$f, which is not on the image"
done
grep -q "KERNEL /boot/vmlinuz-$KVER" <<<"$extcfg" \
    || fail "extlinux.conf does not name the kernel found in the chroot; got: ${extcfg//$'\n'/ | }"
grep -q "INITRD /boot/initrd.img-$KVER" <<<"$extcfg" \
    || fail "extlinux.conf does not name the initrd found in the chroot; got: ${extcfg//$'\n'/ | }"
"${SUDO[@]}" test -s "$tmp/inspect/boot/extlinux/ldlinux.sys" \
    || fail "REGRESSION: no ldlinux.sys — \`extlinux --install\` did not actually install the bootloader"
note "the kernel, the initrd and ldlinux.sys are all on the image, and extlinux.conf names them"

# ══ 6. rsync copied the tree, and excluded what it must ══════════════════════════════
"${SUDO[@]}" test -s "$tmp/inspect/etc/lab-marker" \
    || fail "the chroot's contents did not reach the image — rsync copied nothing"
"${SUDO[@]}" test -e "$tmp/inspect/proc/should-be-excluded" \
    && fail "REGRESSION: /proc was copied into the image; the rsync excludes are gone"
note "the tree was copied, and /proc was excluded"

"${SUDO[@]}" umount "$tmp/inspect"
"${SUDO[@]}" losetup -d "$lodev"; lodev=""

# ══ 7. the failure path: no loop device and no workdir may survive ═══════════════════
# The driver carries an eight-line comment about doing all loop/mount work in a subshell
# with ONE EXIT trap, precisely so a failure cannot leak a loop device and a 20 GiB raw.
# Nothing had ever watched it. The fault is injected at a real seam — the import step
# returns non-zero — which is *after* losetup, mkfs and mount, so the trap is what has to
# clean up.
before="$("${SUDO[@]}" losetup -a 2>/dev/null | wc -l)"
if build backend_from_chroot_vm "$tmp/chroot" "$tmp/fail.log" fail; then
    fail "REGRESSION: the build reported SUCCESS when the import step failed"
fi
grep -qi 'failed' "$tmp/fail.log" || fail "the failed build did not say so; got: $(tail -2 "$tmp/fail.log")"
leaked="$("${SUDO[@]}" losetup -a 2>/dev/null | sed -n "s|^\([^:]*\):.*($tmp/.*)$|\1|p" || true)"
[[ -z "$leaked" ]] \
    || fail "REGRESSION: a failed build leaked loop device(s) backed by this test's workdir: ${leaked//$'\n'/ } — the subshell EXIT trap did not fire"
after="$("${SUDO[@]}" losetup -a 2>/dev/null | wc -l)"
(( after <= before )) \
    || fail "REGRESSION: the loop-device count rose from $before to $after across a failed build"
# -mindepth 1 is load-bearing: `find <dir> -maxdepth 1` yields the START DIRECTORY too, and
# $tmp is itself a `mktemp -d` named tmp.XXXXXXXXXX — so without it this matched $tmp on
# every run and the assertion could never pass. Caught on the first privileged run, which
# is the entire argument for running a test rather than reading it: it reported a leak
# against a driver that had cleaned up correctly.
stray="$("${SUDO[@]}" find "$tmp" -mindepth 1 -maxdepth 1 -name 'tmp.*' -type d 2>/dev/null || true)"
[[ -z "$stray" ]] \
    || fail "REGRESSION: a failed build left its workdir behind: ${stray//$'\n'/ } — a 20 GiB raw per failure"
# ...and the control for the control: the check must be able to SEE a workdir if one is
# there. Without this, `-mindepth 1` could be wrong in the other direction (a typo in the
# -name pattern, say) and the section would pass by matching nothing, forever.
"${SUDO[@]}" mkdir -p "$tmp/tmp.canary-leak"
seen="$("${SUDO[@]}" find "$tmp" -mindepth 1 -maxdepth 1 -name 'tmp.*' -type d 2>/dev/null || true)"
"${SUDO[@]}" rmdir "$tmp/tmp.canary-leak"
[[ "$seen" == *tmp.canary-leak* ]] \
    || fail "control: the leaked-workdir scan cannot see a workdir that IS there, so the assertion above proves nothing"
note "a failure after losetup leaks neither a loop device nor its 20 GiB workdir"

# ══ 7b. a MID-BUILD failure must stop the build, not be swallowed ════════════════════
# REGRESSION for the defect this test's first privileged run exposed. `( … ) || die` makes
# bash SUPPRESS errexit inside the subshell, so a failing command in the middle used to be
# ignored and the build carried on — reporting whatever went wrong three steps later as if
# it were the cause. (`tar` failed in backend_from_tarball_vm and the operator was told
# "no /boot/vmlinuz-* found" about a tarball that had one.)
#
# The fault is injected at `extlinux --install`, which is deliberately NOT the last command
# — the last one already propagates, so a test that broke only that would pass against the
# defect. Measured, not reasoned: re-issuing `set -e` inside, an ERR trap inside, and
# `if ! ( … )` were each tried and NONE re-arm errexit; per-command `|| die` is the guard.
if build backend_from_chroot_vm "$tmp/chroot" "$tmp/mid.log" ok 1; then
    fail "REGRESSION: a failure at extlinux --install was SWALLOWED and the build reported success — errexit is suppressed inside \`( … ) || die\` and the per-command guards are gone"
fi
grep -qi 'extlinux' "$tmp/mid.log" \
    || fail "the build failed after extlinux broke, but never named extlinux — the operator is pointed at the wrong step; got: $(tail -3 "$tmp/mid.log")"
[[ -s "$tmp/import.marker" ]] \
    && fail "REGRESSION: the build continued to the import step after extlinux --install failed — it would have published an unbootable image"
note "a failure in the MIDDLE of the build stops it, names the step that failed, and never reaches the import"

# ══ 8. the refusals that must fire BEFORE any of that work ═══════════════════════════
mkchroot "$tmp/nokernel" kernel
if build backend_from_chroot_vm "$tmp/nokernel" "$tmp/nok.log"; then
    fail "REGRESSION: a chroot with no /boot/vmlinuz-* was accepted"
fi
grep -q 'no /boot/vmlinuz' "$tmp/nok.log" \
    || fail "the missing kernel was refused, but not by name; got: $(tail -2 "$tmp/nok.log")"
[[ -s "$tmp/import.marker" ]] && fail "REGRESSION: the no-kernel case still reached the import step"

mkchroot "$tmp/noinitrd" initrd
if build backend_from_chroot_vm "$tmp/noinitrd" "$tmp/noi.log"; then
    fail "REGRESSION: a chroot with no initrd was accepted"
fi
grep -q 'no /boot/initrd.img' "$tmp/noi.log" \
    || fail "the missing initrd was refused, but not by name; got: $(tail -2 "$tmp/noi.log")"

if build backend_from_chroot_vm "$tmp/does-not-exist" "$tmp/nodir.log"; then
    fail "REGRESSION: a non-existent path was accepted as a chroot"
fi
grep -qi 'not a directory' "$tmp/nodir.log" \
    || fail "a missing chroot path was refused, but not by name; got: $(tail -2 "$tmp/nodir.log")"
note "no kernel / no initrd / no directory are each refused by name, before any disk work"

# ══ 9. the tarball backend delegates, and refuses an absolute-path member ════════════
"${SUDO[@]}" tar -C "$tmp/chroot" -cpf "$tmp/rootfs.tar" --numeric-owner .
build backend_from_tarball_vm "$tmp/rootfs.tar" "$tmp/tar.log" \
    || { cat "$tmp/tar.log" >&2; fail "backend_from_tarball_vm failed on a tarball of the same tree"; }
[[ -s "$tmp/out.qcow2" ]] || fail "the tarball path produced no image"
[[ "$("${SUDO[@]}" qemu-img info --output=json "$tmp/out.qcow2" | python3 -c 'import json,sys; print(json.load(sys.stdin)["format"])')" == qcow2 ]] \
    || fail "the tarball path did not produce a qcow2 — the delegation to backend_from_chroot_vm is broken"
note "the tarball backend delegates and produces the same kind of artifact"

# NOT ASSERTED HERE, deliberately — and this is the second draft of this paragraph.
#
# The first version staged a tarball with an ABSOLUTE member and asserted that no canary
# appeared outside the extract dir, to exercise the `--no-absolute-names` guard (H-3).
# Measured before shipping it: **GNU tar strips the leading `/` on extract by default**
# ("Removing leading `/' from member names"), so that canary cannot be created whether the
# flag is present or not. It was a check that passes identically against a fixed driver and
# a broken one — the exact shape this repo keeps catching, and it would have read as
# coverage.
#
# The absolute-path/symlink hardening has a home that can actually fail:
# `tests/test-from-chroot-symlink.sh`. Left uncovered here, by name, rather than covered
# by something inert.

if (( GATE_RAN )); then
    pass "the VM image backends build a bootable MBR/extlinux qcow2 whose fstab and extlinux.conf name the filesystem that is really on it, leak nothing on failure, and refuse a non-root caller (REVIEW-phase5 §8.4)"
else
    pass "the VM image backends build a bootable MBR/extlinux qcow2 whose fstab and extlinux.conf name the filesystem that is really on it, and leak nothing on failure (REVIEW-phase5 §8.4; the non-root gate was not measured in this pass)"
fi
