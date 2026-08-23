#!/usr/bin/env bash
# bench-boot.sh — time to userspace, same kernel + same rootfs, two VMMs.
#
# Slice 5a's unprivileged half. No fabric, no tap, no network, no root: boot the SAME ELF
# `vmlinux` and a per-instance copy of the SAME `.ext4` under Firecracker and under QEMU
# `-M microvm`, and report how long each takes to reach `/sbin/init` — with the spread,
# because slice 1 established Firecracker's figure with ZERO variance over four runs and a
# single sample is not comparable to that.
#
# ─── WHY THIS EXISTS, AND THE TRAP IT WAS BUILT TO AVOID ────────────────────────────────
#
# The plan's density argument rests on "0.55 s to userspace", measured four times in slices
# 1–4 and never once beside another VMM. The first QEMU boot came back at 0.070 s and the
# obvious headline was "QEMU microvm reaches userspace 8× faster than Firecracker."
#
# That headline is FALSE, and the way it is false is the whole point of this file. Firecracker
# emulates an i8042 PS/2 controller (it is how `SendCtrlAltDel` reaches the guest). QEMU's
# `microvm` machine emulates none. The kernel's i8042 probe waits out a timeout on hardware
# that never answers, and on this kernel that wait is **~0.51 s of the 0.567 s**:
#
#     [    0.051399] clk: Disabling unused clocks          ← same instant in both engines
#     [    0.563440] input: AT Raw Set 2 keyboard …        ← Firecracker, 0.512 s later
#     [    0.052645] EXT4-fs (vda): recovery complete      ← same kernel, i8042 probing off
#
# So the number was never measuring the VMM. It was measuring ONE DEVICE MODEL DIFFERENCE
# through a kernel timeout, and comparing the two engines' defaults would have attributed it
# to the hypervisor. That is this repo's bug class #2 wearing a stopwatch — an artefact of
# the mechanism, reported as the property.
#
# Hence FOUR arms, not two. Each engine is measured with the probe left alone AND with it
# disabled, so the difference between the arms is visible instead of baked into a headline:
#
#     fc-default       Firecracker, boot_args as slices 1–4 used them
#     fc-noi8042       + i8042.noaux i8042.nomux i8042.nopnp i8042.dumbkbd
#     qemu-default     QEMU -M microvm, the same cmdline as fc-default
#     qemu-noi8042     + the same four flags — the CONTROL. microvm has no i8042, so this
#                      arm MUST come out equal to qemu-default. If it does not, the flags
#                      are doing something other than what this file claims and every
#                      conclusion above is void.
#
# ─── WHAT IS AND IS NOT HELD CONSTANT ───────────────────────────────────────────────────
#
# Constant: the kernel FILE (one sha256, printed), the rootfs BYTES (a fresh per-instance
# copy from one source image per run, so ext4 recovery costs the same every time), vcpus,
# memory, KVM acceleration, and the absence of any network device.
#
# NOT constant, and inside "the VMM" on purpose: the device model, the firmware (QEMU loads
# qboot; Firecracker has none), and each VMM's own startup. The kernel-timestamp number
# EXCLUDES all three — it starts when the guest kernel starts. The wall-clock number
# INCLUDES them. Both are reported because neither alone is the honest answer.
#
# `root=` is deliberately NOT symmetric, and that asymmetry is itself decision-E evidence
# (plan E.4): Firecracker APPENDS `root=/dev/vda rw` after the caller's boot_args and refuses
# to be told otherwise, so QEMU must be handed it explicitly to boot the same disk.
set -uo pipefail

PROG="${0##*/}"

# Defaults point at slice 3's workdir — the artifacts Appendices E–G measured.
#
# NOT `$HOME`: under sudo that is ROOT's home, and every micro-cloud artifact belongs to the
# invoking user, so a root-run benchmark would look in /root/.local/state/… and refuse on a
# host that has the files. `${SUDO_USER}` alone is not enough either — it is literally `root`
# when sudo runs from a root shell (the same trap as the root-owned tap, plan G.4) — so fall
# back to this script's own owner and read the home directory out of passwd rather than
# assuming /home/<user>. Found 2026-08-05: the sibling tests were fixed and THIS was missed,
# which is the blast-radius rule earning its place — two of three call sites is not a fix.
_invoking_user_home() {
    local u h
    u="${SUDO_USER:-}"
    [[ -z "$u" || "$u" == root ]] && u="$(stat -c %U "${BASH_SOURCE[0]}" 2>/dev/null || true)"
    if [[ -n "$u" && "$u" != root ]]; then
        h="$(getent passwd "$u" 2>/dev/null | cut -d: -f6)"
        [[ -n "$h" && -d "$h" ]] && { printf '%s\n' "$h"; return 0; }
    fi
    printf '%s\n' "$HOME"
}
WORKDIR="${MC_WORKDIR:-$(_invoking_user_home)/.local/state/lab-create/micro-cloud-s3}"
KERNEL="${MC_KERNEL:-$WORKDIR/vmlinux}"
ROOTFS="${MC_ROOTFS:-$WORKDIR/api1.ext4}"
FC_BIN="${MC_FIRECRACKER:-$WORKDIR/firecracker}"
# ONE ANSWER TO "WHERE IS THE VMM". This file resolves the binary itself (it launches
# Firecracker directly) AND shells out to lab-fc.sh, which used to resolve it from PATH --
# the D8 seam: two tools, two answers, and nothing making them agree. Since 2026-08-23 the
# driver takes $LAB_FC_BIN, so exporting it here means both halves run the SAME binary
# rather than the same version by luck. TODO §11.5.
export LAB_FC_BIN="$FC_BIN"
QEMU_BIN="${MC_QEMU:-qemu-system-x86_64}"
QBOOT="${MC_QBOOT:-/usr/share/qemu/qboot.rom}"

RUNS=3
ENGINES=both
JSON=false
MEM_MIB=256
VCPUS=1
BOOT_TIMEOUT=20          # seconds to wait for the userspace marker before calling a run dead

# The kernel line that means "the kernel is finished and userspace is starting". This is the
# exact marker slices 1–4 timed, so the numbers below are comparable to Appendices E–H.
MARKER='Run /sbin/init as init process'
# The flags that stop the kernel probing a PS/2 controller. Measured one at a time against
# Firecracker, because "add these four flags" is advice nobody can check:
#
#   i8042.nopnp     0.0598   ← this one. The stall is the PNP probe.
#   i8042.dumbkbd   0.0562   ← and this one, by skipping the keyboard command handshake
#   i8042.noaux     0.5681   no effect
#   i8042.nomux     0.5672   no effect
#   i8042.notimeout 0.5670   no effect — note the name; it is not the timeout being waited on
#
# All four are kept in the arm so the arm matches the advice people actually copy around,
# but only the first two are load-bearing and `nopnp` alone is enough.
NOI8042='i8042.noaux i8042.nomux i8042.nopnp i8042.dumbkbd'
# Everything slices 1–4 booted with. `pci=off` because neither machine has a PCI bus;
# `reboot=k` because a microVM has no ACPI; `panic=1` so a failed boot exits instead of
# hanging (plan E.3 measured that one: 1.63 s vs killed at 20 s).
BASE_ARGS='console=ttyS0 reboot=k panic=1 pci=off'

die()  { printf '%s: %s\n' "$PROG" "$*" >&2; exit 2; }
note() { printf '  - %s\n' "$*" >&2; }

# `[    0.069558] Run /sbin/init as init process` → `0.069558`; empty if absent.
#
# `awk`, not `sed`, and that is a bug fix rather than a preference: the marker contains
# `/sbin/init`, so interpolating it into `sed "s/…$MARKER…/"` ends the substitution early —
# "unknown option to `s'". The first version of this harness failed all 20 boots that way
# while reporting "never reached userspace", which was FALSE: every guest had booted and
# printed the line. A parse failure wearing a boot failure's error message is the liar this
# repo fixes first — hence both this function and the two distinct reasons in boot_once.
kernel_ts_from_log() {
    awk -v m="$MARKER" '
        index($0, m) && match($0, /^\[ *[0-9]+\.[0-9]+\]/) {
            s = substr($0, RSTART + 1, RLENGTH - 2); gsub(/ /, "", s); print s; exit
        }' "$1" 2>/dev/null
}

usage() {
    cat <<EOF
$PROG — time to userspace for one kernel + one rootfs under two VMMs

USAGE
  $PROG [--runs N] [--engine {fc|qemu|both}] [--json] [--kernel P] [--rootfs P]

OPTIONS
  --runs N        iterations per arm (default $RUNS; the spread is the point, so N>1)
  --engine E      fc | qemu | both  (default both — four arms, see the header)
  --kernel PATH   ELF vmlinux       (default \$MC_KERNEL or slice 3's)
  --rootfs PATH   raw ext4 image    (default \$MC_ROOTFS or slice 3's)
  --mem MiB       guest memory      (default $MEM_MIB, both engines)
  --json          machine-readable; every sample, not just the summary
  --parse-log F   print the userspace kernel timestamp this harness would read out of the
                  boot log F, and exit. Same code path the runs use — it exists so the
                  parser can be regression-tested without a hypervisor (see
                  tests/test-bench-boot.sh); the first version of it was silently broken.
  -h, --help

EXIT  0 every arm produced a number · 1 an arm failed to boot · 2 misuse / missing input
EOF
}

while (( $# )); do
    case "$1" in
        --runs)    RUNS="${2:-}"; shift 2 ;;
        --engine)  ENGINES="${2:-}"; shift 2 ;;
        --kernel)  KERNEL="${2:-}"; shift 2 ;;
        --rootfs)  ROOTFS="${2:-}"; shift 2 ;;
        --mem)     MEM_MIB="${2:-}"; shift 2 ;;
        --json)    JSON=true; shift ;;
        --parse-log)
            [[ -n "${2:-}" ]] || die "--parse-log needs a file"
            [[ -r "$2" ]] || die "--parse-log: not readable: $2"
            ts="$(kernel_ts_from_log "$2")"
            [[ -n "$ts" ]] || { printf '%s: no "%s" line with a kernel timestamp in %s\n' "$PROG" "$MARKER" "$2" >&2; exit 1; }
            printf '%s\n' "$ts"; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *)         usage >&2; die "unknown argument: $1" ;;
    esac
done
[[ "$RUNS" =~ ^[0-9]+$ && "$RUNS" -ge 1 ]] || die "--runs must be a positive integer, got '$RUNS'"
[[ "$ENGINES" =~ ^(fc|qemu|both)$ ]]       || die "--engine must be fc, qemu or both, got '$ENGINES'"

# ─── Inputs: refuse BEFORE measuring, and name what is missing ──────────────────────────
# A benchmark that silently drops an arm reports a comparison it did not make.
[[ -r "$KERNEL" ]] || die "kernel not readable: $KERNEL
  Slice 3's artifacts live in \$MC_WORKDIR (now '$WORKDIR'); override with --kernel."
[[ -r "$ROOTFS" ]] || die "rootfs not readable: $ROOTFS  (override with --rootfs)"
[[ -r /dev/kvm && -w /dev/kvm ]] \
    || die "/dev/kvm is not read-write for uid $(id -u) — without KVM this would compare TCG emulation, not two VMMs"
if [[ "$ENGINES" != qemu ]]; then
    [[ -x "$FC_BIN" ]] || die "firecracker not executable: $FC_BIN  (set \$MC_FIRECRACKER)"
fi
if [[ "$ENGINES" != fc ]]; then
    command -v "$QEMU_BIN" >/dev/null 2>&1 || die "$QEMU_BIN not on PATH (set \$MC_QEMU)"
    "$QEMU_BIN" -machine help 2>/dev/null | grep -q '^microvm ' \
        || die "$QEMU_BIN has no 'microvm' machine type — this comparison needs it"
    [[ -r "$QBOOT" ]] || die "qboot ROM not readable: $QBOOT  (set \$MC_QBOOT)"
fi

TMP="$(mktemp -d)" || die "could not create a scratch dir"
# Scratch is discarded on a clean run and KEPT on a failed one — a benchmark that deletes
# the evidence of the boot that did not work is a benchmark you cannot debug. Nothing is
# ever written into the repo checkout; an earlier draft did, and left 20 stray logs behind.
KEEP_TMP=0
cleanup() {
    if (( KEEP_TMP )); then
        printf '\nlogs for the failed run(s) kept in: %s\n' "$TMP" >&2
        return
    fi
    [[ -n "${TMP:-}" && -d "$TMP" ]] && rm -rf -- "$TMP"
}
trap cleanup EXIT

# ─── One run of one arm ─────────────────────────────────────────────────────────────────
# Sets: R_KERNEL (guest kernel timestamp on the marker line), R_WALL (host seconds from
# exec to the marker appearing), R_LOG.  Returns non-zero if the guest never reached
# userspace — a dead run must never be averaged in as if it were a fast one.
R_KERNEL="" R_WALL="" R_LOG="" R_WHY=""
boot_once() {
    local engine="$1" tag="$2" extra="$3" n="$4"
    local disk="$TMP/$tag-$n.ext4" log="$TMP/$tag-$n.log"
    R_KERNEL="" R_WALL="" R_LOG="$log" R_WHY=""

    # A PER-INSTANCE COPY, every run, both engines. The source image is dirty (a guest was
    # SIGKILLed on it in slice 3), so ext4 replays its journal on mount; copying gives every
    # run the identical work to do instead of letting run 1 clean up for run 2.
    cp -- "$ROOTFS" "$disk" || return 1

    local args="$BASE_ARGS"
    [[ -n "$extra" ]] && args="$args $extra"

    local t0 pid
    t0="$(date +%s.%N)"
    if [[ "$engine" == fc ]]; then
        # Firecracker appends `root=/dev/vda rw` itself (plan E.4) — supplying it here is
        # what `lab-fc.sh` refuses, so it is absent by design.
        cat > "$TMP/$tag-$n.json" <<JSON
{
  "boot-source": { "kernel_image_path": "$KERNEL", "boot_args": "$args" },
  "drives": [ { "drive_id": "rootfs", "path_on_host": "$disk",
                "is_root_device": true, "is_read_only": false } ],
  "machine-config": { "vcpu_count": $VCPUS, "mem_size_mib": $MEM_MIB }
}
JSON
        "$FC_BIN" --no-api --config-file "$TMP/$tag-$n.json" \
                  --api-sock "$TMP/$tag-$n.sock" >"$log" 2>&1 &
        pid=$!
    else
        # QEMU appends nothing, so `root=` is supplied here. -no-user-config/-nodefaults keep
        # the machine to exactly what is declared; `-display none -serial file:` rather than
        # -nographic, which would hand COM1 to the firmware and corrupt the very log we time.
        "$QEMU_BIN" \
            -M microvm,rtc=on -cpu host -enable-kvm -m "$MEM_MIB" -smp "$VCPUS" \
            -no-user-config -nodefaults -no-reboot -display none \
            -bios "$QBOOT" \
            -kernel "$KERNEL" -append "$args root=/dev/vda rw" \
            -drive "file=$disk,if=none,id=disk0,format=raw" \
            -device "virtio-blk-device,drive=disk0" \
            -serial "file:$log" >"$TMP/$tag-$n.err" 2>&1 &
        pid=$!
    fi

    # Wait for userspace, then stop the guest BY PID. Never by pattern: every one of these
    # command lines carries the shared workdir path, and `pkill -f` on it would match the
    # other engine's run and, historically, a live VM (repo gotcha, exit 144).
    local waited=0 found=0
    while (( waited < BOOT_TIMEOUT * 20 )); do
        if [[ -s "$log" ]] && grep -q -- "$MARKER" "$log" 2>/dev/null; then found=1; break; fi
        kill -0 "$pid" 2>/dev/null || { sleep 0.1; grep -q -- "$MARKER" "$log" 2>/dev/null && found=1; break; }
        sleep 0.05; waited=$((waited+1))
    done
    R_WALL="$(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN{printf "%.4f", b-a}')"
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null

    (( found )) || { R_WHY="the guest never printed the userspace marker within ${BOOT_TIMEOUT}s"; return 1; }

    R_KERNEL="$(kernel_ts_from_log "$log")"
    [[ -n "$R_KERNEL" ]] \
        || { R_WHY="the marker line is present but its kernel timestamp did not parse"; return 1; }
    return 0
}

# ─── Arms ───────────────────────────────────────────────────────────────────────────────
ARMS=()
[[ "$ENGINES" != qemu ]] && ARMS+=("fc:fc-default:" "fc:fc-noi8042:$NOI8042")
[[ "$ENGINES" != fc   ]] && ARMS+=("qemu:qemu-default:" "qemu:qemu-noi8042:$NOI8042")

printf '%s — %d run(s) per arm, %d MiB, %d vcpu, KVM\n' "$PROG" "$RUNS" "$MEM_MIB" "$VCPUS" >&2
note "kernel $(sha256sum -- "$KERNEL" | cut -c1-16)…  $KERNEL"
note "rootfs $(sha256sum -- "$ROOTFS" | cut -c1-16)…  $ROOTFS  (copied per run)"

rc=0
declare -a JSON_ROWS=()
printf '\n%-14s %10s %10s %10s   %10s %10s\n' ARM K_MIN K_MED K_MAX W_MED RUNS >&2
for arm in "${ARMS[@]}"; do
    engine="${arm%%:*}"; rest="${arm#*:}"; tag="${rest%%:*}"; extra="${rest#*:}"
    ks=() ws=() failed=0
    for ((i=1; i<=RUNS; i++)); do
        if boot_once "$engine" "$tag" "$extra" "$i"; then
            ks+=("$R_KERNEL"); ws+=("$R_WALL")
            JSON_ROWS+=("{\"arm\":\"$tag\",\"run\":$i,\"kernel_s\":$R_KERNEL,\"wall_s\":$R_WALL}")
        else
            failed=$((failed+1)); rc=1; KEEP_TMP=1
            printf '  ✗ %s run %d: %s\n      log kept: %s\n' \
                   "$tag" "$i" "${R_WHY:-unknown failure}" "$R_LOG" >&2
        fi
    done
    if (( ${#ks[@]} == 0 )); then
        printf '%-14s %10s %10s %10s   %10s %10s\n' "$tag" UNKNOWN UNKNOWN UNKNOWN UNKNOWN "0/$RUNS" >&2
        continue
    fi
    read -r kmin kmed kmax <<<"$(printf '%s\n' "${ks[@]}" | sort -g | awk '{a[NR]=$1} END{printf "%s %s %s", a[1], a[int((NR+1)/2)], a[NR]}')"
    wmed="$(printf '%s\n' "${ws[@]}" | sort -g | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')"
    printf '%-14s %10s %10s %10s   %10s %10s\n' "$tag" "$kmin" "$kmed" "$kmax" "$wmed" "${#ks[@]}/$RUNS" >&2
done

printf '\nK_* = guest kernel timestamp on "%s" — excludes VMM startup and firmware.\n' "$MARKER" >&2
printf 'W_MED = host wall clock from exec to that line — INCLUDES both.\n' >&2
printf 'qemu-default and qemu-noi8042 must agree: microvm has no i8042, so those flags are\n' >&2
printf 'the control. A gap there invalidates the fc-default vs fc-noi8042 reading.\n' >&2

if [[ "$JSON" == true ]]; then
    printf '{"kernel":"%s","kernel_sha256":"%s","rootfs":"%s","rootfs_sha256":"%s","runs":%d,"mem_mib":%d,"samples":[%s]}\n' \
        "$KERNEL" "$(sha256sum -- "$KERNEL" | cut -d' ' -f1)" \
        "$ROOTFS" "$(sha256sum -- "$ROOTFS" | cut -d' ' -f1)" \
        "$RUNS" "$MEM_MIB" "$(IFS=,; echo "${JSON_ROWS[*]}")"
fi
exit $rc
