#!/usr/bin/env bash
# micro-cloud-preflight-p2.sh — MICRO-CLOUD assumption preflight (P2: the privileged half).
#
#   usage:  sudo tools/micro-cloud-preflight-p2.sh
#   exits:  0 = no unexpected slice-1 blockers  ·  1 = a blocker, OR no XFAIL fired
#
# The companion to tools/micro-cloud-preflight.sh (P1), which checked everything
# reachable WITHOUT privilege and honestly left three rows UNKNOWN. This script
# resolves those three and flips the two "expected gap" rows that are merely missing
# inputs. See MICRO_CLOUD_LAB_PLAN.md §17.1; results land in Appendix A as a SECOND
# dated column — never as an edit to the first. A dated measurement's whole value is
# that it stays a record of what was true then.
#
# ── WHAT THIS TOUCHES (declared up front, because a preflight that surprises you is
#    not a preflight) ────────────────────────────────────────────────────────────────
#   READS ONLY : nftables ruleset, iptables backend, /dev/net/tun, /dev/kvm
#   CREATES    : one bridge + one tap, both named mcp2* — DELETED before this exits,
#                and their absence is asserted afterwards (that assertion is a control)
#   CREATES    : one Debian chroot (~250 MB) under the INVOKING USER's state dir,
#                built by this repo's own phase1-chroot/lab-chroot.sh. It is KEPT —
#                it is slice 1's missing input. Remove it yourself with lab-chroot.sh
#                destroy; this script never deletes a tree.
#   DOWNLOADS  : the pinned Firecracker release tarball + its published .sha256.txt,
#                into the same state dir. Kept, for the same reason.
#   NEVER      : touches br-mc0 / mklab-mc / lxdbr0 / any Calico or libvirt object,
#                changes a sysctl, or writes inside the repo.
#
# ── THE THREE RULES, inherited from P1 ──────────────────────────────────────────────
#   1. UNKNOWN is a verdict distinct from PASS. "I could not check this" must never
#      read as "this is fine" — that is the stale-record failure in miniature.
#   2. Each check asserts an OUTCOME, not a mechanism. `ip tuntap add` succeeding is
#      not "Firecracker can use a tap" — so we open the tap AS THE UNPRIVILEGED USER
#      with the same TUNSETIFF ioctl Firecracker itself issues.
#   3. It MUST contain assumptions expected to FAIL. A preflight reporting all-PASS is
#      indistinguishable from one that checks nothing, so this script exits non-zero
#      if no XFAIL fires. P2's deliberate controls: a sha256 verification run against
#      a KNOWN-WRONG digest (proving the verifier can bite), and the post-delete
#      absence assertions on the bridge and tap.
set -uo pipefail

REPO="${REPO:-/media/sqs/COLD_STORAGE/LAB_CREATE_V2}"
FC_VERSION="${FC_VERSION:-v1.16.1}"
FC_ARCH="${FC_ARCH:-x86_64}"
FC_BASE="https://github.com/firecracker-microvm/firecracker/releases/download"
CHROOT_NAME="${CHROOT_NAME:-mc-p2-trixie}"
CHROOT_SUITE="${CHROOT_SUITE:-trixie}"
BR="mcp2br0"          # deliberately NOT br-mc0 — the fabric's real name stays unused
TAP="mcp2tap0"        # deliberately NOT mc-* — same reason

# ── who is this actually for? ───────────────────────────────────────────────────────
# Under sudo, $HOME is root's. Every artifact here belongs to the INVOKING user, whose
# unprivileged tooling (and P1) look in ~/.local/state/lab-create. Getting this wrong
# would build slice 1's input somewhere slice 1 never looks.
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    printf 'FAIL: P2 is the privileged half — run it as root:\n\n    sudo %s\n\n' "$0" >&2
    exit 1
fi
TARGET_USER="${SUDO_USER:-root}"
USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$USER_HOME" && -d "$USER_HOME" ]] || { printf 'FAIL: cannot resolve home for %s\n' "$TARGET_USER" >&2; exit 1; }
USER_STATE="$USER_HOME/.local/state/lab-create"
OUT="$USER_STATE/micro-cloud-p2"
mkdir -p "$OUT"
LOG="$OUT/p2-transcript.txt"
: > "$LOG"

pass_n=0 fail_n=0 unk_n=0 expected_fail_n=0
ROWS=()
REPORTED=0

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
    printf '  %-7s %s\n' "$v" "$what"
}

say()  { printf '\n══ %s\n' "$*"; printf '\n══ %s\n' "$*" >> "$LOG"; }
note() { printf '   - %s\n' "$*"; printf '   - %s\n' "$*" >> "$LOG"; }
# Run a command, tee its output to the transcript, keep the exit status usable.
runq() { printf '\n$ %s\n' "$*" >> "$LOG"; "$@" >> "$LOG" 2>&1; }

# ── the safety net (CLAUDE.md: no test may ever exit silently) ──────────────────────
cleanup_net() {
    ip link show "$TAP" >/dev/null 2>&1 && ip link del "$TAP" >/dev/null 2>&1
    ip link show "$BR"  >/dev/null 2>&1 && ip link del "$BR"  >/dev/null 2>&1
    return 0
}
on_exit() {
    local rc=$?
    cleanup_net
    if (( REPORTED == 0 )); then
        printf '\nFAIL: P2 exited early (rc=%d) before printing its table — that is a harness\n' "$rc"
        printf '      bug, not a result. Transcript so far: %s\n' "$LOG"
    fi
}
trap on_exit EXIT

printf '\n  MICRO-CLOUD P2 — assumption preflight (privileged half)\n'
printf '  invoking user: %s   artifacts: %s\n' "$TARGET_USER" "$OUT"
printf '  full transcript: %s\n' "$LOG"

# ════════════════════════════════════════════════════════════════════════════════════
# 1. WHO OWNS THE FIREWALL  (§7.1 consequence 2 — P1 row: UNKNOWN)
#    The outcome that matters is not "nft works" but: is `mklab-mc` a free name, and
#    what is already in there that our additive table has to coexist with?
# ════════════════════════════════════════════════════════════════════════════════════
say "1/6  nftables ownership beside Calico"
if nft list tables > "$OUT/nft-tables.txt" 2>>"$LOG"; then
    nft list ruleset > "$OUT/nft-ruleset.txt" 2>>"$LOG" || true
    tbl_n=$(wc -l < "$OUT/nft-tables.txt")
    rule_n=$(grep -c . "$OUT/nft-ruleset.txt" 2>/dev/null || true)
    names=$(awk '{print $2" "$3}' "$OUT/nft-tables.txt" | paste -sd, - | cut -c1-90)
    note "$tbl_n table(s), $rule_n ruleset lines → $OUT/nft-ruleset.txt"
    note "tables: ${names:-<none>}"
    row PASS "§7.1" no "the nftables ruleset is readable and recorded" "$tbl_n tables, $rule_n lines; saved for §7's design"

    if grep -qE '(^| )mklab-mc( |$)' "$OUT/nft-tables.txt"; then
        row FAIL "§7.1" no "the name 'mklab-mc' is free for OUR table" "ALREADY EXISTS — a previous run leaked, or a name clash"
    else
        row PASS "§7.1" no "the name 'mklab-mc' is free for OUR table" "no table by that name in any family"
    fi

    # Not graded — recorded. Calico may drive iptables-nft, legacy iptables, or raw nft,
    # and which one it is changes what "additive" has to mean.
    ipt_ver="$(iptables --version 2>/dev/null | head -1)"
    ipt_n="$(iptables-save 2>/dev/null | grep -c '^-A' || true)"
    note "iptables: ${ipt_ver:-absent}; ${ipt_n} -A rules"
    { printf '\n== iptables-save ==\n'; iptables-save 2>&1; } >> "$LOG"
else
    row UNKNOWN "§7.1" no "the nftables ruleset is readable and recorded" "nft list tables failed even as root — see transcript"
    row UNKNOWN "§7.1" no "the name 'mklab-mc' is free for OUR table" "could not enumerate tables"
fi

# ════════════════════════════════════════════════════════════════════════════════════
# 2. THE TAP PRIMITIVE  (§7 — proves the fabric's atom WITHOUT building the fabric)
#    Mechanism: `ip tuntap add` returns 0.  Outcome: the unprivileged user that will
#    run Firecracker can TUNSETIFF it. Only the second one is worth asserting.
# ════════════════════════════════════════════════════════════════════════════════════
say "2/6  one tap on a throwaway bridge (created, opened as $TARGET_USER, deleted)"
if [[ ! -c /dev/net/tun ]]; then
    row FAIL "§7" yes "/dev/net/tun exists (the tap primitive at all)" "absent — modprobe tun, or the kernel lacks TUN"
elif ip link show "$BR" >/dev/null 2>&1 || ip link show "$TAP" >/dev/null 2>&1; then
    # Refuse rather than clobber: something already owns these names.
    row FAIL "§7" yes "the throwaway names $BR/$TAP are free" "one already exists — refusing to touch a device I did not create"
else
    tap_ok=1
    runq ip link add "$BR" type bridge          || tap_ok=0
    runq ip link set  "$BR" up                  || tap_ok=0
    runq ip tuntap add dev "$TAP" mode tap user "$TARGET_USER" || tap_ok=0
    runq ip link set "$TAP" master "$BR"        || tap_ok=0
    runq ip link set "$TAP" up                  || tap_ok=0

    if (( tap_ok )) && ip -d link show "$TAP" 2>>"$LOG" | grep -q "master $BR"; then
        row PASS "§7" yes "a tap can be created and enslaved to a bridge" "$TAP master $BR, both up"
    else
        row FAIL "§7" yes "a tap can be created and enslaved to a bridge" "creation or enslavement failed — see transcript"
    fi

    # THE OUTCOME. This is the exact ioctl Firecracker issues; running it as the
    # unprivileged user answers "can a non-root Firecracker attach to this tap?".
    if out="$(runuser -u "$TARGET_USER" -- python3 - "$TAP" <<'PY' 2>&1
import fcntl, os, struct, sys
TUNSETIFF, IFF_TAP, IFF_NO_PI = 0x400454ca, 0x0002, 0x1000
name = sys.argv[1].encode()
fd = os.open('/dev/net/tun', os.O_RDWR)
# ifreq is 40 bytes on x86_64; pad so the kernel's copy_from_user stays in bounds.
fcntl.ioctl(fd, TUNSETIFF, struct.pack('16sH22x', name, IFF_TAP | IFF_NO_PI))
print('TUNSETIFF-ok')
os.close(fd)
PY
    )"; then
        row PASS "§7" yes "the UNPRIVILEGED user can TUNSETIFF that tap" "${out##*$'\n'} (as $TARGET_USER — what Firecracker does)"
    else
        row FAIL "§7" yes "the UNPRIVILEGED user can TUNSETIFF that tap" "${out##*$'\n'}"
    fi

    # Delete, then ASSERT ABSENCE. §7.2: teardown is a test, not a cleanup — and this
    # assertion is a real negative control: it bites if the delete silently did nothing.
    runq ip link del "$TAP"
    runq ip link del "$BR"
    gone=1
    ip link show "$TAP" >/dev/null 2>&1 && gone=0
    ip link show "$BR"  >/dev/null 2>&1 && gone=0
    if (( gone )); then
        row PASS "§7.2" no "teardown ACTUALLY removed both devices" "neither $TAP nor $BR resolves after delete"
    else
        row FAIL "§7.2" no "teardown ACTUALLY removed both devices" "a device survived its own delete — a leaked bridge breaks the NEXT lab"
    fi
fi

# ════════════════════════════════════════════════════════════════════════════════════
# 3. A CHROOT TO EXPORT  (§2/§6 — P1's NEGATIVE CONTROL row: none existed)
#    Built with the repo's own tool, not raw debootstrap: the thing slice 1 needs is
#    not "a directory of Debian" but "a chroot this toolchain knows about", and the
#    manifest has to land in the USER's registry, which is where P1 looks.
# ════════════════════════════════════════════════════════════════════════════════════
say "3/6  one small chroot — slice 1's missing input"
TREE="$USER_STATE/trees/$CHROOT_NAME"
MANIFEST="$USER_STATE/chroots/$CHROOT_NAME.toml"
avail_mb=$(df -Pm "$USER_HOME" | awk 'NR==2{print $4}')
if [[ -f "$MANIFEST" && -d "$TREE" ]]; then
    note "already present — not rebuilding"
    build_rc=0
elif (( avail_mb < 2048 )); then
    row FAIL "§6" yes "a chroot exists to export (slice 1's input)" "only ${avail_mb} MB free on $USER_HOME — refusing to debootstrap"
    build_rc=126
else
    note "debootstrap $CHROOT_SUITE (minbase + busybox) → $TREE   [several minutes]"
    note "manifest → $MANIFEST (the USER's registry, not root's — P1 reads that one)"
    runq env LAB_STATE_DIR="$USER_STATE" "$REPO/phase1-chroot/lab-chroot.sh" create \
        --backend debootstrap --distro debian --suite "$CHROOT_SUITE" \
        --arch x86_64 --variant minbase --include busybox \
        --init-script busybox --name "$CHROOT_NAME" --target "$TREE"
    build_rc=$?
    # The manifest belongs to the user; the TREE stays root-owned (it is a rootfs).
    [[ -f "$MANIFEST" ]] && chown "$TARGET_USER" "$MANIFEST" 2>/dev/null
    chown "$TARGET_USER" "$USER_STATE" "$USER_STATE/chroots" 2>/dev/null
fi

if [[ -f "$MANIFEST" && -d "$TREE" ]]; then
    # OUTCOME, not mechanism: a directory full of files is not a chroot until
    # something EXECUTES inside it.
    if out="$(env LAB_STATE_DIR="$USER_STATE" "$REPO/phase1-chroot/lab-chroot.sh" enter "$CHROOT_NAME" \
                 -- /bin/sh -c 'echo mc-p2-executed' 2>>"$LOG")" \
       && [[ "$out" == *mc-p2-executed* ]]; then
        sz=$(du -sm "$TREE" 2>/dev/null | cut -f1)
        row PASS "§6" yes "a chroot exists AND executes (slice 1's input)" "$CHROOT_NAME, ${sz} MB — decision F's Debian datapoint"
    else
        row FAIL "§6" yes "a chroot exists AND executes (slice 1's input)" "tree built but /bin/sh would not run inside it"
    fi
else
    row FAIL "§6" yes "a chroot exists AND executes (slice 1's input)" "lab-chroot.sh create rc=$build_rc — see transcript"
fi

# ════════════════════════════════════════════════════════════════════════════════════
# 4. THE FIRECRACKER BINARY  (§13 — P1 row: XFAIL, author-run fetch)
#    Includes P2's headline negative control: verify against a KNOWN-WRONG digest and
#    confirm the check bites. An unverified verifier is not a verifier.
# ════════════════════════════════════════════════════════════════════════════════════
say "4/6  fetch + verify Firecracker $FC_VERSION"
FCDIR="$OUT/firecracker"
mkdir -p "$FCDIR"
TGZ="$FCDIR/firecracker-${FC_VERSION}-${FC_ARCH}.tgz"
SHAF="$TGZ.sha256.txt"
url="$FC_BASE/$FC_VERSION/firecracker-${FC_VERSION}-${FC_ARCH}.tgz"

fetched=1
[[ -s "$TGZ"  ]] || runq curl -fsSL -m 300 -o "$TGZ"  "$url"           || fetched=0
[[ -s "$SHAF" ]] || runq curl -fsSL -m 60  -o "$SHAF" "$url.sha256.txt" || fetched=0

if (( fetched )) && [[ -s "$TGZ" && -s "$SHAF" ]]; then
    want="$(awk '{print $1}' "$SHAF" | head -1)"
    got="$(sha256sum "$TGZ" | awk '{print $1}')"
    if [[ -n "$want" && "$want" == "$got" ]]; then
        row PASS "§4A" yes "the FC tarball matches its PUBLISHED sha256" "${got:0:16}… == upstream .sha256.txt"
    else
        row FAIL "§4A" yes "the FC tarball matches its PUBLISHED sha256" "want=${want:0:16}… got=${got:0:16}…"
    fi

    # ── NEGATIVE CONTROL ── Feed the verifier a digest that CANNOT be right and
    # require it to say so. If this "passes", the comparison above proved nothing.
    bogus="0000000000000000000000000000000000000000000000000000000000000000"
    if [[ "$got" == "$bogus" ]]; then
        row FAIL "§4A" no "CONTROL: sha verification rejects a wrong digest" "the real digest IS the bogus one — impossible; harness broken"
    else
        row XFAIL "§4A" no "CONTROL: sha verification rejects a wrong digest" "EXPECTED MISMATCH — the verifier bites, so its PASS above means something"
    fi

    runq tar -xzf "$TGZ" -C "$FCDIR"
    FCBIN="$(find "$FCDIR" -maxdepth 3 -type f -name "firecracker-${FC_VERSION}-${FC_ARCH}" | head -1)"
    JAILER="$(find "$FCDIR" -maxdepth 3 -type f -name "jailer-${FC_VERSION}-${FC_ARCH}" | head -1)"
    if [[ -n "$FCBIN" ]]; then
        chmod 0755 "$FCBIN" "${JAILER:-$FCBIN}" 2>/dev/null
        chown -R "$TARGET_USER" "$FCDIR" 2>/dev/null
        ver="$(runuser -u "$TARGET_USER" -- "$FCBIN" --version 2>&1 | head -1)"
        row PASS "§13" yes "the firecracker binary runs as $TARGET_USER" "${ver:-no output} → $FCBIN"
        note "jailer: ${JAILER:-NOT FOUND (§5.6 needs it)}"
    else
        row FAIL "§13" yes "the firecracker binary runs as $TARGET_USER" "no firecracker binary inside the tarball"
        FCBIN=""
    fi
else
    row UNKNOWN "§4A" yes "the FC tarball matches its PUBLISHED sha256" "download failed — see transcript ($url)"
    row UNKNOWN "§13" yes "the firecracker binary runs as $TARGET_USER" "nothing to run"
    FCBIN=""
fi

# ── Does it work on THIS CPU? ───────────────────────────────────────────────────────
# Firecracker's own testing skews Intel; this host is AMD-V (svm). We cannot boot a
# real guest yet (no kernel — that is slice 1), so we boot a DELIBERATELY INVALID
# kernel: a megabyte of zeros. Everything before the kernel loader must still happen —
# config parse, KVM_CREATE_VM, guest memory, vCPU setup — and then it must fail AT THE
# LOADER. Which error we get is the whole measurement:
#     loader error  → KVM path worked on AMD-V   (the thing we wanted to know)
#     KVM error     → a real problem, and slice 1 is blocked
#     anything else → UNKNOWN, honestly
if [[ -n "$FCBIN" ]]; then
    say "5/6  no-op boot on AMD-V (invalid kernel on purpose — grading the failure)"
    NOOP="$OUT/noop"
    mkdir -p "$NOOP"
    head -c 1048576 /dev/zero > "$NOOP/not-a-kernel.bin"
    cat > "$NOOP/config.json" <<JSON
{
  "boot-source": { "kernel_image_path": "$NOOP/not-a-kernel.bin", "boot_args": "console=ttyS0 reboot=k panic=1 pci=off" },
  "drives": [],
  "machine-config": { "vcpu_count": 1, "mem_size_mib": 128, "smt": false }
}
JSON
    chown -R "$TARGET_USER" "$NOOP" 2>/dev/null
    fcout="$(runuser -u "$TARGET_USER" -- timeout 30 "$FCBIN" --no-api --config-file "$NOOP/config.json" 2>&1)"
    fcrc=$?
    { printf '\n== firecracker no-op boot (rc=%d) ==\n%s\n' "$fcrc" "$fcout"; } >> "$LOG"
    tail_line="$(printf '%s' "$fcout" | grep -iE 'error|fail' | tail -1)"
    if printf '%s' "$fcout" | grep -qiE 'elf|magic|kernel.*(load|invalid)|Loader'; then
        row PASS "§13" yes "Firecracker reaches the kernel loader on AMD-V" "${tail_line:0:96}"
    elif printf '%s' "$fcout" | grep -qiE 'kvm|cpuid|vcpu|capabilit|not supported|unsupported'; then
        row FAIL "§13" yes "Firecracker reaches the kernel loader on AMD-V" "KVM-side failure: ${tail_line:0:96}"
    else
        row UNKNOWN "§13" yes "Firecracker reaches the kernel loader on AMD-V" "rc=$fcrc, unrecognised output — read $LOG and grade it by hand"
    fi
else
    row UNKNOWN "§13" yes "Firecracker reaches the kernel loader on AMD-V" "no binary to run"
fi

# ════════════════════════════════════════════════════════════════════════════════════
# 6. P1's TWO REMAINING UNKNOWNs (§6.3c, §6.3a) — not root-gated, but P2 may fetch.
# ════════════════════════════════════════════════════════════════════════════════════
say "6/6  resolving P1's remaining UNKNOWN rows"

# §6.3c — decision B. extract-vmlinux ships in the kernel SOURCE tree, so P1 could not
# find it. It is a ~30-line shell script; fetch it and RUN it on this host's own
# bzImage. "Available" was never the question — "does it produce an ELF" is.
EV="$OUT/extract-vmlinux"
if [[ ! -s "$EV" ]]; then
    runq curl -fsSL -m 60 -o "$EV" \
        "https://raw.githubusercontent.com/torvalds/linux/master/scripts/extract-vmlinux"
fi
if [[ -s "$EV" ]]; then
    chmod 0755 "$EV"
    HOSTK="/boot/vmlinuz-$(uname -r)"
    if [[ -r "$HOSTK" ]]; then
        if "$EV" "$HOSTK" > "$OUT/vmlinux-from-host-bzimage" 2>>"$LOG" \
           && [[ -s "$OUT/vmlinux-from-host-bzimage" ]] \
           && file -b "$OUT/vmlinux-from-host-bzimage" 2>/dev/null | grep -qi ELF; then
            szm=$(du -sm "$OUT/vmlinux-from-host-bzimage" | cut -f1)
            chown "$TARGET_USER" "$OUT/vmlinux-from-host-bzimage" 2>/dev/null
            row PASS "§6.3c" no "extract-vmlinux turns a distro bzImage into ELF" "${szm} MB ELF from $HOSTK — decision B is now testable"
        else
            row FAIL "§6.3c" no "extract-vmlinux turns a distro bzImage into ELF" "ran, produced no ELF — decision B leans toward a purpose-built kernel"
        fi
    else
        row UNKNOWN "§6.3c" no "extract-vmlinux turns a distro bzImage into ELF" "$HOSTK not readable"
    fi
else
    row UNKNOWN "§6.3c" no "extract-vmlinux turns a distro bzImage into ELF" "could not fetch the script"
fi

# §6.3a — P1 refused to guess a bucket path and report a verdict on it. The honest
# resolution is to ENUMERATE, not guess: ask S3 to list the prefix and read back what
# is actually there. If listing is denied, this stays UNKNOWN — that is a real answer.
S3="https://s3.amazonaws.com/spec.ccfc.min"
if listing="$(curl -fsSL -m 30 "$S3?list-type=2&prefix=firecracker-ci/&delimiter=/" 2>>"$LOG")" \
   && printf '%s' "$listing" | grep -q 'CommonPrefixes\|Contents'; then
    latest="$(printf '%s' "$listing" | grep -oE 'firecracker-ci/v[0-9.]+/' | sort -Vu | tail -1)"
    if [[ -n "$latest" ]] \
       && kl="$(curl -fsSL -m 30 "$S3?list-type=2&prefix=${latest}${FC_ARCH}/&delimiter=/" 2>>"$LOG")"; then
        # Keep the kernels, drop their .config siblings and the -no-acpi variants.
        kern="$(printf '%s' "$kl" | grep -oE "${latest}${FC_ARCH}/vmlinux[^<]*" \
                | grep -vE '\.config$|-no-acpi' | sort -Vu | tail -1)"
        printf '%s\n' "$listing" "$kl" > "$OUT/fc-ci-listing.xml"
        if [[ -n "$kern" ]]; then
            row PASS "§6.3a" no "the FC CI kernel artifact URL, ENUMERATED not guessed" "$S3/$kern"
        else
            row UNKNOWN "§6.3a" no "the FC CI kernel artifact URL, ENUMERATED not guessed" "listed $latest$FC_ARCH/ but saw no vmlinux* key"
        fi
    else
        row UNKNOWN "§6.3a" no "the FC CI kernel artifact URL, ENUMERATED not guessed" "top-level listed, per-version listing failed"
    fi
else
    row UNKNOWN "§6.3a" no "the FC CI kernel artifact URL, ENUMERATED not guessed" "bucket listing denied — STILL not guessing a path (slice 1 decides)"
fi

# ════════════════════════════════════════════════════════════════════════════════════
# report
# ════════════════════════════════════════════════════════════════════════════════════
REPORTED=1
hr() { printf '%s\n' "────────────────────────────────────────────────────────────────────────────────────────────────────────────────"; }
{
    printf '\n  MICRO-CLOUD P2 — assumption preflight (privileged half)\n'
    printf '  XFAIL = expected to fail; these are the harness'"'"'s own negative controls.\n\n'
    printf '  %-7s %-8s %-3s %-46s %s\n' VERDICT PLAN§ SL1 ASSUMPTION EVIDENCE
    hr
    printf '  %s\n' "${ROWS[@]}" | sed 's/|/ /g'
    hr
    printf '  %d PASS   %d FAIL   %d XFAIL(expected)   %d UNKNOWN\n' "$pass_n" "$fail_n" "$expected_fail_n" "$unk_n"
    printf '  artifacts: %s\n  transcript: %s\n\n' "$OUT" "$LOG"
} | tee -a "$LOG"

blockers=0
for r in "${ROWS[@]}"; do
    v="${r%%|*}"; rest="${r#*|}"; rest="${rest#*|}"; b="${rest%%|*}"
    [[ "$v" == FAIL && "${b// /}" == yes ]] && blockers=$((blockers+1))
done
if (( blockers > 0 )); then
    printf '  FAIL: %d unexpected slice-1 BLOCKER(s) — do not start slice 1 until resolved.\n\n' "$blockers" | tee -a "$LOG"
    exit 1
fi
if (( expected_fail_n == 0 )); then
    printf '  FAIL: no XFAIL row fired. The sha-verification control did not run, so the\n' | tee -a "$LOG"
    printf '        digest comparison above proves nothing — a harness that cannot fail is\n' | tee -a "$LOG"
    printf '        indistinguishable from one that checks nothing.\n\n' | tee -a "$LOG"
    exit 1
fi
printf '  PASS: no unexpected slice-1 blockers; %d control(s) fired; %d UNKNOWN row(s) remain\n' "$expected_fail_n" "$unk_n" | tee -a "$LOG"
printf '        honest "not checked" — NOT "fine". Paste %s back to record Appendix A.\n\n' "$LOG" | tee -a "$LOG"
exit 0
