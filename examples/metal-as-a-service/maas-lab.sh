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

# driver_path <name> — the script implementing a driver.
#
# The CLI name and the filename differ: `image+measured` is what every doc and
# run-e2e-measured.sh tell you to type, and the file is drivers/image-measured.sh
# because `+` in a filename is a nuisance. One function owns that mapping, because
# it was open-coded in FOUR places and three of them were wrong — including the
# rollback path, where a node deployed as `image+measured` could never have been
# rolled back at all. Found live 2026-07-29.
driver_path() { printf '%s/%s.sh' "$MAAS_DRIVER_DIR" "${1//+/-}"; }
# absolute path to THIS script — the declared panel actions must run from any cwd
MAAS_SELF="${MAAS_SELF:-$MAAS_DIR/maas-lab.sh}"
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
# A FAILED WRITE MUST NOT BE SILENT. This used to be a bare `printf > tmp && mv`
# whose exit status nobody read: with the state dir unwritable, `deploy` printed
# "active <node> (image=v2, healthy)", exited 0, and left the registry saying v1 —
# while the driver had really put v2 on the machine. Reality and the record diverged
# with no error, so every later decision (the rollback target, `recheck`, `apply`'s
# diff) was made against a lie. Found by chaos-run.sh's registry-layer scenario.
_write() {  # _write <node> <field> <value>
    local d; d="$(node_dir "$1")"; mkdir -p "$d" 2>/dev/null
    { printf '%s\n' "$3" > "$d/.$2.tmp" && mv "$d/.$2.tmp" "$d/$2"; } 2>/dev/null \
        || die "cannot write the registry ($d/$2) — the state store is unwritable (full disk? read-only mount?). Refusing to continue: an unrecorded change is worse than a refused one, because nothing downstream can tell they diverged"
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
        >> "$(node_dir "$node")/history.log" 2>/dev/null \
        || die "recorded state '$new' for '$node' but could not append to its history.log — the state store is only partly writable; refusing to continue with a registry that cannot keep its own audit trail"
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

# manage — verify BMC creds, make the node manageable
# (enrolled | error | available -> manageable). The `verifying` state is passed THROUGH so
# the saga shows in history; a BMC that doesn't answer sends the node to `error`, not a
# silent hang.
#
# `available` is here because Ironic puts it here: `manage` is the **unprovide** edge, the
# way a node in the free pool is pulled back out of it for re-inspection or maintenance.
# Without it `available` was a one-way door — nothing led back to `manageable`, so a node
# that had ever been provisioned could never be inspected again. (Found live: a second
# run of run-e2e.sh over an already-`active` fleet had no route back, and `inspect`
# refused. The state machine was missing an edge that Ironic's has.)
cmd_manage() {
    local node="${1:?usage: manage <node>}"; require_node "$node"
    require_state "$node" manage enrolled error available
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

# _write_probe_ipxe <node> <md-url> — the introspection BOOT SCRIPT.
#
# `inspect --boot` used to set bootdev=pxe, power on, and hope the PXE network happened
# to be serving the probe. It never was: the network serves ONE baked boot.ipxe (see
# netboot-chain.sh), so the node dutifully netbooted whatever that was — a busybox
# shell — gathered nothing, reported nothing, and the only symptom was a 120s timeout
# blaming "the probe console". The control plane must SAY what the node boots, exactly
# as the deploy drivers do for a payload. Same shape as drivers/ramdisk.sh's script.
#
# The probe learns its identity and where to report from the kernel cmdline
# (`maas.node=` / `maas.md=` — see probe-init.sh); a probe that boots without them is a
# machine that measures itself and drops the answer on the floor, so both are required.
_write_probe_ipxe() {
    local node="$1" md="$2"
    local nb="${MAAS_NETBOOT_DIR:-$HOME/netboot}"
    local port="${MAAS_NETBOOT_PORT:-8181}"
    local kern="${MAAS_PROBE_KERNEL:-kernel}"
    local ird="${MAAS_PROBE_INITRD:-probe-initramfs.cpio.gz}"
    [[ -n "$md" ]] || die "inspect --boot: no metadata URL. The probe learns where to report
from its kernel cmdline (maas.md=...); without it the node boots, measures itself and has
nowhere to send the answer. Pass --md-url http://<gw>:8282, or set MAAS_MD_URL — it must be
the address metadata-serve.sh is actually bound to, reachable FROM the node."
    [[ -f "$nb/$kern" ]] || die "inspect --boot: no probe kernel in the PXE docroot ($nb/$kern).
The probe is an initramfs, not a kernel — it needs one to be netbooted with. Stage the PXE
payload first: ( cd ../virtualbmc-ipmi-lab && ./setup-pxe-net.sh ), or set MAAS_PROBE_KERNEL."
    [[ -f "$nb/$ird" ]] || die "inspect --boot: the probe initramfs is not staged at $nb/$ird.
Build it: ./build-probe-initramfs.sh --out $nb/$ird"
    mkdir -p "$nb/maas" || die "inspect --boot: could not create $nb/maas"
    local script="$nb/maas/$node.ipxe"
    {   printf '#!ipxe\n'
        printf '# generated by maas-lab.sh for the INTROSPECTION boot of %s\n' "$node"
        printf 'kernel http://${next-server}:%s/%s console=ttyS0 ip=dhcp maas.node=%s maas.md=%s\n' \
               "$port" "$kern" "$node" "$md"
        printf 'initrd http://${next-server}:%s/%s\n' "$port" "$ird"
        printf 'boot\n'
    } > "$script" || die "inspect --boot: could not write the probe boot script at $script"
    info "wrote the introspection boot script: $script (reports to $md)"
}

# inspect — populate schedulable facts (manageable -> manageable, + facts). Three
# modes: --facts injects a file (headless); --from-metadata records what the
# inspection probe POSTed to the metadata service; --boot runs the REAL probe over
# the BMC (author-run). The introspection ramdisk itself is `probe-init.sh`.
cmd_inspect() {
    local node="" facts="" mode="" timeout=120 md_url="${MAAS_MD_URL:-}"
    node="${1:?usage: inspect <node> --facts F | --from-metadata | --boot}"; shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --facts)         facts="$2"; mode="facts"; shift 2 ;;
            --from-metadata) mode="metadata"; shift ;;
            --boot)          mode="boot"; shift ;;
            --md-url)        md_url="$2"; shift 2 ;;
            --timeout)       timeout="$2"; shift 2 ;;
            *) die "inspect: unknown option '$1'" ;;
        esac
    done
    require_node "$node"
    require_state "$node" inspect manageable
    local nd; nd="$(node_dir "$node")"
    case "$mode" in
        facts)
            # -r, NOT -f. The README's own quickstart injects facts with
            # `--facts /dev/stdin <<<'{...}'`, and under bash 5.2 a here-string is a PIPE:
            # /dev/stdin resolves through /proc/self/fd/0 to a pipe, so `-f` is FALSE while
            # `-r` is true and `cp` copies it happily. That gate shipped in this tool's
            # first commit and the README line in the next one, so the documented command
            # had never worked at any commit -- and all 38 tests stayed green, because the
            # only --facts caller among them passes a real file. Ask whether the source is
            # READABLE (the thing cp needs), and refuse a directory by name, which is the
            # case `-f` was really excluding.
            [[ -d "$facts" ]] && die "inspect: --facts is a directory, not a facts file: $facts"
            [[ -r "$facts" ]] || die "inspect: --facts source is not readable: $facts"
            cp -- "$facts" "$nd/facts.json" || die "inspect: could not read facts from $facts"
            info "recorded schedulable facts from $facts" ;;
        metadata)
            [[ -f "$nd/facts.received" ]] || die "inspect --from-metadata: node '$node' has not reported facts yet (no POST to the metadata service). Boot the probe (--boot) or run metadata-serve.sh + the probe."
            info "recorded facts the probe POSTed to the metadata service" ;;
        boot)
            # REAL introspection: PXE-boot the probe; it POSTs facts to the metadata
            # service and powers off. Needs a live BMC + metadata-serve.sh + the probe
            # image on the PXE net → AUTHOR-RUN.
            rm -f "$nd/facts.received"
            _write_probe_ipxe "$node" "$md_url"
            bmc "$node" bootdev pxe >/dev/null 2>&1 || die "inspect --boot: could not set bootdev pxe (is the BMC up?)"
            bmc "$node" power on    >/dev/null 2>&1 || die "inspect --boot: could not power on the node"
            info "booted inspection probe on '$node'; awaiting facts (timeout ${timeout}s)…"
            local waited=0
            while [[ ! -f "$nd/facts.received" ]]; do
                sleep 2; waited=$((waited+2))
                [[ $waited -ge $timeout ]] && { bmc "$node" power off >/dev/null 2>&1 || true; die "inspect --boot: timed out after ${timeout}s with no facts from '$node'.
The boot script was written, so the question is which link of the chain broke. In order:
  1. did the node fetch OUR script?   the console log ($(_read "$node" console "$nd/console.log"))
     shows the iPXE chain; 'no boot script for this node' means the PXE network is still
     serving a baked payload — run ./netboot-chain.sh install
  2. did the probe boot?              the console shows the kernel and 'maas-probe' output
  3. could it reach the sink?         metadata-serve.sh must be bound to an address the
     NODE can route to (the PXE network's gateway), not to localhost"; }
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
        # Mid-deploy, the durable (driver,image) pair still names the PREVIOUS
        # deployment — it is only written when a gate passes. The in-flight driver
        # lives in the transient `deploying_driver`, so a watch during a deploy
        # renders the profile of what is actually booting, not what last ran.
        [[ "$(read_state "$node")" == deploying ]] && drv="$(_read "$node" deploying_driver "$drv")"
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
    # Declare the verbs the panel may drive this node with. The control pane does not
    # know what any of them mean — MAAS owns the argv, the panel just runs it. That is
    # what keeps §5b's invariant true: delete Phase 6 and these exact commands still
    # work in a shell, because they ARE the shell commands.
    #
    # `apply` is deliberately FIRST and marked `reconciling`. A panel of imperative
    # buttons is a remote control; a panel with a reconcile button converges the fleet
    # and is safe to press twice — which matters far more on a surface where a key can
    # repeat than on a command line where the whole thing is typed out.
    { printf 'profile = "%s"\n' "$profile"
      printf 'console = "%s"\n' "$console"
      printf 'milestones = "%s"\n' "$MAAS_MILESTONES"
      printf '\n[[action]]\nkey = "a"\nlabel = "Reconcile (apply)"\nreconciling = true\nargv = ["%s", "apply"]\n' "$MAAS_SELF"
      printf '\n[[action]]\nkey = "h"\nlabel = "Re-check health"\nargv = ["%s", "recheck", "%s"]\n' "$MAAS_SELF" "$node"
      printf '\n[[action]]\nkey = "i"\nlabel = "Show node"\nargv = ["%s", "show", "%s"]\n' "$MAAS_SELF" "$node"
      printf '\n[[action]]\nkey = "b"\nlabel = "Abort (unstick a transition)"\nargv = ["%s", "abort", "%s"]\n' "$MAAS_SELF" "$node"
      printf '\n[[action]]\nkey = "R"\nlabel = "Release (wipes + returns to the pool)"\ndestructive = true\nargv = ["%s", "release", "%s"]\n' "$MAAS_SELF" "$node"; } > "$fleet/$node/node.toml"
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
    # OWNERSHIP FIRST. `describe <image>` is the contract's question "is this image
    # yours?", and until now nobody asked it — so an A/B rollback handed the INSTALL
    # driver a RAM payload, which netbooted a live node and then waited 30 minutes for
    # an installer that did not exist to power it off. F2 could not catch that: the
    # image was correctly signed, it was simply the wrong driver's image.
    # Keep the driver's own FIRST line, for the same reason the verify branch below
    # keeps its last: "no disk.raw", "that is the ramdisk driver's RAM payload" and "no
    # expected PCR policy" are three different operator problems, and collapsing them
    # into "it does not own it" throws away the sentence that says what to do next.
    # (The drivers put the action on line one precisely because this forwards it.)
    local derr
    if ! derr="$(run_driver "$drv" describe "$image" 2>&1 >/dev/null)"; then
        GATE_REASON="driver '$(basename "$drv" .sh)' will not claim image '$image' — it does not own it, so it must not deploy it${derr:+ — ${derr%%$'\n'*}}"
        return 1
    fi
    if [[ "$do_verify" == 1 ]]; then
        # Keep the driver's own last line: "no such image dir" and "signature did
        # not verify" are different operator problems, and swallowing stderr here
        # once reported a missing images dir as a signature failure.
        local verr
        if ! verr="$(run_driver "$drv" verify "$image" 2>&1 >/dev/null)"; then
            GATE_REASON="F2 signature verification failed for image '$image'${verr:+ — ${verr##*$'\n'}}"
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
    local node="" driver="" image="" do_verify=1 region=""
    node="${1:?usage: deploy <node> --driver D --image I [--region R] [--no-verify]}"; shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --driver)    driver="$2"; shift 2 ;;
            --image)     image="$2"; shift 2 ;;
            --no-verify) do_verify=0; shift ;;
            --region)    region="$2"; shift 2 ;;
            *) die "deploy: unknown option '$1'" ;;
        esac
    done
    require_node "$node"
    require_state "$node" deploy available active
    [[ -n "$driver" ]] || die "deploy: --driver is required (install|ramdisk|image|image+measured)"
    [[ -n "$image" ]]  || die "deploy: --image is required (the payload to deploy)"

    # Resolve the driver script. The CLI name and the FILENAME are not the same
    # string: the documented driver is `image+measured` and the file is
    # drivers/image-measured.sh, because `+` in a filename is a nuisance. So the
    # lookup normalises `+` to `-`.
    #
    # THE BUG THIS FIXES, and how it hid. Without the normalisation, `--driver
    # image+measured` resolved to drivers/image+measured.sh, which does not exist,
    # and fell through to a `die` announcing the driver was "a documented fast-follow
    # (not yet implemented)" — a sentence that stopped being true weeks earlier. It
    # survived because tests/test-image-measured-driver.sh invokes the driver as
    # `image-measured` (the filename), while run-e2e-measured.sh, README.md,
    # DEFERRED.md and MANUAL_TESTING.md all say `image+measured`. The suite was green
    # on a name no operator would ever type. Found on the metal, 2026-07-29, after
    # the node had already measured, signed and delivered a quote — the control plane
    # refused the deploy by NAME before any gate ran.
    local drv; drv="$(driver_path "$driver")"
    if [[ ! -x "$drv" ]]; then
        local avail
        avail="$(cd "$MAAS_DRIVER_DIR" 2>/dev/null && ls -1 *.sh 2>/dev/null \
                 | sed 's/\.sh$//' | grep -v '^verify-lib$' | tr '\n' ' ')"
        die "deploy: no driver '$driver' (looked for $drv).
  Available: ${avail:-none found in $MAAS_DRIVER_DIR}
  Note '+' in a driver name maps to '-' in the filename (image+measured -> image-measured.sh)."
    fi

    # The rollback candidate is a PAIR, not an image. An image is only deployable by the
    # driver that put it there, so capture BOTH before overwriting the driver field —
    # rolling `micro-linux-x86_64` back through the `install` driver is not a rollback,
    # it is a different (and much slower) way to break the node.
    local prev prev_drv
    prev="$(_read "$node" image "")"             # current image  -> rollback candidate
    prev_drv="$(_read "$node" driver "")"        # the driver that PUT it there
    # THE PAIR IS ONLY EVER WRITTEN WHEN A GATE PASSES. `driver` used to be
    # overwritten here, pre-gate — so every FAILED deploy left it paired with the
    # old `image`, and the next success captured that mismatch as its rollback
    # pair (live: `previous: install/micro-linux-x86_64`, a pair that never
    # existed). The in-flight driver lives in the transient `deploying_driver`,
    # which is what `watch` renders while state is `deploying`; it is removed on
    # every exit path below.
    _write "$node" deploying_driver "$driver"
    # A node deployed INTO a region is not `active` until it has joined it (fast-follow:
    # ramdisk -> resilient region). Recorded before the gate so the driver can see it.
    [[ -n "$region" ]] && _write "$node" region "$region"
    # Entering a deploy consumes the demoted-by-recheck marker: if THIS deploy
    # fails, the resulting `error` is a failed-deploy hold — an unproven image a
    # human should look at — not a health demotion the reconcile loop may retry.
    # Without this line a crash-looping image would be self-healed forever.
    rm -f "$(node_dir "$node")/demoted_by_recheck" 2>/dev/null || true
    set_state "$node" deploying deploy
    info "deploying image '$image' via '$driver' (verify=$do_verify, health timeout ${MAAS_HEALTH_TIMEOUT}s)…"

    if gate "$drv" "$node" "$image" current "$do_verify"; then
        _write "$node" driver "$driver"          # the pair, written together, gate passed
        _write "$node" image "$image"
        if [[ -n "$prev" && "$prev" != "$image" ]]; then
            _write "$node" previous_image "$prev"
            _write "$node" previous_driver "$prev_drv"   # the pair, or it is not a rollback
        fi
        rm -f "$(node_dir "$node")/deploying_driver" 2>/dev/null || true
        set_state "$node" active deploy
        printf 'active %s (driver=%s image=%s, healthy)\n' "$node" "$driver" "$image" >&2
        return 0
    fi

    # New image failed (bad signature OR bad health) — A/B rollback to previous.
    warn "$GATE_REASON"
    if [[ -n "$prev" && "$prev" != "$image" ]]; then
        # Through the PREVIOUS driver. Reusing $drv here was a real bug: an `install`
        # deploy that failed rolled its predecessor's RAM image back through the
        # installer, which netbooted the node and blocked 30 minutes waiting for a
        # non-existent installer to power it off — while the registry recorded the
        # impossible pair `driver=install image=micro-linux-x86_64`.
        local prev_drv_path=""
        [[ -n "$prev_drv" ]] && prev_drv_path="$(driver_path "$prev_drv")"
        if [[ -z "$prev_drv" || ! -x "$prev_drv_path" ]]; then
            # Refusing to roll back beats rolling back WRONG. A node left on the failed
            # image is honestly broken and says so; one driven by a driver that does not
            # own its image is a machine nobody can reason about.
            rm -f "$(node_dir "$node")/deploying_driver" 2>/dev/null || true
            _write "$node" error_reason "deploy of '$driver/$image' failed (${GATE_REASON:-no reason recorded}); previous image '$prev' is not rollable-back"
            set_state "$node" error deploy
            die "'$image' failed on '$node', and its previous image '$prev' cannot be rolled
back: ${prev_drv:+no driver '$prev_drv' at $prev_drv_path}${prev_drv:-the driver that deployed it was never recorded}.
Rolling back through '$driver' instead would hand it an image it does not own. Node -> error (operator)."
        fi
        warn "rolling back '$node' to its previous image '$prev' via its own driver '$prev_drv' (§4b A/B)…"
        set_state "$node" deploying deploy
        if gate "$prev_drv_path" "$node" "$prev" previous "$do_verify"; then
            _write "$node" image "$prev"
            _write "$node" driver "$prev_drv"    # the record follows the machine back
            _write "$node" previous_image ""
            _write "$node" previous_driver ""
            rm -f "$(node_dir "$node")/deploying_driver" 2>/dev/null || true
            set_state "$node" active deploy
            warn "DEGRADED: '$node' is active on its PREVIOUS image '$prev' (new image '$image' was rejected)"
            printf 'active %s (driver=%s image=%s, DEGRADED — rolled back)\n' "$node" "$prev_drv" "$prev" >&2
            return 0
        fi
        rm -f "$(node_dir "$node")/deploying_driver" 2>/dev/null || true
        _write "$node" error_reason "deploy of '$driver/$image' failed AND the rollback to '$prev_drv/$prev' failed too"
        set_state "$node" error deploy
        die "both images failed for '$node' (new '$driver/$image' and previous '$prev_drv/$prev') — node -> error (operator)"
    fi
    rm -f "$(node_dir "$node")/deploying_driver" 2>/dev/null || true
    # RECORD WHY, every time. error_reason used to be written only by maintenance,
    # abort and recheck — never by a failed deploy — so a node that failed a deploy
    # kept displaying the reason from whatever earlier incident last wrote the file.
    # Live on 2026-07-29 node3 sat in `error` from a refused measured deploy while
    # `show` reported "interrupted live run (recovered by run-e2e-measured.sh)", the
    # text of an abort that had happened half an hour before. A stale reason is worse
    # than none: it sends the operator to the wrong incident.
    _write "$node" error_reason "deploy of '$driver/$image' failed: ${GATE_REASON:-no reason recorded}"
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
    # Restoring a node into a transient state would restore the strand it was in:
    # maintenance was the only verb that accepted `deploying`, and putting it back
    # leaves the node exactly as stuck as before, with one more hop in its history.
    if is_transient "$prior"; then
        _write "$node" error_reason "was in transient state '$prior' when placed in maintenance"
        set_state "$node" error unmaintenance
        printf 'error %s (was mid-%s before maintenance; not restored into it) — recover with: retry %s\n' \
            "$node" "$prior" "$node" >&2
        rm -f "$(node_dir "$node")/prior_state" 2>/dev/null || true
        return 0
    fi
    set_state "$node" "$prior" unmaintenance
    rm -f "$(node_dir "$node")/prior_state" 2>/dev/null || true
    printf '%s %s (out of maintenance)\n' "$prior" "$node" >&2
}

# retry — re-drive a failed node (error -> manageable via manage's verify).
cmd_retry() {
    local node="${1:?usage: retry <node>}"; require_node "$node"
    require_state "$node" retry error
    # A retry is a human looking at the node: it clears the demoted-by-recheck
    # marker and RESETS the self-heal budget. (apply's self-heal path calls this
    # too and then re-writes the incremented counter — the reset here carries the
    # operator's semantics, the rewrite there carries the loop's.)
    rm -f "$(node_dir "$node")/demoted_by_recheck" "$(node_dir "$node")/selfheal_attempts" 2>/dev/null || true
    cmd_manage "$node"
}


# TRANSIENT_STATES — the states a node passes THROUGH. If the control plane dies
# mid-transition, a node is left in one of these with no verb that accepts it: not
# broken, just unreachable by the tool that owns it. `abort` is the way out.
# (Found by chaos-run.sh, which killed maas-lab.sh mid-deploy and then had nothing
# it could do with the node. Real Ironic has the same hazard and solves it the same
# way — an explicit abort, plus a conductor that reaps stranded nodes on takeover.)
TRANSIENT_STATES="verifying deploying cleaning rescuing deleting"
is_transient() { local t; for t in $TRANSIENT_STATES; do [[ "$1" == "$t" ]] && return 0; done; return 1; }

# abort — take a node OUT of a transient state into `error`, where `retry` can pick
# it up. Records why, because "error" with no reason is only marginally better than
# stranded.
cmd_abort() {
    local node="${1:?usage: abort <node> [--reason TEXT]}"; require_node "$node"; shift || true
    local reason="aborted by the operator (was stranded mid-transition)"
    [[ "${1:-}" == --reason ]] && { reason="$2"; shift 2; }
    local cur; cur="$(read_state "$node")"
    is_transient "$cur" \
        || die "cannot 'abort' node '$node' from state '${cur:-<none>}' — abort is for a node stuck mid-transition ($TRANSIENT_STATES)"
    _write "$node" error_reason "$reason"
    set_state "$node" error abort
    printf 'error %s (aborted from %s: %s) — recover with: retry %s\n' "$node" "$cur" "$reason" "$node" >&2
}

# recheck — re-run the CURRENT driver's health check against the CURRENT image, and
# demote a node that no longer passes it. The activation gate is a one-time question;
# without this nothing ever asks it again, so a node that dies after activation keeps
# reporting `active` and everything downstream believes it. Run it from cron, or by
# hand after an incident; the continuous version is `apply` (§3a, increment 6).
#
# recheck_probe — the OBSERVATION half, with no write. `apply --dry-run` needs to know
# whether an `active` node is still healthy (a plan computed from a registry that
# disagrees with reality is a fiction) but must not CHANGE anything to find out — and it
# used to: the pre-flight called cmd_recheck, which demotes active -> error. A dry run
# that says "the plan, before anything is issued" and then issues a state transition is
# the same lie as a check that reports what it did not verify.
recheck_probe() {  # recheck_probe <node> -> 0 healthy, 1 not (never writes)
    local node="$1" driver image drv
    driver="$(_read "$node" driver "")"; image="$(_read "$node" image "")"
    [[ -n "$driver" && -n "$image" ]] || return 1
    drv="$(driver_path "$driver")"
    [[ -x "$drv" ]] || return 1
    run_driver "$drv" health "$node" "$image" >/dev/null 2>&1
}
cmd_recheck() {
    local node="${1:?usage: recheck <node>}"; require_node "$node"
    local cur; cur="$(read_state "$node")"
    [[ "$cur" == active ]] || die "cannot 'recheck' node '$node' from state '$cur' — recheck re-tests a node that claims to be active"
    local driver image drv
    driver="$(_read "$node" driver "")"; image="$(_read "$node" image "")"
    [[ -n "$driver" && -n "$image" ]] || die "node '$node' is active but records no driver/image — nothing to re-check"
    drv="$(driver_path "$driver")"
    [[ -x "$drv" ]] || die "recheck: no driver '$driver' at $drv"
    if run_driver "$drv" health "$node" "$image"; then
        printf 'active %s (driver=%s image=%s, health re-confirmed)\n' "$node" "$driver" "$image" >&2
        return 0
    fi
    _write "$node" error_reason "health re-check failed for image '$image' (it passed at activation and has since stopped)"
    # The marker that distinguishes the two roads into `error` (DEFERRED item 4): a
    # node that FAILED A DEPLOY has an unproven image and waits for a human; one
    # demoted HERE was healthy at activation and stopped later — which is the thing
    # a reconcile loop exists to repair. `apply` self-heals only the marked kind,
    # bounded; entering a deploy consumes the marker (see cmd_deploy).
    _write "$node" demoted_by_recheck 1
    set_state "$node" error recheck
    die "'$node' is NO LONGER healthy on '$image' — demoted active -> error (it passed its activation gate and has since stopped). Recover with: retry $node (or let 'apply' self-heal it, bounded)"
}


# ── apply — reconcile the fleet to its DECLARED end-state (§3a) ─────────────
# The imperative verbs drive one node by hand. `apply` is the loop every real fleet
# manager is built on: declare the end-state, diff it against what is, issue exactly
# the missing transitions, and be safe to run forever.
#
# IT DOES NOT TRUST THE REGISTRY. A reconcile loop computes its actions from the
# record — and the registry-layer chaos scenario showed the record can diverge from
# the machine silently. A node that says `active` while its payload is dead would
# otherwise SATISFY the desired state, and `apply` would converge on a dead fleet and
# report success. So the first thing it does is ground itself: every node claiming
# `active` is re-checked against its driver's own health signal, and one that no
# longer passes is demoted BEFORE the diff is computed. `--no-recheck` skips that,
# and says so loudly, because the run then means much less.
cmd_apply() {
    local spec="$MAAS_DIR/fleet.toml" dry=0 recheck=1
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)    dry=1; shift ;;
            --no-recheck) recheck=0; shift ;;
            -*) die "apply: unknown option '$1'" ;;
            *)  spec="$1"; shift ;;
        esac
    done
    [[ -r "$spec" ]] || die "apply: no fleet spec at $spec"
    local fleet_py="$MAAS_DIR/lib/fleet.py"
    [[ -r "$fleet_py" ]] || die "apply: missing $fleet_py"

    # ── phase 1: ground the registry in reality ─────────────────────────────
    local demoted=0
    local -A DRY_DEMOTED=()      # dry-run only: nodes a real run WOULD have demoted
    if [[ "$recheck" == 1 ]]; then
        local n
        while read -r n; do
            [[ -n "$n" ]] || continue
            node_exists "$n" || continue
            [[ "$(read_state "$n")" == active ]] || continue
            if [[ "$dry" == 1 ]]; then
                # Observe only. Record the would-be demotion in memory so the PLAN below
                # reflects it — a dry run that skips the write but then plans from the
                # stale registry would report "converged" for a node it has just observed
                # to be dead, which is worse than either honest alternative.
                if ! recheck_probe "$n"; then
                    warn "apply: '$n' claims active but is NOT healthy — a real run would demote it to 'error' before the diff (dry run: registry not written)"
                    DRY_DEMOTED[$n]=1
                    demoted=$((demoted+1))
                fi
            elif ! ( cmd_recheck "$n" ) >/dev/null 2>&1; then
                warn "apply: '$n' claimed active but failed its health re-check — demoted before the diff"
                demoted=$((demoted+1))
            fi
        done < <(python3 "$fleet_py" "$spec" names)
    else
        warn "apply: --no-recheck — the diff is computed from the REGISTRY ALONE. A node recorded as active but actually dead will satisfy its desired state and this run will report convergence over a fleet that is not serving."
    fi

    # ── phase 2-4, repeated to STEADY STATE ─────────────────────────────────
    # One pass moves each node one step (enrolled -> manageable -> available ->
    # active), so a single pass is not convergence. Loop until a pass issues nothing,
    # bounded: a pass that changes nothing twice is either done or stuck, and either
    # way running forever would just hide it.
    local pass=0 issued=0 failed=0 held=0 converged=0 total_issued=0
    while :; do
        pass=$((pass+1))
        [[ $pass -gt ${MAAS_APPLY_MAX_PASSES:-6} ]] && {
            warn "apply: stopped after $((pass-1)) passes without reaching steady state — something is refusing to progress; the table above shows where"
            break
        }
    _apply_pass "$spec" "$fleet_py" "$dry" "$pass"
    issued=$APPLY_ISSUED; failed=$APPLY_FAILED; held=$APPLY_HELD; converged=$APPLY_CONVERGED
    total_issued=$(( total_issued + issued ))
    [[ "$dry" == 1 ]] && break
    [[ $issued -eq 0 ]] && break
    done

    printf '\n  applied: %d transition(s) over %d pass(es), %d failed, %d converged, %d held for the operator%s\n' \
        "$total_issued" "$pass" "$failed" "$converged" "$held" \
        "$( [[ $demoted -gt 0 ]] && printf ', %d demoted by the pre-flight health re-check' "$demoted" )" >&2
    [[ $failed -eq 0 ]] || return 1
    return 0
}

# _apply_pass — ONE reconcile pass: diff the declared end-state against the registry,
# print the plan, and (unless dry) issue exactly the missing transitions. Sets
# APPLY_ISSUED / APPLY_FAILED / APPLY_HELD / APPLY_CONVERGED.
APPLY_ISSUED=0; APPLY_FAILED=0; APPLY_HELD=0; APPLY_CONVERGED=0
_apply_pass() {
    local spec="$1" fleet_py="$2" dry="$3" pass="$4"
    local -a PLAN_NODE=() PLAN_CUR=() PLAN_ACT=() PLAN_WHY=()
    local held=0 converged=0
    local name
    while read -r name; do
        [[ -n "$name" ]] || continue
        local NODE_DRIVER="" NODE_IMAGE="" NODE_BMC_PORT=""
        eval "$(python3 "$fleet_py" "$spec" get "$name")"
        local cur act why
        if ! node_exists "$name"; then
            cur="<not enrolled>"; act="enroll"; why="declared in the spec, absent from the registry"
        else
            cur="$(read_state "$name")"
            # A dry run plans against what phase 1 OBSERVED, not what the registry still
            # says — the whole point of the pre-flight re-check is that the two can differ.
            [[ -n "${DRY_DEMOTED[$name]:-}" ]] && cur="error"
            local d i; d="$(_read "$name" driver "")"; i="$(_read "$name" image "")"
            [[ "$cur" == active ]] && cur="active ($d/$i)"
            case "${cur%% *}" in
            enrolled)    act="manage";  why="BMC credentials not verified yet" ;;
            manageable)  act="provide"; why="not schedulable until it has been cleaned" ;;
            available)
                if [[ -n "$NODE_DRIVER" && -n "$NODE_IMAGE" ]]; then
                    act="deploy"; why="declared $NODE_DRIVER/$NODE_IMAGE, nothing deployed"
                else act="-"; why="no driver/image declared — left in the pool"; fi ;;
            active)
                if [[ "$d" == "$NODE_DRIVER" && "$i" == "$NODE_IMAGE" ]]; then
                    act="-"; why="converged"
                else act="deploy"; why="running $d/$i, declared $NODE_DRIVER/$NODE_IMAGE"; fi ;;
            error)
                # Two roads lead here and they are not the same thing (DEFERRED item
                # 4): a FAILED DEPLOY holds for the operator — the image is unproven
                # and a human should look. A node DEMOTED BY THE RE-CHECK was healthy
                # at activation and died afterwards, which is exactly what a
                # reconcile loop exists to repair — so heal that kind, visibly and
                # BOUNDED, or the loop can mask a node that dies after every heal.
                # A human `retry` resets the budget; the loop's own attempts spend it.
                if [[ -n "$(_read "$name" demoted_by_recheck "")" || -n "${DRY_DEMOTED[$name]:-}" ]]; then
                    local sh_n sh_max
                    sh_n="$(_read "$name" selfheal_attempts 0)"; sh_max="${MAAS_APPLY_SELFHEAL_MAX:-2}"
                    if [[ "${sh_n:-0}" -lt "$sh_max" ]]; then
                        act="retry"; why="demoted by the health re-check (healthy at activation, died after) — self-heal $((sh_n+1))/$sh_max"
                    else
                        act="!"; why="HELD in 'error' — self-heal budget spent ($sh_n/$sh_max); the operator does (retry $name — a human retry resets the budget)"
                    fi
                else
                    act="!"; why="HELD in 'error' — apply does not touch a failed deploy; the operator does (retry $name)"
                fi ;;
            maintenance)
                act="!"; why="HELD in 'maintenance' — apply does not touch it; the operator does (unmaintenance)" ;;
            *)
                if is_transient "$cur"; then
                    act="!"; why="HELD mid-transition in '$cur' — a transition is in flight, or it is stranded (abort $name)"
                else act="!"; why="HELD in unexpected state '$cur'"; fi ;;
            esac
        fi
        [[ "$act" == "-" ]] && converged=$((converged+1))
        [[ "$act" == "!" ]] && held=$((held+1))
        PLAN_NODE+=("$name"); PLAN_CUR+=("$cur"); PLAN_ACT+=("$act"); PLAN_WHY+=("$why")
    done < <(python3 "$fleet_py" "$spec" names)

    # show the plan for this pass
    printf '\n  pass %d\n  %-8s  %-26s  %-8s %s\n' "$pass" NODE CURRENT ACTION WHY >&2
    printf '  %-8s  %-26s  %-8s %s\n' "--------" "--------------------------" "--------" "---" >&2
    local k
    for k in "${!PLAN_NODE[@]}"; do
        printf '  %-8s  %-26s  %-8s %s\n' \
            "${PLAN_NODE[$k]}" "${PLAN_CUR[$k]}" "${PLAN_ACT[$k]}" "${PLAN_WHY[$k]}" >&2
    done

    local issued=0 failed=0
    # ── claims: schedule by inspected facts, not by name (fast-follow) ──────
    # A [[claim]] declares WHAT is wanted — "2 nodes with >=2 cpus and >=2G" — and the
    # scheduler picks `available` nodes whose INSPECTED facts satisfy it. That is the
    # difference between a fleet spec and an inventory: nobody has to know which
    # machine is which. Facts come from increment 2's probe; a node that was never
    # inspected has none, and is therefore not schedulable — which is correct, not a
    # bug: scheduling onto hardware you have never looked at is how you get surprises.
    local cname
    while read -r cname; do
        [[ -n "$cname" ]] || continue
        local CLAIM_COUNT=1 CLAIM_DRIVER="" CLAIM_IMAGE="" CLAIM_MIN_CPUS=0 CLAIM_MIN_MEM_MB=0 CLAIM_REGION=""
        eval "$(python3 "$fleet_py" "$spec" claim "$cname")"
        local want="${CLAIM_COUNT:-1}" got=0 cand=() nn
        local nd2
        for nd2 in "$STATE_ROOT"/*/; do
            nn="$(basename "$nd2")"
            node_exists "$nn" || continue
            local st2; st2="$(read_state "$nn")"
            # Already satisfying THIS claim? Ownership is recorded on the node, not
            # inferred from driver+image: two claims can want the same image with
            # different constraints, and counting a node deployed for one of them
            # against the other would leave the second silently under-filled while
            # both report satisfied.
            if [[ "$st2" == active && "$(_read "$nn" claim "")" == "$cname" ]]; then
                got=$((got+1)); continue
            fi
            [[ "$st2" == available ]] || continue
            local cpus mem
            cpus="$(_read "$nn" cpus 0)"; mem="$(_read "$nn" mem_mb 0)"
            [[ "${cpus:-0}" -ge "${CLAIM_MIN_CPUS:-0}" ]] || continue
            [[ "${mem:-0}"  -ge "${CLAIM_MIN_MEM_MB:-0}" ]] || continue
            cand+=("$nn")
        done
        local short=$(( want - got ))
        if [[ $short -le 0 ]]; then
            printf '  claim %-10s satisfied (%d/%d)\n' "$cname" "$got" "$want" >&2
            continue
        fi
        if [[ ${#cand[@]} -eq 0 ]]; then
            printf '  claim %-10s UNSATISFIABLE: want %d more with cpus>=%s mem_mb>=%s, and no `available` node has facts that qualify (inspect one first)\n' \
                "$cname" "$short" "${CLAIM_MIN_CPUS:-0}" "${CLAIM_MIN_MEM_MB:-0}" >&2
            held=$((held+1)); continue
        fi
        local picked
        for picked in "${cand[@]:0:$short}"; do
            printf '  claim %-10s -> %s (cpus=%s mem_mb=%s) deploy %s/%s\n' "$cname" "$picked" \
                "$(_read "$picked" cpus 0)" "$(_read "$picked" mem_mb 0)" "$CLAIM_DRIVER" "$CLAIM_IMAGE" >&2
            [[ "$dry" == 1 ]] && continue
            if MAAS_APPLY_LOG="${MAAS_CLAIM_LOG:-${MAAS_APPLY_LOG:-}}" \
               apply_run "claim $cname -> deploy $picked ($CLAIM_DRIVER/$CLAIM_IMAGE)" \
                     cmd_deploy "$picked" --driver "$CLAIM_DRIVER" --image "$CLAIM_IMAGE" \
                     ${CLAIM_REGION:+--region "$CLAIM_REGION"}; then
                _write "$picked" claim "$cname"      # this node now belongs to this claim
                issued=$((issued+1))
            else
                warn "apply: claim '$cname' -> deploy '$picked' failed"; failed=$((failed+1))
            fi
        done
    done < <(python3 "$fleet_py" "$spec" claims 2>/dev/null)

    # the pool: how many nodes are kept wiped + ready
    local POOL_AVAILABLE=""
    eval "$(python3 "$fleet_py" "$spec" pool 2>/dev/null)"
    if [[ -n "$POOL_AVAILABLE" ]]; then
        local have=0 nn
        for nn in "${PLAN_NODE[@]}"; do
            node_exists "$nn" && [[ "$(read_state "$nn")" == available ]] && have=$((have+1))
        done
        if [[ $have -lt $POOL_AVAILABLE ]]; then
            printf '  pool: want %s available, have %d — every node in this spec is claimed by a [[node]] entry, so the reserve cannot be filled from it\n' \
                "$POOL_AVAILABLE" "$have" >&2
        fi
    fi

    local todo=0
    for k in "${!PLAN_ACT[@]}"; do [[ "${PLAN_ACT[$k]}" == "-" || "${PLAN_ACT[$k]}" == "!" ]] || todo=$((todo+1)); done

    APPLY_HELD=$held; APPLY_CONVERGED=$converged
    if [[ "$dry" == 1 ]]; then
        printf '\n  DRY RUN: %d transition(s) would be issued, %d converged, %d held\n' \
            "$todo" "$converged" "$held" >&2
        APPLY_ISSUED=0; APPLY_FAILED=0
        return 0
    fi

    # issue exactly the missing transitions
    for k in "${!PLAN_NODE[@]}"; do
        name="${PLAN_NODE[$k]}"
        case "${PLAN_ACT[$k]}" in
        enroll)
            local NODE_BMC_PORT="" NODE_DRIVER="" NODE_IMAGE=""
            eval "$(python3 "$fleet_py" "$spec" get "$name")"
            apply_run "enroll $name" cmd_enroll "$name" --bmc-port "$NODE_BMC_PORT" \
                && issued=$((issued+1)) || { warn "apply: enroll '$name' failed"; failed=$((failed+1)); } ;;
        manage)
            apply_run "manage $name" cmd_manage "$name" \
                && issued=$((issued+1)) || { warn "apply: manage '$name' failed (BMC not answering?)"; failed=$((failed+1)); } ;;
        provide)
            if apply_run "provide $name" cmd_provide "$name"; then issued=$((issued+1))
            else warn "apply: '$name' stays in cleaning until its disk wipe is done by hand (F7) — run: provide $name --wiped"; failed=$((failed+1)); fi ;;
        deploy)
            local NODE_DRIVER="" NODE_IMAGE=""
            eval "$(python3 "$fleet_py" "$spec" get "$name")"
            apply_run "deploy $name ($NODE_DRIVER/$NODE_IMAGE)" \
                cmd_deploy "$name" --driver "$NODE_DRIVER" --image "$NODE_IMAGE" \
                && issued=$((issued+1)) || { warn "apply: deploy '$name' ($NODE_DRIVER/$NODE_IMAGE) failed"; failed=$((failed+1)); } ;;
        retry)
            # Self-heal a node the pre-flight demoted. cmd_retry resets the budget
            # (its operator semantics), so re-write the spent count AFTER it — each
            # autonomous attempt is recorded in the history, where a fleet drifting
            # into heal-loops is visible instead of quietly absorbed.
            local sh_n2 sh_max2
            sh_n2="$(_read "$name" selfheal_attempts 0)"; sh_max2="${MAAS_APPLY_SELFHEAL_MAX:-2}"
            if apply_run "self-heal $name (retry, attempt $((sh_n2+1))/$sh_max2)" cmd_retry "$name"; then
                _write "$name" selfheal_attempts "$((sh_n2+1))"
                printf '%s  %-11s -> %-11s (%s)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                    "error" "manageable" "apply self-heal $((sh_n2+1))/$sh_max2" \
                    >> "$(node_dir "$name")/history.log" 2>/dev/null || true
                issued=$((issued+1))
            else
                warn "apply: self-heal retry '$name' failed"; failed=$((failed+1))
            fi ;;
        esac
    done

    APPLY_ISSUED=$issued; APPLY_FAILED=$failed
    return 0
}

# apply_run — issue ONE transition and never swallow what the tool said.
#
# Every branch below used to be `( cmd_x … ) >/dev/null 2>&1` and then paraphrase the
# failure ("deploy 'node1' failed — see its state"). Two costs, both paid live: a deploy
# that blocked for 30 minutes produced ZERO bytes and read as a hang, and when it finally
# failed the reason was in the driver's output, which had been discarded.
#
# The per-node table is still the point, so success stays quiet. What changes: a line
# announcing the transition BEFORE it runs (so a long one is visibly in progress, not
# hung), and on failure the tool's own words, indented, instead of a paraphrase of them.
# MAAS_APPLY_LOG, when set, additionally keeps every transition's output — the run log a
# live driver can point at.
apply_run() {  # apply_run <what> <cmd...>  -> 0 ok, 1 failed (output already reported)
    local what="$1"; shift
    local out; out="$(mktemp "${TMPDIR:-/tmp}/maas-apply.XXXXXX")" || return 1
    printf '  -> %s…\n' "$what" >&2
    local rc=0
    ( "$@" ) >"$out" 2>&1 || rc=$?
    [[ -n "${MAAS_APPLY_LOG:-}" ]] && cat "$out" >> "$MAAS_APPLY_LOG"
    if [[ $rc -ne 0 ]]; then
        # The tool already explained itself. Reprint that verbatim rather than inventing
        # a shorter, vaguer sentence about it.
        sed 's/^/       /' "$out" >&2
    fi
    rm -f "$out"
    return $rc
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

# set-console / set-mac — record the node's PLUMBING, not its lifecycle.
#
# Both are things the control plane cannot discover for itself and must be told once,
# when the machine is cabled up (here: when create-fleet.sh defines the domain). They
# are separate narrow verbs rather than a generic "set any field" because everything
# else in a node's record is written by a state transition, and a verb that can
# overwrite `state` from the command line would make the state machine advisory.
cmd_set_console() {
    local node="${1:?usage: set-console <node> <path>}" path="${2:?usage: set-console <node> <path>}"
    require_node "$node"
    _write "$node" console "$path"
    printf 'console for %s: %s\n' "$node" "$path" >&2
    [[ -e "$path" ]] || warn "note: $path does not exist yet — the health gates will wait for it"
}

cmd_set_mac() {
    local node="${1:?usage: set-mac <node> <mac>}" mac="${2:?usage: set-mac <node> <mac>}"
    require_node "$node"
    [[ "$mac" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]] \
        || die "set-mac: '$mac' is not a MAC address (aa:bb:cc:dd:ee:ff)"
    _write "$node" mac "$mac"
    printf 'mac for %s: %s\n' "$node" "$mac" >&2
}

# set-firmware — correct what `enroll` could only GUESS.
#
# FOUND LIVE 2026-07-29: the registry said `firmware bios` for a node whose domain XML
# said `<os firmware='efi'>`. `enroll --firmware` defaults to bios and nothing ever
# revisited it, while the fleet builder converted the node to UEFI+TPM AFTERWARDS (see
# create-fleet.sh's give_tpm -> lib/tpm_xml.py) and had no way to say so. A record that
# outlived the thing it described — the class CLAUDE.md names.
#
# The control plane cannot derive this itself and must not try: it reaches a node only
# through the BMC and its console, never the hypervisor (install.sh's header), because a
# machine in a rack has no `virsh`. So whoever CHANGES the machine's firmware reports it
# here, the same way reserve_dhcp reports the MAC it found.
cmd_set_firmware() {
    local node="${1:?usage: set-firmware <node> bios|uefi}" fw="${2:?usage: set-firmware <node> bios|uefi}"
    require_node "$node"
    [[ "$fw" == bios || "$fw" == uefi ]] \
        || die "set-firmware: '$fw' is not a firmware mode (bios|uefi)"
    local was; was="$(_read "$node" firmware -)"
    _write "$node" firmware "$fw"
    if [[ "$was" != "$fw" ]]; then
        printf 'firmware for %s: %s (was %s)\n' "$node" "$fw" "$was" >&2
    else
        printf 'firmware for %s: %s\n' "$node" "$fw" >&2
    fi
}

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
    # driver AND image, on both slots: the rollback candidate is a PAIR, and a `show`
    # that prints only the images hides exactly the mismatch that broke a live run.
    printf 'image       %s/%s (previous: %s/%s)\n' \
        "$(_read "$node" driver -)" "$(_read "$node" image -)" \
        "$(_read "$node" previous_driver -)" "$(_read "$node" previous_image -)"
    printf 'schedulable %s\n' "$(_read "$node" schedulable -)"
    printf 'mac         %s\n' "$(_read "$node" mac -)"
    # The console is where every health gate looks, so show whether it is actually
    # being written. "recorded but empty" is a distinct and very common failure —
    # the path is configured and nothing is filling it — and it deserves to be
    # visible here rather than inferred from a downstream timeout.
    local con; con="$(_read "$node" console "$d/console.log")"
    if   [[ ! -e "$con" ]]; then printf 'console     %s (ABSENT — nothing is logging this node)\n' "$con"
    elif [[ ! -s "$con" ]]; then printf 'console     %s (empty — recorded, but nothing has written to it)\n' "$con"
    else printf 'console     %s (%s bytes)\n' "$con" "$(wc -c <"$con" 2>/dev/null | tr -d ' ')"
    fi
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
  inspect <node> {--facts F|--from-metadata|--boot [--md-url URL]}   manageable (+facts)
  set-console <node> <path>    record where this node's serial console is logged
  set-mac <node> <mac>         record the node's PXE MAC
  set-firmware <node> bios|uefi  record the firmware the machine ACTUALLY has
  provide <node> [--wiped]               manageable -> available (via cleaning/wipe)
  deploy <node> --driver D [--image I] [--region R]   available -> active (install|ramdisk|image|image+measured)
  rescue <node> / unrescue <node>        active <-> rescue
  release <node> [--wiped]               active|rescue -> available (via cleaning)
  maintenance <node> / unmaintenance <node>   any <-> maintenance
  retry <node>                           error -> manageable
  abort <node> [--reason TEXT]           <transient> -> error (unstick a node the control plane died mid-transition on)
  recheck <node>                         active -> error if it is no longer healthy (the gate is one-time; this asks again)
  apply [FLEET.toml] [--dry-run]         reconcile the fleet to its declared end-state (idempotent; re-checks health FIRST)

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
        abort)         cmd_abort "$@" ;;
        recheck)       cmd_recheck "$@" ;;
        apply)         cmd_apply "$@" ;;
        power)         cmd_power "$@" ;;
        bootdev)       cmd_bootdev "$@" ;;
        console|sol)   cmd_console "$@" ;;
        watch)         cmd_watch "$@" ;;
        state)         cmd_state "$@" ;;
        set-console)   cmd_set_console "$@" ;;
        set-mac)       cmd_set_mac "$@" ;;
        set-firmware)  cmd_set_firmware "$@" ;;
        show)          cmd_show "$@" ;;
        list)          cmd_list "$@" ;;
        _state-root)   printf '%s\n' "$STATE_ROOT" ;;   # internal: metadata-serve.sh
        # internal: run-e2e.sh, build-verifying-rom.sh, tests. THE one answer to
        # "where is the signed-image store" — the wrappers used to each default
        # this path themselves, run-e2e.sh picked ~/.cache, and the same deploy
        # verb then read different stores depending on which script ran it (a
        # live `apply` failed F2 against an images dir that did not exist).
        _images-dir)   printf '%s\n' "$MAAS_IMAGES_DIR" ;;
        ""|-h|--help|help) usage ;;
        *) die "unknown verb '$verb' (try: maas-lab.sh --help)" ;;
    esac
}
main "$@"
