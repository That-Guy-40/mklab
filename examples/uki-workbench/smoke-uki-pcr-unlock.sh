#!/usr/bin/env bash
# smoke-uki-pcr-unlock.sh — the attestation strand's END-TO-END: a secret SEALED to
# a UKI's measured boot UNLOCKS only on that boot, and a tampered UKI is REFUSED by
# the TPM. This is the piece smoke-uki-pcrsig.sh (self-prediction, host-side) and
# smoke-uki-attest-boot.sh (the live PCR-11 measurement) were building toward: not
# "the boot measures X" but "a key that only exists when the boot measures X".
#
# WHAT IT BUILDS, and why each piece is here:
#   - a SELF-CONTAINED initrd carrying systemd-creds + systemd-pcrextend and their
#     full runtime closure (libsystemd-shared, the dlopen'd libtss2 set, the dynamic
#     linker) beside busybox — so a real systemd TPM2 userspace runs in a ramdisk;
#   - a bootable, PCR-keyed UKI (ukify --measure) with that initrd;
#   - two boots over ONE swtpm state dir (so the TPM's SRK persists) and ONE ext2
#     scratch disk (so the sealed credential persists boot-to-boot).
#
# THE PROOF, graded on what the guest prints to its own serial:
#   BOOT A (the good UKI): the stub measures the UKI's sections into PCR 11,
#     systemd-pcrextend adds the enter-initrd phase, systemd-creds ENROLLS a secret
#     sealed to PCR 11 as-measured (--tpm2-pcrs=11), and systemd-creds DECRYPTs it
#     back — UNLOCK-OK with the real secret.
#   BOOT B (a tampered UKI — one section, .cmdline, changed, nothing else): the same
#     TPM and the same sealed credential, but PCR 11 now measures differently, so the
#     TPM REFUSES the policy — UNLOCK-FAIL, systemd naming the tamper. That refusal is
#     the whole point: the credential is bound to the boot, not merely stored on it.
#
# A REFINEMENT STAYS A SPIKE (named, not hidden). This binds with a DIRECT PCR
# policy, which breaks on any legitimate UKI update. The update-survivable form is
# the UKI's SIGNED .pcrsig policy (systemd-creds --tpm2-public-key, a PolicyAuthorize
# over the signature). Built and measured here while developing this (see PLAN.md):
# the enroll/unlock ran, but the tampered boot STILL unlocked under the public-key
# policy — and that was localized, by event-log replay, to systemd-creds'
# PolicyAuthorize handling and NOT to the TPM (the two UKIs measure PCR 11 to
# genuinely different values, 0x096a… vs 0xa506…). So the signed-policy gating is a
# documented open spike; the direct-policy gating below is proven, control biting.
#
# NOT A TRUST ANCHOR: swtpm is software. This proves the mechanism — seal, measure,
# gate — not that a physical machine is trustworthy (that needs a hardware AK quote,
# which is UNKNOWN here and not fakeable). Exit 0 pass / 1 fail / 77 skip.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
STUB=/usr/lib/systemd/boot/efi/linuxx64.efi.stub
CREDS=/usr/bin/systemd-creds
PCREXTEND=/usr/lib/systemd/systemd-pcrextend
KERNEL="${CAPTURE_KERNEL:-$HOME/.cache/mklab-kernel/vmlinuz}"
OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
OVMF_VARS="${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}"
SL=/usr/lib/x86_64-linux-gnu
WD=""; SWPID=""
# shellcheck disable=SC2154
trap 'rc=$?; [[ -n "$SWPID" ]] && kill "$SWPID" 2>/dev/null; [[ -n "$WD" ]] && rm -rf "$WD"; rm -f /tmp/uki-unlock-*.sock; [[ $rc -eq 0 || $rc -eq 1 || $rc -eq 77 ]] || echo "FAIL: smoke-uki-pcr-unlock.sh exited early (rc=$rc)"' EXIT
skip() { echo "SKIP: $*"; exit 77; }
fail() { echo "FAIL: $*"; exit 1; }
note() { echo "  - $*"; }
pass() { echo "PASS: $*"; exit 0; }

for t in qemu-system-x86_64 swtpm ukify mke2fs mcopy mformat base64 busybox openssl objcopy; do
    command -v "$t" >/dev/null || skip "$t not installed — the in-initrd measured-boot unlock needs it"
done
[[ -x "$CREDS" ]] || skip "systemd-creds not found (systemd)"
[[ -x "$PCREXTEND" ]] || skip "systemd-pcrextend not found (systemd 259+; was systemd-pcrphase)"
[[ -f "$STUB" ]] || skip "no systemd-stub at $STUB (systemd-boot)"
[[ -r "$OVMF_CODE" && -r "$OVMF_VARS" ]] || skip "OVMF 4M images not under /usr/share/OVMF (apt install ovmf)"
[[ -r "$KERNEL" ]] || skip "no TPM-capable kernel at $KERNEL (set CAPTURE_KERNEL=)"
ls "$SL"/libtss2-esys.so.* >/dev/null 2>&1 || skip "libtss2-esys not present — systemd-creds dlopens the TPM2 stack"
ACCEL=$([[ -w /dev/kvm ]] && echo kvm || echo tcg)
SECRET="mklab-attestation-secret-42"

WD="$(mktemp -d)"; R="$WD/root"; mkdir -p "$R/bin"
# ── stage the in-initrd userspace: busybox + systemd-creds/pcrextend + full closure ──
cp "$(command -v busybox)" "$R/bin/busybox"
stage() { local f="$1"; mkdir -p "$R$(dirname "$f")"; cp -L "$f" "$R$f"
    ldd "$f" 2>/dev/null | grep -oE '/[^ ]+\.so[^ ]*' | while read -r l; do [[ -e "$R$l" ]] || { mkdir -p "$R$(dirname "$l")"; cp -L "$l" "$R$l"; }; done; }
stage "$CREDS"; stage "$PCREXTEND"
mkdir -p "$R$SL/systemd"; cp -L "$SL"/systemd/libsystemd-shared-*.so "$R$SL/systemd/" 2>/dev/null
# libtss2 is dlopen'd (invisible to ldd): esys/mu/rc/sys + the tctildr + the /dev/tpmrm0 TCTI
for t in esys mu rc sys tctildr tcti-device; do cp -L "$SL"/libtss2-$t.so.* "$R$SL/" 2>/dev/null; done
mkdir -p "$R/lib64"; cp -L /lib64/ld-linux-x86-64.so.2 "$R/lib64/" 2>/dev/null
[[ -s "$R$CREDS" && -n "$(ls "$R$SL"/libtss2-esys.so.* 2>/dev/null)" ]] || fail "staging the in-initrd systemd userspace failed"

# ── /init: pcrextend → enroll-if-absent (direct PCR-11 policy) → decrypt ──
cat > "$R/init" <<'INIT'
#!/bin/busybox sh
busybox mount -t proc none /proc 2>/dev/null; busybox mount -t sysfs none /sys 2>/dev/null; busybox mount -t devtmpfs none /dev 2>/dev/null
busybox mkdir -p /tmp /mnt
i=0; while [ ! -e /dev/tpmrm0 ] && [ $i -lt 40 ]; do busybox sleep 0.1; i=$((i+1)); done
[ -e /dev/tpmrm0 ] || { busybox echo "ATTEST-FAIL: no /dev/tpmrm0"; busybox sleep 1; busybox poweroff -f; }
busybox mount -t ext2 /dev/vdb /mnt 2>/dev/null || busybox echo "MOUNT-FAIL"
/usr/lib/systemd/systemd-pcrextend enter-initrd 2>/dev/null && busybox echo "PCREXTEND-OK" || busybox echo "PCREXTEND-FAIL"
if [ ! -f /mnt/labsecret.cred ]; then
  busybox printf '%s' "SECRET_PLACEHOLDER" > /tmp/secret
  if /usr/bin/systemd-creds encrypt --with-key=tpm2 --tpm2-pcrs=11 --name=labsecret /tmp/secret /mnt/labsecret.cred 2>/tmp/ee; then
    busybox echo "ENROLL-OK"; busybox sync
  else busybox echo "ENROLL-FAIL: $(busybox cat /tmp/ee|busybox tr '\n' ' '|busybox cut -c1-160)"; fi
else busybox echo "ENROLL-SKIP"; fi
if /usr/bin/systemd-creds decrypt --name=labsecret /mnt/labsecret.cred /tmp/out 2>/tmp/e; then
  busybox echo "UNLOCK-OK secret=[$(busybox cat /tmp/out)]"
else
  busybox echo "UNLOCK-FAIL: $(busybox cat /tmp/e|busybox tr '\n' ' '|busybox cut -c1-160)"
fi
busybox echo "ATTEST-DONE"; busybox sync; busybox sleep 1; busybox poweroff -f
INIT
busybox sed -i "s/SECRET_PLACEHOLDER/$SECRET/" "$R/init" 2>/dev/null || sed -i "s/SECRET_PLACEHOLDER/$SECRET/" "$R/init"
chmod +x "$R/init"
( cd "$R" && find . | busybox cpio -o -H newc 2>/dev/null | gzip ) > "$WD/initrd.cpio.gz"
[[ -s "$WD/initrd.cpio.gz" ]] || fail "building the initrd failed"

# ── the good UKI and a tampered one (same initrd; only .cmdline differs) ──
openssl genrsa -out "$WD/pcr.key" 2048 2>/dev/null; openssl rsa -in "$WD/pcr.key" -pubout -out "$WD/pcr.pub" 2>/dev/null
printf 'ID=mklab-unlock\n' > "$WD/osrel"; printf 'console=ttyS0\n' > "$WD/cmd-good"; printf 'console=ttyS0 rescue\n' > "$WD/cmd-bad"
for v in good bad; do
    ukify build --linux="$KERNEL" --initrd="$WD/initrd.cpio.gz" --cmdline="@$WD/cmd-$v" --os-release="@$WD/osrel" \
        --stub="$STUB" --pcr-private-key="$WD/pcr.key" --pcr-public-key="$WD/pcr.pub" --measure \
        --output="$WD/uki-$v.efi" >"$WD/ukify-$v.log" 2>&1 || { tail -3 "$WD/ukify-$v.log"; fail "ukify failed to build the $v UKI"; }
done
# a one-section change MUST change the signed prediction, or the "tamper" is no tamper
objcopy -O binary --only-section=.pcrsig "$WD/uki-good.efi" "$WD/sig-good" 2>/dev/null
objcopy -O binary --only-section=.pcrsig "$WD/uki-bad.efi"  "$WD/sig-bad"  2>/dev/null
[[ "$(sha256sum <"$WD/sig-good"|cut -d' ' -f1)" != "$(sha256sum <"$WD/sig-bad"|cut -d' ' -f1)" ]] \
    || fail "the good and tampered UKIs carry the SAME .pcrsig — the .cmdline change did not move the prediction, so the negative control would be vacuous"

# ── one swtpm state dir (SRK persists) + one ext2 scratch (the cred persists A→B) ──
TPMSTATE="$WD/tpmstate"; mkdir -p "$TPMSTATE"
rm -rf "$WD/creddir"; mkdir -p "$WD/creddir"; mke2fs -q -t ext2 -F -d "$WD/creddir" "$WD/creds.ext2" 16M 2>/dev/null || fail "could not build the ext2 scratch disk"

boot() {  # boot <uki> <tag> -> prints the guest's ENROLL/UNLOCK lines
    local uki="$1" tag="$2"
    local esp="$WD/esp-$tag.img" sock="/tmp/uki-unlock-$tag.sock" ser="$WD/serial-$tag.log"
    truncate -s 64M "$esp"; mformat -i "$esp" -F ::; mmd -i "$esp" ::/EFI ::/EFI/BOOT; mcopy -i "$esp" "$uki" ::/EFI/BOOT/BOOTX64.EFI
    cp "$OVMF_VARS" "$WD/vars-$tag.fd"; rm -f "$sock"
    swtpm socket --tpmstate "dir=$TPMSTATE" --ctrl "type=unixio,path=$sock" --tpm2 --log "file=$WD/swtpm-$tag.log,level=1" &
    SWPID=$!; local i; for i in $(seq 1 50); do [[ -S "$sock" ]] && break; sleep 0.1; done
    [[ -S "$sock" ]] || { cat "$WD/swtpm-$tag.log"; fail "swtpm did not start for boot $tag"; }
    timeout 240 qemu-system-x86_64 -M "q35,accel=$ACCEL" -m 2048 -display none -no-reboot \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" -drive "if=pflash,format=raw,file=$WD/vars-$tag.fd" \
        -drive "file=$esp,format=raw,if=virtio" -drive "file=$WD/creds.ext2,format=raw,if=virtio" \
        -chardev "socket,id=chrtpm,path=$sock" -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0 \
        -serial "file:$ser" >"$WD/qemu-$tag.log" 2>&1
    kill "$SWPID" 2>/dev/null; SWPID=""
    tr -d '\r' < "$ser"
}

# ── BOOT A: the good UKI enrolls a secret bound to its measured PCR 11, and unlocks it ──
A="$(boot "$WD/uki-good.efi" A)"
grep -qF 'PCREXTEND-OK' <<<"$A" || fail "boot A: systemd-pcrextend did not advance the phase in-guest — the in-initrd systemd userspace is not running (see the serial log)"
grep -qF 'ENROLL-OK' <<<"$A" || fail "boot A: systemd-creds could not seal a secret to PCR 11 in-guest: $(grep -aoE 'ENROLL-FAIL:[^Z]*' <<<"$A" | head -1)"
grep -qF "UNLOCK-OK secret=[$SECRET]" <<<"$A" \
    || fail "boot A: the secret sealed to this boot's PCR 11 did not unlock on the SAME boot ($(grep -aoE 'UNLOCK-[A-Z]+[^Z]*' <<<"$A" | head -1)) — the mechanism is broken before the control can mean anything"
note "boot A (good UKI): the stub measured its sections into PCR 11, systemd-pcrextend added the enter-initrd phase, systemd-creds sealed '$SECRET' to PCR 11 as-measured and decrypted it back — UNLOCK-OK, in a ramdisk, against a real swtpm TPM 2.0"

# ── BOOT B: a tampered UKI, SAME TPM + SAME sealed cred — the TPM must REFUSE the policy ──
B="$(boot "$WD/uki-bad.efi" B)"
grep -qF 'ENROLL-SKIP' <<<"$B" || fail "boot B: the credential from boot A did not persist to boot B (no ENROLL-SKIP) — the test did not actually re-present the SAME sealed secret"
grep -qF 'UNLOCK-OK' <<<"$B" \
    && fail "NEGATIVE CONTROL FAILED: a tampered UKI (its .cmdline changed, a genuinely different PCR 11) STILL unlocked the secret — the credential is not bound to the boot, so a tampered image would attest as trusted"
grep -qiE 'UNLOCK-FAIL.*(policy does not match|tampered|out-of-date|not permitted)' <<<"$B" \
    || fail "boot B did not unlock, but not with a TPM policy-mismatch — the refusal is for the wrong reason: $(grep -aoE 'UNLOCK-FAIL:[^Z]*' <<<"$B" | head -1)"
note "boot B (tampered UKI, same TPM + same cred): PCR 11 measures differently, so the TPM REFUSES the policy — $(grep -aoE 'UNLOCK-FAIL:[^Z]*' <<<"$B" | head -1 | cut -c1-110) — the credential is bound to the boot, not merely stored on it"
note "REFINEMENT, a documented spike (PLAN.md): the UPDATE-SURVIVABLE form uses the UKI's SIGNED .pcrsig (systemd-creds --tpm2-public-key / PolicyAuthorize); its tampered boot STILL unlocked in testing, localized by event-log replay to systemd-creds' PolicyAuthorize handling (the two UKIs do measure PCR 11 differently), not to the TPM — so it stays open, UNKNOWN not PASS"

pass "the attestation strand, END TO END and gated: a secret SEALED to a UKI's measured boot unlocks ONLY on that boot, and a tampered UKI is REFUSED by a real TPM. A self-contained initrd carrying systemd-creds + systemd-pcrextend and their full runtime closure (libsystemd-shared, the dlopen'd libtss2 set, the dynamic linker) runs in a ramdisk under genuine OVMF + swtpm; the systemd-stub measures the UKI's sections into PCR 11, systemd-pcrextend adds the enter-initrd phase, and systemd-creds seals '$SECRET' to PCR 11 as-measured and decrypts it back (boot A). The negative control bites: one changed section (.cmdline) makes PCR 11 measure differently and the TPM refuses the policy — 'policy does not match current system state ... tampered' (boot B), with the SAME TPM and the SAME sealed credential, so the key is bound to the boot and not merely stored on it. The update-survivable signed-.pcrsig (PolicyAuthorize) variant is a named open spike whose gating did not bite in testing, localized to systemd-creds and not the TPM. swtpm is software, not a hardware root of trust — this proves the seal/measure/gate mechanism, not a trustworthy machine"
