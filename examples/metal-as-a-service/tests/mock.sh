#!/usr/bin/env bash
# mock-driver.sh — a deploy driver for tests, so the health gate + A/B rollback in
# maas-lab.sh drive HEADLESSLY (no PXE, no libvirt, no boot). It implements the
# driver contract: verify/deploy/health/describe.
#
#  - verify:  REAL openssl CMS verification (via verify-lib) of the image's signed
#             payloads in $MAAS_IMAGES_DIR/<image>/ vs $MAAS_IMAGES_DIR/trust/ca.crt
#             — so the tamper drill is genuine, not a stub.
#  - deploy:  records the call to $MOCK_DEPLOY_LOG; fails if MOCK_DEPLOY_FAIL names
#             the image (simulates a deploy that didn't even boot).
#  - health:  reads MOCK_HEALTH_<image> = pass|fail (default pass) — the injectable
#             success signal that drives the gate/rollback branches.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VERIFY_LIB="$HERE/../drivers/verify-lib.sh"

verb="${1:-}"; shift || true

# sanitize an image name into a VALID env-var suffix: uppercase, every non-alnum
# char -> '_' (so v1->V1, good-v2->GOOD_V2, image+measured->IMAGE_MEASURED — never
# an invalid identifier that would break ${!key}).
_envkey() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -c '[:alnum:]' '_'; }

case "$verb" in
verify)
    image="${1:?mock verify <image>}"
    dir="${MAAS_IMAGES_DIR:?}/$image"
    ca="${MAAS_IMAGES_DIR}/trust/ca.crt"
    exec "$VERIFY_LIB" verify-dir "$dir" --ca "$ca"
    ;;
deploy)
    node="${1:?}"; image="${2:?}"; slot="${3:-current}"
    [[ -n "${MOCK_DEPLOY_LOG:-}" ]] && printf '%s %s %s\n' "$node" "$image" "$slot" >> "$MOCK_DEPLOY_LOG"
    if [[ " ${MOCK_DEPLOY_FAIL:-} " == *" $image "* ]]; then
        echo "mock-driver: deploy of '$image' failed (MOCK_DEPLOY_FAIL)" >&2; exit 1
    fi
    exit 0
    ;;
health)
    node="${1:?}"; image="${2:?}"
    key="MOCK_HEALTH_$(_envkey "$image")"
    val="${!key:-pass}"
    [[ "$val" == pass ]] && exit 0
    echo "mock-driver: health of '$image' = $val" >&2
    exit 1
    ;;
describe) echo "mock driver: health = MOCK_HEALTH_<image> (test fixture)"; ;;
*) echo "mock-driver: unknown verb '$verb' (verify|deploy|health|describe)" >&2; exit 2 ;;
esac
