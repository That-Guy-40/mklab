#!/usr/bin/env bash
# micro-cloud-preflight.sh — MICRO-CLOUD assumption preflight (P1: unprivileged half).
#
#   usage:  tools/micro-cloud-preflight.sh          # from anywhere; REPO= to override
#   exits:  0 = no unexpected slice-1 blockers · 1 = a blocker, OR no XFAIL fired
#
# PROVISIONAL HOME. This lives in tools/ so the instrument that produced
# MICRO_CLOUD_LAB_PLAN.md's Appendix A survives the session that wrote it — a
# measurement whose harness is gone cannot be re-run, and an un-re-runnable
# measurement silently becomes a belief again. Where it ENDS UP is deliberately still
# open (that plan's §17.4 question 6): it may stay here, become
# examples/micro-cloud/tests/test-assumptions.sh so drift is caught, or seed
# `lab-fc.sh preflight` (§5.9) whose host-capability gates are mostly these checks.
# The third is probably right, but only at slice 4 — before then there is no tool for
# it to be part of. Until that is decided, treat this as a spike that was kept, not
# as shipped tooling.
#
# WHY THIS EXISTS. MICRO_CLOUD_LAB_PLAN v1 shipped four "honest constraints" that were
# false, and they were load-bearing — they shaped the verification strategy, the
# --dry-run-everything design, and the refusal to build a hand-walk. The cost of a false
# premise is a slice's worth of work built on top of it. So: apply the preflight rule
# (refuse before the irreversible step) to the PLAN, before slice 1 depends on any of it.
#
# THREE RULES, all learned the hard way in this repo:
#   1. UNKNOWN is a verdict, distinct from PASS. "I could not check this" must never read
#      as "this is fine" — that is the stale-record failure in miniature.
#   2. Each check asserts an OUTCOME, not a mechanism. `command -v firecracker` is not
#      "Firecracker works"; opening /dev/kvm is not "KVM can create a VM" (ioctl needed).
#   3. It MUST contain assumptions expected to FAIL. A preflight that reports all-PASS is
#      indistinguishable from one that checks nothing. The expected-FAIL rows are this
#      script's own negative control.
#
# Unprivileged: no sudo, no downloads, no writes outside a mktemp dir. P2 covers the
# privileged/fetch half (nft ownership, debootstrap, tap create/delete, the FC binary).
set -uo pipefail

REPO="${REPO:-/media/sqs/COLD_STORAGE/LAB_CREATE_V2}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass_n=0 fail_n=0 unk_n=0 expected_fail_n=0
ROWS=()

# row <verdict> <plan-§> <blocks-slice-1?> <assumption> <evidence>
row() {
    local v="$1" sec="$2" blocks="$3" what="$4" ev="$5"
    case "$v" in
        PASS)    pass_n=$((pass_n+1)) ;;
        FAIL)    fail_n=$((fail_n+1)) ;;
        XFAIL)   expected_fail_n=$((expected_fail_n+1)) ;;   # expected to fail = the control
        UNKNOWN) unk_n=$((unk_n+1)) ;;
    esac
    ROWS+=("$(printf '%-7s|%-8s|%-3s|%-46s|%s' "$v" "$sec" "$blocks" "$what" "$ev")")
}

hr() { printf '%s\n' "────────────────────────────────────────────────────────────────────────────────────────────────────────────────"; }

# ══ 1. Virtualization — the outcome is "KVM can create a VM", not "the file exists" ══
if out="$(python3 - <<'PY' 2>&1
import fcntl, os
KVM_GET_API_VERSION, KVM_CREATE_VM = 0xAE00, 0xAE01
fd = os.open('/dev/kvm', os.O_RDWR)
ver = fcntl.ioctl(fd, KVM_GET_API_VERSION, 0)
vm  = fcntl.ioctl(fd, KVM_CREATE_VM, 0)     # 0 = default machine type
print(f"api={ver} vm_fd={vm}")
os.close(vm); os.close(fd)
PY
)"; then
    row PASS "§10" yes "KVM can actually CREATE a VM (ioctl, not just open)" "$out"
else
    row FAIL "§10" yes "KVM can actually CREATE a VM (ioctl, not just open)" "$out"
fi

if [[ -c /dev/vhost-vsock ]]; then
    row PASS "§5.2,C" no "vsock available for a no-network guest agent" "/dev/vhost-vsock is a char device"
else
    row UNKNOWN "§5.2,C" no "vsock available for a no-network guest agent" "/dev/vhost-vsock absent — modprobe vhost_vsock needs root (P2)"
fi

# The hand-walk vehicle §12 depends on: can a CONTAINER use /dev/kvm?
if command -v podman >/dev/null; then
    if out="$(timeout 90 podman run --rm --device /dev/kvm --pull=missing \
                docker.io/library/alpine:latest sh -c 'test -c /dev/kvm && echo kvm-visible' 2>&1)"; then
        row PASS "§12" no "a container can use --device /dev/kvm (hand-walk vehicle)" "${out##*$'\n'}"
    else
        row FAIL "§12" no "a container can use --device /dev/kvm (hand-walk vehicle)" "${out##*$'\n'}"
    fi
else
    row UNKNOWN "§12" no "a container can use --device /dev/kvm (hand-walk vehicle)" "podman absent"
fi

# ══ 2. The chroot-as-universal-userspace MATRIX (the user's non-negotiable) ══
# Each cell: does a chroot → <consumer> path exist in the repo TODAY?
matrix_cell() {  # matrix_cell <label> <file> <regex> <section>
    local label="$1" file="$2" re="$3" sec="$4"
    if [[ -f "$REPO/$file" ]] && grep -qE "$re" "$REPO/$file"; then
        row PASS "$sec" no "matrix: chroot → $label" "$file matches /$re/"
    else
        row FAIL "$sec" no "matrix: chroot → $label" "no /$re/ in $file"
    fi
}
matrix_cell "OCI container (tarball)"  phase1-chroot/lab-chroot.sh 'export-tarball\)'  "§2"
matrix_cell "netboot RAM (initrd)"     phase1-chroot/lab-chroot.sh 'export-initrd\)'   "§2"
matrix_cell "QEMU bootable disk"       phase2-qemu-vm/lab-vm.sh    'from-chroot\)'      "§2"
matrix_cell "LXD/Incus system ctr"     phase5-lxd/lab-lxd.sh       'from-tarball'       "§2"

# The MISSING cell — expected to fail; it is what §6 exists to build.
if grep -qE 'export-rootfs\)' "$REPO/phase1-chroot/lab-chroot.sh" 2>/dev/null; then
    row PASS "§6" yes "matrix: chroot → Firecracker raw ext4" "export-rootfs already exists"
else
    row XFAIL "§6" yes "matrix: chroot → Firecracker raw ext4" "EXPECTED GAP — export-rootfs is what §6 builds"
fi

# The technique §6.2 depends on: populate a filesystem with NO mount, NO privilege.
mkdir -p "$WORK/tree/etc" "$WORK/tree/sbin"
echo "microcloud-p1" > "$WORK/tree/etc/hostname"
: > "$WORK/tree/sbin/init"
if truncate -s 16M "$WORK/img.ext4" 2>/dev/null \
   && mkfs.ext4 -q -F -L p1test -d "$WORK/tree" "$WORK/img.ext4" >/dev/null 2>&1 \
   && readback="$(debugfs -R "cat /etc/hostname" "$WORK/img.ext4" 2>/dev/null | tr -d '\0\n')" \
   && [[ "$readback" == "microcloud-p1" ]]; then
    row PASS "§6.2" yes "mkfs.ext4 -d populates a fs with no mount, no root" "debugfs read back '$readback'"
else
    row FAIL "§6.2" yes "mkfs.ext4 -d populates a fs with no mount, no root" "round-trip failed (readback='${readback:-}')"
fi

# ══ 3. The REVERSE matrix — the user's backup/preserve requirement ══
rev_cell() {  # rev_cell <label> <file> <regex>
    local label="$1" file="$2" re="$3"
    if [[ -f "$REPO/$file" ]] && grep -qE "$re" "$REPO/$file"; then
        row PASS "§new" no "preserve: $label → portable artifact" "$file has an export verb"
    else
        row XFAIL "§new" no "preserve: $label → portable artifact" "EXPECTED GAP — no export verb in $file"
    fi
}
rev_cell "podman container" phase4-podman/lab-podman.sh '^\s+export\)'
rev_cell "docker container" phase3-docker/lab-docker.sh '^\s+export(-tarball)?\)'
rev_cell "LXD instance"     phase5-lxd/lab-lxd.sh       '^\s+export\)'
rev_cell "QEMU VM"          phase2-qemu-vm/lab-vm.sh    '^\s+export\)'

# ══ 4. Kernel sourcing (§6.3) ══
if grep -qE 'x86_64\)\s+echo arch/x86/boot/bzImage' "$REPO/micro-linux/mlbuild.sh" 2>/dev/null; then
    row XFAIL "§6.3b" no "mlbuild.sh can emit vmlinux for x86_64" "EXPECTED GAP — returns bzImage today; ppc64le precedent returns vmlinux"
else
    row UNKNOWN "§6.3b" no "mlbuild.sh can emit vmlinux for x86_64" "kernel_image() shape changed — re-read it"
fi

if command -v extract-vmlinux >/dev/null 2>&1 || [[ -f /usr/src/linux/scripts/extract-vmlinux ]]; then
    row PASS "§6.3c" no "extract-vmlinux available to try on a distro bzImage" "found on PATH or in /usr/src"
else
    row UNKNOWN "§6.3c" no "extract-vmlinux available to try on a distro bzImage" "not on PATH; it ships in the kernel source tree (decision B stays an experiment)"
fi

# Release assets: check what v1.16.1 actually publishes. HEAD only — no download.
if assets="$(curl -s -m 15 https://api.github.com/repos/firecracker-microvm/firecracker/releases/tags/v1.16.1 2>/dev/null \
             | python3 -c 'import sys,json
d=json.load(sys.stdin)
a=[x["name"] for x in d.get("assets",[]) if "x86_64" in x["name"]]
print(",".join(a[:3]) if a else "NONE")' 2>/dev/null)" && [[ "$assets" != NONE && -n "$assets" ]]; then
    row PASS "§4A" no "v1.16.1 publishes an x86_64 asset to pin" "$assets"
else
    row UNKNOWN "§4A" no "v1.16.1 publishes an x86_64 asset to pin" "could not enumerate assets (egress or API shape)"
fi

row UNKNOWN "§6.3a" no "FC CI *kernel* artifact URL" "NOT PINNED — I will not guess a bucket path and report a verdict on it (slice 1 decides)"

# ══ 5. Network fabric (§7) ══
if ip -4 route show 2>/dev/null | grep -qE '(^|\s)10\.71\.0\.0/24'; then
    row FAIL "§7" no "10.71.0.0/24 is unclaimed on this host" "a route already claims it"
else
    row PASS "§7" no "10.71.0.0/24 is unclaimed on this host" "no route, no bridge claims it"
fi

fwd="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo '?')"
if [[ "$fwd" == 1 ]]; then
    row FAIL "§7" no "ip_forward is ours to set AND to revert" "ALREADY 1 — teardown must not revert what it did not set"
else
    row PASS "§7" no "ip_forward is ours to set AND to revert" "currently $fwd"
fi

calico="$(pgrep -c -x calico-node 2>/dev/null || echo 0)"
if [[ "$calico" -gt 0 ]]; then
    row FAIL "§7,§13" no "this host's forwarding path has no other owner" "$calico live calico-node procs; vxlan.calico over lxdbr0"
else
    row PASS "§7,§13" no "this host's forwarding path has no other owner" "no calico"
fi

row UNKNOWN "§7,§13" no "who owns the nftables ruleset" "nft list tables needs root — P2"

# ══ 6. The four engines (§9.2) ══
for e in qemu-system-x86_64 podman docker incus lxc; do
    if command -v "$e" >/dev/null 2>&1; then
        row PASS "§9.2" no "engine reachable: $e" "$(command -v "$e")"
    else
        row UNKNOWN "§9.2" no "engine reachable: $e" "not on PATH"
    fi
done

# ══ 7. Wizards (the two-entry-points requirement) ══
if command -v uv >/dev/null && [[ -d "$REPO/phase6-tui" ]]; then
    if out="$(cd "$REPO/phase6-tui" && timeout 180 uv run --frozen pytest tests/test_wizards.py -q 2>&1)"; then
        row PASS "§8.1" no "the existing phase1-5 wizards still pass" "${out##*$'\n'}"
    else
        row FAIL "§8.1" no "the existing phase1-5 wizards still pass" "${out##*$'\n'}"
    fi
else
    row UNKNOWN "§8.1" no "the existing phase1-5 wizards still pass" "uv or phase6-tui missing"
fi

if (cd "$REPO" && git grep -qli wizard -- 'phase6b-web/*' 2>/dev/null); then
    row PASS "§8.1" no "the WEB ui has wizards too" "found wizard refs under phase6b-web/"
else
    row XFAIL "§8.1" no "the WEB ui has wizards too" "EXPECTED GAP — zero wizard refs in phase6b-web/"
fi

# ══ 8. Firecracker itself — expected absent; P2/author fetches it ══
if command -v firecracker >/dev/null 2>&1; then
    row PASS "§13" yes "the firecracker binary is installed" "$(firecracker --version 2>&1 | head -1)"
else
    row XFAIL "§13" yes "the firecracker binary is installed" "EXPECTED — author-run fetch (agent fetch+exec of prebuilt binaries is gated)"
fi

# ══ 9. NEGATIVE CONTROL: an assumption I KNOW is false ══
# If this reports PASS, the harness is not looking at the real host.
chroots="$(ls -1 "$HOME/.local/state/lab-create/chroots" 2>/dev/null | wc -l)"
if [[ "$chroots" -gt 0 ]]; then
    row PASS "§6" yes "a chroot exists to export (slice 1's input)" "$chroots tree(s) present"
else
    row XFAIL "§6" yes "a chroot exists to export (slice 1's input)" "NEGATIVE CONTROL — none; slice 1 must debootstrap one first (sudo, P2)"
fi

# ══ report ══
printf '\n  MICRO-CLOUD P1 — assumption preflight (unprivileged half)\n'
printf '  XFAIL = expected to fail; these are the harness'"'"'s own negative controls.\n\n'
printf '  %-7s %-8s %-3s %-46s %s\n' VERDICT PLAN§ SL1 ASSUMPTION EVIDENCE
hr
printf '  %s\n' "${ROWS[@]}" | sed 's/|/ /g'
hr
printf '  %d PASS   %d FAIL   %d XFAIL(expected)   %d UNKNOWN\n\n' "$pass_n" "$fail_n" "$expected_fail_n" "$unk_n"

# The verdict is about SLICE 1, not about perfection.
blockers=0
for r in "${ROWS[@]}"; do
    v="${r%%|*}"; rest="${r#*|}"; rest="${rest#*|}"; b="${rest%%|*}"
    [[ "$v" == FAIL && "${b// /}" == yes ]] && blockers=$((blockers+1))
done
if (( blockers > 0 )); then
    printf '  VERDICT: %d unexpected slice-1 BLOCKER(s) — do not start slice 1 until resolved.\n' "$blockers"
    exit 1
fi
if (( expected_fail_n == 0 )); then
    printf '  VERDICT: no XFAIL rows fired. This harness is not proving anything — every\n'
    printf '           assumption "passed", which is what a check that looks at nothing reports.\n'
    exit 1
fi
printf '  VERDICT: no unexpected slice-1 blockers. %d expected gaps fired (the controls work);\n' "$expected_fail_n"
printf '           %d UNKNOWN row(s) are honest "not checked", NOT "fine" — P2 resolves them.\n' "$unk_n"
exit 0
