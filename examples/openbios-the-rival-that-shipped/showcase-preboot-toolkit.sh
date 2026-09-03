#!/usr/bin/env bash
# showcase-preboot-toolkit.sh — B.3, all of it, in ONE boot.
#
# The Preboot Structure Toolkit is a set of Forth readers (dsl/) that run INSIDE
# the firmware, before any OS exists. Each smoke track proves one of them against
# a foreign oracle. This is the other view: one machine, one boot, four acts, in
# the order a real preboot investigation would take them — and the point of
# putting them together is that no hosted tool can be in this position at all.
#
#   ACT I   — the firmware DISSECTS ITS OWN CONTAINER: it walks the CBFS of the
#             very ROM that delivered it, in the mapped flash window, and finds
#             `fallback/payload` — which IS the firmware doing the reading.
#   ACT II  — the firmware WATCHES ITSELF WORK: re-runs its own coreboot-table
#             parser and diffs memory around it. The region the parser READS is
#             unchanged; the allocator's next block is not.
#   ACT III — a CARD'S OWN PROGRAM, run out of the card's own ROM: the option
#             ROM header read at the live BAR, its FCode byte-loaded from there,
#             and the card asked who it is through PCI config space.
#   ACT IV  — MEASURED-BOOT ARITHMETIC with no TPM and no OS: SHA-256 as a pure
#             Forth function, a TCG event log authored in RAM, and PCR0 replayed
#             as SHA256(PCR ‖ digest) — graded against python's hashlib.
#   ACT V   — the firmware HANDS ITS WORLD OVER: the live device tree — the one
#             the earlier acts just changed — flattened into a device tree blob,
#             pulled out of the guest by QEMU's QMP, and read by the device-tree
#             compiler itself. dtc finds fcode-card@3 and the second card's
#             cfg-id in it: the evidence of Act III, in the boot-handoff format.
#
# Everything is delivered over a CD to a firmware booted from a coreboot ROM;
# nothing is compiled into the firmware for the occasion. The verdict is real:
# every act is graded, and the run FAILS if any of them does not happen.
#
# Exit: 0 PASS / 1 FAIL / 77 SKIP.
# Env: OPENBIOS_WORKDIR (default ~/openbios-lab), COREBOOT_DIR
#      (default ~/linuxboot-lab/coreboot), FCODE_UTILS
set -u
usage() {
    cat <<'USAGE'
showcase-preboot-toolkit.sh      B.3's whole toolkit, in one boot, narrated

Boots the amd64 firmware from a coreboot ROM with two FCode option-ROM cards on
the bus and the dsl/ readers on a CD, then drives four acts at the 0 > prompt:

  I    walk the CBFS of the ROM that delivered this firmware (find itself)
  II   re-run the firmware's own coreboot-table parser and diff memory
  III  read a card's option ROM at its live BAR and run its FCode from there
  IV   SHA-256 in Forth, a TCG event log authored in RAM, PCR0 replayed
  V    flatten the live device tree to a DTB; dtc reads Act III's cards out of it

Prereqs: ./build-openbios.sh amd64 && ./build-coreboot-openbios.sh amd64,
qemu-system-x86_64, genisoimage, python3, device-tree-compiler (dtc, fdtdump,
fdtget), and toke (built on demand from the pinned fcode-utils clone).

Exit: 0 PASS / 1 FAIL / 77 SKIP.
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORKDIR="${OPENBIOS_WORKDIR:-$HOME/openbios-lab}"
CB="${COREBOOT_DIR:-$HOME/linuxboot-lab/coreboot}"

pass() { echo; echo "PASS: $*"; exit 0; }
fail() { echo; echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; exit 77; }
note() { echo "  - $*"; }
act()  { echo; echo "══ $* ══"; }
say()  { echo "     $*"; }
# shellcheck disable=SC2154  # rc IS assigned by the rc=$? at the start of this same
# single-quoted trap body; shellcheck does not carry it into the uses that follow.
trap 'rc=$?; [[ $rc -eq 0 || $rc -eq 1 || $rc -eq 77 ]] || echo "FAIL: showcase exited early (rc=$rc)"' EXIT

for c in qemu-system-x86_64 genisoimage python3 dtc fdtdump fdtget; do
  command -v "$c" >/dev/null || skip "$c not installed$( [[ $c == dtc || $c == fdt* ]] && echo ' (apt: device-tree-compiler)')"
done
ACCEL=$([[ -w /dev/kvm ]] && echo kvm || echo tcg)
ROM="$CB/build-openbios-amd64/coreboot.rom"
CBT="$CB/build-openbios-amd64/cbfstool"
PAY="$WORKDIR/openbios/obj-amd64/openbios-builtin.elf32"
[[ -f "$ROM" ]] || skip "no amd64 coreboot ROM at $ROM — run ./build-coreboot-openbios.sh amd64"
[[ -x "$CBT" ]] || skip "no cbfstool at $CBT — build the ROM first"
[[ -f "$PAY" ]] || skip "no amd64 payload at $PAY — run ./build-openbios.sh amd64"
# THE ROM MUST CARRY THIS TREE'S PAYLOAD, or every act below reports on other
# firmware. This is the record-outlives-its-subject guard, not a formality.
PROV="$("$REPO/tools/openbios-rom-provenance.sh" --check "$ROM" "$PAY" 2>&1)"; PRC=$?
case $PRC in
  0)  ;;
  77) skip "$PROV" ;;
  *)  fail "$PROV" ;;
esac

FCU="${FCODE_UTILS:-$WORKDIR/fcode-utils}"; TOKE="$FCU/toke/toke"
if [[ ! -x "$TOKE" && -f "$FCU/toke/Makefile" ]] && command -v make >/dev/null && command -v cc >/dev/null; then
  make -C "$FCU/toke" >"$WORKDIR/toke-build.log" 2>&1 || true
fi
[[ -x "$TOKE" ]] || skip "no toke at $TOKE — run ./build-openbios.sh (it clones fcode-utils) or set FCODE_UTILS="

FX="$HERE/fixtures/optrom"
DSL=(struct.fth cbfs.fth region.fth lbregion.fth optrom.fth sha256.fth eventlog.fth fdt.fth)
for f in "${DSL[@]}"; do
  [[ -f "$HERE/dsl/$f" ]] || fail "missing $HERE/dsl/$f — the showcase stages the SHIPPED readers"
done
for f in fcode-card.fth fcode-card-cfg.fth build-fcode-rom.py; do
  [[ -f "$FX/$f" ]] || fail "missing $FX/$f"
done

WD="$WORKDIR/showcase-toolkit"; rm -rf "$WD"; mkdir -p "$WD/stage"
echo "OpenBIOS preboot structure toolkit — one boot, four acts"
note "firmware: the amd64 payload of $ROM ($PROV)"
note "accel=$ACCEL"

# ── the two cards ────────────────────────────────────────────────────────────
cp "$FX/fcode-card.fth" "$FX/fcode-card-cfg.fth" "$WD/"
for c in fcode-card fcode-card-cfg; do
  ( cd "$WD" && "$TOKE" "$c.fth" ) >"$WD/toke-$c.log" 2>&1 \
    || fail "toke failed on $c.fth: $(tail -2 "$WD/toke-$c.log" | tr '\n' '|')"
done
python3 "$FX/build-fcode-rom.py" "$WD/fcode-card.fc" "$WD/fcode.rom" >/dev/null \
  || fail "build-fcode-rom.py failed on fcode-card"
python3 "$FX/build-fcode-rom.py" "$WD/fcode-card-cfg.fc" "$WD/cfgcard.rom" >/dev/null \
  || fail "build-fcode-rom.py failed on fcode-card-cfg"
note "cards: fcode-card.fth and fcode-card-cfg.fth → toke → $(stat -c%s "$WD/fcode.rom")- and $(stat -c%s "$WD/cfgcard.rom")-byte PCI option ROMs"

# ── the readers, on a CD ─────────────────────────────────────────────────────
declare -A DOS=( [struct.fth]=STRUCT [cbfs.fth]=CBFS [region.fth]=REGION
                 [lbregion.fth]=LBREGION [optrom.fth]=OPTROM [sha256.fth]=SHA
                 [eventlog.fth]=EVLOG [fdt.fth]=FDT )
for f in "${DSL[@]}"; do cp "$HERE/dsl/$f" "$WD/stage/${DOS[$f]}.FTH"; done
genisoimage -quiet -o "$WD/dsl.iso" -V TOOLKIT -r -J "$WD/stage" 2>/dev/null \
  || fail "genisoimage failed to stage the readers"
note "readers on CD: ${DSL[*]}"

# ── where the ROM maps (derived, never hardcoded) ────────────────────────────
ROMSZ=$(stat -c%s "$ROM"); MAPBASE=$(( 0x100000000 - ROMSZ ))
RGN="$("$CBT" "$ROM" layout 2>/dev/null | sed -n "s/.*'COREBOOT'.*offset \([0-9]*\).*/\1/p" | head -1)"
[[ -n "$RGN" ]] || fail "could not read the COREBOOT region offset from cbfstool layout"
WIN="$(printf '%x' $(( MAPBASE + RGN )))"
note "the ROM is $ROMSZ bytes → QEMU maps it at $(printf '0x%x' "$MAPBASE"); its CBFS region begins at flash window 0x$WIN"

# ── PCR0, computed on the host, as the oracle for ACT IV ─────────────────────
# dsl/eventlog.fth authors digests filled with 0x11 (PCR0) then 0x22 (PCR0);
# a PCR starts at 32 zero bytes and each event extends it. Derived here from
# those constants rather than quoted from a previous run.
ORACLE_PCR0="$(python3 - <<'PY'
import hashlib
p = bytes(32)
for b in (0x11, 0x22):
    p = hashlib.sha256(p + bytes([b])*32).digest()
print(p.hex())
PY
)"

# ── ONE BOOT ─────────────────────────────────────────────────────────────────
SER="/tmp/scts-$$.sock"; MON="/tmp/sctm-$$.sock"; QMP="/tmp/sctq-$$.sock"; LOG="$WD/boot.log"
rm -f "$SER" "$MON" "$QMP" "$LOG"
P="/pci8086,1237@0"      # the pc machine's host bridge, as this firmware names it
qemu-system-x86_64 -M "pc,accel=$ACCEL" -m 512 -bios "$ROM" -nic none \
  -device "e1000,romfile=$WD/fcode.rom" -device "e1000,romfile=$WD/cfgcard.rom" \
  -cdrom "$WD/dsl.iso" -display none \
  -serial "unix:$SER,server=on,wait=off" -monitor "unix:$MON,server=on,wait=off" \
  -qmp "unix:$QMP,server=on,wait=off" \
  -no-reboot >"$WD/qemu.log" 2>&1 &
Q=$!
echo; echo "  booting… (one QEMU, one serial console, everything below is typed at 0 >)"

LOADS=()
for f in "${DSL[@]}"; do
  LOADS+=( --send "load /ide@1/cdrom@0:\\\\${DOS[$f]}.FTH\r" --expect "0 > "
           --send 'load-base load-size evaluate\r' --expect "0 > " )
done
python3 "$REPO/tools/drive-serial-repl.py" "$SER" "$LOG" --timeout 400 \
  --expect "0 > " \
  "${LOADS[@]}" \
  --send "$WIN 20 cbfs-list\r"                       --expect "CBFS-END" --expect "0 > " \
  --send 'region-selftest\r'                          --expect "SELFTEST=" --expect "0 > " \
  --send '.lb-table\r'                                --expect "LBT="      --expect "0 > " \
  --send 'lb-table-diff\r'                            --expect "LBTAB="    --expect "0 > " \
  --send 'lb-heap-diff\r'                             --expect "LAST="     --expect "0 > " \
  --send "dev $P/e1000@3 .fcode-marker optrom-report\r" --expect "0 > " \
  --send 'optrom-cfg optrom-run .fcode-marker\r'      --expect "MARK="     --expect "0 > " \
  --send "dev $P/e1000@4 optrom-run .cfg-id\r"        --expect "CFGID="    --expect "0 > " \
  --send "dev $P ls\r"                                --expect "0 > " \
  --send '." H_abc=" s" abc" sha256 .digest cr\r'     --expect "H_abc="    --expect "0 > " \
  --send '1000 alloc-mem value evbuf\r'               --expect "0 > " \
  --send 'evbuf dup evlog-author value evlen drop\r'  --expect "0 > " \
  --send '." EVLEN=" evlen . cr\r'                    --expect "EVLEN="    --expect "0 > " \
  --send '." PCR0=" evbuf evbuf evlen + 40 0 evlog-replay .digest cr\r' \
                                                      --expect "PCR0="     --expect "0 > " \
  --send '/fdt-buf alloc-mem value fb  fb dt>fdt .fdt-counts\r' --expect "PROPS=" --expect "0 > " \
  --send '." FDTP=" fb >phys u. cr\r'                --expect "FDTP="    --expect "0 > "
RC=$?
# ACT V's bytes leave the guest through QMP while it is still up — QMP, not the
# HMP monitor, whose parser reads a filename as an expression (a trap this repo's
# memory carries, and which still cost the fdt track a run).
FDTP="$(grep -aoE 'FDTP=[0-9a-f]+' "$LOG" | head -1 | cut -d= -f2)"; FDTL="$(grep -aoE 'FDTL=[0-9a-f]+' "$LOG" | head -1 | cut -d= -f2)"
FQR=""
if [[ -n "$FDTP" && -n "$FDTL" ]]; then
  FQR="$(python3 - "$QMP" "$FDTP" "$FDTL" "$WD/tree.dtb" <<'PY'
import socket, sys, json, time
s = socket.socket(socket.AF_UNIX); s.settimeout(15)
for _ in range(20):
    try: s.connect(sys.argv[1]); break
    except OSError: time.sleep(0.5)
else: print("ERR: no qmp"); sys.exit(0)
s.recv(65536)
def cmd(o): s.sendall((json.dumps(o)+"\n").encode()); return s.recv(65536).decode()
cmd({"execute": "qmp_capabilities"})
r = cmd({"execute": "pmemsave", "arguments": {"val": int(sys.argv[2], 16), "size": int(sys.argv[3], 16), "filename": sys.argv[4]}})
print("ERR: " + r.strip() if '"error"' in r else "ok")
PY
)"
fi
kill "$Q" 2>/dev/null   # by PID, never by pattern
G="$(tr -d '\r\000' < "$LOG" 2>/dev/null)"
[[ $RC -eq 0 ]] || fail "the firmware did not finish the five acts (rc=$RC) — see $LOG"

mk() { grep -aoE "$1=[0-9a-fA-F]+" <<<"$G" | head -1 | cut -d= -f2; }

# ══ ACT I ════════════════════════════════════════════════════════════════════
act "ACT I — the firmware dissects the container it arrived in"
say "typed: $WIN 20 cbfs-list          (the mapped flash window, not a file)"
NFILE=$(grep -ac 'cbfs| ' <<<"$G" || true)
# count cbfstool's rows the way the firmware counts entries — every row with an
# offset, the unnamed free-space entry included — so the two numbers answer the
# same question. (Entries against NAMED files is off by one and looks like a bug.)
OFILES=$("$CBT" "$ROM" print 2>/dev/null | awk '$2 ~ /^0x/' | wc -l)
grep -q 'fallback/payload' <<<"$G" \
  || fail "ACT I: the CBFS walk never reached fallback/payload — the SELF payload that IS this running firmware — see $LOG"
grep -q 'bootblock' <<<"$G" \
  || fail "ACT I: the CBFS walk never reached bootblock, so the window was not traversed — see $LOG"
grep -aE 'cbfs\| ' <<<"$G" | sed 's/^/     /' | head -14
note "$NFILE entries read out of guest-PHYSICAL flash by the firmware itself"
[[ "$NFILE" == "$OFILES" ]] \
  || fail "ACT I: the firmware read $NFILE CBFS entries, coreboot's own cbfstool reads $OFILES in the same ROM on the host — see $LOG"
note "coreboot's own cbfstool reads the same $OFILES entries in that ROM from the host"
note "one of them is fallback/payload — the firmware that just read it"
say  "NO HOSTED TOOL CAN BE HERE: cbfstool cannot run inside the ROM it is reading."

# ══ ACT II ═══════════════════════════════════════════════════════════════════
act "ACT II — the firmware watches its own parser work"
SELF="$(mk SELFTEST)"; LBT="$(mk LBT)"; LBLEN="$(mk LBLEN)"; TAB="$(mk LBTAB)"
RANGES="$(mk RANGES)"; STEP="$(mk STEP)"; HEAP="$(mk HEAP)"; LAST="$(mk LAST)"
for p in "SELFTEST:$SELF" "LBT:$LBT" "LBTAB:$TAB" "RANGES:$RANGES" "STEP:$STEP" "HEAP:$HEAP" "LAST:$LAST"; do
  [[ -n "${p#*:}" ]] || fail "ACT II: ${p%%:*} never printed — a word aborted mid-act — see $LOG"
done
[[ "$SELF" == 1 ]] \
  || fail "ACT II: the diff instrument reports SELFTEST=$SELF for one byte the test poked itself — it cannot see a change at all, so nothing else in this act means anything — see $LOG"
say "typed: region-selftest            (calibrate the instrument BEFORE aiming it)"
note "SELFTEST=1 — one byte poked by us, one difference found"
say "typed: .lb-table                  (which region does the firmware's parser read?)"
note "the CBMEM-forwarded coreboot table: 0x$LBT, 0x$LBLEN bytes"
say "typed: lb-table-diff              (snapshot it, re-run the parser, diff)"
[[ "$TAB" == 0 ]] \
  || fail "ACT II: the coreboot table changed (LBTAB=0x$TAB) across a walk that only reads it — see $LOG"
note "LBTAB=0 — unchanged. read_lbtable() is a READER; this is the negative control"
say "typed: lb-heap-diff               (…now snapshot where its next malloc lands)"
(( 16#$HEAP > 0 )) \
  || fail "ACT II: HEAP=0 — re-running the firmware's own coreboot-table parser changed nothing, and SELFTEST=1 says the instrument works — see $LOG"
(( 16#$LAST < 16#$STEP )) \
  || fail "ACT II: the firmware wrote at +0x$LAST, outside the 0x$STEP bytes it allocated — see $LOG"
grep -aE 'region\| diff \+' <<<"$G" | sed 's/^/     /'
note "the bump allocator advanced 0x$STEP bytes (whole 16-byte memranges) and $((16#$HEAP)) of them changed, all inside that block (LAST=0x$LAST)"
note "RANGES=$RANGES — the parser found and wrote that many RAM ranges"
say  "A CHANGE THE FIRMWARE CAUSED, from a code path already in its own tree."

# ══ ACT III ══════════════════════════════════════════════════════════════════
act "ACT III — a card's own program, run out of the card's own ROM"
PHYS="$(grep -aoE 'optrom\| phys=[0-9a-f]+' <<<"$G" | head -1 | cut -d= -f2)"
[[ -n "$PHYS" ]] || fail "ACT III: the firmware found no expansion ROM on e1000@3 — see $LOG"
grep -q 'MARK=none' <<<"$G" \
  || fail "ACT III: fcode-marker was already present BEFORE any byte-load — the outcome would be pre-written — see $LOG"
say "typed: dev $P/e1000@3 .fcode-marker optrom-report"
note "MARK=none — nothing has run yet; the outcome cannot be pre-written"
grep -aoE 'optrom\| phys=[0-9a-f]+ size=[0-9a-f]+' <<<"$G" | head -1 | sed 's/^/     /'
# NOT [^\n] — in an ERE that is "not a backslash and not the letter n", so it
# stops at the 'n' of open-firmware and matches nothing (CLAUDE.md's own trap,
# walked into and caught by reading the output, 2026-09-03).
grep -aoE 'optrom\| sig=.*fcode@[0-9a-f]+' <<<"$G" | head -1 | sed 's/^/     /'
grep -q 'sig=aa55 pcir=50434952' <<<"$G" \
  || fail "ACT III: the 0x55AA/PCIR header did not parse at the live BAR 0x$PHYS — see $LOG"
grep -q 'type=1 open-firmware' <<<"$G" \
  || fail "ACT III: the ROM's PCIR code type did not read as an Open Firmware image — see $LOG"
note "the header is read at 0x$PHYS — the card's ROM BAR, live device memory, not a file"
say "typed: optrom-cfg optrom-run .fcode-marker"
grep -aoE 'cfg\| id=[0-9a-f]+ rom=[0-9a-f]+' <<<"$G" | head -1 | sed 's/^/     /'
grep -aoE 'optrom\| byte-load fcode@[0-9a-f]+' <<<"$G" | head -1 | sed 's/^/     /'
grep -q 'MARK=FCODE-FROM-CARD-RAN' <<<"$G" \
  || fail "ACT III: after byte-load from the live ROM the marker is '$(grep -ao 'MARK=[^ ]*' <<<"$G" | tail -1)' — the card's FCode did not run — see $LOG"
note "MARK=FCODE-FROM-CARD-RAN — the card's own bytecode ran and stamped the node"
grep -q 'fcode-card@3' <<<"$G" \
  || fail "ACT III: the bus listing does not name slot 3 fcode-card@3 — the card's device-name did not rename its node — see $LOG"
note "…and renamed its node: e1000@3 is now fcode-card@3 on the bus"
CFGID="$(mk CFGID)"
[[ "$CFGID" == 100e8086 ]] \
  || fail "ACT III: the second card computed cfg-id=$CFGID about itself; its slot is 8086:100e. 12378086 would be the HOST BRIDGE — what a card reads when my-space answers 0 — see $LOG"
say "typed: dev $P/e1000@4 optrom-run .cfg-id"
note "CFGID=$CFGID — the second card asked its own PCI config space who it is"
say  "(my-space, then \" config-l@\" to the parent bus — from inside the card's bytecode)"

# ══ ACT IV ═══════════════════════════════════════════════════════════════════
act "ACT IV — measured-boot arithmetic, with no TPM and no OS"
HABC="$(grep -aoE 'H_abc=[0-9a-f]+' <<<"$G" | head -1 | cut -d= -f2)"
WANT_ABC="$(python3 -c 'import hashlib;print(hashlib.sha256(b"abc").hexdigest())')"
[[ "$HABC" == "$WANT_ABC" ]] \
  || fail "ACT IV: SHA-256(\"abc\") in Forth is $HABC, python says $WANT_ABC — see $LOG"
say "typed: .\" H_abc=\" s\" abc\" sha256 .digest cr"
note "$HABC"
note "= python hashlib's SHA-256(\"abc\"), and NIST's published vector"
# `.` prints in the CURRENT BASE, which is hex here — parsing it as decimal
# silently yielded an empty string and the prose read "  bytes" (caught 2026-09-03).
# The lesson is the older one: a marker nobody asserts is a marker that can vanish.
EVLENX="$(grep -aoE 'EVLEN=[0-9a-f]+' <<<"$G" | head -1 | cut -d= -f2)"
[[ -n "$EVLENX" ]] \
  || fail "ACT IV: the firmware never printed EVLEN — evlog-author did not complete — see $LOG"
EVLEN=$(( 16#$EVLENX ))
(( EVLEN > 0x40 )) \
  || fail "ACT IV: the authored event log is only $EVLEN bytes — its SpecID header alone is larger — see $LOG"
say "typed: evbuf dup evlog-author value evlen drop"
note "a TCG crypto-agile event log authored in RAM: $EVLEN bytes, a SpecID header + 3 TCG_PCR_EVENT2 entries"
PCR0="$(grep -aoE 'PCR0=[0-9a-f]+' <<<"$G" | head -1 | cut -d= -f2)"
say "typed: .\" PCR0=\" evbuf evbuf evlen + 40 0 evlog-replay .digest cr"
note "$PCR0"
[[ "$PCR0" == "$ORACLE_PCR0" ]] \
  || fail "ACT IV: the firmware replayed PCR0=$PCR0; SHA256(SHA256(0³²‖0x11³²)‖0x22³²) is $ORACLE_PCR0 — see $LOG"
note "= the same extend chain computed on the host: PCR = SHA256(PCR ‖ digest), twice"
say  "UNKNOWN, and it stays UNKNOWN: this replays a log against itself. Whether a"
say  "machine really measured those events needs a hardware-signed quote, which"
say  "nothing here can produce — a verdict distinct from PASS."

# ══ ACT V ════════════════════════════════════════════════════════════════════
act "ACT V — the firmware hands its world over: the live tree, flattened"
FN="$(mk NODES)"; FP="$(mk PROPS)"
[[ -n "$FN" && -n "$FP" && -n "$FDTP" ]] || fail "ACT V: dt>fdt never printed its counts or the buffer's physical address — see $LOG"
say "typed: /fdt-buf alloc-mem value fb  fb dt>fdt .fdt-counts"
note "FDTL=$FDTL NODES=$FN PROPS=$FP — the firmware's own count of what it wrote"
say "typed: .\" FDTP=\" fb >phys u. cr            (…and where, for an observer outside)"
[[ "$FQR" == ok && -s "$WD/tree.dtb" ]] \
  || fail "ACT V: QMP pmemsave of 0x$FDTL bytes at guest-physical 0x$FDTP did not deliver the blob (${FQR:-no reply})"
note "QMP pmemsave pulled $(stat -c%s "$WD/tree.dtb") bytes out of the guest at 0x$FDTP"
DTCOUT="$(dtc -I dtb -O dts -o "$WD/tree.dts" "$WD/tree.dtb" 2>&1)"; DTCRC=$?
[[ $DTCRC -eq 0 ]] || fail "ACT V: dtc REFUSED the flattened tree (rc=$DTCRC): $(grep -v Warning <<<"$DTCOUT" | head -2 | tr '\n' '|')"
DN=$(fdtdump "$WD/tree.dtb" 2>/dev/null | grep -cE '\{$'); DP=$(fdtdump "$WD/tree.dtb" 2>/dev/null | grep -cE '^\s+[^ {}]+( = .*)?;$')
[[ "$DN" -eq $((16#$FN)) && "$DP" -eq $((16#$FP)) ]] \
  || fail "ACT V: fdtdump reads $DN nodes / $DP properties, the firmware said 0x$FN / 0x$FP — see $WD/tree.dtb"
say "host: dtc -I dtb -O dts tree.dtb"
note "dtc parses it: $DN nodes, $DP properties — equal to the firmware's own count"
# the evidence of ACT III, read back out of the blob by a FOREIGN tool
DCFG="$(fdtget -t x "$WD/tree.dtb" "$P/cfg-card@4" cfg-id 2>/dev/null | tr -d ' ')"
[[ "$DCFG" == 100e8086 ]] \
  || fail "ACT V: fdtget reads cfg-id=${DCFG:-<absent>} at $P/cfg-card@4 — the second card's own answer from Act III is not in the flattened tree as 100e8086"
grep -q 'fcode-card@3 {' "$WD/tree.dts" \
  || fail "ACT V: the flattened tree has no fcode-card@3 node — the rename the card's FCode did in Act III did not reach the blob"
DMEM="$(fdtget "$WD/tree.dtb" /memory reg 2>/dev/null | tr '\n' ' ')"
[[ -n "$DMEM" ]] || fail "ACT V: fdtget cannot read /memory reg from the blob"
say "host: fdtget -t x tree.dtb $P/cfg-card@4 cfg-id"
note "$DCFG — Act III's card, asking who it is, answered INTO the tree; dtc's own fdtget reads it back"
note "…and fcode-card@3, the node Act III's FCode renamed, is a node in the blob"
note "/memory reg = $DMEM(two cells per address: the 64-bit root of patch 43)"
say  "THIS IS THE HANDOFF FORMAT: what a kernel would be given. Every earlier act's"
say  "effect is in it, and the reader is the device-tree compiler, not this firmware."

pass "the B.3 preboot structure toolkit, end to end, in ONE boot of the amd64 firmware from a coreboot ROM. (I) It walked the CBFS of the very ROM that delivered it — $NFILE entries out of the mapped flash window at 0x$WIN, fallback/payload among them, which is the firmware doing the reading; coreboot's cbfstool reads the same $OFILES entries in that ROM from the host. (II) It re-ran its OWN coreboot-table parser and diffed memory around it: the table it reads came back byte-identical (the negative control), while the allocator's next block moved 0x$STEP bytes and $((16#$HEAP)) bytes inside it changed — a change the firmware caused, from a code path in its own tree, with the instrument calibrated first (SELFTEST=1). (III) It read a PCI option ROM's 0x55AA/PCIR header at the card's live BAR 0x$PHYS, byte-loaded the card's FCode straight out of it — the card's own program renamed e1000@3 to fcode-card@3 and stamped FCODE-FROM-CARD-RAN — and a second card computed cfg-id=$CFGID about ITSELF through my-space + config-l@ on its parent bus. (IV) It computed SHA-256 as a pure Forth function matching python and NIST, authored a $EVLEN-byte TCG crypto-agile event log in RAM, and replayed PCR0 to the same value the host's hashlib computes for the same extend chain. (V) It flattened its LIVE device tree — the tree the earlier acts had just changed — into a $(stat -c%s "$WD/tree.dtb")-byte version-17 DTB, QEMU's QMP pulled it out of the guest, and the device-tree compiler itself parsed it: $DN nodes and $DP properties, equal to the firmware's own count, with fcode-card@3 (Act III's rename) a node in it and the second card's cfg-id=$DCFG read back by fdtget — the boot-handoff format, carrying every earlier act's evidence, read by a foreign tool. Every reader came over a CD; nothing was compiled in for the occasion; and acts I and II are positions no hosted tool can occupy at all. THE BOUNDARY: act IV proves internal consistency, not that any machine is trustworthy — the hardware-signed quote is UNKNOWN"
