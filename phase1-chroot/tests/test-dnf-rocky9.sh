#!/usr/bin/env bash
# Rocky 9 chroot via dnf, native arch only.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_root
require_cmd jq

if ! command -v dnf >/dev/null 2>&1 && ! command -v yum >/dev/null 2>&1; then
    skip "neither dnf nor yum on host"
fi

# dnf invokes rpmkeys (from the `rpm` package) to verify GPG signatures on
# downloaded RPMs.  On Debian/Ubuntu hosts the default dnf install only
# pulls `rpm-common`, so rpmkeys is absent and every package "Problem
# opening" with "Cannot find rpmkeys executable to verify signatures."
command -v rpmkeys >/dev/null 2>&1 \
    || skip "rpmkeys not on host (apt-get install rpm) — dnf cannot verify GPG signatures without it"

case "$(uname -m)" in
    x86_64|aarch64|ppc64le|s390x|riscv64) ;;
    *) skip "Rocky does not publish for $(uname -m)" ;;
esac

target="$(mktest_target dnf-rocky9)"
name="rocky9-$$"
trap 'cleanup_target "$target" "$name"' EXIT

note "dnf install (this takes a few minutes)"
"$LAB_CHROOT" create \
    --backend dnf --distro rocky --suite 9 \
    --arch "$(uname -m)" --target "$target" --name "$name" \
    --include bash,coreutils

[[ -r "${target}/etc/os-release" ]] || fail "no /etc/os-release in tree"
grep -q '^ID="rocky"' "${target}/etc/os-release" \
    || grep -q '^ID=rocky' "${target}/etc/os-release" \
    || fail "/etc/os-release does not identify as rocky"

note "exec test inside chroot"
"$LAB_CHROOT" enter "$name" -- /bin/true || fail "chroot enter+exec failed"

pass "Rocky 9 dnf chroot built and executed"
