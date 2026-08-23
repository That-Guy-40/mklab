#!/usr/bin/env bash
# Verdict: §9.3's capstone — what each compute type can see of the others, MEASURED, with
# every row it could not run named as UNKNOWN rather than quietly dropped.
#
#   > v2 assumed heterogeneity-on-one-L2 was the payload.  v3 disagrees.  Two microVMs on a
#   > bridge is a *networking* exercise.  A microVM beside a rootless container on the same
#   > fabric is a *security* exercise … So the capstone is not "can they ping" — it is:
#   > **What can each of these four things see of the others, and what did each boundary
#   > cost?**
#
# WHY THIS FILE MEASURES A BOUNDARY AND NOT A FEATURE
# ---------------------------------------------------
# The tempting version of this test asserts that a container "is isolated" by checking that
# some namespace file exists.  That is the mechanism, and this repo has a table of what
# happens next: an assertion naming HOW the code works passes when that mechanism is present
# and broken.  A `/proc/self/ns/pid` symlink proves a PID namespace was created; it says
# nothing about what is visible through it.  So every probe below is phrased as a QUESTION
# ABOUT VISIBILITY and answered by looking:
#
#   pids      how many processes can this thing enumerate, and can it see the host's init?
#   procfs    is /proc its own, or the host's?  (read a value only the host has)
#   netns     does it share the host's network namespace — the rootless-podman asymmetry
#   dmesg     can it read the kernel ring buffer, i.e. the HOST's kernel log
#   kvm       can it open /dev/kvm — the device that grants the power to make more of these
#   clock     can it change the time, or only read it
#   uid       what does root inside map to outside
#
# THE HOST ROW IS THE CONTROL, AND IT IS NOT DECORATION
# -----------------------------------------------------
# Without it, "the container could not see 400 processes" is unfalsifiable — maybe nothing
# can.  The host row is what makes every other row a COMPARISON.  It also catches the
# failure this repo keeps meeting from the other side: if the host row and the container row
# agree on everything, the container is not isolated at all and the matrix would otherwise
# report a tidy table of identical numbers as though that were a result.
#
# WHAT RUNS UNPRIVILEGED, AND WHAT DOES NOT
# ------------------------------------------
# The container and host rows need nothing but podman, so they run in CI.  The microVM, VM
# and LXD rows need KVM, images, and a fabric that needs root — they are reported as
# UNKNOWN, BY NAME, with the reason.  "I could not check this" must never render as "this is
# fine": the summary lists exactly which rows were not measured, and the privileged run that
# fills them in is MANUAL_TESTING.md's.
set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

need podman
have jq || skip "jq is needed to read podman's own answers back"

WORK="$(mktemp -d)"
on_exit 'rm -rf -- "$WORK"'

CTR="mc-isolation-probe-$$"
# Kill by NAME through podman's own lifecycle verb, never by pattern: `pkill -f` on a
# container name matches every process whose argv carries it, and on this host that has
# included the workload being protected.
on_exit 'podman rm -f "'"$CTR"'" >/dev/null 2>&1 || true'

UNKNOWN_ROWS=()
unknown() { UNKNOWN_ROWS+=("$1 — $2"); }

# ── the probes, one implementation, run in whichever context is passed in ────
# `runner` is a function name: it takes a shell command and runs it in that row's context.
probe_all() {
    local runner="$1" label="$2"
    local pids init_seen procfs netns dmesg kvm uid

    pids="$("$runner" 'ls -d /proc/[0-9]* 2>/dev/null | wc -l')"
    init_seen="$("$runner" 'grep -qs "^Name:" /proc/1/status && head -2 /proc/1/status | sed -n "s/^Name:\s*//p" || echo "-"')"
    # A value only the real /proc has: the host's boot id.  If the row reads the SAME id the
    # host does, its /proc is the host's — whatever mount table says otherwise.
    procfs="$("$runner" 'cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "-"')"
    netns="$("$runner" 'readlink /proc/self/ns/net 2>/dev/null || echo "-"')"
    # NOT `dmesg | tail -1 && echo readable`. That was the first version and it reported
    # BOTH rows readable on a host with kernel.dmesg_restrict=1, where neither is: the exit
    # status of a pipeline is the LAST element's, so it was reporting on `tail`, which
    # succeeds over an empty input. The repo's own standing rule — never pipe a command
    # whose exit status is the gate — arriving inside the test written to catch checks that
    # measure the wrong thing.
    dmesg="$("$runner" 'if dmesg >/dev/null 2>&1; then echo readable; else echo refused; fi')"
    kvm="$("$runner" 'test -r /dev/kvm && echo open || echo closed')"
    uid="$("$runner" 'id -u 2>/dev/null || echo "-"')"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$label" "$pids" "$init_seen" "${procfs:0:8}" "${netns//[^0-9]/}" "$dmesg" "$kvm" "$uid"
}

run_host() { bash -c "$1" 2>/dev/null; }
run_ctr()  { podman exec "$CTR" sh -c "$1" 2>/dev/null; }

# ── the two rows a LIVE lab makes measurable, and the two it does not ────────
# Each runner is just "run this shell command in that instance's context". The rows differ
# only in how the command gets there, which is the point: the boundary is what changes, not
# the question.
run_lxd()  { "$REPO_DIR/phase5-lxd/lab-lxd.sh" exec micro-cloud/db -- sh -c "$1" 2>/dev/null; }
run_edge() { ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                 -o ConnectTimeout=5 "lab@$EDGE_IP" "$1" 2>/dev/null; }

# `db` is reachable when the engine says it is running.
#
# NOT `(RUNNING|running)`, which is what this was. Incus prints **`Running`** — a third
# capitalisation the alternation did not enumerate — so on the first run where `db` actually
# came up, the matrix reported it UNKNOWN ("no running LXD instance named 'db'") while
# `lab-lxd.sh list` showed it `Running` three lines earlier in the same log. A FALSE UNKNOWN,
# for the third time in this lab, and the same shape each time: a format guessed at instead
# of asked about (`inspect --json`, `lab =`, and now this).
#
# Enumerating spellings is the bug. Case-folding removes the class rather than adding the
# third member to it.
db_up() {
    "$REPO_DIR/phase5-lxd/lab-lxd.sh" list --lab micro-cloud 2>/dev/null \
        | grep -qiE '\bdb\b.*\brunning\b'
}

# `edge` is reachable at the address the FABRIC leased it — never a number from a doc, and
# never `lab-vm.sh ssh`, which connects to a slirp hostfwd a tap-mode VM does not have.
EDGE_IP=""
edge_up() {
    local leases="${MC_LEASES:-/run/mklab-mc/leases}"
    [[ -r "$leases" ]] || return 1
    EDGE_IP="$(awk '$4 == "edge" { print $3 }' "$leases" | head -1)"
    [[ -n "$EDGE_IP" ]] || return 1
    run_edge true >/dev/null 2>&1
}

# ── the microVM row ──────────────────────────────────────────────────────────
# THE PROBE HAS TO EXECUTE INSIDE THE GUEST, because a microVM's boundary is a hypervisor:
# there is no `exec` verb to borrow and no /proc to read from outside.  Slice 5c built the
# channel that reaches in -- vsock, which needs no bridge, no lease and no root -- and its
# agent now answers `EXEC <cmd>` with that command's stdout, verbatim.
#
# WHY EXEC AND NOT SEVEN PURPOSE-BUILT REPLIES. The matrix's integrity is that ONE
# implementation of the probes runs in every context: the runner changes, the question does
# not.  Had the agent answered the seven questions in C, this row alone would have been
# computed by different code, and a row that differed from the container's would no longer
# distinguish "the boundary differs" from "that C is wrong" -- the exact confusion the
# matrix exists to remove.
#
# THIS GUEST IS BOOTED BY THE TEST, exactly as the container row's is, and the same caveat
# applies in the same place: it is the lab's compute type, configured as the lab configures
# it, not the lab's running instance.  Two honest differences, neither of which touches what
# the row measures: its image carries the agent (slice-3's does not), and it has NO tap,
# because a hypervisor boundary does not become a different boundary for having a NIC.
FC_PORT=1234
S3="${MC_STATE_DIR:-$HOME/.local/state/lab-create/micro-cloud-s3}"
FC_BIN="${MC_FIRECRACKER:-$S3/firecracker}"
# ONE ANSWER TO "WHERE IS THE VMM". This file resolves the binary itself (it launches
# Firecracker directly) AND shells out to lab-fc.sh, which used to resolve it from PATH --
# the D8 seam: two tools, two answers, and nothing making them agree. Since 2026-08-23 the
# driver takes $LAB_FC_BIN, so exporting it here means both halves run the SAME binary
# rather than the same version by luck. TODO §11.5.
export LAB_FC_BIN="$FC_BIN"
FC_KERNEL="${MC_KERNEL:-$S3/vmlinux}"
FC_BASE="${MC_ROOTFS:-$S3/api1.ext4}"
FC_UDS=""; FC_WHY=""; FC_LABEL="api (firecracker microvm, vsock)"

run_fc() { python3 "$LAB_DIR/vsock-probe.py" --engine firecracker \
               --uds "$FC_UDS" --port "$FC_PORT" --exec "$1" --timeout 10 2>/dev/null; }

# Returns non-zero WITH A REASON in FC_WHY, so an unmeasured row can say which precondition
# was missing instead of reporting a generic absence.
fc_boot() {
    have python3            || { FC_WHY="python3 is absent, and vsock-probe.py is the host end of this channel"; return 1; }

    # PREFER THE LAB'S OWN api1 when it is running with a vsock socket. The spec declares
    # `vsock = true` for both microVMs, so on a privileged run this row stops being a
    # stand-in and becomes the instance the rest of the matrix is about. The socket EXISTING
    # is not enough to use it -- Firecracker creates the file whether or not anything in the
    # guest listens -- so it has to answer first, and if it does not we boot our own rather
    # than report an UNKNOWN that a fallback could have avoided.
    local _u
    _u="$("$REPO_DIR/phase7-firecracker/lab-fc.sh" inspect api1 2>/dev/null \
            | sed -n 's/^vsock_uds = "\(.*\)"$/\1/p')"
    if [[ -n "$_u" && -S "$_u" ]]; then
        FC_UDS="$_u"
        if [[ "$(run_fc 'echo MC-ALIVE')" == *MC-ALIVE* ]]; then
            FC_LABEL="api1 (firecracker microvm, the LAB's own)"
            note "the lab's api1 answers over vsock, so this row is the real instance rather than a stand-in"
            return 0
        fi
        FC_UDS=""
    fi

    [[ -x "$FC_BIN" ]]      || { FC_WHY="no firecracker binary at $FC_BIN (set MC_FIRECRACKER)"; return 1; }
    [[ -r "$FC_KERNEL" ]]   || { FC_WHY="no guest kernel at $FC_KERNEL (set MC_KERNEL)"; return 1; }
    [[ -r "$FC_BASE" ]]     || { FC_WHY="no slice-3 rootfs at $FC_BASE to add the agent to (set MC_ROOTFS)"; return 1; }
    [[ -r /dev/kvm && -w /dev/kvm ]] \
        || { FC_WHY="/dev/kvm is not read-write for this user, so no microVM can start unprivileged"; return 1; }
    [[ -r /dev/vhost-vsock && -w /dev/vhost-vsock ]] \
        || { FC_WHY="/dev/vhost-vsock is not read-write for this user, so the guest has no channel to answer on"; return 1; }
    [[ -x "$LAB_DIR/make-vsock-rootfs.sh" ]] \
        || { FC_WHY="make-vsock-rootfs.sh is missing — it is what puts the agent into the image without a loop mount or sudo"; return 1; }

    bash "$LAB_DIR/make-vsock-rootfs.sh" --in "$FC_BASE" --out "$WORK/fc.ext4" --port "$FC_PORT" \
        >"$WORK/mkrootfs.log" 2>&1 \
        || { FC_WHY="make-vsock-rootfs.sh failed: $(tail -1 "$WORK/mkrootfs.log")"; return 1; }

    # sockaddr_un caps a unix path at ~108 bytes and Firecracker's host end IS a unix
    # socket, so a long $WORK would fail as something that reads like a vsock fault.
    local short; short="$(mktemp -d /tmp/mcmx.XXXX)" \
        || { FC_WHY="could not create a short-path scratch dir for the vsock socket"; return 1; }
    on_exit "rm -rf -- '$short'"
    FC_UDS="$short/fc.vsock"

    cat > "$WORK/fc.json" <<JSON
{
  "boot-source": { "kernel_image_path": "$FC_KERNEL",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off mc_name=mx-fc" },
  "drives": [ { "drive_id": "rootfs", "path_on_host": "$WORK/fc.ext4",
                "is_root_device": true, "is_read_only": false } ],
  "vsock": { "guest_cid": 42, "uds_path": "$FC_UDS" },
  "machine-config": { "vcpu_count": 1, "mem_size_mib": 256 }
}
JSON
    "$FC_BIN" --no-api --config-file "$WORK/fc.json" --api-sock "$short/fc.api" \
        >"$WORK/fc.console" 2>&1 &
    local pid=$!
    # BY PID, never by pattern: a pattern carrying this socket path also matches the VMM
    # whose argv carries it, which is how a previous run killed the workload it was measuring.
    on_exit "kill $pid 2>/dev/null || true"

    local _t
    for _t in $(seq 1 90); do
        grep -q 'MC-VSOCK-AGENT LISTENING' "$WORK/fc.console" 2>/dev/null && return 0
        kill -0 "$pid" 2>/dev/null \
            || { FC_WHY="the microVM exited before its agent listened; console tail: $(tail -1 "$WORK/fc.console" 2>/dev/null)"; return 1; }
        sleep 0.5
    done
    FC_WHY="the guest never reported MC-VSOCK-AGENT LISTENING within 45s; console tail: $(tail -1 "$WORK/fc.console" 2>/dev/null)"
    return 1
}

# ── the container row ────────────────────────────────────────────────────────
# `sleep infinity` and alpine: the same image and command micro-cloud.toml declares for
# `metrics`, so this row measures the boundary the LAB has, not a boundary invented here.
if ! podman run -d --name "$CTR" docker.io/library/alpine:latest sleep infinity >/dev/null 2>&1; then
    skip "could not start a rootless alpine container (no image cached and no network?) — the container row is the one row this test exists to run unprivileged"
fi

MATRIX="$WORK/matrix.tsv"
{
    probe_all run_host "host"
    probe_all run_ctr  "metrics (podman, rootless)"
    # Measured ONLY when the instance answers. A row that cannot be probed stays UNKNOWN
    # further down -- rows are unmeasured by default and leave that list only by being
    # measured, which is the rule an earlier version of this file broke by recording its
    # UNKNOWNs conditionally and losing a row entirely.
    if db_up;   then probe_all run_lxd  "db (lxd system container)"; fi
    if edge_up; then probe_all run_edge "edge (qemu vm, full stack)"; fi
    if fc_boot; then probe_all run_fc   "$FC_LABEL"; fi
} > "$MATRIX"

# A NAMESPACE ID IS ONLY COMPARABLE WITHIN ONE KERNEL, and the table invites the opposite
# reading. `edge` reported netns 4026531840 — identical to the host's — and that is NOT
# sharing: 4026531840 is the initial-netns inode in *every* Linux kernel, and edge has its
# own. A reader comparing those two numbers would conclude the VM is on the host's network
# namespace, which is the exact opposite of the truth.
#
# Which rows have their own kernel is DERIVED rather than listed: a row whose boot_id differs
# from the host's is a different kernel, so its ns ids are its own numbering.
host_boot="$(head -1 "$MATRIX" | cut -f4)"
printf '\n  %-32s %6s %-10s %-9s %-11s %-9s %-7s %s\n' \
    ROW PIDS PID1 BOOT_ID NETNS DMESG /dev/kvm UID >&2
while IFS=$'\t' read -r a b c d e f g h; do
    mark=""
    [[ "$d" != "$host_boot" ]] && mark="*"
    printf '  %-32s %6s %-10s %-9s %-10s%-1s %-9s %-7s %s\n' "$a" "$b" "$c" "$d" "$e" "$mark" "$f" "$g" "$h" >&2
done < "$MATRIX"
printf '  * = own kernel (boot_id differs from the host), so its NETNS number is its own\n' >&2
printf '      numbering and is NOT comparable with the host row. 4026531840 is the initial\n' >&2
printf '      netns inode in every kernel; two rows sharing it prove nothing.\n\n' >&2

host_row="$(sed -n '1p' "$MATRIX")"
ctr_row="$( sed -n '2p' "$MATRIX")"

IFS=$'\t' read -r _ h_pids h_init h_boot h_netns h_dmesg h_kvm h_uid <<<"$host_row"
IFS=$'\t' read -r _ c_pids c_init c_boot c_netns c_dmesg c_kvm c_uid <<<"$ctr_row"

# ── the assertions ───────────────────────────────────────────────────────────
# 1. The rows must DIFFER.  An isolation matrix whose rows agree has measured nothing, and
#    it is the failure that looks most like success: a full table of plausible numbers.
[[ "$host_row" != "$ctr_row" ]] \
    || fail "REGRESSION: the host row and the container row are IDENTICAL. Either the probes ran in the same context, or the container has no boundary at all — and a matrix of identical rows reads like a result"
note "the host and container rows differ, so the probes are measuring a boundary"

# 2. The process table is the boundary a reader can see at a glance.
(( c_pids > 0 )) || fail "the container row enumerated 0 processes — the probe did not run, which is not the same as 'it could see nothing'"
(( c_pids < h_pids )) \
    || fail "REGRESSION: the container enumerated $c_pids processes and the host $h_pids. A rootless container has its own PID namespace; seeing as many as the host means it did not get one"
note "process table: host $h_pids, container $c_pids — the PID namespace is doing something"

# 3. Its /proc is its own.  Compared by a VALUE only the host has rather than by a mount
#    table entry, because a bind of the host's /proc would still be called "proc".
[[ "$c_boot" != "$h_boot" || "$c_boot" == "-" ]] || {
    # boot_id is per-BOOT, not per-namespace: a container legitimately reads the host's.
    # This is the interesting half of the row rather than a failure, so it is reported.
    note "/proc: the container reads the HOST's boot_id ($h_boot…) — procfs is namespaced for PIDs, not for the machine's identity. That is the boundary's shape, and it is why §9.3 asks what each can SEE rather than whether it 'is isolated'"
}

# 4. THE ROOTLESS ASYMMETRY, WHICH IS THE WHOLE POINT OF §9.3's LAST PARAGRAPH.
#    `metrics` cannot be given a tap: that needs CAP_NET_ADMIN. So it does not join the
#    fabric — it lives in a network namespace pasta/slirp built for it, and reaches the
#    other instances the way the host does. This is asserted, not narrated, because the
#    spec DELIBERATELY gives metrics no tap and a future edit adding one should fail here.
[[ -n "$c_netns" ]] || fail "could not read the container's network namespace id"
[[ "$c_netns" != "$h_netns" ]] \
    || fail "the rootless container SHARES the host's network namespace. §9.3's exhibit is that it does not — and if it did, 'rootless' would be buying much less than the lab claims"
note "network namespace: host $h_netns, container $c_netns — metrics is NOT on the fabric, by construction"

python3 - "$LAB_DIR/micro-cloud.toml" <<'PY' || fail "micro-cloud.toml gives 'metrics' a tap. A rootless container cannot open one (CAP_NET_ADMIN), so the spec would declare an instance the driver must refuse — and §9.3's asymmetry would stop being measurable"
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
svc = next((s for s in doc.get("service") or [] if s.get("name") == "metrics"), None)
raise SystemExit(0 if svc is not None and not svc.get("tap") else 1)
PY
note "the spec still gives 'metrics' no tap, which is what makes the asymmetry above real"

# 5. /dev/kvm — the device that grants the power to create more of these.
[[ "$c_kvm" == "closed" || "$c_kvm" == "open" ]] || fail "the /dev/kvm probe returned '$c_kvm'"
note "/dev/kvm: host=$h_kvm container=$c_kvm"

# 6. dmesg. REPORTED, not asserted, and the distinction is the point: whether an
#    unprivileged container can read the HOST's kernel ring buffer is a property of
#    `kernel.dmesg_restrict`, which belongs to the machine and not to the lab. Asserting a
#    value here would make the test fail on a hardened host for being hardened. But it is
#    the single most surprising cell in the matrix — the boundary that keeps a container
#    from seeing 900 processes does not keep it from reading what the kernel says about all
#    of them — so it is printed with its cause attached.
dmesg_restrict="$(cat /proc/sys/kernel/dmesg_restrict 2>/dev/null || echo '?')"
note "dmesg: host=$h_dmesg container=$c_dmesg (kernel.dmesg_restrict=$dmesg_restrict — with 0, an unprivileged container reads the HOST's ring buffer; this is a host setting, so it is reported, not asserted)"

# ── the microVM row, when it was measured: is it its OWN machine? ────────────
# The container's boundary and the microVM's are different KINDS, and boot_id is where that
# stops being a slogan. `metrics` reads the HOST's boot_id through a namespaced /proc — its
# isolation is a view of one machine. The microVM reads a DIFFERENT one, because it is a
# different machine. If this row ever showed the host's boot_id it would mean the answers
# came from the host and not from inside the guest at all: the seam answering for the wrong
# instance, a class that has already bitten this repo once.
#
# It is a function so the control below can run the SAME check against values known to be
# wrong, rather than reasoning about what it would have done.
its_own_machine() { [[ -n "$1" && "$1" != "-" && "$1" != "$2" ]]; }

fc_row="$(grep -E '^api[0-9]* \(firecracker' "$MATRIX" || true)"
if [[ -n "$fc_row" ]]; then
    IFS=$'\t' read -r _ f_pids f_init f_boot _ f_dmesg _ _ <<<"$fc_row"
    (( f_pids > 0 )) \
        || fail "the microVM row enumerated 0 processes — the EXEC probe returned nothing, which is not the same as 'the guest could see nothing'"
    its_own_machine "$f_boot" "$h_boot" \
        || fail "REGRESSION: the firecracker row reports boot_id '$f_boot', the same machine identity as the host. A microVM has its own kernel, so this means the probes did not execute inside the guest — the channel answered for the wrong instance"
    its_own_machine "$h_boot" "$h_boot" \
        && fail "control failed: its_own_machine() accepted the host's own boot_id as evidence of a separate machine, so the assertion above cannot fail and proves nothing"
    note "the microVM row is its OWN machine: boot_id $f_boot vs the host's $h_boot, pid1=$f_init, $f_pids processes — measured INSIDE the guest, over vsock"
    # Not asserted, reported: it is its own kernel, so the HOST's dmesg_restrict does not
    # reach it. A microVM reading dmesg is reading ITS OWN ring buffer, which is the
    # opposite of the container case and the reason this cell is worth printing.
    note "dmesg: microvm=$f_dmesg while host=$h_dmesg — not the same buffer, and not a leak: its kernel is not this kernel"
fi

# ── the rows this run could not measure, named ───────────────────────────────
# A ROW IS UNKNOWN UNTIL IT IS MEASURED, not unknown if some precondition happens to fail.
# The first version of this block had it the other way round and immediately demonstrated
# the bug the whole file is about: it recorded the Firecracker row as UNKNOWN only when
# /dev/kvm was unreadable OR the binary was missing — and on this host BOTH were present, so
# the row was neither measured nor reported.  It vanished.  The summary then said "2 rows
# measured" with no mention of the two microVMs, which is exactly the shape of *silently
# downgrading an unchecked thing to a pass*.
#
# So the three remaining rows are declared unmeasured here, unconditionally, and would be
# removed only by code that actually probes them.  Each carries the reason it needs the
# privileged run rather than a generic "not available".
grep -qE '^api[0-9]* \(firecracker' "$MATRIX" \
    || unknown "api (firecracker microVM)" \
        "${FC_WHY:-the microVM row was not attempted}. This row used to be STRUCTURALLY unmeasurable — a hypervisor boundary admits no exec verb, and slice 3's rootfs has no channel at all — and it is measurable now because slice 5c's agent answers EXEC over vsock, which needs no bridge, no lease and no root"
grep -q '^edge (qemu vm' "$MATRIX" \
    || unknown "edge (qemu vm)" \
        "no lease for 'edge' in the fabric's lease file, or it did not answer ssh at that address. It is booted on a fabric tap by the privileged path; note that \`lab-vm.sh ssh\` CANNOT reach it (that verb needs a slirp hostfwd a tap-mode VM does not have)"
grep -q '^db (lxd' "$MATRIX" \
    || unknown "db (lxd)" \
        "no running LXD instance named 'db' in lab micro-cloud. It needs br-mc0 to exist first (its nic device names it as a parent), and on this host that row carries a hazard worth reading before running it: see LEDGER.md L10-1"

if (( ${#UNKNOWN_ROWS[@]} )); then
    printf '  UNKNOWN rows (measured by nothing, so reported as unmeasured):\n' >&2
    printf '    - %s\n' "${UNKNOWN_ROWS[@]}" >&2
    printf '  Fill them in with the privileged run in MANUAL_TESTING.md.\n\n' >&2
fi

# DERIVED FROM THE MATRIX, not from a literal. The first version said "2 of …" because the
# 2 was typed in — so a run that measured THREE rows (host, metrics and a live `edge`)
# printed all three in the table above and then reported two. Under-reporting is the less
# dangerous direction, but this file's whole subject is honest row accounting, and a count
# that cannot change when the thing it counts changes is not a count.
_measured="$(wc -l < "$MATRIX")"
pass "§9.3 isolation matrix: $_measured of $((_measured + ${#UNKNOWN_ROWS[@]})) rows measured ($(cut -f1 "$MATRIX" | paste -sd'; ')), rows differ, PID and network namespaces both observed to bound what metrics can see; ${#UNKNOWN_ROWS[@]} row(s) reported UNKNOWN by name"
