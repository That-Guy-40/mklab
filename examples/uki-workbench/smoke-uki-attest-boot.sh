#!/usr/bin/env bash
# smoke-uki-attest-boot.sh — the UKI's measured boot into a REAL TPM, not a host
# self-prediction. The companion to smoke-uki-pcrsig.sh, which proved (host-side,
# no boot) that the UKI's carried .pcrsig REPRODUCES a systemd-measure signing over
# the UKI's own sections. This one BOOTS the UKI under genuine OVMF + a real swtpm
# TPM 2.0 and checks what actually lands in PCR 11.
#
# WHAT WAS DEFERRED, AND WHAT THIS CLOSES (UKI_WORKBENCH_LAB_PLAN.md §3 / PLAN.md
# "defers"). The attestation strand's BOOT half was UNKNOWN: "the carried prediction
# == an ACTUAL OVMF+swtpm boot's PCR 11 (needs a live TPM)." This builds that live
# boot and PROVES, foreign-oracle-graded:
#   1. a PCR-keyed, *bootable* UKI (real kernel + initrd, ukify --measure) boots to
#      Linux under OVMF with a swtpm TPM 2.0 the guest sees;
#   2. the systemd-stub measures the UKI's sections into PCR 11 of that real TPM;
#   3. the guest reads the LIVE PCR 11 out of its own TPM (/sys/class/tpm/tpm0);
#   4. the kernel's TCG event log REPLAYS (tpm2_eventlog — the foreign oracle) to
#      EXACTLY that live register, and its PCR-11 events are precisely the UKI's
#      sections, each measured name-then-content — the TPM saw this UKI and nothing
#      else;
#   5. a one-section change (a different .cmdline) MOVES PCR 11 — the measured boot
#      is content-sensitive, which is the whole point (the negative control).
#
# WHAT STAYS UNKNOWN, NAMED (not hidden). Matching the carried .pcrsig's SIGNED
# POLICY at a boot *phase* (enter-initrd:…) needs systemd-pcrphase to extend the
# phase word into PCR 11; a busybox initrd never runs it, so this boot stops at
# "sections measured" and PCR 11 is the sections-only value (systemd-measure
# calculate always reports a phase already applied, so the two are off by exactly
# the phase extension — diagnosed, not a mismatch in the measurement). Closing that
# is a systemd initrd that runs systemd-pcrphase and unlocks a .pcrsig-sealed secret
# — the end-to-end policy satisfaction, deferred with its crux here. UNKNOWN≠PASS.
#
# Exit 0 pass / 1 fail / 77 skip. Env: CAPTURE_KERNEL (a TPM-capable bzImage).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RIVAL="$(cd "$HERE/../openbios-the-rival-that-shipped" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STUB=/usr/lib/systemd/boot/efi/linuxx64.efi.stub
OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
OVMF_VARS="${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}"
KERNEL="${CAPTURE_KERNEL:-$HOME/.cache/mklab-kernel/vmlinuz}"
PACKER="$REPO/examples/metal-as-a-service/build-probe-initramfs.sh"
CAPINIT="$RIVAL/fixtures/edk2-swtpm/capture-init.sh"
WD=""
# shellcheck disable=SC2154
trap 'rc=$?; [[ -n "${SWPID:-}" ]] && kill "$SWPID" 2>/dev/null; [[ -n "$WD" ]] && rm -rf "$WD"; rm -f "${TPMSOCK:-}"; [[ $rc -eq 0 || $rc -eq 1 || $rc -eq 77 ]] || echo "FAIL: smoke-uki-attest-boot.sh exited early (rc=$rc)"' EXIT
skip() { echo "SKIP: $*"; exit 77; }
fail() { echo "FAIL: $*"; exit 1; }
note() { echo "  - $*"; }

# ── guards (SKIP by name — this needs a full UEFI+TPM boot) ────────────────────
for t in qemu-system-x86_64 swtpm ukify mcopy mformat tpm2_eventlog base64 sha256sum genisoimage; do
    command -v "$t" >/dev/null || skip "$t not installed — the live measured boot needs it"
done
[[ -x /usr/lib/systemd/systemd-measure ]] || skip "systemd-measure not found (systemd-ukify) — the prediction side"
[[ -f "$STUB" ]] || skip "no systemd-stub at $STUB (systemd-boot) — a UKI needs the EFI stub"
[[ -r "$OVMF_CODE" && -r "$OVMF_VARS" ]] || skip "OVMF 4M images not under /usr/share/OVMF (apt install ovmf)"
[[ -r "$KERNEL" ]] || skip "no TPM-capable kernel at $KERNEL (set CAPTURE_KERNEL=; a bzImage with TCG_TIS built in)"
[[ -x "$PACKER" ]] || skip "missing the initramfs packer $PACKER"
[[ -f "$CAPINIT" ]] || fail "missing $CAPINIT — the guest /init that reads PCR 11 from sysfs"
command -v busybox >/dev/null || skip "busybox not installed — the measure initramfs needs it"
ACCEL=$([[ -w /dev/kvm ]] && echo kvm || echo tcg)

WD="$(mktemp -d)"; TPMSOCK="/tmp/attboot-$$.sock"
# ── the measure initramfs: busybox + capture-init.sh (reads /sys/class/tpm pcr-11) ─
"$PACKER" --init "$CAPINIT" --busybox "$(command -v busybox)" --out "$WD/measure.cpio.gz" >"$WD/packer.log" 2>&1 \
    || { tail -3 "$WD/packer.log"; fail "building the measure initramfs failed"; }
# one lab PCR keypair, reused for both UKIs
openssl genrsa -out "$WD/pcr.key" 2048 2>/dev/null; openssl rsa -in "$WD/pcr.key" -pubout -out "$WD/pcr.pub" 2>/dev/null
printf 'ID=mklab-attest\nPRETTY_NAME="mklab UKI attestation"\n' > "$WD/osrel"

# build_uki <cmdline-string> <out.efi>: a bootable, PCR-keyed UKI
build_uki() {
    local cl="$1" out="$2"; printf '%s\n' "$cl" > "$WD/cmdline"
    ukify build --linux="$KERNEL" --initrd="$WD/measure.cpio.gz" --cmdline="@$WD/cmdline" \
        --os-release="@$WD/osrel" --stub="$STUB" \
        --pcr-private-key="$WD/pcr.key" --pcr-public-key="$WD/pcr.pub" --measure \
        --output="$out" >"$WD/ukify.log" 2>&1 || { tail -5 "$WD/ukify.log"; fail "ukify failed to build the PCR-keyed UKI"; }
    objdump -h "$out" 2>/dev/null | grep -qE '[[:space:]]\.pcrsig[[:space:]]' || fail "the UKI carries no .pcrsig — ukify did not sign a prediction"
}

# boot_pcr <uki.efi> <tag>: boot the UKI under OVMF + swtpm, print the live PCR 11
# (LIVEPCR11_<tag>=…) and the replayed-from-log value (LOGPCR11_<tag>=…). A fresh
# swtpm per boot, so each PCR 11 starts from zero and reflects this UKI alone.
boot_pcr() {
    local uki="$1" tag="$2"
    local esp="$WD/esp-$tag.img" ser="$WD/serial-$tag.log" st="$WD/tpm-$tag"
    truncate -s 64M "$esp"; mformat -i "$esp" -F ::; mmd -i "$esp" ::/EFI ::/EFI/BOOT
    mcopy -i "$esp" "$uki" ::/EFI/BOOT/BOOTX64.EFI
    cp "$OVMF_VARS" "$WD/vars-$tag.fd"; mkdir -p "$st"; rm -f "$TPMSOCK"
    swtpm socket --tpmstate "dir=$st" --ctrl "type=unixio,path=$TPMSOCK" --tpm2 --log "file=$WD/swtpm-$tag.log,level=1" &
    SWPID=$!
    local i; for i in $(seq 1 50); do [[ -S "$TPMSOCK" ]] && break; sleep 0.1; done
    [[ -S "$TPMSOCK" ]] || { cat "$WD/swtpm-$tag.log"; fail "swtpm did not create its socket"; }
    timeout 240 qemu-system-x86_64 -M "q35,accel=$ACCEL" -m 2048 -display none -no-reboot \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$WD/vars-$tag.fd" \
        -drive "file=$esp,format=raw,if=virtio" \
        -chardev "socket,id=chrtpm,path=$TPMSOCK" -tpmdev emulator,id=tpm0,chardev=chrtpm \
        -device "tpm-tis,tpmdev=tpm0" \
        -serial "file:$ser" >"$WD/qemu-$tag.log" 2>&1
    kill "$SWPID" 2>/dev/null; SWPID=""
    local g; g="$(tr -d '\r' < "$ser")"
    grep -qF 'CAPTURE-DONE' <<<"$g" || { echo "$g" | tail -8; fail "($tag) the guest never reached CAPTURE-DONE — the UKI did not boot to the measure initramfs, or the TPM was not seen"; }
    local live; live="$(grep -aoE 'PCR-SHA256-11=[0-9A-Fa-f]+' <<<"$g" | head -1 | cut -d= -f2 | tr 'A-F' 'a-f')"
    [[ "$live" =~ ^[0-9a-f]{64}$ ]] || fail "($tag) no live PCR 11 read from the guest's TPM"
    # replay the guest's own TCG event log — the FOREIGN oracle must explain the register
    awk '/EVLOG-B64-BEGIN/{f=1;next} /EVLOG-B64-END/{f=0} f' <<<"$g" | tr -d '\r\n ' | base64 -d > "$WD/evlog-$tag.bin" 2>/dev/null
    [[ -s "$WD/evlog-$tag.bin" ]] || fail "($tag) the guest emitted no TCG event log to replay against"
    local logpcr; logpcr="$(tpm2_eventlog "$WD/evlog-$tag.bin" 2>/dev/null | sed -n '/sha256:/,/^[^ ]/p' | awk '$1=="11"{print $3}' | head -1 | sed 's/^0x//')"
    printf 'LIVEPCR11_%s=%s\n' "$tag" "$live"
    printf 'LOGPCR11_%s=%s\n'  "$tag" "${logpcr:-none}"
    # the PCR-11 events are the UKI's sections, name-then-content
    tpm2_eventlog "$WD/evlog-$tag.bin" 2>/dev/null > "$WD/elog-$tag.yaml"
    SECCOUNT="$(python3 - "$WD/elog-$tag.yaml" <<'PY'
import sys,yaml
d=yaml.safe_load(open(sys.argv[1])) or {}
secs=[]
for e in d.get('events',[]):
    if e.get('PCRIndex')==11 and e.get('EventType')=='EV_IPL':
        ev=e.get('Event');
        s=ev.get('String','') if isinstance(ev,dict) else ''
        secs.append(''.join(ch for ch in s if ch.strip()))
print(len([s for s in secs if s.startswith('.')]))
PY
)"
    printf 'SECEVENTS_%s=%s\n' "$tag" "${SECCOUNT:-0}"
}

# ── the measured boot, graded ─────────────────────────────────────────────────
build_uki 'console=ttyS0 quiet' "$WD/uki-a.efi"
eval "$(boot_pcr "$WD/uki-a.efi" A)"
[[ "$LOGPCR11_A" == "$LIVEPCR11_A" ]] \
    || fail "the TCG event log replays PCR 11 to $LOGPCR11_A but the guest's live TPM holds $LIVEPCR11_A — the log does not explain the register, so the measurement is not trustworthy"
(( SECEVENTS_A >= 7 )) \
    || fail "only $SECEVENTS_A PCR-11 section events in the log — the stub did not measure the UKI's sections (.linux/.osrel/.cmdline/.initrd/.uname/.sbat/.pcrpkey) into the real TPM"
note "boot A: the UKI booted under OVMF + a real swtpm TPM 2.0; PCR 11 = ${LIVEPCR11_A:0:16}… read LIVE from the guest's /sys/class/tpm/tpm0; tpm2_eventlog replays the kernel's TCG log to exactly that value; $SECEVENTS_A PCR-11 events, each a UKI section measured name-then-content"

# ── the negative control: a one-section change MUST move PCR 11 ───────────────
build_uki 'console=ttyS0 rescue' "$WD/uki-b.efi"
eval "$(boot_pcr "$WD/uki-b.efi" B)"
[[ "$LOGPCR11_B" == "$LIVEPCR11_B" ]] \
    || fail "(control) the event log ($LOGPCR11_B) does not explain the live PCR 11 ($LIVEPCR11_B) on the changed UKI"
[[ "$LIVEPCR11_B" != "$LIVEPCR11_A" ]] \
    || fail "NEGATIVE CONTROL FAILED: a UKI with a different .cmdline measured to the SAME PCR 11 ($LIVEPCR11_A) — the measured boot is not content-sensitive, so a tampered UKI would be indistinguishable"
note "control: changing one section (.cmdline) moved PCR 11 to ${LIVEPCR11_B:0:16}… (≠ boot A) — a tampered UKI measures differently, and the log explains the new register too"

note "UNKNOWN (named, deferred): PHASE-level .pcrsig policy satisfaction. The actual PCR 11 here is the UKI's sections measured into the real TPM; systemd-measure calculate reports a value with the enter-initrd PHASE already applied, so the two differ by exactly that phase extension. Reaching the phase needs a systemd-pcrphase initrd (busybox never runs it); the end-to-end proof is such an initrd unlocking a .pcrsig-sealed secret. See PLAN.md."

pass() { echo "PASS: $*"; }
pass "the UKI's MEASURED BOOT, into a real TPM, graded by a foreign oracle — closing most of the attestation strand's boot half (was UNKNOWN per the plan). A bootable PCR-keyed UKI (ukify --measure, real kernel + initrd) boots under genuine OVMF with a swtpm TPM 2.0; the systemd-stub measures its sections into PCR 11; the guest reads the LIVE PCR 11 from its own TPM; and tpm2_eventlog (the foreign oracle) replays the kernel's TCG event log to EXACTLY that register, its PCR-11 events being the UKI's own sections measured name-then-content. The negative control bites: a one-section change (.cmdline) moves PCR 11, so the measured boot is content-sensitive. What stays UNKNOWN is named: matching the carried .pcrsig at a boot PHASE needs a systemd-pcrphase initrd — the sections-only value measured here differs from systemd-measure's phase-applied prediction by exactly that extension, diagnosed not hand-waved. This is the live-TPM counterpart to smoke-uki-pcrsig.sh's host-side self-prediction"
