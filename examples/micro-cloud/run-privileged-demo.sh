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
    if [[ ! -e /var/chroots/micro-cloud-base/etc/network/interfaces ]] \
       || [[ ! -L /var/chroots/micro-cloud-base/etc/systemd/system/multi-user.target.wants/networking.service ]]; then
        echo "  !! this tree has no ifupdown network config — 'db' will start, get its veth"
        echo "  !! on br-mc0, and never ask for an address: present on the L2 and invisible"
        echo "  !! on the network. --reset rebuilds it. LEDGER L10-13 / L10-16."
    fi
else
    # TWO consumer-specific requirements, both found by running it, both on `db`:
    #
    #   --include systemd-sysv   a minbase tree has NO /sbin/init, and LXC execs it. Fine for
    #                            a microVM (slice 1 supplies its own init) and fatal for a
    #                            system container. LEDGER L10-11.
    #   a network stack          minbase has NO dhclient, ifupdown, udhcpc or iproute2, so
    #                            `db` came up, got its veth on br-mc0, and NOTHING EVER ASKED
    #                            FOR AN ADDRESS -- on the L2 physically and invisible on the
    #                            network. LEDGER L10-13.
    #
    # IFUPDOWN RATHER THAN systemd-networkd, AND THE REASON IS MEASURED. The first attempt
    # enabled networkd, and it ran -- `systemctl is-active` said active, the .network file was
    # in place -- and still configured nothing. Its own journal said why:
    #
    #     lo: Link UP / lo: Gained carrier / Enumeration completed
    #     vethce0469d8: Interface name change detected, renamed to eth0.
    #
    # It handled `lo` (loopback needs no udev), finished enumerating, watched eth0 appear, and
    # stopped there. systemd-networkd waits for **udev** to mark a link initialized before
    # configuring it, and this tree has no systemd-udevd at all: Debian ships udev as its own
    # package and `systemd-sysv` does not pull it. ifupdown is a boot-time script with no such
    # dependency, which is why it is the conventional path in a container. LEDGER L10-16.
    #
    #   send host-name "db"      dhclient sends /etc/hostname by default, and lab-chroot.sh
    #                            bakes a RANDOM one into the tree (`badass-box-qmhu`). dnsmasq
    #                            registers whatever it is told, so without this `db` resolves
    #                            under a name nobody can guess.
    #   iproute2                 not for the lab -- for the DIAGNOSTIC. `ip: not found` is why
    #                            two probes in the previous run returned nothing.
    #
    # TWO DETAILS THAT ARE NOT INCIDENTAL, both found by checking instead of running:
    #
    #   ENABLED BY SYMLINK, not by `systemctl enable`. `systemctl` inside a chroot has no
    #   running systemd to talk to and its behaviour there varies by version -- some refuse
    #   with "Running in chroot, ignoring request". The symlink IS what enable creates, it is
    #   the same thing on every version, and unlike the command its effect is checkable with
    #   `ls`. This script checks for it below.
    #
    #   Hostname=db IN THE DHCP REQUEST. dnsmasq serves DNS for names it learns from DHCP
    #   (--domain --expand-hosts), but LXD sets the container's hostname to the INSTANCE name
    #   -- `lab-micro-cloud-db` -- so `db` would have registered under that and `getent db`
    #   from `edge` would still have failed. `db` has no fabric reservation to fall back on
    #   either: `fabric.sh tap` reserves against a MAC for instances that take a TAP, and this
    #   one takes an LXD veth. So the name has to travel in the request itself.
    #
    # A microVM needs neither of these (its init DHCPs itself); an OCI container needs neither
    # (podman supplies the namespace and the command). Only the system container needs both,
    # which is what "universal userspace" costs.
    "$REPO/phase1-chroot/lab-chroot.sh" create \
        --backend debootstrap --distro debian --suite bookworm --arch x86_64 \
        --variant minbase --manager none \
        --include systemd-sysv,ifupdown,isc-dhcp-client,iproute2 \
        --post-command 'mkdir -p /etc/network /etc/dhcp /etc/systemd/system/multi-user.target.wants' \
        --post-command 'printf "auto lo\niface lo inet loopback\n\nauto eth0\niface eth0 inet dhcp\n" > /etc/network/interfaces' \
        --post-command 'printf "send host-name \"db\";\n" >> /etc/dhcp/dhclient.conf' \
        --post-command 'ln -sf /lib/systemd/system/networking.service /etc/systemd/system/multi-user.target.wants/networking.service' \
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

# ── why does db have no address? ASK IT. ────────────────────────────────────
# Two rounds of this were diagnosed by inference — first "it has no init", then "it has no
# DHCP client" — and each cost a privileged run to test a guess. The container is running,
# `lab-lxd.sh exec` demonstrably works (the isolation matrix probes through it), and every
# fact needed is one command away inside it. So it is asked rather than reasoned about, and
# the answers are printed whether or not it worked: a run where `db` DID get an address
# should show that too, or the block becomes a thing that only ever appears on failure and
# nobody knows what healthy looks like.
step "4b. db's own view of its network (asked, not inferred)"
dbx() { asuser "$REPO/phase5-lxd/lab-lxd.sh" exec micro-cloud/db -- sh -c "$1" 2>&1 | sed 's/^/      /'; }
if asuser "$REPO/phase5-lxd/lab-lxd.sh" exec micro-cloud/db -- true >/dev/null 2>&1; then
    echo "    interfaces:";        dbx 'ip -o link show | cut -d: -f2 | tr -d " "'
    echo "    addresses:";         dbx 'ip -4 -o addr show | awk "{print \$2, \$4}"'
    echo "    hostname:";          dbx 'hostname'
    # ASK ABOUT THE MECHANISM ACTUALLY IN USE. The first version of this block probed
    # systemd-networkd -- and stayed pointed at it after the lab switched to ifupdown, so a
    # run whose whole question was "did ifupdown bring eth0 up" answered "networkd is
    # inactive", which is both true and beside the point. A diagnostic aimed at the previous
    # design is a diagnostic that confirms the previous design is gone.
    echo "    networking.service:"; dbx 'systemctl is-active networking 2>&1; systemctl is-enabled networking 2>&1'
    echo "    interfaces file:";    dbx 'cat /etc/network/interfaces 2>&1'
    echo "    dhclient present:";   dbx 'command -v dhclient || echo "NOT INSTALLED"'
    echo "    dhclient leases:";    dbx 'ls -la /var/lib/dhcp/ 2>&1 | head -5'
    echo "    networking log:";     dbx 'journalctl -u networking --no-pager -n 20 2>&1 || echo "(no journal)"'
    echo "    ifup by hand:";       dbx 'ifup eth0 2>&1 | tail -5; echo "rc=$?"; ip -4 -o addr show eth0 2>&1'
    # networkd is kept only to confirm it is NOT the thing running, since a half-migration
    # with both managers would look like this too.
    echo "    (networkd, expect inactive):"; dbx 'systemctl is-active systemd-networkd 2>&1'
else
    echo "    db is not exec-able, so nothing could be asked of it"
fi

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
