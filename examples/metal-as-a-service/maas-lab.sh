#!/usr/bin/env bash
# maas-lab.sh — a miniature bare-metal control plane (Metal-as-a-Service).
#
# INCREMENT 1 (build-order step 1): the fleet registry + the full Ironic-faithful
# state machine as PURE STATE TRANSITIONS, `power`/`bootdev` passthrough to the
# BMC, guarded `cleaning`, `error`/`maintenance`, and `rescue`. The heavy actions
# (a real PXE install, the RAM inspection probe, dd-a-golden-image) are build
# steps 2–5; here every verb is verifiable HEADLESSLY, with no libvirt and no
# install, because all out-of-band effects go through one injectable seam:
#
#     MAAS_BMC   -> path to bmc-toolkit's bmc.sh (default: ../bmc-toolkit/bmc.sh),
#                   invoked as `$MAAS_BMC <node> <verb> ...` (node first).
#                   Tests point it at a mock that records calls + returns canned
#                   output, so the whole machine drives with zero rootful libvirt.
#
# See METAL_AS_A_SERVICE_LAB_PLAN.md (§3 state machine, §9 build order) and the
# lab README for the design. Ironic node-state model:
#   https://docs.openstack.org/ironic/latest/contributor/states.html
#
# Security posture (AUDIT.md): BMC creds live on loopback only (F1); the
# `cleaning` disk wipe is path-guarded and HANDED TO THE USER, never auto-run
# (F7); processes are killed by PID, never by pattern.
set -uo pipefail

MAAS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly MAAS_DIR

# ── the BMC seam ────────────────────────────────────────────────────────────
# Default to the sibling bmc-toolkit; a test or a different fleet overrides it.
MAAS_BMC="${MAAS_BMC:-$MAAS_DIR/../bmc-toolkit/bmc.sh}"

die()  { printf 'maas: %s\n' "$*" >&2; exit 1; }
warn() { printf 'maas: %s\n' "$*" >&2; }
info() { printf '  - %s\n' "$*" >&2; }

# ── state directory resolution ──────────────────────────────────────────────
# Mirrors tools/control-pane's LAB_STATE_DIR logic so the two agree on one base
# (MAAS lives beside control-pane, which later renders its progress).
maas_state_root() {
    if [[ -n "${MAAS_STATE:-}" ]]; then printf '%s\n' "$MAAS_STATE"; return; fi
    local base
    if   [[ -n "${LAB_STATE_DIR:-}" ]]; then base="$LAB_STATE_DIR"
    elif [[ "$(id -u)" == 0 ]];         then base="/var/lib/lab-create"
    else base="${XDG_STATE_HOME:-$HOME/.local/state}/lab-create"; fi
    printf '%s/metal-as-a-service\n' "$base"
}
STATE_ROOT="$(maas_state_root)"
readonly STATE_ROOT
REG_BMC="$STATE_ROOT/fleet-bmc.toml"   # generated bmc-toolkit registry for bmc.sh

# The surfacing layer: MAAS ships milestone PROFILES; the engine + `watch` are the
# repo tool tools/control-pane (CONTROL_PANE_LAB_PLAN.md). `watch` delegates to it.
CONTROL_PANE="${CONTROL_PANE:-$MAAS_DIR/../../tools/control-pane}"
MAAS_MILESTONES="${MAAS_MILESTONES:-$MAAS_DIR/milestones.toml}"

# Deploy drivers + signed-image store (increment 3). A driver is drivers/<name>.sh
# implementing verify/deploy/health/describe; MAAS_DRIVER_DIR lets tests inject a
# mock. Images (signed payloads) live under MAAS_IMAGES_DIR/<image>/, trust root at
# MAAS_IMAGES_DIR/trust/ca.crt.
MAAS_DRIVER_DIR="${MAAS_DRIVER_DIR:-$MAAS_DIR/drivers}"
MAAS_IMAGES_DIR="${MAAS_IMAGES_DIR:-$STATE_ROOT/images}"
MAAS_HEALTH_TIMEOUT="${MAAS_HEALTH_TIMEOUT:-120}"

# Where a lab registers control-pane nodes — always the SIBLING of STATE_ROOT
# (both are "<base>/<component>"), so Phase-6 (which reads $LAB_STATE_DIR/control-pane
# via tools/control_pane/cli.py's _fleet_dir) and MAAS land under one base.
control_pane_fleet_dir() { printf '%s/control-pane\n' "$(dirname "$STATE_ROOT")"; }

node_dir()  { printf '%s/%s\n' "$STATE_ROOT" "$1"; }
node_exists() { [[ -d "$(node_dir "$1")" ]]; }
require_node() { node_exists "$1" || die "no such node '$1' (enroll it first: maas-lab.sh enroll $1 ...)"; }

# ── registry primitives (atomic single-value files) ─────────────────────────
# The registry is a directory tree: one dir per node, one small file per field.
# Atomic writes (tmp + mv) keep `state` always readable and never half-written.
_write() {  # _write <node> <field> <value>
    local d; d="$(node_dir "$1")"; mkdir -p "$d"
    printf '%s\n' "$3" > "$d/.$2.tmp" && mv "$d/.$2.tmp" "$d/$2"
}
_read() {   # _read <node> <field> [default]
    local f; f="$(node_dir "$1")/$2"
    if [[ -f "$f" ]]; then cat "$f"; else printf '%s' "${3:-}"; fi
}
read_state() { _read "$1" state ""; }

# The single choke-point for every state change: validates nothing here (callers
# guard preconditions), records the transition in history, writes atomically.
set_state() {  # set_state <node> <new-state> <verb>
    local node="$1" new="$2" verb="$3" old ts
    old="$(read_state "$node")"; old="${old:-<new>}"
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _write "$node" state "$new"
    printf '%s  %-11s -> %-11s (%s)\n' "$ts" "$old" "$new" "$verb" \
        >> "$(node_dir "$node")/history.log"
}

# Precondition guard: current state must be one of the allowed set, else refuse
# with a SPECIFIC message naming the required state (test convention: name the
# defect, not "illegal transition").
require_state() {  # require_state <node> <verb> <allowed>...
    local node="$1" verb="$2"; shift 2
    local cur; cur="$(read_state "$node")"
    local a
    for a in "$@"; do [[ "$cur" == "$a" ]] && return 0; done
    die "cannot '$verb' node '$node' from state '${cur:-<none>}' — needs one of: $*"
}

# ── the BMC seam ────────────────────────────────────────────────────────────
# All power/bootdev/sol reach the node through bmc-toolkit, using MAAS's own
# generated registry. A mock bmc.sh (tests) ignores the registry entirely.
bmc() {  # bmc <node> <verb> [args...]
    BMC_REGISTRY="$REG_BMC" "$MAAS_BMC" "$@"
}

# Regenerate the bmc-toolkit registry from every enrolled node (all vbmcd on
# loopback). Called on enroll so `bmc.sh` can resolve MAAS's node names.
regen_bmc_registry() {
    local tmp="$REG_BMC.tmp" d n
    mkdir -p "$STATE_ROOT"
    {
        printf '# Generated by maas-lab.sh — do not hand-edit (regenerated on enroll).\n'
        printf '# bmc-toolkit registry: MAAS fleet, all vbmcd on loopback (F1).\n\n'
        for d in "$STATE_ROOT"/*/; do
            [[ -f "$d/state" ]] || continue
            n="$(basename "$d")"
            printf '[[node]]\n'
            printf 'name      = "%s"\n' "$n"
            printf 'backend   = "vbmcd"\n'
            printf 'domain    = "%s"\n' "$(_read "$n" domain "$n")"
            printf 'uri       = "%s"\n' "$(_read "$n" uri qemu:///system)"
            printf 'ipmi_host = "%s"\n' "$(_read "$n" bmc_host 127.0.0.1)"
            printf 'ipmi_port = %s\n'   "$(_read "$n" bmc_port 623)"
            printf 'ipmi_user = "%s"\n' "$(_read "$n" bmc_user admin)"
            printf 'ipmi_pass = "%s"\n\n' "$(_read "$n" bmc_pass password)"
        done
    } > "$tmp" && mv "$tmp" "$REG_BMC"
}

# ═══════════════════════════════════════════════════════════════════════════
# Verbs
# ═══════════════════════════════════════════════════════════════════════════

# enroll — register a node into the fleet (∅ -> enrolled).
cmd_enroll() {
    local node="" domain="" bmc_port="" mac="" firmware="bios" uri="qemu:///system"
    local bmc_user="admin" bmc_pass="password" bmc_host="127.0.0.1" console=""
    node="${1:?usage: enroll <node> --bmc-port P [--domain D --mac M --firmware bios|uefi]}"; shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain)   domain="$2"; shift 2 ;;
            --bmc-port) bmc_port="$2"; shift 2 ;;
            --bmc-host) bmc_host="$2"; shift 2 ;;
            --bmc-user) bmc_user="$2"; shift 2 ;;
            --bmc-pass) bmc_pass="$2"; shift 2 ;;
            --mac)      mac="$2"; shift 2 ;;
            --firmware) firmware="$2"; shift 2 ;;
            --uri)      uri="$2"; shift 2 ;;
            --console)  console="$2"; shift 2 ;;
            *) die "enroll: unknown option '$1'" ;;
        esac
    done
    node_exists "$node" && die "node '$node' already enrolled (state=$(read_state "$node")); use 'show $node'"
    [[ -n "$bmc_port" ]] || die "enroll: --bmc-port is required (the node's loopback IPMI port, e.g. 6230)"
    [[ "$firmware" == bios || "$firmware" == uefi ]] || die "enroll: --firmware must be 'bios' or 'uefi'"
    [[ -n "$domain" ]] || domain="$node"
    mkdir -p "$(node_dir "$node")"
    _write "$node" domain "$domain"
    _write "$node" bmc_port "$bmc_port"
    _write "$node" bmc_host "$bmc_host"
    _write "$node" bmc_user "$bmc_user"
    _write "$node" bmc_pass "$bmc_pass"
    _write "$node" uri "$uri"
    [[ -n "$mac" ]] && _write "$node" mac "$mac"
    [[ -n "$console" ]] && _write "$node" console "$console"
    _write "$node" firmware "$firmware"
    set_state "$node" enrolled enroll
    regen_bmc_registry
    printf 'enrolled %s (domain=%s bmc=%s:%s firmware=%s)\n' \
        "$node" "$domain" "$bmc_host" "$bmc_port" "$firmware" >&2
}

# manage — verify BMC creds, make the node manageable (enrolled|error -> manageable).
# The `verifying` state is passed THROUGH so the saga shows in history; a BMC that
# doesn't answer sends the node to `error`, not a silent hang.
cmd_manage() {
    local node="${1:?usage: manage <node>}"; require_node "$node"
    require_state "$node" manage enrolled error
    set_state "$node" verifying manage
    if bmc "$node" power status >/dev/null 2>&1; then
        set_state "$node" manageable manage
        printf 'manageable %s (BMC creds verified)\n' "$node" >&2
    else
        set_state "$node" error manage
        die "verify failed for '$node': BMC did not answer 'power status' — node -> error (retry after fixing the BMC)"
    fi
}

# summarize_facts — distil facts.json into a one-line schedulable summary (cpus/mem)
# for `list`/`show`. Ironic populates "schedulable facts" from introspection; this is
# the miniature of that.
summarize_facts() {  # summarize_facts <node>
    local node="$1" fj; fj="$(node_dir "$node")/facts.json"
    [[ -f "$fj" ]] || return 0
    python3 - "$fj" > "$(node_dir "$node")/schedulable" 2>/dev/null <<'PY' || true
import json, sys
try:
    f = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
cpus = f.get("cpus") or f.get("cpu") or "?"
mem = f.get("mem_mb")
if mem is None and f.get("mem_kb"):
    try: mem = int(f["mem_kb"]) // 1024
    except Exception: mem = "?"
mac = f.get("mac", "?")
print(f"cpus={cpus} mem_mb={mem or '?'} mac={mac}")
PY
}

# inspect — populate schedulable facts (manageable -> manageable, + facts). Three
# modes: --facts injects a file (headless); --from-metadata records what the
# inspection probe POSTed to the metadata service; --boot runs the REAL probe over
# the BMC (author-run). The introspection ramdisk itself is `probe-init.sh`.
cmd_inspect() {
    local node="" facts="" mode="" timeout=120
    node="${1:?usage: inspect <node> --facts F | --from-metadata | --boot}"; shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --facts)         facts="$2"; mode="facts"; shift 2 ;;
            --from-metadata) mode="metadata"; shift ;;
            --boot)          mode="boot"; shift ;;
            --timeout)       timeout="$2"; shift 2 ;;
            *) die "inspect: unknown option '$1'" ;;
        esac
    done
    require_node "$node"
    require_state "$node" inspect manageable
    local nd; nd="$(node_dir "$node")"
    case "$mode" in
        facts)
            [[ -f "$facts" ]] || die "inspect: --facts file not found: $facts"
            cp -- "$facts" "$nd/facts.json"
            info "recorded schedulable facts from $facts" ;;
        metadata)
            [[ -f "$nd/facts.received" ]] || die "inspect --from-metadata: node '$node' has not reported facts yet (no POST to the metadata service). Boot the probe (--boot) or run metadata-serve.sh + the probe."
            info "recorded facts the probe POSTed to the metadata service" ;;
        boot)
            # REAL introspection: PXE-boot the probe; it POSTs facts to the metadata
            # service and powers off. Needs a live BMC + metadata-serve.sh + the probe
            # image on the PXE net → AUTHOR-RUN.
            rm -f "$nd/facts.received"
            bmc "$node" bootdev pxe >/dev/null 2>&1 || die "inspect --boot: could not set bootdev pxe (is the BMC up?)"
            bmc "$node" power on    >/dev/null 2>&1 || die "inspect --boot: could not power on the node"
            info "booted inspection probe on '$node'; awaiting facts (timeout ${timeout}s)…"
            local waited=0
            while [[ ! -f "$nd/facts.received" ]]; do
                sleep 2; waited=$((waited+2))
                [[ $waited -ge $timeout ]] && { bmc "$node" power off >/dev/null 2>&1 || true; die "inspect --boot: timed out after ${timeout}s with no facts from '$node' — check metadata-serve.sh + the probe console"; }
            done
            bmc "$node" power off >/dev/null 2>&1 || true
            info "probe reported facts for '$node'" ;;
        "")
            die "inspect: choose a mode — --facts <file> (inject), --from-metadata (read the probe's POST), or --boot (real probe over the BMC)" ;;
    esac
    summarize_facts "$node"
    set_state "$node" manageable inspect   # re-affirm; records the inspect in history
    printf 'inspected %s (%s)\n' "$node" "$(_read "$node" schedulable 'facts recorded')" >&2
}

# watch — render live boot/install progress for a node, via tools/control-pane.
# MAAS ships the milestone PROFILES (milestones.toml); the engine + bars are the
# repo tool. `watch` also REGISTERS the node under the control-pane fleet dir so
# Phase-6 surfaces the same node with a live bar (the plan's "same file the Phase-6
# bars consume"). Profile defaults from the node's deploy driver.
cmd_watch() {
    local node="" console="" profile="" register_only=0 stall=""
    node="${1:?usage: watch <node> [--console F] [--profile P] [--register-only] [--stall SEC]}"; shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --console)       console="$2"; shift 2 ;;
            --profile)       profile="$2"; shift 2 ;;
            --register-only) register_only=1; shift ;;
            --stall)         stall="$2"; shift 2 ;;
            *) die "watch: unknown option '$1'" ;;
        esac
    done
    require_node "$node"
    [[ -x "$CONTROL_PANE" ]] || die "watch: tools/control-pane not found/executable at $CONTROL_PANE"
    # profile: explicit, else map the deploy driver, else 'probe' (inspection) then 'install'
    if [[ -z "$profile" ]]; then
        local drv; drv="$(_read "$node" driver "")"
        case "$drv" in
            install) profile=install ;;
            ramdisk) profile=ramdisk ;;
            image|image+measured) profile=image ;;
            *)       profile=install ;;
        esac
    fi
    # console: explicit, else registered, else the conventional per-node log
    [[ -z "$console" ]] && console="$(_read "$node" console "")"
    [[ -z "$console" ]] && console="$(node_dir "$node")/console.log"

    # Register into the control-pane fleet so Phase-6 (TUI + web) surfaces this node.
    local fleet; fleet="$(control_pane_fleet_dir)"
    mkdir -p "$fleet/$node"
    { printf 'profile = "%s"\n' "$profile"
      printf 'console = "%s"\n' "$console"
      printf 'milestones = "%s"\n' "$MAAS_MILESTONES"; } > "$fleet/$node/node.toml"
    info "registered '$node' under the control-pane fleet: $fleet/$node/node.toml (profile=$profile)"
    [[ $register_only -eq 1 ]] && { printf 'registered %s for Phase-6 (profile=%s)\n' "$node" "$profile" >&2; return 0; }

    [[ -f "$console" ]] || die "watch: console log not found: $console (the node must be booting/logging; pass --console, or --register-only to just surface it in Phase-6)"
    info "watching $node (profile=$profile) via tools/control-pane…"
    exec "$CONTROL_PANE" watch --profile "$profile" --milestones "$MAAS_MILESTONES" \
        ${stall:+--stall "$stall"} "$console"
}

# provide — clean the node and make it schedulable (manageable -> available).
# Passes THROUGH `cleaning`: a disk wipe is a SECURITY BOUNDARY (data remanence),
# not housekeeping. A node with a real backing disk STAYS in `cleaning` until the
# operator runs the handed-over wipe and re-runs with --wiped — the machine never
# auto-runs a destructive command (F7). A diskless (ramdisk) node cleans as a
# genuine no-op.
cmd_provide() {
    local node="" wiped=0
    node="${1:?usage: provide <node> [--wiped]}"; shift
    while [[ $# -gt 0 ]]; do
        case "$1" in --wiped) wiped=1; shift ;; *) die "provide: unknown option '$1'" ;; esac
    done
    require_node "$node"
    require_state "$node" provide manageable cleaning
    set_state "$node" cleaning provide
    if wipe_disk "$node" "$wiped"; then
        set_state "$node" available provide
        printf 'available %s (cleaned; schedulable)\n' "$node" >&2
    else
        die "node '$node' stays in 'cleaning' until its disk is wiped — do the wipe above, then: provide $node --wiped"
    fi
}

# wipe_disk — the `cleaning` action. NEVER runs a destructive verb itself; it
# prints the exact, path-guarded command for the operator to run (F7 + the repo
# rule: destructive deletes are handed over, not auto-executed).
# Returns 0 = clean (no disk, or operator-confirmed); 2 = wipe pending (handed
# over). Refuses (exit 1) a disk outside the lab-owned allow-list.
wipe_disk() {  # wipe_disk <node> <confirmed:0|1>
    local node="$1" confirmed="${2:-0}" disk
    disk="$(_read "$node" disk "")"
    if [[ -z "$disk" ]]; then
        info "cleaning '$node': no backing disk registered — wipe is a no-op (ramdisk-style node)"
        return 0
    fi
    case "$disk" in
        /var/lib/libvirt/images/*|"$STATE_ROOT"/*) : ;;   # allow-list: lab-owned paths only
        *) die "cleaning refused: disk '$disk' is outside the lab's allow-list — will not wipe" ;;
    esac
    if [[ "$confirmed" == 1 ]]; then
        info "operator confirmed the wipe of $disk (--wiped)"
        return 0
    fi
    warn "cleaning '$node' needs a disk wipe (data remanence). NOT auto-run — run this yourself:"
    printf '    sudo blkdiscard -f %q  ||  sudo dd if=/dev/zero of=%q bs=1M status=progress\n' \
        "$disk" "$disk" >&2
    return 2
}

# run_driver — invoke a deploy driver verb with the node/image context in the env.
# The driver (drivers/<name>.sh) implements verify/deploy/health/describe.
run_driver() {  # run_driver <driver-script> <verb> <args...>
    local drv="$1"; shift
    MAAS_BMC="$MAAS_BMC" MAAS_STATE="$STATE_ROOT" MAAS_IMAGES_DIR="$MAAS_IMAGES_DIR" \
    MAAS_HEALTH_TIMEOUT="$MAAS_HEALTH_TIMEOUT" MAAS_REG_BMC="$REG_BMC" \
        "$drv" "$@"
}

# gate — the activation gate for one image: verify (F2, unless --no-verify) ->
# deploy -> health. Sets GATE_REASON on failure. Returns 0 healthy, non-zero not.
GATE_REASON=""
gate() {  # gate <driver-script> <node> <image> <slot> <verify:0|1>
    local drv="$1" node="$2" image="$3" slot="$4" do_verify="$5"
    GATE_REASON=""
    if [[ "$do_verify" == 1 ]]; then
        if ! run_driver "$drv" verify "$image" >/dev/null 2>&1; then
            GATE_REASON="F2 signature verification failed for image '$image'"
            return 1
        fi
    fi
    if ! run_driver "$drv" deploy "$node" "$image" "$slot"; then
        GATE_REASON="driver could not deploy image '$image'"
        return 1
    fi
    if ! run_driver "$drv" health "$node" "$image"; then
        GATE_REASON="image '$image' failed its health gate (never reached 'active')"
        return 1
    fi
    return 0
}

# deploy — put an OS on the node through a driver, gated on health, with A/B
# rollback (§4b). deploying -> active only if the image VERIFIES (F2) and passes
# its HEALTH gate; a failure rolls the node back to its previous good image
# (staying degraded-but-up) instead of bricking; both slots bad -> error. Allowed
# from `available` (fresh) and `active` (A/B upgrade-in-place).
cmd_deploy() {
    local node="" driver="" image="" do_verify=1
    node="${1:?usage: deploy <node> --driver D --image I [--no-verify]}"; shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --driver)    driver="$2"; shift 2 ;;
            --image)     image="$2"; shift 2 ;;
            --no-verify) do_verify=0; shift ;;
            *) die "deploy: unknown option '$1'" ;;
        esac
    done
    require_node "$node"
    require_state "$node" deploy available active
    [[ -n "$driver" ]] || die "deploy: --driver is required (install|ramdisk|image|image+measured)"
    [[ -n "$image" ]]  || die "deploy: --image is required (the payload to deploy)"

    # Resolve the driver script. install is real (author-run); ramdisk/image are
    # honest not-yet — name the build step rather than pretending.
    local drv="$MAAS_DRIVER_DIR/$driver.sh"
    if [[ ! -x "$drv" ]]; then
        case "$driver" in
            ramdisk) die "deploy: the 'ramdisk' driver lands in build step 4 (not yet implemented)" ;;
            image)   die "deploy: the 'image' driver lands in build step 5 (not yet implemented)" ;;
            image+measured) die "deploy: 'image+measured' is a documented fast-follow (not yet implemented)" ;;
            *) die "deploy: no driver '$driver' at $drv" ;;
        esac
    fi

    local prev; prev="$(_read "$node" image "")"     # current image -> rollback candidate
    _write "$node" driver "$driver"
    set_state "$node" deploying deploy
    info "deploying image '$image' via '$driver' (verify=$do_verify, health timeout ${MAAS_HEALTH_TIMEOUT}s)…"

    if gate "$drv" "$node" "$image" current "$do_verify"; then
        _write "$node" image "$image"
        [[ -n "$prev" && "$prev" != "$image" ]] && _write "$node" previous_image "$prev"
        set_state "$node" active deploy
        printf 'active %s (driver=%s image=%s, healthy)\n' "$node" "$driver" "$image" >&2
        return 0
    fi

    # New image failed (bad signature OR bad health) — A/B rollback to previous.
    warn "$GATE_REASON"
    if [[ -n "$prev" && "$prev" != "$image" ]]; then
        warn "rolling back '$node' to its previous image '$prev' (§4b A/B)…"
        set_state "$node" deploying deploy
        if gate "$drv" "$node" "$prev" previous "$do_verify"; then
            _write "$node" image "$prev"
            _write "$node" previous_image ""
            set_state "$node" active deploy
            warn "DEGRADED: '$node' is active on its PREVIOUS image '$prev' (new image '$image' was rejected)"
            printf 'active %s (driver=%s image=%s, DEGRADED — rolled back)\n' "$node" "$driver" "$prev" >&2
            return 0
        fi
        set_state "$node" error deploy
        die "both images failed for '$node' (new '$image' and previous '$prev') — node -> error (operator)"
    fi
    set_state "$node" error deploy
    die "$GATE_REASON, and no previous image to roll back to — node '$node' -> error"
}

# rescue — boot a recovery ramdisk to fix a broken node (active -> rescue).
# INCREMENT 1: records intent + flips bootdev; the real root-password-reset
# recovery ramdisk boot is a fast-follow.
cmd_rescue() {
    local node="${1:?usage: rescue <node>}"; require_node "$node"
    require_state "$node" rescue active
    set_state "$node" rescuing rescue
    bmc "$node" bootdev pxe >/dev/null 2>&1 || info "(bootdev pxe not confirmed — headless/mock)"
    info "recovery ramdisk (root-password-reset idioms) boots here — fast-follow"
    set_state "$node" rescue rescue
    printf 'rescue %s (recovery mode)\n' "$node" >&2
}

# unrescue — leave rescue, back to service (rescue -> active).
cmd_unrescue() {
    local node="${1:?usage: unrescue <node>}"; require_node "$node"
    require_state "$node" unrescue rescue
    bmc "$node" bootdev disk >/dev/null 2>&1 || true
    set_state "$node" active unrescue
    printf 'active %s (left rescue)\n' "$node" >&2
}

# release — return a node to the pool (active|rescue -> available), via cleaning.
# Same F7 wipe guard as provide: a node with a real disk stays in `cleaning`
# until --wiped.
cmd_release() {
    local node="" wiped=0
    node="${1:?usage: release <node> [--wiped]}"; shift
    while [[ $# -gt 0 ]]; do
        case "$1" in --wiped) wiped=1; shift ;; *) die "release: unknown option '$1'" ;; esac
    done
    require_node "$node"
    require_state "$node" release active rescue cleaning
    set_state "$node" deleting release
    # a released node's slots are stale — forget them so the next tenant starts clean
    rm -f "$(node_dir "$node")/driver" "$(node_dir "$node")/image" \
          "$(node_dir "$node")/previous_image" 2>/dev/null || true
    set_state "$node" cleaning release
    if wipe_disk "$node" "$wiped"; then
        set_state "$node" available release
        printf 'available %s (released to pool)\n' "$node" >&2
    else
        die "node '$node' stays in 'cleaning' until its disk is wiped — do the wipe above, then: release $node --wiped"
    fi
}

# maintenance — pull a node out of scheduling (any -> maintenance), remembering
# the state to return to. unmaintenance restores it.
cmd_maintenance() {
    local node="${1:?usage: maintenance <node>}"; require_node "$node"
    local cur; cur="$(read_state "$node")"
    [[ "$cur" == maintenance ]] && die "node '$node' is already in maintenance"
    _write "$node" prior_state "$cur"
    set_state "$node" maintenance maintenance
    printf 'maintenance %s (was %s)\n' "$node" "$cur" >&2
}
cmd_unmaintenance() {
    local node="${1:?usage: unmaintenance <node>}"; require_node "$node"
    require_state "$node" unmaintenance maintenance
    local prior; prior="$(_read "$node" prior_state manageable)"
    set_state "$node" "$prior" unmaintenance
    rm -f "$(node_dir "$node")/prior_state" 2>/dev/null || true
    printf '%s %s (out of maintenance)\n' "$prior" "$node" >&2
}

# retry — re-drive a failed node (error -> manageable via manage's verify).
cmd_retry() {
    local node="${1:?usage: retry <node>}"; require_node "$node"
    require_state "$node" retry error
    cmd_manage "$node"
}

# power / bootdev / console — passthrough to the BMC (the seam).
cmd_power() {
    local node="${1:?usage: power <node> on|off|cycle|status}"; require_node "$node"
    local sub="${2:?usage: power <node> on|off|cycle|status}"
    bmc "$node" power "$sub"
}
cmd_bootdev() {
    local node="${1:?usage: bootdev <node> pxe|disk|cdrom}"; require_node "$node"
    local sub="${2:?usage: bootdev <node> pxe|disk|cdrom}"
    bmc "$node" bootdev "$sub"
}
cmd_console() {  # honest SOL substitute = libvirt serial via bmc-toolkit's `sol`
    local node="${1:?usage: console <node>}"; require_node "$node"
    bmc "$node" sol
}

# ── readers ─────────────────────────────────────────────────────────────────
cmd_state() { local node="${1:?usage: state <node>}"; require_node "$node"; read_state "$node"; }

cmd_show() {
    local node="${1:?usage: show <node>}"; require_node "$node"
    local d; d="$(node_dir "$node")"
    printf 'node        %s\n' "$node"
    printf 'state       %s\n' "$(read_state "$node")"
    printf 'domain      %s\n' "$(_read "$node" domain -)"
    printf 'bmc         %s:%s (%s/%s)\n' "$(_read "$node" bmc_host -)" "$(_read "$node" bmc_port -)" \
        "$(_read "$node" bmc_user -)" "$(_read "$node" bmc_pass -)"
    printf 'firmware    %s\n' "$(_read "$node" firmware -)"
    printf 'driver      %s\n' "$(_read "$node" driver -)"
    printf 'image       %s (previous: %s)\n' "$(_read "$node" image -)" "$(_read "$node" previous_image -)"
    printf 'schedulable %s\n' "$(_read "$node" schedulable -)"
    [[ -f "$d/facts.json" ]] && printf 'facts       %s\n' "$(cat "$d/facts.json")"
    if [[ -f "$d/history.log" ]]; then
        printf 'history:\n'; sed 's/^/  /' "$d/history.log"
    fi
}

cmd_list() {
    local json=0; [[ "${1:-}" == "--json" ]] && json=1
    local d n st dr
    if [[ $json -eq 1 ]]; then
        printf '['
        local first=1
        for d in "$STATE_ROOT"/*/; do
            [[ -f "$d/state" ]] || continue
            n="$(basename "$d")"; st="$(read_state "$n")"; dr="$(_read "$n" driver "")"
            [[ $first -eq 1 ]] || printf ','; first=0
            printf '{"name":"%s","state":"%s","driver":"%s"}' "$n" "$st" "$dr"
        done
        printf ']\n'
        return
    fi
    [[ -d "$STATE_ROOT" ]] || { printf 'no nodes enrolled (state dir: %s)\n' "$STATE_ROOT" >&2; return; }
    local any=0
    printf '%-10s %-12s %-10s %s\n' NODE STATE DRIVER DOMAIN
    for d in "$STATE_ROOT"/*/; do
        [[ -f "$d/state" ]] || continue
        any=1; n="$(basename "$d")"
        printf '%-10s %-12s %-10s %s\n' "$n" "$(read_state "$n")" \
            "$(_read "$n" driver -)" "$(_read "$n" domain -)"
    done
    [[ $any -eq 1 ]] || printf 'no nodes enrolled (state dir: %s)\n' "$STATE_ROOT" >&2
}

usage() {
    cat >&2 <<'EOF'
maas-lab.sh — miniature bare-metal control plane (increment 1: registry + state machine)

Lifecycle verbs (Ironic-faithful state machine):
  enroll <node> --bmc-port P [--domain D --mac M --firmware bios|uefi]   (∅ -> enrolled)
  manage <node>                          enrolled|error -> manageable (verifies BMC)
  inspect <node> {--facts F|--from-metadata|--boot}   manageable (+schedulable facts)
  provide <node> [--wiped]               manageable -> available (via cleaning/wipe)
  deploy <node> --driver D [--image I]   available -> active (install|ramdisk|image|image+measured)
  rescue <node> / unrescue <node>        active <-> rescue
  release <node> [--wiped]               active|rescue -> available (via cleaning)
  maintenance <node> / unmaintenance <node>   any <-> maintenance
  retry <node>                           error -> manageable

Out-of-band (passthrough to bmc-toolkit's bmc.sh via MAAS_BMC):
  power <node> {on|off|cycle|status}     bootdev <node> {pxe|disk|cdrom}     console <node>

Watch live boot/install progress (delegates to tools/control-pane):
  watch <node> [--console F] [--profile P] [--register-only] [--stall SEC]

Inspect the registry:
  list [--json]     state <node>     show <node>

Increment 1 is headless: set MAAS_BMC=<mock> to drive the whole machine with no libvirt.
State dir: $STATE_ROOT (override with MAAS_STATE / LAB_STATE_DIR).
EOF
}

# ── dispatch ────────────────────────────────────────────────────────────────
main() {
    local verb="${1:-}"; [[ $# -gt 0 ]] && shift
    case "$verb" in
        enroll)        cmd_enroll "$@" ;;
        manage)        cmd_manage "$@" ;;
        inspect)       cmd_inspect "$@" ;;
        provide)       cmd_provide "$@" ;;
        deploy)        cmd_deploy "$@" ;;
        rescue)        cmd_rescue "$@" ;;
        unrescue)      cmd_unrescue "$@" ;;
        release|undeploy) cmd_release "$@" ;;
        maintenance)   cmd_maintenance "$@" ;;
        unmaintenance) cmd_unmaintenance "$@" ;;
        retry)         cmd_retry "$@" ;;
        power)         cmd_power "$@" ;;
        bootdev)       cmd_bootdev "$@" ;;
        console|sol)   cmd_console "$@" ;;
        watch)         cmd_watch "$@" ;;
        state)         cmd_state "$@" ;;
        show)          cmd_show "$@" ;;
        list)          cmd_list "$@" ;;
        _state-root)   printf '%s\n' "$STATE_ROOT" ;;   # internal: metadata-serve.sh
        ""|-h|--help|help) usage ;;
        *) die "unknown verb '$verb' (try: maas-lab.sh --help)" ;;
    esac
}
main "$@"
