#!/usr/bin/env bash
# Regression: `host-copy` against a statically-linked binary must succeed.
# ldd returns non-zero on static binaries ("not a dynamic executable") and
# earlier versions of the resolver let that kill the script via pipefail.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_root
require_cmd jq

static_bin=""
for cand in /bin/busybox /usr/bin/busybox; do
    if [[ -x "$cand" ]] && file "$cand" 2>/dev/null | grep -qi 'statically linked'; then
        static_bin="$cand"; break
    fi
done

if [[ -z "$static_bin" ]]; then
    # Fabricate a static binary via a tiny C program as a fallback.
    if have cc && have strip; then
        tmp_src="$(mktemp --suffix=.c)"
        static_bin="$(mktemp)"
        cat > "$tmp_src" <<'EOF'
int main(void) { return 0; }
EOF
        if cc -static -o "$static_bin" "$tmp_src" 2>/dev/null; then
            chmod +x "$static_bin"
            on_exit 'rm -f "$tmp_src" "$static_bin"'
        else
            rm -f "$tmp_src" "$static_bin"
            skip "no static binary available and static compile failed"
        fi
    else
        skip "no static binary on host and no cc+strip for fallback"
    fi
fi

target="$(mktest_target host-copy-static)"
name="hc-static-$$"
# No need to re-state the fallback's cleanup: registrations ACCUMULATE, where a second
# `trap … EXIT` would have replaced the first (which is why that branch existed).
on_exit 'cleanup_target "$target" "$name"'

note "host-copy with static binary: $static_bin"
"$LAB_CHROOT" create \
    --backend host-copy \
    --target "$target" \
    --name "$name" \
    --binaries "$static_bin"

[[ -x "${target}${static_bin}" ]] || fail "static binary not copied to chroot"

# The manifest must exist — earlier bug silently exited before writing it.
manifest="${LAB_STATE_DIR:-/var/lib/lab-create}/chroots/${name}.toml"
[[ -r "$manifest" ]] || manifest="/var/lib/lab-create/chroots/${name}.toml"
[[ -r "$manifest" ]] || fail "manifest not written — create exited silently?"

pass "host-copy tolerates statically-linked binaries"
