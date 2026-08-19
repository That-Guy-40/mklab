#!/usr/bin/env bash
# run-privileged-demo.sh — the privileged run of this lab, as a script instead of a habit.
#
#   sudo -E examples/micro-cloud/run-privileged-demo.sh            # bring up, probe, tear down
#   sudo -E examples/micro-cloud/run-privileged-demo.sh --reset    # destroy earlier state first
#        examples/micro-cloud/run-privileged-demo.sh --help
#
# ─────────────────────────────────────────────────────────────────────────────
# WHY THIS IS IN THE REPO AND NOT IN /tmp
#
# It lived in a scratch directory for five runs and a reboot took it. That is the second
# time this lab has lost a privileged harness to a temp directory — `fabric.sh` was
# recovered from a session transcript by replaying a Write and eleven Edits (plan §18.1),
# and its header still opens with *"THIS FILE WAS ALMOST LOST, WHICH IS THE FIRST THING TO
# KNOW ABOUT IT."*  A procedure that has been run five times, that encodes every ordering
# constraint the runs discovered, and that MANUAL_TESTING.md's success signature is filled
# in from, is not scratch work. It is the lab.
#
# WHAT IT DOES THAT `micro-cloud.sh up` DOES NOT
#
#   1. It brackets everything with an INDEPENDENT recording of the live CNI's state —
#      tunnel binding, pod veth count, ip_forward, and both engine bridges' membership —
#      and diffs it at the end. `fabric.sh` makes the same comparison internally; this one
#      is derived separately, so a regression in the fabric's own comparison cannot hide
#      behind it. On this host a live Calico cluster's endpoint sits on a bridge that is
#      down and memberless (LEDGER L10-1), so that is not a formality.
#   2. It WAITS FOR READINESS. `up` returns when the VMMs are running; a guest still has to
#      boot and finish DHCP after that (LEDGER L10-2). Everything that reads state does so
#      after the wait, which is the difference between measuring the lab and measuring the
#      race.
#   3. It asks the capstone question the way it has to be asked — from `edge`, at the
#      address the FABRIC leased it, with resolution and reachability as SEPARATE probes.
#      Not `lab-vm.sh ssh`: that verb needs a slirp hostfwd a tap-mode VM does not have,
#      and phase 2 now refuses it by name (LEDGER L10-8).
#
# WHAT `--reset` DESTROYS, so you can read it before passing it
#
#   lab-vm.sh     stop/destroy edge          lab-fc.sh destroy api1, api2
#   lab-podman.sh down --lab micro-cloud     lab-lxd.sh down --lab micro-cloud
#   lab-chroot.sh destroy micro-cloud-base   <-- deletes the chroot tree
#
# Each is addressed BY NAME through the tool that created it. Nothing is removed by
# pattern and this script runs no `rm`. It is opt-in because `down` deliberately does not
# destroy microVMs or VMs, and `create` deliberately refuses one that exists — the
# halt-don't-converge contract, which is correct and which makes a repeat run need this.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "$HERE/../.." && pwd)"
MC="$HERE/micro-cloud.sh"
FABRIC="$HERE/fabric.sh"
LEASES="${MC_LEASES:-/run/mklab-mc/leases}"
DO_RESET=0

usage() {
    cat <<EOF
run-privileged-demo.sh — bring this lab up for real, probe it, and tear it down.

USAGE
  sudo -E $0 [--reset]

  --reset   destroy what earlier runs left first (edge, api1, api2, the chroot,
            and the podman/lxd labs), each through its own tool, by name.
            Needed for a repeat run: 'down' does not destroy and 'create'
            refuses an instance that already exists.

  -E on sudo matters: it carries XDG_RUNTIME_DIR through for rootless podman.

Reads no arguments beyond those. The log path is printed at the end.
EOF
}

case "${1:-}" in
    --reset) DO_RESET=1 ;;
    --help|-h) usage; exit 0 ;;
    "") ;;
    *) printf 'unknown argument: %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
esac

[[ $EUID -eq 0 ]] || { echo "this needs root (the fabric does). Re-run: sudo -E $0 ${1:-}" >&2; exit 1; }

# The invoking user's paths, not root's. `runuser` sets HOME, but PATH and the state dir
# are ours to get right: the pinned firecracker lives in the slice-3 workdir rather than on
# PATH, and root and the user must agree on LAB_STATE_DIR or root creates instances a later
# unprivileged `status` cannot see.
REAL_USER="${SUDO_USER:-root}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
export PATH="$REAL_HOME/.local/state/lab-create/micro-cloud-s3:$PATH"
export LAB_STATE_DIR="${LAB_STATE_DIR:-$REAL_HOME/.local/state/lab-create}"
IMG="$HERE/images"
LOG="$LAB_STATE_DIR/micro-cloud-demo.log"
mkdir -p "$LAB_STATE_DIR"
asuser() { runuser -u "$REAL_USER" -- "$@"; }

exec > >(tee "$LOG") 2>&1
echo "=============================================================="
echo " micro-cloud privileged demo   $(date -u +%FT%TZ)"
echo " user=$REAL_USER  state=$LAB_STATE_DIR  reset=$DO_RESET"
echo "=============================================================="

# ── the independent observation ─────────────────────────────────────────────
snapshot_theirs() {
    echo "  tunnel   : $(ip -d link show vxlan.calico 2>/dev/null | grep -oE 'local [0-9.]+ dev [a-zA-Z0-9._-]+' || echo none)"
    echo "  cali veth: $(ip -o link show 2>/dev/null | grep -cE ': cali[0-9a-f]+@')"
    echo "  forward  : $(cat /proc/sys/net/ipv4/ip_forward)"
    echo "  lxdbr0   : operstate=$(cat /sys/class/net/lxdbr0/operstate 2>/dev/null || echo absent) members=$(ls /sys/class/net/lxdbr0/brif 2>/dev/null | wc -l)"
    echo "  incusbr0 : operstate=$(cat /sys/class/net/incusbr0/operstate 2>/dev/null || echo absent) members=$(ls /sys/class/net/incusbr0/brif 2>/dev/null | wc -l)"
}
BEFORE="$(snapshot_theirs)"
echo; echo "### 0. BEFORE — what belongs to the cluster and the engines"; echo "$BEFORE"
step() { echo; echo "### $*   (t+${SECONDS}s)"; }

# ── reset ───────────────────────────────────────────────────────────────────
if (( DO_RESET )); then
    step "R. RESET — each object through the tool that made it, by name"
    asuser "$REPO/phase2-qemu-vm/lab-vm.sh"     stop    edge                    2>&1 | sed 's/^/  /'
    asuser "$REPO/phase2-qemu-vm/lab-vm.sh"     destroy edge   --force          2>&1 | sed 's/^/  /'
    asuser "$REPO/phase7-firecracker/lab-fc.sh" destroy api1   --force          2>&1 | sed 's/^/  /'
    asuser "$REPO/phase7-firecracker/lab-fc.sh" destroy api2   --force          2>&1 | sed 's/^/  /'
    asuser "$REPO/phase4-podman/lab-podman.sh"  down --lab micro-cloud          2>&1 | sed 's/^/  /'
    asuser "$REPO/phase5-lxd/lab-lxd.sh"        down --lab micro-cloud          2>&1 | sed 's/^/  /'
    "$REPO/phase1-chroot/lab-chroot.sh"         destroy micro-cloud-base --force 2>&1 | sed 's/^/  /'
fi

# ── step 0 — the spine and the export db imports ────────────────────────────
# RUNBOOK step 0. It is here rather than in `up` because a chroot is a BUILD INPUT: the
# instances consume its EXPORTS, and the control plane has no slot that emits an export
# step, so a [[chroot]] block in the runtime spec was circular (LEDGER L10-10).
#
# `--include systemd-sysv` is the flag the lab failed without: a Debian minbase tree has NO
# /sbin/init, which is fine for a microVM and fatal for a system container, and `db` is the
# system-container case (LEDGER L10-11).
step "0. STEP 0 — the spine, and db's image"
if [[ -d /var/chroots/micro-cloud-base ]]; then
    echo "  chroot exists; leaving it alone (pass --reset to rebuild it)"
    if [[ ! -e /var/chroots/micro-cloud-base/sbin/init ]]; then
        echo "  !! it has NO /sbin/init — this tree predates --include systemd-sysv, and"
        echo "  !! 'db' will fail at launch with 'forklxc … exit status 1'. Re-run with"
        echo "  !! --reset to rebuild it. See LEDGER L10-11."
    fi
else
    "$REPO/phase1-chroot/lab-chroot.sh" create \
        --backend debootstrap --distro debian --suite bookworm --arch x86_64 \
        --variant minbase --manager none --include systemd-sysv \
        --name micro-cloud-base --target /var/chroots/micro-cloud-base --lab micro-cloud \
        2>&1 | tail -3 | sed 's/^/  /'
fi
if [[ ! -e /var/chroots/micro-cloud-base/sbin/init ]] || [[ ! -r "$IMG/micro-cloud-base.tar.gz" ]] || (( DO_RESET )); then
    "$REPO/phase1-chroot/lab-chroot.sh" export-tarball micro-cloud-base \
        --output "$IMG/micro-cloud-base.tar.gz" --force 2>&1 | tail -2 | sed 's/^/  /'
    chown "$REAL_USER" "$IMG/micro-cloud-base.tar.gz" 2>/dev/null || true
fi
echo "  /sbin/init in the tree : $([[ -e /var/chroots/micro-cloud-base/sbin/init ]] && echo present || echo 'ABSENT — db will not launch')"
ls -l "$IMG/micro-cloud-base.tar.gz" 2>&1 | awk '{print "  db image             :", $3, $5}'
# The microVM ext4s are left alone on purpose: the ones in place are a BusyBox tree from
# slices 1/3 whose SLICE3-* console markers are what the microVM half is proved by, and a
# Debian minbase would boot systemd and print none of them.
ls -l "$IMG"/api1.ext4 "$IMG"/api2.ext4 2>&1 | awk '{print "  microVM image        :", $3, $5, $9}'

# ── up ──────────────────────────────────────────────────────────────────────
step "1. up — the full spec"
"$MC" up; UP_RC=$?
echo "    -> up rc=$UP_RC"

# ── readiness, which `up` deliberately does not wait for ────────────────────
step "2. waiting for READINESS (up returns on invocation, not state)"
EDGE_IP=""; EDGE_SSH=no
for _ in $(seq 1 60); do
    EDGE_IP="$(awk '$4 == "edge" { print $3 }' "$LEASES" 2>/dev/null | head -1)"
    [[ -n "$EDGE_IP" ]] && break
    sleep 5
done
if [[ -n "$EDGE_IP" ]]; then
    echo "  edge leased $EDGE_IP  (t+${SECONDS}s)"
    for _ in $(seq 1 60); do
        if asuser ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
                      -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
                      "lab@$EDGE_IP" true >/dev/null 2>&1; then
            EDGE_SSH=yes; echo "  edge answered ssh   (t+${SECONDS}s)"; break
        fi
        sleep 5
    done
    [[ "$EDGE_SSH" == yes ]] || echo "  edge never answered ssh in 300s"
else
    echo "  edge took no lease in 300s. The console is the ground truth:"
    tail -20 "$LAB_STATE_DIR/vms/edge/console.log" 2>/dev/null | sed 's/^/    /' \
        || echo "    (no console.log — is this an older VM, made before the logfile= fix?)"
fi

step "3. status"
"$MC" status

step "4. every instance, in its own words"
for n in api1 api2; do
    printf '  %-7s ' "$n"
    asuser "$REPO/phase7-firecracker/lab-fc.sh" inspect "$n" 2>&1 | sed -n 's/^state = //p'
done
asuser "$REPO/phase2-qemu-vm/lab-vm.sh"      list                     2>&1 | tail -2 | sed 's/^/  /'
asuser "$REPO/phase5-lxd/lab-lxd.sh"         list --lab micro-cloud   2>&1 | tail -6 | sed 's/^/  /'
asuser "$REPO/phase4-podman/lab-podman.sh"   status micro-cloud       2>&1 | tail -6 | sed 's/^/  /'
echo "  -- leases --";        sed 's/^/    /' "$LEASES" 2>/dev/null
echo "  -- br-mc0 members --"; ls /sys/class/net/br-mc0/brif 2>/dev/null | tr '\n' ' '; echo

# ── the capstone ────────────────────────────────────────────────────────────
step "5. CAPSTONE — heterogeneous instances, one L2, resolved BY NAME"
if [[ "$EDGE_SSH" == yes ]]; then
    e() {
        asuser ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
                   -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
                   -o LogLevel=ERROR "lab@$EDGE_IP" "$1" 2>&1
    }
    echo "  from edge ($EDGE_IP):"
    printf '    hostname        -> %s\n' "$(e 'hostname')"
    printf '    address         -> %s\n' "$(e "ip -4 -o addr show scope global | awk '{print \$4}' | tr '\n' ' '")"
    # RESOLUTION and REACHABILITY, separately: ping answering proves both at once and says
    # nothing about which broke when it fails.
    for peer in api1 api2 db; do
        printf '    getent %-5s    -> %s\n' "$peer" "$(e "getent hosts $peer")"
    done
    for peer in api1 db; do
        printf '    ping %-7s   -> %s\n' "$peer" "$(e "ping -c2 -W3 $peer 2>&1 | tail -2 | tr '\n' ' '")"
    done
else
    echo "  UNKNOWN — edge unreachable, so the claim was not tested. Not a failed claim."
fi
echo "  -- api1's own console, from the inside --"
sed -n '/SLICE3-BEGIN/,$p' "$LAB_STATE_DIR/fc/api1/fc.log" 2>/dev/null | head -8 | sed 's/^/    /'

step "6. §9.3 isolation matrix"
MC_LEASES="$LEASES" asuser bash "$HERE/tests/test-isolation-matrix.sh" 2>&1 | tail -30

DURING="$(snapshot_theirs)"; echo; echo "### 7. DURING"; echo "$DURING"

step "8. down"
"$MC" down; DOWN_RC=$?
echo "    -> down rc=$DOWN_RC"

step "9. absence, checked independently of the fabric's own assertion"
echo "  br-mc0   : $([[ -d /sys/class/net/br-mc0 ]] && echo 'STILL PRESENT <-- bad' || echo absent)"
echo "  mc-* taps: $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -c '^mc-')"

AFTER="$(snapshot_theirs)"; echo; echo "### 10. AFTER"; echo "$AFTER"
echo; echo "=============================================================="
if [[ "$BEFORE" == "$AFTER" ]]; then
    echo "VERDICT: the cluster and both engine bridges are UNCHANGED across the run."
else
    echo "VERDICT: *** SOMETHING OF THEIRS MOVED *** — this is the F.6 shape:"
    diff <(echo "$BEFORE") <(echo "$AFTER")
fi
echo
echo "up rc=$UP_RC   down rc=$DOWN_RC   edge=${EDGE_IP:-none} ssh=$EDGE_SSH   elapsed=${SECONDS}s"
echo
echo "Persisting by design (this script never destroys them without --reset):"
echo "  chroot   : sudo $REPO/phase1-chroot/lab-chroot.sh destroy micro-cloud-base"
echo "  edge     : $REPO/phase2-qemu-vm/lab-vm.sh destroy edge --force"
echo "  microVMs : $REPO/phase7-firecracker/lab-fc.sh destroy api1 --force   (and api2)"
echo
echo "log: $LOG"
echo "=============================================================="
