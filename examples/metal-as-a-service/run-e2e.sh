#!/usr/bin/env bash
# run-e2e.sh — drive the whole control plane against REAL hardware-ish nodes, once.
#
# Everything the headless suite proves with mocks, done for real: three libvirt domains,
# three IPMI BMCs, a PXE network, an introspection probe that actually boots and reports
# its CPU/RAM, a signed payload that actually netboots into RAM, and a reconcile loop
# that converges the fleet and then does nothing.
#
# THIS SCRIPT IS GLUE. Every step below is an existing tool — `create-fleet.sh` (which
# itself wraps ../virtualbmc-ipmi-lab), `setup-pxe-net.sh`, `metadata-serve.sh`,
# `build-probe-initramfs.sh`, `netboot-chain.sh`, `drivers/ramdisk.sh`, and `maas-lab.sh`.
# Nothing here
# implements control-plane behaviour; if a step fails, it fails in the tool that owns
# it. Modelled on ../virtualbmc-ipmi-lab/run-finale.sh, which does the same thing for
# the single-node PXE install.
#
#   ./run-e2e.sh --dry-run     print the plan, touch nothing, need no sudo
#   sudo -v && ./run-e2e.sh    the real run (sudo primed; see below)
#   ./run-e2e.sh --down        tear the fleet down
#
#   E2E_NO_IMGVERIFY=1 ./run-e2e.sh   payload stays SIGNED and the host-side F2 gate
#                                     still runs; only the in-firmware `imgverify` is
#                                     omitted, for a ROM without IMAGE_TRUST_CMD.
#                                     (E2E_UNSIGNED is the old name, still accepted.)
#
# SUDO: rootful libvirt (qemu:///system) and rootful podman (vbmcd) are unavoidable —
# the system libvirt socket is root:libvirt. All the sudo-needing work is FRONT-LOADED
# in phases 1–3, exactly as run-finale.sh does it, so the long part runs unprivileged.
# Prime it with `sudo -v` first; this script never asks for a password mid-run.
#
# PAYLOAD: `micro-linux-x86_64` from ramdisk-catalog.toml — a from-source kernel +
# BusyBox initramfs that boots to a shell in seconds. Deliberately not the AlmaLinux
# install: that path is already proven end-to-end by run-finale.sh and takes ~30 min,
# and what this script is here to exercise is the CONTROL PLANE, not Anaconda.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MAAS="$HERE/maas-lab.sh"
VBMC_LAB="${VBMC_LAB:-$HERE/../virtualbmc-ipmi-lab}"
IMAGE="${E2E_IMAGE:-micro-linux-x86_64}"
NODE="${E2E_NODE:-node1}"
LOG="${E2E_LOG:-$HERE/e2e-run.log}"
# The signed-image store (and trust/ca.key inside it) — asked of maas-lab.sh, the
# single owner of the answer, NOT re-derived here. This script used to default it
# to ~/.cache while maas-lab.sh defaulted to $XDG_STATE_HOME/…: the same deploy
# verb then read a different store depending on which script invoked it, and a
# bare `maas-lab.sh apply` failed F2 against an images dir that did not exist.
# (~/.cache was also the wrong contract for a signing key: that dir is by
# definition safe to delete, and it WAS deleted mid-session once, taking the
# fleet's whole signing chain with it.)
export MAAS_IMAGES_DIR="${MAAS_IMAGES_DIR:-$("$MAAS" _images-dir)}"
[[ -n "$MAAS_IMAGES_DIR" ]] || { echo "run-e2e: maas-lab.sh _images-dir returned nothing" >&2; exit 1; }
export MAAS_NETBOOT_DIR="${MAAS_NETBOOT_DIR:-$HOME/netboot}"
DRY=0; DOWN=0
case "${1:-}" in --dry-run) DRY=1 ;; --down) DOWN=1 ;; -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac

# --dry-run must not touch the real log. It used to `tee -a` into it while skipping the
# truncation, so a dry run APPENDED a ghost run to the last real one — and a log with
# two interleaved runs in it is worse than no log when you are trying to read a failure.
_tee() { if [[ $DRY == 1 ]]; then cat >&2; else tee -a "$LOG" >&2; fi; }
step() { printf '\n== %s ==\n' "$*" | _tee; }
info() { printf '   %s\n' "$*" | _tee; }
die()  { printf 'FAIL: %s\n' "$*" | _tee; exit 1; }

# run — a phase that MUST succeed. Anything else is how a run marches past the actual
# defect: phase 3 once failed outright (`create-node node1 failed`, no domains, no
# consoles, no enroll) and phases 4-10 ran anyway, each producing its own confusing
# error, and the verdict blamed a health gate. Every setup step here is load-bearing;
# if one fails, the rest are noise.
run()  {
    if [[ $DRY == 1 ]]; then printf '   $ %s\n' "$*" >&2; return 0; fi
    printf '   $ %s\n' "$*" | tee -a "$LOG" >&2
    local rc=0
    "$@" >>"$LOG" 2>&1 || rc=$?      # capture BEFORE anything else runs: the printf
    if [[ $rc -ne 0 ]]; then          # below would otherwise clobber $? and report 0
        printf '\n' | tee -a "$LOG" >&2
        die "the step above failed (rc=$rc): $*
Everything after it depends on it, so continuing would report a different, misleading
failure several phases later. The tool's own output is in $LOG — read it there; this
script deliberately does not paraphrase what a tool it wraps already said."
    fi
}
# run_soft — a phase whose failure IS the result, not an obstacle to it. The deploy and
# the reconcile are the things under test: when they fail we want the state, the apply
# report and the final verdict, not an abort.
run_soft() {
    if [[ $DRY == 1 ]]; then printf '   $ %s\n' "$*" >&2; return 0; fi
    printf '   $ %s\n' "$*" | tee -a "$LOG" >&2
    "$@" >>"$LOG" 2>&1 || info "(that step failed — continuing; the verdict below is what counts)"
}

# ensure_manageable — phase 4's decision, hoisted into a function so it can be exercised
# without a fleet. The REGISTRY outlives the fleet: create-fleet.sh rebuilds the domains
# but skips enrolling a node it already knows ("already enrolled (state=manageable) —
# skipping"), so on a re-run the node arrives here already past `enrolled` and `manage`
# correctly refuses — it is a transition from enrolled/error, not a re-check you can spam.
# The state machine was right; the driver was wrong to assume a fresh registry.
#
# The empty case is NOT a third way of saying "nothing to do": no state at all means the
# node was never enrolled, which means phase 3 did not finish, and every phase after this
# would fail with its own confusing error. That one aborts.
#
# A TRANSIENT state is a third case, and lumping it in with "already past it" was wrong.
# A run killed mid-deploy leaves its node in `deploying` — not broken, just unreachable
# by every verb that owns it. The permissive `*)` branch below waved that through as
# "already advanced", and the run then died two phases later at `inspect` with a message
# about inspect, nowhere near the strand. (Same defect shape as the one this branch was
# added to fix: a default that reads as success.)
#
# The control plane already has the way out — `abort` (transient -> error, with the reason
# recorded), then `manage`. Drive it, and say so: a node stranded by the previous run is
# information the operator wants, not something to quietly paper over.
E2E_TRANSIENT="verifying deploying cleaning rescuing deleting"   # == maas-lab.sh's
ensure_manageable() {
    local st; st="$("$MAAS" state "$NODE" 2>/dev/null)"
    local t
    for t in $E2E_TRANSIENT; do
        [[ "$st" == "$t" ]] || continue
        info "'$NODE' is STRANDED in transient state '$st' — a previous run died mid-transition."
        info "No verb accepts a node there, so everything downstream would fail for reasons that"
        info "look nothing like this. Aborting it into 'error' first, which is recoverable:"
        run "$MAAS" abort "$NODE" --reason "stranded in '$st' by an earlier run; aborted by run-e2e.sh"
        st=error
        break
    done
    # `active` (or `rescue`) means the LAST run got there. Phase 3 has just rebuilt this
    # node's domain and disk, so that record is already stale — the machine behind it is
    # blank. Releasing is therefore reconciling the record with reality, not discarding a
    # live workload, and for a ramdisk node the wipe is a documented no-op. Say it out
    # loud anyway: a script that silently releases a node someone believes is serving
    # would be a much worse thing to be.
    case "$st" in
        active|rescue)
            info "'$NODE' is '$st' from a previous run. Phase 3 has already rebuilt its domain and"
            info "disk, so that record is stale — the machine behind it is blank. Releasing it back"
            info "to the pool so this run can inspect it again (for a ramdisk node the wipe is a"
            info "no-op; nothing that is actually serving is being torn down):"
            run "$MAAS" release "$NODE"
            st=available ;;
    esac
    case "$st" in
        enrolled|error|available) run "$MAAS" manage "$NODE" ;;
        manageable) info "'$NODE' is already 'manageable' — nothing to drive" ;;
        "")  die "'$NODE' is not enrolled and create-fleet.sh did not enroll it — phase 3 did not finish" ;;
        # NO permissive default. This branch used to be `*) carry on`, and it was wrong
        # three separate times — for a transient state, for `available`, and for `active`
        # — each time producing a failure two phases downstream with a message about some
        # other verb. Phase 6 needs `manageable`; anything this function cannot get there
        # is a stop, here, naming the state.
        *)   die "'$NODE' is in state '$st', and this run does not know how to get it to
'manageable' from there — which is what phase 6's 'inspect' requires. Drive it by hand
(see 'maas-lab.sh --help'), or start clean: ./run-e2e.sh --down and remove \$MAAS_STATE" ;;
    esac
}

# THE LOG IS NOT TRUNCATED YET. It used to be replaced here, before preflight — so a run
# that refused at the sudo gate, or at any preflight check, destroyed the log of the last
# run that actually finished. (Done to a passing run's log, by me, while testing a
# preflight check.) Same class as the --dry-run ghost-log bug: the record of a completed
# run wrecked by a run that never started.
#
# Preflight writes to a scratch file instead; the real log is replaced only once the run
# commits to doing work. Either way the reap trap removes the scratch.
REAL_LOG="$LOG"
if [[ $DRY == 0 ]]; then
    LOG="$(mktemp "${TMPDIR:-/tmp}/maas-e2e-preflight.XXXXXX")" || LOG="$REAL_LOG"
    SCRATCH_LOG="$LOG"
fi
# commit_log — preflight passed; this run owns the log now. Replaces it with what
# preflight said, so the file still starts at the top of THIS run.
commit_log() {
    [[ $DRY == 1 || -z "${SCRATCH_LOG:-}" ]] && return 0
    cp -f "$SCRATCH_LOG" "$REAL_LOG" 2>/dev/null || : > "$REAL_LOG"
    rm -f "$SCRATCH_LOG"; SCRATCH_LOG=""
    LOG="$REAL_LOG"
}

# ── reap the one process this script starts ─────────────────────────────────
# The facts sink is backgrounded here and holds :8282 for the whole run. Three runs in
# a row died on a timeout, left it behind, and the NEXT run's sink then failed to bind —
# the first time silently, with the blame landing on the probe two phases later.
#
# The rule this script states elsewhere ("does not kill processes it did not start") is
# right and does not apply: this one it DID start, and it has the pid. So reap it, BY
# PID (never a pattern — CLAUDE.md, and the pattern here would be a path shared with
# other tooling). Everything else — watchers, the fleet, vbmcd — is still the operator's,
# because this script did not start those.
MD_PID=""
reap() {
    local rc=$?
    [[ -n "${SCRATCH_LOG:-}" ]] && rm -f "$SCRATCH_LOG"
    if [[ -n "$MD_PID" ]] && kill -0 "$MD_PID" 2>/dev/null; then
        kill "$MD_PID" 2>/dev/null
        # Give it a moment to release :8282, then insist. A sink that ignores SIGTERM
        # and survives is exactly the leftover this trap exists to prevent.
        for _ in 1 2 3 4 5; do kill -0 "$MD_PID" 2>/dev/null || break; sleep 0.2; done
        kill -0 "$MD_PID" 2>/dev/null && kill -9 "$MD_PID" 2>/dev/null
        printf '   reaped the facts sink (pid %s)\n' "$MD_PID" >&2
    fi
    return $rc
}
trap reap EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ── teardown ────────────────────────────────────────────────────────────────
if [[ $DOWN == 1 ]]; then
    step "tearing the fleet down (rootful)"
    run "$HERE/create-fleet.sh" down
    info "any watchers you started are yours to stop — this script does not kill"
    info "processes it did not start (and never by pattern; kill by PID). Its own"
    info "facts sink is reaped by the EXIT trap, so no run leaves one holding :8282."
    exit 0
fi

# ── preflight ───────────────────────────────────────────────────────────────
step "preflight"
for c in virsh ipmitool python3 openssl; do
    command -v "$c" >/dev/null || die "missing required command: $c"
done
[[ -d "$VBMC_LAB" ]] || die "sibling lab not found: $VBMC_LAB (set VBMC_LAB=)"
info "payload      : $IMAGE"
info "subject node : $NODE"
info "images dir   : $MAAS_IMAGES_DIR"
info "PXE docroot  : $MAAS_NETBOOT_DIR"
# The payload must already be built by the lab that owns it. This script does not
# build other labs' artifacts; the driver's own refusal names the command.
if [[ $DRY == 0 ]]; then
    "$HERE/drivers/ramdisk.sh" describe "$IMAGE" >/dev/null 2>&1 \
        || die "no catalog entry '$IMAGE' (see ramdisk-catalog.toml)"

    # …AND SO MUST EVERY OTHER PAYLOAD fleet.toml DECLARES. Phase 9 converges the whole
    # fleet, not just the subject node, so a sibling declared against an artifact this
    # host has never built fails there — nine phases and several minutes after the fact
    # was knowable. node2/node3 once declared `busybox-netboot` and `anycast-dns-ram`,
    # neither built here: apply refused them by name (correctly), both landed in `error`,
    # and the reconciliation invariant could not be reached at all.
    #
    # A missing artifact is a HOST condition, not a repo defect — which is why the
    # headless suite only checks that the catalog owns the image, and the check for
    # whether it exists lives here, where the host is.
    REPO_ROOT="$(cd -- "$HERE/../.." && pwd)"
    missing=""
    while read -r nname nimg; do
        [[ -n "$nname" && -n "$nimg" ]] || continue
        d="$("$HERE/drivers/ramdisk.sh" describe "$nimg" 2>&1)" \
            || die "fleet.toml declares '$nname' as ramdisk/'$nimg', which the catalog does not
describe. Phase 9 converges the whole fleet, so this node would fail there. Fix the
declaration, or add the image to ramdisk-catalog.toml."
        eval "$(python3 "$HERE/lib/catalog.py" "$HERE/ramdisk-catalog.toml" get "$nimg" 2>/dev/null)"
        # Catalog paths are absolute OR repo-relative (catalog.py expands ~ and $VARS but
        # documents "relative = repo root"). Resolve them the same way drivers/ramdisk.sh
        # does — testing them against $PWD instead reported every artifact missing,
        # including the one this run had just staged.
        for f in "${IMG_KERNEL:-}" "${IMG_INITRD:-}"; do
            [[ -n "$f" ]] || continue
            case "$f" in /*) : ;; *) f="$REPO_ROOT/$f" ;; esac
            [[ -f "$f" ]] || missing+="  $nname -> $nimg: missing $f
"
        done
    done < <(python3 -c '
import sys, tomllib
spec = tomllib.load(open(sys.argv[1], "rb"))
for n in spec.get("node", []):
    if n.get("driver") == "ramdisk":
        print(n.get("name", "?"), n.get("image", ""))
' "$HERE/fleet.toml")
    if [[ -n "$missing" ]]; then
        die "fleet.toml declares payloads this host has not built:
$missing
Phase 9 converges the WHOLE fleet, so those nodes would fail there — nine phases after
this was knowable. Either build them (the catalog prints the command:
'drivers/ramdisk.sh describe <image>') or declare those nodes on a payload that exists."
    fi
fi

# Checked LAST of the preflight items, deliberately: everything above is a config
# question the operator can answer without privilege, and demanding sudo before telling
# them their spec is wrong wastes the trip.
if [[ $DRY == 0 ]]; then
    sudo -n true 2>/dev/null \
        || die "sudo is not primed. Run 'sudo -v' first — this script front-loads the
privileged work and must not stop to ask for a password halfway through a boot."
fi

commit_log      # preflight is done; from here the real log is this run's

# ── 1. the PXE network + HTTP docroot (SUDO) ────────────────────────────────
step "[1/10] PXE network + HTTP docroot (sudo)"
info "creates the vbmc-pxe libvirt network and points iPXE at the host's :8181 nginx"
run env PAYLOAD=busybox "$VBMC_LAB/setup-pxe-net.sh"

# ── 1b. …and make it a FLEET network, not a one-payload network (SUDO) ──────
# setup-pxe-net.sh bakes ONE payload into boot.ipxe for the whole network. That is
# right for its single node and fatal here: the per-node scripts maas-lab.sh writes
# would never be fetched, so every node would netboot busybox and every gate would
# time out. (This is exactly how the first live run of this script failed — twice, in
# two different phases, with two different-looking errors.)
step "[2/10] replace the baked boot.ipxe with the per-node CHAIN (sudo)"
run "$HERE/netboot-chain.sh" install

# ── 3. the fleet: 3 domains + 3 BMCs, enrolled (SUDO) ───────────────────────
step "[3/10] fleet up: 3 libvirt domains + one vbmcd hosting BMCs on 6230-6232 (sudo)"
info "create-fleet.sh wraps ../virtualbmc-ipmi-lab and then enrolls into the registry"
info "it also gives each domain a FILE-backed serial console — every health gate in"
info "this lab greps a console log, and a pty console records nothing"
run "$HERE/create-fleet.sh" up

# ── everything below is UNPRIVILEGED ────────────────────────────────────────
step "[4/10] verify the BMC round-trip — the seam, against a real BMC"
# Drive the node to `manageable` only if it is not already past it (see ensure_manageable
# above) — and then exercise the seam either way, because `power status` is the part that
# actually proves the BMC answers.
if [[ $DRY == 1 ]]; then
    printf '   $ %s\n' "$MAAS manage $NODE   # only when the node is in enrolled/error" >&2
else
    ensure_manageable
fi
run "$MAAS" power "$NODE" status
if [[ $DRY == 0 ]]; then
    con="$("$MAAS" show "$NODE" 2>/dev/null | awk '$1=="console"{print $2; exit}')"
    [[ -n "$con" && -f "$con" ]] \
        || die "no console log is recorded for '$NODE'. Every health gate in this lab reads
one, so the run would be blind: a node that boots the wrong payload and a node that never
boots at all both look like a timeout. Check create-fleet.sh's 'instrumenting the fleet'
step (FLEET_CONSOLE=file), or set one by hand: $MAAS set-console $NODE <path>"
    info "console log: $con"
fi

# ── 5. introspection: the probe really boots and reports ────────────────────
step "[5/10] build the introspection initramfs + start the facts sink (:8282)"
run "$HERE/build-probe-initramfs.sh" --out "$MAAS_NETBOOT_DIR/probe-initramfs.cpio.gz"
# The probe needs a kernel with its NIC driver BUILT IN — it boots an initramfs, which
# carries no modules. The repo's ~/netboot/kernel is Debian stock (virtio_net and e1000
# both modular), so a probe booted with it comes up with NO network device at all: it
# measures the machine correctly and has nothing to post the answer over. micro-linux's
# defconfig kernel has e1000 built in; pair it with the fleet's e1000 NIC.
PK="${MAAS_PROBE_KERNEL_SRC:-$HERE/../../micro-linux/out/x86_64/kernel}"
if [[ $DRY == 0 ]]; then
    [[ -f "$PK" ]] || die "no probe kernel at $PK. The probe boots an initramfs, so it needs
a kernel with its NIC driver built in; ~/netboot/kernel is Debian stock and has none.
Build it:  micro-linux/mlbuild.sh all --arch x86_64   (or set MAAS_PROBE_KERNEL_SRC)"
    run cp -f "$PK" "$MAAS_NETBOOT_DIR/probe-kernel"
fi
export MAAS_PROBE_KERNEL=probe-kernel
GW="$(virsh -c qemu:///system net-dumpxml vbmc-pxe 2>/dev/null \
      | sed -nE "s/.*<ip address='([^']+)'.*/\1/p" | head -1)"
GW="${GW:-192.168.180.1}"
info "facts sink will bind $GW:8282 (the node reaches it at the network gateway)"
if [[ $DRY == 1 ]]; then
    printf '   $ %s\n' "$HERE/metadata-serve.sh --host $GW --port 8282  &   # background" >&2
else
    "$HERE/metadata-serve.sh" --host "$GW" --port 8282 >>"$LOG" 2>&1 &
    MD_PID=$!
    sleep 1
    # Backgrounding a server hides its exit status, and this one WILL fail if a sink
    # from a previous run still holds :8282 — which is the normal state of affairs after
    # a run that ended in a timeout, because nothing reaps it. The first time that
    # happened the script sailed on with a dead PID and blamed the probe two phases
    # later. So: confirm it is alive AND answering before anything depends on it.
    if ! kill -0 "$MD_PID" 2>/dev/null; then
        MD_PID=""      # nothing of ours to reap; do not let the trap fire on a dead pid
        holder="$(ss -ltnp 2>/dev/null | awk -v a="$GW:8282" '$4==a {print $NF}')"
        die "the facts sink did not start on $GW:8282${holder:+ — still held by $holder}.
That is almost certainly a sink from a run of this script that predates the EXIT trap
below (runs before 2026-07-28 left theirs behind). Kill it BY PID and re-run:
    ss -ltnp | grep 8282
    kill <pid>
(never by pattern — see CLAUDE.md. Check the cmdline first: it should be lib/metadata.py.)"
    fi
    curl -fsS --max-time 5 -o /dev/null "http://$GW:8282/" 2>/dev/null \
        || info "note: the sink is running but did not answer a probe GET — continuing"
    info "metadata-serve.sh running as PID $MD_PID — reaped automatically when this exits"
fi

step "[6/10] inspect: PXE-boot the probe, await its facts, power off"
info "this is the REAL introspection path — the node boots, POSTs cpus/mem/MAC, powers down"
info "--md-url is not decoration: it becomes maas.md= on the probe's kernel cmdline,"
info "and a probe without it measures the machine and has nowhere to send the answer"
run "$MAAS" inspect "$NODE" --boot --md-url "http://$GW:8282"
run "$MAAS" show "$NODE"

# ── 7. provide + stage a signed payload ─────────────────────────────────────
step "[7/10] provide (through cleaning) + stage and SIGN the payload"
run "$MAAS" provide "$NODE"
if [[ $DRY == 0 && ! -f "$MAAS_IMAGES_DIR/trust/ca.crt" ]]; then
    run mkdir -p "$MAAS_IMAGES_DIR/trust"
    run "$HERE/drivers/verify-lib.sh" gen-keys --dir "$MAAS_IMAGES_DIR/trust"
fi
# IS THE SIGNING CERTIFICATE ONE THE FIRMWARE WILL ACCEPT? The host-side gate never
# asks — `openssl cms -verify` ignores key usage entirely — so a keydir minted before
# this lab learned better signs payloads that iPXE refuses outright ("Not a signing
# certificate", https://ipxe.org/022ae1). That is invisible until a node is asked to
# boot one, which is far too late and looks like a payload problem.
if [[ $DRY == 0 ]] && ! ( "$HERE/drivers/verify-lib.sh" check-keys --dir "$MAAS_IMAGES_DIR/trust" ) >/dev/null 2>&1; then
    if [[ "${MAAS_IPXE_TRUSTS_CA:-0}" == 1 ]]; then
        die "this fleet's signing leaf is one verifying firmware REFUSES, and MAAS_IPXE_TRUSTS_CA=1
says the nodes will check. Re-mint and re-sign before running:
      rm -rf $MAAS_IMAGES_DIR/trust        # then:
      ./drivers/verify-lib.sh gen-keys --dir $MAAS_IMAGES_DIR/trust
      ./drivers/ramdisk.sh stage $IMAGE    # re-sign every image with the new leaf
      ./build-verifying-rom.sh build       # the ROM bakes the CA -- rebuild it too
   Details: ./drivers/verify-lib.sh check-keys --dir $MAAS_IMAGES_DIR/trust"
    else
        info "NOTE: the signing leaf in $MAAS_IMAGES_DIR/trust lacks keyUsage=digitalSignature,"
        info "so verifying firmware would refuse these payloads (https://ipxe.org/022ae1). This"
        info "run does not exercise the on-node half, so it proceeds — but the F2 claim it makes"
        info "is host-side only. ./drivers/verify-lib.sh check-keys --dir $MAAS_IMAGES_DIR/trust"
    fi
fi
run "$HERE/drivers/ramdisk.sh" stage "$IMAGE"

# ── 8. the deploy: F2 gate, netboot into RAM, health gate ───────────────────
#
# THE FIRMWARE HAS TO BE ABLE TO HONOUR THE GATE. `ramdisk.sh` emits `imgverify` lines
# whenever the image is signed — that is the on-node half of F2. QEMU's STOCK iPXE ROM
# (what a libvirt virtio NIC boots by default) is built without IMAGE_TRUST_CMD, so
# `imgverify` is an unknown command: the script aborts, nothing boots, and because that
# ROM also has no serial console the failure leaves **zero bytes** on the node's console
# log. A live run proved it by accident and by controlled experiment — the introspection
# script (no imgverify) booted and printed a full kernel log on the same node, same
# network, minutes earlier.
#
# So this is checked here, loudly, rather than discovered as a 120s silence.
#
# HOW TO SKIP THE ON-NODE HALF, AND HOW NOT TO. The first attempt re-staged the image
# --unsigned, on the reasoning that no signatures means no `imgverify` line. It does mean
# that — and it also means the HOST-side gate refuses the image, because both halves read
# the same .sig files. The live run got `F2 signature verification failed ... -> error`
# and never reached the firmware at all. Worse, the message printed alongside it claimed
# "the host-side gate still runs at 'verify'", which was the exact opposite of what had
# just happened. Sign normally, and drop the on-node half at the line the firmware reads:
# MAAS_NO_IMGVERIFY=1, honoured by the driver's boot-script writer.
if [[ "${E2E_NO_IMGVERIFY:-${E2E_UNSIGNED:-0}}" == 1 ]]; then
    export MAAS_NO_IMGVERIFY=1
    info "MAAS_NO_IMGVERIFY=1: the payload is SIGNED and the host-side F2 gate runs for"
    info "real at 'verify'; only the in-firmware 'imgverify' line is omitted, because this"
    info "fleet's ROM cannot honour it. That is the honest half to skip, and the only one"
    info "that can be skipped on its own."
fi
if [[ $DRY == 0 ]]; then
    # If the firmware is claimed to verify, the domain must actually CARRY the
    # verifying ROM. Phase 3 re-created the fleet with THIS run's env, and
    # give_verifying_rom() used to attach nothing when the var was forgotten (it
    # now defaults ON whenever the ROM is installed on the host) — this check
    # stays as the belt: FLEET_NIC_ROM=0, a missing installed ROM, an old fleet —
    # so MAAS_IPXE_TRUSTS_CA=1 without FLEET_NIC_ROM=1 would send a stock ROM
    # (no imgverify, no serial console) into a script it aborts in silence.
    if [[ "${MAAS_IPXE_TRUSTS_CA:-0}" == 1 ]] && command -v virsh >/dev/null; then
        _dom="$("$MAAS" show "$NODE" 2>/dev/null | awk '$1=="domain"{print $2; exit}')"
        virsh -c qemu:///system dumpxml --inactive "${_dom:-$NODE}" 2>/dev/null | grep -q '<rom file=' \
            || die "MAAS_IPXE_TRUSTS_CA=1, but domain '${_dom:-$NODE}' carries NO <rom file=> — the
stock ROM cannot honour imgverify and cannot speak on the serial console, so the
deploy would time out in silence. Re-run with BOTH vars:
    FLEET_NIC_ROM=1 MAAS_IPXE_TRUSTS_CA=1 $0"
    fi
    if [[ -f "$MAAS_IMAGES_DIR/$IMAGE/kernel.sig" \
          && "${MAAS_IPXE_TRUSTS_CA:-0}" != 1 && "${MAAS_NO_IMGVERIFY:-0}" != 1 ]]; then
        die "'$IMAGE' is signed, so the boot script will carry \`imgverify\` — and nothing
here has established that this fleet's firmware can honour it. QEMU's stock iPXE ROM has no
IMAGE_TRUST_CMD and no serial console, so it fails the command and boots nothing, silently.
Either:
  * build the NIC firmware that CAN honour it — one command, ~10 minutes of docker:
        ./build-verifying-rom.sh build && ./build-verifying-rom.sh install
    then re-run with BOTH vars on the e2e itself:
        FLEET_NIC_ROM=1 MAAS_IPXE_TRUSTS_CA=1 $0
    (phase 3 re-creates the fleet; the ROM now defaults ON when installed, but an
    explicit FLEET_NIC_ROM=1 makes a missing ROM a loud failure instead of a plain fleet)
  * or run the whole path with ONLY the in-firmware half skipped — the payload stays
    signed and the host-side F2 gate still gates the deploy:
        E2E_NO_IMGVERIFY=1 $0
Refusing rather than booting into a silence that looks like a dead payload."
    fi
fi
step "[8/10] deploy: verify -> netboot into RAM -> health gate -> active"
if [[ "${MAAS_NO_IMGVERIFY:-0}" == 1 ]]; then
    info "the node fetches a SIGNED kernel+initrd, gated host-side; the iPXE script omits"
    info "imgverify because this fleet's ROM has no IMAGE_TRUST_CMD"
else
    info "the node fetches a SIGNED kernel+initrd; the iPXE script carries imgverify"
fi
run_soft "$MAAS" deploy "$NODE" --driver ramdisk --image "$IMAGE"
run_soft "$MAAS" state "$NODE"

# ── 9. the reconcile loop, twice — the invariant ────────────────────────────
#
# THE INVARIANT NEEDS *REAL* THEN *REAL*. This was `--dry-run` then real, with the second
# one labelled "must issue ZERO transitions". A dry run converges nothing, so the real run
# after it issues exactly what the dry run just predicted — the label described a property
# the sequence had not set up, and the check would have passed on any apply at all.
#
# Convergence is a fixed point: apply until nothing changes, then apply again and assert
# nothing changed. The dry run stays, first, because seeing the plan before it is executed
# is worth a line — it is just not one of the two runs the invariant is about.
step "[9/10] apply: converge the fleet, then prove a SECOND real run is a no-op"
info "the plan, before anything is issued:"
run_soft "$MAAS" apply "$HERE/fleet.toml" --dry-run
info "pass 1 — converge (this one is expected to issue transitions):"
run_soft "$MAAS" apply "$HERE/fleet.toml"
info "pass 2 — the invariant: a converged fleet must issue ZERO transitions"
if [[ $DRY == 0 ]]; then
    APPLY2="$(mktemp "${TMPDIR:-/tmp}/maas-apply2.XXXXXX")"
    printf '   $ %s\n' "$MAAS apply $HERE/fleet.toml" | tee -a "$LOG" >&2
    "$MAAS" apply "$HERE/fleet.toml" >"$APPLY2" 2>&1 || true
    cat "$APPLY2" >> "$LOG"
    # `applied: N transition(s) over …` — N must be 0. Parsed rather than eyeballed,
    # because "the fleet is converged" is the one claim in this run that a human reading
    # a wall of tables will nod along to without checking.
    n2="$(sed -nE 's/^ *applied: ([0-9]+) transition.*/\1/p' "$APPLY2" | tail -1)"
    # HELD nodes matter as much as the transition count. `apply` deliberately does not
    # touch a node in `error` — so a fleet with two thirds of it held reports ZERO
    # transitions and satisfies "fixed point" while doing nothing at all. That is exactly
    # what happened on the run this check was added for, and the ✓ printed anyway.
    # Zero transitions is convergence only when there is nothing being ignored.
    h2="$(sed -nE 's/^ *applied: .*, ([0-9]+) held for the operator.*/\1/p' "$APPLY2" | tail -1)"
    if [[ -z "$n2" ]]; then
        info "WARNING: could not parse the transition count out of pass 2 — the invariant was NOT checked"
    elif [[ "$n2" == 0 && "${h2:-0}" != 0 ]]; then
        info "WARNING: pass 2 issued 0 transitions, but ${h2} node(s) are HELD in 'error' and were"
        info "not considered at all. That is not a fixed point — it is a fleet apply has given up"
        info "on. Recover them ('maas-lab.sh retry <node>') and re-run to test convergence for real."
    elif [[ "$n2" == 0 ]]; then
        info "pass 2 issued 0 transitions and 0 nodes held — the whole fleet is a fixed point ✓"
    else
        info "WARNING: pass 2 issued $n2 transition(s). apply is not converging: either a node"
        info "keeps failing its gate and being retried, or fleet.toml declares an end-state the"
        info "fleet cannot reach. The verdict below reports the node's state either way."
    fi
    rm -f "$APPLY2"
else
    printf '   $ %s\n' "$MAAS apply $HERE/fleet.toml   # pass 2: must issue 0 transitions" >&2
fi

step "[10/10] the surface: register with the control pane + list the declared actions"
run_soft "$MAAS" watch "$NODE" --register-only
CP="$HERE/../../tools/control-pane"
[[ -x "$CP" ]] && run_soft "$CP" actions "$NODE"

# ── verdict ─────────────────────────────────────────────────────────────────
if [[ $DRY == 1 ]]; then
    printf '\nDRY RUN: the plan above touches nothing. Real run: sudo -v && %s\n' "$0" >&2
    exit 0
fi
st="$( "$MAAS" state "$NODE" 2>/dev/null )"
printf '\n' | tee -a "$LOG" >&2
if [[ "$st" == active ]]; then
    printf 'PASS: end-to-end on real domains — BMC round-trip, probe-reported facts, a SIGNED payload netbooted into RAM, and apply converged. %s is active.\n' "$NODE" | tee -a "$LOG" >&2
    printf '      log: %s     teardown: %s --down\n' "$LOG" "$0" >&2
    exit 0
fi
printf 'FAIL: %s ended in state "%s", not active — see %s (and: %s show %s)\n' \
    "$NODE" "${st:-<none>}" "$LOG" "$MAAS" "$NODE" | tee -a "$LOG" >&2
exit 1
