#!/usr/bin/env bash
# sandbox.sh — bring up a Calico we are allowed to break, run the experiment, tear it down.
#
#   sandbox.sh up          create + resize + boot, and wait for the cluster
#   sandbox.sh experiment  copy guest-experiment.sh in and run it, printing NCS-* lines
#   sandbox.sh cni-chaos   inject a fault at each CNI layer and print the CNI-* record
#   sandbox.sh status      where the guest's tunnel is right now
#   sandbox.sh down        destroy the VM
#
# ⚠️ THIS SCRIPT MUST NEVER TOUCH THE HOST'S NETWORKING. The guest is `network_mode = user`
# (slirp): no tap, no bridge, no fabric on this side. The host runs a LIVE microk8s whose
# tunnel has moved three times in six days on its own; the entire value of this lab is that
# it asks its questions somewhere that is safe to wreck. `status` prints the host's binding
# too, purely so a reader can SEE it did not move.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "$HERE/../.." && pwd)"
LAB_VM="$REPO/phase2-qemu-vm/lab-vm.sh"
SPEC="$HERE/nested-calico-sandbox.toml"
VM=calico-sandbox
DISK_SIZE="${NCS_DISK_SIZE:-16G}"
READY_TIMEOUT="${NCS_READY_TIMEOUT:-900}"

info() { printf '[info] %s\n' "$*" >&2; }
die()  { printf '[error] %s\n' "$*" >&2; exit 1; }

vm_state_dir() { printf '%s/.local/state/lab-create/vms/%s\n' "$HOME" "$VM"; }
serial_sock()  { printf '%s/serial.sock\n' "$(vm_state_dir)"; }
console()      { printf '%s/ncs-console.log\n' "$(vm_state_dir)"; }

# THE CONSOLE IS A UNIX SOCKET, NOT A FILE. lab-vm.sh exposes it as
# `-chardev socket,...,server=on` so `lab-vm.sh console` can attach; nothing writes a log.
# The first draft of this script waited for a `console.log` that is never created — it would
# have sat out its full 900 s timeout and reported a cluster failure that had not happened.
# So we capture it ourselves.
#
# ⚠️ ONE CLIENT AT A TIME on that socket: a second reader silently steals the bytes. While
# this capture runs, `lab-vm.sh console <vm>` will see nothing — read the log instead.
CAPTURE_PID=""
start_capture() {
    command -v socat >/dev/null 2>&1 || die "socat is required to capture the guest console (the console is a unix socket, not a file)"
    : > "$(console)"
    socat -u "UNIX-CONNECT:$(serial_sock)" "OPEN:$(console),append" >/dev/null 2>&1 &
    CAPTURE_PID=$!
}
stop_capture() {
    # BY PID. Never `pkill -f serial.sock`: QEMU's own command line carries that exact path,
    # and in this repo that pattern has killed a live VM and the agent's shell (exit 144).
    if [[ -n "$CAPTURE_PID" ]]; then
        kill "$CAPTURE_PID" 2>/dev/null || true
        wait "$CAPTURE_PID" 2>/dev/null || true
    fi
    CAPTURE_PID=""
}

host_binding() { ip -d link show vxlan.calico 2>/dev/null | grep -oE 'local [0-9.]+ dev [a-zA-Z0-9._-]+' || echo '<absent>'; }

case "${1:-}" in
up)
    command -v qemu-img >/dev/null 2>&1 || die "qemu-img is required to resize the overlay"
    [[ -x "$LAB_VM" ]] || die "phase-2 driver not executable: $LAB_VM"

    HOST_BEFORE="$(host_binding)"
    info "host Calico binding BEFORE (recorded so teardown can prove we did not move it):"
    info "  $HOST_BEFORE"

    bash "$LAB_VM" create --config "$SPEC" || die "create failed"

    # THE RESIZE, and why it is here rather than in the spec. The cached Debian cloud image
    # is 3 GiB virtual; microk8s wants ~10. `disk_size` in a spec only reaches the
    # from-chroot backend, so the overlay is grown directly — cloud-init's `growpart` (on by
    # default in every stock cloud image) extends the root partition into it on first boot.
    disk="$(vm_state_dir)/disk.qcow2"
    [[ -f "$disk" ]] || die "expected an overlay at $disk after create"

    # READ THE TOP-LEVEL virtual-size, and do it with a JSON parser.
    #
    # The first draft grepped `"virtual-size"` out of the JSON with sed and took `head -1`.
    # That is the WRONG match: qemu-img nests a `children[].info` block describing the
    # qcow2 FILE, whose virtual-size appears first. So the guard compared the file's size
    # rather than the disk's — and it PASSED, because writing new metadata makes the file
    # marginally bigger. It reported "grown 0M -> 0M" and carried on: a guard that cannot
    # detect the failure it exists for, which is the cheap check answering a different,
    # easier question. Caught 2026-08-07 by reading its own output instead of its exit code.
    vsize() { qemu-img info --output=json "$1" \
                | python3 -c 'import json,sys; print(json.load(sys.stdin)["virtual-size"])'; }

    before="$(vsize "$disk")" || die "could not read the overlay's virtual size"
    qemu-img resize "$disk" "$DISK_SIZE" >/dev/null || die "could not resize the overlay to $DISK_SIZE"
    after="$(vsize "$disk")" || die "could not re-read the overlay's virtual size"
    (( after > before )) \
        || die "the overlay did not grow: virtual-size is still $((after / 1024 / 1024))M.
cloud-init would then run out of space installing microk8s, and the failure would surface as
a snap error with nothing pointing back here."
    info "overlay virtual-size $(( before / 1024 / 1024 ))M -> $(( after / 1024 / 1024 ))M"

    bash "$LAB_VM" start "$VM" || die "start failed"
    start_capture
    trap stop_capture EXIT

    # Wait on the guest's OWN marker, not on a sleep. The console is the only channel that
    # works before the network does, so a guest that fails to install still tells us so.
    info "waiting up to ${READY_TIMEOUT}s for the cluster (first boot pulls ~200 MB of snap)"
    c="$(console)"; t0=$SECONDS
    while (( SECONDS - t0 < READY_TIMEOUT )); do
        if [[ -f "$c" ]] && grep -q 'NCS-READY-FOR-EXPERIMENT' "$c" 2>/dev/null; then
            # The character class needs LOWERCASE: without it `NCS-CALICO=docker.io/...`
            # printed as a bare `NCS-CALICO=` and read as an empty marker twice — the
            # display truncating a value that was there all along.
            grep -oE 'NCS-[A-Za-z0-9=./:_-]+' "$c" | sort -u | sed 's/^/  /' >&2
            grep -q 'NCS-K8S-READY' "$c" \
                || die "the guest booted but the cluster never became ready — see $c"
            info "cluster ready after $((SECONDS - t0))s"
            exit 0
        fi
        sleep 10
    done
    die "timed out after ${READY_TIMEOUT}s; console: $c" ;;

experiment)
    # `-o StrictHostKeyChecking=no` is not needed: lab-vm.sh's ssh verb manages its own
    # known_hosts for the VM it created.
    info "copying guest-experiment.sh into the guest and running it as root"
    bash "$LAB_VM" ssh "$VM" -- 'cat > /tmp/guest-experiment.sh' < "$HERE/guest-experiment.sh" \
        || die "could not copy the experiment into the guest"
    # `set -e` would exit on a non-zero ssh BEFORE `rc=$?` ever ran, so the status is
    # captured in the same statement. The experiment's own exit code is the verdict and must
    # reach the caller intact.
    rc=0
    bash "$LAB_VM" ssh "$VM" -- 'sudo NCS_POLL_WAIT='"${NCS_POLL_WAIT:-240}"' bash /tmp/guest-experiment.sh' || rc=$?
    info "host Calico binding AFTER the experiment: $(host_binding)"
    exit $rc ;;

cni-chaos)
    # Same shape as `experiment`: the script travels in and runs as root there. It is a
    # separate verb rather than a flag because it takes ~10 minutes, deletes things, and
    # nobody should reach it by accident.
    info "copying cni-chaos.sh into the guest and running it as root (~10 min: it waits out"
    info "  each layer's recovery rather than sampling once)"
    bash "$LAB_VM" ssh "$VM" -- 'cat > /tmp/cni-chaos.sh' < "$HERE/cni-chaos.sh" \
        || die "could not copy the chaos script into the guest"
    rc=0
    bash "$LAB_VM" ssh "$VM" -- 'sudo CNI_RECOVER_WAIT='"${CNI_RECOVER_WAIT:-240}"' bash /tmp/cni-chaos.sh' || rc=$?
    info "host Calico binding AFTER the chaos run: $(host_binding)"
    exit $rc ;;

status)
    bash "$LAB_VM" ssh "$VM" -- 'ip -d link show vxlan.calico 2>/dev/null | grep -oE "local [0-9.]+ dev [a-zA-Z0-9._-]+" || echo "<absent>"' 2>/dev/null \
        | sed 's/^/  guest: /' || info "  guest: unreachable"
    printf '  host : %s   <- must be unchanged by anything this lab does\n' "$(host_binding)" >&2 ;;

down)
    bash "$LAB_VM" destroy "$VM" --force || die "destroy failed"
    info "host Calico binding after teardown: $(host_binding)" ;;

*)
    sed -n '3,8p' "$0" >&2; exit 1 ;;
esac
