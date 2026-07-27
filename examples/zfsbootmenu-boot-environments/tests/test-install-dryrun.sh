#!/usr/bin/env bash
# test-install-dryrun.sh — install-zfs-root.sh must plan the whole install and
# touch NOTHING.
#
# install-zfs-root.sh repartitions a disk, makes a pool, debootstraps, chroots
# and registers a UEFI boot entry. It is the one script in this lab that can
# destroy data, and until it grew INSTALL_DRYRUN=1 it could only be checked by
# reading it. The dry run is now the thing under test.
#
# THE ASSERTION THAT MATTERS IS COMPLETENESS, NOT PLAUSIBILITY. A dry run that
# guards nine commands out of ten is worse than none at all: a reader trusts it
# and still loses the disk. So this does not merely read the printed plan —
# it puts REFUSING STUBS for every destructive tool on PATH and fails if the
# script reaches even one of them. A command that escaped run() would execute
# the stub, the stub records itself and exits non-zero, and the test says so.
#
# The stubs cannot do damage: each one appends its argv to a log and exits 111.
# That is the point — a test for a "changes nothing" mode must not be capable of
# changing anything either.
# shellcheck disable=SC1091
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
arm_exit_trap

INSTALL="$LAB_DIR/install-zfs-root.sh"
[[ -x "$INSTALL" ]] || fail "install-zfs-root.sh not found or not executable at $INSTALL"

WORK="$(mktemp -d)"
# shellcheck disable=SC2154
trap 'rc=$?; rm -rf "$WORK"; [[ $rc == 0 || $rc == 77 ]] || printf "FAIL: test exited early (rc=%s)\n" "$rc" >&2' EXIT

STUBS="$WORK/stubs"; mkdir -p "$STUBS"
MARKER="$WORK/executed.log"; : >"$MARKER"

# Every tool the script can use to change the machine.
for t in sgdisk partprobe zpool zfs debootstrap mkfs.vfat mount umount \
         chroot efibootmgr curl blkid install mkdir rm chpasswd; do
    cat >"$STUBS/$t" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "${t}" "\$*" >>"\$STUB_MARKER"
exit 111
STUB
    chmod +x "$STUBS/$t"
done

MNT="$WORK/mnt"
PLAN="$WORK/plan.txt"
set +e
env PATH="$STUBS:$PATH" STUB_MARKER="$MARKER" \
    INSTALL_DRYRUN=1 DISK=/dev/definitely-not-a-real-disk MNT="$MNT" \
    "$INSTALL" >"$PLAN" 2>&1
rc=$?
set -e
plan="$(sed 's/\x1b\[[0-9;]*m//g' "$PLAN")"

# ── 1. the completeness proof ───────────────────────────────────────────────
if [[ -s "$MARKER" ]]; then
    while read -r line; do note "ESCAPED run(): $line"; done <"$MARKER"
    fail "REGRESSION: the dry run EXECUTED the tool(s) listed above. A partial dry run is worse than none — a reader would trust it and still lose the disk. Route the offending command through run() (or write_file() if it is a redirection)"
fi
note "no destructive tool was reached: every effect went through run()/write_file()  ✓"

[[ $rc -eq 0 ]] || fail "the dry run exited $rc; it should complete a full plan (output: $(tail -3 <<<"$plan" | tr '\n' ' '))"
note "the dry run completes end to end (exit 0)  ✓"

# ── 2. it wrote nothing ─────────────────────────────────────────────────────
[[ ! -e "$MNT" ]] \
    || fail "REGRESSION: the dry run CREATED $MNT — a file write escaped write_file() (contains: $(find "$MNT" | head -5 | tr '\n' ' '))"
note "nothing was created under \$MNT  ✓"

# ── 3. the plan is the real install, in the order that makes it work ─────────
# Ordering is not cosmetic: the pool cannot be made before the partition table,
# the ESP cannot be mounted before it is formatted, and ZFSBootMenu cannot be
# dropped on an ESP that is not mounted yet.
steps=(
    'sgdisk --zap-all'                  # partition first
    'zpool create'                      # then the pool
    'zfs create -o canmount=noauto'     # the first boot environment
    'zpool set bootfs='                 # make it the default BE
    'debootstrap'                       # the base system
    'mkfs.vfat -F32'                    # format the ESP
    'mount /dev/definitely-not-a-real-disk1'   # …then mount it
    'chroot'                            # configure inside
    'curl -fL -o'                       # fetch ZFSBootMenu
    'efibootmgr --create'               # register the boot entry
    'zpool export'                      # and leave the pool clean
)
prev=0
for s in "${steps[@]}"; do
    n=$(grep -nF -- "$s" <<<"$plan" | head -1 | cut -d: -f1)
    [[ -n "$n" ]] || fail "REGRESSION: the install plan no longer contains '$s'"
    [[ $n -gt $prev ]] \
        || fail "REGRESSION: '$s' appears at line $n, before the previous step (line $prev) — the install order is broken and the result would not boot"
    prev=$n
done
note "all ${#steps[@]} install steps are present, in a working order  ✓"

# ── 4. the two BE-correctness rules the script documents ────────────────────
cmdline="$(grep -F 'org.zfsbootmenu:commandline=' <<<"$plan" | head -1)"
[[ -n "$cmdline" ]] || fail "the plan never sets org.zfsbootmenu:commandline"
grep -qE '(^|[^a-z])root=' <<<"$cmdline" \
    && fail "REGRESSION: the kernel command line contains root=. ZFSBootMenu injects root=zfs:<be> for whichever BE it boots; a hard-coded one pins the wrong dataset and every clone inherits the mistake"
grep -qE '/ROOT($|[^/])' <<<"$cmdline" \
    || fail "REGRESSION: the command line is set on a single BE, not on the ROOT container — future boot environments would not inherit it (got: $cmdline)"
note "kernel cmdline: no root=, and set on the ROOT container so clones inherit it  ✓"

# ── 5. the ESP path the loader points at is the one we actually write ───────
# If these drift apart the firmware launches a file that is not there, and the
# machine simply does not boot — with nothing in the install log to say why.
# Compare the two paths rather than grepping for both literals — that way the
# test states the actual invariant ("the firmware is pointed at the file we
# wrote") instead of two independent spellings that could drift together.
# run() prints with %q, so the Windows-style separators arrive doubled
# (\\EFI\\zbm) — correct copy-pasteable quoting, normalised away here.
written="$(grep -F 'curl -fL -o' <<<"$plan" | head -1 | awk '{print $5}')"
[[ -n "$written" ]] || fail "the plan never fetches the ZFSBootMenu EFI"
written="${written#*/boot/efi/}"                       # → EFI/zbm/vmlinuz.EFI
loader="$(sed -nE 's/.*--loader ([^ ]+).*/\1/p' <<<"$plan" | head -1)"
[[ -n "$loader" ]] || fail "the plan never registers a --loader with efibootmgr"
loader="${loader//\\\\/\\}"                            # un-double %q's escaping
loader="${loader//\\//}"                                # \EFI\zbm → EFI/zbm
loader="${loader#/}"
[[ "$written" == "$loader" ]] \
    || fail "REGRESSION: the EFI is written to '$written' but the firmware is pointed at '$loader' — the machine would launch a file that does not exist, and nothing in the install log would say why"
note "the registered --loader ('$loader') is exactly where the EFI is written  ✓"

# The ESP must be partition 1 both when it is created and when it is registered.
grep -qF -- '-t1:EF00' <<<"$plan" || fail "the ESP is no longer created as partition 1 with type EF00"
grep -qF -- '--part 1' <<<"$plan" \
    || fail "REGRESSION: efibootmgr registers a different partition than the one formatted as the ESP"
note "the ESP is partition 1 both when formatted and when registered  ✓"

pass "install-zfs-root.sh plans the full install, in a working order, and reaches no destructive tool at all"
