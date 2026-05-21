#!/usr/bin/env bash
# §5/§6.4: the gen_init_cpio spec must bake /dev/console, keep uid/gid 0, and
# NOT embed the kernel (the whole point of the gen_init_cpio packer).
set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
need find readlink sort
# shellcheck source=/dev/null
source "$MLBUILD"
set +e

tree="$(mktemp -d)"; etc="$(mktemp -d)"; trap 'rm -rf "$tree" "$etc"' EXIT
mkdir -p "$tree/bin" "$tree/usr/bin" "$tree/sbin"
: > "$tree/bin/busybox"; chmod 0755 "$tree/bin/busybox"
ln -s busybox            "$tree/bin/ls"        # applet symlink (relative)
ln -s ../../bin/busybox  "$tree/usr/bin/awk"   # applet symlink (deeper)
for f in passwd group shadow securetty issue; do : > "$etc/$f"; done

spec="$(emit_cpio_spec /fake/init "$tree" "$etc")"

grep -q '^nod /dev/console 0600 0 0 c 5 1$'   <<<"$spec" || fail "missing /dev/console device node"
grep -q '^nod /dev/null 0666 0 0 c 1 3$'      <<<"$spec" || fail "missing /dev/null device node"
grep -q '^file /init /fake/init 0755 0 0$'    <<<"$spec" || fail "missing /init entry"
grep -q '^dir /usr 0755 0 0$'                 <<<"$spec" || fail "missing dir entry for /usr"
grep -q '^slink /bin/ls busybox 0777 0 0$'    <<<"$spec" || fail "missing slink entry for /bin/ls"
grep -q '^file /bin/busybox '                 <<<"$spec" || fail "missing file entry for busybox"
note "spec bakes /dev/console + /dev/null, /init, dirs, slinks, files"

# Login setup (getty + login): /etc account files + /root, with correct modes.
grep -q '^dir /root 0700 0 0$'                       <<<"$spec" || fail "missing /root dir"
grep -q '^dir /etc 0755 0 0$'                        <<<"$spec" || fail "missing /etc dir"
grep -q "^file /etc/passwd $etc/passwd 0644 0 0\$"   <<<"$spec" || fail "missing /etc/passwd"
grep -q "^file /etc/shadow $etc/shadow 0600 0 0\$"   <<<"$spec" || fail "/etc/shadow missing or not mode 0600"
grep -q "^file /etc/securetty $etc/securetty 0644 0 0\$" <<<"$spec" || fail "missing /etc/securetty"
grep -q "^file /etc/issue $etc/issue 0644 0 0\$"     <<<"$spec" || fail "missing /etc/issue"
note "login setup: /etc/{passwd,shadow(0600),securetty,issue} + /root baked"

if grep -qiE 'vmlinuz|/boot' <<<"$spec"; then
    fail "spec must NOT embed the kernel (/boot or vmlinuz found)"
fi
note "kernel is NOT embedded in the initramfs"

# every dir/file/slink/nod line must be owned by uid/gid 0
if grep -E '^(dir|file|slink|nod) ' <<<"$spec" | grep -vqE ' 0 0( c [0-9]+ [0-9]+)?$'; then
    fail "found a spec entry with a non-root owner"
fi
note "all entries are uid/gid 0 (reproducible, root-owned)"

pass "gen_init_cpio spec OK"
