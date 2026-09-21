#!/usr/bin/env bash
# test-contract-conformance.sh — prove dsl/ modules conform to the contract (v1).
#
# HEADLESS: drives openbios-unix as an ordinary process (no QEMU), the same way
# the `unix` track does. It stages the SHIPPED dsl/*.fth on an ISO and drives the
# firmware to exercise, per module: the required core exists (NAME-open/-fields/
# -validate/-manifest), NAME-manifest carries an ARCH scope, NAME-validate REFUSES
# a corrupt fixture BY NAME and accepts a valid one, and — the separability
# guarantee — a slim profile names each absent module rather than mis-reporting it.
#
# THE CONTROL IS WHERE THE BUGS ARE (CLAUDE.md). This checker proves ITSELF first,
# on four fixture modules built here: a fully-conformant one that must NOT be
# caught, and three with a planted defect each — a manifest with no arch scope, a
# validate that never refuses, and a missing NAME-validate — that MUST be caught by
# the very assertions used on the real modules. An all-PASS run where none of the
# must-catch fixtures fired is a checker that checks nothing, and this exits non-zero
# on exactly that. Only after the self-proof passes are the shipped modules graded.
#
# The CBFS case is the load-bearing negative control the whole exercise rests on:
# dsl/cbfs.fth's cbfs-list used to read a corrupt first entry as an empty archive
# (silent CBFS-END); contract v1 makes it refuse by name, and this asserts that.
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd genisoimage python3

UB="${OPENBIOS_WORKDIR:-$HOME/openbios-lab}/openbios/obj-amd64/openbios-unix"
UD="$UB.dict"
[[ -x "$UB" ]] || skip "missing $UB — run ./build-openbios.sh unix (or all) first"
[[ -f "$UD" ]] || skip "missing $UD — run ./build-openbios.sh unix (or all) first"

DSL="$LAB_DIR/dsl"
for f in struct contract sha256 cbfs cbfs-conform elf elf-conform fdt fdt-read \
         fdt-conform eventlog evlog-conform cpio cpio-conform pe pe-conform \
         bootparams bootparams-conform \
         pe-edit pe-write-conform cpio-edit cpio-write-conform \
         bootparams-edit bootparams-write-conform; do
    [[ -f "$DSL/$f.fth" ]] \
        || fail "missing $DSL/$f.fth — this checker stages the SHIPPED files, never re-implements them"
done

STAGE="$(mktemp -d)"; TMPDIRS+=("$STAGE")
# 8.3-friendly uppercase names on the ISO; the driver loads them by these.
cp "$DSL/struct.fth"       "$STAGE/STRUCT.FTH"
cp "$DSL/contract.fth"     "$STAGE/CONTRACT.FTH"
cp "$DSL/sha256.fth"       "$STAGE/SHA256.FTH"
cp "$DSL/cbfs.fth"         "$STAGE/CBFS.FTH"
cp "$DSL/cbfs-conform.fth" "$STAGE/CBFSC.FTH"
cp "$DSL/elf.fth"          "$STAGE/ELF.FTH"
cp "$DSL/elf-conform.fth"  "$STAGE/ELFC.FTH"
cp "$DSL/fdt.fth"          "$STAGE/FDT.FTH"
cp "$DSL/fdt-read.fth"     "$STAGE/FDTREAD.FTH"
cp "$DSL/fdt-conform.fth"  "$STAGE/FDTC.FTH"
cp "$DSL/eventlog.fth"     "$STAGE/EVLOG.FTH"
cp "$DSL/evlog-conform.fth" "$STAGE/EVLOGC.FTH"
cp "$DSL/cpio.fth"         "$STAGE/CPIO.FTH"
cp "$DSL/cpio-conform.fth" "$STAGE/CPIOC.FTH"
cp "$DSL/pe.fth"           "$STAGE/PE.FTH"
cp "$DSL/pe-conform.fth"   "$STAGE/PEC.FTH"
cp "$DSL/bootparams.fth"       "$STAGE/BP.FTH"
cp "$DSL/bootparams-conform.fth" "$STAGE/BPC.FTH"
cp "$DSL/pe-edit.fth"          "$STAGE/PEEDIT.FTH"
cp "$DSL/pe-write-conform.fth" "$STAGE/PEW.FTH"
cp "$DSL/cpio-edit.fth"        "$STAGE/CPIOEDIT.FTH"
cp "$DSL/cpio-write-conform.fth" "$STAGE/CPIOW.FTH"
cp "$DSL/bootparams-edit.fth"  "$STAGE/BPEDIT.FTH"
cp "$DSL/bootparams-write-conform.fth" "$STAGE/BPW.FTH"

# ── fixture byte images: a valid + corrupt CBFS region and FDT blob ──────────
python3 - "$STAGE" <<'PY'
import struct, sys
o = sys.argv[1]
def be(*v): return b''.join(struct.pack('>I', x) for x in v)
# CBFS: one LARCHIVE entry (name "hi", 4 bytes content), then a non-LARCHIVE end.
def cbfs_entry(name, content, etype=0x50):
    off = 0x20
    nf = (name.encode() + b'\0'); nf += b'\0' * (off - 24 - len(nf))
    return b'LARCHIVE' + be(len(content), etype, 0, off) + nf + content, off
c, off = cbfs_entry('hi', b'DATA')
nxt = (off + 4 + 0x3f) & ~0x3f
open(o + '/VCBFS.BIN', 'wb').write(c + b'\0' * (nxt - len(c)) + b'\xff' * 16)
open(o + '/CCBFS.BIN', 'wb').write(b'XXXXXXXX' + b'\0' * 56)   # stomped magic
# FDT: valid header (magic d00dfeed) vs a wrong magic.
hdr = lambda magic: be(magic, 0x28, 0x28, 0x28, 0x28, 0x11, 0x10, 0, 0, 0)
open(o + '/VFDT.BIN', 'wb').write(hdr(0xd00dfeed))
open(o + '/CFDT.BIN', 'wb').write(hdr(0xdeadbeef))
# CPIO: a valid TRAILER-only newc archive (opens on ASCII "070701"); corrupt = flipped magic.
def newc(name, data):
    namez = name.encode() + b'\0'
    h = b'070701' + b''.join(b'%08X' % x for x in
        [0, 0, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(namez), 0])
    b = h + namez;  b += b'\0' * ((-len(b)) % 4)
    b += data;      b += b'\0' * ((-len(b)) % 4)
    return b
vcpio = newc('TRAILER!!!', b'')
open(o + '/VCPIO.BIN', 'wb').write(vcpio)
open(o + '/CCPIO.BIN', 'wb').write(b'07070X' + vcpio[6:])
# PE: a minimal PE32+ (MZ, e_lfanew→PE\0\0, COFF, optmagic 0x20b, one section); corrupt = stomp MZ.
pe = bytearray(0xc0)
pe[0:2] = b'MZ'
struct.pack_into('<I', pe, 0x3c, 0x40)         # e_lfanew
pe[0x40:0x44] = b'PE\0\0'
struct.pack_into('<H', pe, 0x44, 0x8664)       # Machine
struct.pack_into('<H', pe, 0x46, 1)            # NumberOfSections
struct.pack_into('<H', pe, 0x54, 0x28)         # SizeOfOptionalHeader (COFF+0x10)
struct.pack_into('<H', pe, 0x58, 0x20b)        # optional-header Magic PE32+
pe[0x80:0x88] = b'.test\0\0\0'                  # section table @ pe-hdr+0x18+optsize = 0x80
struct.pack_into('<I', pe, 0x88, 0x1000)       # VirtualSize
struct.pack_into('<I', pe, 0x8c, 0x1000)       # VirtualAddress
open(o + '/VPE.BIN', 'wb').write(bytes(pe))
cpe = bytearray(pe); cpe[0:2] = b'XX'
open(o + '/CPE.BIN', 'wb').write(bytes(cpe))
# BOOTPARAMS: the two anchors present; corrupt = wrong boot_flag.
bp = bytearray(0x300)
struct.pack_into('<H', bp, 0x1fe, 0xAA55)      # boot_flag
struct.pack_into('<I', bp, 0x202, 0x53726448)  # "HdrS"
open(o + '/VBP.BIN', 'wb').write(bytes(bp))
cbp = bytearray(bp); struct.pack_into('<H', cbp, 0x1fe, 0x1234)
open(o + '/CBP.BIN', 'wb').write(bytes(cbp))

# ── writer-half DELTA fixtures (Tier 2): richer, so an edit can be reverified ──
# PE with TWO sections at fixed rawoffs: .cmdline (0x100,"OLD",rawsize 0x20) + a
# neighbour .other (0x120,"KEEP"). A pe-write of .cmdline must change 0x100 and
# leave 0x120 alone; an oversize edit must be refused with 0x100 unchanged.
wpe = bytearray(0x200); wpe[0:2] = b'MZ'
struct.pack_into('<I', wpe, 0x3c, 0x40);  wpe[0x40:0x44] = b'PE\0\0'
struct.pack_into('<H', wpe, 0x44, 0x8664)
struct.pack_into('<H', wpe, 0x46, 2)              # two sections
struct.pack_into('<H', wpe, 0x54, 0x28)
struct.pack_into('<H', wpe, 0x58, 0x20b)
st = 0x80
wpe[st:st+8] = b'.cmdline'
struct.pack_into('<I', wpe, st+0x08, 3)           # VirtualSize
struct.pack_into('<I', wpe, st+0x10, 0x20)        # SizeOfRawData
struct.pack_into('<I', wpe, st+0x14, 0x100)       # PointerToRawData
e2 = st+0x28
wpe[e2:e2+8] = b'.other\0\0'
struct.pack_into('<I', wpe, e2+0x08, 4)
struct.pack_into('<I', wpe, e2+0x10, 0x10)
struct.pack_into('<I', wpe, e2+0x14, 0x120)
wpe[0x100:0x103] = b'OLD';  wpe[0x120:0x124] = b'KEEP'
open(o + '/WPE.BIN', 'wb').write(bytes(wpe))
# cpio with two members: cfg="AAAA", keep="ZZZZ", then TRAILER (offsets 0x74/0xec).
warc = newc('cfg', b'AAAA') + newc('keep', b'ZZZZ') + newc('TRAILER!!!', b'')
open(o + '/WCPIO.BIN', 'wb').write(warc)
# bootparams phys-0 dump: boot_params @0x100, cmd_line_ptr=0x400 → "old", cmdline_size 0x40,
# a code32_start neighbour = 0xDEADBEEF that a cmdline edit must not touch.
wbp = bytearray(0x800); Bp = 0x100
struct.pack_into('<H', wbp, Bp+0x1fe, 0xAA55)
struct.pack_into('<I', wbp, Bp+0x202, 0x53726448)
struct.pack_into('<I', wbp, Bp+0x214, 0xDEADBEEF) # code32_start (neighbour)
struct.pack_into('<I', wbp, Bp+0x228, 0x400)      # cmd_line_ptr
struct.pack_into('<I', wbp, Bp+0x238, 0x40)       # cmdline_size
wbp[0x400:0x404] = b'old\0'
open(o + '/WBP.BIN', 'wb').write(bytes(wbp))
PY

# ── fixture MODULES: one conformant, three each with one planted defect ──────
# The handle is a 1-byte marker buffer: byte 0 == valid, nonzero == corrupt. Each
# fixture defines the contract core except where a defect removes it.
cat > "$STAGE/FIX.FTH" <<'FTH'
hex
\ (1) GOOD — fully conformant. Must NOT be caught.
: good-validate ( h -- c-addr u )  c@ 0= if 0 0 else s" good: bad marker" then ;
: good-open  ( a l -- h )  drop dup good-validate ?refused if .refusal drop 0 exit then 2drop ;
: good-fields ( h -- )  drop s" marker" 0 1 .field3 ;
: good-manifest ( -- )  ." conformant fixture " arch-4/4 cr ;
s" good" ['] good-manifest register-module
\ (2) BADARCH — manifest carries NO arch scope. The ARCH check must catch it.
: bad1-validate ( h -- c-addr u )  c@ 0= if 0 0 else s" bad1: bad marker" then ;
: bad1-open  ( a l -- h )  drop dup bad1-validate ?refused if .refusal drop 0 exit then 2drop ;
: bad1-fields ( h -- )  drop s" marker" 0 1 .field3 ;
: bad1-manifest ( -- )  ." fixture with no arch scope" cr ;
s" bad1" ['] bad1-manifest register-module
\ (3) LENIENT — validate ACCEPTS a corrupt input. The refuses-by-name check must catch it.
: bad2-validate ( h -- c-addr u )  drop 0 0 ;
: bad2-open  ( a l -- h )  2drop 0 ;
: bad2-fields ( h -- )  drop s" marker" 0 1 .field3 ;
: bad2-manifest ( -- )  ." lenient fixture " arch-4/4 cr ;
s" bad2" ['] bad2-manifest register-module
\ (4) NOVALIDATE — the required core word bad3-validate is NOT defined. Must be caught.
: bad3-open  ( a l -- h )  2drop 0 ;
: bad3-fields ( h -- )  drop s" marker" 0 1 .field3 ;
: bad3-manifest ( -- )  ." missing validate " arch-4/4 cr ;
s" bad3" ['] bad3-manifest register-module
\ two marker buffers a test drives validate against
1 alloc-mem value mgood   0 mgood c!    \ valid marker
1 alloc-mem value mbad     1 mbad  c!    \ corrupt marker
FTH

ISO="$STAGE/conform.iso"
genisoimage -quiet -o "$ISO" -V CONFORM -r -J "$STAGE" \
    || fail "genisoimage failed to build the staging ISO"

# ── drive(): one openbios-unix process. Preamble points load-base at a scratch
# arena and loads the substrate; extra 'load X / evaluate' pairs and commands come
# from the caller (one string, newline-separated). Output (CR-stripped) → $OUT,
# the firmware's exit code → $DRC. Never pipe the gate: capture, then test.
OUT=""
drive() {
    local body="$1" log="$STAGE/drive.log"
    # `|| true`: a nonzero firmware exit must not trip set -e before we read the
    # log — the banner check below is the real liveness gate.
    { printf '%s\n' \
        '10000 alloc-mem value cb' 'cb (u.) s" load-base" $setenv' \
        'load hd:\STRUCT.FTH'   'load-base load-size evaluate' \
        'load hd:\CONTRACT.FTH' 'load-base load-size evaluate'
      printf '%s\n' "$body"
      printf 'bye\n'
    } | "$UB" -f "$ISO" "$UD" >"$log" 2>&1 || true
    OUT="$(tr -d '\r' < "$log")"
    # A drive that never reached the prompt is not a result about conformance.
    grep -qa 'Welcome to OpenBIOS' <<<"$OUT" \
        || fail "the firmware did not boot to a prompt — see $log"
}

# helper: load one module file + evaluate, as a body line-pair
lev() { printf 'load hd:\\%s\nload-base load-size evaluate\n' "$1"; }

# ── PART 0: the checker proves ITSELF on the fixtures, before any real module ──
note "self-proof: 1 conformant fixture (must NOT be caught) + 3 planted defects (must be caught)"
caught=0

# Drive the four fixtures once; each fixture's core is exercised against mgood/mbad.
FIXBODY="$(lev FIX.FTH)"$'\n'
FIXBODY+='." M-good=" good-manifest'$'\n'
FIXBODY+='." M-bad1=" bad1-manifest'$'\n'
FIXBODY+='." M-bad2=" bad2-manifest'$'\n'
FIXBODY+='." M-bad3=" bad3-manifest'$'\n'
FIXBODY+='." V-good-corrupt=" mbad  good-validate .refusal'$'\n'
FIXBODY+='." V-bad2-corrupt=" mbad  bad2-validate .refusal ." (blank=accepted-corrupt)" cr'$'\n'
FIXBODY+='." W-bad3=" mbad bad3-validate .refusal'   # bad3-validate undefined → error
drive "$FIXBODY"

# must-NOT-catch: GOOD is conformant on all three axes.
grep -qaE 'M-good=conformant fixture ARCH:(4/4|x86-only)' <<<"$OUT" \
    || fail "self-proof: the conformant fixture's manifest lacks an ARCH token — the arch check would reject a good module (false positive)"
grep -qa 'V-good-corrupt=REFUSED:' <<<"$OUT" \
    || fail "self-proof: the conformant fixture's validate did not refuse a corrupt input by name — the refuses-by-name check would reject a good module (false positive)"

# must-catch (1): a manifest with no ARCH token.
if grep -qaE 'M-bad1=.*ARCH:(4/4|x86-only)' <<<"$OUT"; then
    fail "self-proof: the no-arch fixture's manifest reported an ARCH token it does not have — the arch check is blind"
else
    note "caught: bad1 manifest has no ARCH scope"; caught=$((caught+1))
fi
# must-catch (2): a validate that accepts a corrupt input.
if grep -qa 'V-bad2-corrupt=REFUSED:' <<<"$OUT"; then
    fail "self-proof: the lenient fixture refused a corrupt input, so this fixture is not lenient — the control does not model the defect"
else
    note "caught: bad2 validate accepted a corrupt input (no REFUSED:)"; caught=$((caught+1))
fi
# must-catch (3): a missing NAME-validate word.
if grep -qaiE 'bad3-validate.*undefined|undefined word' <<<"$OUT"; then
    note "caught: bad3 is missing its NAME-validate word (undefined word)"; caught=$((caught+1))
else
    fail "self-proof: calling the absent bad3-validate did not surface an 'undefined word' — the core-word-exists check is blind"
fi
(( caught == 3 )) \
    || fail "self-proof: only $caught/3 planted defects were caught — an all-PASS run indistinguishable from a checker that checks nothing"
note "self-proof passed: good fixture clean, all 3 planted defects caught"

# ── PART 1: the real modules, each on its own arena ──────────────────────────
# CBFS — the load-bearing control: valid lists + validates clean; corrupt REFUSED.
cbody="$(lev CBFS.FTH)"$'\n'"$(lev CBFSC.FTH)"
cbody+=$'\n''load hd:\\VCBFS.BIN'$'\n''." cbfs-list-valid:" cr load-base 20 cbfs-list'$'\n'
cbody+='." cbfs-fields:" cr load-base cbfs-fields'$'\n'
cbody+='." cbfs-manifest=" cbfs-manifest'$'\n'
cbody+='." cbfs-v-valid=" load-base cbfs-validate .refusal ." (blank=valid)" cr'$'\n'
cbody+='load hd:\\CCBFS.BIN'$'\n''." cbfs-v-corrupt=" load-base cbfs-validate .refusal'$'\n'
cbody+='." cbfs-list-corrupt:" cr load-base 20 cbfs-list'
drive "$cbody"
grep -qa 'undefined word' <<<"$OUT" \
    && fail "cbfs: a required contract word is undefined — see the drive log; core not implemented"
grep -qaE 'cbfs-manifest=.*ARCH:(4/4|x86-only)' <<<"$OUT" \
    || fail "cbfs: NAME-manifest carries no ARCH scope"
grep -qa 'cbfs| off=00000000' <<<"$OUT" \
    || fail "cbfs: cbfs-list did not list the valid archive's entry"
grep -qa 'cbfs-fields:' <<<"$OUT" && grep -qa 'fld| name=magic' <<<"$OUT" \
    || fail "cbfs: cbfs-fields did not enumerate the layout"
grep -qaE 'cbfs-v-valid=.*blank=valid' <<<"$OUT" && ! grep -qa 'cbfs-v-valid=REFUSED' <<<"$OUT" \
    || fail "cbfs: cbfs-validate refused a VALID archive"
grep -qa 'cbfs-v-corrupt=REFUSED:' <<<"$OUT" \
    || fail "cbfs: cbfs-validate did not refuse a corrupt region BY NAME"
# THE DEFECT: a corrupt first entry must refuse by name, NOT print an empty CBFS-END.
awk '/cbfs-list-corrupt:/{f=1;next} f' <<<"$OUT" | grep -qa 'REFUSED: cbfs: no LARCHIVE' \
    || fail "REGRESSION: cbfs-list read a CORRUPT first entry as empty (no REFUSED) — the silent-stop defect contract v1 closes has returned; see cbfs.fth"
note "cbfs: lists a valid archive, refuses a corrupt first entry by name (the closed defect), ARCH:4/4"

# ELF — author a valid header, corrupt one field; validate via the reason seam.
ebody="$(lev ELF.FTH)"$'\n'"$(lev ELFC.FTH)"
ebody+=$'\n''40 alloc-mem value hdr  hdr elf64-new'$'\n'
ebody+='." elf-manifest=" elf-manifest'$'\n'
ebody+='." elf-v-valid=" hdr elf-validate .refusal ." (blank=valid)" cr'$'\n'
ebody+='." elf-open-valid=" hdr 40 elf-open u. cr'$'\n'
ebody+='." elf-fields:" cr hdr elf-fields'$'\n'
ebody+='0 @elf e_class t!'$'\n''." elf-v-corrupt=" hdr elf-validate .refusal'$'\n'
ebody+='hdr elf64-new 0 @elf e_magic t!'$'\n''." elf-open-corrupt=" hdr 40 elf-open u. cr'
drive "$ebody"
grep -qa 'undefined word' <<<"$OUT" \
    && fail "elf: a required contract word is undefined — core not implemented"
grep -qaE 'elf-manifest=.*ARCH:(4/4|x86-only)' <<<"$OUT" \
    || fail "elf: NAME-manifest carries no ARCH scope"
grep -qaE 'elf-v-valid=.*blank=valid' <<<"$OUT" && ! grep -qa 'elf-v-valid=REFUSED' <<<"$OUT" \
    || fail "elf: elf-validate refused a header elf64-new had just authored — writer and validator disagree"
grep -qa 'fld| name=e_class' <<<"$OUT" \
    || fail "elf: elf-fields did not enumerate the header"
grep -qa 'elf-v-corrupt=REFUSED: not ELF64' <<<"$OUT" \
    || fail "elf: elf-validate did not refuse a corrupt e_class BY NAME (via the chk reason seam)"
grep -qa 'elf-open-corrupt=REFUSED: elf: bad ELF magic' <<<"$OUT" \
    || fail "elf: elf-open did not refuse a bad magic BY NAME"
note "elf: validates its own authored header, refuses a corrupt class/magic by name, ARCH:4/4"

# FDT — valid vs wrong-magic blob.
fbody="$(lev FDT.FTH)"$'\n'"$(lev FDTREAD.FTH)"$'\n'"$(lev FDTC.FTH)"
fbody+=$'\n''load hd:\\VFDT.BIN'$'\n''." fdt-manifest=" fdt-manifest'$'\n'
fbody+='." fdt-v-valid=" load-base fdt-validate .refusal ." (blank=valid)" cr'$'\n'
fbody+='." fdt-fields:" cr load-base fdt-fields'$'\n'
fbody+='load hd:\\CFDT.BIN'$'\n''." fdt-v-corrupt=" load-base fdt-validate .refusal'
drive "$fbody"
grep -qa 'undefined word' <<<"$OUT" \
    && fail "fdt: a required contract word is undefined — core not implemented"
grep -qaE 'fdt-manifest=.*ARCH:(4/4|x86-only)' <<<"$OUT" \
    || fail "fdt: NAME-manifest carries no ARCH scope"
grep -qaE 'fdt-v-valid=.*blank=valid' <<<"$OUT" && ! grep -qa 'fdt-v-valid=REFUSED' <<<"$OUT" \
    || fail "fdt: fdt-validate refused a VALID device tree blob"
grep -qa 'fld| name=magic' <<<"$OUT" \
    || fail "fdt: fdt-fields did not enumerate the header"
grep -qa 'fdt-v-corrupt=REFUSED: fdt: bad FDT magic' <<<"$OUT" \
    || fail "fdt: fdt-validate did not refuse a bad magic BY NAME"
note "fdt: validates a real blob, refuses a bad magic by name, ARCH:4/4"

# EVLOG — author its own log, corrupt the SpecID signature. Needs sha256 first.
vbody="$(lev SHA256.FTH)"$'\n'"$(lev EVLOG.FTH)"$'\n'"$(lev EVLOGC.FTH)"
vbody+=$'\n''200 alloc-mem value elog  elog evlog-author drop'$'\n'
vbody+='." evlog-manifest=" evlog-manifest'$'\n'
vbody+='." evlog-v-valid=" elog evlog-validate .refusal ." (blank=valid)" cr'$'\n'
vbody+='." evlog-fields:" cr elog evlog-fields'$'\n'
vbody+='55 elog 20 + c!'$'\n''." evlog-v-corrupt=" elog evlog-validate .refusal'
drive "$vbody"
grep -qa 'undefined word' <<<"$OUT" \
    && fail "evlog: a required contract word is undefined — core not implemented"
grep -qaE 'evlog-manifest=.*ARCH:(4/4|x86-only)' <<<"$OUT" \
    || fail "evlog: NAME-manifest carries no ARCH scope"
grep -qaE 'evlog-v-valid=.*blank=valid' <<<"$OUT" && ! grep -qa 'evlog-v-valid=REFUSED' <<<"$OUT" \
    || fail "evlog: evlog-validate refused a log it had just authored"
grep -qa 'fld| name=pcrIndex' <<<"$OUT" \
    || fail "evlog: evlog-fields did not enumerate the entry"
grep -qa 'evlog-v-corrupt=REFUSED: evlog:' <<<"$OUT" \
    || fail "evlog: evlog-validate did not refuse a stomped SpecID signature BY NAME"
note "evlog: validates its own authored log, refuses a stomped signature by name, ARCH:4/4"

# CPIO — a TRAILER-only newc archive vs a flipped ASCII magic.
kbody="$(lev CPIO.FTH)"$'\n'"$(lev CPIOC.FTH)"
kbody+=$'\n''load hd:\\VCPIO.BIN'$'\n''." cpio-manifest=" cpio-manifest'$'\n'
kbody+='." cpio-v-valid=" load-base cpio-validate .refusal ." (blank=valid)" cr'$'\n'
kbody+='." cpio-fields:" cr load-base cpio-fields'$'\n'
kbody+='load hd:\\CCPIO.BIN'$'\n''." cpio-v-corrupt=" load-base cpio-validate .refusal'
drive "$kbody"
grep -qa 'undefined word' <<<"$OUT" \
    && fail "cpio: a required contract word is undefined — core not implemented"
grep -qaE 'cpio-manifest=.*ARCH:(4/4|x86-only)' <<<"$OUT" \
    || fail "cpio: NAME-manifest carries no ARCH scope"
grep -qaE 'cpio-v-valid=.*blank=valid' <<<"$OUT" && ! grep -qa 'cpio-v-valid=REFUSED' <<<"$OUT" \
    || fail "cpio: cpio-validate refused a valid newc archive"
grep -qa 'fld| name=c_magic' <<<"$OUT" \
    || fail "cpio: cpio-fields did not enumerate the header"
grep -qa 'cpio-v-corrupt=REFUSED: cpio:' <<<"$OUT" \
    || fail "cpio: cpio-validate did not refuse a flipped newc magic BY NAME"
note "cpio: validates a newc archive, refuses a flipped magic by name, ARCH:4/4 (ASCII-hex, no byte order)"

# PE — a minimal PE32+ vs a stomped MZ. pe-open reuses the native status opener.
pbody="$(lev PE.FTH)"$'\n'"$(lev PEC.FTH)"
pbody+=$'\n''load hd:\\VPE.BIN'$'\n''." pe-manifest=" pe-manifest'$'\n'
pbody+='." pe-v-valid=" load-base pe-validate .refusal ." (blank=valid)" cr'$'\n'
pbody+='." pe-open-valid=" load-base c0 pe-open u. cr'$'\n'
pbody+='." pe-fields:" cr load-base pe-fields'$'\n'
pbody+='load hd:\\CPE.BIN'$'\n''." pe-open-corrupt=" load-base c0 pe-open u. cr'
drive "$pbody"
grep -qa 'undefined word' <<<"$OUT" \
    && fail "pe: a required contract word is undefined — core not implemented"
grep -qaE 'pe-manifest=.*ARCH:(4/4|x86-only)' <<<"$OUT" \
    || fail "pe: NAME-manifest carries no ARCH scope"
grep -qaE 'pe-v-valid=.*blank=valid' <<<"$OUT" && ! grep -qa 'pe-v-valid=REFUSED' <<<"$OUT" \
    || fail "pe: pe-validate refused a valid PE32+"
grep -qa 'fld| name=Machine' <<<"$OUT" \
    || fail "pe: pe-fields did not enumerate the header"
grep -qa 'pe-open-corrupt=REFUSED: pe: no MZ' <<<"$OUT" \
    || fail "pe: pe-open did not refuse a stomped MZ BY NAME"
grep -qa 'pe-open-valid=REFUSED' <<<"$OUT" \
    && fail "pe: pe-open refused a valid PE32+"
note "pe: validates a PE32+, refuses a stomped MZ by name, ARCH:4/4 (x86/UEFI format read LE on all four)"

# BOOTPARAMS — anchors present vs a wrong boot_flag. bootparams-open reuses bp-open.
zbody="$(lev BP.FTH)"$'\n'"$(lev BPC.FTH)"
zbody+=$'\n''load hd:\\VBP.BIN'$'\n''." bp-manifest=" bootparams-manifest'$'\n'
zbody+='." bp-v-valid=" load-base bootparams-validate .refusal ." (blank=valid)" cr'$'\n'
zbody+='." bp-fields:" cr load-base bootparams-fields'$'\n'
zbody+='load hd:\\CBP.BIN'$'\n''." bp-open-corrupt=" load-base 300 bootparams-open u. cr'
drive "$zbody"
grep -qa 'undefined word' <<<"$OUT" \
    && fail "bootparams: a required contract word is undefined — core not implemented"
grep -qaE 'bp-manifest=.*ARCH:(4/4|x86-only)' <<<"$OUT" \
    || fail "bootparams: NAME-manifest carries no ARCH scope"
grep -qaE 'bp-v-valid=.*blank=valid' <<<"$OUT" && ! grep -qa 'bp-v-valid=REFUSED' <<<"$OUT" \
    || fail "bootparams: bootparams-validate refused a valid zero page"
grep -qa 'fld| name=boot_flag' <<<"$OUT" \
    || fail "bootparams: bootparams-fields did not enumerate the header"
grep -qa 'bp-open-corrupt=REFUSED: bootparams:' <<<"$OUT" \
    || fail "bootparams: bootparams-open did not refuse a wrong boot_flag BY NAME"
note "bootparams: validates a zero page, refuses a wrong boot_flag by name, ARCH:4/4 (LE, ppc earns its keep)"

# ── PART 3: the WRITER half — NAME-write graded on a DELTA + refuse-before-write ──
# The edit must land, a NEIGHBOUR must not move (only the delta), and an
# oversize/invalid edit must be refused BY NAME with the bytes UNCHANGED (no partial
# write). The refuse assertions ARE the negative controls of this section.
note "writer half: each NAME-write graded on the delta, with a refuse-before-write control"

# PE — pe-write edits .cmdline (0x100); .other (0x120) must not move.
wpbody="$(lev PE.FTH)"$'\n'"$(lev PEEDIT.FTH)"$'\n'"$(lev PEW.FTH)"
wpbody+=$'\n''load hd:\\WPE.BIN'$'\n'
wpbody+='load-base load-size s" .cmdline" s" NEW=1" pe-write drop'$'\n'
wpbody+='." pe-w-after=" load-base 100 + cstr type cr'$'\n'
wpbody+='." pe-w-neighbor=" load-base 120 + 4 type cr'$'\n'
wpbody+='load hd:\\WPE.BIN'$'\n'
wpbody+='." pe-w-refuse=" load-base load-size s" .cmdline" load-base 30 pe-write drop cr'$'\n'
wpbody+='." pe-w-intact=" load-base 100 + cstr type cr'
drive "$wpbody"
grep -qa 'undefined word' <<<"$OUT" \
    && fail "pe-write: a required word is undefined — the writer half is not implemented"
grep -qa 'pe-w-after=NEW=1' <<<"$OUT" \
    || fail "pe-write: the .cmdline edit did not land (expected NEW=1) — see the drive log"
grep -qa 'pe-w-neighbor=KEEP' <<<"$OUT" \
    || fail "pe-write: a NEIGHBOUR section changed — the edit wrote more than the delta"
grep -qa 'pe-w-refuse=edit| TOO-BIG' <<<"$OUT" \
    || fail "pe-write: an oversize edit was not refused BY NAME before the write"
grep -qa 'pe-w-intact=OLD' <<<"$OUT" \
    || fail "pe-write: a REFUSED edit still changed the bytes — a partial write past the refuse gate"
note "pe-write: .cmdline edit landed (NEW=1), neighbour intact (KEEP); oversize refused (edit| TOO-BIG), bytes unchanged (OLD)"

# CPIO — cpio-write patches member cfg (0x74); sibling keep (0xec) must not move.
wcbody="$(lev CPIO.FTH)"$'\n'"$(lev CPIOEDIT.FTH)"$'\n'"$(lev CPIOW.FTH)"
wcbody+=$'\n''load hd:\\WCPIO.BIN'$'\n'
wcbody+='load-base load-size 20 s" cfg" s" BBBB" cpio-write drop'$'\n'
wcbody+='." cpio-w-after=" load-base 74 + 4 type cr'$'\n'
wcbody+='." cpio-w-sibling=" load-base ec + 4 type cr'$'\n'
wcbody+='load hd:\\WCPIO.BIN'$'\n'
wcbody+='." cpio-w-refuse=" load-base load-size 20 s" cfg" s" BB" cpio-write drop cr'$'\n'
wcbody+='." cpio-w-intact=" load-base 74 + 4 type cr'
drive "$wcbody"
grep -qa 'undefined word' <<<"$OUT" \
    && fail "cpio-write: a required word is undefined — the writer half is not implemented"
grep -qa 'cpio-w-after=BBBB' <<<"$OUT" \
    || fail "cpio-write: the member edit did not land (expected BBBB)"
grep -qa 'cpio-w-sibling=ZZZZ' <<<"$OUT" \
    || fail "cpio-write: a SIBLING member changed — the edit wrote more than the delta"
grep -qa 'cpio-w-refuse=cpio| LEN-CHANGE' <<<"$OUT" \
    || fail "cpio-write: a length-changing edit was not refused BY NAME"
grep -qa 'cpio-w-intact=AAAA' <<<"$OUT" \
    || fail "cpio-write: a REFUSED edit still changed the member — a partial write past the refuse gate"
note "cpio-write: member edit landed (BBBB), sibling intact (ZZZZ); length change refused (cpio| LEN-CHANGE), bytes unchanged (AAAA)"

# BOOTPARAMS — bootparams-write edits the command line; code32_start must not move.
wbbody="$(lev BP.FTH)"$'\n'"$(lev BPEDIT.FTH)"$'\n'"$(lev BPW.FTH)"
wbbody+=$'\n''load hd:\\WBP.BIN'$'\n'
wbbody+='load-base load-size s" new=1" bootparams-write drop'$'\n'
wbbody+='." bp-w-after=" load-base 400 + cstr type cr'$'\n'
wbbody+='." bp-w-neighbor=" load-base 314 + le-l@ u. cr'$'\n'
wbbody+='load hd:\\WBP.BIN'$'\n'
wbbody+='." bp-w-refuse=" load-base load-size load-base 50 bootparams-write drop cr'$'\n'
wbbody+='." bp-w-intact=" load-base 400 + cstr type cr'
drive "$wbbody"
grep -qa 'undefined word' <<<"$OUT" \
    && fail "bootparams-write: a required word is undefined — the writer half is not implemented"
grep -qa 'bp-w-after=new=1' <<<"$OUT" \
    || fail "bootparams-write: the command-line edit did not land (expected new=1)"
grep -qa 'bp-w-neighbor=deadbeef' <<<"$OUT" \
    || fail "bootparams-write: code32_start (a NEIGHBOUR field) changed — the edit wrote more than the delta"
grep -qa 'bp-w-refuse=bp| CMDLINE-TOO-BIG' <<<"$OUT" \
    || fail "bootparams-write: an over-cmdline_size edit was not refused BY NAME"
grep -qa 'bp-w-intact=old' <<<"$OUT" \
    || fail "bootparams-write: a REFUSED edit still changed the command line — a partial write past the refuse gate"
note "bootparams-write: command line edited (new=1), code32_start intact (deadbeef); over-size refused (bp| CMDLINE-TOO-BIG), unchanged (old)"

# ── PART 2: the separability guarantee — a slim profile names what is absent ──
sbody="$(lev CBFS.FTH)"$'\n'"$(lev CBFSC.FTH)"$'\n'"$(lev ELF.FTH)"$'\n'"$(lev ELFC.FTH)"
sbody+=$'\n''." SLIM:" cr'$'\n'
sbody+='s" cbfs" need-module'$'\n''s" elf" need-module'$'\n'
sbody+='s" fdt" need-module'$'\n''s" evlog" need-module'$'\n'
sbody+='." NMODULES=" #modules @ . cr'
drive "$sbody"
grep -qa 'MODULE fdt: not loaded'   <<<"$OUT" \
    || fail "separability: a slim profile (cbfs+elf) did not NAME fdt absent — a dropped module was silently missing"
grep -qa 'MODULE evlog: not loaded' <<<"$OUT" \
    || fail "separability: a slim profile did not NAME evlog absent"
grep -qa 'MODULE cbfs: not loaded'  <<<"$OUT" \
    && fail "separability: a PRESENT module (cbfs) was mis-reported as not loaded — need-module lies about what is there"
grep -qa 'MODULE elf: not loaded'   <<<"$OUT" \
    && fail "separability: a PRESENT module (elf) was mis-reported as not loaded"
grep -qa 'NMODULES=2' <<<"$OUT" \
    || fail "separability: the registry counted something other than the 2 modules the slim profile loaded — a phantom or a missed registration"
note "separability: slim profile (cbfs+elf) names fdt+evlog absent, present modules not mis-reported, #modules=2"

pass "contract v1: struct.fth's reason seam + dsl/contract.fth's registry, and all seven modules (cbfs, elf, fdt, evlog — Tier 0; cpio, pe, bootparams — Tier 1) conform through per-module sidecars — each implements the required core, its manifest carries an ARCH scope, its validate refuses a corrupt fixture BY NAME and accepts a valid one, cbfs-list refuses a corrupt first entry (the closed silent-stop defect), and a slim profile names every absent module. The WRITER half (Tier 2) is graded on a DELTA: pe-write/cpio-write/bootparams-write each land an edit while a neighbour stays put, and each refuses an oversize/invalid edit BY NAME with the bytes unchanged (no partial write). The checker proved itself first: a conformant fixture passed and three planted defects (no arch scope, a lenient validate, a missing validate) were each caught."
