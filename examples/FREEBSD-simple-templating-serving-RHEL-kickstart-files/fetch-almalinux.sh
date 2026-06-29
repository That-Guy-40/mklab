#!/bin/sh
# fetch-almalinux.sh — get the AlmaLinux bits this lab needs. Two subcommands:
#
#   boot-iso   (run on the HOST)     download the AlmaLinux boot ISO for the client
#   serve-dvd  (run on the FreeBSD VM, as root)
#                                    download the AlmaLinux DVD ISO, mount it, and
#                                    expose its BaseOS/AppStream under the nginx
#                                    docroot — the faithful "FreeBSD serves the DVD"
#
# Defaults target AlmaLinux 9 x86_64. Override with env: ALMA_MAJOR, ALMA_VER, ARCH.
ALMA_MAJOR="${ALMA_MAJOR:-9}"
ALMA_VER="${ALMA_VER:-9.5}"           # point release for the ISO filenames
ARCH="${ARCH:-x86_64}"
MIRROR="${MIRROR:-https://repo.almalinux.org/almalinux}"
WORKDIR="${WORKDIR:-$HOME/freebsd-kickstart-lab}"
DOCROOT="${DOCROOT:-/usr/local/www/nginx}"

boot_iso() {
    mkdir -p "$WORKDIR"
    url="$MIRROR/$ALMA_VER/isos/$ARCH/AlmaLinux-$ALMA_VER-$ARCH-boot.iso"
    echo "==> downloading boot ISO: $url"
    curl -fSL -o "$WORKDIR/almalinux-boot.iso" "$url"
    echo "==> saved $WORKDIR/almalinux-boot.iso  (attach as the client's first CD-ROM)"
}

serve_dvd() {
    # On FreeBSD, as root. Fetch the DVD, mount it, graft BaseOS/AppStream into the
    # docroot at the path the kickstart expects: almalinux/<major>/<repo>/<arch>/os
    iso="/tmp/AlmaLinux-$ALMA_VER-$ARCH-dvd.iso"
    url="$MIRROR/$ALMA_VER/isos/$ARCH/AlmaLinux-$ALMA_VER-$ARCH-dvd.iso"
    [ -f "$iso" ] || { echo "==> fetching DVD: $url (~10 GB)"; fetch -o "$iso" "$url"; }
    mnt=/mnt/almalinux-dvd
    mkdir -p "$mnt"
    md=$(mdconfig -a -t vnode -f "$iso")
    mount_cd9660 "/dev/$md" "$mnt"
    base="$DOCROOT/almalinux/$ALMA_MAJOR"
    mkdir -p "$base/BaseOS/$ARCH" "$base/AppStream/$ARCH"
    # The DVD lays out BaseOS/ and AppStream/ at its root, each with repodata +
    # Packages. Anaconda wants .../<repo>/<arch>/os, so point "os" at the DVD dirs.
    ln -snf "$mnt/BaseOS"    "$base/BaseOS/$ARCH/os"
    ln -snf "$mnt/AppStream" "$base/AppStream/$ARCH/os"
    echo "==> mounted $md at $mnt and grafted into $base"
    echo "    BaseOS    -> http://<server>/almalinux/$ALMA_MAJOR/BaseOS/$ARCH/os/"
    echo "    AppStream -> http://<server>/almalinux/$ALMA_MAJOR/AppStream/$ARCH/os/"
    echo "    (to undo: umount $mnt && mdconfig -d -u ${md#md})"
}

case "${1:-}" in
    boot-iso)  boot_iso ;;
    serve-dvd) serve_dvd ;;
    *) echo "usage: $0 {boot-iso|serve-dvd}" >&2; exit 1 ;;
esac
