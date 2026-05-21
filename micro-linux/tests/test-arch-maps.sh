#!/usr/bin/env bash
# The per-arch toolchain maps (pure functions, no side effects).
set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
source "$MLBUILD"     # defines the functions; guarded main() does not run
set +e                # tests below capture rc explicitly

eq() { local got="$1" want="$2" lbl="$3"; [[ "$got" == "$want" ]] || fail "$lbl: got '$got' want '$want'"; note "$lbl = '${got}'"; }

eq "$(kernel_arch x86_64)"  "x86_64"               "kernel_arch x86_64"
eq "$(kernel_arch aarch64)" "arm64"                "kernel_arch aarch64"
eq "$(kernel_arch riscv64)" "riscv"                "kernel_arch riscv64"

eq "$(kernel_cross x86_64)"  ""                       "kernel_cross x86_64 (native)"
eq "$(kernel_cross aarch64)" "aarch64-linux-gnu-"     "kernel_cross aarch64"
eq "$(kernel_cross riscv64)" "riscv64-linux-gnu-"     "kernel_cross riscv64"

eq "$(kernel_image x86_64)"  "arch/x86/boot/bzImage"  "kernel_image x86_64"
eq "$(kernel_image aarch64)" "arch/arm64/boot/Image"  "kernel_image aarch64"
eq "$(kernel_image riscv64)" "arch/riscv/boot/Image"  "kernel_image riscv64"

eq "$(kernel_cons x86_64)"  "CONFIG_SERIAL_8250_CONSOLE"        "kernel_cons x86_64"
eq "$(kernel_cons aarch64)" "CONFIG_SERIAL_AMBA_PL011_CONSOLE"  "kernel_cons aarch64 (PL011)"
eq "$(kernel_cons riscv64)" "CONFIG_SERIAL_8250_CONSOLE"        "kernel_cons riscv64 (8250)"

pass "arch maps OK"
