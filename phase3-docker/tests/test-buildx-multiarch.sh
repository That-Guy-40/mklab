#!/usr/bin/env bash
# Build an aarch64 image from any host via buildx + qemu-user-static.
# Skips on aarch64 hosts (would defeat the foreign-arch point) or when
# binfmt isn't registered.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_docker
require_cmd jq

[[ "$(uname -m)" != "aarch64" ]] || skip "host is aarch64; foreign-arch test wants a different host"

if [[ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]]; then
    skip "binfmt qemu-aarch64 not registered (run 'sudo update-binfmts --enable qemu-aarch64' or 'docker run --privileged --rm tonistiigi/binfmt --install all')"
fi

docker buildx version >/dev/null 2>&1 || skip "docker buildx not installed"

ctx="$(mktemp -d)"
tag="lab-mxa-test-$$:arm64"
name="t-mxa-$$"
cname="lab-${name}"

cleanup() {
    cleanup_container "$cname"
    docker rmi "$tag" >/dev/null 2>&1 || true
    rm -rf "$ctx"
}
trap cleanup EXIT

cat > "$ctx/Dockerfile" <<'EOF'
FROM alpine:latest
CMD ["uname", "-m"]
EOF

note "buildx --platform=linux/arm64 (this can take a couple of minutes)"
"$LAB_DOCKER" build --tag "$tag" --backend buildx --context "$ctx" --arch aarch64

note "run the image — should report aarch64"
got="$("$LAB_DOCKER" run --name "$name" --image "$tag" --rm --tty)"
got="${got//$'\r'/}"; got="${got//$'\n'/}"
[[ "$got" == "aarch64" ]] || fail "expected 'aarch64', got: $got"

pass "buildx multi-arch OK"
