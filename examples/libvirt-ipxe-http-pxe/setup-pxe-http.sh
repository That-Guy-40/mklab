#!/usr/bin/env bash
# setup-pxe-http.sh — scaffolding for Dusty Mabe's "easy PXE boot testing with
# only HTTP, using iPXE + libvirt" (dustymabe.com, 2019), for a modern host.
#
#   Upstream posts : upstream-tutorial/  (byte-exact archives + provenance)
#     Post 1 (pxelinux) : https://dustymabe.com/2019/01/04/easy-pxe-boot-testing-with-only-http-using-ipxe-and-libvirt/
#     Post 2 (minus-pxelinux) : https://dustymabe.com/2019/09/13/update-on-easy-pxe-boot-testing-post-minus-pxelinux/
#
# THE GEM: libvirt's NIC firmware is iPXE, which can fetch the DHCP *bootfile
# over HTTP*.  Put an http:// URL in the libvirt network's <bootp file=…> and the
# whole PXE flow — bootfile, kernel, initrd, kickstart, even the DVD repo — comes
# off one `python3 -m http.server`.  No TFTP.  Two variants:
#   ipxe     (post 2) bootfile = an iPXE script (#!ipxe) — no pxelinux at all
#   pxelinux (post 1) bootfile = pxelinux.0 → reads pxelinux.cfg/default
#
# This script does the parts that need NO root — it stages the HTTP tree by
# *extracting* the ISO with xorriso (the post loop-mounts it with sudo; we don't
# need to) and generates the configs exactly as the post's `cat <<EOF` blocks do.
# The steps that touch YOUR libvirt (editing the default network) or spin a VM
# are PRINTED for you to run — this script never reconfigures your networks.
#
# Usage:
#   setup-pxe-http.sh stage  --iso PATH [--variant ipxe|pxelinux] [--ip IP] [--port N]
#   setup-pxe-http.sh serve  [--port N]           # python3 -m http.server in the tree
#   setup-pxe-http.sh netxml [--variant …]        # emit ready libvirt net XML + next cmds
#   setup-pxe-http.sh virtinstall                  # print the virt-install command
#   setup-pxe-http.sh tree | clean | help
#
# Env: PXE_HTTP_DIR (default ~/.cache/lab-create/libvirt-ipxe-http-pxe/pxeserver)
set -euo pipefail

HTTPDIR="${PXE_HTTP_DIR:-$HOME/.cache/lab-create/libvirt-ipxe-http-pxe/pxeserver}"
IP="192.168.122.1"      # libvirt default bridge (virbr0); overridable with --ip
PORT="8000"
VARIANT="ipxe"
ISO=""
NET="${PXE_LIBVIRT_NET:-default}"
CONNECT="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

log()  { printf '\033[1;36m[pxe-http]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[pxe-http] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[pxe-http] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

parse() {  # consume common flags from "$@"
    while (($#)); do
        case "$1" in
            --iso)     ISO="$2"; shift 2;;
            --variant) VARIANT="$2"; shift 2;;
            --ip)      IP="$2"; shift 2;;
            --port)    PORT="$2"; shift 2;;
            *) die "unknown flag: $1";;
        esac
    done
    [[ "$VARIANT" == ipxe || "$VARIANT" == pxelinux ]] \
        || die "--variant must be 'ipxe' or 'pxelinux'"
}

# ─── stage: extract ISO (rootless) + generate configs ───────────────────────
stage() {
    parse "$@"
    [[ -n "$ISO" ]] || die "stage needs --iso PATH (a Fedora Server DVD ISO)"
    [[ -f "$ISO" ]] || die "no such ISO: $ISO"
    command -v xorriso >/dev/null || die "need xorriso (apt install xorriso / dnf install xorriso)"
    local isobase; isobase="$(basename "$ISO")"

    mkdir -p "$HTTPDIR"
    local dest="$HTTPDIR/$isobase"
    if [[ -e "$dest/images/pxeboot/vmlinuz" ]]; then
        log "ISO already extracted: $dest"
    else
        log "extracting $isobase (rootless, via xorriso — no loop-mount) …"
        rm -rf "$dest"; mkdir -p "$dest"
        xorriso -osirrox on -indev "$ISO" -extract / "$dest" 2>/dev/null \
            || die "xorriso extract failed"
        [[ -e "$dest/images/pxeboot/vmlinuz" ]] \
            || die "extracted, but $isobase has no images/pxeboot/vmlinuz — is it a Server DVD?"
    fi

    # kickstart.cfg — faithful to the post; url --url points at the served DVD.
    cat > "$HTTPDIR/kickstart.cfg" <<EOF
url --url http://$IP:$PORT/$isobase/
reboot
rootpw --plaintext foobar
services --enabled="sshd,chronyd"
zerombr
clearpart --all
autopart --type lvm
# Modern Anaconda is happier with these two; the 2019 post omitted them.
network --bootproto=dhcp
timezone --utc Etc/UTC
%packages
@core
%end
EOF

    if [[ "$VARIANT" == ipxe ]]; then
        # post 2: an iPXE script IS the bootfile.
        cat > "$HTTPDIR/boot.ipxe" <<EOF
#!ipxe
kernel $isobase/images/pxeboot/vmlinuz console=ttyS0 inst.ks=http://$IP:$PORT/kickstart.cfg
initrd $isobase/images/pxeboot/initrd.img
boot
EOF
        log "generated: kickstart.cfg + boot.ipxe"
    else
        # post 1: pxelinux.0 is the bootfile → reads pxelinux.cfg/default.
        local sx=/usr/share/syslinux have_sx=0
        if [[ -f "$sx/pxelinux.0" && -f "$sx/ldlinux.c32" ]]; then
            cp "$sx/pxelinux.0" "$sx/ldlinux.c32" "$HTTPDIR/"; have_sx=1
        else
            warn "syslinux not found at $sx — install 'syslinux' (Fedora) /"
            warn "'syslinux-common pxelinux' (Debian), then copy pxelinux.0 + ldlinux.c32 into $HTTPDIR"
        fi
        mkdir -p "$HTTPDIR/pxelinux.cfg"
        cat > "$HTTPDIR/pxelinux.cfg/default" <<EOF
DEFAULT pxeboot
TIMEOUT 20
PROMPT 0
LABEL pxeboot
    KERNEL $isobase/images/pxeboot/vmlinuz
    APPEND initrd=$isobase/images/pxeboot/initrd.img console=ttyS0 inst.ks=http://$IP:$PORT/kickstart.cfg
IPAPPEND 2
EOF
        (( have_sx )) \
            && log "generated: kickstart.cfg + pxelinux.cfg/default + pxelinux.0/ldlinux.c32" \
            || log "generated: kickstart.cfg + pxelinux.cfg/default (pxelinux.0/ldlinux.c32 still needed — see WARN above)"
    fi
    printf '%s\n' "$VARIANT" > "$HTTPDIR/.variant"
    do_tree
    log "next: '$0 serve'  (new terminal),  then '$0 netxml',  then '$0 virtinstall'"
}

do_tree() {
    log "HTTP root: $HTTPDIR"
    if command -v tree >/dev/null; then tree -L 2 "$HTTPDIR" >&2
    else (cd "$HTTPDIR" && find . -maxdepth 2 ! -path . | sort >&2); fi
}

serve() {
    parse "$@"
    [[ -d "$HTTPDIR" ]] || die "nothing staged — run '$0 stage --iso …' first"
    log "serving $HTTPDIR on http://$IP:$PORT/  (Ctrl-C to stop)"
    cd "$HTTPDIR"; exec python3 -m http.server "$PORT"
}

# ─── netxml: derive a ready net XML from YOUR current net + the bootp line ──
netxml() {
    parse "$@"
    command -v virsh >/dev/null || die "virsh not found"
    local bootfile out backup
    [[ "$VARIANT" == ipxe ]] && bootfile="http://$IP:$PORT/boot.ipxe" \
                             || bootfile="http://$IP:$PORT/pxelinux.0"
    out="$HTTPDIR/net-$NET-$VARIANT.xml"; backup="$HTTPDIR/net-$NET.orig.xml"
    mkdir -p "$HTTPDIR"
    virsh -c "$CONNECT" net-dumpxml "$NET" > "$backup" 2>/dev/null \
        || die "couldn't dump net '$NET' from $CONNECT (is libvirt up / are you in the libvirt group?)"
    grep -q "<bootp" "$backup" && warn "net '$NET' already has a <bootp> line; review $out"
    # inject <bootp file=…/> as the last child of <dhcp> (idempotent-ish)
    python3 - "$backup" "$bootfile" > "$out" <<'PY'
import sys,re
xml=open(sys.argv[1]).read(); bf=sys.argv[2]
xml=re.sub(r'\n[ \t]*<bootp file=[^\n]*', '', xml)         # drop any existing
# insert as the last child of <dhcp>, preserving </dhcp>'s own indentation
xml=re.sub(r'\n([ \t]*)</dhcp>',
           lambda m: f"\n      <bootp file='{bf}'/>\n{m.group(1)}</dhcp>",
           xml, count=1)
sys.stdout.write(xml)
PY
    xmllint --noout "$out" 2>/dev/null || die "generated XML failed xmllint: $out"
    log "wrote $out   (original backed up: $backup)"
    cat >&2 <<EOF

  To apply it to YOUR libvirt (this is the step the post does with net-edit):
    virsh -c $CONNECT net-destroy $NET
    virsh -c $CONNECT net-define  $out
    virsh -c $CONNECT net-start   $NET
  To restore afterwards:
    virsh -c $CONNECT net-destroy $NET && virsh -c $CONNECT net-define $backup && virsh -c $CONNECT net-start $NET
EOF
}

virtinstall() {
    cat >&2 <<EOF
  Run the installer VM (serial console; the whole point is you watch iPXE HTTP-boot):
    virt-install --connect $CONNECT --pxe --network network=$NET \\
        --name pxe --memory 2048 --disk size=10 \\
        --nographics --boot menu=on,useserial=on \\
        --osinfo detect=on,require=off
  (--osinfo is the one modern addition: the 2019 post's command errors on
   current virt-install, which now REQUIRES an --osinfo/--os-variant.)

  Tear it down when done:
    virsh -c $CONNECT destroy pxe ; virsh -c $CONNECT undefine pxe --remove-all-storage
EOF
}

clean() {
    log "removing $HTTPDIR"; rm -rf "$HTTPDIR"
    warn "if you applied the net XML, restore your network with the net.orig.xml (see README)"
}

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d;s/^# \{0,1\}//'; }

case "${1:-help}" in
    stage)       shift; stage "$@";;
    serve)       shift; serve "$@";;
    netxml)      shift; netxml "$@";;
    virtinstall) shift; virtinstall;;
    tree)        do_tree;;
    clean)       clean;;
    help|-h|--help) usage;;
    *) die "unknown command '${1}' (try: help)";;
esac
